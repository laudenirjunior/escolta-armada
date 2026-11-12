/**
 * Seleção do Campo (correção após o teste da prévia do PR #10, 2026-11-12): o id pedido pelo
 * detalhe (?escolta=) é respeitado também para agendada, e a troca de modo não perde a escolha.
 * Rodar: node --test tests/campo-selecao.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { selecionarEscoltaCampo } from '../lib/campo-selecao.ts'

const e = (id: string, status: string) => ({ id, status })
const ATIVAS = [e('esc-0004', 'em_andamento'), e('esc-0007', 'em_pre_inicio'), e('esc-0009', 'retornando')]
const AGENDADAS = [e('esc-0011', 'agendada'), e('esc-0012', 'agendada')]

test('id de agendada é respeitado: não cai na primeira ativa e não vai para escoltaAtiva', () => {
  const s = selecionarEscoltaCampo({ pedida: 'esc-0011', atual: null, ativas: ATIVAS, agendadas: AGENDADAS })
  assert.equal(s.ativa, null)
  assert.equal(s.agendadaPedida?.id, 'esc-0011')
  assert.equal(s.pedidoPendente, 'esc-0011')
})

test('id de ativa é respeitado (não a primeira da lista)', () => {
  const s = selecionarEscoltaCampo({ pedida: 'esc-0009', atual: null, ativas: ATIVAS, agendadas: AGENDADAS })
  assert.equal(s.ativa?.id, 'esc-0009')
  assert.equal(s.agendadaPedida, null)
  assert.equal(s.pedidoPendente, null)
})

test('id inexistente não quebra: pedido descartado, vale a primeira ativa', () => {
  const s = selecionarEscoltaCampo({ pedida: 'nao-existe', atual: null, ativas: ATIVAS, agendadas: AGENDADAS })
  assert.equal(s.ativa?.id, 'esc-0004')
  assert.equal(s.agendadaPedida, null)
  assert.equal(s.pedidoPendente, null)
  const vazio = selecionarEscoltaCampo({ pedida: 'nao-existe', atual: null, ativas: [], agendadas: [] })
  assert.deepEqual(vazio, { ativa: null, agendadaPedida: null, pedidoPendente: null })
})

test('sem id pedido: o padrão de sempre (primeira ativa)', () => {
  const s = selecionarEscoltaCampo({ pedida: null, atual: null, ativas: ATIVAS, agendadas: AGENDADAS })
  assert.equal(s.ativa?.id, 'esc-0004')
  assert.equal(s.agendadaPedida, null)
})

test('recarga (troca de modo, tempo real) mantém a escolta já aberta', () => {
  const s = selecionarEscoltaCampo({ pedida: null, atual: 'esc-0009', ativas: ATIVAS, agendadas: AGENDADAS })
  assert.equal(s.ativa?.id, 'esc-0009')
})

test('recarga mantém a agendada pedida (o pedido continua guardado) até ela virar ativa', () => {
  const r1 = selecionarEscoltaCampo({ pedida: 'esc-0011', atual: null, ativas: ATIVAS, agendadas: AGENDADAS })
  const r2 = selecionarEscoltaCampo({ pedida: r1.pedidoPendente, atual: r1.ativa?.id, ativas: ATIVAS, agendadas: AGENDADAS })
  assert.equal(r2.ativa, null)
  assert.equal(r2.agendadaPedida?.id, 'esc-0011')
  // Pré-início iniciado pelo wizard: a escolta passa a ativa e abre, sem cair em outra.
  const ativas = [...ATIVAS, e('esc-0011', 'em_pre_inicio')]
  const r3 = selecionarEscoltaCampo({ pedida: r2.pedidoPendente, atual: null, ativas, agendadas: [AGENDADAS[1]] })
  assert.equal(r3.ativa?.id, 'esc-0011')
  assert.equal(r3.pedidoPendente, null)
})

test('escolta aberta que saiu das ativas: volta ao pedido pendente ou ao padrão', () => {
  const s = selecionarEscoltaCampo({ pedida: null, atual: 'esc-finalizada', ativas: ATIVAS, agendadas: AGENDADAS })
  assert.equal(s.ativa?.id, 'esc-0004')
})
