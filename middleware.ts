import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'
import { createServerClient, type CookieOptions } from '@supabase/ssr'

/**
 * Antes este middleware tinha `matcher: []` e nunca rodava. O comentário
 * justificava com `@supabase/ssr@0.0.10`, que não persistia sessão em cookie,
 * mas o projeto está em `^0.12.0`, que persiste. A justificativa estava
 * obsoleta e toda a proteção dependia de um `if` no componente cliente, que
 * o usuário vê piscar antes do redirecionamento.
 *
 * Aqui o middleware faz duas coisas: renova a sessão a cada navegação e
 * barra quem não está autenticado antes de a página existir.
 *
 * A checagem de PERFIL continua no cliente, porque depende de uma consulta a
 * `usuarios` e encareceria cada navegação. Quem garante a autorização de fato
 * é a RLS no banco, não a tela.
 */
export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request: { headers: request.headers } })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet: Array<{ name: string; value: string; options: CookieOptions }>) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
          response = NextResponse.next({ request: { headers: request.headers } })
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options),
          )
        },
      },
    },
  )

  // getUser revalida o token no servidor. getSession apenas lê o cookie e
  // aceitaria um token forjado.
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const rota = request.nextUrl.pathname
  const ehDashboard = rota.startsWith('/dashboard')
  const ehAuth = rota.startsWith('/auth')

  if (ehDashboard && !user) {
    const url = request.nextUrl.clone()
    url.pathname = '/auth/login'
    url.searchParams.set('de', rota)
    return NextResponse.redirect(url)
  }

  if (user && rota === '/auth/login') {
    const url = request.nextUrl.clone()
    url.pathname = '/dashboard'
    url.search = ''
    return NextResponse.redirect(url)
  }

  void ehAuth
  return response
}

export const config = {
  matcher: [
    /*
     * Todas as rotas, menos arquivo estático, imagem otimizada, favicon e as
     * rotas de API, que fazem a própria checagem em lib/api-auth.ts.
     */
    '/((?!_next/static|_next/image|favicon.ico|api/|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)',
  ],
}
