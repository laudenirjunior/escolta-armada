/**
 * Qual escolta o Campo mostra (correção após o teste da prévia do PR #10, 2026-11-12).
 *
 * O detalhe abre o Campo com ?escolta=<id>. Antes a tela procurava esse id só nas ativas e,
 * quando a escolta pedida ainda estava agendada, caía na primeira ativa (outra escolta).
 *
 * Regra:
 * - A escolta já aberta (atual) continua aberta enquanto estiver entre as ativas: recarga,
 *   tempo real e troca de modo guiado/completo não mudam a seleção.
 * - Sem escolta aberta, vale o id pedido: se é ativa, abre; se é agendada, vira a
 *   "agendada pedida" (mostrada sozinha, sem o avanço de checkpoint agendada para
 *   pré-início, que pularia o wizard). O pedido de agendada continua guardado até ela
 *   virar ativa ou sumir das listas.
 * - Id pedido que não existe nas listas não quebra: o pedido é descartado e vale o padrão.
 * - Sem id pedido: a primeira ativa, como sempre foi.
 *
 * Testes: node --test tests/campo-selecao.test.ts
 */
export interface ComId { id: string }

export interface SelecaoCampo<T extends ComId> {
  /** Vai para escoltaAtiva (nunca uma agendada). */
  ativa: T | null
  /** Agendada pedida pelo id: mostrada no Campo, com o caminho para o wizard no detalhe. */
  agendadaPedida: T | null
  /** Id a guardar para as próximas recargas (null quando o pedido já foi atendido ou não existe). */
  pedidoPendente: string | null
}

export function selecionarEscoltaCampo<T extends ComId>(entrada: {
  pedida: string | null | undefined
  atual: string | null | undefined
  ativas: T[]
  agendadas: T[]
}): SelecaoCampo<T> {
  const { pedida, atual, ativas, agendadas } = entrada
  const atualAtiva = atual ? ativas.find(e => e.id === atual) ?? null : null
  if (atualAtiva) return { ativa: atualAtiva, agendadaPedida: null, pedidoPendente: null }
  if (pedida) {
    const ativa = ativas.find(e => e.id === pedida)
    if (ativa) return { ativa, agendadaPedida: null, pedidoPendente: null }
    const agendada = agendadas.find(e => e.id === pedida)
    if (agendada) return { ativa: null, agendadaPedida: agendada, pedidoPendente: pedida }
  }
  return { ativa: ativas[0] ?? null, agendadaPedida: null, pedidoPendente: null }
}
