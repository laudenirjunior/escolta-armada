/**
 * UF de um endereço escolhido na busca da Mapbox (lote 2026-10, onda K; docs/14, 15.2 item 4).
 *
 * A Mapbox Geocoding v5 devolve a unidade federativa no `context`, no item cujo id começa
 * com "region.", com `short_code` no formato ISO 3166-2 ("BR-RJ"). Quando a própria
 * sugestão é do tipo region, o `short_code` vem em `properties`. Sem region (POI sem
 * endereço completo, por exemplo), não há UF aqui: a Nova pergunta ao banco pela
 * coordenada (RPC uf_da_coordenada, migration 216).
 *
 * Este arquivo não importa nada: o teste de unidade roda direto no Node com as respostas
 * gravadas da documentação oficial (escolta-homolog/e2e/k_uf_mapbox.test.mjs).
 */

export const UFS_BRASIL = [
  'AC', 'AL', 'AM', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MG', 'MS', 'MT', 'PA',
  'PB', 'PE', 'PI', 'PR', 'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO',
]

export interface SugestaoMapboxUf {
  place_type?: string[]
  properties?: { short_code?: string } | null
  context?: { id: string; short_code?: string }[] | null
}

/** "BR-RJ" (sem diferenciar maiúscula) vira "RJ"; qualquer outra coisa, null. */
export function ufDoShortCode(codigo: string | null | undefined): string | null {
  if (!codigo) return null
  const m = /^BR-([A-Z]{2})$/.exec(codigo.trim().toUpperCase())
  return m && UFS_BRASIL.includes(m[1]) ? m[1] : null
}

/** UF da sugestão da Mapbox: region do context, ou a própria sugestão do tipo region. */
export function ufDaSugestaoMapbox(f: SugestaoMapboxUf | null | undefined): string | null {
  if (!f) return null
  if ((f.place_type ?? []).includes('region')) {
    const propria = ufDoShortCode(f.properties?.short_code)
    if (propria) return propria
  }
  const regiao = (f.context ?? []).find(c => typeof c?.id === 'string' && c.id.startsWith('region.'))
  return ufDoShortCode(regiao?.short_code)
}

export interface UfsEscolta {
  origem_uf?: string | null
  destino_uf?: string | null
  origem_uf_estimada?: boolean | null
  destino_uf_estimada?: boolean | null
  interestadual?: boolean | null
}

/**
 * Texto da etiqueta Interestadual (detalhe, impressão e PDF). Com as duas UFs conhecidas e
 * nenhuma estimada pela coordenada, "Interestadual: RJ para SP"; com qualquer lado estimado
 * (ou fora do Brasil), só "Interestadual", sem a UF vizinha por extenso (docs/14, 15.1 item 5).
 */
export function textoInterestadual(e: UfsEscolta): string {
  if (!e.origem_uf_estimada && !e.destino_uf_estimada && e.origem_uf && e.destino_uf) return `Interestadual: ${e.origem_uf} para ${e.destino_uf}`
  return 'Interestadual'
}

/** Sim, Não ou Não determinado (coluna gerada interestadual), para o CSV e o relatório. */
export function rotuloInterestadual(e: Pick<UfsEscolta, 'interestadual'>): string {
  return e.interestadual === true ? 'Sim' : e.interestadual === false ? 'Não' : 'Não determinado'
}
