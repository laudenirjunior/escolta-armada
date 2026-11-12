/**
 * Alerta de escolta duplicada na criação (pedido de Peçanha em 2026-11-12). Só aviso.
 * Rodar: node --test tests/duplicidade-escolta.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  RAIO_MESMO_LUGAR_M, diaBrasilia, distanciaMetros, encontrarParecidas, janelaDeBusca, mesmoLugar, normalizarEndereco,
  textoMotivos, type EscoltaComparavel,
} from '../lib/duplicidade-escolta.ts'

const NOVA: EscoltaComparavel = {
  cliente_id: 'c1',
  data_hora_prevista: '2026-11-13T11:00:00Z', // 08:00 de Brasília
  origem_endereco: 'Avenida Brasil, 500 - Penha, Rio de Janeiro - RJ',
  origem_lat: -22.8400, origem_lng: -43.2800,
  destino_endereco: 'Rua São José, 10 - Centro, Niterói - RJ',
  destino_lat: -22.8950, destino_lng: -43.1200,
  veiculo_ids: ['v1'],
}

function existente(over: Partial<EscoltaComparavel> = {}): EscoltaComparavel {
  return {
    ...NOVA, id: 'e1', codigo_escolta: 'ESC-001', status: 'agendada', veiculo_ids: ['v9'],
    data_hora_prevista: '2026-11-13T13:30:00Z', ...over,
  }
}

test('normalização: acento, caixa, pontuação e espaços', () => {
  assert.equal(normalizarEndereco('  Rua  São José, 10 - Centro  '), 'rua sao jose 10 centro')
  assert.equal(normalizarEndereco('RUA SAO JOSE 10, CENTRO'), 'rua sao jose 10 centro')
  assert.equal(normalizarEndereco(null), '')
})

test('mesmo lugar: endereço normalizado igual ou coordenada a até 300 m', () => {
  assert.equal(mesmoLugar({ endereco: 'Rua São José, 10', lat: null, lng: null }, { endereco: 'rua sao jose 10', lat: null, lng: null }), true)
  // Outro texto, coordenada a ~110 m.
  assert.equal(mesmoLugar({ endereco: 'Av. Brasil 500', lat: -22.84, lng: -43.28 }, { endereco: 'Avenida Brasil, 500, galpão 3', lat: -22.841, lng: -43.28 }), true)
  // Outro texto, coordenada a ~1,1 km.
  assert.equal(mesmoLugar({ endereco: 'Av. Brasil 500', lat: -22.84, lng: -43.28 }, { endereco: 'Av. Brasil 1500', lat: -22.85, lng: -43.28 }), false)
  // Coordenada zerada não vale.
  assert.equal(mesmoLugar({ endereco: 'A', lat: 0, lng: 0 }, { endereco: 'B', lat: 0, lng: 0 }), false)
  assert.ok(Math.abs(distanciaMetros(-22.84, -43.28, -22.841, -43.28) - 111) < 2)
  assert.equal(RAIO_MESMO_LUGAR_M, 300)
})

test('dia de Brasília: 22h de Brasília continua no mesmo dia (já é o dia seguinte em UTC)', () => {
  assert.equal(diaBrasilia('2026-11-14T01:00:00Z'), '2026-11-13')
  assert.equal(diaBrasilia('2026-11-13T03:00:00Z'), '2026-11-13')
  assert.equal(diaBrasilia('2026-11-13T02:59:00Z'), '2026-11-12')
  assert.equal(diaBrasilia('x'), '')
  const j = janelaDeBusca('2026-11-13T11:00:00Z')
  assert.ok(j.desde < '2026-11-13T03:00:00Z' && j.ate > '2026-11-14T03:00:00Z', 'a janela cobre o dia inteiro de Brasília')
})

test('mesmo cliente, mesma data e mesma rota: avisa', () => {
  const r = encontrarParecidas(NOVA, [existente()])
  assert.equal(r.length, 1)
  assert.deepEqual(r[0].motivos, ['mesma_rota'])
  assert.equal(r[0].codigo, 'ESC-001')
  assert.equal(textoMotivos(r[0].motivos), 'mesmo cliente, mesmo dia e mesma rota')
})

test('mesma rota escrita de outro jeito (normalização e coordenada) também avisa', () => {
  const r = encontrarParecidas(NOVA, [existente({
    origem_endereco: 'AV BRASIL 500, PENHA', origem_lat: -22.8405, origem_lng: -43.2801,
    destino_endereco: 'rua sao jose, 10 - centro, niteroi - rj',
  })])
  assert.deepEqual(r.map(x => x.id), ['e1'])
})

test('canceladas, arquivadas e excluídas ficam fora', () => {
  assert.deepEqual(encontrarParecidas(NOVA, [
    existente({ id: 'a', status: 'cancelada' }),
    existente({ id: 'b', arquivada_em: '2026-11-10T10:00:00Z' }),
    existente({ id: 'c', excluida_em: '2026-11-10T10:00:00Z' }),
  ]), [])
  // Finalizada no mesmo dia conta (pode ter sido lançada de novo por engano).
  assert.equal(encontrarParecidas(NOVA, [existente({ status: 'finalizada' })]).length, 1)
})

test('outra data (dia de Brasília), outro cliente ou outra rota: não avisa', () => {
  assert.deepEqual(encontrarParecidas(NOVA, [
    existente({ id: 'd', data_hora_prevista: '2026-11-14T11:00:00Z' }),
    existente({ id: 'e', data_hora_prevista: '2026-11-13T02:00:00Z' }), // 23h do dia 12 em Brasília
    existente({ id: 'f', cliente_id: 'c2' }),
    existente({ id: 'g', destino_endereco: 'Rua Outra, 99', destino_lat: -22.70, destino_lng: -43.40 }),
    // Rota invertida é a volta, outra operação.
    existente({
      id: 'h', origem_endereco: NOVA.destino_endereco, origem_lat: NOVA.destino_lat, origem_lng: NOVA.destino_lng,
      destino_endereco: NOVA.origem_endereco, destino_lat: NOVA.origem_lat, destino_lng: NOVA.origem_lng,
    }),
  ]), [])
})

test('mesma viatura no mesmo dia, de qualquer cliente: avisa como motivo mais fraco', () => {
  const r = encontrarParecidas(NOVA, [
    existente({ id: 'x', cliente_id: 'c2', destino_endereco: 'Outro', destino_lat: -22.7, destino_lng: -43.4, veiculo_ids: ['v1'] }),
    existente({ id: 'y' }),
    existente({ id: 'z', veiculo_ids: ['v1'] }),
  ])
  assert.deepEqual(r.map(x => x.id), ['z', 'y', 'x'], 'rota e viatura, depois rota, depois só viatura')
  assert.deepEqual(r[0].motivos, ['mesma_rota', 'mesma_viatura'])
  assert.equal(textoMotivos(r[2].motivos), 'mesma viatura no mesmo dia')
})

test('só aviso: a função não lança nem decide nada além da lista; nova sem data não compara', () => {
  assert.deepEqual(encontrarParecidas({ ...NOVA, data_hora_prevista: null }, [existente()]), [])
  assert.deepEqual(encontrarParecidas(NOVA, []), [])
  assert.deepEqual(encontrarParecidas({ ...NOVA, id: 'e1' }, [existente()]), [], 'a própria escolta não conta')
})

test('desempate pela hora mais próxima', () => {
  const r = encontrarParecidas(NOVA, [
    existente({ id: 'longe', data_hora_prevista: '2026-11-13T22:00:00Z' }),
    existente({ id: 'perto', data_hora_prevista: '2026-11-13T11:30:00Z' }),
  ])
  assert.deepEqual(r.map(x => x.id), ['perto', 'longe'])
})
