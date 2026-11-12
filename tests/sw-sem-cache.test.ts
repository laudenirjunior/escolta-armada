/**
 * Service worker (lib/offline/sw-fonte.js) fora do navegador, com caches e fetch falsos: o GET
 * de reconferência (cabeçalho x-escolta-sem-cache) nunca é respondido com a cópia guardada.
 * Teste de 12/11/2026: a cópia do GET de status, lida na etapa anterior, voltou sem rede.
 * Rodar: node --test tests/sw-sem-cache.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import vm from 'node:vm'

const SUPA = 'https://exemplo.supabase.co'
const URL_STATUS = `${SUPA}/rest/v1/escoltas?select=status&id=eq.e1`
// JWT sem assinatura com role authenticated e sub (o SW só lê o payload).
const corpoJwt = Buffer.from(JSON.stringify({ role: 'authenticated', sub: 'u1' })).toString('base64url')
const AUTH = `Bearer x.${corpoJwt}.y`

function montarSw(rede: (req: Request) => Promise<Response>) {
  const lojas = new Map<string, Map<string, Response>>()
  const loja = (nome: string) => {
    if (!lojas.has(nome)) lojas.set(nome, new Map())
    const m = lojas.get(nome)!
    return {
      match: async (r: Request | string) => m.get(typeof r === 'string' ? r : r.url)?.clone(),
      put: async (r: Request, resp: Response) => { m.set(r.url, resp) },
      delete: async (r: Request) => m.delete(r.url),
      keys: async () => [...m.keys()].map(u => new Request(u)),
    }
  }
  const ouvintes: Record<string, (ev: unknown) => void> = {}
  const self = {
    location: { origin: 'https://app.exemplo' },
    navigator: { onLine: true },
    addEventListener: (tipo: string, fn: (ev: unknown) => void) => { ouvintes[tipo] = fn },
    skipWaiting: () => {},
    clients: { claim: async () => {} },
  }
  const caches = {
    open: async (nome: string) => loja(nome),
    match: async () => undefined,
    keys: async () => [...lojas.keys()],
    delete: async (nome: string) => lojas.delete(nome),
  }
  const fonte = readFileSync(join(import.meta.dirname, '..', 'lib', 'offline', 'sw-fonte.js'), 'utf8')
    .replace("'__BUILD_ID__'", JSON.stringify('teste'))
    .replace("'__SUPABASE__'", JSON.stringify(SUPA))
    .replace('__PRECARGA__', '[]')
  vm.runInNewContext(fonte, {
    self, caches, fetch: (req: Request) => rede(req), Request, Response, URL, setTimeout, clearTimeout,
    AbortController, atob, JSON, console,
  })
  const pedir = async (cabecalhos: Record<string, string>): Promise<Response | undefined> => {
    let resposta: Promise<Response> | undefined
    ouvintes.fetch({ request: new Request(URL_STATUS, { headers: { authorization: AUTH, ...cabecalhos } }), respondWith: (p: Promise<Response>) => { resposta = p } })
    return resposta ? await resposta : undefined
  }
  return { pedir, lojas }
}

const json = (o: unknown) => new Response(JSON.stringify(o), { status: 200, headers: { 'Content-Type': 'application/json' } })

test('leitura comum: com rede guarda a cópia; sem rede devolve a cópia (como antes)', async () => {
  let online = true
  const sw = montarSw(async () => { if (!online) throw new TypeError('Failed to fetch'); return json({ status: 'em_pre_inicio' }) })
  assert.deepEqual(await (await sw.pedir({}))!.json(), { status: 'em_pre_inicio' })
  online = false
  const r = await sw.pedir({})
  assert.equal(r!.status, 200)
  assert.deepEqual(await r!.json(), { status: 'em_pre_inicio' })
})

test('12/11: reconferência sem rede NÃO volta com a cópia antiga: 504 SEM_CONEXAO', async () => {
  let online = true
  const sw = montarSw(async () => { if (!online) throw new TypeError('Failed to fetch'); return json({ status: 'em_pre_inicio' }) })
  await sw.pedir({})                     // cópia guardada na etapa anterior
  online = false
  const r = await sw.pedir({ 'x-escolta-sem-cache': '1' })
  assert.equal(r!.status, 504)
  assert.equal((await r!.json()).code, 'SEM_CONEXAO')
})

test('reconferência com rede: resposta do servidor e nada guardado', async () => {
  const sw = montarSw(async () => json({ status: 'na_origem' }))
  const r = await sw.pedir({ 'x-escolta-sem-cache': '1' })
  assert.deepEqual(await r!.json(), { status: 'na_origem' })
  const guardadas = [...sw.lojas.values()].reduce((n, m) => n + m.size, 0)
  assert.equal(guardadas, 0)
})
