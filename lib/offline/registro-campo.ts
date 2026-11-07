/**
 * Envelope de transporte dos registros de campo (Lote 2026-10, onda L; decisão S11; docs/14,
 * seções 16.2.4 e 16.3.3).
 *
 * Cada tela continua montando as PRÓPRIAS linhas, exatamente as de hoje (fotos,
 * pontos_controle, checklists, checklist_respostas, ocorrencias, emergencias, o KM de
 * escolta_veiculos), opcionalmente seguidas da etapa (os argumentos da
 * registrar_etapa_escolta) ou da presença na base. Esta biblioteca só guarda no aparelho e
 * envia; o servidor (registrar_campo, migration 219) grava as linhas numa transação, com a
 * RLS e as triggers de quem chama.
 *
 * Sempre guarda primeiro na fila (nada se perde se a página fechar). Com sinal, espera a
 * resposta, como hoje ("enviado": aplicado ou conflito). Sem sinal, devolve "guardado":
 * a tela mostra "Guardado no aparelho. Será enviado quando houver sinal.", nunca "a central
 * foi avisada".
 */
import { pedirEnderecoDepois } from '../geocodificacao.ts'
import {
  caminhoFoto, filaDisponivel, guardarRegistro, guardarFotoAvulsa, lerRecibo, lerRegistro, novoId,
  FOTO_AVULSA, VERSAO_FILA,
  type AvisoPosEnvio, type FotoFila, type GpsAcao, type RegistroFila, type TipoRegistro,
} from './fila.ts'
import { classificarErro, desvioDoRelogio, enviarFila, type ClienteOffline } from './envio.ts'

export const MENSAGEM_GUARDADO = 'Guardado no aparelho. Será enviado quando houver sinal.'

// ── Linhas, como a tela monta hoje (colunas da lista fechada da registrar_campo) ─────
export type Linha = Record<string, unknown> & { id?: string }
export interface LinhasEnvelope {
  fotos?: Linha[]
  checklists?: Linha[]
  checklist_respostas?: Linha[]
  pontos_controle?: Linha[]
  ocorrencias?: Linha[]
  emergencias?: Linha[]
  /** Só escolta_veiculo_id, quilometragem_saida e quilometragem_retorno. */
  km?: Array<{ escolta_veiculo_id: string; quilometragem_saida?: number | null; quilometragem_retorno?: number | null }>
}
/** Argumentos da registrar_etapa_escolta, sem o p_ (a escolta vem do envelope). */
export interface EtapaEnvelope {
  pontos?: Linha[]
  status_atual?: string | null
  status_novo?: string | null
  observacao?: string | null
  latitude?: number | null
  longitude?: number | null
  observacao_fechamento?: string | null
  data_hora_prevista?: string | null
  tipo_ponto_todas?: string | null
}
export interface PresencaEnvelope { latitude: number | null; longitude: number | null; precisao: number | null }

/** Foto preparada na captura: o id já vai nas linhas (foto_id) antes de o registro existir. */
export interface FotoPreparada {
  id: string
  caminho: string
  blob: Blob
  tipoMime: string
  /** Linha de fotos, igual à de hoje (com a hora e o carimbo da captura). */
  linha: Linha
}

export interface DadosFoto {
  blob: Blob
  tipoFotoId: string
  /** Hora da captura (ISO), a mesma que o carimbo escreve. */
  dataHoraCaptura: string
  gps: GpsAcao | null
  carimbado: boolean
  criadoPor: string | null
}

/**
 * Monta a foto com id do aparelho e caminho determinístico (campo/{escolta}/{id}.jpg). O
 * blob precisa ser o já carimbado.
 */
export function prepararFoto(escoltaId: string, dados: DadosFoto): FotoPreparada {
  const id = novoId()
  const caminho = caminhoFoto(escoltaId, id)
  return {
    id, caminho, blob: dados.blob, tipoMime: dados.blob.type || 'image/jpeg',
    linha: {
      id, caminho_arquivo: caminho, tipo_foto_id: dados.tipoFotoId,
      latitude: dados.gps?.lat ?? null, longitude: dados.gps?.lng ?? null, precisao_metros: dados.gps?.precisao ?? null,
      data_hora_captura: dados.dataHoraCaptura, carimbo_aplicado: dados.carimbado,
      enviada_telegram: false, sincronizada: true, criado_por: dados.criadoPor,
    },
  }
}

/** Guarda a foto no aparelho já na captura (16.3.1), antes do registro. */
export async function guardarFotoNaCaptura(authUserId: string, escoltaId: string, f: FotoPreparada): Promise<void> {
  if (!filaDisponivel()) return
  await guardarFotoAvulsa(fotoParaFila(authUserId, escoltaId, FOTO_AVULSA, f))
}

function fotoParaFila(authUserId: string, escoltaId: string, registro: string, f: FotoPreparada): FotoFila {
  return {
    foto_client_id: f.id, registro_client_id: registro, auth_user_id: authUserId, escolta_id: escoltaId,
    caminho: f.caminho, blob: f.blob, bytes: f.blob.size, tipo_mime: f.tipoMime, estado: 'pendente',
    criado_em: new Date().toISOString(),
  }
}

// ── Entrada e resultado ─────────────────────────────────────────────────────────────
export interface EntradaRegistroCampo {
  tipo: TipoRegistro
  escoltaId: string
  escoltaVeiculoId?: string | null
  /** versao_gestao da escolta como a tela leu (snapshot). Sempre mandar. */
  versaoGestao: number | null
  /** Status que a tela viu (o servidor recusa como conflito se mudou). Na etapa, o status_atual. */
  statusEsperado?: string | null
  linhas?: LinhasEnvelope
  etapa?: EtapaEnvelope
  presenca?: PresencaEnvelope
  /** Fotos preparadas (prepararFoto); entram em linhas.fotos e na fila com o blob. */
  fotos?: FotoPreparada[]
  /** Hora da ação (padrão: agora). */
  dataHoraAcao?: string
  gps?: GpsAcao | null
  /** Telegram de hoje, mandado só depois de aplicado e uma vez só. */
  aviso?: AvisoPosEnvio | null
  /** Livre para a tela (não interpretado pelo servidor). */
  meta?: Record<string, unknown>
}

export interface ContextoRegistro {
  supabase: ClienteOffline
  authUserId: string
  usuarioId: string | null
  online?: () => boolean
  /** Quanto esperar pela resposta com sinal antes de dizer "guardado" (padrão 30 s). */
  esperarMs?: number
  fetch?: typeof fetch
}

export type ResultadoRegistroCampo =
  | { modo: 'enviado'; clientId: string; resultado: 'aplicado' | 'conflito'; motivo: string | null; duplicado: boolean;
      resposta: Record<string, unknown> | null; textoOffline: string | null }
  | { modo: 'guardado'; clientId: string; mensagem: string }
  | { modo: 'recusado'; clientId: string; erro: string }

/** Payload do envelope (formato que a registrar_campo valida). */
export function montarPayload(e: EntradaRegistroCampo): Record<string, unknown> {
  const linhas: Record<string, unknown> = {}
  const fotos = [...(e.linhas?.fotos ?? []), ...(e.fotos ?? []).map(f => f.linha)]
  if (fotos.length) linhas.fotos = fotos
  for (const k of ['checklists', 'checklist_respostas', 'pontos_controle', 'ocorrencias', 'emergencias', 'km'] as const) {
    const v = e.linhas?.[k]
    if (v && v.length) linhas[k] = v
  }
  const p: Record<string, unknown> = { escolta_id: e.escoltaId }
  if (e.escoltaVeiculoId) p.escolta_veiculo_id = e.escoltaVeiculoId
  if (e.statusEsperado) p.status_esperado = e.statusEsperado
  if (Object.keys(linhas).length) p.linhas = linhas
  if (e.etapa) p.etapa = semIndefinidos(e.etapa)
  if (e.presenca) p.presenca = e.presenca
  if (e.meta) p.meta = e.meta
  return p
}

function semIndefinidos<T extends object>(o: T): Partial<T> {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) as Partial<T>
}

function prioridade(tipo: TipoRegistro): number { return tipo === 'emergencia' ? 0 : 1 }

/**
 * Guarda o registro e, com sinal, envia (na ordem da fila) e espera a resposta.
 * Lança ErroEspacoAparelho se o espaço acabou (a tela bloqueia a captura com aviso).
 */
export async function registrarCampo(ctx: ContextoRegistro, e: EntradaRegistroCampo): Promise<ResultadoRegistroCampo> {
  const online = ctx.online ?? (() => (typeof navigator === 'undefined' ? true : navigator.onLine !== false))
  const clientId = novoId()
  const payload = montarPayload(e)
  const agora = new Date().toISOString()
  const relogio: Record<string, unknown> = {
    offline: !online(), registrado_em: agora, desvio_ms: desvioDoRelogio(),
    fuso: (() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone } catch { return null } })(),
  }

  // Sem IndexedDB (navegador sem armazenamento): só dá para mandar direto, com sinal.
  if (!filaDisponivel()) {
    // Onda M (revisão adversarial da onda L, achado 4): as fotos sobem ANTES do envelope, como
    // no caminho da fila. Se uma foto falhar, nada é aplicado no banco (o objeto já enviado fica
    // no bucket com caminho determinístico e é reaproveitado se o operador tentar de novo).
    for (const f of e.fotos ?? []) {
      const up = await ctx.supabase.storage.from('fotos').upload(f.caminho, f.blob, { upsert: false, contentType: f.tipoMime })
      if (up.error && !/already exists|duplicate/i.test(up.error.message)) throw new Error(`Falha ao enviar a foto: ${up.error.message}`)
    }
    const r = await ctx.supabase.rpc('registrar_campo', {
      p_client_id: clientId, p_tipo: e.tipo, p_payload: payload, p_versao_gestao: e.versaoGestao,
      p_data_hora_acao: e.dataHoraAcao ?? agora, p_relogio: relogio,
    })
    if (r.error) {
      if (classificarErro(r.error, r.status) === 'recusado') return { modo: 'recusado', clientId, erro: r.error.message }
      throw new Error(`Não foi possível registrar: ${r.error.message}`)
    }
    const d = (r.data ?? {}) as Record<string, unknown>
    // Revisão cruzada (2.2): o caminho sem IndexedDB também pede o endereço depois.
    if (d.resultado === 'aplicado') pedirEnderecoDepois([e.escoltaId], ctx.fetch ?? fetch)
    return { modo: 'enviado', clientId, resultado: d.resultado === 'aplicado' ? 'aplicado' : 'conflito',
             motivo: (d.motivo as string) ?? null, duplicado: !!d.duplicado, resposta: d, textoOffline: (d.texto_offline as string) ?? null }
  }

  const reg: RegistroFila = {
    versao_fila: VERSAO_FILA, client_id: clientId, auth_user_id: ctx.authUserId, usuario_id: ctx.usuarioId,
    escolta_id: e.escoltaId, escolta_veiculo_id: e.escoltaVeiculoId ?? null, tipo: e.tipo, payload,
    versao_gestao: e.versaoGestao, data_hora_acao: e.dataHoraAcao ?? agora, relogio, gps: e.gps ?? null,
    prioridade: prioridade(e.tipo), estado: 'pendente', tentativas: 0, ultimo_erro: null,
    fotos: (e.fotos ?? []).map(f => f.id), criado_em: agora, aviso: e.aviso ?? null,
  }
  await guardarRegistro(reg, (e.fotos ?? []).map(f => fotoParaFila(ctx.authUserId, e.escoltaId, clientId, f)))

  if (!online()) return { modo: 'guardado', clientId, mensagem: MENSAGEM_GUARDADO }

  // Com sinal: envia a fila na ordem (os anteriores primeiro) e espera este.
  const limite = ctx.esperarMs ?? 30_000
  let relogio_: ReturnType<typeof setTimeout> | undefined
  await Promise.race([
    enviarFila({ supabase: ctx.supabase, authUserId: ctx.authUserId, online, fetch: ctx.fetch }, { esperarTrava: true, ignorarEspera: true }).catch(() => null),
    new Promise(resolve => { relogio_ = setTimeout(resolve, limite) }),
  ])
  if (relogio_) clearTimeout(relogio_)
  return resultadoDoRegistro(clientId)
}

/** Situação de um registro guardado (aplicado vira recibo; os demais ficam na fila). */
export async function resultadoDoRegistro(clientId: string): Promise<ResultadoRegistroCampo> {
  const recibo = await lerRecibo(clientId)
  if (recibo) {
    const d = recibo.resposta ?? {}
    return { modo: 'enviado', clientId, resultado: 'aplicado', motivo: null, duplicado: !!d.duplicado,
             resposta: recibo.resposta, textoOffline: recibo.texto_offline }
  }
  const reg = await lerRegistro(clientId)
  if (reg?.estado === 'conflito') {
    const d = reg.resposta ?? {}
    return { modo: 'enviado', clientId, resultado: 'conflito', motivo: (d.motivo as string) ?? reg.ultimo_erro,
             duplicado: !!d.duplicado, resposta: reg.resposta ?? null, textoOffline: null }
  }
  if (reg?.estado === 'recusado') return { modo: 'recusado', clientId, erro: reg.ultimo_erro ?? 'Registro recusado pelo servidor.' }
  return { modo: 'guardado', clientId, mensagem: MENSAGEM_GUARDADO }
}
