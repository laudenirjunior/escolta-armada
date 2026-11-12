/**
 * Lançamento retroativo (pedido de Peçanha em 2026-11-12, migration 222): regras que a tela
 * confere antes de chamar a RPC. Quem garante é o banco (database/testes/05_lancamento_retroativo.sql).
 * Rodar: node --test tests/lancamento-retroativo.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  STATUS_PARTIDA_RETROATIVO, brasiliaParaIso, colunasFotoGaleria, dataFinalizacaoDe, erroMotivo, etapasQueFaltam,
  etapaTemPonto, etapasSemFoto, formatarBrasilia, isoParaBrasilia, montarPEtapas, podeLancarRetroativo, textoHorarioRegistro,
  textoLocalizacaoFoto, textoResumoLancamento, validarEtapas, type EtapaInformada,
} from '../lib/lancamento-retroativo.ts'

const AGORA = new Date('2026-11-12T15:00:00Z') // 12/11/2026 12:00 em Brasília
const TODOS_STATUS = ['rascunho', 'agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino',
  'no_destino', 'em_transito_retorno', 'retornando', 'na_base', 'finalizada', 'cancelada']

/** Etapas que faltam a partir de `status`, uma por hora a partir de `inicio` (Brasília). */
function etapasDesde(status: string, inicio = '2026-11-11T08:00:00-03:00', passoMin = 60): EtapaInformada[] {
  const t0 = Date.parse(inicio)
  return etapasQueFaltam(status).map((s, i) => ({
    status: s, dataHora: new Date(t0 + i * passoMin * 60_000).toISOString(), fotos: etapaTemPonto(s) ? 1 : 0,
  }))
}

test('perfis: só gestor e administrador lançam; supervisor, central e operador não', () => {
  for (const p of ['gestor', 'administrador']) assert.equal(podeLancarRetroativo(p, { status: 'agendada' }), true, p)
  for (const p of ['supervisor', 'central', 'operador', null, undefined, 'GESTOR']) {
    assert.equal(podeLancarRetroativo(p, { status: 'agendada' }), false, String(p))
  }
})

test('status de partida: Agendada até Na Base; nunca rascunho, finalizada, cancelada, arquivada ou excluída', () => {
  for (const s of TODOS_STATUS) {
    const esperado = !['rascunho', 'finalizada', 'cancelada'].includes(s)
    assert.equal(podeLancarRetroativo('gestor', { status: s }), esperado, s)
  }
  assert.equal(podeLancarRetroativo('gestor', { status: 'agendada', arquivada_em: '2026-11-01T00:00:00Z' }), false)
  assert.equal(podeLancarRetroativo('gestor', { status: 'agendada', excluida_em: '2026-11-01T00:00:00Z' }), false)
  assert.deepEqual(STATUS_PARTIDA_RETROATIVO, TODOS_STATUS.slice(1, 10))
})

test('etapas que faltam: da próxima etapa até Finalizada, na ordem', () => {
  assert.deepEqual(etapasQueFaltam('agendada'), ['em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino',
    'no_destino', 'em_transito_retorno', 'retornando', 'na_base', 'finalizada'])
  assert.deepEqual(etapasQueFaltam('na_base'), ['finalizada'])
  assert.deepEqual(etapasQueFaltam('finalizada'), [])
  assert.deepEqual(etapasQueFaltam('rascunho'), [])
})

test('sequência correta passa', () => {
  for (const s of STATUS_PARTIDA_RETROATIVO) {
    assert.deepEqual(validarEtapas({ statusAtual: s, etapas: etapasDesde(s), agora: AGORA }), [], s)
  }
})

test('pular etapa é recusado', () => {
  const et = etapasDesde('agendada')
  et.splice(2, 1) // sem na_origem
  const erros = validarEtapas({ statusAtual: 'agendada', etapas: et, agora: AGORA })
  assert.match(erros[0], /^Etapa pulada: falta Na Origem antes de Trânsito p\/ Destino/)
})

test('repetir etapa é recusado (inclusive o status atual)', () => {
  const et = etapasDesde('no_destino')
  const repetida = [et[0], { ...et[0], dataHora: et[1].dataHora }, ...et.slice(1)]
  assert.match(validarEtapas({ statusAtual: 'no_destino', etapas: repetida, agora: AGORA })[0], /^Etapa repetida/)
  const atual = [{ status: 'no_destino', dataHora: et[0].dataHora }, ...et]
  assert.match(validarEtapas({ statusAtual: 'no_destino', etapas: atual, agora: AGORA })[0], /^Etapa repetida/)
})

test('lançamento tem de terminar em Finalizada', () => {
  const et = etapasDesde('agendada').slice(0, -1)
  assert.match(validarEtapas({ statusAtual: 'agendada', etapas: et, agora: AGORA })[0], /precisa ir até Finalizada: falta Finalizada/)
  assert.match(validarEtapas({ statusAtual: 'agendada', etapas: [], agora: AGORA })[0], /Informe as etapas/)
})

test('horário fora de ordem (igual ou anterior à etapa de antes) é recusado', () => {
  const et = etapasDesde('no_destino')
  et[2] = { ...et[2], dataHora: et[1].dataHora }
  assert.ok(validarEtapas({ statusAtual: 'no_destino', etapas: et, agora: AGORA }).some(e => e.startsWith('Horários fora de ordem')))
  const et2 = etapasDesde('no_destino')
  et2[1] = { ...et2[1], dataHora: '2026-11-11T07:00:00-03:00' }
  assert.ok(validarEtapas({ statusAtual: 'no_destino', etapas: et2, agora: AGORA }).some(e => e.startsWith('Horários fora de ordem')))
})

test('horário no futuro é recusado, com tolerância de 5 minutos', () => {
  const quase = etapasDesde('na_base', new Date(AGORA.getTime() + 4 * 60_000).toISOString())
  assert.deepEqual(validarEtapas({ statusAtual: 'na_base', etapas: quase, agora: AGORA }), [])
  const futuro = etapasDesde('na_base', new Date(AGORA.getTime() + 6 * 60_000).toISOString())
  assert.match(validarEtapas({ statusAtual: 'na_base', etapas: futuro, agora: AGORA })[0], /^Horário no futuro/)
})

test('limite de 30 dias', () => {
  const ok = etapasDesde('na_base', new Date(AGORA.getTime() - 29 * 86_400_000).toISOString())
  assert.deepEqual(validarEtapas({ statusAtual: 'na_base', etapas: ok, agora: AGORA }), [])
  const velho = etapasDesde('na_base', new Date(AGORA.getTime() - 31 * 86_400_000).toISOString())
  assert.match(validarEtapas({ statusAtual: 'na_base', etapas: velho, agora: AGORA })[0], /até 30 dias/)
})

test('todos os horários depois do último registro da escolta', () => {
  const et = etapasDesde('no_destino')
  const erros = validarEtapas({ statusAtual: 'no_destino', etapas: et, agora: AGORA, ultimoRegistro: '2026-11-11T08:30:00-03:00' })
  assert.match(erros[0], /depois do último registro/)
  assert.deepEqual(validarEtapas({ statusAtual: 'no_destino', etapas: et, agora: AGORA, ultimoRegistro: '2026-11-11T07:59:00-03:00' }), [])
})

test('horário vazio é recusado', () => {
  const et = etapasDesde('na_base')
  et[0] = { ...et[0], dataHora: null }
  assert.match(validarEtapas({ statusAtual: 'na_base', etapas: et, agora: AGORA })[0], /Informe data e hora de Finalizada/)
})

test('motivo: mínimo de 10 caracteres (aparados) e máximo de 1000', () => {
  assert.match(erroMotivo('curto') ?? '', /pelo menos 10/)
  assert.match(erroMotivo('   123456789   ') ?? '', /pelo menos 10/)
  assert.equal(erroMotivo('Operador sem bateria'), null)
  assert.match(erroMotivo('x'.repeat(1001)) ?? '', /no máximo 1000/)
})

test('data_finalizacao = horário da última etapa (Finalizada), não o de agora', () => {
  const et = etapasDesde('agendada')
  assert.equal(dataFinalizacaoDe(et), et[et.length - 1].dataHora)
  assert.equal(Date.parse(dataFinalizacaoDe(et)!), Date.parse('2026-11-11T16:00:00-03:00'))
})

test('conversão de fuso: horário de Brasília para ISO com -03:00 e de volta', () => {
  assert.equal(brasiliaParaIso('2026-11-10', '08:00'), '2026-11-10T08:00:00-03:00')
  assert.equal(new Date(brasiliaParaIso('2026-11-10', '23:30')!).toISOString(), '2026-11-11T02:30:00.000Z')
  assert.equal(brasiliaParaIso('2026-02-30', '08:00'), null)
  assert.equal(brasiliaParaIso('2026-11-10', '24:00'), null)
  assert.equal(brasiliaParaIso('', '08:00'), null)
  assert.deepEqual(isoParaBrasilia('2026-11-11T02:30:00Z'), { data: '2026-11-10', hora: '23:30' })
  assert.equal(formatarBrasilia('2026-11-11T02:30:00Z'), '10/11/2026 23:30')
  // Fuso histórico com horário de verão (janeiro de 2018, -02:00): o fuso vem do instante.
  assert.equal(brasiliaParaIso('2018-01-15', '10:00'), '2018-01-15T10:00:00-02:00')
})

test('p_etapas: prévia leva a quantidade de fotos; confirmação, os ids; etapa sem ponto nunca leva foto', () => {
  const et: EtapaInformada[] = [
    { status: 'na_base', dataHora: '2026-11-11T08:00:00-03:00', observacao: '  chegou  ', fotos: 2 },
    { status: 'finalizada', dataHora: '2026-11-11T08:30:00-03:00', observacao: '', fotos: 0 },
  ]
  assert.deepEqual(montarPEtapas(et), [
    { status: 'na_base', data_hora: '2026-11-11T08:00:00-03:00', observacao: 'chegou', fotos_previstas: 2 },
    { status: 'finalizada', data_hora: '2026-11-11T08:30:00-03:00', observacao: null, fotos_previstas: 0 },
  ])
  assert.deepEqual(montarPEtapas(et, { na_base: ['a', 'b'], finalizada: ['c'] }).map(e => e.foto_ids), [['a', 'b'], []])
})

test('foto da galeria sem GPS: nada de coordenada nem carimbo; rótulo "Sem localização (galeria)"', () => {
  const c = colunasFotoGaleria('2026-11-11T08:00:00-03:00')
  assert.equal(c.latitude, null)
  assert.equal(c.longitude, null)
  assert.equal(c.precisao_metros, null)
  assert.equal(c.carimbo_aplicado, false)
  assert.equal(c.data_hora_captura, '2026-11-11T08:00:00-03:00')
  assert.equal(textoLocalizacaoFoto({ latitude: null, longitude: null, origem: 'galeria' }), 'Sem localização (galeria)')
  assert.equal(textoLocalizacaoFoto({ latitude: -22.9, longitude: -43.2, origem: null }), null)
})

test('etapas sem foto e textos do registro', () => {
  const et = etapasDesde('no_destino').map(e => ({ ...e, fotos: 0 }))
  assert.deepEqual(etapasSemFoto(et), ['em_transito_retorno', 'retornando', 'na_base'])
  assert.equal(textoHorarioRegistro({ data_hora: '2026-11-11T11:00:00Z', registrado_em: '2026-11-12T13:05:00Z', retroativo: true }),
    'Ocorrido em 11/11/2026 08:00 · registrado em 12/11/2026 10:05')
  assert.equal(textoHorarioRegistro({ data_hora: '2026-11-11T11:00:00Z', registrado_em: '2026-11-11T11:00:01Z', retroativo: false }),
    '11/11/2026 08:00')
  const resumo = textoResumoLancamento({ codigo: 'ESC-2026-0001', statusAtual: 'no_destino', etapas: et, motivo: ' Sem sinal no retorno ',
    quem: 'Gestor QA', quando: AGORA })
  assert.match(resumo, /^Lançamento retroativo: ESC-2026-0001/)
  assert.match(resumo, /1\. Trânsito p\/ Retorno: 11\/11\/2026 08:00 \(sem foto\)/)
  assert.match(resumo, /Lançado por: Gestor QA em 12\/11\/2026 12:00 \(Brasília\)\./)
  assert.match(resumo, /Motivo: Sem sinal no retorno$/)
  assert.doesNotMatch(resumo, /[–—]/) // sem travessão
})
