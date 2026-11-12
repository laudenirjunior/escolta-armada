/**
 * Reconferência da etapa antes de gravar (teste real de 12/11/2026: DevTools Offline,
 * navigator.onLine true, o GET de status voltou da cópia do service worker com a etapa antiga e
 * a tela acusou "A etapa já foi avançada em outra tela" sem guardar nada).
 * Rodar: node --test tests/reconferencia.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { decidirAvanco, leituraDaResposta, MENSAGEM_SEM_CONFERENCIA, type EntradaDecisao } from '../lib/offline/reconferencia.ts'
import type { RegistroFila } from '../lib/offline/fila.ts'

const ESC = 'esc-1'

function etapa(seq: number, statusAtual: string, statusNovo: string, estado: RegistroFila['estado'] = 'pendente'): RegistroFila {
  return {
    seq, versao_fila: 1, client_id: `c${seq}`, auth_user_id: 'u', usuario_id: null,
    escolta_id: ESC, escolta_veiculo_id: null, tipo: 'etapa',
    payload: { etapa: { status_atual: statusAtual, status_novo: statusNovo, pontos: [] } },
    versao_gestao: null, data_hora_acao: '2026-11-12T19:15:00Z', relogio: null, gps: null,
    prioridade: 1, estado, tentativas: 0, ultimo_erro: null, fotos: [], criado_em: '2026-11-12T19:15:00Z',
  }
}

function entrada(p: Partial<EntradaDecisao>): EntradaDecisao {
  return { envelope: true, leitura: { tipo: 'lida', status: 'em_andamento', fresca: true }, statusTela: 'em_andamento', escoltaId: ESC, pendentes: [], ...p }
}

const ehRede = (e: { message?: string; code?: string }) => e.code === 'SEM_CONEXAO' || /failed to fetch/i.test(e.message ?? '')

// ── Cenário de 12/11 ────────────────────────────────────────────────────────────────
test('12/11: cópia do SW com a etapa anterior (não fresca), fila vazia: guarda, não é outra tela', () => {
  const d = decidirAvanco(entrada({ leitura: { tipo: 'lida', status: 'em_pre_inicio', fresca: false } }))
  assert.deepEqual(d, { acao: 'gravar', semConexao: false })
})

test('12/11: GET de status sem rede (504 SEM_CONEXAO do SW): guarda como sem conexão', () => {
  const leitura = leituraDaResposta({ data: null, error: { code: 'SEM_CONEXAO', message: 'Sem conexão e sem cópia guardada no aparelho.' } }, ehRede)
  assert.deepEqual(leitura, { tipo: 'falhou', rede: true, mensagem: 'Sem conexão e sem cópia guardada no aparelho.' })
  assert.deepEqual(decidirAvanco(entrada({ leitura })), { acao: 'gravar', semConexao: true })
})

test('12/11: GET falhou com TypeError de rede (navigator.onLine mentindo true): guarda', () => {
  const leitura = leituraDaResposta({ data: null, error: { message: 'TypeError: Failed to fetch' } }, ehRede)
  assert.deepEqual(decidirAvanco(entrada({ leitura })), { acao: 'gravar', semConexao: true })
})

test('12/11: data null (escolta não lida): guarda, não é outra tela', () => {
  const leitura = leituraDaResposta({ data: null, error: null }, ehRede)
  assert.deepEqual(decidirAvanco(entrada({ leitura })), { acao: 'gravar', semConexao: false })
})

test('aparelho sabidamente sem rede (leitura pulada): guarda como sem conexão', () => {
  assert.deepEqual(decidirAvanco(entrada({ leitura: { tipo: 'pulada' } })), { acao: 'gravar', semConexao: true })
})

test('com o envelope, erro que não é de rede também guarda (o servidor confere no envio)', () => {
  const d = decidirAvanco(entrada({ leitura: { tipo: 'falhou', rede: false, mensagem: 'JWT expired' } }))
  assert.deepEqual(d, { acao: 'gravar', semConexao: false })
})

// ── Outra tela de verdade ───────────────────────────────────────────────────────────
test('servidor realmente à frente, leitura fresca, fila vazia: continua sendo outra tela', () => {
  const d = decidirAvanco(entrada({ leitura: { tipo: 'lida', status: 'na_origem', fresca: true } }))
  assert.deepEqual(d, { acao: 'bloquear', motivo: 'outra_tela', mensagem: null })
})

test('servidor à frente da cadeia da fila, leitura fresca: outra tela', () => {
  const d = decidirAvanco(entrada({
    leitura: { tipo: 'lida', status: 'na_origem', fresca: true },
    pendentes: [etapa(1, 'em_pre_inicio', 'em_andamento')],
  }))
  assert.equal(d.acao === 'bloquear' && d.motivo, 'outra_tela')
})

test('mesmo status, leitura fresca: grava com rede', () => {
  assert.deepEqual(decidirAvanco(entrada({})), { acao: 'gravar', semConexao: false })
})

// ── Regressão do PR #9 (etapa anterior ainda na fila) ───────────────────────────────
test('PR #9: etapa anterior na fila, servidor atrás (fresco): com o envelope, segue', () => {
  const d = decidirAvanco(entrada({
    leitura: { tipo: 'lida', status: 'em_pre_inicio', fresca: true },
    pendentes: [etapa(1, 'em_pre_inicio', 'em_andamento')],
  }))
  assert.deepEqual(d, { acao: 'gravar', semConexao: false })
})

test('PR #9: etapa anterior na fila, sem o envelope: avisa que a anterior está sendo enviada', () => {
  const d = decidirAvanco(entrada({
    envelope: false,
    leitura: { tipo: 'lida', status: 'em_pre_inicio', fresca: true },
    pendentes: [etapa(1, 'em_pre_inicio', 'em_andamento')],
  }))
  assert.deepEqual(d, { acao: 'bloquear', motivo: 'anterior_enviando', mensagem: null })
})

// ── Sem o envelope (gravação direta, como antes da onda L) ──────────────────────────
test('sem o envelope, leitura que falhou bloqueia com a mensagem do erro (não fala em outra tela)', () => {
  const d = decidirAvanco(entrada({ envelope: false, leitura: { tipo: 'falhou', rede: true, mensagem: 'Failed to fetch' } }))
  assert.deepEqual(d, { acao: 'bloquear', motivo: 'erro', mensagem: 'Failed to fetch' })
})

test('sem o envelope, escolta não lida: pede para conferir a conexão, não acusa outra tela', () => {
  const d = decidirAvanco(entrada({ envelope: false, leitura: { tipo: 'lida', status: null, fresca: true } }))
  assert.deepEqual(d, { acao: 'bloquear', motivo: 'erro', mensagem: MENSAGEM_SEM_CONFERENCIA })
})

test('sem o envelope, outra tela fresca continua bloqueando', () => {
  const d = decidirAvanco(entrada({ envelope: false, leitura: { tipo: 'lida', status: 'na_origem', fresca: true } }))
  assert.equal(d.acao === 'bloquear' && d.motivo, 'outra_tela')
})
