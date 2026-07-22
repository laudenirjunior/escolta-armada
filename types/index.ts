/**
 * Tipos principais do sistema Escolta Armada
 * Baseado no planejamento técnico v1
 */

// ============================================================================
// ENUMS E TIPOS BÁSICOS
// ============================================================================

export enum Perfil {
  ADMINISTRADOR = 'administrador',
  GESTOR = 'gestor',
  SUPERVISOR = 'supervisor',
  CENTRAL = 'central',
  OPERADOR = 'operador',
}

export enum StatusEscolta {
  RASCUNHO = 'rascunho',
  AGENDADA = 'agendada',
  EM_PRE_INICIO = 'em_pre_inicio',
  EM_ANDAMENTO = 'em_andamento',
  NA_ORIGEM = 'na_origem',
  EM_TRANSITO_DESTINO = 'em_transito_destino',
  NO_DESTINO = 'no_destino',
  RETORNANDO = 'retornando',
  NA_BASE = 'na_base',
  FINALIZADA = 'finalizada',
  CANCELADA = 'cancelada',
}

export enum TipoPonto {
  BASE_SAIDA = 'base_saida',
  ORIGEM = 'origem',
  DESTINO = 'destino',
  BASE_RETORNO = 'base_retorno',
}

export enum PapelEscolta {
  COMANDANTE = 'comandante',
  OPERADOR = 'operador',
}

export enum StatusUsuario {
  PENDENTE = 'pendente',
  ATIVO = 'ativo',
  INATIVO = 'inativo',
  BLOQUEADO = 'bloqueado',
}

export enum TipoFoto {
  PRESENCA = 'presenca',
  CHECKLIST_VIATURA = 'checklist_viatura',
  PONTO_CONTROLE = 'ponto_controle',
  OCORRENCIA = 'ocorrencia',
  OUTRO = 'outro',
}

export enum TipoChecklist {
  MATERIAL = 'material',
  VIATURA = 'viatura',
}

// ============================================================================
// USUÁRIOS E ACESSO
// ============================================================================

export interface Usuario {
  id: string
  nome_completo: string
  cpf: string
  email: string
  telefone?: string
  perfil_id: string
  status: StatusUsuario
  troca_senha_obrigatoria: boolean
  ultimo_acesso?: string
  criado_em: string
  atualizado_em: string
  criado_por?: string
  atualizado_por?: string
  metadados?: Record<string, any>
}

export interface Vigilante {
  id: string
  usuario_id?: string
  nome_completo: string
  cpf: string
  funcao_id: string
  cnv?: string
  extensao_escolta_armada?: string
  valor_padrao_pago?: number
  status: 'ativo' | 'inativo'
  criado_em: string
  atualizado_em: string
  metadados?: Record<string, any>
}

export interface Funcao {
  id: string
  nome: string
  ativo: boolean
}

// ============================================================================
// CLIENTES E RECURSOS
// ============================================================================

export interface Cliente {
  id: string
  nome_cliente: string
  cnpj?: string
  contato: string
  telefone: string
  cor_destaque: string
  telegram_chat_id?: string
  observacoes?: string
  status: 'ativo' | 'inativo'
  criado_em: string
  atualizado_em: string
  metadados?: Record<string, any>
}

export interface Veiculo {
  id: string
  tipo_id: string
  placa: string
  modelo?: string
  status: 'ativo' | 'inativo' | 'manutencao'
  observacoes?: string
  criado_em: string
  atualizado_em: string
  metadados?: Record<string, any>
}

export interface Armamento {
  id: string
  tipo_id: string
  calibre_id: string
  numeracao?: string
  documentacao?: string
  status: 'ativo' | 'inativo'
  criado_em: string
  atualizado_em: string
  metadados?: Record<string, any>
}

// ============================================================================
// ESCOLTAS
// ============================================================================

export interface Escolta {
  id: string
  cliente_id: string
  codigo_escolta: string
  data_solicitacao: string
  data_hora_prevista: string
  status: StatusEscolta
  origem_endereco: string
  origem_lat: number
  origem_lng: number
  destino_endereco: string
  destino_lat: number
  destino_lng: number
  checklist_pendente_no_inicio: boolean
  observacao_fechamento?: string
  data_finalizacao?: string
  criada_por: string
  criado_em: string
  atualizado_em: string
  metadados?: Record<string, any>
}

export interface EscoltaVeiculo {
  id: string
  escolta_id: string
  veiculo_id: string
  responsavel_lancamento_id: string
  quilometragem_saida: number
  quilometragem_retorno?: number
  abastecimento_litros?: number
  abastecimento_valor?: number
  observacoes?: string
  criado_em: string
  atualizado_em: string
  metadados?: Record<string, any>
}

export interface EscoltaEfetivo {
  id: string
  escolta_id: string
  escolta_veiculo_id: string
  vigilante_id: string
  papel_na_escolta: PapelEscolta
  valor_cobrado_cliente?: number
  valor_pago_vigilante?: number
  confirmado: boolean
  criado_em: string
  atualizado_em: string
}

export interface EscoltaArmamento {
  id: string
  escolta_veiculo_id: string
  armamento_id?: string
  tipo_id: string
  calibre_id: string
  quantidade: number
  criado_em: string
  atualizado_em: string
}

// ============================================================================
// FOTOS E GEOLOCALIZAÇÃO
// ============================================================================

export interface Foto {
  id: string
  caminho_arquivo: string
  tipo_foto_id: string
  latitude?: number
  longitude?: number
  precisao_metros?: number
  data_hora_captura: string
  carimbo_aplicado: boolean
  enviada_telegram: boolean
  sincronizada: boolean
  criado_por: string
  criado_em: string
  atualizado_em: string
}

export interface PontoControle {
  id: string
  escolta_veiculo_id: string
  tipo_ponto_id: string
  data_hora: string
  latitude: number
  longitude: number
  precisao_metros?: number
  foto_id?: string
  lancado_por: string
  sincronizado: boolean
  criado_offline: boolean
  criado_em: string
  atualizado_em: string
}

export interface Rastreamento {
  id: string
  escolta_veiculo_id: string
  data_hora: string
  latitude: number
  longitude: number
  precisao_metros?: number
  sincronizado: boolean
  criado_offline: boolean
}

export interface Presenca {
  id: string
  escolta_id: string
  vigilante_id: string
  foto_id: string
  data_hora: string
  latitude: number
  longitude: number
  sincronizado: boolean
  criado_em: string
  atualizado_em: string
}

// ============================================================================
// CHECKLISTS
// ============================================================================

export interface ChecklistModelo {
  id: string
  tipo: TipoChecklist
  nome: string
  versao: number
  ativo: boolean
  criado_em: string
  atualizado_em: string
}

export interface ChecklistModeloItem {
  id: string
  modelo_id: string
  descricao_item: string
  exige_foto: boolean
  ordem: number
  ativo: boolean
}

export interface Checklist {
  id: string
  escolta_veiculo_id: string
  modelo_id: string
  tipo: TipoChecklist
  concluido: boolean
  data_conclusao?: string
  responsavel_id: string
  sincronizado: boolean
  criado_em: string
  atualizado_em: string
}

export interface ChecklistResposta {
  id: string
  checklist_id: string
  descricao_item: string
  conforme: boolean
  observacao?: string
  foto_id?: string
  criado_em: string
  atualizado_em: string
}

// ============================================================================
// EVENTOS E TIMELINE
// ============================================================================

export interface AtualizacaoStatus {
  id: string
  escolta_id: string
  tipo_evento_id: string
  descricao: string
  foto_id?: string
  autor_id: string
  data_hora: string
  latitude?: number
  longitude?: number
}

export interface Ocorrencia {
  id: string
  escolta_id: string
  escolta_veiculo_id?: string
  tipo_ocorrencia_id: string
  descricao: string
  data_hora: string
  latitude?: number
  longitude?: number
  foto_id?: string
  registrado_por: string
  sincronizado: boolean
  criado_em: string
  atualizado_em: string
}

export interface Emergencia {
  id: string
  escolta_id: string
  escolta_veiculo_id: string
  acionado_por: string
  data_hora: string
  latitude: number
  longitude: number
  status: 'aberta' | 'em_atendimento' | 'encerrada'
  encerrada_por?: string
  observacao?: string
  criado_em: string
  atualizado_em: string
}

// ============================================================================
// NOTIFICAÇÕES
// ============================================================================

export interface Notificacao {
  id: string
  escolta_id: string
  canal: 'app' | 'telegram'
  tipo_evento_id: string
  destino: string
  payload: Record<string, any>
  status_envio: 'pendente' | 'enviada' | 'falha'
  tentativas: number
  data_envio?: string
}

// ============================================================================
// AUDITORIA
// ============================================================================

export interface LogAuditoria {
  id: string
  usuario_id: string
  acao: string
  entidade_afetada: string
  registro_id: string
  dados_antes?: Record<string, any>
  dados_depois?: Record<string, any>
  data_hora: string
  ip: string
}

// ============================================================================
// CONTEXTO DA APLICAÇÃO
// ============================================================================

export interface UsuarioAutenticado extends Usuario {
  perfil?: {
    id: string
    codigo: Perfil
    nome_exibicao: string
  }
}

export interface EstadoSincronizacao {
  pendente: number
  enviado: number
  erros: number
  ultima_sincronizacao?: string
}
