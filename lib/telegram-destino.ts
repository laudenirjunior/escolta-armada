/**
 * Para onde vai o aviso do POST /api/telegram, decidido no servidor (correção após o teste da
 * prévia do PR #10, 2026-11-12).
 *
 * Ordem: o grupo do cliente da escolta (clientes.telegram_chat_id), salvo aviso para a
 * central; depois um chat_id explícito, só de administrador ou gestor; por último o chat
 * central (TELEGRAM_CHAT_ID).
 *
 * Sem nenhum destino é configuração (cliente sem grupo e ambiente sem TELEGRAM_CHAT_ID), não
 * erro de quem chamou: a rota responde 200 com ok false e omitido true, e o registro da
 * escolta, que já foi gravado antes, segue normal. Antes era HTTP 400 e aparecia como
 * falha ao iniciar o pré-início.
 *
 * Testes: node --test tests/telegram-destino.test.ts
 */
export function resolverDestinoTelegram(entrada: {
  chatDoCliente: string | null | undefined
  paraCentral: boolean
  chatIdExplicito: unknown
  perfil: string | null | undefined
  chatCentral: string | null | undefined
}): string | null {
  const { chatDoCliente, paraCentral, chatIdExplicito, perfil, chatCentral } = entrada
  if (!paraCentral && chatDoCliente) return chatDoCliente
  if (!paraCentral && typeof chatIdExplicito === 'string' && chatIdExplicito.trim()
    && ['administrador', 'gestor'].includes(perfil ?? '')) return chatIdExplicito.trim()
  return chatCentral || null
}

export const MSG_SEM_DESTINO = 'Destino não configurado para este cliente.'

/** Resposta da rota quando não há destino: envio omitido, não erro. */
export const RESPOSTA_SEM_DESTINO = {
  status: 200,
  corpo: { ok: false, omitido: true, motivo: 'destino_nao_configurado', error: MSG_SEM_DESTINO },
} as const
