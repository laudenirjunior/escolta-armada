'use client'

import { useState } from 'react'
import { Send, Bot, Search, CheckCircle2, XCircle, Loader2, Copy, Radio, RefreshCw } from 'lucide-react'

const P = {
  navy:    '#1A294A',
  steel:   '#53648A',
  light:   '#ABB5C9',
  bg:      '#EEF0F5',
  surface: '#FFFFFF',
  border:  '#D4D9E6',
  text:    '#0E1A33',
  sub:     '#5A6A80',
  muted:   '#8899AA',
}

interface ChatInfo {
  id: string
  tipo: string
  nome: string
  ultimaMensagem: string
}

interface BotInfo {
  id: number
  first_name: string
  username: string
  can_join_groups: boolean
  can_read_all_group_messages: boolean
}

export default function TelegramPage() {
  const [botInfo, setBotInfo] = useState<BotInfo | null>(null)
  const [chats, setChats] = useState<ChatInfo[]>([])
  const [chatIdManual, setChatIdManual] = useState('')
  const [chatIdTestado, setChatIdTestado] = useState<{ id: string; nome: string } | null>(null)
  const [msgTeste, setMsgTeste] = useState('🔔 Teste de notificação — Escolta Armada funcionando!')

  const [loadingBot, setLoadingBot] = useState(false)
  const [loadingUpdates, setLoadingUpdates] = useState(false)
  const [loadingVerify, setLoadingVerify] = useState(false)
  const [loadingEnvio, setLoadingEnvio] = useState(false)

  const [resultadoEnvio, setResultadoEnvio] = useState<{ ok: boolean; msg: string } | null>(null)
  const [erro, setErro] = useState<string | null>(null)

  async function carregarBot() {
    setLoadingBot(true)
    setErro(null)
    try {
      const r = await fetch('/api/telegram?action=me')
      const d = await r.json()
      if (d.ok) setBotInfo(d.result)
      else setErro(d.description ?? 'Erro ao consultar bot')
    } catch {
      setErro('Falha de conexão com a API do Telegram')
    } finally {
      setLoadingBot(false)
    }
  }

  async function buscarChats() {
    setLoadingUpdates(true)
    setErro(null)
    try {
      const r = await fetch('/api/telegram?action=updates')
      const d = await r.json()
      if (d.ok) {
        setChats(d.chats)
        if (d.chats.length === 0) {
          setErro('Nenhuma mensagem recente encontrada. Envie /start ao bot no Telegram e tente novamente.')
        }
      } else {
        setErro(d.description ?? 'Erro ao buscar atualizações')
      }
    } catch {
      setErro('Falha de conexão')
    } finally {
      setLoadingUpdates(false)
    }
  }

  async function verificarChatManual() {
    if (!chatIdManual.trim()) return
    setLoadingVerify(true)
    setErro(null)
    setChatIdTestado(null)
    try {
      const r = await fetch(`/api/telegram?action=verify&chat_id=${encodeURIComponent(chatIdManual.trim())}`)
      const d = await r.json()
      if (d.ok) {
        const nome = d.result?.title ?? d.result?.first_name ?? d.result?.username ?? chatIdManual
        setChatIdTestado({ id: chatIdManual.trim(), nome })
      } else {
        setErro(d.description ?? 'Chat não encontrado ou bot sem acesso')
      }
    } catch {
      setErro('Falha de conexão')
    } finally {
      setLoadingVerify(false)
    }
  }

  async function enviarTeste(chatId: string) {
    setLoadingEnvio(true)
    setResultadoEnvio(null)
    setErro(null)
    try {
      const r = await fetch('/api/telegram', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          tipo: 'default',
          titulo: 'Teste de Notificação',
          descricao: msgTeste,
          escolta_codigo: 'ESC-2026-TESTE',
          efetivo: 'Admin Sistema',
          chat_id: chatId,
        }),
      })
      const d = await r.json()
      if (d.ok) {
        setResultadoEnvio({ ok: true, msg: `✅ Mensagem enviada para o chat ${chatId}!` })
      } else {
        setResultadoEnvio({ ok: false, msg: d.error ?? 'Erro ao enviar' })
      }
    } catch {
      setResultadoEnvio({ ok: false, msg: 'Falha de conexão com a API' })
    } finally {
      setLoadingEnvio(false)
    }
  }

  function copiar(texto: string) {
    navigator.clipboard.writeText(texto)
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px', maxWidth: '760px' }}>

      {/* Header */}
      <div>
        <div className="eyebrow-tag mb-2">
          <Radio size={10} />Sistema · Integração
        </div>
        <h1 className="page-title" style={{ marginBottom: '2px' }}>Telegram · Configuração</h1>
        <p className="page-subtitle">Configure e teste o envio de notificações via bot do Telegram</p>
      </div>

      {/* Erro global */}
      {erro && (
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px', padding: '12px 14px', backgroundColor: '#FAEAE9', border: '1px solid rgba(184,56,50,0.2)', borderRadius: '2px' }}>
          <XCircle size={14} style={{ color: '#B83832', flexShrink: 0 }} />
          <p style={{ fontSize: '12px', color: '#B83832', fontWeight: 600 }}>{erro}</p>
        </div>
      )}

      {/* Passo 1: Verificar bot */}
      <div style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', overflow: 'hidden' }}>
        <div className="cc-panel-header">
          <Bot size={11} />
          Passo 1 — Verificar Bot
        </div>
        <div style={{ padding: '16px' }}>
          <p style={{ fontSize: '12px', color: P.sub, marginBottom: '12px', lineHeight: 1.6 }}>
            Clique em <strong>Verificar Bot</strong> para confirmar que o token está configurado corretamente e o bot está ativo.
          </p>
          <button
            onClick={carregarBot}
            disabled={loadingBot}
            style={{ display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 16px', backgroundColor: loadingBot ? P.light : P.navy, color: '#fff', border: 'none', borderRadius: '2px', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', cursor: loadingBot ? 'not-allowed' : 'pointer' }}
          >
            {loadingBot ? <Loader2 size={12} className="animate-spin" /> : <Bot size={12} />}
            Verificar Bot
          </button>

          {botInfo && (
            <div style={{ marginTop: '14px', padding: '12px 14px', backgroundColor: '#E6F4ED', border: '1px solid rgba(30,124,82,0.2)', borderRadius: '2px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '8px' }}>
                <CheckCircle2 size={14} style={{ color: '#1E7C52' }} />
                <span style={{ fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#1E7C52' }}>Bot Ativo</span>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
                <p style={{ fontSize: '12px', color: P.text }}><strong>Nome:</strong> {botInfo.first_name}</p>
                <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <p style={{ fontSize: '12px', color: P.text }}><strong>Username:</strong> @{botInfo.username}</p>
                  <a
                    href={`https://t.me/${botInfo.username}`}
                    target="_blank"
                    rel="noopener noreferrer"
                    style={{ fontSize: '10px', color: P.steel, fontWeight: 700, textDecoration: 'underline' }}
                  >
                    Abrir no Telegram ↗
                  </a>
                </div>
                <p style={{ fontSize: '12px', color: P.text }}><strong>ID:</strong> {botInfo.id}</p>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Passo 2: Descobrir chat_id */}
      <div style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', overflow: 'hidden' }}>
        <div className="cc-panel-header">
          <Search size={11} />
          Passo 2 — Descobrir o Chat ID
        </div>
        <div style={{ padding: '16px', display: 'flex', flexDirection: 'column', gap: '14px' }}>

          {/* Opção A: automático */}
          <div>
            <p style={{ fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.sub, marginBottom: '6px' }}>
              Opção A — Detectar automaticamente
            </p>
            <p style={{ fontSize: '12px', color: P.sub, marginBottom: '10px', lineHeight: 1.6 }}>
              1. Abra o Telegram e procure pelo bot <strong>@{botInfo?.username ?? 'seu bot'}</strong><br />
              2. Adicione o bot ao seu grupo/canal <em>ou</em> inicie uma conversa direta e envie qualquer mensagem<br />
              3. Clique em <strong>Buscar Chats</strong> abaixo
            </p>
            <button
              onClick={buscarChats}
              disabled={loadingUpdates}
              style={{ display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '8px 16px', backgroundColor: loadingUpdates ? P.light : P.steel, color: '#fff', border: 'none', borderRadius: '2px', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', cursor: loadingUpdates ? 'not-allowed' : 'pointer' }}
            >
              {loadingUpdates ? <Loader2 size={12} className="animate-spin" /> : <RefreshCw size={12} />}
              Buscar Chats
            </button>

            {chats.length > 0 && (
              <div style={{ marginTop: '12px', display: 'flex', flexDirection: 'column', gap: '6px' }}>
                {chats.map(c => (
                  <div key={c.id} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 14px', backgroundColor: P.bg, border: `1px solid ${P.border}`, borderRadius: '2px' }}>
                    <div>
                      <p style={{ fontSize: '12px', fontWeight: 700, color: P.text }}>{c.nome}</p>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginTop: '2px' }}>
                        <span style={{ fontSize: '10px', color: P.muted, textTransform: 'uppercase', letterSpacing: '0.1em' }}>{c.tipo}</span>
                        <span style={{ fontSize: '11px', fontFamily: 'monospace', color: P.sub }}>{c.id}</span>
                      </div>
                      {c.ultimaMensagem && (
                        <p style={{ fontSize: '10px', color: P.muted, marginTop: '2px', fontStyle: 'italic' }}>"{c.ultimaMensagem.slice(0, 60)}{c.ultimaMensagem.length > 60 ? '…' : ''}"</p>
                      )}
                    </div>
                    <div style={{ display: 'flex', gap: '6px', flexShrink: 0 }}>
                      <button
                        onClick={() => copiar(c.id)}
                        title="Copiar chat_id"
                        style={{ width: '30px', height: '30px', display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', cursor: 'pointer', color: P.sub }}
                      >
                        <Copy size={12} />
                      </button>
                      <button
                        onClick={() => enviarTeste(c.id)}
                        disabled={loadingEnvio}
                        style={{ display: 'inline-flex', alignItems: 'center', gap: '5px', padding: '0 12px', height: '30px', backgroundColor: P.navy, color: '#fff', border: 'none', borderRadius: '2px', fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', cursor: loadingEnvio ? 'not-allowed' : 'pointer' }}
                      >
                        {loadingEnvio ? <Loader2 size={10} className="animate-spin" /> : <Send size={10} />}
                        Testar
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          <div style={{ borderTop: `1px solid ${P.border}`, paddingTop: '14px' }}>
            <p style={{ fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.sub, marginBottom: '8px' }}>
              Opção B — Informar chat_id manualmente
            </p>
            <p style={{ fontSize: '12px', color: P.sub, marginBottom: '10px', lineHeight: 1.6 }}>
              Se você já conhece o chat_id (ex: <code style={{ fontSize: '11px', backgroundColor: P.bg, padding: '1px 5px', borderRadius: '2px' }}>-1001234567890</code> para grupos), cole abaixo:
            </p>
            <div style={{ display: 'flex', gap: '8px' }}>
              <input
                value={chatIdManual}
                onChange={e => setChatIdManual(e.target.value)}
                placeholder="Ex: -1001234567890 ou @canal"
                onKeyDown={e => { if (e.key === 'Enter') verificarChatManual() }}
                style={{ flex: 1, height: '38px', padding: '0 12px', backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', fontSize: '12px', color: P.text, outline: 'none', fontFamily: 'monospace' }}
              />
              <button
                onClick={verificarChatManual}
                disabled={loadingVerify || !chatIdManual.trim()}
                style={{ display: 'inline-flex', alignItems: 'center', gap: '6px', padding: '0 16px', height: '38px', backgroundColor: chatIdManual.trim() ? P.steel : P.light, color: '#fff', border: 'none', borderRadius: '2px', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', cursor: (!chatIdManual.trim() || loadingVerify) ? 'not-allowed' : 'pointer' }}
              >
                {loadingVerify ? <Loader2 size={12} className="animate-spin" /> : <Search size={12} />}
                Verificar
              </button>
            </div>

            {chatIdTestado && (
              <div style={{ marginTop: '10px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 14px', backgroundColor: '#E6F4ED', border: '1px solid rgba(30,124,82,0.2)', borderRadius: '2px' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <CheckCircle2 size={14} style={{ color: '#1E7C52' }} />
                  <div>
                    <p style={{ fontSize: '12px', fontWeight: 700, color: P.text }}>{chatIdTestado.nome}</p>
                    <p style={{ fontSize: '11px', fontFamily: 'monospace', color: P.sub }}>{chatIdTestado.id}</p>
                  </div>
                </div>
                <button
                  onClick={() => enviarTeste(chatIdTestado.id)}
                  disabled={loadingEnvio}
                  style={{ display: 'inline-flex', alignItems: 'center', gap: '5px', padding: '0 14px', height: '32px', backgroundColor: P.navy, color: '#fff', border: 'none', borderRadius: '2px', fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', cursor: loadingEnvio ? 'not-allowed' : 'pointer' }}
                >
                  {loadingEnvio ? <Loader2 size={10} className="animate-spin" /> : <Send size={10} />}
                  Enviar Teste
                </button>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Passo 3: Mensagem de teste */}
      <div style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', overflow: 'hidden' }}>
        <div className="cc-panel-header">
          <Send size={11} />
          Passo 3 — Mensagem de Teste
        </div>
        <div style={{ padding: '16px' }}>
          <p style={{ fontSize: '12px', color: P.sub, marginBottom: '10px', lineHeight: 1.6 }}>
            Personalize a mensagem que será enviada no teste:
          </p>
          <textarea
            value={msgTeste}
            onChange={e => setMsgTeste(e.target.value)}
            rows={3}
            style={{ width: '100%', padding: '10px 12px', backgroundColor: P.bg, border: `1px solid ${P.border}`, borderRadius: '2px', fontSize: '12px', color: P.text, outline: 'none', resize: 'vertical', fontFamily: 'inherit', boxSizing: 'border-box' }}
          />
          <p style={{ fontSize: '10px', color: P.muted, marginTop: '6px' }}>
            O envio de teste inclui automaticamente: título, código de escolta fictício (ESC-2026-TESTE), efetivo e horário.
          </p>
        </div>
      </div>

      {/* Resultado do envio */}
      {resultadoEnvio && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: '10px',
          padding: '14px 16px', borderRadius: '2px', border: '1px solid',
          backgroundColor: resultadoEnvio.ok ? '#E6F4ED' : '#FAEAE9',
          borderColor: resultadoEnvio.ok ? 'rgba(30,124,82,0.2)' : 'rgba(184,56,50,0.2)',
        }}>
          {resultadoEnvio.ok
            ? <CheckCircle2 size={16} style={{ color: '#1E7C52', flexShrink: 0 }} />
            : <XCircle size={16} style={{ color: '#B83832', flexShrink: 0 }} />}
          <p style={{ fontSize: '13px', fontWeight: 600, color: resultadoEnvio.ok ? '#1E7C52' : '#B83832' }}>
            {resultadoEnvio.msg}
          </p>
        </div>
      )}

      {/* Próximos passos */}
      <div style={{ backgroundColor: '#EBF0F8', border: `1px solid #C8D4E8`, borderRadius: '2px', padding: '14px 16px' }}>
        <p style={{ fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.steel, marginBottom: '8px' }}>
          Próximos Passos
        </p>
        <ul style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: '6px' }}>
          {[
            'Copie o chat_id do grupo/canal onde as notificações devem chegar',
            'Cole em TELEGRAM_CHAT_ID= no arquivo .env.local',
            'Reinicie o servidor (npm run dev) para carregar a variável',
            'As notificações serão enviadas automaticamente ao criar pontos de controle e ocorrências',
          ].map((s, i) => (
            <li key={i} style={{ display: 'flex', alignItems: 'flex-start', gap: '8px', fontSize: '12px', color: P.sub, lineHeight: 1.5 }}>
              <span style={{ width: '18px', height: '18px', flexShrink: 0, borderRadius: '50%', backgroundColor: P.steel, color: '#fff', fontSize: '9px', fontWeight: 900, display: 'flex', alignItems: 'center', justifyContent: 'center', marginTop: '1px' }}>{i + 1}</span>
              {s}
            </li>
          ))}
        </ul>
      </div>

    </div>
  )
}
