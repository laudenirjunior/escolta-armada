/**
 * Apoio das telas de campo à onda L (Lote 2026-10; docs/14, seções 16.3.3, 16.3.4 e 16.3.10).
 *
 * As telas (Campo, Painel Guiado e detalhe) continuam montando as próprias linhas, como
 * hoje (S11); aqui ficam só as peças repetidas: o contexto do envelope, a leitura da chave
 * offline_ligado, o texto de cada resultado, a conferência de espaço na captura (S12) e as
 * fotos pendentes vistas a partir do blob local.
 */
import { createClient } from '@/lib/supabase/client'
import { assinarEstadoEnvio, dispararEnvio, lerConfigOffline, type ClienteOffline, type ConfigOffline, type ProgressoEnvio } from './envio.ts'
import { ErroEspacoAparelho, filaDisponivel, fotosDoRegistro, type RegistroFila } from './fila.ts'
import { MENSAGEM_GUARDADO, registrarCampo, type ContextoRegistro, type EntradaRegistroCampo, type ResultadoRegistroCampo } from './registro-campo.ts'

export { ErroEspacoAparelho, MENSAGEM_GUARDADO }

/** Sem rede segundo o aparelho (as leituras e conferências opcionais são puladas). */
export function aparelhoSemRede(): boolean {
  return typeof navigator !== 'undefined' && navigator.onLine === false
}

/**
 * Lê a chave offline_ligado. Desligada (ou "atualização em andamento", sem a 219), a tela
 * grava direto, como antes da onda L.
 */
export async function envelopeLigado(): Promise<ConfigOffline & { usar: boolean }> {
  if (!filaDisponivel()) return { offlineLigado: false, telefoneCentral: null, usar: false }
  const sb = createClient() as unknown as ClienteOffline
  const c = await lerConfigOffline(sb)
  return { ...c, usar: c.offlineLigado !== false }
}

/**
 * Guarda e envia um registro de campo pelo envelope (registrarCampo) e dispara o envio do
 * restante da fila. Lança ErroEspacoAparelho se o aparelho estiver sem espaço.
 */
export async function gravarPeloEnvelope(
  ids: { authUserId: string | null; usuarioId: string | null },
  entrada: EntradaRegistroCampo,
  aoAndamento?: (texto: string) => void,
  /** Onda O (revisão cruzada 1): sem esperar a confirmação (a etapa anterior ficou no aparelho). */
  semEspera = false,
): Promise<ResultadoRegistroCampo> {
  if (!ids.authUserId) throw new Error('Sessão sem usuário. Entre de novo antes de registrar.')
  const ctx: ContextoRegistro = {
    supabase: createClient() as unknown as ClienteOffline,
    authUserId: ids.authUserId,
    usuarioId: ids.usuarioId,
    // Onda O (A1): com sinal, a tela espera a confirmação por até 15 s; passou disso, o registro
    // já está guardado no aparelho e a tela é liberada enquanto o envio continua.
    esperarMs: semEspera ? 0 : ESPERA_CONFIRMACAO_MS,
    aoProgredir: aoAndamento ? (p) => aoAndamento(textoAndamento(p)) : undefined,
  }
  aoAndamento?.('Guardando no aparelho')
  const sair = aoAndamento ? assinarEstadoEnvio((e) => { if (e.progresso) aoAndamento(textoAndamento(e.progresso)) }) : null
  try {
    const r = await registrarCampo(ctx, entrada)
    void dispararEnvio()
    return r
  } finally {
    sair?.()
  }
}

/** Onda O (A1): quanto a tela espera a confirmação do servidor antes de liberar como "guardado". */
export const ESPERA_CONFIRMACAO_MS = 15_000

/** Onda O (A1): texto de andamento ("Enviando foto 3 de 7", "Gravando no sistema"). */
export function textoAndamento(p: Pick<ProgressoEnvio, 'fase' | 'fotosFeitas' | 'fotosTotal'>): string {
  if (p.fase === 'fotos' && p.fotosTotal > 0 && p.fotosFeitas < p.fotosTotal) {
    return `Enviando foto ${Math.min(p.fotosFeitas + 1, p.fotosTotal)} de ${p.fotosTotal}`
  }
  return 'Gravando no sistema'
}

const MOTIVOS: Record<string, string> = {
  versao: 'a escolta foi alterada pela gestão enquanto o registro estava guardado',
  status_final: 'a escolta já estava finalizada ou cancelada',
  status: 'a etapa da escolta já era outra',
  viatura_removida: 'a viatura saiu da escolta',
  ponto_repetido: 'esta viatura já tinha registrado esta etapa',
  sem_acesso: 'você não faz mais parte desta escolta',
  recusado: 'o sistema recusou o registro',
}

/** Texto do conflito para o operador (o servidor guardou o registro inteiro e avisou a supervisão). */
export function textoConflito(motivo: string | null): string {
  const m = MOTIVOS[motivo ?? ''] ?? 'a escolta mudou no servidor'
  return `O registro não foi aceito: ${m}. Nada se perdeu: ele ficou guardado e a supervisão foi avisada.`
}

/** Texto do registro recusado (sem vínculo com a escolta ou formato inválido): não é reenviado. */
export function textoRecusado(erro: string): string {
  return erro === 'SEM_VINCULO'
    ? 'Registro recusado: você não tem vínculo com esta escolta. Ele fica em "Registros recusados" no Painel. Avise a central.'
    : `Registro recusado pelo sistema (${erro}). Ele fica em "Registros recusados" no Painel. Avise a central.`
}

/** Erro da gravação para a tela (espaço do aparelho com o aviso próprio). */
export function textoErroGravacao(err: unknown, padrao: string): string {
  if (err instanceof ErroEspacoAparelho) return err.message
  return err instanceof Error && err.message ? err.message : padrao
}

/**
 * S12: a captura é bloqueada com aviso se o espaço do aparelho acabar. Confere pela estimativa
 * do navegador (folga de duas vezes o tamanho da foto). Sem a estimativa, não bloqueia.
 */
export async function conferirEspacoParaFoto(bytes: number): Promise<void> {
  try {
    const st = typeof navigator !== 'undefined' ? navigator.storage : undefined
    if (!st?.estimate) return
    const e = await st.estimate()
    if (typeof e.quota === 'number' && typeof e.usage === 'number' && e.quota - e.usage < bytes * 2) {
      throw new ErroEspacoAparelho()
    }
  } catch (err) {
    if (err instanceof ErroEspacoAparelho) throw err
  }
}

/** Hora da captura de um arquivo da câmera (o File nasce na captura); fora do razoável, agora. */
export function horaDaCaptura(file: File): string {
  const t = file.lastModified
  const agora = Date.now()
  return Number.isFinite(t) && t > agora - 24 * 3600_000 && t <= agora + 60_000 ? new Date(t).toISOString() : new Date(agora).toISOString()
}

/** Imagem no lugar da foto já enviada que não pode ser assinada sem rede (16.3.4). */
export const FOTO_SEM_CONEXAO = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200">' +
  '<rect width="320" height="200" fill="#EEF1F4"/><text x="160" y="96" font-family="sans-serif" font-size="15" ' +
  'font-weight="700" fill="#53648A" text-anchor="middle">Foto indisponível</text><text x="160" y="120" ' +
  'font-family="sans-serif" font-size="15" font-weight="700" fill="#53648A" text-anchor="middle">sem conexão</text></svg>')

/**
 * Fotos dos registros pendentes (caminho -> URL do blob local), para a tela mostrar o que
 * ainda não subiu. As URLs antigas são revogadas pela tela quando recarrega.
 */
export async function urlsDosPendentes(pendentes: RegistroFila[]): Promise<Record<string, string>> {
  const mapa: Record<string, string> = {}
  if (typeof URL === 'undefined' || !URL.createObjectURL) return mapa
  for (const r of pendentes) {
    try {
      for (const f of await fotosDoRegistro(r.client_id)) mapa[f.caminho] = URL.createObjectURL(f.blob)
    } catch { /* fila ilegível: fica sem a miniatura */ }
  }
  return mapa
}

/** Linhas de fotos dos pendentes (id -> caminho), para casar com os foto_ids dos pontos pendentes. */
export function fotosDosPendentes(pendentes: RegistroFila[]): Record<string, string> {
  const mapa: Record<string, string> = {}
  for (const r of pendentes) {
    const fotos = (r.payload as { linhas?: { fotos?: Array<{ id?: string; caminho_arquivo?: string }> } }).linhas?.fotos ?? []
    for (const f of fotos) if (f.id && f.caminho_arquivo) mapa[f.id] = f.caminho_arquivo
  }
  return mapa
}

/** Erro de leitura que é falta de rede (a tela usa a cópia do aparelho, não esvazia). */
export function erroDeRede(erro: { message?: string; code?: string } | null | undefined): boolean {
  if (!erro) return false
  // Resposta do service worker sem rede e sem cópia (504 imediato, sem novas tentativas).
  if (erro.code === 'SEM_CONEXAO') return true
  if (aparelhoSemRede()) return true
  const m = String(erro.message ?? '')
  return !erro.code && /failed to fetch|fetch failed|networkerror|network request failed|load failed|err_internet|typeerror/i.test(m)
}
