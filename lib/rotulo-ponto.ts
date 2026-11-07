/**
 * Rótulo de um ponto de controle (lote 2026-10, M1).
 *
 * A coordenada do GPS é a verdade. O endereço por extenso vem da geocodificação reversa
 * e, perto de divisa de município (caso da JAMEF, em São João de Meriti), pode trazer o
 * bairro ou o município vizinho mesmo com a coordenada certa. Por isso: ponto a até
 * 100 m de um local salvo ativo mostra o local (nome e endereço conferidos); senão, o
 * endereço reverso aparece marcado como aproximado, com a precisão do GPS.
 */
import { LocalSalvo, distanciaMetros } from './locais'

export const RAIO_LOCAL_M = 100

export function rotuloDoPonto(
  p: { latitude: number | null; longitude: number | null; precisao_metros?: number | null; endereco?: string | null },
  locais: LocalSalvo[],
): string | null {
  if (p.latitude == null || p.longitude == null) return null
  let melhor: { l: LocalSalvo; d: number } | null = null
  for (const l of locais) {
    if (l.situacao !== 'ativo' || l.latitude == null || l.longitude == null) continue
    const d = distanciaMetros(Number(p.latitude), Number(p.longitude), l.latitude, l.longitude)
    if (d <= RAIO_LOCAL_M && (!melhor || d < melhor.d)) melhor = { l, d }
  }
  if (melhor) return `Local: ${melhor.l.nome}, ${melhor.l.endereco} (a ${melhor.d} m)`
  if (p.endereco) {
    const prec = p.precisao_metros != null ? `, GPS ±${Math.round(Number(p.precisao_metros))} m` : ''
    return `${p.endereco} (endereço aproximado${prec})`
  }
  return null
}
