'use client'

import { useEffect, useState, useRef } from 'react'
import { createClient } from '@/lib/supabase/client'
import type { UsuarioAutenticado, Perfil } from '@/types'
import { ehErroDeRede, esquecerUsuario, lembrarUsuario, pedirArmazenamentoPersistente, perfilOffline, semRede } from '@/lib/offline/sessao'
import { contarFila, filaDisponivel } from '@/lib/offline/fila'

const supabase = createClient()

// Lote 2026-10 (onda L): leitura do perfil que falhou por falta de rede (não por recusa).
// Sem rede, o app abre com o perfil guardado no aparelho (snapshot do último login).
class ErroSemRede extends Error {
  constructor() { super('Sem conexão com o servidor.'); this.name = 'ErroSemRede' }
}

export function useAuth() {
  const [user, setUser]       = useState<UsuarioAutenticado | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError]     = useState<string | null>(null)
  const fetchingRef           = useRef(false)
  // Onda L: dono da fila de campo e da sessão sem rede.
  const [authUserId, setAuthUserId] = useState<string | null>(null)
  const [modoOffline, setModoOffline] = useState(false)

  async function carregarPerfil(authUserId: string): Promise<UsuarioAutenticado | null> {
    try {
      const { data: u, error: erroU } = await supabase
        .from('usuarios')
        .select('*')
        .eq('auth_user_id', authUserId)
        .maybeSingle() as any

      if (erroU && ehErroDeRede(erroU)) throw new ErroSemRede()
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

      const { data: p, error: erroP } = await supabase
        .from('dom_perfis')
        .select('id, codigo, nome_exibicao')
        .eq('id', u.perfil_id)
        .maybeSingle() as any
      if (erroP && ehErroDeRede(erroP)) throw new ErroSemRede()

      // Ultimo acesso, COM await.
      //
      // Antes era promessa solta, sem await. O PostgREST do supabase-js so dispara a
      // requisicao quando a promessa e consumida, entao o UPDATE muitas vezes nunca saia:
      // em 19/08/2026, quatro dos cinco usuarios ja tinham entrado no sistema e a tela de
      // usuarios mostrava "Nunca acessou" para todos eles.
      //
      // Falha aqui nao pode derrubar o login: quem entrou, entrou. O que se perde e a
      // data na tela de governanca.
      try {
        await (supabase as any)
          .from('usuarios')
          .update({ ultimo_acesso: new Date().toISOString() })
          .eq('id', u.id)
      } catch {
        // silencioso de proposito: ver comentario acima
      }

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

    supabase.auth.getSession().then(async ({ data: { session }, error: erroSessao }) => {
      if (session?.user) {
        try {
          const perfil = await carregarPerfil(session.user.id)
          setUser(perfil)
          if (perfil) {
            setAuthUserId(session.user.id)
            void lembrarUsuario(session.user.id, perfil)
          }
        } catch (e) {
          // Onda L: sem rede, o perfil guardado no aparelho (sem mandar ao login).
          const off = e instanceof ErroSemRede || semRede() ? await perfilOffline<UsuarioAutenticado>(session.user.id) : null
          setUser(off?.perfil ?? null)
          setAuthUserId(off ? off.authUserId : null)
          setModoOffline(!!off)
        }
      } else if ((erroSessao && ehErroDeRede(erroSessao)) || semRede()) {
        // Token vencido e sem rede para renovar: o último usuário deste aparelho.
        const off = await perfilOffline<UsuarioAutenticado>()
        setUser(off?.perfil ?? null)
        setAuthUserId(off ? off.authUserId : null)
        setModoOffline(!!off)
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
      setAuthUserId(session.user.id)
      setModoOffline(false)
      // Onda L: guarda o perfil para abrir sem rede e pede armazenamento persistente.
      void lembrarUsuario(session.user.id, perfil)
      void pedirArmazenamentoPersistente()
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
    // Onda L: sair com registros guardados avisa (eles ficam no aparelho e só sobem quando
    // este usuário entrar de novo aqui).
    if (authUserId && filaDisponivel()) {
      try {
        const c = await contarFila(authUserId)
        if (c.pendentes > 0 && typeof window !== 'undefined'
            && !window.confirm(`Há ${c.pendentes} registro(s) guardado(s) neste aparelho que ainda não foram enviados. ` +
              'Eles só serão enviados quando você entrar de novo neste aparelho, com internet. Sair mesmo assim?')) {
          return
        }
      } catch { /* fila ilegível: sai normalmente */ }
    }
    setLoading(true)
    await supabase.auth.signOut()
    await esquecerUsuario(authUserId)
    setUser(null)
    setAuthUserId(null)
    setModoOffline(false)
    setLoading(false)
  }

  const changePassword = async (newPassword: string) => {
    setError(null)
    try {
      const { error: err } = await supabase.auth.updateUser({ password: newPassword })
      if (err) throw err
      if (user) {
        await (supabase as any).from('usuarios').update({ troca_senha_obrigatoria: false }).eq('id', user.id)

        // Guarda a senha para o administrador poder consultar depois, decisao de Pecanha
        // em 2026-08-19. Este e o UNICO momento em que a senha nova existe em texto no
        // aplicativo: `auth.users` so guarda o bcrypt, e dele nao se volta.
        //
        // Falha aqui nao derruba a troca: a senha nova ja esta valendo e o usuario
        // consegue entrar. O que se perde e a consulta futura pelo administrador, e para
        // esse caso a tela dele oferece redefinir.
        try {
          await (supabase as any).rpc('registrar_credencial', {
            p_usuario_id: user.id,
            p_senha: newPassword,
            p_provisoria: false,
          })
        } catch {
          // silencioso de proposito: ver comentario acima
        }

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
    // Onda L: dono da fila de campo e indicação de que o perfil veio do aparelho (sem rede).
    authUserId,
    modoOffline,
  }
}
