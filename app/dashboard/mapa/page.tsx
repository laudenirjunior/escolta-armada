'use client'

import { useEffect, useRef, useState, useCallback } from 'react'
import mapboxgl from 'mapbox-gl'
import 'mapbox-gl/dist/mapbox-gl.css'
import { MapPin, Navigation, ArrowRight, RefreshCw, ExternalLink } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'

const MAPBOX_TOKEN = process.env.NEXT_PUBLIC_MAPBOX_TOKEN ?? ''

interface EscoltaAtiva {
  id: string
  codigo_escolta: string | null
  status: string
  origem_lat: number | null
  origem_lng: number | null
  destino_lat: number | null
  destino_lng: number | null
  origem_endereco: string
  destino_endereco: string
  cliente: { nome_cliente: string } | null
}

const STATUS_MAP: Record<string, { label: string; cls: string; color: string }> = {
  em_pre_inicio: { label: 'Pré-Início',   cls: 'badge-warning', color: '#D97706' },
  em_andamento:  { label: 'Em Andamento', cls: 'badge-info',    color: '#2563EB' },
  na_origem:     { label: 'Na Origem',    cls: 'badge-info',    color: '#7C3AED' },
  no_destino:    { label: 'No Destino',   cls: 'badge-success', color: '#059669' },
  retornando:    { label: 'Retornando',   cls: 'badge-warning', color: '#D97706' },
  na_base:       { label: 'Na Base',      cls: 'badge-success', color: '#1E7C52' },
}

const STATUS_ATIVOS = ['em_pre_inicio', 'em_andamento', 'na_origem', 'no_destino', 'retornando', 'na_base']

const sb = createClient() as any

function buildGoogleMapsUrl(lat: number, lng: number): string {
  return `https://www.google.com/maps?q=${lat},${lng}`
}

export default function MapaPage() {
  useAuth()
  const [escoltas, setEscoltas]       = useState<EscoltaAtiva[]>([])
  const [selecionada, setSelecionada] = useState<EscoltaAtiva | null>(null)
  const [loading, setLoading]         = useState(true)
  const [lastUpdate, setLastUpdate]   = useState<Date>(new Date())
  const [mapReady, setMapReady]       = useState(false)

  const mapContainerRef = useRef<HTMLDivElement>(null)
  const mapRef          = useRef<mapboxgl.Map | null>(null)
  const markersRef      = useRef<mapboxgl.Marker[]>([])
  const destMarkerRef   = useRef<mapboxgl.Marker | null>(null)

  // ── Carregar escoltas ────────────────────────────────────────────────────────
  const carregar = useCallback(async () => {
    setLoading(true)
    const { data } = await sb
      .from('escoltas')
      .select(`
        id, codigo_escolta, status,
        origem_lat, origem_lng, destino_lat, destino_lng,
        origem_endereco, destino_endereco,
        cliente:clientes(nome_cliente)
      `)
      .in('status', STATUS_ATIVOS)
      .order('status')

    const lista = (data ?? []) as EscoltaAtiva[]
    setEscoltas(lista)
    setLastUpdate(new Date())
    if (lista.length > 0 && !selecionada) setSelecionada(lista[0])
    setLoading(false)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    carregar()
    const interval = setInterval(carregar, 60000)
    return () => clearInterval(interval)
  }, [carregar])

  // ── Inicializar mapa Mapbox ──────────────────────────────────────────────────
  useEffect(() => {
    if (!mapContainerRef.current || mapRef.current || !MAPBOX_TOKEN) return

    mapboxgl.accessToken = MAPBOX_TOKEN

    const map = new mapboxgl.Map({
      container: mapContainerRef.current,
      style: 'mapbox://styles/mapbox/streets-v12',
      center: [-43.1729, -22.9068], // Rio de Janeiro
      zoom: 10,
      attributionControl: false,
    })

    map.addControl(new mapboxgl.NavigationControl({ showCompass: false }), 'top-right')
    map.addControl(new mapboxgl.AttributionControl({ compact: true }), 'bottom-right')

    map.on('load', () => {
      // Camada de rota (linha tracejada)
      map.addSource('route', {
        type: 'geojson',
        data: { type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: [] } },
      })
      map.addLayer({
        id: 'route-line',
        type: 'line',
        source: 'route',
        paint: {
          'line-color': '#1A294A',
          'line-width': 2.5,
          'line-dasharray': [5, 3],
          'line-opacity': 0.75,
        },
      })
      setMapReady(true)
    })

    mapRef.current = map
    return () => {
      map.remove()
      mapRef.current = null
      setMapReady(false)
    }
  }, [])

  // ── Atualizar marcadores quando a lista de escoltas muda ─────────────────────
  useEffect(() => {
    if (!mapRef.current || !mapReady) return

    // Remove marcadores antigos
    markersRef.current.forEach(m => m.remove())
    markersRef.current = []

    escoltas.forEach((e) => {
      if (!e.origem_lat || !e.origem_lng) return

      const statusInfo = STATUS_MAP[e.status] ?? { color: '#53648A', label: e.status }

      // Elemento do marcador customizado
      const el = document.createElement('div')
      el.style.cssText = `
        width: 32px; height: 32px; border-radius: 50%;
        background-color: ${statusInfo.color};
        border: 3px solid white;
        box-shadow: 0 2px 8px rgba(0,0,0,0.3);
        cursor: pointer;
        display: flex; align-items: center; justify-content: center;
        transition: transform 0.15s ease;
      `
      el.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="white"><path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z"/></svg>`

      el.addEventListener('mouseenter', () => { el.style.transform = 'scale(1.2)' })
      el.addEventListener('mouseleave', () => { el.style.transform = 'scale(1)' })

      const popup = new mapboxgl.Popup({ offset: 20, closeButton: false })
        .setHTML(`
          <div style="font-family: system-ui; padding: 2px 0;">
            <p style="font-size:11px;font-weight:800;color:#0E1A33;margin:0">${e.codigo_escolta ?? '—'}</p>
            <p style="font-size:10px;color:#5A6A80;margin:2px 0 0">${e.cliente?.nome_cliente ?? '—'}</p>
            <p style="font-size:9px;color:${statusInfo.color};font-weight:700;margin:3px 0 0;text-transform:uppercase">${statusInfo.label}</p>
          </div>
        `)

      const marker = new mapboxgl.Marker({ element: el })
        .setLngLat([e.origem_lng, e.origem_lat])
        .setPopup(popup)
        .addTo(mapRef.current!)

      el.addEventListener('click', () => setSelecionada(e))
      markersRef.current.push(marker)
    })
  }, [escoltas, mapReady])

  // ── Voar para a escolta selecionada e desenhar rota ──────────────────────────
  useEffect(() => {
    if (!mapRef.current || !mapReady || !selecionada) return
    if (!selecionada.origem_lat || !selecionada.origem_lng) return

    const map = mapRef.current

    // Remove marcador de destino anterior
    destMarkerRef.current?.remove()
    destMarkerRef.current = null

    // Atualiza linha de rota
    const hasDestino = !!(selecionada.destino_lat && selecionada.destino_lng)
    const coords = hasDestino
      ? [[selecionada.origem_lng, selecionada.origem_lat], [selecionada.destino_lng!, selecionada.destino_lat!]]
      : []

    const source = map.getSource('route') as mapboxgl.GeoJSONSource | undefined
    if (source) {
      source.setData({
        type: 'Feature',
        properties: {},
        geometry: { type: 'LineString', coordinates: coords },
      })
    }

    // Marcador de destino
    if (hasDestino) {
      const elDest = document.createElement('div')
      elDest.style.cssText = `
        width: 28px; height: 28px; border-radius: 50%;
        background-color: #B83832;
        border: 3px solid white;
        box-shadow: 0 2px 8px rgba(0,0,0,0.3);
        display: flex; align-items: center; justify-content: center;
      `
      elDest.innerHTML = `<svg width="12" height="12" viewBox="0 0 24 24" fill="white"><path d="M21 3L3 10.53v.98l6.84 2.65L12.48 21h.98L21 3z"/></svg>`

      destMarkerRef.current = new mapboxgl.Marker({ element: elDest })
        .setLngLat([selecionada.destino_lng!, selecionada.destino_lat!])
        .setPopup(new mapboxgl.Popup({ offset: 20, closeButton: false }).setHTML(
          `<div style="font-family:system-ui;font-size:10px;font-weight:700;color:#B83832">DESTINO</div>
           <div style="font-family:system-ui;font-size:11px;color:#0E1A33;margin-top:2px">${selecionada.destino_endereco}</div>`
        ))
        .addTo(map)
    }

    // Ajusta câmera para mostrar origem + destino
    if (hasDestino) {
      const bounds = new mapboxgl.LngLatBounds()
      bounds.extend([selecionada.origem_lng, selecionada.origem_lat])
      bounds.extend([selecionada.destino_lng!, selecionada.destino_lat!])
      map.fitBounds(bounds, { padding: { top: 60, bottom: 60, left: 60, right: 60 }, duration: 900, maxZoom: 14 })
    } else {
      map.flyTo({ center: [selecionada.origem_lng, selecionada.origem_lat], zoom: 13, duration: 900 })
    }
  }, [selecionada, mapReady])

  const escoltaComCoordenadas = escoltas.filter(e => e.origem_lat && e.origem_lng)

  return (
    <div className="space-y-5">

      {/* ── Header ── */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="page-title">Mapa de Operações</h1>
          <p className="page-subtitle">
            Visualização em tempo real · Atualizado às {lastUpdate.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
          </p>
        </div>
        <button onClick={carregar} className="btn-outline flex items-center gap-2" disabled={loading}>
          <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
          Atualizar
        </button>
      </div>

      {/* ── Stats ── */}
      <div className="grid grid-cols-3 gap-4">
        <div className="card-light p-4 text-center">
          <p className="text-2xl font-black" style={{ color: '#1E2D35' }}>{escoltas.length}</p>
          <p className="text-xs uppercase tracking-wider mt-1" style={{ color: '#6B7E8A' }}>Escoltas Ativas</p>
        </div>
        <div className="card-light p-4 text-center">
          <p className="text-2xl font-black" style={{ color: '#1E2D35' }}>{escoltaComCoordenadas.length}</p>
          <p className="text-xs uppercase tracking-wider mt-1" style={{ color: '#6B7E8A' }}>Com Coordenadas</p>
        </div>
        <div className="card-light p-4 text-center">
          <p className="text-2xl font-black" style={{ color: '#1E2D35' }}>
            {escoltas.filter(e => ['em_andamento', 'na_origem', 'no_destino', 'retornando'].includes(e.status)).length}
          </p>
          <p className="text-xs uppercase tracking-wider mt-1" style={{ color: '#6B7E8A' }}>Em Trânsito</p>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5" style={{ minHeight: '540px' }}>

        {/* ── Painel lateral de escoltas ── */}
        <div className="card-light flex flex-col" style={{ maxHeight: '600px' }}>
          <div className="px-4 py-3 border-b" style={{ borderColor: '#E2E8EC' }}>
            <h2 className="text-sm font-bold" style={{ color: '#1E2D35' }}>Escoltas em Campo</h2>
            <p className="text-[11px] mt-0.5" style={{ color: '#6B7E8A' }}>Clique para centralizar no mapa</p>
          </div>

          <div className="flex-1 overflow-y-auto">
            {loading ? (
              <div className="py-12 flex items-center justify-center gap-2">
                <div className="w-4 h-4 rounded-full border-2 animate-spin"
                  style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
                <span className="text-xs" style={{ color: '#6B7E8A' }}>Carregando...</span>
              </div>
            ) : escoltas.length === 0 ? (
              <div className="py-12 text-center px-4">
                <MapPin size={28} className="mx-auto mb-2" style={{ color: '#E2E8EC' }} />
                <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Nenhuma escolta ativa</p>
                <p className="text-xs mt-1" style={{ color: '#A8B8C2' }}>Aguardando operações em campo</p>
              </div>
            ) : (
              escoltas.map((e) => {
                const s = STATUS_MAP[e.status] ?? { label: e.status, cls: 'badge-neutral', color: '#53648A' }
                const isSelected = selecionada?.id === e.id
                return (
                  <button
                    key={e.id}
                    onClick={() => setSelecionada(e)}
                    className="w-full text-left px-4 py-3 transition-all border-b"
                    style={{
                      borderColor: '#E2E8EC',
                      backgroundColor: isSelected ? 'rgba(26,41,74,0.06)' : '',
                      borderLeft: isSelected ? `3px solid ${s.color}` : '3px solid transparent',
                    }}
                    onMouseEnter={ev => { if (!isSelected) (ev.currentTarget as HTMLElement).style.backgroundColor = '#F8FAFC' }}
                    onMouseLeave={ev => { if (!isSelected) (ev.currentTarget as HTMLElement).style.backgroundColor = '' }}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <p className="text-xs font-mono font-bold" style={{ color: '#1E2D35' }}>
                          {e.codigo_escolta ?? 'Sem código'}
                        </p>
                        <p className="text-[11px] truncate mt-0.5" style={{ color: '#6B7E8A' }}>
                          {e.cliente?.nome_cliente ?? '—'}
                        </p>
                      </div>
                      <span
                        className="shrink-0 text-[9px] font-black uppercase tracking-wider px-1.5 py-0.5"
                        style={{ backgroundColor: `${s.color}18`, color: s.color, border: `1px solid ${s.color}30` }}
                      >
                        {s.label}
                      </span>
                    </div>
                    <div className="mt-2 space-y-1">
                      <div className="flex items-center gap-1">
                        <div style={{ width: 7, height: 7, borderRadius: '50%', backgroundColor: s.color, flexShrink: 0 }} />
                        <span className="text-[10px] truncate" style={{ color: '#A8B8C2' }}>{e.origem_endereco}</span>
                      </div>
                      {e.destino_endereco && (
                        <div className="flex items-center gap-1">
                          <div style={{ width: 7, height: 7, borderRadius: '50%', backgroundColor: '#B83832', flexShrink: 0 }} />
                          <span className="text-[10px] truncate" style={{ color: '#A8B8C2' }}>{e.destino_endereco}</span>
                        </div>
                      )}
                    </div>
                    {!e.origem_lat && (
                      <p className="text-[9px] mt-1.5" style={{ color: '#E2C8C8' }}>Sem coordenadas</p>
                    )}
                  </button>
                )
              })
            )}
          </div>

          {/* Legenda */}
          <div className="px-4 py-3 border-t" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8FAFC' }}>
            <p className="text-[9px] font-bold uppercase tracking-widest mb-2" style={{ color: '#A8B8C2' }}>Legenda</p>
            <div className="flex flex-wrap gap-x-3 gap-y-1">
              {Object.entries(STATUS_MAP).map(([, v]) => (
                <div key={v.label} className="flex items-center gap-1">
                  <div style={{ width: 8, height: 8, borderRadius: '50%', backgroundColor: v.color }} />
                  <span style={{ fontSize: '9px', color: '#6B7E8A' }}>{v.label}</span>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* ── Mapa Mapbox ── */}
        <div className="lg:col-span-2 card-light flex flex-col overflow-hidden" style={{ minHeight: '540px' }}>

          {/* Cabeçalho do mapa */}
          {selecionada && (
            <div className="px-4 py-3 border-b flex items-center justify-between shrink-0" style={{ borderColor: '#E2E8EC' }}>
              <div className="min-w-0">
                <p className="text-sm font-bold truncate" style={{ color: '#1E2D35' }}>
                  {selecionada.codigo_escolta ?? 'Escolta sem código'}
                  {selecionada.cliente && (
                    <span className="font-normal ml-2" style={{ color: '#6B7E8A' }}>
                      — {selecionada.cliente.nome_cliente}
                    </span>
                  )}
                </p>
                <div className="flex items-center gap-1.5 mt-0.5">
                  <span className="text-[10px] truncate max-w-[200px]" style={{ color: '#6B7E8A' }}>{selecionada.origem_endereco}</span>
                  <ArrowRight size={9} style={{ color: '#C8D5DC', flexShrink: 0 }} />
                  <span className="text-[10px] truncate max-w-[200px]" style={{ color: '#6B7E8A' }}>{selecionada.destino_endereco}</span>
                </div>
              </div>
              {selecionada.origem_lat && selecionada.origem_lng && (
                <a
                  href={buildGoogleMapsUrl(selecionada.origem_lat, selecionada.origem_lng)}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="btn-outline text-xs flex items-center gap-1.5 shrink-0 ml-3"
                >
                  <ExternalLink size={12} />
                  Google Maps
                </a>
              )}
            </div>
          )}

          {/* Container do mapa */}
          <div className="flex-1 relative" style={{ minHeight: '460px' }}>
            {!MAPBOX_TOKEN || MAPBOX_TOKEN.includes('COLE_SUA') ? (
              <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-slate-50">
                <MapPin size={32} style={{ color: '#C8D5DC' }} />
                <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Token Mapbox não configurado</p>
                <p className="text-xs" style={{ color: '#A8B8C2' }}>Adicione NEXT_PUBLIC_MAPBOX_TOKEN no .env.local</p>
              </div>
            ) : (
              <>
                <div ref={mapContainerRef} style={{ width: '100%', height: '100%', minHeight: '460px' }} />
                {!selecionada && (
                  <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 pointer-events-none"
                    style={{ backgroundColor: 'rgba(255,255,255,0.7)' }}>
                    <Navigation size={28} style={{ color: '#C8D5DC' }} />
                    <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Selecione uma escolta</p>
                  </div>
                )}
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
