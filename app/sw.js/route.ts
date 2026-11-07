/**
 * /sw.js: o service worker da onda L (Lote 2026-10; docs/14, seção 16.3.6), gerado no build.
 *
 * Antes era public/sw.js, fixo e sem cache. Agora o arquivo muda a cada build (a versão é o
 * BUILD_ID, de next.config.mjs), o que faz o navegador instalar o novo e apagar as cópias
 * da versão anterior. A lista de scripts e estilos do Campo, do Painel e do detalhe vem do
 * manifesto do build (.next/app-build-manifest.json), lido aqui, na geração estática. O
 * código do worker está em lib/offline/sw-fonte.js.
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

export const dynamic = 'force-static'

const ENTRADAS = ['/layout', '/dashboard/layout', '/dashboard/page', '/dashboard/campo/page', '/dashboard/escoltas/[id]/page']

function lerJson(arquivo: string): Record<string, unknown> | null {
  try { return JSON.parse(readFileSync(join(process.cwd(), '.next', arquivo), 'utf8')) } catch { return null }
}

function precarga(): string[] {
  const app = lerJson('app-build-manifest.json') as { pages?: Record<string, string[]> } | null
  const base = lerJson('build-manifest.json') as { rootMainFiles?: string[]; polyfillFiles?: string[] } | null
  const arquivos = new Set<string>()
  for (const e of ENTRADAS) for (const f of app?.pages?.[e] ?? []) arquivos.add(f)
  for (const f of [...(base?.rootMainFiles ?? []), ...(base?.polyfillFiles ?? [])]) arquivos.add(f)
  return Array.from(arquivos).filter(f => f.startsWith('static/') && /\.(js|css)$/.test(f)).map(f => `/_next/${f}`)
}

function versao(): string {
  try {
    const id = readFileSync(join(process.cwd(), '.next', 'BUILD_ID'), 'utf8').trim()
    if (id) return id
  } catch { /* ainda não escrito: usa o do next.config */ }
  return process.env.ESCOLTA_BUILD_ID ?? 'desenvolvimento'
}

export function GET() {
  const fonte = readFileSync(join(process.cwd(), 'lib', 'offline', 'sw-fonte.js'), 'utf8')
  let origemSupabase = ''
  try { origemSupabase = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? '').origin } catch { origemSupabase = '' }
  const corpo = fonte
    .replace("'__BUILD_ID__'", JSON.stringify(versao()))
    .replace("'__SUPABASE__'", JSON.stringify(origemSupabase))
    .replace('__PRECARGA__', JSON.stringify(precarga()))
  return new Response(corpo, {
    headers: {
      'Content-Type': 'application/javascript; charset=utf-8',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Service-Worker-Allowed': '/',
    },
  })
}
