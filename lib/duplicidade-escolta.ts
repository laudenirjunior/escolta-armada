/**
 * Alerta de escolta duplicada (pedido de Peçanha em 2026-11-12). Ao criar uma escolta, a tela
 * avisa quando já existe outra parecida. É SÓ AVISO: o usuário segue ou desiste; nada é
 * bloqueado aqui nem no banco (duas escoltas iguais no mesmo dia podem ser legítimas, por
 * exemplo duas cargas do mesmo cliente na mesma rota).
 *
 * Critério (e por quê):
 * 1. Mesmo cliente, mesmo dia previsto em Brasília e mesma rota (origem E destino). É a
 *    duplicidade típica: duas pessoas da central lançando o mesmo pedido do cliente. O dia é o
 *    de Brasília (a partida às 22h de Brasília cai no dia seguinte em UTC). A hora não entra:
 *    quem lança de novo costuma errar a hora, não o dia.
 *    Mesmo lugar = endereço igual depois de normalizar (sem acento, caixa, pontuação e
 *    espaços repetidos) OU coordenadas a até 300 m. Toda escolta nasce com coordenada
 *    conferida no mapa (tela de criação), então a coordenada cobre o mesmo lugar escrito de
 *    outro jeito ("Av." e "Avenida", com e sem complemento); 300 m cabem num mesmo pátio ou
 *    galpão sem juntar dois clientes vizinhos de bairro. Comparar só cidade ou UF juntaria
 *    escoltas diferentes demais (toda escolta do Rio para o Rio).
 *    A rota invertida (origem e destino trocados) não conta: é a volta, outra operação.
 * 2. Mesma viatura (placa) no mesmo dia, de qualquer cliente: a viatura não faz duas escoltas
 *    ao mesmo tempo, e lançar a mesma placa duas vezes no dia costuma ser engano. Aviso mais
 *    fraco (pode ser uma escolta de manhã e outra à tarde).
 * Ficam de fora as canceladas, as arquivadas e as excluídas (estas a RLS já não devolve).
 *
 * Testes: node --test tests/duplicidade-escolta.test.ts
 */

export const FUSO_BRASILIA = 'America/Sao_Paulo'
/** Distância máxima, em metros, para dois pontos contarem como o mesmo lugar. */
export const RAIO_MESMO_LUGAR_M = 300

export interface EscoltaComparavel {
  id?: string
  codigo_escolta?: string | null
  status?: string | null
  cliente_id: string | null
  data_hora_prevista: string | null
  origem_endereco: string | null
  origem_lat: number | null
  origem_lng: number | null
  destino_endereco: string | null
  destino_lat: number | null
  destino_lng: number | null
  arquivada_em?: string | null
  excluida_em?: string | null
  /** Veículos (veiculos.id) das viaturas da escolta. */
  veiculo_ids?: string[]
}

export type MotivoParecida = 'mesma_rota' | 'mesma_viatura'

export interface EscoltaParecida {
  id: string
  codigo: string | null
  status: string | null
  dataHoraPrevista: string | null
  origem: string | null
  destino: string | null
  motivos: MotivoParecida[]
  /** Maior é mais parecida (ordena a lista). */
  pontos: number
}

/** Endereço comparável: sem acento, minúsculo, sem pontuação, espaços simples. */
export function normalizarEndereco(s: string | null | undefined): string {
  return String(s ?? '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .replace(/\s+/g, ' ')
}

/** Distância em metros (haversine). */
export function distanciaMetros(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6_371_000
  const rad = (g: number) => (g * Math.PI) / 180
  const dLat = rad(lat2 - lat1)
  const dLng = rad(lng2 - lng1)
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) ** 2
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)))
}

/** Coordenada utilizável (a zerada cai no golfo da Guiné e não vale). */
function coordValida(lat: number | null | undefined, lng: number | null | undefined): boolean {
  return typeof lat === 'number' && typeof lng === 'number' && Number.isFinite(lat) && Number.isFinite(lng) && !(lat === 0 && lng === 0)
}

export function mesmoLugar(
  a: { endereco: string | null; lat: number | null; lng: number | null },
  b: { endereco: string | null; lat: number | null; lng: number | null },
): boolean {
  const na = normalizarEndereco(a.endereco)
  if (na && na === normalizarEndereco(b.endereco)) return true
  if (coordValida(a.lat, a.lng) && coordValida(b.lat, b.lng)) {
    return distanciaMetros(a.lat as number, a.lng as number, b.lat as number, b.lng as number) <= RAIO_MESMO_LUGAR_M
  }
  return false
}

/** Dia (AAAA-MM-DD) de um instante em Brasília; vazio se inválido. */
export function diaBrasilia(iso: string | null | undefined): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return new Intl.DateTimeFormat('en-CA', { timeZone: FUSO_BRASILIA, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d)
}

/**
 * Janela da consulta: um dia a mais para cada lado, em UTC, para não depender do fuso do
 * aparelho; o recorte exato pelo dia de Brasília é feito em encontrarParecidas.
 */
export function janelaDeBusca(iso: string): { desde: string; ate: string } {
  const t = new Date(iso).getTime()
  return { desde: new Date(t - 36 * 3600_000).toISOString(), ate: new Date(t + 36 * 3600_000).toISOString() }
}

const FORA: string[] = ['cancelada']

/** Escoltas parecidas com a nova, da mais para a menos parecida. Só aviso. */
export function encontrarParecidas(nova: EscoltaComparavel, existentes: EscoltaComparavel[]): EscoltaParecida[] {
  const dia = diaBrasilia(nova.data_hora_prevista)
  if (!dia) return []
  const veiculos = new Set((nova.veiculo_ids ?? []).filter(Boolean))
  const r: EscoltaParecida[] = []
  for (const e of existentes) {
    if (!e.id || (nova.id && e.id === nova.id)) continue
    if (FORA.includes(e.status ?? '') || e.arquivada_em || e.excluida_em) continue
    if (diaBrasilia(e.data_hora_prevista) !== dia) continue
    const motivos: MotivoParecida[] = []
    if (nova.cliente_id && e.cliente_id === nova.cliente_id
        && mesmoLugar({ endereco: nova.origem_endereco, lat: nova.origem_lat, lng: nova.origem_lng },
                      { endereco: e.origem_endereco, lat: e.origem_lat, lng: e.origem_lng })
        && mesmoLugar({ endereco: nova.destino_endereco, lat: nova.destino_lat, lng: nova.destino_lng },
                      { endereco: e.destino_endereco, lat: e.destino_lat, lng: e.destino_lng })) {
      motivos.push('mesma_rota')
    }
    if ((e.veiculo_ids ?? []).some(v => veiculos.has(v))) motivos.push('mesma_viatura')
    if (motivos.length === 0) continue
    // Rota vale mais que viatura; as duas juntas, mais ainda. Hora mais perto desempata.
    const dif = Math.abs(new Date(e.data_hora_prevista ?? 0).getTime() - new Date(nova.data_hora_prevista ?? 0).getTime())
    const pontos = (motivos.includes('mesma_rota') ? 100 : 0) + (motivos.includes('mesma_viatura') ? 50 : 0)
      + Math.max(0, 24 - Math.floor(dif / 3600_000))
    r.push({
      id: e.id, codigo: e.codigo_escolta ?? null, status: e.status ?? null, dataHoraPrevista: e.data_hora_prevista,
      origem: e.origem_endereco, destino: e.destino_endereco, motivos, pontos,
    })
  }
  return r.sort((a, b) => b.pontos - a.pontos)
}

export function textoMotivos(m: MotivoParecida[]): string {
  const partes: string[] = []
  if (m.includes('mesma_rota')) partes.push('mesmo cliente, mesmo dia e mesma rota')
  if (m.includes('mesma_viatura')) partes.push('mesma viatura no mesmo dia')
  return partes.join('; ')
}
