/**
 * Aviso entre abas (BroadcastChannel): a aba do detalhe relê quando o Campo guarda ou envia.
 * Rodar: node --test tests/avisos-abas.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { avisarOutrasAbas, fecharAvisosAbas, ouvirOutrasAbas, type AvisoAbas } from '../lib/offline/avisos-abas.ts'

test('o aviso de uma aba chega às outras; aviso inválido é ignorado', async () => {
  const recebidos: AvisoAbas[] = []
  const parar = ouvirOutrasAbas(a => recebidos.push(a))
  try {
    avisarOutrasAbas({ tipo: 'guardado', escoltaId: 'esc-1', clientId: 'c1' })
    // Mensagem fora do formato (outra versão do app, por exemplo).
    const intruso = new BroadcastChannel('escolta-campo-fila')
    intruso.postMessage({ tipo: 'qualquer' })
    intruso.close()
    avisarOutrasAbas({ tipo: 'enviado', escoltaId: 'esc-1', clientId: 'c1' })
    for (let i = 0; i < 20 && recebidos.length < 2; i++) await new Promise(r => setTimeout(r, 10))
    assert.deepEqual(recebidos, [
      { tipo: 'guardado', escoltaId: 'esc-1', clientId: 'c1' },
      { tipo: 'enviado', escoltaId: 'esc-1', clientId: 'c1' },
    ])
  } finally {
    parar()
    fecharAvisosAbas()
  }
})
