'use client'

/**
 * Mapa com pino arrastável (lote 2026-10, M1 e M2). Sem token da Mapbox no ambiente,
 * mostra latitude e longitude editáveis e avisa que o mapa está indisponível.
 */
import { useEffect, useRef } from 'react'
import 'mapbox-gl/dist/mapbox-gl.css'

export function MapaPino({ lat, lng, onMover, altura = 220 }: {
  lat: number | null
  lng: number | null
  onMover: (lat: number, lng: number) => void
  altura?: number
}) {
  const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN
  const caixa = useRef<HTMLDivElement>(null)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const mapa = useRef<any>(null)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const pino = useRef<any>(null)
  const moverRef = useRef(onMover)
  moverRef.current = onMover

  useEffect(() => {
    if (!token || !caixa.current || mapa.current) return
    let vivo = true
    import('mapbox-gl').then(({ default: mapboxgl }) => {
      if (!vivo || !caixa.current) return
      mapboxgl.accessToken = token
      const centro: [number, number] = [lng ?? -43.1729, lat ?? -22.9068]
      mapa.current = new mapboxgl.Map({ container: caixa.current, style: 'mapbox://styles/mapbox/streets-v12', center: centro, zoom: lat != null ? 16 : 10 })
      pino.current = new mapboxgl.Marker({ draggable: true, color: '#B83832' }).setLngLat(centro).addTo(mapa.current)
      pino.current.on('dragend', () => { const p = pino.current.getLngLat(); moverRef.current(p.lat, p.lng) })
      mapa.current.on('click', (ev: { lngLat: { lat: number; lng: number } }) => {
        pino.current.setLngLat([ev.lngLat.lng, ev.lngLat.lat]); moverRef.current(ev.lngLat.lat, ev.lngLat.lng)
      })
    })
    return () => { vivo = false; mapa.current?.remove(); mapa.current = null }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token])

  // Coordenada trocada por fora (atalho, nova sugestão): leva o pino e o mapa até ela.
  useEffect(() => {
    if (!mapa.current || !pino.current || lat == null || lng == null) return
    const atual = pino.current.getLngLat()
    if (Math.abs(atual.lat - lat) < 1e-7 && Math.abs(atual.lng - lng) < 1e-7) return
    pino.current.setLngLat([lng, lat]); mapa.current.flyTo({ center: [lng, lat], zoom: 16 })
  }, [lat, lng])

  if (!token) {
    return (
      <div className="p-3 space-y-2" style={{ border: '1.5px dashed #D6DAE5', borderRadius: '4px', backgroundColor: '#F8FAFC' }} data-teste="mapa-indisponivel">
        <p style={{ fontSize: '11px', color: '#5A6A80' }}>Mapa indisponível neste ambiente. Confira a coordenada pelos números.</p>
        <div className="grid grid-cols-2 gap-2">
          <label style={{ fontSize: '10px', color: '#5A6A80' }}>Latitude
            <input type="number" step="0.000001" value={lat ?? ''} onChange={e => { const v = parseFloat(e.target.value); if (Number.isFinite(v)) onMover(v, lng ?? 0) }} className="input-light w-full text-xs mt-0.5" />
          </label>
          <label style={{ fontSize: '10px', color: '#5A6A80' }}>Longitude
            <input type="number" step="0.000001" value={lng ?? ''} onChange={e => { const v = parseFloat(e.target.value); if (Number.isFinite(v)) onMover(lat ?? 0, v) }} className="input-light w-full text-xs mt-0.5" />
          </label>
        </div>
      </div>
    )
  }
  return <div ref={caixa} style={{ height: altura, borderRadius: '4px', overflow: 'hidden', border: '1.5px solid #D6DAE5' }} data-teste="mapa-pino" />
}
