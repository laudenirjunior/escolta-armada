/** @type {import('next').NextConfig} */
// Lote 2026-10: sem images.remotePatterns. O app não usa next/image, e o bloco só
// expunha a otimização de imagens (alvo do aviso crítico do npm audit no Next 14).
//
// Lote 2026-10 (onda L): o BUILD_ID é escolhido aqui e vai também para o código
// (ESCOLTA_BUILD_ID), para o service worker (/sw.js, app/sw.js/route.ts) trocar de versão a
// cada build e apagar as cópias da anterior.
// O next build carrega este arquivo em mais de um processo; o primeiro escolhe o id e os
// processos filhos o herdam pelo ambiente (senão cada um teria um Date.now diferente).
if (!process.env.ESCOLTA_BUILD_ID) {
  process.env.ESCOLTA_BUILD_ID = (process.env.VERCEL_GIT_COMMIT_SHA ? process.env.VERCEL_GIT_COMMIT_SHA.slice(0, 12) + '-' : 'b')
    + Date.now().toString(36)
}
const BUILD_ID = process.env.ESCOLTA_BUILD_ID

const nextConfig = {
  reactStrictMode: true,
  generateBuildId: async () => BUILD_ID,
  env: { ESCOLTA_BUILD_ID: BUILD_ID },
  // O cache do webpack nunca é necessário em tempo de execução; fora dele, nenhuma função
  // (em especial /sw.js, que lê arquivos de .next) arrasta centenas de MB para a Vercel.
  experimental: {
    outputFileTracingExcludes: {
      '*': ['.next/cache/**'],
      '/sw.js': ['.next/cache/**'],
    },
  },
}

export default nextConfig
