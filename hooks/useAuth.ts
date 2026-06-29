'use client'

import { useEffect, useState, useRef } from 'react'
import { createClient } from '@/lib/supabase/client'
import type { UsuarioAutenticado, Perfil } from '@/types'

const supabase = createClient()

export function useAuth() {
  const [user, setUser]       = useState<UsuarioAutenticado | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError]     = useState<string | null>(null)
  const fetchingRef           = useRef(false)

  async function carregarPerfil(authUserId: string): Promise<UsuarioAutenticado | null> {
    try {
      const { data: u } = await supabase
        .from('usuarios')
        .select('*')
        .eq('auth_user_id', authUserId)
        .maybeSingle() as any

      if (!u) return null

      if (u.status !== 'ativo') {
        await supabase.auth.signOut()
        const msgs: Record<string, string> = {
          inativo:   'Sua conta está inativa. Contate o administrador.',
          bloqueado: 'Sua conta está bloqueada. Contate o administrador.',
          pendente:  'Sua conta ainda não foi aprovada. Aguarde a ativação.',
        }
        throw new Error(msgs[u.status] ?? 'Acesso negado.')
      }

      const { data: p } = await supabase
        .from('dom_perfis')
        .select('id, codigo, nome_exibicao')
        .eq('id', u.perfil_id)
        .maybeSingle() as any

      // atualiza último acesso sem bloquear
      supabase.from('usuarios').update({ ultimo_acesso: new Date().toISOString() }).eq('id', u.id)

      return {
        ...u,
        perfil: p ?? undefined,
      } as UsuarioAutenticado
    } catch (e) {
      if (e instanceof Error && e.message) throw e
      return null
    }
  }

  // Inicializa sessão existente
  useEffect(() => {
    if (fetchingRef.current) return
    fetchingRef.current = true

    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (session?.user) {
        try {
          const perfil = await carregarPerfil(session.user.id)
          setUser(perfil)
        } catch {
          setUser(null)
        }
      }
      setLoading(false)
    })

    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (event === 'SIGNED_OUT') {
        setUser(null)
        setLoading(false)
      }
    })

    return () => subscription.unsubscribe()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const login = async (email: string, password: string): Promise<{ ok: boolean; trocarSenha: boolean }> => {
    setError(null)
    setLoading(true)

    try {
      const { error: authErr } = await supabase.auth.signInWithPassword({ email, password })
      if (authErr) {
        const msg = authErr.message === 'Invalid login credentials'
          ? 'E-mail ou senha incorretos.'
          : authErr.message
        setError(msg)
        setLoading(false)
        return { ok: false, trocarSenha: false }
      }

      const { data: { session } } = await supabase.auth.getSession()
      if (!session?.user) {
        setError('Sessão não encontrada. Tente novamente.')
        setLoading(false)
        return { ok: false, trocarSenha: false }
      }

      const perfil = await carregarPerfil(session.user.id)
      if (!perfil) {
        setError('Usuário não encontrado no sistema. Contate o administrador.')
        setLoading(false)
        return { ok: false, trocarSenha: false }
      }

      setUser(perfil)
      setLoading(false)
      return { ok: true, trocarSenha: perfil.troca_senha_obrigatoria ?? false }

    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Erro ao fazer login.'
      setError(msg)
      setUser(null)
      setLoading(false)
      return { ok: false, trocarSenha: false }
    }
  }

  const logout = async () => {
    setLoading(true)
    await supabase.auth.signOut()
    setUser(null)
    setLoading(false)
  }

  const changePassword = async (newPassword: string) => {
    setError(null)
    try {
      const { error: err } = await supabase.auth.updateUser({ password: newPassword })
      if (err) throw err
      if (user) {
        await supabase.from('usuarios').update({ troca_senha_obrigatoria: false }).eq('id', user.id)
        setUser({ ...user, troca_senha_obrigatoria: false })
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Erro ao alterar senha'
      setError(msg)
      throw err
    }
  }

  return {
    user,
    loading,
    error,
    login,
    logout,
    changePassword,
    isAuthenticated: !!user,
    precisaTrocarSenha: user?.troca_senha_obrigatoria ?? false,
  }
}
