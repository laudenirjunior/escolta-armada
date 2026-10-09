/**
 * Cartão padrão da escolta (lote 2026-10, onda K; docs/14, seção 15.2 item 2).
 *
 * Uma consulta só (SELECT_CARTAO) e as mesmas regras de exibição para a lista, o mural,
 * o painel inicial, o Modo Guiado, o mapa e as arquivadas: código, cliente com a cor da
 * paleta, data e hora em Brasília, origem e destino resumidos (bairro e município), quem
 * criou, equipe, status por lib/fluxo-escolta.ts e as etiquetas.
 *
 * Equipe: a RLS de escolta_efetivo só mostra o efetivo à gestão e ao próprio efetivo. Para
 * o operador, "Sem equipe" vem só do servidor (mural_info.tem_equipe), nunca do efetivo que
 * ele mesmo lê (onda G: a escolta de outra dupla pareceria livre).
 */
import { CLASSE_BADGE_STATUS, LABELS_STATUS } from '@/lib/fluxo-escolta'
import { corDoCliente } from '@/lib/paleta-clientes'

/** Colunas do cartão. UF e interestadual são da migration 216 (bloco 1, antes do deploy). */
export const SELECT_CARTAO = `
  id, codigo_escolta, status, data_hora_prevista,
  origem_endereco, destino_endereco, origem_uf, destino_uf, uf_estimada, interestadual,
  escala_fixa, checklist_pendente_no_inicio, reiniciada_em, arquivada_em, criada_por,
  criador:usuarios!criada_por(nome_completo),
  cliente:clientes(id, nome_cliente, cor_destaque),
  conclusao:escolta_conclusoes_antecipadas(id, anulado_em),
  efetivo:escolta_efetivo(papel_na_escolta, vigilante:vigilantes(nome_completo))
`

export interface CartaoEscolta {
  id: string
  codigo_escolta: string | null
  status: string
  data_hora_prevista: string
  origem_endereco: string | null
  destino_endereco: string | null
  origem_uf?: string | null
  destino_uf?: string | null
  uf_estimada?: boolean | null
  interestadual?: boolean | null
  escala_fixa?: boolean | null
  checklist_pendente_no_inicio?: boolean | null
  reiniciada_em?: string | null
  arquivada_em?: string | null
  criada_por?: string | null
  criador?: { nome_completo: string | null } | null
  cliente: { id?: string; nome_cliente: string; cor_destaque: string | null } | null
  conclusao?: { id: string; anulado_em: string | null }[] | null
  efetivo?: { papel_na_escolta: string | null; vigilante: { nome_completo: string | null } | null }[] | null
  /** Cor do cliente vinda do servidor (cores_clientes_das_escoltas) quando a RLS esconde o cliente. */
  cor_cliente_servidor?: string | null
}

export type Etiqueta = { chave: 'interestadual' | 'escala-fixa' | 'pendencias' | 'reiniciada' | 'arquivada'; texto: string; classe: string }

/** Data e hora em Brasília, DD/MM/AAAA HH:MM. */
export function dataHoraBrasilia(iso: string | null | undefined): string {
  if (!iso) return '--/--/---- --:--'
  const d = new Date(iso)
  if (isNaN(d.getTime())) return '--/--/---- --:--'
  const p = new Intl.DateTimeFormat('pt-BR', {
    timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(d)
  const v = (t: string) => p.find(x => x.type === t)?.value ?? ''
  return `${v('day')}/${v('month')}/${v('year')} ${v('hour')}:${v('minute')}`
}

const CEP = /^\d{5}-?\d{3}$/

/**
 * Bairro e município do endereço gravado. O texto da Mapbox vem como "Rua X 100, Bairro,
 * Município - Estado, CEP, Brasil" (com o complemento da Nova no fim, depois de vírgula).
 * O município é a parte com " - " (antes do traço); o bairro, a anterior a ela, se não for
 * a primeira (a rua). Sem esse formato: as duas últimas partes úteis, ou o texto cortado.
 */
export function resumoEndereco(endereco: string | null | undefined): string {
  const txt = (endereco ?? '').trim()
  if (!txt) return 'Sem endereço'
  const partes = txt.split(',').map(s => s.trim()).filter(s => s && !CEP.test(s) && s.toLowerCase() !== 'brasil')
  const iMun = partes.findIndex((s, i) => i > 0 && / - /.test(s))
  if (iMun > 0) {
    const municipio = partes[iMun].split(' - ')[0].trim()
    const bairro = iMun - 1 >= 1 ? partes[iMun - 1] : null
    return bairro ? `${bairro}, ${municipio}` : municipio
  }
  if (partes.length >= 3) return `${partes[partes.length - 2]}, ${partes[partes.length - 1]}`
  const curto = partes.join(', ')
  return curto.length > 48 ? `${curto.slice(0, 47).trim()}…` : curto
}

export function rotuloStatusCartao(status: string): { label: string; classe: string } {
  return { label: LABELS_STATUS[status] ?? status, classe: CLASSE_BADGE_STATUS[status] ?? 'badge-neutral' }
}

export function corCartao(e: Pick<CartaoEscolta, 'cliente' | 'cor_cliente_servidor'>): string {
  return corDoCliente(e.cliente?.cor_destaque ?? e.cor_cliente_servidor)
}

/**
 * Cor do cliente das escoltas cujo cliente a RLS esconde (o operador só lê o cliente das
 * escoltas em que está no efetivo; no mural, as agendadas de outra equipe vêm sem cliente e
 * sairiam todas na mesma cor). A RPC da 216 devolve só a cor, nunca o nome. Sem a RPC (ou com
 * erro) as linhas ficam como estão: a cor padrão.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function completarCoresClientes<T extends CartaoEscolta>(sb: any, linhas: T[]): Promise<T[]> {
  const ids = linhas.filter(l => !l.cliente).map(l => l.id)
  if (ids.length === 0) return linhas
  try {
    const { data, error } = await sb.rpc('cores_clientes_das_escoltas', { p_escolta_ids: ids })
    if (error || !Array.isArray(data)) return linhas
    const cor = new Map<string, string>((data as { escolta_id: string; cor_destaque: string }[]).map(d => [d.escolta_id, d.cor_destaque]))
    return linhas.map(l => (cor.has(l.id) ? { ...l, cor_cliente_servidor: cor.get(l.id) } : l))
  } catch {
    return linhas
  }
}

export const comPendencias = (e: Pick<CartaoEscolta, 'status' | 'conclusao'>) =>
  e.status === 'finalizada' && (e.conclusao ?? []).some(c => !c.anulado_em)

/**
 * Etiquetas do cartão. Interestadual só quando a coluna gerada é verdadeira; quando a UF
 * é estimada pela coordenada (uf_estimada), só a etiqueta, sem nome de UF (15.1 item 5).
 * Arquivada só para o administrador (as outras pessoas nem leem a escolta arquivada).
 */
export function etiquetas(e: CartaoEscolta, perfil: string | null | undefined): Etiqueta[] {
  const r: Etiqueta[] = []
  if (e.interestadual === true) r.push({ chave: 'interestadual', texto: 'Interestadual', classe: 'badge-warning' })
  if (e.escala_fixa) r.push({ chave: 'escala-fixa', texto: 'Escala fixa', classe: 'badge-neutral' })
  if (comPendencias(e)) r.push({ chave: 'pendencias', texto: 'Concluída com pendências', classe: 'badge-warning' })
  if (e.status === 'agendada' && e.reiniciada_em) r.push({ chave: 'reiniciada', texto: 'Reiniciada pela gestão', classe: 'badge-info' })
  if (e.arquivada_em && perfil === 'administrador') r.push({ chave: 'arquivada', texto: 'Arquivada', classe: 'badge-danger' })
  return r
}

/**
 * Texto da equipe. Gestão: quantidade e comandante (do efetivo embutido). Operador: só o
 * que o servidor diz (semEquipe da mural_info); sem essa informação, nada.
 */
export function textoEquipe(e: CartaoEscolta, perfil: string | null | undefined, semEquipe?: boolean | null): string | null {
  if (perfil === 'operador') {
    if (semEquipe === true) return 'Sem equipe'
    if (semEquipe === false) return 'Com equipe'
    return null
  }
  const ef = e.efetivo ?? []
  if (ef.length === 0) return 'Sem equipe'
  const cmt = ef.find(m => m.papel_na_escolta === 'comandante')?.vigilante?.nome_completo
  const qtd = `${ef.length} ${ef.length === 1 ? 'vigilante' : 'vigilantes'}`
  return cmt ? `${qtd}, comandante ${cmt}` : qtd
}

/** Tem equipe, para o filtro da gestão (efetivo embutido). */
export function temEquipeGestao(e: CartaoEscolta): boolean {
  return (e.efetivo ?? []).length > 0
}

/** Escapa texto para o HTML do popup do mapa. */
export function esc(s: string | null | undefined): string {
  return (s ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch] as string))
}
