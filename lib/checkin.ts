/**
 * Check-in periodico: regra de atraso e gravacao, em um lugar so.
 *
 * Antes havia duas regras de atraso divergentes. O alerta global
 * (components/checkin-alert-provider.tsx) contava qualquer ponto PARADA como
 * check-in e ignorava a escolta que ainda nao tinha nenhum. A tela de detalhe
 * contava so o `reporte_periodico` e, sem nenhum, media a partir da data prevista.
 * O mesmo check-in podia estar "atrasado" numa tela e "em dia" na outra.
 *
 * A gravacao saiu da tela de detalhe para o modo guiado da tela de Campo usar a
 * mesma funcao. Fica aqui SO o insert do ponto: upload de foto e Telegram continuam
 * com quem chama, porque as duas telas sobem foto de formas diferentes (o Campo
 * carimba a imagem, a tela de detalhe ainda nao).
 */

import { lerObservacao, serializarObservacao } from './pontos-controle'
import { STATUS } from './fluxo-escolta'

/** O check-in grava no tipo de ponto PARADA, marcado como reporte periodico. */
export const TIPO_PONTO_PARADA_ID = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
export const TIPO_CHECKIN = 'reporte_periodico'
export const ROTULO_CHECKIN = 'Reporte Periódico'

/** Etapas em que a escolta esta na rua e o check-in periodico vale. */
export const STATUS_COM_CHECKIN: string[] = [
  STATUS.EM_ANDAMENTO,
  STATUS.NA_ORIGEM,
  STATUS.EM_TRANSITO_DESTINO,
  STATUS.NO_DESTINO,
  STATUS.EM_TRANSITO_RETORNO,
  STATUS.RETORNANDO,
]

interface PontoLido {
  data_hora: string
  observacoes: string | null
}

export function ehPontoCheckin(p: PontoLido): boolean {
  return lerObservacao(p.observacoes).tipo === TIPO_CHECKIN
}

/** Horario do check-in mais recente entre os pontos informados, ou null. */
export function ultimoCheckinEm(pontos: PontoLido[]): string | null {
  const datas = pontos.filter(ehPontoCheckin).map((p) => p.data_hora).sort()
  return datas.length ? datas[datas.length - 1] : null
}

/** Horario do primeiro ponto de controle da escolta, que marca a saida para a rua. */
export function inicioOperacaoEm(pontos: { data_hora: string }[]): string | null {
  const datas = pontos.map((p) => p.data_hora).sort()
  return datas.length ? datas[0] : null
}

/**
 * Minutos ate o proximo check-in. Negativo e atraso. Null quando nao se aplica
 * (periodicidade desligada ou escolta fora da rua).
 *
 * Referencia, nesta ordem: o ultimo check-in; sem nenhum, o primeiro ponto da
 * escolta (a saida da base); sem nenhum ponto, a data prevista. A data prevista
 * sozinha acusava atraso no primeiro minuto de uma escolta que saiu com horas de
 * atraso sobre o agendado.
 */
export function minutosAteCheckin(params: {
  periodicidadeMin: number | null | undefined
  status: string
  ultimoCheckin: string | null
  inicioOperacao: string | null
  dataHoraPrevista: string | null
  agora?: number
}): number | null {
  const { periodicidadeMin, status } = params
  if (!periodicidadeMin || !STATUS_COM_CHECKIN.includes(status)) return null
  const referencia = params.ultimoCheckin ?? params.inicioOperacao ?? params.dataHoraPrevista
  if (!referencia) return null
  const agora = params.agora ?? Date.now()
  const diff = periodicidadeMin * 60_000 - (agora - new Date(referencia).getTime())
  return Math.floor(diff / 60_000)
}

/**
 * Grava o ponto do check-in e devolve o id.
 *
 * Exige GPS, como sempre exigiu: o check-in existe para dizer onde a equipe esta.
 * Le as linhas afetadas, porque insert negado pela RLS pode voltar sem erro e sem
 * linha.
 */
export async function registrarCheckin(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  sb: any,
  dados: {
    escoltaVeiculoId: string
    fotoIds: string[]
    gps: { lat: number; lng: number; precisao: number }
    observacao: string | null
    endereco?: string | null
    userId: string | null
  },
): Promise<string> {
  const { data, error } = await sb
    .from('pontos_controle')
    .insert({
      escolta_veiculo_id: dados.escoltaVeiculoId,
      tipo_ponto_id: TIPO_PONTO_PARADA_ID,
      data_hora: new Date().toISOString(),
      latitude: dados.gps.lat,
      longitude: dados.gps.lng,
      precisao_metros: dados.gps.precisao,
      sem_sinal_gps: false,
      foto_id: dados.fotoIds[0] ?? null,
      lancado_por: dados.userId,
      observacoes: serializarObservacao({
        tipo: TIPO_CHECKIN,
        tipoLabel: ROTULO_CHECKIN,
        observacao: dados.observacao,
        fotoIds: dados.fotoIds,
        endereco: dados.endereco ?? null,
      }),
      sincronizado: true,
    })
    .select('id')
  if (error) throw new Error(error.message)
  if (!data || data.length === 0) {
    throw new Error('O check-in não foi aceito pelo sistema. Confira se você está vinculado a esta escolta.')
  }
  return data[0].id as string
}
