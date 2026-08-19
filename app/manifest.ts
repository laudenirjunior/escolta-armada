import type { MetadataRoute } from 'next'

/**
 * Servido em /manifest.webmanifest. O Next injeta a tag <link rel="manifest">
 * sozinho, por isso nao existe public/manifest.json em paralelo nem link escrito
 * a mao: dois manifestos concorrentes e a forma classica de o navegador instalar
 * a versao errada.
 *
 * Os icones sao PNG gerados a partir do mesmo escudo da tela de login. PNG, e nao
 * SVG, porque o iOS ignora por completo o array de icones do manifesto e so aceita
 * o apple-touch-icon em PNG: app/apple-icon.png, que o Next serve sozinho.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    id: '/dashboard',
    start_url: '/dashboard',
    scope: '/',
    name: 'Escolta Armada | Controle Operacional',
    short_name: 'Escolta',
    description:
      'Controle operacional de escolta armada: jornada, pontos de controle, fotos e georreferenciamento.',
    lang: 'pt-BR',
    dir: 'ltr',
    display: 'standalone',
    orientation: 'portrait',
    background_color: '#1A294A',
    theme_color: '#1A294A',
    icons: [
      { src: '/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: '/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      // O maskable traz o escudo menor, dentro dos 80% centrais, e o fundo sangrando
      // ate a borda: o Android recorta a moldura na forma do sistema do aparelho.
      { src: '/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
  }
}
