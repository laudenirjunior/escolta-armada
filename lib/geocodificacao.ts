/**
 * Endereço por extenso de uma coordenada (geocodificação reversa da Mapbox v5), a mesma
 * chamada da tela de detalhe. Lote 2026-10 (onda F): o check-in pelo Campo e pelo Painel
 * Guiado passa a gravar o endereço, como a tela de detalhe já fazia. É só rótulo: a
 * coordenada do GPS continua sendo a verdade (lib/rotulo-ponto.ts).
 * Sem token, sem rede ou sem resultado, devolve null e o ponto fica só com a coordenada.
 */
export async function enderecoPorExtenso(lat: number, lng: number, timeoutMs = 4000): Promise<string | null> {
  const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN
  if (!token) return null
  const controle = new AbortController()
  const t = setTimeout(() => controle.abort(), timeoutMs)
  try {
    const res = await fetch(
      `https://api.mapbox.com/geocoding/v5/mapbox.places/${lng},${lat}.json?access_token=${token}&language=pt&types=address,neighborhood,place&limit=1`,
      { signal: controle.signal },
    )
    if (!res.ok) return null
    const data = await res.json()
    return data.features?.[0]?.place_name ?? null
  } catch {
    return null
  } finally {
    clearTimeout(t)
  }
}
