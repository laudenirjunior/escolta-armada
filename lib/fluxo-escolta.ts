/**
 * Fonte unica de verdade do fluxo da escolta.
 *
 * Antes desta versao havia quatro definicoes divergentes da maquina de estados
 * (a tela de detalhe, a tela de campo, utils/constants.ts e a trigger do banco),
 * mais cerca de 25 arrays de status literais espalhados por 9 paginas. A tela
 * oferecia a transicao `na_origem -> em_transito_destino` e o banco recusava.
 *
 * Tudo que precise conhecer status, rotulo, cor, etapa ou tipo de ponto importa
 * daqui. A trigger `validar_transicao_status_escolta` no banco espelha
 * TRANSICOES_VALIDAS e e quem de fato garante a regra.
 */

export const STATUS = {
  RASCUNHO: 'rascunho',
  AGENDADA: 'agendada',
  EM_PRE_INICIO: 'em_pre_inicio',
  EM_ANDAMENTO: 'em_andamento',
  NA_ORIGEM: 'na_origem',
  EM_TRANSITO_DESTINO: 'em_transito_destino',
  NO_DESTINO: 'no_destino',
  EM_TRANSITO_RETORNO: 'em_transito_retorno',
  RETORNANDO: 'retornando',
  NA_BASE: 'na_base',
  FINALIZADA: 'finalizada',
  CANCELADA: 'cancelada',
} as const

export type StatusEscolta = (typeof STATUS)[keyof typeof STATUS]

/** Rotulo curto, usado em badge e em tabela. */
export const LABELS_STATUS: Record<string, string> = {
  [STATUS.RASCUNHO]: 'Rascunho',
  [STATUS.AGENDADA]: 'Agendada',
  [STATUS.EM_PRE_INICIO]: 'Pré-Início',
  [STATUS.EM_ANDAMENTO]: 'Em Andamento',
  [STATUS.NA_ORIGEM]: 'Na Origem',
  [STATUS.EM_TRANSITO_DESTINO]: 'Trânsito p/ Destino',
  [STATUS.NO_DESTINO]: 'No Destino',
  [STATUS.EM_TRANSITO_RETORNO]: 'Trânsito p/ Retorno',
  [STATUS.RETORNANDO]: 'Retornando',
  [STATUS.NA_BASE]: 'Na Base',
  [STATUS.FINALIZADA]: 'Finalizada',
  [STATUS.CANCELADA]: 'Cancelada',
}

/** Classe de badge do design system Navy (ver app/globals.css). */
export const CLASSE_BADGE_STATUS: Record<string, string> = {
  [STATUS.RASCUNHO]: 'badge-neutral',
  [STATUS.AGENDADA]: 'badge-info',
  [STATUS.EM_PRE_INICIO]: 'badge-warning',
  [STATUS.EM_ANDAMENTO]: 'badge-info',
  [STATUS.NA_ORIGEM]: 'badge-info',
  [STATUS.EM_TRANSITO_DESTINO]: 'badge-info',
  [STATUS.NO_DESTINO]: 'badge-success',
  [STATUS.EM_TRANSITO_RETORNO]: 'badge-info',
  [STATUS.RETORNANDO]: 'badge-warning',
  [STATUS.NA_BASE]: 'badge-success',
  [STATUS.FINALIZADA]: 'badge-success',
  [STATUS.CANCELADA]: 'badge-danger',
}

/** Status em que a escolta esta operando. Usado em filtro, mapa e KPI. */
export const STATUS_ATIVOS: string[] = [
  STATUS.AGENDADA,
  STATUS.EM_PRE_INICIO,
  STATUS.EM_ANDAMENTO,
  STATUS.NA_ORIGEM,
  STATUS.EM_TRANSITO_DESTINO,
  STATUS.NO_DESTINO,
  STATUS.EM_TRANSITO_RETORNO,
  STATUS.RETORNANDO,
  STATUS.NA_BASE,
]

export const STATUS_TERMINAIS: string[] = [STATUS.FINALIZADA, STATUS.CANCELADA]

/**
 * Espelha a trigger do banco. O cliente usa para desenhar o botao certo;
 * quem garante a regra e a trigger.
 */
export const TRANSICOES_VALIDAS: Record<string, string[]> = {
  [STATUS.RASCUNHO]: [STATUS.AGENDADA, STATUS.CANCELADA],
  [STATUS.AGENDADA]: [STATUS.EM_PRE_INICIO, STATUS.CANCELADA],
  [STATUS.EM_PRE_INICIO]: [STATUS.EM_ANDAMENTO, STATUS.CANCELADA],
  [STATUS.EM_ANDAMENTO]: [STATUS.NA_ORIGEM, STATUS.CANCELADA],
  [STATUS.NA_ORIGEM]: [STATUS.EM_TRANSITO_DESTINO, STATUS.CANCELADA],
  [STATUS.EM_TRANSITO_DESTINO]: [STATUS.NO_DESTINO, STATUS.CANCELADA],
  [STATUS.NO_DESTINO]: [STATUS.EM_TRANSITO_RETORNO, STATUS.CANCELADA],
  [STATUS.EM_TRANSITO_RETORNO]: [STATUS.RETORNANDO, STATUS.CANCELADA],
  [STATUS.RETORNANDO]: [STATUS.NA_BASE, STATUS.CANCELADA],
  [STATUS.NA_BASE]: [STATUS.FINALIZADA, STATUS.CANCELADA],
  [STATUS.FINALIZADA]: [],
  [STATUS.CANCELADA]: [],
}

/** Proxima etapa e o rotulo do botao que a dispara. */
export const PROXIMO_STATUS: Record<string, { status: string; label: string } | null> = {
  [STATUS.RASCUNHO]: { status: STATUS.AGENDADA, label: 'Agendar Escolta' },
  [STATUS.AGENDADA]: { status: STATUS.EM_PRE_INICIO, label: 'Iniciar Pré-Início' },
  [STATUS.EM_PRE_INICIO]: null, // passa pelo wizard, nao pelo botao generico
  [STATUS.EM_ANDAMENTO]: { status: STATUS.NA_ORIGEM, label: 'Confirmar na Origem' },
  [STATUS.NA_ORIGEM]: { status: STATUS.EM_TRANSITO_DESTINO, label: 'Iniciar Trânsito ao Destino' },
  [STATUS.EM_TRANSITO_DESTINO]: { status: STATUS.NO_DESTINO, label: 'Confirmar no Destino' },
  [STATUS.NO_DESTINO]: { status: STATUS.EM_TRANSITO_RETORNO, label: 'Iniciar Trânsito de Retorno' },
  [STATUS.EM_TRANSITO_RETORNO]: { status: STATUS.RETORNANDO, label: 'Confirmar Retorno' },
  [STATUS.RETORNANDO]: { status: STATUS.NA_BASE, label: 'Confirmar na Base' },
  [STATUS.NA_BASE]: { status: STATUS.FINALIZADA, label: 'Finalizar Escolta' },
  [STATUS.FINALIZADA]: null,
  [STATUS.CANCELADA]: null,
}

/** As 9 etapas da barra de progresso. */
export const JORNADA_ETAPAS: { statuses: string[]; label: string }[] = [
  { statuses: [STATUS.RASCUNHO, STATUS.AGENDADA], label: 'Planejamento' },
  { statuses: [STATUS.EM_PRE_INICIO], label: 'Pré-Início' },
  { statuses: [STATUS.EM_ANDAMENTO], label: 'Em Trânsito' },
  { statuses: [STATUS.NA_ORIGEM], label: 'Na Origem' },
  { statuses: [STATUS.EM_TRANSITO_DESTINO], label: 'Trânsito p/ Destino' },
  { statuses: [STATUS.NO_DESTINO], label: 'No Destino' },
  { statuses: [STATUS.EM_TRANSITO_RETORNO], label: 'Trânsito p/ Retorno' },
  { statuses: [STATUS.RETORNANDO], label: 'Retorno' },
  { statuses: [STATUS.NA_BASE, STATUS.FINALIZADA], label: 'Concluída' },
]

/** Codigos de dom_tipos_ponto. Os ids sao resolvidos em runtime, ver tipos-dominio.ts. */
export const TIPO_PONTO = {
  BASE_SAIDA: 'base_saida',
  ORIGEM: 'origem',
  TRANSITO_DESTINO: 'transito_destino',
  DESTINO: 'destino',
  TRANSITO_RETORNO: 'transito_retorno',
  RETORNO: 'retorno',
  BASE_RETORNO: 'base_retorno',
  PARADA: 'parada',
} as const

/** Qual ponto de controle o status recem-atingido produz. */
export const TIPO_PONTO_POR_STATUS: Record<string, string> = {
  [STATUS.EM_ANDAMENTO]: TIPO_PONTO.BASE_SAIDA,
  [STATUS.NA_ORIGEM]: TIPO_PONTO.ORIGEM,
  [STATUS.EM_TRANSITO_DESTINO]: TIPO_PONTO.TRANSITO_DESTINO,
  [STATUS.NO_DESTINO]: TIPO_PONTO.DESTINO,
  [STATUS.EM_TRANSITO_RETORNO]: TIPO_PONTO.TRANSITO_RETORNO,
  [STATUS.RETORNANDO]: TIPO_PONTO.RETORNO,
  [STATUS.NA_BASE]: TIPO_PONTO.BASE_RETORNO,
}

/**
 * Regra de fotos por ponto, decidida com Pecanha: ate 5, no minimo 1.
 * Vale para todo ponto do fluxo. O wizard de pre-inicio tem regra propria,
 * porque la cada uma das 5 fotos da viatura tem significado individual.
 */
export const FOTOS_POR_PONTO = { min: 1, max: 5 } as const

export function ehStatusAtivo(status: string): boolean {
  return STATUS_ATIVOS.includes(status)
}

export function ehTerminal(status: string): boolean {
  return STATUS_TERMINAIS.includes(status)
}

export function podeTransicionar(de: string, para: string): boolean {
  return (TRANSICOES_VALIDAS[de] ?? []).includes(para)
}

export function indiceEtapa(status: string): number {
  return JORNADA_ETAPAS.findIndex((e) => e.statuses.includes(status))
}

export function rotuloStatus(status: string): string {
  return LABELS_STATUS[status] ?? status
}
