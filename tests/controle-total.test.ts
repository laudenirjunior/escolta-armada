/**
 * Controle total da gestão (pedido de Peçanha em 2026-11-12): gestor e administrador podem
 * tudo; supervisor, central e operador ficam exatamente como antes.
 * Rodar: node --test tests/controle-total.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  PERFIS_GESTAO, PODE_CANCELAR_ESCOLTA, PODE_EXCLUIR_ESCOLTA, PODE_PODER_TOTAL, PODE_VER_ARQUIVADAS,
  ehGestorOuAdmin, temPermissao,
} from '../lib/permissions.ts'
import {
  exclusaoEtapa1Ok, exclusaoEtapa2Ok, modoCancelamento, podeExcluirEscolta, podeReagendar, podeRecuperarArquivada,
} from '../lib/controle-total.ts'

const TOTAL = ['administrador', 'gestor']
const DEMAIS = ['supervisor', 'central', 'operador']
const TODOS_STATUS = ['rascunho', 'agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino',
  'no_destino', 'em_transito_retorno', 'retornando', 'na_base', 'finalizada', 'cancelada']
const ANTES_DE_FINALIZADA = TODOS_STATUS.filter(s => !['finalizada', 'cancelada'].includes(s))

test('conjuntos: o poder total é só administrador e gestor; PERFIS_GESTAO não mudou', () => {
  assert.deepEqual([...PODE_PODER_TOTAL].sort(), TOTAL.slice().sort())
  assert.deepEqual([...PODE_EXCLUIR_ESCOLTA].sort(), TOTAL.slice().sort())
  assert.deepEqual([...PODE_VER_ARQUIVADAS].sort(), TOTAL.slice().sort())
  assert.deepEqual([...PERFIS_GESTAO].sort(), ['administrador', 'central', 'gestor', 'supervisor'])
  assert.deepEqual([...PODE_CANCELAR_ESCOLTA].sort(), ['administrador', 'gestor', 'supervisor'])
})

test('ehGestorOuAdmin: só gestor e administrador; nulo e desconhecido não', () => {
  for (const p of TOTAL) assert.equal(ehGestorOuAdmin(p), true, p)
  for (const p of DEMAIS) assert.equal(ehGestorOuAdmin(p), false, p)
  assert.equal(ehGestorOuAdmin(null), false)
  assert.equal(ehGestorOuAdmin(undefined), false)
  assert.equal(ehGestorOuAdmin('ADMINISTRADOR'), false)
})

test('excluir e recuperar arquivada: gestor e administrador sim; supervisor, central e operador não', () => {
  for (const p of TOTAL) {
    assert.equal(podeExcluirEscolta(p), true, p)
    assert.equal(podeRecuperarArquivada(p), true, p)
  }
  for (const p of [...DEMAIS, null, undefined]) {
    assert.equal(podeExcluirEscolta(p), false, String(p))
    assert.equal(podeRecuperarArquivada(p), false, String(p))
    assert.equal(temPermissao(p, PODE_VER_ARQUIVADAS), false, String(p))
  }
})

test('cancelar antes de finalizada: administrador, gestor e supervisor pelo caminho de sempre', () => {
  for (const st of ANTES_DE_FINALIZADA) {
    for (const p of [...TOTAL, 'supervisor']) assert.equal(modoCancelamento(p, { status: st }), 'etapa', `${p} ${st}`)
    for (const p of ['central', 'operador', null]) assert.equal(modoCancelamento(p, { status: st }), null, `${p} ${st}`)
  }
})

test('cancelar finalizada: só gestor e administrador, pela RPC da gestão (221)', () => {
  for (const p of TOTAL) assert.equal(modoCancelamento(p, { status: 'finalizada' }), 'gestao', p)
  for (const p of DEMAIS) assert.equal(modoCancelamento(p, { status: 'finalizada' }), null, p)
})

test('cancelar: cancelada e arquivada não, para ninguém (arquivada: recuperar antes ou excluir)', () => {
  for (const p of [...TOTAL, ...DEMAIS]) {
    assert.equal(modoCancelamento(p, { status: 'cancelada' }), null, p)
    for (const st of TODOS_STATUS) {
      assert.equal(modoCancelamento(p, { status: st, arquivada_em: '2026-11-12T10:00:00Z' }), null, `${p} ${st}`)
    }
  }
})

test('reagendar: nunca a partir de finalizada, cancelada ou arquivada', () => {
  for (const st of ANTES_DE_FINALIZADA) assert.equal(podeReagendar({ status: st }), true, st)
  assert.equal(podeReagendar({ status: 'finalizada' }), false)
  assert.equal(podeReagendar({ status: 'cancelada' }), false)
  assert.equal(podeReagendar({ status: 'agendada', arquivada_em: '2026-11-12T10:00:00Z' }), false)
})

test('exclusão, etapa 1: motivo de 10 a 1000 caracteres (aparado) e "entendi" marcado', () => {
  assert.equal(exclusaoEtapa1Ok('Escolta duplicada no cadastro', true), true)
  assert.equal(exclusaoEtapa1Ok('Escolta duplicada no cadastro', false), false)
  assert.equal(exclusaoEtapa1Ok('curto', true), false)
  assert.equal(exclusaoEtapa1Ok('   123456789   ', true), false)
  assert.equal(exclusaoEtapa1Ok('1234567890', true), true)
  assert.equal(exclusaoEtapa1Ok('x'.repeat(1001), true), false)
})

test('exclusão, etapa 2: o código da escolta digitado igual (sem diferenciar maiúsculas)', () => {
  assert.equal(exclusaoEtapa2Ok('ESC-2026-0007', 'ESC-2026-0007'), true)
  assert.equal(exclusaoEtapa2Ok(' esc-2026-0007 ', 'ESC-2026-0007'), true)
  assert.equal(exclusaoEtapa2Ok('ESC-2026-0001', 'ESC-2026-0007'), false)
  assert.equal(exclusaoEtapa2Ok('', 'ESC-2026-0007'), false)
  assert.equal(exclusaoEtapa2Ok('', null), false)
  assert.equal(exclusaoEtapa2Ok('', ''), false)
})
