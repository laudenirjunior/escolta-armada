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





export const INTERVALO_RASTREAMENTO_MS = 60000 // 1 minuto
export const TIMEOUT_SINCRONIZACAO_MS = 30000 // 30 segundos
export const LIMITE_TAMANHO_FOTO_MB = 5
export const PRECISION_COORDINATES = 6 // Casas decimais para coordenadas


