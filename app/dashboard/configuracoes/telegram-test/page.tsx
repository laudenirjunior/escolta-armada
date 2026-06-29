'use client'

import { useState } from 'react'
import { Send, CheckCircle2, AlertTriangle, Camera, Bot } from 'lucide-react'

export default function TelegramTestPage() {
  const [chatId, setChatId] = useState('')
  const [tipo, setTipo] = useState('status')
  const [titulo, setTitulo] = useState('Teste de Notificação')
  const [descricao, setDescricao] = useState('Esta é uma mensagem de teste da plataforma Escolta Armada.')
  const [escoltaCodigo, setEscoltaCodigo] = useState('ESC-2026-0001')
  const [efetivo, setEfetivo] = useState('João Silva')
  const [fotoUrl, setFotoUrl] = useState('')
  const [enviando, setEnviando] = useState(false)
  const [resultado, setResultado] = useState<{ ok: boolean; msg: string } | null>(null)

  const enviar = async () => {
    if (!chatId.trim()) { setResultado({ ok: false, msg: 'Informe o Chat ID.' }); return }
    setEnviando(true)
    setResultado(null)
    try {
      const resp = await fetch('/api/telegram', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          tipo,
          titulo,
          descricao,
          escolta_codigo: escoltaCodigo || null,
          efetivo: efetivo || null,
          foto_url: fotoUrl || null,
          chat_id: chatId,
        }),
      })
      const data = await resp.json()
      if (resp.ok && data.ok) {
        setResultado({ ok: true, msg: '✅ Mensagem enviada com sucesso!' })
      } else {
        setResultado({ ok: false, msg: `❌ Erro: ${data.error ?? resp.statusText}` })
      }
    } catch (e: any) {
      setResultado({ ok: false, msg: `❌ Erro: ${e.message}` })
    } finally {
      setEnviando(false)
    }
  }

  const verificarChat = async () => {
    if (!chatId.trim()) return
    try {
      const resp = await fetch(`/api/telegram?chat_id=${encodeURIComponent(chatId)}`)
      const data = await resp.json()
      if (data.ok) {
        setResultado({ ok: true, msg: `✅ Chat encontrado: "${data.result?.title ?? data.result?.first_name ?? 'Chat'}" (${data.result?.type})` })
      } else {
        setResultado({ ok: false, msg: `❌ Chat não encontrado: ${data.description ?? 'verifique o chat_id'}` })
      }
    } catch (e: any) {
      setResultado({ ok: false, msg: `❌ Erro: ${e.message}` })
    }
  }

  const label = 'block text-xs font-black uppercase tracking-widest mb-1'
  const input = 'w-full h-9 px-3 rounded-sm text-sm border border-white/10 bg-white/5 text-white placeholder-white/20 outline-none focus:border-[#53648A]/60'

  return (
    <div className="space-y-5 max-w-xl">
      <div>
        <div className="eyebrow-tag mb-2"><Bot size={10} />Telegram · Teste de Integração</div>
        <h1 className="page-title">Teste do Bot Telegram</h1>
        <p className="page-subtitle">Envie uma notificação de teste para verificar a integração com o @Esquematiza_bot.</p>
      </div>

      {/* Instruções */}
      <div className="card-bezel p-4 space-y-2">
        <p className="text-xs font-black uppercase tracking-widest text-white/40 mb-3">Como obter o Chat ID</p>
        <ol className="space-y-2 text-sm text-white/60 list-decimal list-inside">
          <li>Adicione o bot <strong className="text-white">@Esquematiza_bot</strong> ao seu grupo/canal no Telegram</li>
          <li>Envie qualquer mensagem no grupo (ex: <code className="bg-white/5 px-1 rounded text-xs">/start</code>)</li>
          <li>Use o campo abaixo com <strong className="text-white">@nome_do_grupo</strong> (ex: <code className="bg-white/5 px-1 rounded text-xs">@meu_grupo</code>) ou o ID numérico</li>
          <li>Clique em <strong className="text-white">Verificar Chat</strong> primeiro para confirmar</li>
        </ol>
      </div>

      <div className="card-bezel p-5 space-y-4">
        {/* Chat ID */}
        <div>
          <label className={label} style={{ color: 'rgba(255,255,255,0.4)' }}>Chat ID ou @username *</label>
          <div className="flex gap-2">
            <input className={input} style={{ flex: 1 }} value={chatId} onChange={e => setChatId(e.target.value)} placeholder="-100123456789 ou @meu_grupo" />
            <button
              onClick={verificarChat}
              className="px-3 h-9 text-xs font-black uppercase tracking-wider rounded-sm border border-white/10 text-white/60 hover:bg-white/5 transition-colors"
            >
              Verificar
            </button>
          </div>
        </div>

        {/* Tipo */}
        <div>
          <label className={label} style={{ color: 'rgba(255,255,255,0.4)' }}>Tipo de evento</label>
          <select className={input} value={tipo} onChange={e => setTipo(e.target.value)} style={{ cursor: 'pointer' }}>
            <option value="status">Status</option>
            <option value="ponto_controle">Check-in / Ponto de Controle</option>
            <option value="ocorrencia">Ocorrência</option>
            <option value="presenca">Presença</option>
            <option value="chat">Mensagem Interna</option>
          </select>
        </div>

        {/* Título e descrição */}
        <div className="grid grid-cols-1 gap-3">
          <div>
            <label className={label} style={{ color: 'rgba(255,255,255,0.4)' }}>Título</label>
            <input className={input} value={titulo} onChange={e => setTitulo(e.target.value)} />
          </div>
          <div>
            <label className={label} style={{ color: 'rgba(255,255,255,0.4)' }}>Descrição</label>
            <input className={input} value={descricao} onChange={e => setDescricao(e.target.value)} />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className={label} style={{ color: 'rgba(255,255,255,0.4)' }}>Código da Escolta</label>
            <input className={input} value={escoltaCodigo} onChange={e => setEscoltaCodigo(e.target.value)} placeholder="ESC-2026-0001" />
          </div>
          <div>
            <label className={label} style={{ color: 'rgba(255,255,255,0.4)' }}>Efetivo</label>
            <input className={input} value={efetivo} onChange={e => setEfetivo(e.target.value)} placeholder="Nome do vigilante" />
          </div>
        </div>

        <div>
          <label className={label} style={{ color: 'rgba(255,255,255,0.4)' }}>
            <Camera size={10} style={{ display: 'inline', marginRight: '4px' }} />
            URL da Foto (opcional)
          </label>
          <input className={input} value={fotoUrl} onChange={e => setFotoUrl(e.target.value)} placeholder="https://... (URL pública da imagem)" />
        </div>

        {/* Resultado */}
        {resultado && (
          <div style={{
            padding: '10px 14px',
            borderRadius: '2px',
            backgroundColor: resultado.ok ? 'rgba(30,124,82,0.12)' : 'rgba(184,56,50,0.12)',
            border: `1px solid ${resultado.ok ? 'rgba(30,124,82,0.3)' : 'rgba(184,56,50,0.3)'}`,
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
          }}>
            {resultado.ok ? <CheckCircle2 size={14} style={{ color: '#1E7C52', flexShrink: 0 }} /> : <AlertTriangle size={14} style={{ color: '#B83832', flexShrink: 0 }} />}
            <p style={{ fontSize: '12px', color: resultado.ok ? '#1E7C52' : '#B83832', fontWeight: 700 }}>{resultado.msg}</p>
          </div>
        )}

        {/* Botão enviar */}
        <button
          onClick={enviar}
          disabled={enviando || !chatId.trim()}
          className="w-full py-3 rounded-sm text-white font-black text-sm uppercase tracking-wider flex items-center justify-center gap-2 transition-all active:scale-[0.98] disabled:opacity-50"
          style={{ backgroundColor: '#1A294A' }}
        >
          <Send size={14} />
          {enviando ? 'Enviando...' : 'Enviar Mensagem de Teste'}
        </button>
      </div>
    </div>
  )
}
