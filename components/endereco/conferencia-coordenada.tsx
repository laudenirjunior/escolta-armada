'use client'

/**
 * Conferência da coordenada antes de salvar a escolta (M1): mapa com pino, aviso de
 * sugestão sem número e "Conferido no mapa". Onda D2: "Salvar este endereço" saiu daqui
 * para o lado do campo (components/endereco/salvar-endereco-local.tsx).
 */
import { AlertTriangle, CheckCircle2 } from 'lucide-react'
import { MapaPino } from '@/components/mapa/mapa-pino'

export function ConferenciaCoordenada({
  lat, lng, conferida, semNumero, viaLocal, uf, onMover, onConferir,
}: {
  lat: number | null
  lng: number | null
  conferida: boolean
  semNumero: boolean
  /** Veio de um local salvo ativo: coordenada já conferida. */
  viaLocal: string | null
  /** UF preenchida pelo atalho (onda D2). */
  uf?: string
  onMover: (lat: number, lng: number) => void
  onConferir: (v: boolean) => void
}) {
  if (!lat || !lng) return null
  if (viaLocal) {
    return (
      <p className="flex items-center gap-1.5 mt-1.5" style={{ fontSize: '11px', color: '#1E7C52' }} data-teste="via-local">
        <CheckCircle2 size={13} /> {`Local salvo "${viaLocal}", coordenada conferida.${uf ? ` UF ${uf}.` : ''}`}
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
    </div>
  )
}
