/**
 * Quem pode executar as acoes OPERACIONAIS de uma escolta.
 *
 * Decisao de Pecanha em 2026-09-29: o criterio principal e o vinculo com a escolta,
 * nao o perfil. Quem esta no efetivo registra pre-inicio, fotos, KM, check-in,
 * parada, chegadas, ocorrencia, emergencia e finalizacao, seja operador, supervisor
 * ou qualquer outro perfil. A gestao continua podendo agir em qualquer escolta, como
 * ja podia, para cobrir a equipe que nao consegue registrar.
 *
 * As acoes ADMINISTRATIVAS (criar, editar, cancelar, reagendar, alterar a
 * periodicidade do check-in) continuam por perfil, em lib/permissions.ts.
 *
 * O vinculo percorre escolta_efetivo -> vigilantes.usuario_id, o mesmo caminho que a
 * RLS usa em sou_do_efetivo(). Quem garante a regra e o banco; esta funcao serve
 * para a tela nao oferecer um botao que o banco vai recusar.
 */

import { PERFIS_GESTAO, temPermissao } from './permissions'

export function ehGestao(perfil: string | null | undefined): boolean {
  return temPermissao(perfil, PERFIS_GESTAO)
}

export function podeOperarEscolta(perfil: string | null | undefined, vinculado: boolean): boolean {
  return vinculado || ehGestao(perfil)
}

export interface VinculoEscolta {
  escolta_id: string
  escolta_veiculo_id: string | null
  papel_na_escolta: string | null
}

/**
 * Viatura que o registro sugere: a do proprio usuario naquela escolta.
 *
 * Decisao de 2026-09-29: com duas ou mais viaturas, qualquer participante registra
 * por qualquer viatura da mesma escolta. A sugestao e so o ponto de partida do
 * seletor; quem nao esta numa viatura escolhe manualmente.
 */
export function viaturaSugerida(vinculos: VinculoEscolta[], escoltaId: string | null | undefined): string | null {
  if (!escoltaId) return null
  return vinculos.find((v) => v.escolta_id === escoltaId)?.escolta_veiculo_id ?? null
}
