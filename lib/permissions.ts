// Fonte única de verdade para controle de acesso por perfil.
// Importe daqui em vez de definir arrays localmente em cada página.

export const PERFIS = {
  ADMINISTRADOR: 'administrador',
  GESTOR:        'gestor',
  SUPERVISOR:    'supervisor',
  CENTRAL:       'central',
  OPERADOR:      'operador',
} as const

export type CodigoPerfil = typeof PERFIS[keyof typeof PERFIS]

// ── Permissões por funcionalidade ─────────────────────────────────────────────

/** Pode criar nova escolta. Central entrou por decisao de Pecanha em 2026-08-20. */
export const PODE_CRIAR_ESCOLTA: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor', 'central']

/**
 * Pode editar uma escolta que ainda nao comecou: cliente, data, local, viatura, efetivo.
 *
 * Operador fica de fora de proposito. Ele pode PUXAR uma escolta agendada e incluir o
 * companheiro de viatura, mas nao altera o que foi contratado. A regra tambem esta no
 * banco, na trigger `impedir_edicao_por_operador` (migration 191): esta lista serve para
 * a tela nao oferecer um botao que o banco vai recusar.
 */
export const PODE_EDITAR_ESCOLTA: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor', 'central']

/** Pode cancelar/reagendar uma escolta */
export const PODE_CANCELAR_ESCOLTA: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor']

/** Pode avançar o status da escolta */
export const PODE_AVANCAR_ESCOLTA: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor', 'central', 'operador']

/** Pode finalizar uma escolta */
export const PODE_FINALIZAR_ESCOLTA: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor']

/** Pode editar registros de cadastro (clientes, vigilantes, veículos) */
export const PODE_EDITAR_CADASTROS: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor', 'central']

/** Pode gerenciar usuários de forma plena (qualquer perfil) */
export const PODE_GERENCIAR_USUARIOS: CodigoPerfil[] = ['administrador', 'gestor']

/** Pode acessar a página de Usuários (governança). Supervisor entra com escopo restrito a operadores. */
export const PODE_ACESSAR_USUARIOS: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor']

/** Pode cadastrar/editar operadores (vigilantes). Supervisor só mexe neste perfil. */
export const PODE_GERENCIAR_OPERADORES: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor']

/** Pode ver dados financeiros das escoltas */
export const PODE_VER_FINANCEIRO: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor', 'central']

/** Pode ver relatórios e indicadores */
export const PODE_VER_RELATORIOS: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor', 'central']

/** Pode configurar Telegram e integrações */
export const PODE_CONFIGURAR_INTEGRACOES: CodigoPerfil[] = ['administrador', 'gestor']

/** Pode acessar auditoria e configurações de sistema */
export const PODE_ADMINISTRAR_SISTEMA: CodigoPerfil[] = ['administrador']

/** Perfis considerados "gestão" — podem ver todas as escoltas no Campo */
export const PERFIS_GESTAO: CodigoPerfil[] = ['administrador', 'gestor', 'supervisor', 'central']

/** Helper: verifica se um perfil tem a permissão */
export function temPermissao(perfil: string | undefined | null, permissao: CodigoPerfil[]): boolean {
  if (!perfil) return false
  return permissao.includes(perfil as CodigoPerfil)
}
