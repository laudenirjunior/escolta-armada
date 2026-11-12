/* eslint-disable */
/**
 * Service worker do Escolta Armada (Lote 2026-10, onda L; docs/14, seção 16.3.6).
 * Servido em /sw.js pela rota app/sw.js/route.ts, gerada no build com a versão (BUILD_ID),
 * a origem do Supabase e a lista de scripts e estilos do Campo, do Painel e do detalhe lida
 * do manifesto do build. Este arquivo é o modelo; os marcadores __...__ são trocados lá.
 *
 * O comentário antigo (sw.js sem cache) continua valendo no que importa: nunca servir
 * bundle velho depois de um deploy. Por isso:
 * - /_next/static/* é cache-first (o nome muda a cada build: não existe "bundle velho");
 * - as páginas são network-first (4 s) com cópia por versão; a cópia de uma versão é
 *   apagada quando a seguinte ativa;
 * - os scripts da versão anterior ficam até a seguinte (abas antigas abertas ainda pedem
 *   os nomes antigos); os de duas versões atrás são apagados;
 * - /api/*, POST (inclusive o do Supabase: RPC, URL assinada de foto) e o payload RSC do
 *   roteador nunca entram em cache nem passam por aqui;
 * - GET do Supabase REST das tabelas que o Campo, o Painel e o detalhe leem: network-first
 *   (4 s), com cópia por usuário (o sub do token), apagada no logout e na troca de usuário.
 * - GET com o cabeçalho x-escolta-sem-cache (a reconferência da etapa antes de gravar): só
 *   rede, nunca guardado e nunca respondido com a cópia. Sem rede, 504 SEM_CONEXAO. Teste de
 *   12/11/2026: a cópia do GET de status, lida na etapa anterior, voltou sem rede com o status
 *   antigo e a tela acusou "etapa avançada em outra tela" sem guardar o registro.
 */
const VERSAO = '__BUILD_ID__'
const SUPABASE = '__SUPABASE__'
const PRECARGA = __PRECARGA__
const CACHE_ESTATICO = 'escolta-estatico-' + VERSAO
const CACHE_PAGINAS = 'escolta-paginas-' + VERSAO
const PREFIXO_ESTATICO = 'escolta-estatico-'
const PREFIXO_PAGINAS = 'escolta-paginas-'
const PREFIXO_DADOS = 'escolta-dados-'
const CACHE_META = 'escolta-meta'
const PAGINA_OFFLINE = '/offline.html'
const TEMPO_REDE_MS = 4000
const TEMPO_CONFERENCIA_MS = 8000
const CABECALHO_SEM_CACHE = 'x-escolta-sem-cache'
const MAX_DADOS = 400
const TELAS_FIXAS = ['/dashboard', '/dashboard/campo']
// Só as tabelas que o Campo, o Painel e o detalhe leem (escoltas do operador, 16.3.4); o resto
// (cadastros, locais, relatórios) segue direto para a rede, como antes.
const TABELAS_CAMPO = ['escoltas', 'escolta_efetivo', 'escolta_veiculos', 'pontos_controle', 'checklists',
  'checklist_respostas', 'checklist_modelos', 'fotos', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
  'escolta_status_historico', 'escolta_conclusoes_antecipadas', 'vigilantes', 'usuarios', 'veiculos', 'clientes',
  'dom_perfis', 'dom_tipos_ocorrencia', 'dom_tipos_ponto', 'dom_tipos_foto']
const RE_DETALHE = /^\/dashboard\/escoltas\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/?$/i

function telaOffline(caminho) {
  return TELAS_FIXAS.includes(caminho) || RE_DETALHE.test(caminho)
}
function semBarraFinal(caminho) {
  return caminho.length > 1 && caminho.endsWith('/') ? caminho.slice(0, -1) : caminho
}
function chavePagina(caminho) {
  return new Request(self.location.origin + semBarraFinal(caminho))
}

// ── Instalação e ativação ─────────────────────────────────────────────────────────────
self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const estatico = await caches.open(CACHE_ESTATICO)
    try { await estatico.add(new Request(PAGINA_OFFLINE, { cache: 'reload' })) } catch (e) { /* tenta de novo na próxima */ }
    await Promise.all(PRECARGA.map((u) => guardarEstatico(u).catch(() => {})))
  })())
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const meta = await caches.open(CACHE_META)
    let versoes = []
    try { const r = await meta.match('/__versoes'); if (r) versoes = await r.json() } catch (e) { versoes = [] }
    versoes = versoes.filter((v) => v !== VERSAO).concat([VERSAO]).slice(-2)
    await meta.put('/__versoes', new Response(JSON.stringify(versoes), { headers: { 'Content-Type': 'application/json' } }))
    for (const nome of await caches.keys()) {
      if (nome.startsWith(PREFIXO_PAGINAS) && nome !== CACHE_PAGINAS) await caches.delete(nome)
      if (nome.startsWith(PREFIXO_ESTATICO) && !versoes.includes(nome.slice(PREFIXO_ESTATICO.length))) await caches.delete(nome)
    }
    await self.clients.claim()
  })())
})

// ── Roteamento ────────────────────────────────────────────────────────────────────────
self.addEventListener('fetch', (event) => {
  const req = event.request
  if (req.method !== 'GET') return                       // POST nunca (RPC, URL assinada, Telegram)
  let url
  try { url = new URL(req.url) } catch (e) { return }
  if (url.origin === self.location.origin) {
    if (url.pathname.startsWith('/api/')) return            // nunca em cache
    if (url.pathname.startsWith('/_next/static/')) { event.respondWith(cacheFirst(req)); return }
    if (req.mode === 'navigate') { event.respondWith(navegacao(req, url)); return }
    return                                                  // RSC e o resto: rede, como antes
  }
  if (SUPABASE && url.origin === SUPABASE && url.pathname.startsWith('/rest/v1/') && !req.headers.has('range')) {
    if (req.headers.has(CABECALHO_SEM_CACHE)) { event.respondWith(somenteRede(req)); return }
    if (TABELAS_CAMPO.includes(url.pathname.slice('/rest/v1/'.length))) { event.respondWith(dadosRede(req)); return }
    // Parte 2: sem rede, as demais leituras respondem na hora (sem as novas tentativas do
    // supabase-js, que seguravam a tela por 7 s a cada leitura); com rede, nada muda.
    if (semRedeNoAparelho()) event.respondWith(respostaSemConexao())
  }
})

// Sem rede e sem cópia: resposta imediata com erro (504, código SEM_CONEXAO), que o
// supabase-js não repete; a tela usa a cópia do aparelho. Nas demais tabelas, só com o
// aparelho sem rede (com rede, o erro de rede de sempre).
function semRedeNoAparelho() {
  return self.navigator && self.navigator.onLine === false
}
function respostaSemConexao() {
  return new Response(JSON.stringify({ code: 'SEM_CONEXAO', message: 'Sem conexão e sem cópia guardada no aparelho.', details: null, hint: null }),
    { status: 504, headers: { 'Content-Type': 'application/json' } })
}

async function guardarEstatico(u) {
  const req = new Request(u)
  if (await caches.match(req)) return
  const resp = await fetch(req)
  if (resp.ok) await (await caches.open(CACHE_ESTATICO)).put(req, resp)
}

async function cacheFirst(req) {
  const guardada = await caches.match(req)
  if (guardada) return guardada
  const resp = await fetch(req)
  if (resp.ok && resp.type === 'basic') {
    const copia = resp.clone()
    caches.open(CACHE_ESTATICO).then((c) => c.put(req, copia)).catch(() => {})
  }
  return resp
}

function comPrazo(promessa, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => resolve(undefined), ms)
    promessa.then((v) => { clearTimeout(t); resolve(v) }, (e) => { clearTimeout(t); reject(e) })
  })
}

async function paginaGuardada(caminho) {
  const c = await caches.open(CACHE_PAGINAS)
  let r = await c.match(chavePagina(caminho), { ignoreSearch: true })
  if (!r && semBarraFinal(caminho) === '/dashboard') r = await c.match(chavePagina('/dashboard/campo'), { ignoreSearch: true })
  return r
}

async function paginaOffline() {
  const r = await caches.match(PAGINA_OFFLINE)
  if (r) return r
  return new Response('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>Sem conexão</title><body style="font-family:sans-serif;padding:24px"><h1>Esta tela precisa de internet.</h1>' +
    '<p><a href="/dashboard/campo">Volte ao Painel</a></p></body>', { headers: { 'Content-Type': 'text/html; charset=utf-8' } })
}

async function navegacao(req, url) {
  const caminho = semBarraFinal(url.pathname)
  if (!telaOffline(caminho)) {
    try { return await fetch(req) } catch (e) { return paginaOffline() }
  }
  const rede = fetch(req).then(async (resp) => {
    if (resp.ok && !resp.redirected && resp.type === 'basic') {
      const c = await caches.open(CACHE_PAGINAS)
      await c.put(chavePagina(caminho), resp.clone())
      guardarRecursosDaPagina(resp.clone()).catch(() => {})
    }
    return resp
  })
  try {
    const resp = await comPrazo(rede, TEMPO_REDE_MS)
    if (resp) return resp
    const guardada = await paginaGuardada(caminho)
    return guardada || await rede
  } catch (e) {
    return (await paginaGuardada(caminho)) || paginaOffline()
  }
}

// Scripts e estilos citados no HTML (e as fontes citadas nos estilos): a página abre sem internet.
async function guardarRecursosDaPagina(resp) {
  const html = await resp.text()
  const achados = new Set()
  const re = /(?:src|href)="(\/_next\/static\/[^"]+)"/g
  let m
  while ((m = re.exec(html))) achados.add(m[1].replace(/&amp;/g, '&'))
  const re2 = /\\?"(\/_next\/static\/[^"\\]+\.(?:js|css))\\?"/g
  while ((m = re2.exec(html))) achados.add(m[1])
  for (const u of achados) {
    await guardarEstatico(u).catch(() => {})
    if (u.endsWith('.css')) {
      const css = await caches.match(u)
      if (css) {
        const texto = await css.clone().text()
        const reFonte = /url\((\/_next\/static\/media\/[^)]+)\)/g
        let f
        while ((f = reFonte.exec(texto))) await guardarEstatico(f[1]).catch(() => {})
      }
    }
  }
}

async function precarregar(urls) {
  for (const bruto of urls || []) {
    let url
    try { url = new URL(bruto, self.location.origin) } catch (e) { continue }
    if (url.origin !== self.location.origin) continue
    const caminho = semBarraFinal(url.pathname)
    if (!telaOffline(caminho)) continue
    try {
      const resp = await fetch(new Request(self.location.origin + caminho, { credentials: 'same-origin', redirect: 'follow' }))
      if (!resp.ok || resp.redirected) continue
      const c = await caches.open(CACHE_PAGINAS)
      await c.put(chavePagina(caminho), resp.clone())
      await guardarRecursosDaPagina(resp)
    } catch (e) { /* sem rede: tenta de novo na próxima */ }
  }
}

// ── Dados do Supabase por usuário ─────────────────────────────────────────────────────
function usuarioDoToken(auth) {
  if (!auth || !/^Bearer /i.test(auth)) return null
  try {
    const parte = auth.split(' ')[1].split('.')[1]
    const json = JSON.parse(atob(parte.replace(/-/g, '+').replace(/_/g, '/')))
    return json && json.role === 'authenticated' && json.sub ? json.sub : null
  } catch (e) { return null }
}

async function aparar(cache) {
  const chaves = await cache.keys()
  for (let i = 0; i < chaves.length - MAX_DADOS; i++) await cache.delete(chaves[i])
}

// Reconferência: a resposta tem de ser do servidor, agora. Sem rede (ou rede que não responde
// no prazo), o 504 SEM_CONEXAO; a tela guarda o registro e o servidor confere no envio.
async function somenteRede(req) {
  const ctrl = typeof AbortController === 'function' ? new AbortController() : null
  const t = ctrl ? setTimeout(() => ctrl.abort(), TEMPO_CONFERENCIA_MS) : null
  try {
    return await fetch(req, ctrl ? { signal: ctrl.signal, cache: 'no-store' } : { cache: 'no-store' })
  } catch (e) {
    return respostaSemConexao()
  } finally {
    if (t) clearTimeout(t)
  }
}

async function dadosRede(req) {
  const sub = usuarioDoToken(req.headers.get('authorization'))
  if (!sub) return fetch(req)
  const nome = PREFIXO_DADOS + sub
  const rede = fetch(req).then(async (resp) => {
    if (resp.ok) {
      const c = await caches.open(nome)
      await c.delete(req, { ignoreVary: true })
      await c.put(req, resp.clone())
      aparar(c).catch(() => {})
    }
    return resp
  })
  try {
    const resp = await comPrazo(rede, TEMPO_REDE_MS)
    if (resp) return resp
    const guardada = await (await caches.open(nome)).match(req, { ignoreVary: true })
    return guardada || await rede
  } catch (e) {
    const guardada = await (await caches.open(nome)).match(req, { ignoreVary: true })
    if (guardada) return guardada
    // A rede falhou e não há cópia: resposta imediata (o supabase-js não repete) e a tela usa
    // a cópia do aparelho. Não depende de navigator.onLine, que num SW recém-iniciado pode
    // continuar true sem rede.
    return respostaSemConexao()
  }
}

// ── Mensagens da página ───────────────────────────────────────────────────────────────
self.addEventListener('message', (event) => {
  const d = event.data || {}
  if (d.tipo === 'usuario' && d.authUserId) {
    // Troca de usuário: apaga a cópia de dados dos outros.
    event.waitUntil((async () => {
      for (const nome of await caches.keys()) {
        if (nome.startsWith(PREFIXO_DADOS) && nome !== PREFIXO_DADOS + d.authUserId) await caches.delete(nome)
      }
    })())
  } else if (d.tipo === 'sair' && d.authUserId) {
    event.waitUntil(caches.delete(PREFIXO_DADOS + d.authUserId))
  } else if (d.tipo === 'precarregar') {
    event.waitUntil(precarregar(d.urls))
  } else if (d.tipo === 'versao' && event.ports && event.ports[0]) {
    event.ports[0].postMessage({ versao: VERSAO })
  }
})
