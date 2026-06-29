'use client'

import { useEffect, useRef, useState, useCallback } from 'react'
import mapboxgl from 'mapbox-gl'
import 'mapbox-gl/dist/mapbox-gl.css'
import { MapPin, Navigation, ArrowRight, RefreshCw, ExternalLink } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'

const MAPBOX_TOKEN = process.env.NEXT_PUBLIC_MAPBOX_TOKEN ?? ''
const sb = createClient() as any

// ── Tipos -------------------------------------------------------------------

interface UltimoPonto {
  lat: number
  lng: number
  data_hora: string
  tipo: string
  endereco?: string | null
}

interface HistoricoPos {
  lat: number
  lng: number
  data_hora: string
}

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
  viatura_id: string | null
  ultimo_ponto: UltimoPonto | null
}

interface MarkerSet {
  pos: mapboxgl.Marker
  orig: mapboxgl.Marker
  dest: mapboxgl.Marker | null
}

// ── Constantes --------------------------------------------------------------

const STATUS_MAP: Record<string, { label: string; color: string }> = {
  em_pre_inicio: { label: 'Pré-Início',   color: '#D97706' },
  em_andamento:  { label: 'Em Andamento', color: '#2563EB' },
  na_origem:     { label: 'Na Origem',    color: '#7C3AED' },
  no_destino:    { label: 'No Destino',   color: '#059669' },
  retornando:    { label: 'Retornando',   color: '#D97706' },
  na_base:       { label: 'Na Base',      color: '#1E7C52' },
}

const STATUS_ATIVOS = ['em_pre_inicio', 'em_andamento', 'na_origem', 'no_destino', 'retornando', 'na_base']

// ── Helpers -----------------------------------------------------------------

function tempoAtras(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'agora'
  if (mins < 60) return `${mins}min atrás`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24) return `${hrs}h${mins % 60 > 0 ? ` ${mins % 60}min` : ''} atrás`
  return `${Math.floor(hrs / 24)}d atrás`
}

function corSinal(iso: string): string {
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60000)
  if (mins < 30) return '#1E7C52'
  if (mins < 90) return '#D97706'
  return '#B83832'
}

function buildGMapsUrl(lat: number, lng: number) {
  return `https://www.google.com/maps?q=${lat},${lng}`
}

function criarElOrigem(color: string): HTMLElement {
  const el = document.createElement('div')
  el.title = 'ORIGEM'
  el.style.cssText = `
    width:12px; height:12px; border-radius:50%;
    background:${color}; border:2.5px solid #fff;
    box-shadow:0 1px 6px rgba(0,0,0,0.35);
  `
  return el
}

function criarElDestino(): HTMLElement {
  const el = document.createElement('div')
  el.title = 'DESTINO'
  el.style.cssText = `
    width:0; height:0;
    border-left:8px solid transparent;
    border-right:8px solid transparent;
    border-bottom:16px solid #B83832;
    filter:drop-shadow(0 2px 4px rgba(0,0,0,0.35));
  `
  return el
}

function criarElPosicao(code: string, color: string): HTMLElement {
  const el = document.createElement('div')
  el.style.cssText = `position:relative; cursor:pointer; width:32px; height:32px;`
  el.innerHTML = `
    <div style="
      position:absolute; inset:-8px; border-radius:50%;
      background:${color}33;
      animation:pulse-ring 2.4s ease-out infinite;
      pointer-events:none;
    "></div>
    <div style="
      position:relative;
      width:32px; height:32px; border-radius:50%;
      background:${color};
      border:3px solid #fff;
      box-shadow:0 3px 14px ${color}66;
      display:flex; align-items:center; justify-content:center;
      z-index:1;
    ">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="white">
        <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z"/>
      </svg>
    </div>
    <div style="
      position:absolute; top:36px; left:50%; transform:translateX(-50%);
      background:${color}; color:#fff;
      padding:2px 6px;
      font-size:9px; font-weight:900; font-family:monospace;
      text-transform:uppercase; letter-spacing:0.05em;
      white-space:nowrap;
      box-shadow:0 2px 8px rgba(0,0,0,0.25);
      pointer-events:none;
    ">${code}</div>
  `
  return el
}

function popupHTML(e: EscoltaAtiva): string {
  const s = STATUS_MAP[e.status] ?? { label: e.status, color: '#53648A' }
  const pt = e.ultimo_ponto
  return `
    <div style="font-family:system-ui;padding:4px 0;min-width:160px">
      <div style="font-size:12px;font-weight:800;color:#0E1A33">${e.codigo_escolta ?? '—'}</div>
      <div style="font-size:11px;color:#5A6A80;margin:2px 0 4px">${e.cliente?.nome_cliente ?? '—'}</div>
      <span style="font-size:9px;font-weight:700;padding:1px 6px;background:${s.color}22;color:${s.color};text-transform:uppercase">${s.label}</span>
      ${pt ? `
        <div style="margin-top:6px;padding-top:5px;border-top:1px solid #f0f0f0">
          <div style="font-size:10px;font-weight:700;color:${corSinal(pt.data_hora)}">${pt.tipo} · ${tempoAtras(pt.data_hora)}</div>
          ${pt.endereco ? `<div style="font-size:9px;color:#8B9BAD;margin-top:2px">${pt.endereco.substring(0, 70)}</div>` : ''}
        </div>
      ` : `<div style="font-size:9px;color:#9CA3AF;margin-top:5px">Posição: coordenadas de origem</div>`}
    </div>
  `
}

// ── Componente Principal ----------------------------------------------------

export default function MapaPage() {
  useAuth()
  const [escoltas, setEscoltas]         = useState<EscoltaAtiva[]>([])
  const [selecionada, setSelecionada]   = useState<EscoltaAtiva | null>(null)
  const [historico, setHistorico]       = useState<HistoricoPos[]>([])
  const [loading, setLoading]           = useState(true)
  const [lastUpdate, setLastUpdate]     = useState<Date>(new Date())
  const [mapReady, setMapReady]         = useState(false)
  const [tick, setTick]                 = useState(0) // força re-render para "X min atrás"

  const mapContainerRef = useRef<HTMLDivElement>(null)
  const mapRef          = useRef<mapboxgl.Map | null>(null)
  const markersRef      = useRef<Map<string, MarkerSet>>(new Map())

  // Atualiza contadores de tempo a cada minuto
  useEffect(() => {
    const t = setInterval(() => setTick(n => n + 1), 60000)
    return () => clearInterval(t)
  }, [])
  void tick // usado indiretamente pelo render

  // ── Carregar dados ----------------------------------------------------------
  const carregar = useCallback(async () => {
    setLoading(true)
    try {
      const { data: raw } = await sb
        .from('escoltas')
        .select(`
          id, codigo_escolta, status,
          origem_lat, origem_lng, destino_lat, destino_lng,
          origem_endereco, destino_endereco,
          cliente:clientes(nome_cliente),
          veiculos:escolta_veiculos(id)
        `)
        .in('status', STATUS_ATIVOS)
        .order('status')

      if (!raw?.length) {
        setEscoltas([])
        setLastUpdate(new Date())
        setLoading(false)
        return
      }

      // IDs de todos os veículos das escoltas ativas
      const viaturaIds: string[] = (raw as any[]).flatMap(e =>
        (e.veiculos ?? []).map((v: any) => v.id)
      )

      // Último ponto_controle com GPS por viatura
      let ultimosPontos: Record<string, any> = {}
      if (viaturaIds.length > 0) {
        const { data: pontos } = await sb
          .from('pontos_controle')
          .select('escolta_veiculo_id, latitude, longitude, data_hora, observacoes, tipo_ponto:dom_tipo_ponto(nome)')
          .in('escolta_veiculo_id', viaturaIds)
          .not('latitude', 'is', null)
          .not('longitude', 'is', null)
          .order('data_hora', { ascending: false })
          .limit(viaturaIds.length * 15)

        // Simulação de DISTINCT ON: primeiro = mais recente (já ordenado DESC)
        for (const pt of (pontos ?? []) as any[]) {
          if (!ultimosPontos[pt.escolta_veiculo_id]) {
            ultimosPontos[pt.escolta_veiculo_id] = pt
          }
        }
      }

      const lista: EscoltaAtiva[] = (raw as any[]).map(e => {
        const vt = e.veiculos?.[0]
        const ulPt = vt ? ultimosPontos[vt.id] : null
        let ultimoPonto: UltimoPonto | null = null
        if (ulPt?.latitude && ulPt?.longitude) {
          let endereco: string | null = null
          try { endereco = JSON.parse(ulPt.observacoes ?? '{}').endereco ?? null } catch {}
          ultimoPonto = {
            lat: ulPt.latitude,
            lng: ulPt.longitude,
            data_hora: ulPt.data_hora,
            tipo: ulPt.tipo_ponto?.nome ?? 'Reporte',
            endereco,
          }
        }
        return {
          id: e.id,
          codigo_escolta: e.codigo_escolta,
          status: e.status,
          origem_lat: e.origem_lat,
          origem_lng: e.origem_lng,
          destino_lat: e.destino_lat,
          destino_lng: e.destino_lng,
          origem_endereco: e.origem_endereco,
          destino_endereco: e.destino_endereco,
          cliente: e.cliente,
          viatura_id: vt?.id ?? null,
          ultimo_ponto: ultimoPonto,
        }
      })

      setEscoltas(lista)
      setLastUpdate(new Date())
      setSelecionada(prev => {
        if (!prev) return lista[0] ?? null
        return lista.find(e => e.id === prev.id) ?? prev
      })
    } finally {
      setLoading(false)
    }
  }, [])

  // Histórico de posições para breadcrumb
  const carregarHistorico = useCallback(async (e: EscoltaAtiva) => {
    if (!e.viatura_id) { setHistorico([]); return }
    const { data } = await sb
      .from('pontos_controle')
      .select('latitude, longitude, data_hora')
      .eq('escolta_veiculo_id', e.viatura_id)
      .not('latitude', 'is', null)
      .not('longitude', 'is', null)
      .order('data_hora', { ascending: true })
      .limit(50)
    setHistorico((data ?? []).map((p: any) => ({ lat: p.latitude, lng: p.longitude, data_hora: p.data_hora })))
  }, [])

  useEffect(() => {
    carregar()
    const iv = setInterval(carregar, 30000)
    return () => clearInterval(iv)
  }, [carregar])

  useEffect(() => {
    if (selecionada) carregarHistorico(selecionada)
    else setHistorico([])
  }, [selecionada, carregarHistorico])

  // ── Realtime: novo ponto_controle ------------------------------------------
  useEffect(() => {
    const ch = sb.channel('mapa-realtime-pontos')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'pontos_controle' },
        async (payload: any) => {
          const pt = payload.new
          if (!pt.latitude || !pt.longitude) return
          const { data: vt } = await sb
            .from('escolta_veiculos').select('escolta_id').eq('id', pt.escolta_veiculo_id).maybeSingle()
          if (!vt) return
          let endereco: string | null = null
          try { endereco = JSON.parse(pt.observacoes ?? '{}').endereco ?? null } catch {}
          const novoPonto: UltimoPonto = { lat: pt.latitude, lng: pt.longitude, data_hora: pt.data_hora, tipo: 'Reporte', endereco }
          setEscoltas(prev => prev.map(e => e.id === vt.escolta_id ? { ...e, ultimo_ponto: novoPonto } : e))
          setSelecionada(prev => (prev?.id === vt.escolta_id && prev) ? ({ ...prev, ultimo_ponto: novoPonto } as EscoltaAtiva) : prev)
          setHistorico(prev => {
            // só adiciona se a escolta selecionada é a mesma
            return prev
          })
        }
      )
      .subscribe()
    return () => { sb.removeChannel(ch) }
  }, [])

  // ── Realtime: status da escolta muda ---------------------------------------
  useEffect(() => {
    const ch = sb.channel('mapa-realtime-status')
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'escoltas' }, () => carregar())
      .subscribe()
    return () => { sb.removeChannel(ch) }
  }, [carregar])

  // ── Inicializar mapa -------------------------------------------------------
  useEffect(() => {
    if (!mapContainerRef.current || mapRef.current || !MAPBOX_TOKEN) return
    mapboxgl.accessToken = MAPBOX_TOKEN
    const map = new mapboxgl.Map({
      container: mapContainerRef.current,
      style: 'mapbox://styles/mapbox/light-v11',
      center: [-43.1729, -22.9068],
      zoom: 10,
      attributionControl: false,
    })
    map.addControl(new mapboxgl.NavigationControl({ showCompass: false }), 'top-right')
    map.addControl(new mapboxgl.AttributionControl({ compact: true }), 'bottom-right')
    map.on('load', () => {
      // Rota percorrida (sólida colorida)
      map.addSource('rota-traj', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } })
      map.addLayer({
        id: 'rota-traj-line', type: 'line', source: 'rota-traj',
        paint: { 'line-color': ['get', 'cor'], 'line-width': 3, 'line-opacity': 0.9 },
      })
      // Rota restante (tracejada cinza)
      map.addSource('rota-rest', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } })
      map.addLayer({
        id: 'rota-rest-line', type: 'line', source: 'rota-rest',
        paint: { 'line-color': '#9CA3AF', 'line-width': 2, 'line-opacity': 0.45, 'line-dasharray': [4, 3] },
      })
      // Breadcrumb dots
      map.addSource('breadcrumb', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } })
      map.addLayer({
        id: 'breadcrumb-dots', type: 'circle', source: 'breadcrumb',
        paint: { 'circle-radius': 4, 'circle-color': ['get', 'cor'], 'circle-opacity': 0.55, 'circle-stroke-color': '#fff', 'circle-stroke-width': 1.5 },
      })
      setMapReady(true)
    })
    mapRef.current = map
    return () => { map.remove(); mapRef.current = null; setMapReady(false) }
  }, [])

  // ── Atualizar marcadores no mapa -------------------------------------------
  useEffect(() => {
    if (!mapRef.current || !mapReady) return
    const map = mapRef.current

    // Remove marcadores de escoltas que saíram da lista
    const idsAtivos = new Set(escoltas.map(e => e.id))
    markersRef.current.forEach((ms, id) => {
      if (!idsAtivos.has(id)) {
        ms.pos.remove(); ms.orig.remove(); ms.dest?.remove()
        markersRef.current.delete(id)
      }
    })

    escoltas.forEach(e => {
      const s = STATUS_MAP[e.status] ?? { color: '#53648A', label: e.status }
      const posLat = e.ultimo_ponto?.lat ?? e.origem_lat
      const posLng = e.ultimo_ponto?.lng ?? e.origem_lng
      if (posLat == null || posLng == null) return

      const existing = markersRef.current.get(e.id)
      if (existing) {
        existing.pos.setLngLat([posLng, posLat])
        existing.pos.getPopup()?.setHTML(popupHTML(e))
      } else {
        // Criar marcadores
        const origEl = criarElOrigem(s.color)
        const origMarker = e.origem_lat && e.origem_lng
          ? new mapboxgl.Marker({ element: origEl })
              .setLngLat([e.origem_lng, e.origem_lat])
              .setPopup(new mapboxgl.Popup({ offset: 12, closeButton: false }).setHTML(
                `<div style="font-family:system-ui;font-size:10px;font-weight:700;color:#1E7C52">ORIGEM</div>
                 <div style="font-family:system-ui;font-size:11px;color:#0E1A33;margin-top:2px">${e.origem_endereco?.substring(0, 60)}</div>`
              ))
              .addTo(map)
          : new mapboxgl.Marker({ element: origEl }).setLngLat([posLng, posLat])

        const posEl = criarElPosicao(e.codigo_escolta ?? '—', s.color)
        posEl.addEventListener('click', () => setSelecionada(e))
        const posMarker = new mapboxgl.Marker({ element: posEl, anchor: 'bottom' })
          .setLngLat([posLng, posLat])
          .setPopup(new mapboxgl.Popup({ offset: 24, closeButton: false }).setHTML(popupHTML(e)))
          .addTo(map)

        let destMarker: mapboxgl.Marker | null = null
        if (e.destino_lat && e.destino_lng) {
          const destEl = criarElDestino()
          destMarker = new mapboxgl.Marker({ element: destEl, anchor: 'bottom' })
            .setLngLat([e.destino_lng, e.destino_lat])
            .setPopup(new mapboxgl.Popup({ offset: 20, closeButton: false }).setHTML(
              `<div style="font-family:system-ui;font-size:10px;font-weight:700;color:#B83832">DESTINO</div>
               <div style="font-family:system-ui;font-size:11px;color:#0E1A33;margin-top:2px">${e.destino_endereco?.substring(0, 60)}</div>`
            ))
            .addTo(map)
        }
        markersRef.current.set(e.id, { pos: posMarker, orig: origMarker, dest: destMarker })
      }
    })
  }, [escoltas, mapReady])

  // ── Rota + breadcrumb para selecionada ------------------------------------
  useEffect(() => {
    if (!mapRef.current || !mapReady) return
    const map = mapRef.current
    const s = selecionada ? (STATUS_MAP[selecionada.status] ?? { color: '#53648A' }) : null

    const posLat = selecionada?.ultimo_ponto?.lat ?? selecionada?.origem_lat
    const posLng = selecionada?.ultimo_ponto?.lng ?? selecionada?.origem_lng

    // Rota percorrida
    const trajSrc = map.getSource('rota-traj') as mapboxgl.GeoJSONSource | undefined
    if (trajSrc) {
      const coords = (selecionada && selecionada.origem_lat && selecionada.origem_lng && posLat && posLng)
        ? [[selecionada.origem_lng, selecionada.origem_lat], [posLng, posLat]]
        : []
      trajSrc.setData({ type: 'FeatureCollection', features: coords.length ? [{ type: 'Feature', properties: { cor: s?.color ?? '#53648A' }, geometry: { type: 'LineString', coordinates: coords } }] : [] })
    }

    // Rota restante
    const restSrc = map.getSource('rota-rest') as mapboxgl.GeoJSONSource | undefined
    if (restSrc) {
      const coords = (selecionada && posLat && posLng && selecionada.destino_lat && selecionada.destino_lng)
        ? [[posLng, posLat], [selecionada.destino_lng, selecionada.destino_lat]]
        : []
      restSrc.setData({ type: 'FeatureCollection', features: coords.length ? [{ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: coords } }] : [] })
    }

    // Breadcrumb
    const breadSrc = map.getSource('breadcrumb') as mapboxgl.GeoJSONSource | undefined
    if (breadSrc) {
      breadSrc.setData({
        type: 'FeatureCollection',
        features: historico.map(h => ({
          type: 'Feature' as const,
          properties: { cor: s?.color ?? '#53648A' },
          geometry: { type: 'Point' as const, coordinates: [h.lng, h.lat] },
        })),
      })
    }

    // Câmera
    if (selecionada && posLat && posLng) {
      if (selecionada.origem_lat && selecionada.origem_lng && selecionada.destino_lat && selecionada.destino_lng) {
        const b = new mapboxgl.LngLatBounds()
        b.extend([selecionada.origem_lng, selecionada.origem_lat])
        b.extend([posLng, posLat])
        b.extend([selecionada.destino_lng, selecionada.destino_lat])
        map.fitBounds(b, { padding: { top: 80, bottom: 100, left: 60, right: 60 }, duration: 900, maxZoom: 14 })
      } else {
        map.flyTo({ center: [posLng, posLat], zoom: 13, duration: 900 })
      }
    } else if (!selecionada) {
      // Limpar linhas
      trajSrc?.setData({ type: 'FeatureCollection', features: [] })
      restSrc?.setData({ type: 'FeatureCollection', features: [] })
      breadSrc?.setData({ type: 'FeatureCollection', features: [] })
    }
  }, [selecionada, historico, mapReady])

  const comGPS = escoltas.filter(e => e.ultimo_ponto || (e.origem_lat && e.origem_lng))
  const emTransito = escoltas.filter(e => ['em_andamento', 'na_origem', 'no_destino', 'retornando'].includes(e.status))

  return (
    <div className="space-y-4">
      <style>{`
        @keyframes pulse-ring {
          0%   { transform: scale(0.85); opacity: 0.8; }
          70%  { transform: scale(2.4);  opacity: 0; }
          100% { transform: scale(0.85); opacity: 0; }
        }
      `}</style>

      {/* ── Header ── */}
      <div className="flex items-start justify-between flex-wrap gap-3">
        <div>
          <h1 className="page-title">Mapa de Operações</h1>
          <div className="flex items-center gap-2 mt-0.5">
            <div style={{ width: 7, height: 7, borderRadius: '50%', backgroundColor: '#1E7C52', boxShadow: '0 0 6px #1E7C5280', animation: 'pulse 2s infinite' }} />
            <p className="page-subtitle" style={{ margin: 0 }}>
              Ao vivo · atualizado às {lastUpdate.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
            </p>
          </div>
        </div>
        <button onClick={carregar} className="btn-outline flex items-center gap-2" disabled={loading}>
          <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
          Atualizar
        </button>
      </div>

      {/* ── Stats ── */}
      <div className="grid grid-cols-3 gap-3">
        {[
          { valor: escoltas.length,  label: 'Escoltas Ativas',  cor: '#1E2D35' },
          { valor: comGPS.length,    label: 'Com Posição GPS',  cor: '#2563EB' },
          { valor: emTransito.length, label: 'Em Trânsito',     cor: '#7C3AED' },
        ].map(({ valor, label, cor }) => (
          <div key={label} className="card-light p-3 md:p-4 text-center">
            <p className="text-2xl font-black" style={{ color: cor }}>{valor}</p>
            <p className="text-[10px] uppercase tracking-wider mt-1" style={{ color: '#6B7E8A' }}>{label}</p>
          </div>
        ))}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4" style={{ minHeight: '580px' }}>

        {/* ── Painel lateral ── */}
        <div className="card-light flex flex-col" style={{ maxHeight: '660px' }}>
          <div className="px-4 py-3 border-b" style={{ borderColor: '#E2E8EC' }}>
            <h2 className="text-sm font-bold" style={{ color: '#1E2D35' }}>Escoltas em Campo</h2>
            <p className="text-[10px] mt-0.5" style={{ color: '#6B7E8A' }}>Posição via último check-in GPS</p>
          </div>

          <div className="flex-1 overflow-y-auto">
            {loading ? (
              <div className="py-12 flex items-center justify-center gap-2">
                <div className="w-4 h-4 rounded-full border-2 animate-spin" style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
                <span className="text-xs" style={{ color: '#6B7E8A' }}>Carregando...</span>
              </div>
            ) : escoltas.length === 0 ? (
              <div className="py-12 text-center px-4">
                <MapPin size={28} className="mx-auto mb-2" style={{ color: '#E2E8EC' }} />
                <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Nenhuma escolta ativa</p>
              </div>
            ) : escoltas.map(e => {
              const s = STATUS_MAP[e.status] ?? { label: e.status, color: '#53648A' }
              const isSel = selecionada?.id === e.id
              const pt = e.ultimo_ponto
              const sinalCor = pt ? corSinal(pt.data_hora) : null

              return (
                <button
                  key={e.id}
                  onClick={() => setSelecionada(e)}
                  className="w-full text-left px-4 py-3 transition-all border-b"
                  style={{
                    borderColor: '#E2E8EC',
                    backgroundColor: isSel ? `${s.color}0A` : '',
                    borderLeft: isSel ? `3px solid ${s.color}` : '3px solid transparent',
                  }}
                  onMouseEnter={ev => { if (!isSel) (ev.currentTarget as HTMLElement).style.backgroundColor = '#F8FAFC' }}
                  onMouseLeave={ev => { if (!isSel) (ev.currentTarget as HTMLElement).style.backgroundColor = '' }}
                >
                  {/* Linha 1: código + badge de status */}
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs font-mono font-bold truncate" style={{ color: '#1E2D35' }}>
                      {e.codigo_escolta ?? '—'}
                    </span>
                    <span className="shrink-0 text-[9px] font-black uppercase tracking-wider px-1.5 py-0.5"
                      style={{ backgroundColor: `${s.color}18`, color: s.color, border: `1px solid ${s.color}30` }}>
                      {s.label}
                    </span>
                  </div>

                  {/* Linha 2: cliente */}
                  <p className="text-[11px] mt-0.5 truncate" style={{ color: '#6B7E8A' }}>
                    {e.cliente?.nome_cliente ?? '—'}
                  </p>

                  {/* Linha 3: rota compacta origem → destino */}
                  <div className="flex items-center gap-1 mt-1.5">
                    <div style={{ width: 6, height: 6, borderRadius: '50%', backgroundColor: '#1E7C52', flexShrink: 0 }} />
                    <span className="text-[10px] truncate" style={{ color: '#A8B8C2', maxWidth: 80 }}>
                      {e.origem_endereco?.split(',')[0] ?? '—'}
                    </span>
                    <ArrowRight size={8} style={{ color: '#C8D5DC', flexShrink: 0 }} />
                    <div style={{ width: 0, height: 0, borderLeft: '5px solid transparent', borderRight: '5px solid transparent', borderBottom: '9px solid #B83832', flexShrink: 0 }} />
                    <span className="text-[10px] truncate" style={{ color: '#A8B8C2', maxWidth: 80 }}>
                      {e.destino_endereco?.split(',')[0] ?? '—'}
                    </span>
                  </div>

                  {/* Linha 4: último GPS */}
                  {pt ? (
                    <div className="mt-2 flex items-start gap-1.5 rounded px-2 py-1.5"
                      style={{ backgroundColor: `${sinalCor}12`, border: `1px solid ${sinalCor}25` }}>
                      <div style={{ width: 7, height: 7, borderRadius: '50%', backgroundColor: sinalCor ?? '#9CA3AF', flexShrink: 0, marginTop: 2 }} />
                      <div className="min-w-0">
                        <p className="text-[10px] font-bold leading-tight" style={{ color: sinalCor ?? '#1E2D35' }}>
                          {pt.tipo} · {tempoAtras(pt.data_hora)}
                        </p>
                        {pt.endereco && (
                          <p className="text-[9px] truncate mt-0.5 leading-tight" style={{ color: '#8B9BAD' }}>
                            {pt.endereco}
                          </p>
                        )}
                      </div>
                    </div>
                  ) : (
                    <div className="mt-2 flex items-center gap-1 px-2 py-1 rounded" style={{ backgroundColor: '#F3F4F6' }}>
                      <MapPin size={9} style={{ color: '#9CA3AF', flexShrink: 0 }} />
                      <span className="text-[9px]" style={{ color: '#9CA3AF' }}>
                        {e.origem_lat ? 'Sem check-in · usando origem' : 'Sem GPS registrado'}
                      </span>
                    </div>
                  )}
                </button>
              )
            })}
          </div>

          {/* Legenda */}
          <div className="px-4 py-3 border-t space-y-2" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8FAFC' }}>
            <p className="text-[9px] font-bold uppercase tracking-widest" style={{ color: '#A8B8C2' }}>Status</p>
            <div className="flex flex-wrap gap-x-3 gap-y-1">
              {Object.values(STATUS_MAP).map(v => (
                <div key={v.label} className="flex items-center gap-1">
                  <div style={{ width: 7, height: 7, borderRadius: '50%', backgroundColor: v.color }} />
                  <span style={{ fontSize: '9px', color: '#6B7E8A' }}>{v.label}</span>
                </div>
              ))}
            </div>
            <p className="text-[9px] font-bold uppercase tracking-widest pt-1" style={{ color: '#A8B8C2' }}>Sinal GPS</p>
            <div className="flex gap-x-3 flex-wrap">
              {[{ cor: '#1E7C52', txt: '< 30min' }, { cor: '#D97706', txt: '30-90min' }, { cor: '#B83832', txt: '> 90min' }].map(x => (
                <div key={x.txt} className="flex items-center gap-1">
                  <div style={{ width: 7, height: 7, borderRadius: '50%', backgroundColor: x.cor }} />
                  <span style={{ fontSize: '9px', color: '#6B7E8A' }}>{x.txt}</span>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* ── Mapa ── */}
        <div className="lg:col-span-2 card-light flex flex-col overflow-hidden" style={{ minHeight: '560px' }}>

          {/* Cabeçalho da escolta selecionada */}
          {selecionada && (() => {
            const s = STATUS_MAP[selecionada.status] ?? { label: selecionada.status, color: '#53648A' }
            const pt = selecionada.ultimo_ponto
            return (
              <div className="px-4 py-3 border-b shrink-0" style={{ borderColor: '#E2E8EC' }}>
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="text-sm font-bold" style={{ color: '#1E2D35' }}>{selecionada.codigo_escolta}</span>
                      {selecionada.cliente && (
                        <span className="text-sm" style={{ color: '#6B7E8A' }}>— {selecionada.cliente.nome_cliente}</span>
                      )}
                      <span className="text-[9px] font-black uppercase tracking-wider px-1.5 py-0.5"
                        style={{ backgroundColor: `${s.color}18`, color: s.color, border: `1px solid ${s.color}30` }}>
                        {s.label}
                      </span>
                    </div>
                    <div className="flex items-center gap-1.5 mt-1 flex-wrap">
                      <div style={{ width: 6, height: 6, borderRadius: '50%', backgroundColor: '#1E7C52', flexShrink: 0 }} />
                      <span className="text-[10px]" style={{ color: '#6B7E8A' }}>{selecionada.origem_endereco?.split(',')[0]}</span>
                      <ArrowRight size={8} style={{ color: '#C8D5DC' }} />
                      <div style={{ width: 0, height: 0, borderLeft: '5px solid transparent', borderRight: '5px solid transparent', borderBottom: '9px solid #B83832', flexShrink: 0 }} />
                      <span className="text-[10px]" style={{ color: '#6B7E8A' }}>{selecionada.destino_endereco?.split(',')[0]}</span>
                    </div>
                    {pt && (
                      <div className="flex items-center gap-1.5 mt-1">
                        <div style={{ width: 6, height: 6, borderRadius: '50%', backgroundColor: corSinal(pt.data_hora), flexShrink: 0 }} />
                        <span className="text-[10px]" style={{ color: '#6B7E8A' }}>
                          Último GPS: <strong style={{ color: corSinal(pt.data_hora) }}>{tempoAtras(pt.data_hora)}</strong>
                          {' · '}{pt.tipo}
                        </span>
                        {historico.length > 0 && (
                          <span className="text-[9px]" style={{ color: '#A8B8C2' }}>
                            · {historico.length} pontos
                          </span>
                        )}
                      </div>
                    )}
                    {!pt && (
                      <p className="text-[10px] mt-1" style={{ color: '#9CA3AF' }}>Sem check-in · exibindo coordenadas de origem</p>
                    )}
                  </div>
                  {pt && (
                    <a href={buildGMapsUrl(pt.lat, pt.lng)} target="_blank" rel="noopener noreferrer"
                      className="btn-outline text-xs flex items-center gap-1.5 shrink-0">
                      <ExternalLink size={12} /> Google Maps
                    </a>
                  )}
                </div>
              </div>
            )
          })()}

          {/* Container do mapa */}
          <div className="flex-1 relative" style={{ minHeight: '460px' }}>
            {!MAPBOX_TOKEN ? (
              <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-slate-50">
                <MapPin size={32} style={{ color: '#C8D5DC' }} />
                <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Token Mapbox não configurado</p>
              </div>
            ) : (
              <>
                <div ref={mapContainerRef} style={{ width: '100%', height: '100%', minHeight: '460px' }} />
                {!selecionada && !loading && (
                  <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 pointer-events-none"
                    style={{ backgroundColor: 'rgba(255,255,255,0.65)' }}>
                    <Navigation size={28} style={{ color: '#C8D5DC' }} />
                    <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Selecione uma escolta no painel</p>
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
