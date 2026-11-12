/**
 * Concorrência na mesma escolta (pedido de Peçanha em 2026-11-12). Gestão, central, supervisor
 * e operador em campo mexem na mesma escolta ao mesmo tempo; aqui fica a lógica pura que as
 * telas usam para:
 * (a) reconhecer a recusa por conflito (etapa já avançada, prévia desatualizada, versão da
 *     gestão diferente) e montar a mensagem com quem alterou, o quê e quando (Brasília);
 * (c) decidir, num evento do Realtime, se a página relê em silêncio ou avisa (formulário ou
 *     janela de ação aberta) e agrupar os eventos em rajada;
 * (d) agrupar a presença (Realtime Presence) por usuário, sem o próprio, em ordem.
 *
 * A última alteração vem da RPC ultima_alteracao_escolta (migration 223). Sem ela (antes de
 * aplicar a 223), a leitura cai na última linha do histórico de status, e sem nada disso na
 * mensagem genérica: a tela nunca fica sem texto.
 *
 * Testes: node --test tests/concorrencia.test.ts
 */
import { SEQUENCIA_STATUS, rotuloStatus } from './fluxo-escolta.ts'
import { ehFuncaoAusente } from './gestao.ts'

export const FUSO_BRASILIA = 'America/Sao_Paulo'

// ── (a) Reconhecer o conflito ───────────────────────────────────────────────────────

/**
 * - 'etapa': a transição pedida já não vale (ERRO_SEM_TRANSICAO da registrar_etapa_escolta,
 *   ou a reconferência da tela que viu outra etapa no servidor);
 * - 'previa': a confirmação da gestão foi recusada porque a escolta mudou desde a prévia
 *   (voltar, zerar, lançamento retroativo);
 * - 'estado': a escolta já está no estado que a ação queria (cancelada, arquivada, excluída,
 *   fora do mural).
 */
export type TipoConflito = 'etapa' | 'previa' | 'estado'

const PADROES_CONFLITO: Array<[RegExp, TipoConflito]> = [
  [/^ERRO_SEM_TRANSICAO$/, 'etapa'],
  [/avançada em outra tela|mudou de status em outro dispositivo|status da escolta mudou em outro dispositivo/i, 'etapa'],
  [/mudou desde a prévia|mudaram desde a conferência/i, 'previa'],
  [/esta escolta já está (cancelada|arquivada|excluída)|não está mais disponível: ela já saiu do mural|já tem equipe designada/i, 'estado'],
]

/** Tipo do conflito pela mensagem do banco ou da tela; nulo quando não é conflito. */
export function classificarConflito(mensagem: string | null | undefined): TipoConflito | null {
  const m = String(mensagem ?? '').trim()
  if (!m) return null
  for (const [re, tipo] of PADROES_CONFLITO) if (re.test(m)) return tipo
  return null
}

// ── (a) A última alteração ──────────────────────────────────────────────────────────

export interface UltimaAlteracao {
  quemId: string | null
  quemNome: string | null
  /** Nome de exibição do perfil (Gestor, Central, Operador...). */
  perfil: string | null
  perfilCodigo: string | null
  /** A última alteração foi do próprio usuário (outra aba ou outro aparelho). */
  eu: boolean
  oQue: string | null
  quando: string | null
  status: string | null
  versaoGestao: number | null
}

const texto = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v.trim() : null)

/** jsonb da ultima_alteracao_escolta para o tipo da tela; nulo se não veio nada útil. */
export function lerUltimaAlteracao(raw: unknown): UltimaAlteracao | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const r = raw as Record<string, unknown>
  const quando = texto(r.quando)
  const alt: UltimaAlteracao = {
    quemId: texto(r.quem_id),
    quemNome: texto(r.quem_nome),
    perfil: texto(r.perfil),
    perfilCodigo: texto(r.perfil_codigo),
    eu: r.eu === true,
    oQue: texto(r.o_que),
    quando: quando && !Number.isNaN(new Date(quando).getTime()) ? quando : null,
    status: texto(r.status),
    versaoGestao: typeof r.versao_gestao === 'number' ? r.versao_gestao : null,
  }
  return alt.oQue || alt.quemNome || alt.quando ? alt : null
}

/**
 * Texto de uma mudança de status (o mesmo de lote_interno.texto_mudanca_status, migration
 * 223), para a leitura direta do histórico antes de a 223 ser aplicada.
 */
export function textoMudancaStatus(de: string | null | undefined, para: string, observacao?: string | null, retroativo = false): string {
  const obs = observacao ?? ''
  if (para === 'cancelada') return 'escolta cancelada'
  if (obs.startsWith('Zerada pela gestão:')) return 'escolta zerada para Agendada'
  if (obs.startsWith('Reset:')) return `etapa voltada para ${rotuloStatus(para)}`
  if (obs.startsWith('Reagendamento')) return 'escolta reagendada'
  const i = (s: string | null | undefined) => (s ? SEQUENCIA_STATUS.indexOf(s) + 1 : 0)
  if (i(para) > i(de)) return `etapa avançada para ${rotuloStatus(para)}${retroativo ? ' (lançamento retroativo)' : ''}`
  return `status alterado de ${rotuloStatus(de ?? '')} para ${rotuloStatus(para)}`
}

/** Linha do histórico lida direto (com o autor embutido, quando a RLS deixa ver). */
export interface LinhaHistoricoConflito {
  status_anterior: string | null
  status_novo: string
  data_hora: string
  observacao?: string | null
  alterado_por?: string | null
  autor?: { nome_completo?: string | null; perfil?: { nome_exibicao?: string | null; codigo?: string | null } | null } | null
}

export function alteracaoDoHistorico(h: LinhaHistoricoConflito | null | undefined, meuUsuarioId?: string | null): UltimaAlteracao | null {
  if (!h?.status_novo) return null
  return {
    quemId: h.alterado_por ?? null,
    quemNome: texto(h.autor?.nome_completo),
    perfil: texto(h.autor?.perfil?.nome_exibicao),
    perfilCodigo: texto(h.autor?.perfil?.codigo),
    eu: !!meuUsuarioId && h.alterado_por === meuUsuarioId,
    oQue: textoMudancaStatus(h.status_anterior, h.status_novo, h.observacao),
    quando: texto(h.data_hora),
    status: h.status_novo,
    versaoGestao: null,
  }
}

/** Partes de data e hora de Brasília (sem depender do fuso do aparelho). */
function partesBrasilia(d: Date): { dia: string; mes: string; ano: string; hora: string; minuto: string } {
  const partes = new Intl.DateTimeFormat('en-CA', {
    timeZone: FUSO_BRASILIA, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).formatToParts(d)
  const v = (t: string) => partes.find(p => p.type === t)?.value ?? ''
  return { dia: v('day'), mes: v('month'), ano: v('year'), hora: v('hour'), minuto: v('minute') }
}

/**
 * "às 14h32" no mesmo dia (Brasília) de `agora`; "em 11/11 às 14h32" em outro dia do mesmo
 * ano; "em 11/11/2025 às 14h32" em outro ano. Vazio sem horário válido.
 */
export function quandoBrasilia(iso: string | null | undefined, agora: Date = new Date()): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const p = partesBrasilia(d)
  const h = `às ${p.hora}h${p.minuto}`
  const a = partesBrasilia(agora)
  if (p.ano === a.ano && p.mes === a.mes && p.dia === a.dia) return h
  return p.ano === a.ano ? `em ${p.dia}/${p.mes} ${h}` : `em ${p.dia}/${p.mes}/${p.ano} ${h}`
}

/** "Fulano (Gestor)", "você, em outra tela ou aparelho," ou "outra pessoa". */
function quemAlterou(alt: UltimaAlteracao): string {
  if (alt.eu) return 'você, em outra tela ou aparelho,'
  if (!alt.quemNome) return 'outra pessoa'
  return alt.perfil ? `${alt.quemNome} (${alt.perfil})` : alt.quemNome
}

/**
 * "alterada por Fulano (Gestor) às 14h32: etapa avançada para Na Origem". Nulo sem a
 * informação (a tela usa o texto genérico).
 */
export function textoUltimaAlteracao(alt: UltimaAlteracao | null | undefined, agora: Date = new Date()): string | null {
  if (!alt || (!alt.oQue && !alt.quemNome)) return null
  const quando = quandoBrasilia(alt.quando, agora)
  return `alterada por ${quemAlterou(alt)}${quando ? ` ${quando}` : ''}${alt.oQue ? `: ${alt.oQue}` : ''}`.replace(/,(:|$)/, '$1')
}

export const FECHO_NADA_GRAVADO = 'Nenhum registro seu foi gravado.'
export const FECHO_TELA_ATUALIZADA = 'A tela foi atualizada; confira e tente de novo.'
export const MENSAGEM_CONFLITO_GENERICA =
  'Esta escolta foi alterada por outra pessoa ou em outra tela antes da sua ação.'

/**
 * Mensagem do conflito: quem, o quê e quando, e o que aconteceu com a ação do usuário.
 * `nadaGravado` (padrão: o texto de sempre) e `fecho` podem ser trocados pela tela que sabe
 * mais (por exemplo, a prévia da gestão que foi recarregada). Passar null omite a frase.
 */
export function mensagemConflito(
  alt: UltimaAlteracao | null | undefined,
  opcoes: { nadaGravado?: string | null; fecho?: string | null; agora?: Date } = {},
): string {
  const ultima = textoUltimaAlteracao(alt, opcoes.agora)
  const inicio = ultima ? `Esta escolta foi ${ultima}.` : MENSAGEM_CONFLITO_GENERICA
  const nada = opcoes.nadaGravado === undefined ? FECHO_NADA_GRAVADO : opcoes.nadaGravado
  const fecho = opcoes.fecho === undefined ? FECHO_TELA_ATUALIZADA : opcoes.fecho
  return [inicio, nada, fecho].filter(Boolean).join(' ')
}

/**
 * ERRO_SEM_TRANSICAO também sai de regra do banco sem ninguém ter mexido na escolta (por
 * exemplo, transição que a máquina de estados não aceita). Só é conflito de concorrência se o
 * status no servidor já não é o que a tela tinha. Sem a leitura, na dúvida, é conflito.
 */
export function statusMudouNoServidor(alt: UltimaAlteracao | null | undefined, statusDaTela: string | null | undefined): boolean {
  if (!alt?.status || !statusDaTela) return true
  return alt.status !== statusDaTela
}

/** Cliente mínimo para a leitura (o createClient da tela, por cast, como em lib/offline). */
export interface ClienteConcorrencia {
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>
  from: (tabela: string) => {
    select: (colunas: string) => {
      eq: (coluna: string, valor: string) => {
        order: (coluna: string, opcoes: { ascending: boolean }) => {
          limit: (n: number) => PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>
        }
      }
    }
  }
}

export const SELECT_HISTORICO_CONFLITO =
  'status_anterior, status_novo, data_hora, observacao, alterado_por, autor:usuarios!alterado_por(nome_completo, perfil:dom_perfis(nome_exibicao, codigo))'

/**
 * Última alteração da escolta: pela RPC da 223; sem ela, pela última linha do histórico (o
 * nome do autor só aparece se a RLS de usuarios deixar ver). Nunca lança: nulo no pior caso.
 */
export async function buscarUltimaAlteracao(
  sb: ClienteConcorrencia, escoltaId: string, meuUsuarioId?: string | null,
): Promise<UltimaAlteracao | null> {
  try {
    const { data, error } = await sb.rpc('ultima_alteracao_escolta', { p_escolta_id: escoltaId })
    if (!error) return lerUltimaAlteracao(data)
    if (!ehFuncaoAusente(error)) return null
  } catch {
    return null
  }
  try {
    const { data, error } = await sb.from('escolta_status_historico').select(SELECT_HISTORICO_CONFLITO)
      .eq('escolta_id', escoltaId).order('data_hora', { ascending: false }).limit(1)
    if (error || !Array.isArray(data)) return null
    return alteracaoDoHistorico(data[0] as LinhaHistoricoConflito | undefined, meuUsuarioId)
  } catch {
    return null
  }
}

// ── (c) Tempo real na página de detalhe ─────────────────────────────────────────────

/**
 * O que fazer com uma alteração que chegou pelo Realtime:
 * - 'ignorar': esta aba está gravando; ela mesma relê ao terminar (ou mostra o conflito);
 * - 'avisar': há janela de ação ou formulário aberto; reler agora mudaria a escolta por baixo
 *   do que o usuário está preenchendo. Mostra "Esta escolta foi atualizada por X" com o botão;
 * - 'recarregar': relê em silêncio.
 */
export type DecisaoAtualizacao = 'ignorar' | 'avisar' | 'recarregar'

export function decidirAtualizacao(e: { gravando: boolean; editando: boolean }): DecisaoAtualizacao {
  if (e.gravando) return 'ignorar'
  if (e.editando) return 'avisar'
  return 'recarregar'
}

/**
 * Aviso depois da releitura silenciosa: só quando quem alterou foi outra pessoa e a
 * alteração é recente (o evento pode ter vindo de uma gravação antiga reprocessada).
 */
export function mostrarAvisoAposReler(alt: UltimaAlteracao | null | undefined, agora: Date = new Date(), janelaMs = 5 * 60_000): boolean {
  if (!alt || alt.eu || !alt.quando) return false
  const t = new Date(alt.quando).getTime()
  return Number.isFinite(t) && agora.getTime() - t <= janelaMs
}

/** "Esta escolta foi atualizada por Fulano (Gestor) às 14h32: etapa avançada para Na Origem." */
export function textoAtualizadaPor(alt: UltimaAlteracao | null | undefined, agora: Date = new Date()): string {
  const t = textoUltimaAlteracao(alt, agora)
  return t ? `Esta escolta foi ${t.replace(/^alterada/, 'atualizada')}.` : 'Esta escolta foi atualizada por outra pessoa.'
}

export interface Relogio {
  setTimeout: (fn: () => void, ms: number) => unknown
  clearTimeout: (h: unknown) => void
  agora: () => number
}

const RELOGIO_PADRAO: Relogio = {
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
  agora: () => Date.now(),
}

/**
 * Agrupa uma rajada de eventos numa chamada só: dispara `esperaMs` depois do último evento,
 * mas nunca espera mais que `maxEsperaMs` desde o primeiro da rajada (um fluxo contínuo de
 * pontos não pode deixar a tela parada).
 */
export function criarAgrupador(fn: () => void, esperaMs: number, maxEsperaMs: number, relogio: Relogio = RELOGIO_PADRAO) {
  let h: unknown = null
  let inicio: number | null = null
  const disparar = () => {
    h = null
    inicio = null
    fn()
  }
  return {
    evento() {
      const agora = relogio.agora()
      if (inicio === null) inicio = agora
      if (h !== null) relogio.clearTimeout(h)
      const resta = Math.max(0, Math.min(esperaMs, inicio + maxEsperaMs - agora))
      h = relogio.setTimeout(disparar, resta)
    },
    cancelar() {
      if (h !== null) relogio.clearTimeout(h)
      h = null
      inicio = null
    },
    pendente: () => h !== null,
  }
}

// ── (d) Presença ────────────────────────────────────────────────────────────────────

/** O que cada aba publica no canal de presença da escolta. */
export interface MetaPresenca {
  usuario_id: string
  nome: string
  perfil: string | null
  /** Janela de ação aberta (avançar etapa, cancelar, voltar etapa...). */
  editando?: boolean
  /** ISO de quando a aba entrou. */
  desde?: string
  aba?: string
}

export interface PessoaPresente {
  usuarioId: string
  nome: string
  perfil: string | null
  iniciais: string
  editando: boolean
  desde: string | null
  abas: number
}

/** Iniciais do nome: primeira e última palavra ("Maria da Silva" vira "MS"). */
export function iniciais(nome: string | null | undefined): string {
  const partes = String(nome ?? '').trim().split(/\s+/).filter(p => p && !/^(d[aeo]s?|e)$/i.test(p))
  if (partes.length === 0) return '?'
  const primeira = partes[0][0] ?? ''
  const ultima = partes.length > 1 ? partes[partes.length - 1][0] ?? '' : ''
  return (primeira + ultima).toLocaleUpperCase('pt-BR')
}

/**
 * Estado do Presence (chave -> metas) para a barra: um item por usuário (as abas do mesmo
 * usuário viram uma só), sem o próprio usuário, quem está editando primeiro e depois por nome.
 */
export function agruparPresenca(estado: Record<string, MetaPresenca[] | undefined>, meuUsuarioId: string | null | undefined): PessoaPresente[] {
  const porUsuario = new Map<string, PessoaPresente>()
  for (const metas of Object.values(estado)) {
    for (const m of metas ?? []) {
      if (!m?.usuario_id || m.usuario_id === meuUsuarioId) continue
      const atual = porUsuario.get(m.usuario_id)
      if (!atual) {
        porUsuario.set(m.usuario_id, {
          usuarioId: m.usuario_id,
          nome: m.nome?.trim() || 'Usuário',
          perfil: m.perfil ?? null,
          iniciais: iniciais(m.nome),
          editando: !!m.editando,
          desde: m.desde ?? null,
          abas: 1,
        })
        continue
      }
      atual.abas += 1
      atual.editando = atual.editando || !!m.editando
      if (m.desde && (!atual.desde || m.desde < atual.desde)) atual.desde = m.desde
    }
  }
  return [...porUsuario.values()].sort((a, b) =>
    a.editando !== b.editando ? (a.editando ? -1 : 1) : a.nome.localeCompare(b.nome, 'pt-BR'))
}

/** "Fulano (Gestor)", com "editando" quando for o caso. */
export function rotuloPresenca(p: PessoaPresente): string {
  return `${p.nome}${p.perfil ? ` (${p.perfil})` : ''}${p.editando ? ', editando' : ''}`
}
