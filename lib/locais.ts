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
  /** UF do local (migration 215); o atalho a leva para a escolta quando a onda K existir. */
  uf?: string | null
  /** Quantas vezes o local virou origem ou destino de escolta (trigger da 215). */
  vezes_usado?: number
}

/** As 27 UFs, para o cadastro do local e o "Salvar este endereço". */
export const UFS = ['AC', 'AL', 'AM', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MG', 'MS', 'MT', 'PA', 'PB', 'PE',
  'PI', 'PR', 'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO']

/** Quem cadastra e edita local salvo (decisão 5). */
export const PERFIS_CADASTRAM_LOCAL = ['administrador', 'gestor', 'supervisor']
/** Quem confere o pino e ativa (decisão 6: Peçanha ou Bruno). */
export const PERFIS_ATIVAM_LOCAL = ['administrador', 'gestor']

/**
 * Atalhos ativos, os mais usados primeiro (vezes_usado DESC, nome; onda D2). Sem a 215 no
 * banco (colunas uf e vezes_usado ausentes), cai na consulta da onda D, por nome.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function carregarLocaisAtivos(sb: any): Promise<LocalSalvo[]> {
  const base = 'id, nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, conferido_em'
  let r = await sb.from('locais_salvos').select(`${base}, uf, vezes_usado`)
    .eq('situacao', 'ativo').order('vezes_usado', { ascending: false }).order('nome')
  if (r.error) r = await sb.from('locais_salvos').select(base).eq('situacao', 'ativo').order('nome')
  return r.error ? [] : ((r.data ?? []) as LocalSalvo[]).map(l => ({ ...l, latitude: l.latitude != null ? Number(l.latitude) : null, longitude: l.longitude != null ? Number(l.longitude) : null }))
}

/**
 * A escolta já tem as colunas de UF (onda K, migration 216)? Sem elas, a UF que o atalho
 * preenche fica só na tela e não vai para o INSERT (gravar coluna inexistente derrubaria a
 * criação). A editar_escolta (218) já ignora sozinha as colunas que não existem.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function escoltaTemUf(sb: any): Promise<boolean> {
  const { error } = await sb.from('escoltas').select('origem_uf, destino_uf').limit(0)
  return !error
}

/** Distância em metros entre duas coordenadas (haversine). */
export function distanciaMetros(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000, t = Math.PI / 180
  const dLat = (lat2 - lat1) * t, dLng = (lng2 - lng1) * t
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * t) * Math.cos(lat2 * t) * Math.sin(dLng / 2) ** 2
  return Math.round(2 * R * Math.asin(Math.sqrt(a)))
}
