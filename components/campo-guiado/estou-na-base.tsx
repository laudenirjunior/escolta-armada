'use client'

/**
 * "Estou na base" no Painel Guiado (T2, lote 2026-10). Aparece para a equipe escalada
 * a partir do início da janela; depois de confirmado, ninguém assume a escolta.
 */
import { useCallback, useEffect, useState } from 'react'
import { CheckCircle2, Clock } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { InfoMural, lerInfoMural, confirmarPresencaBase, horaBrasilia, lerGps } from '@/lib/mural'
import { lerEstadoEnvio } from '@/lib/offline/envio'
import {
  MENSAGEM_GUARDADO, aparelhoSemRede, envelopeLigado, gravarPeloEnvelope, textoConflito, textoErroGravacao, textoRecusado,
} from '@/lib/offline/tela'

// Onda L: o último estado lido do mural fica no aparelho, para o botão aparecer sem rede.
const CHAVE_MURAL = 'escolta-campo:mural:'
function guardarInfo(escoltaId: string, info: InfoMural | null) {
  try { if (info) globalThis.localStorage?.setItem(CHAVE_MURAL + escoltaId, JSON.stringify(info)) } catch { /* sem memória */ }
}
function infoGuardada(escoltaId: string): InfoMural | null {
  try { const s = globalThis.localStorage?.getItem(CHAVE_MURAL + escoltaId); return s ? (JSON.parse(s) as InfoMural) : null } catch { return null }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

export function EstouNaBase({ escoltaId }: { escoltaId: string }) {
  const [info, setInfo] = useState<InfoMural | null>(null)
  const [ativo, setAtivo] = useState(false)
  const [enviando, setEnviando] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; texto: string } | null>(null)
  // Onda L: presença guardada no aparelho, ainda não enviada.
  const [guardada, setGuardada] = useState(false)
  const carregar = useCallback(async () => {
    const lido = await lerInfoMural(sb, [escoltaId])
    if (lido.falhou && aparelhoSemRede()) {
      // Sem rede: o último estado guardado (o servidor confere a janela no envio).
      const guardada = infoGuardada(escoltaId)
      if (guardada) { setAtivo(true); setInfo(atual => atual ?? guardada) }
      return
    }
    setAtivo(lido.ativo)
    setInfo(lido.info[escoltaId] ?? null)
    guardarInfo(escoltaId, lido.info[escoltaId] ?? null)
  }, [escoltaId])
  useEffect(() => {
    carregar()
    const t = setInterval(carregar, 30_000)
    return () => clearInterval(t)
  }, [carregar])

  if (!ativo || !info) return null
  if (guardada && !info.eu_confirmei) {
    return (
      <p data-teste="presenca-guardada" className="flex items-center gap-2 font-bold" style={{ fontSize: '16px', color: '#9A6A00' }}>
        <Clock size={18} /> Presença guardada no aparelho. {MENSAGEM_GUARDADO.replace('Guardado no aparelho. ', '')}
      </p>
    )
  }
  if (info.eu_confirmei) {
    return (
      <p className="flex items-center gap-2 font-bold" style={{ fontSize: '16px', color: '#1E7C52' }}>
        <CheckCircle2 size={18} /> Presença na base confirmada
      </p>
    )
  }
  if (Date.now() < new Date(info.janela_inicio).getTime()) {
    return (
      <p className="flex items-center gap-2" style={{ fontSize: '15px', color: '#5A6A80' }}>
        <Clock size={16} /> Confirmação de presença na base a partir das {horaBrasilia(info.janela_inicio)}
      </p>
    )
  }
  return (
    <div className="space-y-2">
      <button type="button" disabled={enviando}
        onClick={async () => {
          setEnviando(true)
          // Onda L: pelo envelope (tipo presenca_base, a RPC da 204 no servidor); sem rede,
          // guardada no aparelho. Com a chave desligada, a chamada direta de sempre.
          const env = await envelopeLigado()
          if (env.usar) {
            try {
              const gps = await lerGps()
              const r = await gravarPeloEnvelope({ authUserId: lerEstadoEnvio().authUserId, usuarioId: null }, {
                tipo: 'presenca_base', escoltaId, versaoGestao: null,
                gps, presenca: { latitude: gps?.lat ?? null, longitude: gps?.lng ?? null, precisao: gps?.precisao ?? null },
              })
              if (r.modo === 'guardado') {
                setMsg(null)
                setGuardada(true)
              } else if (r.modo === 'recusado') setMsg({ ok: false, texto: textoRecusado(r.erro) })
              else if (r.resultado === 'conflito') setMsg({ ok: false, texto: textoConflito(r.motivo) })
              else setMsg({ ok: true, texto: 'Presença confirmada.' })
            } catch (e) {
              setMsg({ ok: false, texto: textoErroGravacao(e, 'Não foi possível confirmar a presença.') })
            }
            setEnviando(false)
            if (!aparelhoSemRede()) await carregar()
            return
          }
          const erro = await confirmarPresencaBase(sb, escoltaId)
          setMsg(erro ? { ok: false, texto: erro } : { ok: true, texto: 'Presença confirmada.' })
          setEnviando(false)
          await carregar()
        }}
        className="w-full flex items-center justify-center gap-2 font-black uppercase text-white disabled:opacity-50"
        style={{ minHeight: '56px', fontSize: '16px', backgroundColor: '#1E7C52', borderRadius: '4px' }}>
        <CheckCircle2 size={20} /> {enviando ? 'Confirmando...' : 'Estou na base'}
      </button>
      {msg && <p style={{ fontSize: '14px', color: msg.ok ? '#1E7C52' : '#B83832' }}>{msg.texto}</p>}
    </div>
  )
}
