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
 * com a coordenada (fila sem internet, ou check-in sem resposta da Mapbox). A rota
 * (/api/pontos/endereco) lê com a RLS de quem chama e grava uma única vez.
 *
 * Revisão cruzada (2.2): o pedido não é mais descartável. As escoltas ficam numa lista no
 * aparelho (localStorage, por conveniência; sem ele vale só a tentativa da hora) até a rota
 * responder sem pendências; a próxima rodada de envio da fila tenta de novo. Erro nunca vai
 * à tela: o ponto continua com a coordenada, que é a verdade.
 */
const CHAVE_PENDENTES = 'escolta.endereco.pendentes'

function lerPendentesEndereco(): string[] {
  try { const v = JSON.parse(localStorage.getItem(CHAVE_PENDENTES) ?? '[]'); return Array.isArray(v) ? v.filter((x) => typeof x === 'string') : [] } catch { return [] }
}
function gravarPendentesEndereco(lista: string[]): void {
  try { if (lista.length) localStorage.setItem(CHAVE_PENDENTES, JSON.stringify(lista.slice(-30))); else localStorage.removeItem(CHAVE_PENDENTES) } catch { /* só conveniência */ }
}

export function pedirEnderecoDepois(escoltaIds: Array<string | null | undefined>, f: typeof fetch = fetch): void {
  const novas = escoltaIds.filter((e): e is string => !!e)
  const todas = Array.from(new Set([...lerPendentesEndereco(), ...novas]))
  if (todas.length === 0) return
  gravarPendentesEndereco(todas)
  const lote = todas.slice(0, 10)
  try {
    void f('/api/pontos/endereco', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ escoltas: lote }),
    }).then(async (r) => {
      if (!r.ok) return
      const d = await r.json().catch(() => null) as { pendentes?: number } | null
      // Sem pendências: estas escoltas saem da lista; com pendências, ficam para a próxima.
      if (d && d.pendentes === 0) gravarPendentesEndereco(lerPendentesEndereco().filter((e) => !lote.includes(e)))
    }).catch(() => {})
  } catch { /* sem fetch: fica para a próxima rodada */ }
}

/** Há escoltas esperando o endereço dos pontos (a rodada de envio tenta de novo). */
export function temEnderecoPendente(): boolean {
  return lerPendentesEndereco().length > 0
}
