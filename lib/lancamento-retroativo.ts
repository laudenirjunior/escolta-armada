/**
 * Lançamento retroativo (pedido de Peçanha em 2026-11-12): a gestão lança depois do fato as
 * etapas de uma escolta que aconteceu, mas não foi registrada na hora, com os horários reais.
 *
 * Quem garante a regra é o banco (migration 222, public.lancar_escolta_retroativa): só gestor e
 * administrador, sequência sem pular e sem repetir até Finalizada, horários crescentes, nada no
 * futuro, até 30 dias, depois do último registro, motivo de 10 caracteres. Aqui ficam as mesmas
 * regras para a tela avisar antes de chamar, a conversão do horário de Brasília para ISO com o
 * fuso certo e a montagem do p_etapas.
 *
 * Testes: node --test tests/lancamento-retroativo.test.ts
 */
import { LABELS_STATUS, SEQUENCIA_STATUS, STATUS, TIPO_PONTO_POR_STATUS, FOTOS_POR_PONTO } from './fluxo-escolta.ts'
import { ehGestorOuAdmin } from './permissions.ts'

type Perfil = string | null | undefined

export const FUSO_BRASILIA = 'America/Sao_Paulo'
export const MOTIVO_MINIMO = 10
export const MOTIVO_MAXIMO = 1000
export const OBSERVACAO_MAXIMA = 500
/** Tolerância para relógio adiantado (o banco usa a mesma). */
export const TOLERANCIA_FUTURO_MS = 5 * 60_000
/** Antiguidade máxima do lançamento (o banco usa a mesma). */
export const LIMITE_DIAS = 30

/** Status de partida aceitos: Agendada até Na Base (lote_interno.retroativo_partidas). */
export const STATUS_PARTIDA_RETROATIVO: string[] = [
  STATUS.AGENDADA, STATUS.EM_PRE_INICIO, STATUS.EM_ANDAMENTO, STATUS.NA_ORIGEM, STATUS.EM_TRANSITO_DESTINO,
  STATUS.NO_DESTINO, STATUS.EM_TRANSITO_RETORNO, STATUS.RETORNANDO, STATUS.NA_BASE,
]

export const MSG_DEPENDE_222 =
  'Esta ação depende da atualização do banco (migration 222), ainda não aplicada. Nada foi alterado. Peça ao administrador do sistema para aplicá-la.'

export interface EstadoEscoltaRetroativo {
  status: string
  arquivada_em?: string | null
  excluida_em?: string | null
}

/** O botão aparece só para gestor e administrador, em escolta ativa de Agendada até Na Base. */
export function podeLancarRetroativo(perfil: Perfil, e: EstadoEscoltaRetroativo): boolean {
  return ehGestorOuAdmin(perfil) && !e.arquivada_em && !e.excluida_em && STATUS_PARTIDA_RETROATIVO.includes(e.status)
}

/** Etapas que faltam, em ordem, do status atual até Finalizada. Vazio fora das partidas aceitas. */
export function etapasQueFaltam(status: string): string[] {
  if (!STATUS_PARTIDA_RETROATIVO.includes(status)) return []
  return SEQUENCIA_STATUS.slice(SEQUENCIA_STATUS.indexOf(status) + 1)
}

/** A etapa produz ponto de controle (e por isso aceita e, ao vivo, exige foto)? */
export function etapaTemPonto(status: string): boolean {
  return status in TIPO_PONTO_POR_STATUS
}

export const MAX_FOTOS_ETAPA = FOTOS_POR_PONTO.max

// ── Horário de Brasília ───────────────────────────────────────────────────────────

/** Diferença, em minutos, entre o relógio de Brasília e o UTC num instante (negativa: -180). */
export function deslocamentoBrasilia(instanteMs: number): number {
  const partes = new Intl.DateTimeFormat('en-US', {
    timeZone: FUSO_BRASILIA, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(instanteMs))
  const v = (t: string) => Number(partes.find(p => p.type === t)?.value)
  const relogio = Date.UTC(v('year'), v('month') - 1, v('day'), v('hour'), v('minute'), v('second'))
  return Math.round((relogio - Math.floor(instanteMs / 1000) * 1000) / 60_000)
}

/**
 * Data (AAAA-MM-DD) e hora (HH:MM) de Brasília para ISO com o fuso explícito, por exemplo
 * '2026-11-10T08:00:00-03:00'. O fuso é calculado para o próprio instante (vale também se o
 * horário de verão voltar). Devolve null para data ou hora inválida.
 */
export function brasiliaParaIso(data: string, hora: string): string | null {
  const md = /^(\d{4})-(\d{2})-(\d{2})$/.exec(data ?? '')
  const mh = /^(\d{2}):(\d{2})$/.exec(hora ?? '')
  if (!md || !mh) return null
  const [a, m, d] = [Number(md[1]), Number(md[2]), Number(md[3])]
  const [h, min] = [Number(mh[1]), Number(mh[2])]
  if (m < 1 || m > 12 || d < 1 || d > 31 || h > 23 || min > 59) return null
  const comoUtc = Date.UTC(a, m - 1, d, h, min)
  const conferida = new Date(comoUtc)
  if (conferida.getUTCFullYear() !== a || conferida.getUTCMonth() !== m - 1 || conferida.getUTCDate() !== d) return null
  // Duas passadas: o deslocamento do instante aproximado e, depois, o do instante corrigido.
  let desl = deslocamentoBrasilia(comoUtc - (-180) * 60_000)
  desl = deslocamentoBrasilia(comoUtc - desl * 60_000)
  const sinal = desl < 0 ? '-' : '+'
  const abs = Math.abs(desl)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${data}T${hora}:00${sinal}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`
}

/** Instante (ISO ou Date) para data e hora de Brasília, nos formatos dos campos da tela. */
export function isoParaBrasilia(valor: string | Date): { data: string; hora: string } {
  const partes = new Intl.DateTimeFormat('en-CA', {
    timeZone: FUSO_BRASILIA, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).formatToParts(new Date(valor))
  const v = (t: string) => partes.find(p => p.type === t)?.value ?? ''
  return { data: `${v('year')}-${v('month')}-${v('day')}`, hora: `${v('hour')}:${v('minute')}` }
}

/** DD/MM/AAAA HH:MM de Brasília (o mesmo formato de public._hora_br). */
export function formatarBrasilia(valor: string | Date | null | undefined): string {
  if (!valor) return ''
  const { data, hora } = isoParaBrasilia(valor)
  const [a, m, d] = data.split('-')
  return `${d}/${m}/${a} ${hora}`
}

// ── Validação ─────────────────────────────────────────────────────────────────────

export function erroMotivo(motivo: string): string | null {
  const n = (motivo ?? '').trim().length
  if (n < MOTIVO_MINIMO) return `Informe o motivo com pelo menos ${MOTIVO_MINIMO} caracteres.`
  if (n > MOTIVO_MAXIMO) return `O motivo pode ter no máximo ${MOTIVO_MAXIMO} caracteres.`
  return null
}

export interface EtapaInformada {
  status: string
  /** ISO com fuso (brasiliaParaIso) ou null quando o campo está vazio ou inválido. */
  dataHora: string | null
  observacao?: string | null
  /** Quantidade de fotos escolhidas (antes do envio). */
  fotos?: number
}

const rotulo = (s: string) => LABELS_STATUS[s] ?? s

/**
 * Confere as etapas como o banco confere. Devolve a lista de erros (vazia quando está tudo
 * certo). `ultimoRegistro`: último registro de campo da escolta, quando a tela o conhece; o
 * banco confere de qualquer jeito.
 */
export function validarEtapas(params: {
  statusAtual: string
  etapas: EtapaInformada[]
  agora?: Date
  ultimoRegistro?: string | null
}): string[] {
  const { statusAtual, etapas } = params
  const agora = (params.agora ?? new Date()).getTime()
  const erros: string[] = []
  if (!STATUS_PARTIDA_RETROATIVO.includes(statusAtual)) {
    return [`Escolta em ${rotulo(statusAtual)}: o lançamento retroativo vale para escolta de Agendada até Na Base.`]
  }
  if (etapas.length === 0) return ['Informe as etapas a lançar, da próxima etapa até Finalizada.']
  const faltam = etapasQueFaltam(statusAtual)
  let anterior = statusAtual
  let horaAnterior: number | null = null
  const ultimo = params.ultimoRegistro ? Date.parse(params.ultimoRegistro) : null
  for (let i = 0; i < etapas.length; i++) {
    const et = etapas[i]
    const esperado = faltam[i]
    if (!esperado) { erros.push('Etapa a mais depois de Finalizada: o lançamento termina em Finalizada.'); break }
    const pos = SEQUENCIA_STATUS.indexOf(et.status)
    if (pos < 0) { erros.push(`Etapa ${i + 1} sem status válido.`); break }
    if (et.status === anterior || pos < SEQUENCIA_STATUS.indexOf(esperado)) {
      erros.push(`Etapa repetida ou fora de ordem: ${rotulo(et.status)} já foi registrada. A próxima é ${rotulo(esperado)}.`)
      break
    }
    if (et.status !== esperado) {
      erros.push(`Etapa pulada: falta ${rotulo(esperado)} antes de ${rotulo(et.status)}.`)
      break
    }
    const t = et.dataHora ? Date.parse(et.dataHora) : NaN
    if (!Number.isFinite(t)) {
      erros.push(`Informe data e hora de ${rotulo(et.status)}.`)
    } else {
      if (t > agora + TOLERANCIA_FUTURO_MS) erros.push(`Horário no futuro em ${rotulo(et.status)} (${formatarBrasilia(et.dataHora)}).`)
      if (t < agora - LIMITE_DIAS * 86_400_000) {
        erros.push(`Lançamento retroativo vale para até ${LIMITE_DIAS} dias: ${rotulo(et.status)} está em ${formatarBrasilia(et.dataHora)}.`)
      }
      if (horaAnterior !== null && t <= horaAnterior) {
        erros.push(`Horários fora de ordem: ${rotulo(et.status)} precisa ser depois de ${rotulo(anterior)}.`)
      }
      if (ultimo !== null && Number.isFinite(ultimo) && t <= ultimo) {
        erros.push(`O horário de ${rotulo(et.status)} precisa ser depois do último registro da escolta (${formatarBrasilia(params.ultimoRegistro)}).`)
      }
      horaAnterior = t
    }
    if ((et.observacao ?? '').trim().length > OBSERVACAO_MAXIMA) {
      erros.push(`A observação de ${rotulo(et.status)} pode ter no máximo ${OBSERVACAO_MAXIMA} caracteres.`)
    }
    if ((et.fotos ?? 0) > 0 && !etapaTemPonto(et.status)) {
      erros.push(`${rotulo(et.status)} não tem ponto de controle: foto não se aplica a esta etapa.`)
    }
    if ((et.fotos ?? 0) > MAX_FOTOS_ETAPA) erros.push(`No máximo ${MAX_FOTOS_ETAPA} fotos em ${rotulo(et.status)}.`)
    anterior = et.status
  }
  if (erros.length === 0 && anterior !== STATUS.FINALIZADA) {
    const prox = SEQUENCIA_STATUS[SEQUENCIA_STATUS.indexOf(anterior) + 1]
    erros.push(`O lançamento precisa ir até Finalizada: falta ${rotulo(prox)}.`)
  }
  return erros
}

/** data_finalizacao que o banco vai gravar: o horário informado para Finalizada. */
export function dataFinalizacaoDe(etapas: EtapaInformada[]): string | null {
  const fim = etapas.find(e => e.status === STATUS.FINALIZADA)
  return fim?.dataHora ?? null
}

/** Etapas com ponto e sem foto (ao vivo exigiriam): o banco aceita e marca a falta. */
export function etapasSemFoto(etapas: EtapaInformada[]): string[] {
  return etapas.filter(e => etapaTemPonto(e.status) && (e.fotos ?? 0) === 0).map(e => e.status)
}

export interface EtapaRpc {
  status: string
  data_hora: string
  observacao: string | null
  foto_ids?: string[]
  fotos_previstas?: number
}

/**
 * Monta o p_etapas. Na prévia vai só a quantidade de fotos (ainda não enviadas); na
 * confirmação, os ids das fotos já gravadas, por etapa (fotoIds[status]).
 */
export function montarPEtapas(etapas: EtapaInformada[], fotoIds?: Record<string, string[]>): EtapaRpc[] {
  return etapas.map(e => {
    const base: EtapaRpc = {
      status: e.status,
      data_hora: e.dataHora ?? '',
      observacao: (e.observacao ?? '').trim() || null,
    }
    if (fotoIds) base.foto_ids = etapaTemPonto(e.status) ? (fotoIds[e.status] ?? []) : []
    else base.fotos_previstas = etapaTemPonto(e.status) ? (e.fotos ?? 0) : 0
    return base
  })
}

// ── Fotos da galeria ─────────────────────────────────────────────────────────────

/**
 * Colunas da linha de `fotos` gravada pela tela antes da RPC. Sem latitude e longitude (nunca o
 * GPS atual do aparelho), sem carimbo e com o horário operacional da etapa; a RPC marca
 * retroativo, origem 'galeria' e origem_localizacao 'nenhuma'. EXIF não é lido.
 */
export function colunasFotoGaleria(dataHoraEtapa: string) {
  return {
    latitude: null,
    longitude: null,
    precisao_metros: null,
    data_hora_captura: dataHoraEtapa,
    carimbo_aplicado: false,
    enviada_telegram: false,
    sincronizada: true,
  }
}

/** Prefixo do caminho no storage (<prefixo>/<escolta_id>/<arquivo>, a regra de leitura da 198). */
export const PREFIXO_FOTO_RETROATIVA = 'retroativo'

// ── Textos da tela ───────────────────────────────────────────────────────────────

/** "Ocorrido em X · registrado em Y" para registros retroativos; só o horário nos demais. */
export function textoHorarioRegistro(r: { data_hora?: string | null; registrado_em?: string | null; retroativo?: boolean | null }): string {
  const ocorrido = formatarBrasilia(r.data_hora)
  if (!r.retroativo) return ocorrido
  const registrado = formatarBrasilia(r.registrado_em)
  return registrado ? `Ocorrido em ${ocorrido} · registrado em ${registrado}` : `Ocorrido em ${ocorrido}`
}

/** Rótulo de localização de uma foto: sem coordenada da galeria não finge GPS. */
export function textoLocalizacaoFoto(f: { latitude?: number | null; longitude?: number | null; origem?: string | null }): string | null {
  if (f.latitude != null && f.longitude != null) return null
  return f.origem === 'galeria' ? 'Sem localização (galeria)' : 'Sem localização'
}

/** Resumo em texto (o mesmo conteúdo do aviso do Telegram que o banco monta), para a prévia. */
export function textoResumoLancamento(params: {
  codigo: string | null | undefined
  statusAtual: string
  etapas: EtapaInformada[]
  motivo: string
  quem: string
  quando: Date
}): string {
  const linhas = [
    `Lançamento retroativo: ${params.codigo ?? ''}`.trim(),
    `De ${rotulo(params.statusAtual)} até Finalizada. Horários em que aconteceu (Brasília):`,
    ...params.etapas.map((e, i) => `${i + 1}. ${rotulo(e.status)}: ${formatarBrasilia(e.dataHora)}${etapaTemPonto(e.status) && (e.fotos ?? 0) === 0 ? ' (sem foto)' : ''}`),
  ]
  const total = params.etapas.reduce((s, e) => s + (etapaTemPonto(e.status) ? (e.fotos ?? 0) : 0), 0)
  const sem = etapasSemFoto(params.etapas).length
  linhas.push(`Fotos da galeria: ${total}${sem > 0 ? `; etapas sem foto: ${sem}` : ''}.`)
  linhas.push(`Lançado por: ${params.quem} em ${formatarBrasilia(params.quando)} (Brasília).`)
  linhas.push(`Motivo: ${params.motivo.trim()}`)
  return linhas.join('\n')
}
