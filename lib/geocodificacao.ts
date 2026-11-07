/**
 * Endereço por extenso de uma coordenada (geocodificação reversa da Mapbox v5), a mesma
 * chamada da tela de detalhe. Lote 2026-10 (onda F): o check-in pelo Campo e pelo Painel
 * Guiado passa a gravar o endereço, como a tela de detalhe já fazia. É só rótulo: a
 * coordenada do GPS continua sendo a verdade (lib/rotulo-ponto.ts).
 * Sem token, sem rede ou sem resultado, devolve null e o ponto fica só com a coordenada.
 */
export async function enderecoPorExtenso(lat: number, lng: number, timeoutMs = 4000): Promise<string | null> {
  // Onda M: no servidor (rota /api/pontos/endereco) valem também MAPBOX_TOKEN e MAPBOX_API_BASE,
  // lidas na hora (não entram no pacote do navegador). MAPBOX_API_BASE existe só para a
  // homologação apontar para uma Mapbox falsa, como TELEGRAM_API_BASE no Telegram.
  const noServidor = typeof window === 'undefined'
  const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN || (noServidor ? process.env.MAPBOX_TOKEN : undefined)
  const base = (noServidor && process.env.MAPBOX_API_BASE) || 'https://api.mapbox.com'
  if (!token) return null
  const controle = new AbortController()
  const t = setTimeout(() => controle.abort(), timeoutMs)
  try {
    const res = await fetch(
      `${base}/geocoding/v5/mapbox.places/${lng},${lat}.json?access_token=${token}&language=pt&types=address,neighborhood,place&limit=1`,
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

/**
 * Onda M (B2): pede ao servidor o endereço por extenso dos pontos que chegaram ao banco só
 * com a coordenada (fila sem internet, ou check-in sem resposta da Mapbox). Uma chamada por
 * envio, sem esperar e sem erro na tela: falhou, o ponto continua com a coordenada, que é a
 * verdade. A rota (/api/pontos/endereco) lê com a RLS de quem chama e grava uma única vez.
 */
export function pedirEnderecoDepois(escoltaIds: Array<string | null | undefined>, f: typeof fetch = fetch): void {
  const escoltas = Array.from(new Set(escoltaIds.filter((e): e is string => !!e))).slice(0, 10)
  if (escoltas.length === 0) return
  try {
    void f('/api/pontos/endereco', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ escoltas }),
    }).catch(() => {})
  } catch { /* sem fetch: fica só a coordenada */ }
}
