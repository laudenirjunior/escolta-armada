interface TelegramPayload {
  tipo: string
  titulo: string
  descricao: string
  escolta_codigo?: string | null
  efetivo?: string | null
  veiculo?: string | null
  foto_url?: string | null
  chat_id: string
}

export async function enviarTelegram(payload: TelegramPayload): Promise<boolean> {
  try {
    const resp = await fetch('/api/telegram', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    return resp.ok
  } catch {
    return false
  }
}
