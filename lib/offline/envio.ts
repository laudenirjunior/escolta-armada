/**
 * Envio da fila de campo ao servidor (Lote 2026-10, onda L; docs/14, seção 16.3.2).
 *
 * - Gatilhos: evento online, volta da aba (visibilitychange), relógio de 30 s com o app
 *   aberto e logo depois de cada registro (dispararEnvio).
 * - Uma aba por vez: navigator.locks ('fila-campo'); o servidor cobre o resto (client_id).
 * - Ordem: emergência primeiro, depois a ordem de registro (seq). Para cada registro: sobe
 *   as fotos (objeto que já existe no bucket conta como sucesso), chama registrar_campo e
 *   marca o resultado. Falha de rede para a fila inteira (a etapa seguinte depende da
 *   anterior) e tenta de novo com espera crescente.
 * - Antes do primeiro envio de cada rodada: auth.refreshSession(). Sessão que não renova
 *   (refresh revogado, usuário bloqueado) para a fila e pede novo login do mesmo usuário.
 * - A fila é por auth_user_id: outro usuário no mesmo aparelho não envia a do anterior.
 * - SEM_VINCULO ou PAYLOAD_INVALIDO: estado recusado (nada gravado no servidor), visível ao
 *   operador e nunca reenviado.
 * - Depois de cada rodada com envio, informa ao servidor quantos registros ainda estão no
 *   aparelho (informar_pendentes), usado na reversão da onda.
 * - Chave offline_ligado (config_offline): lida aqui; desligada, as telas gravam direto,
 *   como antes, e esta fila continua sendo esvaziada.
 *
 * Sem import do app em tempo de execução: o cliente Supabase entra por parâmetro (testes).
 */
import { pedirEnderecoDepois, temEnderecoPendente } from '../geocodificacao.ts'
import {
  apagarFotosSubidas, atualizarRegistro, concluirAplicado, contarFila, lerFoto, marcarFotoSubida,
  pendentesDoUsuario, recuperarEnviando, filaDisponivel, novoId,
  type RegistroFila, type AvisoPosEnvio,
} from './fila.ts'

// ── Contratos mínimos do cliente Supabase (o real e o falso dos testes) ──────────────
export interface ErroSupabase {
  message: string
  code?: string
  details?: string | null
  hint?: string | null
  name?: string
  status?: number
  statusCode?: string | number
}
export interface RespostaRpc<T = unknown> {
  data: T | null
  error: ErroSupabase | null
  status?: number
}
export interface ClienteOffline {
  rpc(fn: string, args?: Record<string, unknown>): PromiseLike<RespostaRpc>
  storage: {
    from(bucket: string): {
      upload(caminho: string, corpo: Blob, opcoes?: { upsert?: boolean; contentType?: string; cacheControl?: string }): PromiseLike<{ data: unknown; error: ErroSupabase | null }>
      createSignedUrl(caminho: string, segundos: number): PromiseLike<{ data: { signedUrl: string } | null; error: ErroSupabase | null }>
    }
  }
  auth: {
    refreshSession(): PromiseLike<{ data: { session: { user: { id: string } } | null }; error: ErroSupabase | null }>
  }
}

export interface DependenciasEnvio {
  supabase: ClienteOffline
  authUserId: string
  /** fetch para o /api/telegram (padrão: o global). */
  fetch?: typeof fetch
  /** Online segundo o aparelho (padrão: navigator.onLine). */
  online?: () => boolean
}

// ── Estado observável (faixa fixa, contador do Painel) ────────────────────────────────
export interface EstadoEnvio {
  authUserId: string | null
  online: boolean
  enviando: boolean
  pendentes: number
  conflitos: number
  recusados: number
  /** Sessão não renovou: "Entre de novo para enviar N registros". */
  precisaLogin: boolean
  /** registrar_campo ainda não existe no servidor (código novo sem a 219). */
  atualizacaoEmAndamento: boolean
  ultimoErro: string | null
  proximaTentativaEm: number | null
  /**
   * Onda O (A1): andamento do registro que está subindo agora, para a tela mostrar
   * "Enviando foto 3 de 7" e "Gravando etapa" em vez de um "Iniciando..." parado.
   */
  progresso: ProgressoEnvio | null
}

export interface ProgressoEnvio { clientId: string; fase: 'fotos' | 'registro'; fotosFeitas: number; fotosTotal: number }

const ESTADO_INICIAL: EstadoEnvio = {
  authUserId: null, online: true, enviando: false, pendentes: 0, conflitos: 0, recusados: 0,
  precisaLogin: false, atualizacaoEmAndamento: false, ultimoErro: null, proximaTentativaEm: null, progresso: null,
}

/** Onda O (A1): fotos sobem em paralelo, no máximo 3 por vez (rede de celular). */
export const FOTOS_EM_PARALELO = 3

/**
 * Roda `fn` para cada item com no máximo `limite` em andamento, na ordem de início, e devolve os
 * resultados na ordem dos itens. Sem dependência do app (usado na fila e nas telas).
 */
export async function emParalelo<T, R>(itens: T[], limite: number, fn: (item: T, i: number) => Promise<R>): Promise<R[]> {
  const saida: R[] = new Array(itens.length)
  let proximo = 0
  const trabalhador = async () => {
    while (proximo < itens.length) {
      const i = proximo++
      saida[i] = await fn(itens[i], i)
    }
  }
  await Promise.all(Array.from({ length: Math.min(Math.max(1, limite), itens.length) }, trabalhador))
  return saida
}

// ── Aviso de conclusão por registro (onda O, A1) ─────────────────────────────────────
// A tela que gravou espera só o PRÓPRIO registro ser aplicado (ou virar conflito ou recusa),
// não a fila inteira nem o Telegram, que seguem em segundo plano.
const esperandoConclusao = new Map<string, Array<() => void>>()
export function aoConcluirRegistro(clientId: string): Promise<void> {
  return new Promise(resolve => {
    const lista = esperandoConclusao.get(clientId) ?? []
    lista.push(resolve)
    esperandoConclusao.set(clientId, lista)
  })
}
function avisarConclusao(clientId: string): void {
  const lista = esperandoConclusao.get(clientId)
  if (!lista) return
  esperandoConclusao.delete(clientId)
  for (const fn of lista) { try { fn() } catch { /* nada */ } }
}
let estado: EstadoEnvio = { ...ESTADO_INICIAL }
const ouvintes = new Set<(e: EstadoEnvio) => void>()

export function lerEstadoEnvio(): EstadoEnvio { return estado }
export function assinarEstadoEnvio(fn: (e: EstadoEnvio) => void): () => void {
  ouvintes.add(fn)
  return () => { ouvintes.delete(fn) }
}
function mudar(parcial: Partial<EstadoEnvio>): void {
  estado = { ...estado, ...parcial }
  for (const fn of ouvintes) { try { fn(estado) } catch { /* ouvinte não derruba o envio */ } }
}
/** Só para os testes. */
export function reiniciarEstadoEnvio(): void {
  estado = { ...ESTADO_INICIAL }
  falhasSeguidas = 0
  proximaTentativa = 0
  emAndamentoLocal = null
}

export async function atualizarContagem(authUserId: string): Promise<void> {
  if (!filaDisponivel()) return
  try {
    const c = await contarFila(authUserId)
    mudar({ authUserId, pendentes: c.pendentes, conflitos: c.conflitos, recusados: c.recusados })
  } catch { /* fila ilegível: mantém a última contagem */ }
}

// ── Classificação dos erros ─────────────────────────────────────────────────────────
export type ClasseErro = 'rede' | 'login' | 'atualizacao' | 'recusado' | 'temporario'

const RE_REDE = /failed to fetch|fetch failed|networkerror|network request failed|load failed|err_internet|err_network|timeout|aborted|offline/i

export function classificarErro(erro: ErroSupabase | null | undefined, status?: number): ClasseErro {
  if (!erro) return 'temporario'
  const msg = String(erro.message ?? '')
  const code = String(erro.code ?? '')
  if (msg === 'SEM_VINCULO' || msg.startsWith('PAYLOAD_INVALIDO') || msg.startsWith('Identificador de registro já usado')) return 'recusado'
  if (code === 'PGRST202' || status === 404) return 'atualizacao'
  if (code === 'PGRST301' || code === 'PGRST303' || status === 401 || /jwt/i.test(msg) || msg === 'Sessão inválida.') return 'login'
  if ((status === 0 || status === undefined || !code) && RE_REDE.test(msg)) return 'rede'
  if (erro.name === 'AuthRetryableFetchError' || erro.name === 'StorageUnknownError' || erro.name === 'TypeError') return 'rede'
  return 'temporario'
}

function objetoJaExiste(erro: ErroSupabase): boolean {
  const s = String(erro.statusCode ?? erro.status ?? '')
  return s === '409' || /already exists|duplicate/i.test(String(erro.message ?? ''))
}

// ── Espera crescente ────────────────────────────────────────────────────────────────
let falhasSeguidas = 0
let proximaTentativa = 0
const ESPERA_BASE_MS = 5_000
const ESPERA_MAX_MS = 5 * 60_000
function falhou(): void {
  falhasSeguidas++
  const espera = Math.min(ESPERA_MAX_MS, ESPERA_BASE_MS * 2 ** (falhasSeguidas - 1))
  proximaTentativa = Date.now() + espera
  mudar({ proximaTentativaEm: proximaTentativa })
}
function deuCerto(): void {
  falhasSeguidas = 0
  proximaTentativa = 0
  mudar({ proximaTentativaEm: null })
}

// ── Aparelho ────────────────────────────────────────────────────────────────────────
let aparelhoMemoria: string | null = null
export function idDoAparelho(): string {
  try {
    const salvo = globalThis.localStorage?.getItem('escolta-campo:aparelho')
    if (salvo) return salvo
    const novo = novoId()
    globalThis.localStorage?.setItem('escolta-campo:aparelho', novo)
    return novo
  } catch {
    if (!aparelhoMemoria) aparelhoMemoria = novoId()
    return aparelhoMemoria
  }
}

// ── Configuração (chave offline_ligado e telefone da central) ───────────────────────
export interface ConfigOffline { offlineLigado: boolean; telefoneCentral: string | null }
let configMemoria: ConfigOffline | null = null

/**
 * Lê config_offline uma vez por sessão (e guarda para abrir sem internet). Sem a RPC (código
 * novo sem a 219): desligado ("Atualização em andamento"). Sem rede e sem cópia: ligado (é
 * a única forma de não perder o registro).
 */
export async function lerConfigOffline(supabase: ClienteOffline, forcar = false): Promise<ConfigOffline> {
  if (configMemoria && !forcar) return configMemoria
  try {
    const r = await supabase.rpc('config_offline')
    if (r.error) {
      const classe = classificarErro(r.error, r.status)
      if (classe === 'atualizacao') {
        mudar({ atualizacaoEmAndamento: true })
        configMemoria = { offlineLigado: false, telefoneCentral: null }
        return configMemoria
      }
      throw r.error
    }
    const d = (r.data ?? {}) as { offline_ligado?: boolean; telefone_central?: string | null }
    configMemoria = { offlineLigado: d.offline_ligado !== false, telefoneCentral: d.telefone_central ?? null }
    try { globalThis.localStorage?.setItem('escolta-campo:config', JSON.stringify(configMemoria)) } catch { /* sem memória */ }
    mudar({ atualizacaoEmAndamento: false })
    return configMemoria
  } catch {
    try {
      const salvo = globalThis.localStorage?.getItem('escolta-campo:config')
      if (salvo) return (configMemoria = JSON.parse(salvo) as ConfigOffline)
    } catch { /* sem memória */ }
    return { offlineLigado: true, telefoneCentral: null }
  }
}
/** Só para os testes. */
export function esquecerConfigOffline(): void { configMemoria = null }

// ── Desvio do relógio do aparelho (cabeçalho Date da última resposta) ───────────────
let desvioRelogioMs: number | null = null
export function registrarHoraServidor(dataHttp: string | null | undefined): void {
  if (!dataHttp) return
  const t = Date.parse(dataHttp)
  if (Number.isFinite(t)) desvioRelogioMs = Date.now() - t
}
export function desvioDoRelogio(): number | null { return desvioRelogioMs }

// ── Exclusão entre abas ─────────────────────────────────────────────────────────────
let emAndamentoLocal: Promise<unknown> | null = null
interface TravasNavegador {
  request<T>(nome: string, opcoes: { ifAvailable?: boolean }, fn: (trava: unknown) => Promise<T>): Promise<T>
}
async function comTrava<T>(esperar: boolean, fn: () => Promise<T>): Promise<T | null> {
  const travas = (globalThis.navigator as { locks?: TravasNavegador } | undefined)?.locks
  if (travas?.request) {
    return travas.request<T | null>('fila-campo', esperar ? {} : { ifAvailable: true }, async trava => (trava ? fn() : null))
  }
  // Sem Web Locks (navegador antigo, testes): exclusão só dentro desta aba.
  while (emAndamentoLocal) {
    if (!esperar) return null
    try { await emAndamentoLocal } catch { /* a outra rodada falhou; segue */ }
  }
  const p = fn()
  emAndamentoLocal = p
  try { return await p } finally { emAndamentoLocal = null }
}

// ── Uma rodada de envio ─────────────────────────────────────────────────────────────
export type ParadaEnvio = 'rede' | 'login' | 'atualizacao' | 'temporario' | 'ocupado' | 'espera' | 'offline' | null

export interface ResumoEnvio {
  aplicados: string[]
  conflitos: string[]
  recusados: string[]
  parouPor: ParadaEnvio
}

export interface OpcoesEnvio {
  /** Espera a trava (envio online de um registro) em vez de desistir se outra aba envia. */
  esperarTrava?: boolean
  /** Ignora a espera crescente (gatilho online ou registro novo com sinal). */
  ignorarEspera?: boolean
}

export async function enviarFila(deps: DependenciasEnvio, opcoes: OpcoesEnvio = {}): Promise<ResumoEnvio> {
  const resumo: ResumoEnvio = { aplicados: [], conflitos: [], recusados: [], parouPor: null }
  if (!filaDisponivel()) return resumo
  const online = deps.online ?? (() => (typeof navigator === 'undefined' ? true : navigator.onLine !== false))
  mudar({ authUserId: deps.authUserId, online: online() })
  if (!online()) { resumo.parouPor = 'offline'; await atualizarContagem(deps.authUserId); return resumo }
  if (!opcoes.ignorarEspera && proximaTentativa > Date.now()) { resumo.parouPor = 'espera'; return resumo }

  const r = await comTrava(!!opcoes.esperarTrava, () => rodada(deps, resumo))
  if (r === null) resumo.parouPor = 'ocupado'
  await atualizarContagem(deps.authUserId)
  return resumo
}

async function rodada(deps: DependenciasEnvio, resumo: ResumoEnvio): Promise<ResumoEnvio> {
  const { supabase, authUserId } = deps
  await recuperarEnviando(authUserId)
  const fila = await pendentesDoUsuario(authUserId)
  if (fila.length === 0) { deuCerto(); return resumo }

  mudar({ enviando: true })
  try {
    // Sessão do MESMO usuário, renovada antes de enviar.
    const ses = await supabase.auth.refreshSession()
    if (ses.error || !ses.data.session) {
      const classe = ses.error ? classificarErro(ses.error, ses.error.status) : 'login'
      if (classe === 'rede') { falhou(); resumo.parouPor = 'rede'; mudar({ ultimoErro: 'Sem conexão com o servidor.' }); return resumo }
      resumo.parouPor = 'login'
      mudar({ precisaLogin: true, ultimoErro: 'A sessão expirou. Entre de novo para enviar os registros guardados.' })
      return resumo
    }
    if (ses.data.session.user.id !== authUserId) {
      // Outro usuário entrou neste aparelho: a fila do anterior espera ele voltar.
      resumo.parouPor = 'login'
      return resumo
    }
    mudar({ precisaLogin: false })

    for (const reg of fila) {
      const r = await enviarUm(deps, reg)
      if (r === 'aplicado') resumo.aplicados.push(reg.client_id)
      else if (r === 'conflito') resumo.conflitos.push(reg.client_id)
      else if (r === 'recusado') resumo.recusados.push(reg.client_id)
      else {
        resumo.parouPor = r
        if (r === 'rede' || r === 'temporario') falhou()
        if (r === 'login') mudar({ precisaLogin: true, ultimoErro: 'A sessão expirou. Entre de novo para enviar os registros guardados.' })
        if (r === 'atualizacao') mudar({ atualizacaoEmAndamento: true, ultimoErro: 'Atualização em andamento: os registros ficam guardados até o servidor ser atualizado.' })
        break
      }
    }
    if (!resumo.parouPor) { deuCerto(); mudar({ ultimoErro: null }) }

    // Onda M (B2): os pontos que subiram sem endereço (gravados sem internet) recebem o
    // endereço por extenso uma única vez, pelo servidor, depois de chegarem ao banco.
    // Revisão cruzada (2.2): também quando sobrou pedido de uma rodada anterior.
    if (resumo.aplicados.length || temEnderecoPendente()) {
      const aplicados = new Set(resumo.aplicados)
      pedirEnderecoDepois(fila.filter(r => aplicados.has(r.client_id)).map(r => r.escolta_id), deps.fetch ?? fetch)
    }

    // Contagem do aparelho (reversão em duas etapas, 16.5).
    try {
      const c = await contarFila(authUserId)
      await supabase.rpc('informar_pendentes', { p_aparelho_id: idDoAparelho(), p_pendentes: c.pendentes })
    } catch { /* informativo */ }
    return resumo
  } finally {
    mudar({ enviando: false })
  }
}

type ResultadoUm = 'aplicado' | 'conflito' | 'recusado' | Exclude<ClasseErro, 'recusado'>

async function enviarUm(deps: DependenciasEnvio, reg: RegistroFila): Promise<ResultadoUm> {
  const { supabase } = deps
  await atualizarRegistro(reg.client_id, { estado: 'enviando', tentativas: (reg.tentativas ?? 0) + 1 })

  // 1. Fotos (caminho determinístico; "já existe" é sucesso). Onda O (A1): até 3 em paralelo,
  // com o andamento publicado para a tela. Qualquer falha deixa o registro pendente e o
  // envelope não é chamado (as que subiram ficam marcadas e não sobem de novo).
  const idsFotos = reg.fotos ?? []
  let feitas = 0
  const progresso = (fase: ProgressoEnvio['fase']) =>
    mudar({ progresso: { clientId: reg.client_id, fase, fotosFeitas: feitas, fotosTotal: idsFotos.length } })
  progresso('fotos')
  const erros = await emParalelo(idsFotos, FOTOS_EM_PARALELO, async (fotoId): Promise<ErroSupabase | null> => {
    const f = await lerFoto(fotoId)
    if (!f || f.estado === 'subida') { feitas++; progresso('fotos'); return null }
    const up = await supabase.storage.from('fotos').upload(f.caminho, f.blob, { upsert: false, contentType: f.tipo_mime || 'image/jpeg' })
    if (up.error && !objetoJaExiste(up.error)) return up.error
    await marcarFotoSubida(fotoId)
    feitas++; progresso('fotos')
    return null
  })
  const erroFoto = erros.find((e): e is ErroSupabase => !!e)
  if (erroFoto) {
    const classe = classificarErro(erroFoto, Number(erroFoto.statusCode ?? erroFoto.status) || undefined)
    await atualizarRegistro(reg.client_id, { estado: 'pendente', ultimo_erro: `Foto: ${erroFoto.message}` })
    mudar({ progresso: null })
    return classe === 'recusado' ? 'temporario' : classe
  }

  // 2. O envelope.
  progresso('registro')
  const resp = await supabase.rpc('registrar_campo', {
    p_client_id: reg.client_id,
    p_tipo: reg.tipo,
    p_payload: reg.payload,
    p_versao_gestao: reg.versao_gestao,
    p_data_hora_acao: reg.data_hora_acao,
    p_relogio: { ...(reg.relogio ?? {}), aparelho: idDoAparelho(), desvio_ms: desvioRelogioMs, tentativas: (reg.tentativas ?? 0) + 1 },
  })
  if (resp.error) {
    const classe = classificarErro(resp.error, resp.status)
    if (classe === 'recusado') {
      await atualizarRegistro(reg.client_id, { estado: 'recusado', ultimo_erro: resp.error.message, enviado_em: new Date().toISOString() })
      await apagarFotosSubidas(reg.client_id)
      mudar({ progresso: null }); avisarConclusao(reg.client_id)
      return 'recusado'
    }
    await atualizarRegistro(reg.client_id, { estado: 'pendente', ultimo_erro: resp.error.message })
    mudar({ progresso: null })
    return classe
  }
  const d = (resp.data ?? {}) as { resultado?: string; motivo?: string | null; recebido_em?: string | null; texto_offline?: string | null; duplicado?: boolean }
  if (d.resultado === 'aplicado') {
    await concluirAplicado(reg.client_id, {
      client_id: reg.client_id, auth_user_id: reg.auth_user_id, escolta_id: reg.escolta_id, tipo: reg.tipo,
      data_hora_acao: reg.data_hora_acao, recebido_em: d.recebido_em ?? null, resultado: 'aplicado',
      texto_offline: d.texto_offline ?? null, resposta: (resp.data ?? null) as Record<string, unknown> | null,
    })
    // Onda O (A1): a tela que gravou já pode seguir; o Telegram vem logo depois, na fila.
    mudar({ progresso: null }); avisarConclusao(reg.client_id)
    const avancou = (d as { resposta?: { avancou?: boolean } | null }).resposta?.avancou === true
    if (reg.aviso && (!reg.aviso.soSeAvancou || avancou)) {
      await avisarTelegram(deps, reg.client_id, reg.aviso, d.texto_offline ?? null, reg.data_hora_acao)
    }
    return 'aplicado'
  }
  // Conflito (o servidor guardou no livro e avisou a supervisão): o aparelho para de reenviar.
  await atualizarRegistro(reg.client_id, {
    estado: 'conflito', resposta: (resp.data ?? null) as Record<string, unknown> | null,
    ultimo_erro: d.motivo ?? null, enviado_em: new Date().toISOString(),
  })
  await apagarFotosSubidas(reg.client_id)
  mudar({ progresso: null }); avisarConclusao(reg.client_id)
  return 'conflito'
}

/**
 * Telegram do registro aplicado: uma única vez (reserva campo:<client_id> no banco, padrão da
 * 208). Registro feito sem conexão leva as duas horas ("Registrado às HH:MM sem conexão,
 * enviado às HH:MM (Brasília)").
 */
export async function avisarTelegram(deps: DependenciasEnvio, clientId: string, aviso: AvisoPosEnvio,
                                     textoOffline: string | null, dataHoraAcao: string): Promise<boolean> {
  try {
    const reserva = await deps.supabase.rpc('reservar_aviso_campo', { p_client_id: clientId })
    if (reserva.error || reserva.data !== true) return false
    const corpo: Record<string, unknown> = { ...aviso.corpo }
    if (textoOffline) {
      if (!corpo.data_hora) corpo.data_hora = horaBrasilia(dataHoraAcao)
      const desc = typeof corpo.descricao === 'string' && corpo.descricao.trim() ? `${corpo.descricao.trim()}\n` : ''
      corpo.descricao = `${desc}${textoOffline}`
    }
    if (aviso.fotoCaminho) {
      const s = await deps.supabase.storage.from('fotos').createSignedUrl(aviso.fotoCaminho, 3600)
      if (s.data?.signedUrl) corpo.foto_url = s.data.signedUrl
    }
    const f = deps.fetch ?? globalThis.fetch
    await f('/api/telegram', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpo) })
    return true
  } catch {
    return false
  }
}

/** DD/MM/AAAA HH:MM no horário de Brasília. */
export function horaBrasilia(iso: string): string {
  return new Date(iso).toLocaleString('pt-BR', {
    timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
  }).replace(',', '')
}

// ── Gatilhos automáticos ────────────────────────────────────────────────────────────
let depsAtivas: DependenciasEnvio | null = null

/** Dispara uma rodada agora (depois de cada registro, ou pelo botão "Enviar agora"). */
export function dispararEnvio(ignorarEspera = true): Promise<ResumoEnvio> | null {
  if (!depsAtivas) return null
  return enviarFila(depsAtivas, { ignorarEspera }).catch(() => ({ aplicados: [], conflitos: [], recusados: [], parouPor: 'temporario' as const }))
}

/**
 * Liga os gatilhos para o usuário logado e devolve a função que desliga. Com a fila vazia,
 * nenhum pedido sai para o servidor (só a leitura local da contagem).
 */
export function iniciarEnvioAutomatico(deps: DependenciasEnvio, intervaloMs = 30_000): () => void {
  depsAtivas = deps
  const online = deps.online ?? (() => (typeof navigator === 'undefined' ? true : navigator.onLine !== false))
  mudar({ authUserId: deps.authUserId, online: online(), precisaLogin: false })
  void atualizarContagem(deps.authUserId)
  const aoFicarOnline = () => { mudar({ online: true }); void dispararEnvio(true) }
  const aoFicarOffline = () => { mudar({ online: false }) }
  const aoVoltar = () => { if (typeof document !== 'undefined' && document.visibilityState === 'visible') void dispararEnvio(false) }
  const w = typeof window !== 'undefined' ? window : null
  w?.addEventListener('online', aoFicarOnline)
  w?.addEventListener('offline', aoFicarOffline)
  if (typeof document !== 'undefined') document.addEventListener('visibilitychange', aoVoltar)
  const relogio = setInterval(() => { void dispararEnvio(false) }, intervaloMs)
  void dispararEnvio(true)
  return () => {
    w?.removeEventListener('online', aoFicarOnline)
    w?.removeEventListener('offline', aoFicarOffline)
    if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', aoVoltar)
    clearInterval(relogio)
    if (depsAtivas === deps) depsAtivas = null
  }
}
