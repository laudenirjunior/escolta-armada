/**
 * Constantes da aplicação
 */

export const PERFIS = {
  ADMINISTRADOR: 'administrador',
  GESTOR: 'gestor',
  SUPERVISOR: 'supervisor',
  CENTRAL: 'central',
  OPERADOR: 'operador',
} as const

export const STATUS_ESCOLTA = {
  RASCUNHO: 'rascunho',
  AGENDADA: 'agendada',
  EM_PRE_INICIO: 'em_pre_inicio',
  EM_ANDAMENTO: 'em_andamento',
  NA_ORIGEM: 'na_origem',
  EM_TRANSITO_DESTINO: 'em_transito_destino',
  NO_DESTINO: 'no_destino',
  RETORNANDO: 'retornando',
  NA_BASE: 'na_base',
  FINALIZADA: 'finalizada',
  CANCELADA: 'cancelada',
} as const

export const TIPOS_PONTO = {
  BASE_SAIDA: 'base_saida',
  ORIGEM: 'origem',
  DESTINO: 'destino',
  BASE_RETORNO: 'base_retorno',
} as const

export const PAPEIS_ESCOLTA = {
  COMANDANTE: 'comandante',
  OPERADOR: 'operador',
} as const

export const STATUS_USUARIO = {
  PENDENTE: 'pendente',
  ATIVO: 'ativo',
  INATIVO: 'inativo',
  BLOQUEADO: 'bloqueado',
} as const

export const TIPOS_FOTO = {
  PRESENCA: 'presenca',
  CHECKLIST_VIATURA: 'checklist_viatura',
  PONTO_CONTROLE: 'ponto_controle',
  OCORRENCIA: 'ocorrencia',
  OUTRO: 'outro',
} as const

export const TIPOS_CHECKLIST = {
  MATERIAL: 'material',
  VIATURA: 'viatura',
} as const

export const LABELS_STATUS = {
  [STATUS_ESCOLTA.RASCUNHO]: 'Rascunho',
  [STATUS_ESCOLTA.AGENDADA]: 'Agendada',
  [STATUS_ESCOLTA.EM_PRE_INICIO]: 'Pré-Início',
  [STATUS_ESCOLTA.EM_ANDAMENTO]: 'Em Andamento',
  [STATUS_ESCOLTA.NA_ORIGEM]: 'Na Origem',
  [STATUS_ESCOLTA.NO_DESTINO]: 'No Destino',
  [STATUS_ESCOLTA.RETORNANDO]: 'Retornando',
  [STATUS_ESCOLTA.NA_BASE]: 'Na Base',
  [STATUS_ESCOLTA.FINALIZADA]: 'Finalizada',
  [STATUS_ESCOLTA.CANCELADA]: 'Cancelada',
} as const

export const LABELS_PONTO = {
  [TIPOS_PONTO.BASE_SAIDA]: 'Base de Saída',
  [TIPOS_PONTO.ORIGEM]: 'Origem',
  [TIPOS_PONTO.DESTINO]: 'Destino',
  [TIPOS_PONTO.BASE_RETORNO]: 'Base de Retorno',
} as const

export const INTERVALO_RASTREAMENTO_MS = 60000 // 1 minuto
export const TIMEOUT_SINCRONIZACAO_MS = 30000 // 30 segundos
export const LIMITE_TAMANHO_FOTO_MB = 5
export const PRECISION_COORDINATES = 6 // Casas decimais para coordenadas

export const TRANSICOES_VALIDAS_STATUS: Record<string, string[]> = {
  [STATUS_ESCOLTA.RASCUNHO]: [STATUS_ESCOLTA.AGENDADA, STATUS_ESCOLTA.CANCELADA],
  [STATUS_ESCOLTA.AGENDADA]: [STATUS_ESCOLTA.EM_PRE_INICIO, STATUS_ESCOLTA.CANCELADA],
  [STATUS_ESCOLTA.EM_PRE_INICIO]: [STATUS_ESCOLTA.EM_ANDAMENTO, STATUS_ESCOLTA.CANCELADA],
  [STATUS_ESCOLTA.EM_ANDAMENTO]: [STATUS_ESCOLTA.NA_ORIGEM, STATUS_ESCOLTA.CANCELADA],
  [STATUS_ESCOLTA.NA_ORIGEM]: [STATUS_ESCOLTA.NO_DESTINO],
  [STATUS_ESCOLTA.NO_DESTINO]: [STATUS_ESCOLTA.RETORNANDO],
  [STATUS_ESCOLTA.RETORNANDO]: [STATUS_ESCOLTA.NA_BASE],
  [STATUS_ESCOLTA.NA_BASE]: [STATUS_ESCOLTA.FINALIZADA],
  [STATUS_ESCOLTA.FINALIZADA]: [],
  [STATUS_ESCOLTA.CANCELADA]: [],
}
