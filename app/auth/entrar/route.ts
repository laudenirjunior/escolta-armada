import { NextResponse, type NextRequest } from 'next/server'
import type { EmailOtpType } from '@supabase/supabase-js'
import { createClient } from '@/lib/supabase/server'

/**
 * Entrada pela intranet (login único).
 * A intranet gera um link de uso único para a conta da pessoa neste sistema
 * (auth.admin.generateLink) e manda para cá. Aqui o token é validado e a
 * sessão é criada nos cookies, como num login normal. Token inválido ou
 * vencido cai na tela de login de sempre. O middleware não barra /auth.
 */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url)
  const tokenHash = searchParams.get('token_hash')
  const tipo = (searchParams.get('type') ?? 'magiclink') as EmailOtpType
  const next = searchParams.get('next')
  const destino = next && next.startsWith('/') && !next.startsWith('//') ? next : '/dashboard'

  if (tokenHash) {
    const supabase = createClient()
    const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: tipo })
    if (!error) return NextResponse.redirect(`${origin}${destino}`)
  }

  return NextResponse.redirect(`${origin}/auth/login?erro=entrada_intranet`)
}
