/**
 * Destino do POST /api/telegram (correção após o teste da prévia do PR #10, 2026-11-12). Sem
 * destino configurado o envio é omitido (200, ok false), não HTTP 400. Não chama o Telegram.
 * Rodar: node --test tests/telegram-destino.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { RESPOSTA_SEM_DESTINO, resolverDestinoTelegram } from '../lib/telegram-destino.ts'

const base = { chatDoCliente: null, paraCentral: false, chatIdExplicito: undefined, perfil: 'operador', chatCentral: null }

test('pré-início de escolta de cliente sem grupo e sem TELEGRAM_CHAT_ID: sem destino', () => {
  assert.equal(resolverDestinoTelegram(base), null)
})

test('sem destino é envio omitido (200, ok false), não erro 400', () => {
  assert.equal(RESPOSTA_SEM_DESTINO.status, 200)
  assert.equal(RESPOSTA_SEM_DESTINO.corpo.ok, false)
  assert.equal(RESPOSTA_SEM_DESTINO.corpo.omitido, true)
})

test('grupo do cliente vem primeiro', () => {
  assert.equal(resolverDestinoTelegram({ ...base, chatDoCliente: '-100cliente', chatCentral: '-100central' }), '-100cliente')
})

test('sem grupo do cliente, cai no chat central (TELEGRAM_CHAT_ID)', () => {
  assert.equal(resolverDestinoTelegram({ ...base, chatCentral: '-100central' }), '-100central')
})

test('aviso para a central ignora o grupo do cliente e o chat_id explícito', () => {
  assert.equal(resolverDestinoTelegram({ ...base, paraCentral: true, chatDoCliente: '-100cliente', chatIdExplicito: '123', perfil: 'administrador', chatCentral: '-100central' }), '-100central')
  assert.equal(resolverDestinoTelegram({ ...base, paraCentral: true, chatDoCliente: '-100cliente' }), null)
})

test('chat_id explícito só de administrador ou gestor', () => {
  assert.equal(resolverDestinoTelegram({ ...base, chatIdExplicito: '123', perfil: 'gestor' }), '123')
  assert.equal(resolverDestinoTelegram({ ...base, chatIdExplicito: '123', perfil: 'administrador' }), '123')
  for (const perfil of ['supervisor', 'central', 'operador', null]) {
    assert.equal(resolverDestinoTelegram({ ...base, chatIdExplicito: '123', perfil }), null)
  }
})
