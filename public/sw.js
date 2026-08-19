/**
 * Service worker de escopo minimo, com ZERO CACHE. Deliberadamente.
 *
 * POR QUE NAO HA CACHE AQUI, E POR QUE NAO PODE HAVER:
 * um service worker cache-first e exatamente o que serve pagina velha depois de
 * um deploy. O usuario atualiza, o worker devolve o bundle antigo do cache, o
 * codigo corrigido fica invisivel e o defeito parece nao ter sido resolvido.
 * Este projeto ja perdeu tempo com bundle velho servido em producao; repetir o
 * problema por conta propria, do lado do cliente, seria pior, porque um cache
 * de service worker sobrevive a limpeza normal do navegador.
 *
 * Este arquivo existe por um unico motivo: o Chrome no Android so considera o
 * site instalavel se houver um service worker registrado com handler de fetch.
 * O handler abaixo e vazio de proposito, sem event.respondWith e sem caches.open,
 * entao toda requisicao segue direto para a rede, como se o worker nao existisse.
 *
 * Offline de verdade e outra entrega, com estrategia network-first e
 * versionamento de cache. NAO acrescente cache aqui sem essa decisao.
 */

self.addEventListener('install', () => {
  // Assume o controle sem esperar as abas antigas fecharem.
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim())
})

// Handler vazio: existe para satisfazer o criterio de instalabilidade e nada mais.
// Sem respondWith, o navegador trata a requisicao normalmente, pela rede.
self.addEventListener('fetch', () => {})
