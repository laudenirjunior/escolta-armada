/**
 * Leitura de GPS com nova tentativa quando a precisão é ruim (onda M, B3).
 *
 * Antes: uma leitura de alta precisão (15 s) e, se falhasse, uma de rede (10 s, cache de
 * 30 s). A precisão era gravada (precisao_metros), mas uma leitura de 800 m valia igual a
 * uma de 10 m. Agora, se a primeira leitura vier pior que PRECISAO_BOA_M, o aparelho
 * continua ouvindo o GPS por até NOVA_TENTATIVA_MS e grava a melhor leitura do período.
 * Nunca piora: a leitura inicial é guardada e só é trocada por outra mais precisa.
 * A precisão volta junto, para a tela mostrar ao operador.
 */
export interface LeituraGps { lat: number; lng: number; precisao: number }

export const PRECISAO_BOA_M = 100
export const NOVA_TENTATIVA_MS = 10_000

type Geo = Pick<Geolocation, 'getCurrentPosition' | 'watchPosition' | 'clearWatch'>

function paraLeitura(p: GeolocationPosition): LeituraGps {
  return { lat: p.coords.latitude, lng: p.coords.longitude, precisao: p.coords.accuracy }
}

function lerUmaVez(geo: Geo, alta: boolean, timeout: number, maximumAge: number): Promise<LeituraGps> {
  return new Promise((resolve, reject) => {
    geo.getCurrentPosition((p) => resolve(paraLeitura(p)), reject, { enableHighAccuracy: alta, timeout, maximumAge })
  })
}

/** Ouve o GPS por até `ms` e devolve a melhor leitura (ou a inicial, se nada melhorar). */
export function melhorarLeitura(geo: Geo, inicial: LeituraGps, ms = NOVA_TENTATIVA_MS): Promise<LeituraGps> {
  return new Promise((resolve) => {
    let melhor = inicial
    let id: number | null = null
    const fim = () => {
      if (id !== null) { try { geo.clearWatch(id) } catch { /* nada */ } }
      clearTimeout(relogio)
      resolve(melhor)
    }
    const relogio = setTimeout(fim, ms)
    try {
      id = geo.watchPosition(
        (p) => {
          const l = paraLeitura(p)
          if (l.precisao < melhor.precisao) melhor = l
          if (melhor.precisao <= PRECISAO_BOA_M) fim()
        },
        () => { /* erro na nova tentativa: fica a leitura que já existe */ },
        { enableHighAccuracy: true, timeout: ms, maximumAge: 0 },
      )
    } catch {
      fim()
    }
  })
}

export async function obterGpsPreciso(geo: Geo | undefined = typeof navigator !== 'undefined' ? navigator.geolocation : undefined): Promise<LeituraGps> {
  if (!geo) throw new Error('GPS não disponível neste dispositivo')
  let leitura: LeituraGps
  try {
    leitura = await lerUmaVez(geo, true, 15000, 0)
  } catch {
    leitura = await lerUmaVez(geo, false, 10000, 30000)
  }
  if (leitura.precisao > PRECISAO_BOA_M) leitura = await melhorarLeitura(geo, leitura)
  return leitura
}

/** Texto curto da precisão para a tela ("GPS ±35 m" ou "GPS impreciso: ±420 m"). */
export function textoPrecisao(precisao: number | null | undefined): string {
  if (precisao == null || !Number.isFinite(precisao)) return 'GPS sem precisão informada'
  const m = Math.round(precisao)
  return m > PRECISAO_BOA_M ? `GPS impreciso: ±${m} m` : `GPS ±${m} m`
}
