/**
 * Locais salvos (lote 2026-10, M2 e M1): atalhos de endereço com coordenada conferida no
 * mapa. Só os ativos viram atalho; a RLS só mostra os ativos a quem não é supervisor ou
 * acima (migration 205). Também alimentam o rótulo dos pontos de controle.
 */

export interface LocalSalvo {
  id: string
  nome: string
  endereco: string
  complemento: string | null
  latitude: number | null
  longitude: number | null
  situacao: 'ativo' | 'inativo' | 'aguardando_conferencia'
  fonte_coordenada: string | null
  conferido_em: string | null
  conferidor?: { nome_completo: string } | null
}

/** Quem cadastra e edita local salvo (decisão 5). */
export const PERFIS_CADASTRAM_LOCAL = ['administrador', 'gestor', 'supervisor']
/** Quem confere o pino e ativa (decisão 6: Peçanha ou Bruno). */
export const PERFIS_ATIVAM_LOCAL = ['administrador', 'gestor']

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function carregarLocaisAtivos(sb: any): Promise<LocalSalvo[]> {
  const { data, error } = await sb.from('locais_salvos')
    .select('id, nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, conferido_em')
    .eq('situacao', 'ativo').order('nome')
  return error ? [] : ((data ?? []) as LocalSalvo[]).map(l => ({ ...l, latitude: l.latitude != null ? Number(l.latitude) : null, longitude: l.longitude != null ? Number(l.longitude) : null }))
}

/** Distância em metros entre duas coordenadas (haversine). */
export function distanciaMetros(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000, t = Math.PI / 180
  const dLat = (lat2 - lat1) * t, dLng = (lng2 - lng1) * t
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * t) * Math.cos(lat2 * t) * Math.sin(dLng / 2) ** 2
  return Math.round(2 * R * Math.asin(Math.sqrt(a)))
}
