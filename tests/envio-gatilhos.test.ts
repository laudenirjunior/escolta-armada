/**
 * Gatilhos do envio automático da fila (evento online, volta da aba, relógio).
 * Rodar: node --test tests/envio-gatilhos.test.ts
 */
import { test, mock } from 'node:test'
import assert from 'node:assert/strict'
import { ligarGatilhosEnvio, ESPERA_MAX_MS } from '../lib/offline/envio.ts'

class Documento extends EventTarget { visibilityState = 'hidden' }

function montar() {
  const janela = new EventTarget()
  const documento = new Documento()
  const chamadas: boolean[] = []
  const rede: boolean[] = []
  const desligar = ligarGatilhosEnvio({ disparar: (i) => chamadas.push(i), aoMudarRede: (o) => rede.push(o) }, 30_000, { janela, documento })
  return { janela, documento, chamadas, rede, desligar }
}

test('evento online envia já, ignorando a espera crescente', () => {
  const t = montar()
  t.janela.dispatchEvent(new Event('online'))
  assert.deepEqual(t.chamadas, [true])
  assert.deepEqual(t.rede, [true])
  t.desligar()
})

test('evento offline só atualiza a faixa, não tenta enviar', () => {
  const t = montar()
  t.janela.dispatchEvent(new Event('offline'))
  assert.deepEqual(t.chamadas, [])
  assert.deepEqual(t.rede, [false])
  t.desligar()
})

test('aba de volta à frente (visibilitychange visível ou focus) envia já; escondida não', () => {
  const t = montar()
  t.documento.dispatchEvent(new Event('visibilitychange'))
  assert.deepEqual(t.chamadas, [])
  t.documento.visibilityState = 'visible'
  t.documento.dispatchEvent(new Event('visibilitychange'))
  t.janela.dispatchEvent(new Event('focus'))
  assert.deepEqual(t.chamadas, [true, true])
  t.desligar()
})

test('relógio tenta a cada intervalo respeitando a espera (navigator.onLine que mente: sem evento online)', () => {
  mock.timers.enable({ apis: ['setInterval'] })
  try {
    const t = montar()
    mock.timers.tick(30_000)
    mock.timers.tick(30_000)
    assert.deepEqual(t.chamadas, [false, false])
    t.desligar()
    mock.timers.tick(30_000)
    assert.equal(t.chamadas.length, 2)
  } finally {
    mock.timers.reset()
  }
})

test('desligar remove todos os ouvintes', () => {
  const t = montar()
  t.desligar()
  t.documento.visibilityState = 'visible'
  t.janela.dispatchEvent(new Event('online'))
  t.janela.dispatchEvent(new Event('focus'))
  t.documento.dispatchEvent(new Event('visibilitychange'))
  assert.deepEqual(t.chamadas, [])
})

test('espera crescente limitada a 1 minuto (o relógio de 30 s percebe a volta da rede)', () => {
  assert.equal(ESPERA_MAX_MS, 60_000)
})
