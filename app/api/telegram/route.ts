import { NextRequest, NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { exigirSessao, dentroDoLimite, escaparHtml } from '@/lib/api-auth'

// Antes esta rota nao exigia nada. Qualquer um podia mandar mensagem em nome
// do bot para qualquer chat, e o GET ?action=updates despejava as conversas
// recentes dele para chamador anonimo.
const LIMITE_ENVIOS_POR_MINUTO = 30

const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN
const BASE_URL = `https://api.telegram.org/bot${BOT_TOKEN}`

if (!BOT_TOKEN) {
  console.warn('[telegram] TELEGRAM_BOT_TOKEN não configurado no .env.local')
}

async function sendMessage(chatId: string, text: string) {
  return fetch(`${BASE_URL}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'HTML', disable_web_page_preview: true }),
  })
}

async function sendPhoto(chatId: string, photoUrl: string, caption: string) {
  return fetch(`${BASE_URL}/sendPhoto`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, photo: photoUrl, caption, parse_mode: 'HTML' }),
  })
}

const EMOJI: Record<string, string> = {
  ponto_controle:  '📍',
  ocorrencia:      '⚠️',
  status:          '🔄',
  presenca:        '✅',
  alerta_checkin:  '🔔',
  default:         '📋',
}

// POST /api/telegram
export async function POST(req: NextRequest) {
  if (!BOT_TOKEN) {
    return NextResponse.json({ error: 'TELEGRAM_BOT_TOKEN não configurado' }, { status: 500 })
  }
  const auth = await exigirSessao()
  if (!auth.ok) {
    return NextResponse.json({ error: auth.erro }, { status: auth.status })
  }
  if (!dentroDoLimite('tg:' + auth.sessao.usuarioId, LIMITE_ENVIOS_POR_MINUTO, 60_000)) {
    return NextResponse.json({ error: 'Muitas mensagens. Aguarde um minuto.' }, { status: 429 })
  }

  try {
    const body = await req.json()
    const {
      tipo,
      titulo,
      texto_completo,
      descricao,
      escolta_id,
      escolta_codigo,
      cliente,
      status_atual,
      efetivos,
      veiculo,
      foto_url,
      data_hora,
      chat_id,
    } = body

    // O chat_id vinha do cliente: qualquer um usava o bot para mandar mensagem
    // a qualquer destino. Agora e resolvido no servidor a partir da escolta.
    let destChatId: string | undefined
    if (escolta_id) {
      const sb = createClient()
      const { data } = await sb
        .from('escoltas')
        .select('cliente:clientes(telegram_chat_id)')
        .eq('id', escolta_id)
        .maybeSingle()
      const cli = (data as unknown as { cliente: { telegram_chat_id: string | null } | null } | null)?.cliente
      destChatId = cli?.telegram_chat_id ?? undefined
    }
    // Um chat_id explicito so e aceito de quem administra as integracoes.
    if (!destChatId && chat_id && ['administrador', 'gestor'].includes(auth.sessao.perfil)) {
      destChatId = chat_id
    }
    destChatId = destChatId ?? process.env.TELEGRAM_CHAT_ID
    if (!destChatId) {
      return NextResponse.json({ error: 'Destino não configurado para este cliente.' }, { status: 400 })
    }

    let texto: string

    if (texto_completo) {
      // Mensagem pré-formatada (ex: relatório de finalização)
      texto = texto_completo
    } else {
      const emoji = EMOJI[tipo] ?? EMOJI.default
      const agora = data_hora ?? new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })
      const appUrl = process.env.NEXT_PUBLIC_APP_URL ?? 'http://localhost:3000'

      texto = `${emoji} <b>${escaparHtml(String(titulo ?? ""))}</b>\n\n`
      texto += `📅 <b>Data e Hora:</b> ${escaparHtml(String(agora))}\n`
      if (escolta_codigo) texto += `🔖 <b>Escolta:</b> <code>${escaparHtml(String(escolta_codigo))}</code>\n`
      if (cliente)        texto += `🏢 <b>Cliente:</b> ${escaparHtml(String(cliente))}\n`
      if (status_atual)   texto += `🔄 <b>Status:</b> ${escaparHtml(String(status_atual))}\n`
      if (veiculo)        texto += `🚗 <b>Viatura:</b> <code>${escaparHtml(String(veiculo))}</code>\n`

      if (Array.isArray(efetivos) && efetivos.length > 0) {
        texto += `\n👥 <b>Efetivos:</b>\n`
        for (const nome of efetivos) texto += `  • ${escaparHtml(String(nome))}\n`
      }

      if (descricao?.trim()) texto += `\n📝 <i>${descricao.trim()}</i>\n`

      if (escolta_id) {
        texto += `\n🔗 <a href="${appUrl}/dashboard/escoltas/${escolta_id}">Abrir Escolta ${escolta_codigo ?? ''}</a>`
      }
    }

    // Finalização: texto primeiro (longo), depois foto separada (sem limite de caption)
    if (tipo === 'finalizacao') {
      const msgResp = await sendMessage(destChatId, texto)
      if (!msgResp.ok) {
        const err = await msgResp.text()
        console.error('[telegram] sendMessage (finalizacao) falhou:', err)
        return NextResponse.json({ error: err }, { status: 500 })
      }
      if (foto_url) {
        const caption = `📷 Última foto — Escolta ${escolta_codigo ?? ''}`
        const photoResp = await sendPhoto(destChatId, foto_url, caption)
        if (!photoResp.ok) {
          console.warn('[telegram] sendPhoto (finalizacao) falhou:', await photoResp.text())
        }
      }
      return NextResponse.json({ ok: true })
    }

    // Demais eventos: foto com caption se houver, senão só texto
    let enviado = false
    if (foto_url) {
      const resp = await sendPhoto(destChatId, foto_url, texto.slice(0, 1024))
      if (resp.ok) {
        enviado = true
      } else {
        console.warn('[telegram] sendPhoto falhou:', await resp.text())
      }
    }

    if (!enviado) {
      const resp = await sendMessage(destChatId, texto)
      if (!resp.ok) {
        const err = await resp.text()
        console.error('[telegram] sendMessage falhou:', err)
        return NextResponse.json({ error: err }, { status: 500 })
      }
    }

    return NextResponse.json({ ok: true })
  } catch (err: any) {
    console.error('[telegram]', err)
    return NextResponse.json({ error: err.message }, { status: 500 })
  }
}

// GET /api/telegram?action=me|updates|verify&chat_id=xxx
export async function GET(req: NextRequest) {
  if (!BOT_TOKEN) {
    return NextResponse.json({ error: 'TELEGRAM_BOT_TOKEN não configurado no .env.local' }, { status: 500 })
  }

  const auth = await exigirSessao()
  if (!auth.ok) {
    return NextResponse.json({ error: auth.erro }, { status: auth.status })
  }
  if (!['administrador', 'gestor'].includes(auth.sessao.perfil)) {
    return NextResponse.json({ error: 'Permissão negada.' }, { status: 403 })
  }

  const action = req.nextUrl.searchParams.get('action') ?? 'verify'
  const chatId = req.nextUrl.searchParams.get('chat_id')

  if (action === 'me') {
    const resp = await fetch(`${BASE_URL}/getMe`)
    const data = await resp.json()
    return NextResponse.json(data)
  }

  if (action === 'updates') {
    const resp = await fetch(`${BASE_URL}/getUpdates?limit=20`)
    const data = await resp.json()
    if (!data.ok) return NextResponse.json(data, { status: 400 })

    const chats = new Map<string, { id: string; tipo: string; nome: string; ultimaMensagem: string }>()
    for (const upd of data.result ?? []) {
      const msg = upd.message ?? upd.channel_post ?? upd.my_chat_member?.chat
      if (!msg) continue
      const chat = msg.chat ?? msg
      if (!chat?.id) continue
      const id = String(chat.id)
      if (!chats.has(id)) {
        chats.set(id, {
          id,
          tipo: chat.type ?? 'desconhecido',
          nome: chat.title ?? chat.first_name ?? chat.username ?? id,
          ultimaMensagem: msg.text ?? msg.caption ?? '',
        })
      }
    }
    return NextResponse.json({ ok: true, chats: Array.from(chats.values()) })
  }

  if (action === 'verify' || chatId) {
    if (!chatId) return NextResponse.json({ error: 'Informe ?chat_id=...' }, { status: 400 })
    const resp = await fetch(`${BASE_URL}/getChat?chat_id=${chatId}`)
    const data = await resp.json()
    return NextResponse.json(data)
  }

  return NextResponse.json({ error: 'Ação inválida. Use ?action=me|updates|verify&chat_id=xxx' }, { status: 400 })
}
