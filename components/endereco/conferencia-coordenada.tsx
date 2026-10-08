'use client'

/**
 * Conferência da coordenada antes de salvar a escolta (M1): mapa com pino, aviso de
 * sugestão sem número, "Conferido no mapa" e "Salvar este endereço como local".
 */
import { useState } from 'react'
import { AlertTriangle, CheckCircle2, Star } from 'lucide-react'
import { MapaPino } from '@/components/mapa/mapa-pino'

export function ConferenciaCoordenada({
  lat, lng, conferida, semNumero, viaLocal, podeSalvarLocal, onMover, onConferir, onSalvarLocal,
}: {
  lat: number | null
  lng: number | null
  conferida: boolean
  semNumero: boolean
  /** Veio de um local salvo ativo: coordenada já conferida. */
  viaLocal: string | null
  podeSalvarLocal: boolean
  onMover: (lat: number, lng: number) => void
  onConferir: (v: boolean) => void
  onSalvarLocal: (nome: string) => Promise<string | null>
}) {
  const [nome, setNome] = useState('')
  const [salvando, setSalvando] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  if (!lat || !lng) return null
  if (viaLocal) {
    return (
      <p className="flex items-center gap-1.5 mt-1.5" style={{ fontSize: '11px', color: '#1E7C52' }}>
        <CheckCircle2 size={13} /> {`Local salvo "${viaLocal}", coordenada conferida.`}
      </p>
    )
  }
  return (
    <div className="mt-2 space-y-2" data-teste="conferencia-coordenada">
      {semNumero && (
        <p className="flex items-start gap-1.5 p-2" style={{ fontSize: '11px', color: '#8A5A10', backgroundColor: '#FFF7E6', borderRadius: '4px' }}>
          <AlertTriangle size={13} style={{ flexShrink: 0, marginTop: 1 }} />
          A sugestão escolhida não tem número: a busca pode ter posto o ponto no meio da rua, no bairro ou na cidade. Confira e arraste o pino até o portão.
        </p>
      )}
      <MapaPino lat={lat} lng={lng} onMover={(a, b) => { onMover(a, b); onConferir(false) }} />
      <label className="flex items-center gap-2 font-bold" style={{ fontSize: '12px', color: conferida ? '#1E7C52' : '#1E2D35' }}>
        <input type="checkbox" checked={conferida} onChange={e => onConferir(e.target.checked)} />
        Conferido no mapa: o pino está no lugar certo
      </label>
      {podeSalvarLocal && (
        <div className="flex gap-2 items-center">
          <input value={nome} onChange={e => setNome(e.target.value)} maxLength={40} placeholder="Nome do atalho (ex.: JAMEF)" className="input-light flex-1 text-xs" />
          <button type="button" disabled={salvando || nome.trim().length < 2}
            onClick={async () => { setSalvando(true); setMsg(await onSalvarLocal(nome.trim())); setSalvando(false) }}
            className="inline-flex items-center gap-1 px-3 text-[11px] font-bold disabled:opacity-50"
            style={{ minHeight: '34px', border: '1.5px solid #D6DAE5', borderRadius: '4px', color: '#1E2D35' }}>
            <Star size={12} /> Salvar este endereço como local
          </button>
        </div>
      )}
      {msg && <p style={{ fontSize: '11px', color: '#5A6A80' }}>{msg}</p>}
    </div>
  )
}
