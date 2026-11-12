/**
 * Regra do servidor atrás do aparelho (relato de 10/11/2026: "A etapa já foi avançada em
 * outra tela" com a etapa anterior ainda na fila). Rodar: node --test tests/pendentes.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { servidorAtrasDoAparelho } from '../lib/offline/pendentes.ts'
import type { RegistroFila } from '../lib/offline/fila.ts'

const ESC = 'esc-1'

function etapa(seq: number, statusAtual: string, statusNovo: string, estado: RegistroFila['estado'] = 'pendente'): RegistroFila {
  return {
    seq, versao_fila: 1, client_id: `c${seq}`, auth_user_id: 'u', usuario_id: null,
    escolta_id: ESC, escolta_veiculo_id: null, tipo: 'etapa',
    payload: { etapa: { status_atual: statusAtual, status_novo: statusNovo, pontos: [] } },
    versao_gestao: null, data_hora_acao: '2026-11-10T23:40:00Z', relogio: null, gps: null,
    prioridade: 1, estado, tentativas: 0, ultimo_erro: null, fotos: [], criado_em: '2026-11-10T23:40:00Z',
  }
}

test('etapa anterior na fila: o servidor está atrás, não é outra tela', () => {
  const fila = [etapa(1, 'em_pre_inicio', 'em_andamento')]
  assert.equal(servidorAtrasDoAparelho(ESC, 'em_pre_inicio', 'em_andamento', fila), true)
})

test('duas etapas na fila (em envio e pendente): a cadeia leva à etapa da tela', () => {
  const fila = [etapa(1, 'em_pre_inicio', 'em_andamento', 'enviando'), etapa(2, 'em_andamento', 'na_origem')]
  assert.equal(servidorAtrasDoAparelho(ESC, 'em_pre_inicio', 'na_origem', fila), true)
})

test('sem nada na fila: a diferença é legítima (outra tela ou a gestão)', () => {
  assert.equal(servidorAtrasDoAparelho(ESC, 'na_origem', 'em_andamento', []), false)
})

test('servidor à frente da cadeia do aparelho: legítimo', () => {
  const fila = [etapa(1, 'em_pre_inicio', 'em_andamento')]
  assert.equal(servidorAtrasDoAparelho(ESC, 'na_origem', 'em_andamento', fila), false)
})

test('registro já em conflito ou aplicado não conta', () => {
  const fila = [etapa(1, 'em_pre_inicio', 'em_andamento', 'conflito')]
  assert.equal(servidorAtrasDoAparelho(ESC, 'em_pre_inicio', 'em_andamento', fila), false)
})

test('fila de outra escolta não conta', () => {
  const fila = [{ ...etapa(1, 'em_pre_inicio', 'em_andamento'), escolta_id: 'outra' }]
  assert.equal(servidorAtrasDoAparelho(ESC, 'em_pre_inicio', 'em_andamento', fila), false)
})

test('mesmo status: nada a decidir', () => {
  assert.equal(servidorAtrasDoAparelho(ESC, 'em_andamento', 'em_andamento', [etapa(1, 'em_pre_inicio', 'em_andamento')]), false)
})
