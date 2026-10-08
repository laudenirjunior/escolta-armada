/** @type {import('next').NextConfig} */
// Lote 2026-10: sem images.remotePatterns. O app não usa next/image, e o bloco só
// expunha a otimização de imagens (alvo do aviso crítico do npm audit no Next 14).
const nextConfig = {
  reactStrictMode: true,
}

export default nextConfig
