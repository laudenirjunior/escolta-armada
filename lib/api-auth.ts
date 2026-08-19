import { createClient } from '@/lib/supabase/server'

/**
 * Guarda de sessao para Route Handlers.
 *
 * As duas rotas de API do projeto aceitavam chamada de qualquer um na internet.
 * A de IA era um proxy aberto e faturado para a OpenAI; a do Telegram permitia
 * mandar mensagem em nome do bot para qualquer chat e listar as conversas
 * recentes dele.
 *
 * Devolve o usuario e o perfil, ou uma resposta pronta de 401/403.
 */
export type SessaoApi = {
  usuarioId: string
  authUserId: string
  perfil: string
  nome: string
}

export async function exigirSessao(): Promise<
  { ok: true; sessao: SessaoApi } | { ok: false; status: number; erro: string }
> {
  const sb = createClient()

  const {
    data: { user },
    error,
  } = await sb.auth.getUser()

  if (error || !user) {
    return { ok: false, status: 401, erro: 'Sessão inválida ou expirada.' }
  }

  const { data: perfilRow } = await sb
    .from('usuarios')
    .select('id, nome_completo, status, perfil:dom_perfis(codigo)')
    .eq('auth_user_id', user.id)
    .maybeSingle()

  if (!perfilRow) {
    return { ok: false, status: 403, erro: 'Usuário sem cadastro ativo.' }
  }

  const row = perfilRow as unknown as {
    id: string
    nome_completo: string
    status: string
    perfil: { codigo: string } | null
  }

  if (row.status !== 'ativo') {
    return { ok: false, status: 403, erro: 'Usuário inativo ou bloqueado.' }
  }

  return {
    ok: true,
    sessao: {
      usuarioId: row.id,
      authUserId: user.id,
      perfil: row.perfil?.codigo ?? '',
      nome: row.nome_completo,
    },
  }
}

/** Limite simples por usuario, em memoria do processo. */
const janelas = new Map<string, { ate: number; usos: number }>()

export function dentroDoLimite(chave: string, maximo: number, janelaMs: number): boolean {
  const agora = Date.now()
  const atual = janelas.get(chave)

  if (!atual || agora > atual.ate) {
    janelas.set(chave, { ate: agora + janelaMs, usos: 1 })
    return true
  }
  if (atual.usos >= maximo) return false

  atual.usos += 1
  return true
}

/** Escapa o que vai para o Telegram com parse_mode HTML. */
export function escaparHtml(texto: string): string {
  return texto
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}
