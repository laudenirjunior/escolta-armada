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

/**
 * Leitura rápida para o carimbo da foto na tela de detalhe (onda M): aceita leitura de até
 * 5 s e espera no máximo 4 s. Sem sinal, devolve null e o carimbo diz "SEM SINAL DE GPS".
 * A coordenada gravada no ponto continua sendo a do registro (obterGpsPreciso).
 */
export function gpsRapido(geo: Geo | undefined = typeof navigator !== 'undefined' ? navigator.geolocation : undefined): Promise<LeituraGps | null> {
  if (!geo) return Promise.resolve(null)
  // Onda O (A2): leitura de até 5 s sai na hora; com o GPS contínuo ligado, a última leitura
  // (até 60 s) é a posição atual, porque a observação só avisa quando a posição muda. Sem isto
  // a foto esperava até 4 s por uma leitura nova com o aparelho parado (achado no h_wizard).
  if (atual) {
    const idade = Date.now() - atual.em
    if (idade <= 5_000 || (idObservacao !== null && idade <= IDADE_MAXIMA_GPS_MS)) {
      return Promise.resolve({ lat: atual.lat, lng: atual.lng, precisao: atual.precisao })
    }
  }
  // Revisão cruzada (2.7): leitura de no máximo 5 s atrás. Sem leitura nova, o carimbo diz
  // "SEM SINAL DE GPS", mais honesto que uma coordenada de um minuto antes.
  return lerUmaVez(geo, false, 4000, 5_000).catch(() => null)
}

// ── Onda O (A2): GPS sem travar a etapa ────────────────────────────────────────────────
// No teste de 07/11 cada etapa esperou 12 a 13 s pelo GPS. Agora a leitura começa quando a
// janela abre (ou o assistente de partida aparece) e segue ligada enquanto a tela estiver
// aberta (watchPosition, leitura de até 60 s atrás). O Confirmar fica livre em no máximo 3 s
// com a melhor leitura disponível; leitura melhor que chegar depois troca o ponto na tela.

/** Leitura aceita como atual (60 s). */
export const IDADE_MAXIMA_GPS_MS = 60_000
/** Espera máxima pelo GPS antes de liberar o Confirmar. */
export const ESPERA_CONFIRMAR_MS = 3_000

interface LeituraDatada extends LeituraGps { em: number }

let atual: LeituraDatada | null = null
let idObservacao: number | null = null
let usuarios = 0
const ouvintesGps = new Set<(l: LeituraGps) => void>()

function geoPadrao(): Geo | undefined {
  return typeof navigator !== 'undefined' ? navigator.geolocation : undefined
}

/**
 * Troca a leitura guardada quando a nova é mais precisa, ou quando a guardada passou de 15 s
 * (a viatura anda: posição nova de precisão boa vale mais que uma antiga).
 */
export function aceitarLeitura(nova: LeituraGps, agora = Date.now()): boolean {
  const velha = atual
  const melhor = !velha
    || agora - velha.em > IDADE_MAXIMA_GPS_MS
    || nova.precisao <= velha.precisao
    || (agora - velha.em > 15_000 && nova.precisao <= Math.max(velha.precisao, PRECISAO_BOA_M))
  if (!melhor) return false
  atual = { ...nova, em: agora }
  for (const fn of ouvintesGps) { try { fn(nova) } catch { /* ouvinte não derruba o GPS */ } }
  return true
}

/** A leitura guardada, se tiver até 60 s. */
export function leituraAtualGps(agora = Date.now()): LeituraGps | null {
  if (!atual || agora - atual.em > IDADE_MAXIMA_GPS_MS) return null
  return { lat: atual.lat, lng: atual.lng, precisao: atual.precisao }
}

/**
 * Liga o GPS contínuo (uma observação para a página inteira, com contagem de quem usa) e
 * pede uma leitura rápida de rede, que costuma chegar antes da de satélite. Devolve a função
 * que desliga a parte deste usuário.
 */
export function iniciarRastreioGps(geo: Geo | undefined = geoPadrao()): () => void {
  if (!geo) return () => {}
  usuarios++
  if (idObservacao === null) {
    try {
      idObservacao = geo.watchPosition(
        (p) => { aceitarLeitura(paraLeitura(p)) },
        () => { /* sem sinal: fica a última leitura */ },
        { enableHighAccuracy: true, maximumAge: IDADE_MAXIMA_GPS_MS, timeout: 30_000 },
      )
    } catch { idObservacao = null }
    lerUmaVez(geo, false, 10_000, IDADE_MAXIMA_GPS_MS).then(aceitarLeitura).catch(() => {})
  }
  let parado = false
  return () => {
    if (parado) return
    parado = true
    usuarios = Math.max(0, usuarios - 1)
    if (usuarios === 0 && idObservacao !== null) {
      try { geo.clearWatch(idObservacao) } catch { /* nada */ }
      idObservacao = null
    }
  }
}

/** Avisa a cada leitura aceita (a tela troca o ponto quando chega uma melhor). */
export function assinarGps(fn: (l: LeituraGps) => void): () => void {
  ouvintesGps.add(fn)
  return () => { ouvintesGps.delete(fn) }
}

/**
 * Melhor leitura disponível em no máximo `ms` (padrão 3 s): a guardada na hora, senão a
 * primeira que chegar. Sem nenhuma, devolve null (o ponto vai como "sem sinal de GPS").
 */
export function leituraParaConfirmar(ms = ESPERA_CONFIRMAR_MS, geo: Geo | undefined = geoPadrao()): Promise<LeituraGps | null> {
  const ja = leituraAtualGps()
  if (ja || !geo) return Promise.resolve(ja)
  const parar = iniciarRastreioGps(geo)
  return new Promise((resolve) => {
    let feito = false
    const fim = (l: LeituraGps | null) => {
      if (feito) return
      feito = true
      clearTimeout(relogio); sair(); parar()
      resolve(l)
    }
    const sair = assinarGps((l) => fim(l))
    const relogio = setTimeout(() => fim(leituraAtualGps()), ms)
  })
}

/** Só para os testes. */
export function reiniciarGps(): void {
  atual = null; idObservacao = null; usuarios = 0; ouvintesGps.clear()
}
