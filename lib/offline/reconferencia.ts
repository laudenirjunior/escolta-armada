/**
 * Reconferência da etapa logo antes de gravar (Campo e detalhe), com o envelope ligado ou não.
 *
 * Teste real de 12/11/2026 (operador de teste, DevTools Offline): navigator.onLine continuou
 * true com o service worker ativo, a tela fez o GET de status, o SW não alcançou a rede e
 * devolveu a CÓPIA guardada daquele mesmo GET (lida na etapa anterior, com o status antigo).
 * A tela leu "status diferente", a fila estava vazia (a etapa anterior já tinha chegado ao
 * servidor) e abortou com "A etapa já foi avançada em outra tela", sem guardar nada.
 *
 * Regra daqui: "outra tela" só com leitura FRESCA do servidor mostrando outra etapa, que a
 * fila deste aparelho não explica. Sem rede, leitura que falhou, 504 SEM_CONEXAO, cópia do
 * SW ou escolta não lida: com o envelope, a etapa é guardada e o servidor confere no envio
 * (status_esperado; conflito, nunca descarte).
 */
import { servidorAtrasDoAparelho, type OpcoesSobreposicao } from './pendentes.ts'
import type { RegistroFila } from './fila.ts'

/**
 * Cabeçalho do GET de reconferência: o service worker manda direto para a rede, nunca guarda e
 * nunca responde com a cópia (sem rede: 504 SEM_CONEXAO).
 */
export const CABECALHO_SEM_CACHE = 'x-escolta-sem-cache'

export type LeituraStatus =
  /** Não houve leitura: o aparelho já sabia que estava sem rede. */
  | { tipo: 'pulada' }
  /** A leitura falhou; `rede` quando foi falta de conexão (inclusive o 504 SEM_CONEXAO do SW). */
  | { tipo: 'falhou'; rede: boolean; mensagem?: string | null }
  /**
   * A leitura voltou. `fresca` quando veio do servidor (pedida com CABECALHO_SEM_CACHE); cópia
   * do SW não é prova de que o servidor está em outra etapa.
   */
  | { tipo: 'lida'; status: string | null; fresca: boolean }

export type MotivoBloqueio = 'outra_tela' | 'anterior_enviando' | 'erro'

export type DecisaoAvanco =
  /**
   * Segue para a gravação. `semConexao`: a rede faltou de fato (a etapa vai para a fila sem
   * esperar resposta e o ponto sai com criado_offline).
   */
  | { acao: 'gravar'; semConexao: boolean }
  | { acao: 'bloquear'; motivo: MotivoBloqueio; mensagem: string | null }

export interface EntradaDecisao {
  /** Chave offline_ligado (envelope): a fila guarda e o servidor confere no envio. */
  envelope: boolean
  leitura: LeituraStatus
  /** Etapa mostrada na tela (pode ser a otimista, com a anterior ainda na fila). */
  statusTela: string
  escoltaId: string
  /** Registros deste aparelho (pendentes e em envio contam). */
  pendentes: RegistroFila[]
  opcoes?: OpcoesSobreposicao
}

export const MENSAGEM_SEM_CONFERENCIA =
  'Não foi possível conferir a etapa atual desta escolta. Confira a conexão e tente de novo. Nada foi gravado desta vez.'

export function decidirAvanco(e: EntradaDecisao): DecisaoAvanco {
  const { envelope, leitura } = e
  if (leitura.tipo === 'pulada') return { acao: 'gravar', semConexao: true }
  if (leitura.tipo === 'falhou') {
    if (envelope) return { acao: 'gravar', semConexao: leitura.rede }
    return { acao: 'bloquear', motivo: 'erro', mensagem: leitura.mensagem || MENSAGEM_SEM_CONFERENCIA }
  }
  if (leitura.status === e.statusTela) return { acao: 'gravar', semConexao: false }
  // Escolta não lida ou cópia antiga: não há prova de outra tela.
  if (leitura.status == null || !leitura.fresca) {
    return envelope ? { acao: 'gravar', semConexao: false } : { acao: 'bloquear', motivo: 'erro', mensagem: MENSAGEM_SEM_CONFERENCIA }
  }
  // Leitura fresca e diferente: a etapa anterior pode estar ainda na fila deste aparelho.
  if (servidorAtrasDoAparelho(e.escoltaId, leitura.status, e.statusTela, e.pendentes, e.opcoes)) {
    return envelope ? { acao: 'gravar', semConexao: false } : { acao: 'bloquear', motivo: 'anterior_enviando', mensagem: null }
  }
  return { acao: 'bloquear', motivo: 'outra_tela', mensagem: null }
}

/** Resultado do GET de reconferência (supabase-js) como LeituraStatus. */
export function leituraDaResposta(
  r: { data: { status?: string | null } | null; error: { message?: string; code?: string } | null },
  ehErroDeRede: (erro: { message?: string; code?: string }) => boolean,
): LeituraStatus {
  if (r.error) return { tipo: 'falhou', rede: ehErroDeRede(r.error), mensagem: r.error.message ?? null }
  return { tipo: 'lida', status: r.data?.status ?? null, fresca: true }
}
