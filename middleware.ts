import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

// Middleware simplificado — proteção real feita no client (dashboard/layout.tsx)
// O @supabase/ssr@0.0.10 não persiste sessão em cookies, apenas localStorage.
export function middleware(request: NextRequest) {
  return NextResponse.next()
}

export const config = {
  matcher: [],
}
