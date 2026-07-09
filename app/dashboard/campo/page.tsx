'use client'

import { useEffect, useState, useRef, useCallback } from 'react'
import {
  MapPin, Camera, ClipboardList, CheckCircle2, AlertTriangle,
  Zap, X, Check, ChevronDown, ChevronRight,
  Shield, Navigation, Home, Package, Flag, RotateCcw,
  Clock, User, Crosshair
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { AiTextButton } from '@/components/ui/ai-text-button'
import { VoiceInputButton } from '@/components/ui/voice-input-button'

const supabase = createClient()
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = supabase as any

// ─── IDs de domínio (fixos, já existem no banco) ─────────────────────────────
const TIPO_FOTO = {
  PONTO_CONTROLE:     'db608f8f-322e-4748-b4f8-fef572a6c1e6',
  OCORRENCIA:         '8c4873a9-1907-4cef-b14e-435b3dbead70',
  CHECKLIST_VIATURA:  'bcaae1bb-5cb0-420c-a436-80b777082625',
  CHECKLIST_MATERIAL: '0b3e6a7a-26d7-43a6-ae03-a0ccb938bf3c',
}

const TIPO_PONTO = {
  BASE_SAIDA:   '18ce0259-8471-46ac-bc12-6602678fa910',
  ORIGEM:       'e1aec874-4d4e-4aa2-bae2-de4e711a9f9f',
  DESTINO:      'e4623e3e-a210-4c17-942a-80f01cc28f2d',
  BASE_RETORNO: 'c9bc3e19-d55d-4174-8acb-12fe1e2b50b7',
}

// Ao avançar para o status X, qual ponto foi atingido?
const STATUS_TO_TIPO_PONTO: Record<string, string> = {
  em_andamento: TIPO_PONTO.BASE_SAIDA,
  na_origem:    TIPO_PONTO.ORIGEM,
  no_destino:   TIPO_PONTO.DESTINO,
  na_base:      TIPO_PONTO.BASE_RETORNO,
}

// ─── Types ────────────────────────────────────────────────────────────────────
interface EscoltaAtiva {
  id: string
  codigo_escolta: string | null
  status: string
  origem_endereco: string
  destino_endereco: string
  data_hora_prevista: string
  cliente: { nome_cliente: string; cor_destaque: string | null } | null
  escolta_veiculo_id?: string
  veiculo_placa?: string
  veiculo_modelo?: string
  papel?: string
}

interface ChecklistItem {
  id: string
  descricao_item: string
  exige_foto: boolean
  ordem: number
  resposta: boolean | null
  observacao: string
  foto: File | null
  fotoPreview: string | null
}

interface FotoCaptura {
  file: File
  preview: string
  timestamp: string
  gps: { lat: number; lng: number; precisao: number } | null
}

interface TipoOcorrencia { id: string; nome: string }

// ─── Status flow ──────────────────────────────────────────────────────────────
const PROXIMO_STATUS: Record<string, string> = {
  em_pre_inicio: 'em_andamento',
  em_andamento:  'na_origem',
  na_origem:     'no_destino',
  no_destino:    'retornando',
  retornando:    'na_base',
  na_base:       'finalizada',
}

const BOTAO_AVANCO: Record<string, { label: string; cor: string }> = {
  em_pre_inicio: { label: 'Confirmar Saída da Base',      cor: '#1A294A' },
  em_andamento:  { label: 'Confirmar Chegada na Origem',  cor: '#1E7C52' },
  na_origem:     { label: 'Partir para o Destino',        cor: '#53648A' },
  no_destino:    { label: 'Confirmar Entrega e Retornar', cor: '#9F906D' },
  retornando:    { label: 'Confirmar Chegada na Base',    cor: '#1E7C52' },
  na_base:       { label: 'Finalizar Escolta',            cor: '#1E7C52' },
}

const JORNADA = [
  { status: 'em_pre_inicio', label: 'Base\nSaída',    icon: <Home size={13}/> },
  { status: 'em_andamento',  label: 'A Caminho\nOrigem', icon: <Navigation size={13}/> },
  { status: 'na_origem',     label: 'Na\nOrigem',    icon: <Package size={13}/> },
  { status: 'no_destino',    label: 'No\nDestino',   icon: <Flag size={13}/> },
  { status: 'retornando',    label: 'Retornando',    icon: <RotateCcw size={13}/> },
  { status: 'na_base',       label: 'Base\nChegada', icon: <Home size={13}/> },
]

const STATUS_IDX: Record<string, number> = {
  em_pre_inicio: 0, em_andamento: 1, na_origem: 2,
  no_destino: 3, retornando: 4, na_base: 5, finalizada: 6,
}

const STATUS_LABELS: Record<string, string> = {
  em_pre_inicio: 'Pré-Início', em_andamento: 'Em Andamento',
  na_origem: 'Na Origem', no_destino: 'No Destino',
  retornando: 'Retornando', na_base: 'Na Base', finalizada: 'Finalizada',
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
async function obterGPS(): Promise<{ lat: number; lng: number; precisao: number }> {
  if (!navigator.geolocation) throw new Error('GPS não disponível')

  const tentarObter = (highAccuracy: boolean, timeout: number, maximumAge: number) =>
    new Promise<{ lat: number; lng: number; precisao: number }>((resolve, reject) => {
      navigator.geolocation.getCurrentPosition(
        (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude, precisao: p.coords.accuracy }),
        reject,
        { enableHighAccuracy: highAccuracy, timeout, maximumAge }
      )
    })

  try {
    return await tentarObter(true, 15000, 0)
  } catch {
    return await tentarObter(false, 10000, 30000)
  }
}

function formatarCarimbo(timestamp: string, gps: { lat: number; lng: number } | null): string {
  const d = new Date(timestamp)
  const data = d.toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' })
  if (gps) return `${data}  |  ${gps.lat.toFixed(5)}, ${gps.lng.toFixed(5)}`
  return data
}

// ─── Toast ────────────────────────────────────────────────────────────────────
function Toast({ msg }: { msg: { tipo: 'ok' | 'erro'; texto: string } | null }) {
  if (!msg) return null
  return (
    <div className={`fixed top-4 left-1/2 -translate-x-1/2 z-50 px-5 py-3 rounded text-sm font-semibold shadow-2xl flex items-center gap-2 animate-in slide-in-from-top-2 ${
      msg.tipo === 'ok' ? 'bg-emerald-600 text-white' : 'bg-red-600 text-white'
    }`}>
      {msg.tipo === 'ok' ? <CheckCircle2 size={15}/> : <AlertTriangle size={15}/>}
      {msg.texto}
    </div>
  )
}

// ─── FotoCapture Component ────────────────────────────────────────────────────
function FotoCapture({
  label,
  sublabel,
  captura,
  onCapturar,
  onLimpar,
  fileRef,
}: {
  label: string
  sublabel?: string
  captura: FotoCaptura | null
  onCapturar: (e: React.ChangeEvent<HTMLInputElement>) => void
  onLimpar: () => void
  fileRef: React.RefObject<HTMLInputElement | null>
}) {
  return (
    <div>
      <input ref={fileRef} type="file" accept="image/*" capture="environment"
        className="hidden" onChange={onCapturar} />

      {captura ? (
        <div className="relative rounded overflow-hidden border border-[#E2E8EC]">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={captura.preview} alt="foto" className="w-full h-44 object-cover" />
          {/* Carimbo data/hora/GPS */}
          <div className="absolute bottom-0 left-0 right-0 bg-black/65 px-3 py-2">
            <p className="text-white font-mono text-[11px] leading-tight">
              {formatarCarimbo(captura.timestamp, captura.gps)}
            </p>
          </div>
          <button
            onClick={onLimpar}
            className="absolute top-2 right-2 w-7 h-7 bg-black/50 hover:bg-black/70 rounded flex items-center justify-center transition-all"
          >
            <X size={13} className="text-white"/>
          </button>
        </div>
      ) : (
        <button
          onClick={() => fileRef.current?.click()}
          className="w-full py-6 border-2 border-dashed border-[#E2E8EC] rounded flex flex-col items-center gap-2 hover:border-[#4A90A4] hover:bg-[#F8FAFC] transition-all"
        >
          <Camera size={26} className="text-[#C4CDD4]"/>
          <span className="text-sm font-semibold text-[#6B7E8A]">{label}</span>
          {sublabel && <span className="text-xs text-[#A8B8C2]">{sublabel}</span>}
        </button>
      )}
    </div>
  )
}

// ─── Main Page ────────────────────────────────────────────────────────────────
export default function CampoPage() {
  const { user } = useAuth()

  const [escoltaAtiva, setEscoltaAtiva] = useState<EscoltaAtiva | null>(null)
  const [todasEscoltas, setTodasEscoltas] = useState<EscoltaAtiva[]>([])
  const [checklistItems, setChecklistItems] = useState<ChecklistItem[]>([])
  const [tiposOcorrencia, setTiposOcorrencia] = useState<TipoOcorrencia[]>([])
  const [loading, setLoading] = useState(true)
  const [executando, setExecutando] = useState(false)
  const [toast, setToast] = useState<{ tipo: 'ok' | 'erro'; texto: string } | null>(null)

  // Accordions
  const [painelAberto, setPainelAberto] = useState<'checkpoint' | 'checklist' | 'ocorrencia' | null>(null)

  // Foto do checkpoint (avançar status)
  const [fotoCheckpoint, setFotoCheckpoint] = useState<FotoCaptura | null>(null)
  const [obsAvanco, setObsAvanco] = useState('')
  const fotoCheckpointRef = useRef<HTMLInputElement>(null)

  // Foto da ocorrência
  const [tipoOcId, setTipoOcId] = useState('')
  const [descOcorrencia, setDescOcorrencia] = useState('')
  const [fotoOcorrencia, setFotoOcorrencia] = useState<FotoCaptura | null>(null)
  const fotoOcorrenciaRef = useRef<HTMLInputElement>(null)

  // Foto por item do checklist (1 ref compartilhado, controlado por índice)
  const [checklistFotoIdx, setChecklistFotoIdx] = useState<number | null>(null)
  const fotoChecklistRef = useRef<HTMLInputElement>(null)

  // Emergência
  const [emergConfirm, setEmergConfirm] = useState(false)

  const isAdmin = ['administrador', 'gestor', 'supervisor', 'central'].includes((user?.perfil?.codigo ?? '') as any)

  const showToast = (tipo: 'ok' | 'erro', texto: string) => {
    setToast({ tipo, texto })
    setTimeout(() => setToast(null), 4000)
  }

  // ── Carregar dados ────────────────────────────────────────────────────────
  const carregar = useCallback(async () => {
    if (!user) return
    setLoading(true)

    const ATIVOS = ['em_pre_inicio', 'em_andamento', 'na_origem', 'no_destino', 'retornando', 'na_base']

    if (isAdmin) {
      const { data: esc } = await sb
        .from('escoltas')
        .select('id, codigo_escolta, status, origem_endereco, destino_endereco, data_hora_prevista, cliente:clientes(nome_cliente, cor_destaque)')
        .in('status', ATIVOS)
        .order('data_hora_prevista')

      const lista = (esc ?? []) as EscoltaAtiva[]
      setTodasEscoltas(lista)
      if (lista.length > 0 && !escoltaAtiva) setEscoltaAtiva(lista[0])
    } else {
      const { data: vig } = await sb
        .from('vigilantes')
        .select('id')
        .eq('usuario_id', user.id)
        .maybeSingle()

      if (!vig) { setLoading(false); return }

      const { data: efetivo } = await sb
        .from('escolta_efetivo')
        .select('escolta_id, escolta_veiculo_id, papel_na_escolta, escolta:escoltas(id,codigo_escolta,status,origem_endereco,destino_endereco,data_hora_prevista,cliente:clientes(nome_cliente,cor_destaque)), veiculo:escolta_veiculos(veiculo:veiculos(placa,modelo))')
        .eq('vigilante_id', vig.id)

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const ativa = (efetivo ?? []).find((e: any) => ATIVOS.includes(e.escolta?.status ?? ''))
      if (ativa) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const e = ativa.escolta as any
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const v = (ativa.veiculo as any)?.veiculo
        setEscoltaAtiva({
          ...e,
          escolta_veiculo_id: ativa.escolta_veiculo_id,
          veiculo_placa: v?.placa,
          veiculo_modelo: v?.modelo,
          papel: ativa.papel_na_escolta,
        })
      }
    }

    const [{ data: tipos }, { data: ckItens }] = await Promise.all([
      sb.from('dom_tipos_ocorrencia').select('id, nome').eq('ativo', true).order('nome'),
      sb.from('checklist_modelo_itens').select('id, descricao_item, exige_foto, ordem').eq('ativo', true).order('ordem').limit(30),
    ])

    setTiposOcorrencia(tipos ?? [])
    if (ckItens) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      setChecklistItems((ckItens as any[]).map(i => ({
        ...i,
        resposta: null,
        observacao: '',
        foto: null,
        fotoPreview: null,
      })))
    }
    setLoading(false)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user])

  useEffect(() => { carregar() }, [carregar])

  // ── Helper: capturar foto com GPS + timestamp ─────────────────────────────
  const capturarFoto = async (file: File): Promise<FotoCaptura> => {
    const preview = URL.createObjectURL(file)
    const timestamp = new Date().toISOString()
    let gps = null
    try { gps = await obterGPS() } catch { /* GPS opcional */ }
    return { file, preview, timestamp, gps }
  }

  // ── Helper: fazer upload e criar registro em fotos ────────────────────────
  const uploadFoto = async (
    captura: FotoCaptura,
    tipoFotoId: string
  ): Promise<string | null> => {
    const ext = captura.file.name.split('.').pop() ?? 'jpg'
    const path = `campo/${escoltaAtiva?.id ?? 'geral'}/${tipoFotoId}_${Date.now()}.${ext}`

    const { error: upErr } = await supabase.storage.from('fotos').upload(path, captura.file)
    if (upErr) { console.error('Upload erro:', upErr.message); return null }

    const { data: fotoRow } = await sb.from('fotos').insert({
      caminho_arquivo: path,
      tipo_foto_id: tipoFotoId,
      latitude: captura.gps?.lat ?? null,
      longitude: captura.gps?.lng ?? null,
      precisao_metros: captura.gps?.precisao ?? null,
      data_hora_captura: captura.timestamp,
      carimbo_aplicado: true,
      enviada_telegram: false,
      sincronizada: true,
      criado_por: user?.id ?? null,
    }).select('id').single()

    return fotoRow?.id ?? null
  }

  // ── Handlers de captura de foto ───────────────────────────────────────────
  const handleFotoCheckpoint = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0]
    if (!f) return
    const captura = await capturarFoto(f)
    setFotoCheckpoint(captura)
  }

  const handleFotoOcorrencia = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0]
    if (!f) return
    const captura = await capturarFoto(f)
    setFotoOcorrencia(captura)
  }

  const handleFotoChecklist = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0]
    if (!f || checklistFotoIdx === null) return
    const captura = await capturarFoto(f)
    const preview = URL.createObjectURL(f)
    setChecklistItems(its => its.map((item, idx) =>
      idx === checklistFotoIdx ? { ...item, foto: f, fotoPreview: preview } : item
    ))
    setChecklistFotoIdx(null)
  }

  const limparFotoCheckpoint = () => {
    if (fotoCheckpoint) URL.revokeObjectURL(fotoCheckpoint.preview)
    setFotoCheckpoint(null)
    if (fotoCheckpointRef.current) fotoCheckpointRef.current.value = ''
  }

  const limparFotoOcorrencia = () => {
    if (fotoOcorrencia) URL.revokeObjectURL(fotoOcorrencia.preview)
    setFotoOcorrencia(null)
    if (fotoOcorrenciaRef.current) fotoOcorrenciaRef.current.value = ''
  }

  const limparFotoChecklistItem = (idx: number) => {
    setChecklistItems(its => its.map((item, i) => {
      if (i !== idx) return item
      if (item.fotoPreview) URL.revokeObjectURL(item.fotoPreview)
      return { ...item, foto: null, fotoPreview: null }
    }))
  }

  // ── Avançar status (checkpoint principal) ─────────────────────────────────
  const avancarStatus = async () => {
    if (!escoltaAtiva) return
    const statusAtual = escoltaAtiva.status
    const proximo = PROXIMO_STATUS[statusAtual]
    if (!proximo) return

    if (!fotoCheckpoint) {
      showToast('erro', 'Foto obrigatória para registrar o checkpoint.')
      return
    }

    setExecutando(true)
    try {
      // GPS
      let gps = fotoCheckpoint?.gps ?? null
      if (!gps) {
        try { gps = await obterGPS() } catch { /* GPS opcional */ }
      }

      // Upload foto do checkpoint
      let fotoId: string | null = null
      if (fotoCheckpoint) {
        fotoId = await uploadFoto(fotoCheckpoint, TIPO_FOTO.PONTO_CONTROLE)
      }

      // Atualiza status da escolta
      await sb.from('escoltas').update({ status: proximo }).eq('id', escoltaAtiva.id)

      // Histórico de status
      await sb.from('escolta_status_historico').insert({
        escolta_id: escoltaAtiva.id,
        status_anterior: statusAtual,
        status_novo: proximo,
        alterado_por: user?.id,
        data_hora: new Date().toISOString(),
        latitude: gps?.lat ?? null,
        longitude: gps?.lng ?? null,
        observacao: obsAvanco.trim() || null,
      })

      // Ponto de controle (com foto e tipo correto)
      const tipoPontoId = STATUS_TO_TIPO_PONTO[proximo]
      if (gps && escoltaAtiva.escolta_veiculo_id && tipoPontoId) {
        await sb.from('pontos_controle').insert({
          escolta_veiculo_id: escoltaAtiva.escolta_veiculo_id,
          tipo_ponto_id: tipoPontoId,
          data_hora: fotoCheckpoint?.timestamp ?? new Date().toISOString(),
          latitude: gps.lat,
          longitude: gps.lng,
          precisao_metros: gps.precisao,
          foto_id: fotoId,
          lancado_por: user?.id,
          sincronizado: true,
          criado_offline: false,
        })
      }

      // Notificar Telegram — sempre dispara após qualquer avanço de status
      const STATUS_TG_TITULO: Record<string, string> = {
        em_andamento: 'Saída da Base',
        na_origem:    'Chegada na Origem',
        no_destino:   'Chegada no Destino',
        retornando:   'Retorno Iniciado',
        na_base:      'Chegada na Base',
        finalizada:   'Escolta Finalizada',
      }
      const STATUS_TG_LABEL: Record<string, string> = {
        em_andamento: 'Em Rota',
        na_origem:    'Na Origem',
        no_destino:   'No Destino',
        retornando:   'Em Retorno',
        na_base:      'Na Base',
        finalizada:   'Finalizada',
      }

      // Foto pública
      let fotoTgUrl: string | null = null
      if (fotoId) {
        const { data: fotoData } = await sb.from('fotos').select('caminho_arquivo').eq('id', fotoId).maybeSingle()
        if (fotoData?.caminho_arquivo) {
          const { data: pub } = sb.storage.from('fotos').getPublicUrl(fotoData.caminho_arquivo)
          fotoTgUrl = pub?.publicUrl ?? null
        }
      }

      // Todos os efetivos da escolta (via escolta_veiculos para garantir filtro correto)
      const { data: viatRows } = await sb
        .from('escolta_veiculos')
        .select('id')
        .eq('escolta_id', escoltaAtiva.id)
      const viatIds = (viatRows ?? []).map((v: any) => v.id)
      const { data: efetivosData } = viatIds.length > 0
        ? await sb
            .from('escolta_efetivo')
            .select('papel_na_escolta, vigilante:vigilantes(nome_completo)')
            .in('escolta_veiculo_id', viatIds)
        : { data: [] }
      const efetivos: string[] = (efetivosData ?? []).map((e: any) =>
        `${e.vigilante?.nome_completo ?? '—'}${e.papel_na_escolta ? ` (${e.papel_na_escolta})` : ''}`
      )

      const dataHoraFmt = new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })

      fetch('/api/telegram', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          tipo: 'ponto_controle',
          titulo: STATUS_TG_TITULO[proximo] ?? proximo,
          descricao: obsAvanco.trim() || undefined,
          escolta_id: escoltaAtiva.id,
          escolta_codigo: escoltaAtiva.codigo_escolta,
          cliente: escoltaAtiva.cliente?.nome_cliente,
          status_atual: STATUS_TG_LABEL[proximo] ?? proximo,
          efetivos,
          veiculo: escoltaAtiva.veiculo_placa,
          foto_url: fotoTgUrl,
          data_hora: dataHoraFmt,
        }),
      }).catch(() => {})

      setEscoltaAtiva({ ...escoltaAtiva, status: proximo })
      if (isAdmin) setTodasEscoltas(ts => ts.map(t => t.id === escoltaAtiva.id ? { ...t, status: proximo } : t))

      limparFotoCheckpoint()
      setObsAvanco('')
      setPainelAberto(null)

      const msgs: Record<string, string> = {
        em_andamento: 'Saída registrada! Em deslocamento.',
        na_origem: 'Chegada na Origem confirmada!',
        no_destino: 'Partiu para o Destino!',
        retornando: 'Entrega confirmada. Retornando...',
        na_base: 'Chegada na Base confirmada!',
        finalizada: 'Escolta finalizada com sucesso!',
      }
      showToast('ok', msgs[proximo] ?? 'Status atualizado.')
    } catch (err) {
      showToast('erro', err instanceof Error ? err.message : 'Erro ao registrar checkpoint.')
    } finally {
      setExecutando(false)
    }
  }

  // ── Salvar checklist ──────────────────────────────────────────────────────
  const salvarChecklist = async () => {
    const semResposta = checklistItems.filter(i => i.resposta === null)
    if (semResposta.length > 0) {
      showToast('erro', `${semResposta.length} item(ns) sem resposta.`)
      return
    }
    const naoConformesSemObs = checklistItems.filter(i => i.resposta === false && !i.observacao.trim())
    if (naoConformesSemObs.length > 0) {
      showToast('erro', 'Descreva a não conformidade em todos os itens reprovados.')
      return
    }

    setExecutando(true)
    try {
      const status = escoltaAtiva?.status ?? ''
      const tipoChecklist = status === 'em_pre_inicio' ? 'viatura' : 'material'
      const tipoFotoChecklist = tipoChecklist === 'viatura'
        ? TIPO_FOTO.CHECKLIST_VIATURA
        : TIPO_FOTO.CHECKLIST_MATERIAL

      const { data: cl } = await sb.from('checklists').insert({
        escolta_veiculo_id: escoltaAtiva?.escolta_veiculo_id ?? null,
        modelo_id: null,
        tipo: tipoChecklist,
        concluido: true,
        data_conclusao: new Date().toISOString(),
        responsavel_id: user?.id,
        sincronizado: true,
      }).select('id').single()

      if (cl) {
        for (const item of checklistItems) {
          // Upload foto do item se houver
          let fotoId: string | null = null
          if (item.foto) {
            const captura: FotoCaptura = {
              file: item.foto,
              preview: item.fotoPreview ?? '',
              timestamp: new Date().toISOString(),
              gps: null,
            }
            fotoId = await uploadFoto(captura, tipoFotoChecklist)
          }

          await sb.from('checklist_respostas').insert({
            checklist_id: cl.id,
            descricao_item: item.descricao_item,
            conforme: item.resposta,
            observacao: item.observacao.trim() || null,
            foto_id: fotoId,
          })
        }
      }

      setPainelAberto(null)
      showToast('ok', 'Checklist concluído e salvo com sucesso!')

      // Reset checklist
      setChecklistItems(its => its.map(i => ({ ...i, resposta: null, observacao: '', foto: null, fotoPreview: null })))
    } catch (err) {
      showToast('erro', err instanceof Error ? err.message : 'Erro ao salvar checklist.')
    } finally {
      setExecutando(false)
    }
  }

  // ── Registrar ocorrência ──────────────────────────────────────────────────
  const registrarOcorrencia = async () => {
    if (!tipoOcId || !descOcorrencia.trim()) {
      showToast('erro', 'Preencha tipo e descrição.')
      return
    }

    setExecutando(true)
    try {
      let gps = fotoOcorrencia?.gps ?? null
      if (!gps) {
        try { gps = await obterGPS() } catch { /* GPS opcional */ }
      }

      // Upload foto da ocorrência
      let fotoId: string | null = null
      if (fotoOcorrencia) {
        fotoId = await uploadFoto(fotoOcorrencia, TIPO_FOTO.OCORRENCIA)
      }

      await sb.from('ocorrencias').insert({
        escolta_id: escoltaAtiva?.id,
        escolta_veiculo_id: escoltaAtiva?.escolta_veiculo_id ?? null,
        tipo_ocorrencia_id: tipoOcId,
        descricao: descOcorrencia.trim(),
        data_hora: fotoOcorrencia?.timestamp ?? new Date().toISOString(),
        latitude: gps?.lat ?? null,
        longitude: gps?.lng ?? null,
        foto_id: fotoId,
        registrado_por: user?.id,
        sincronizado: true,
      })

      // Telegram
      const tipoOcLabel = tiposOcorrencia.find(t => t.id === tipoOcId)?.nome ?? 'Ocorrência'
      let fotoTgUrl: string | null = null
      if (fotoId) {
        const { data: fRow } = await sb.from('fotos').select('caminho_arquivo').eq('id', fotoId).maybeSingle()
        if (fRow?.caminho_arquivo) {
          const { data: pub } = sb.storage.from('fotos').getPublicUrl(fRow.caminho_arquivo)
          fotoTgUrl = pub?.publicUrl ?? null
        }
      }
      const { data: viatRowsOc } = await sb
        .from('escolta_veiculos')
        .select('id')
        .eq('escolta_id', escoltaAtiva!.id)
      const viatIdsOc = (viatRowsOc ?? []).map((v: any) => v.id)
      const { data: efData } = viatIdsOc.length > 0
        ? await sb
            .from('escolta_efetivo')
            .select('papel_na_escolta, vigilante:vigilantes(nome_completo)')
            .in('escolta_veiculo_id', viatIdsOc)
        : { data: [] }
      const efetivos: string[] = (efData ?? []).map((e: any) =>
        `${e.vigilante?.nome_completo ?? '—'}${e.papel_na_escolta ? ` (${e.papel_na_escolta})` : ''}`
      )
      fetch('/api/telegram', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          tipo: 'ocorrencia',
          titulo: `Ocorrência: ${tipoOcLabel}`,
          descricao: descOcorrencia.trim(),
          escolta_id: escoltaAtiva!.id,
          escolta_codigo: escoltaAtiva!.codigo_escolta,
          cliente: escoltaAtiva!.cliente?.nome_cliente,
          status_atual: escoltaAtiva!.status,
          efetivos,
          veiculo: escoltaAtiva!.veiculo_placa,
          foto_url: fotoTgUrl,
          data_hora: new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' }),
        }),
      }).catch(() => {})

      setTipoOcId('')
      setDescOcorrencia('')
      limparFotoOcorrencia()
      setPainelAberto(null)
      showToast('ok', 'Ocorrência registrada com sucesso.')
    } catch (err) {
      showToast('erro', err instanceof Error ? err.message : 'Erro ao registrar ocorrência.')
    } finally {
      setExecutando(false)
    }
  }

  // ── Acionar emergência ────────────────────────────────────────────────────
  const acionarEmergencia = async () => {
    setExecutando(true)
    try {
      let gps = null
      try { gps = await obterGPS() } catch { /* GPS obrigatório */ }
      await sb.from('emergencias').insert({
        escolta_id: escoltaAtiva?.id,
        escolta_veiculo_id: escoltaAtiva?.escolta_veiculo_id ?? null,
        acionado_por: user?.id,
        data_hora: new Date().toISOString(),
        latitude: gps?.lat ?? null,
        longitude: gps?.lng ?? null,
        status: 'aberta',
      })
      setEmergConfirm(false)
      showToast('ok', 'EMERGÊNCIA ACIONADA! Central notificada.')
    } catch (err) {
      showToast('erro', err instanceof Error ? err.message : 'Erro ao acionar emergência.')
    } finally {
      setExecutando(false)
    }
  }

  // ── Loading ───────────────────────────────────────────────────────────────
  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="w-6 h-6 rounded border-2 border-t-transparent animate-spin"
          style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
      </div>
    )
  }

  const status = escoltaAtiva?.status ?? ''
  const idxAtual = STATUS_IDX[status] ?? -1
  const botaoAvanco = BOTAO_AVANCO[status]
  const podeAvancar = !!PROXIMO_STATUS[status]
  const mostrarChecklist = ['em_pre_inicio', 'na_base'].includes(status)
  const mostrarOcorrencia = ['em_andamento', 'na_origem', 'no_destino', 'retornando'].includes(status)
  const checklistRespondidos = checklistItems.filter(i => i.resposta !== null).length

  return (
    <div className="max-w-xl mx-auto space-y-4 pb-12 px-4 md:px-0">
      <Toast msg={toast} />

      {/* ── Header ── */}
      <div>
        <h1 className="page-title">Campo</h1>
        <p className="page-subtitle flex items-center gap-1.5">
          <User size={12}/> {user?.nome_completo?.split(' ').slice(0, 2).join(' ')} · {user?.perfil?.nome_exibicao}
        </p>
      </div>

      {/* ── Seletor de escolta (admin) ── */}
      {isAdmin && todasEscoltas.length > 0 && (
        <div className="card-light p-3">
          <p className="text-[10px] font-black text-[#6B7E8A] uppercase tracking-widest mb-2">Selecionar Escolta</p>
          <div className="flex flex-wrap gap-2">
            {todasEscoltas.map(e => (
              <button
                key={e.id}
                onClick={() => setEscoltaAtiva(e)}
                className="px-3 py-1.5 rounded text-xs font-semibold border transition-all"
                style={
                  escoltaAtiva?.id === e.id
                    ? { backgroundColor: '#3A5464', color: '#fff', borderColor: '#3A5464' }
                    : { backgroundColor: '#fff', color: '#5C6B73', borderColor: '#E2E8EC' }
                }
              >
                {e.codigo_escolta ?? 'S/Código'}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* ── Sem escolta ── */}
      {!escoltaAtiva ? (
        <div className="card-light py-16 flex flex-col items-center gap-4 text-center">
          <div className="w-14 h-14 rounded flex items-center justify-center" style={{ backgroundColor: '#F4F4F9', border: '1px solid #E2E8EC' }}>
            <Shield size={26} style={{ color: '#C4CDD4' }} />
          </div>
          <div>
            <p className="text-sm font-bold" style={{ color: '#1E2D35' }}>Nenhuma escolta ativa</p>
            <p className="text-xs mt-1" style={{ color: '#6B7E8A' }}>
              {isAdmin ? 'Não há escoltas em andamento no momento.' : 'Você não está vinculado a uma escolta ativa.'}
            </p>
          </div>
        </div>
      ) : (
        <>
          {/* ── Card da escolta ── */}
          <div className="card-light overflow-hidden">
            <div className="h-1.5 w-full" style={{ backgroundColor: escoltaAtiva.cliente?.cor_destaque ?? '#4A90A4' }} />
            <div className="p-4 space-y-3">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="text-[11px] font-mono" style={{ color: '#A8B8C2' }}>{escoltaAtiva.codigo_escolta ?? 'Sem código'}</p>
                  <p className="text-base font-black leading-tight" style={{ color: '#1E2D35' }}>{escoltaAtiva.cliente?.nome_cliente ?? '—'}</p>
                </div>
                <span className="badge-info shrink-0">{STATUS_LABELS[status] ?? status}</span>
              </div>
              <div className="space-y-2 text-xs" style={{ color: '#6B7E8A' }}>
                <div className="flex items-start gap-1.5">
                  <MapPin size={12} className="mt-0.5 shrink-0" style={{ color: '#4A90A4' }} />
                  <span className="leading-relaxed"><strong style={{ color: '#1E2D35' }}>Origem:</strong> {escoltaAtiva.origem_endereco}</span>
                </div>
                <div className="flex items-start gap-1.5">
                  <Flag size={12} className="mt-0.5 shrink-0" style={{ color: '#7C3AED' }} />
                  <span className="leading-relaxed"><strong style={{ color: '#1E2D35' }}>Destino:</strong> {escoltaAtiva.destino_endereco}</span>
                </div>
                <div className="flex items-center gap-1.5">
                  <Clock size={12} style={{ color: '#A8B8C2' }} />
                  <span>Previsto: {new Date(escoltaAtiva.data_hora_prevista).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}</span>
                </div>
                {escoltaAtiva.veiculo_placa && (
                  <div className="flex items-center gap-1.5">
                    <Shield size={12} style={{ color: '#A8B8C2' }} />
                    <span>{escoltaAtiva.veiculo_placa}{escoltaAtiva.veiculo_modelo ? ` — ${escoltaAtiva.veiculo_modelo}` : ''}</span>
                  </div>
                )}
              </div>
            </div>
          </div>

          {/* ── Timeline da jornada ── */}
          <div className="card-light p-3 md:p-4">
            <p className="text-[10px] font-black uppercase tracking-widest mb-3 md:mb-4" style={{ color: '#6B7E8A' }}>Progresso da Operação</p>
            <div className="relative">
              <div className="absolute top-4 md:top-5 left-3 right-3 h-0.5" style={{ backgroundColor: '#E2E8EC' }} />
              <div
                className="absolute top-4 md:top-5 left-3 h-0.5 transition-all duration-700"
                style={{
                  backgroundColor: '#4A90A4',
                  width: idxAtual >= 0 ? `${(idxAtual / (JORNADA.length - 1)) * 100}%` : '0%'
                }}
              />
              <div className="relative flex justify-between">
                {JORNADA.map((step, idx) => {
                  const concluido = idx < idxAtual
                  const atual = idx === idxAtual
                  return (
                    <div key={step.status} className="flex flex-col items-center gap-1" style={{ width: `${100 / JORNADA.length}%` }}>
                      <div
                        className="rounded border-2 flex items-center justify-center z-10 transition-all"
                        style={{
                          width: '32px', height: '32px',
                          backgroundColor: concluido ? '#4A90A4' : atual ? '#1C2B35' : '#fff',
                          borderColor: concluido || atual ? '#4A90A4' : '#E2E8EC',
                          color: concluido || atual ? '#fff' : '#C4CDD4',
                          boxShadow: atual ? '0 0 0 3px rgba(74,144,164,0.15)' : 'none',
                        }}
                      >
                        {concluido ? <Check size={12}/> : step.icon}
                      </div>
                      <p
                        className="text-center font-bold uppercase tracking-wide leading-tight whitespace-pre-line"
                        style={{ fontSize: '8px', color: atual ? '#1C2B35' : concluido ? '#4A90A4' : '#C4CDD4' }}
                      >
                        {step.label}
                      </p>
                    </div>
                  )
                })}
              </div>
            </div>
          </div>

          {/* ═══════════════════════════════════════════════════════════════════
              PAINEL DE AÇÕES
          ═══════════════════════════════════════════════════════════════════ */}
          <div className="space-y-2">

            {/* ── [1] CHECKPOINT / Foto do status ── */}
            {podeAvancar && botaoAvanco && (
              <div className="card-light overflow-hidden" style={{ border: '1.5px solid rgba(74,144,164,0.3)' }}>
                {/* Header do painel */}
                <button
                  onClick={() => setPainelAberto(painelAberto === 'checkpoint' ? null : 'checkpoint')}
                  className="w-full flex items-center justify-between p-4 transition-colors hover:bg-[#F8FAFC]"
                >
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded flex items-center justify-center" style={{ backgroundColor: '#EBF3FC', border: '1px solid #BEDAEF' }}>
                      <Crosshair size={18} style={{ color: '#2166A8' }} />
                    </div>
                    <div className="text-left">
                      <p className="text-sm font-bold" style={{ color: '#1E2D35' }}>Registrar Checkpoint</p>
                      <p className="text-xs" style={{ color: '#6B7E8A' }}>
                        {fotoCheckpoint ? '✓ Foto capturada — pronto para confirmar' : 'Foto + GPS obrigatórios'}
                      </p>
                    </div>
                  </div>
                  <ChevronDown size={15} style={{ color: '#C4CDD4', transform: painelAberto === 'checkpoint' ? 'rotate(180deg)' : 'none', transition: 'transform 0.2s' }}/>
                </button>

                {painelAberto === 'checkpoint' && (
                  <div className="px-4 pb-4 pt-3 border-t space-y-3" style={{ borderColor: '#E2E8EC' }}>
                    {/* Input oculto */}
                    <input ref={fotoCheckpointRef} type="file" accept="image/*" capture="environment"
                      className="hidden" onChange={handleFotoCheckpoint} />

                    <FotoCapture
                      label="Tirar foto do checkpoint"
                      sublabel="GPS será capturado automaticamente"
                      captura={fotoCheckpoint}
                      onCapturar={handleFotoCheckpoint}
                      onLimpar={limparFotoCheckpoint}
                      fileRef={fotoCheckpointRef}
                    />

                    <div>
                      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '4px' }}>
                        <label className="block text-[11px] font-black uppercase tracking-widest" style={{ color: '#6B7E8A' }}>
                          Observação (opcional)
                        </label>
                        <div style={{ display: 'flex', gap: '4px' }}>
                          <VoiceInputButton onTranscript={t => setObsAvanco(v => v ? `${v} ${t}` : t)} />
                          <AiTextButton value={obsAvanco} onChange={setObsAvanco} contexto="Observação de ponto de controle em escolta armada" />
                        </div>
                      </div>
                      <input
                        type="text"
                        placeholder="Informe uma observação..."
                        value={obsAvanco}
                        onChange={e => setObsAvanco(e.target.value)}
                        className="input-light text-sm"
                        style={{ minHeight: '48px' }}
                      />
                    </div>

                    <button
                      onClick={avancarStatus}
                      disabled={executando}
                      className="w-full rounded text-white font-black text-sm uppercase tracking-wider flex items-center justify-center gap-2 transition-all active:scale-[0.98] disabled:opacity-50"
                      style={{ backgroundColor: botaoAvanco.cor, minHeight: '56px', padding: '0 16px' }}
                    >
                      {executando ? (
                        <>
                          <div className="w-4 h-4 rounded border-2 border-white/30 border-t-white animate-spin"/>
                          Registrando...
                        </>
                      ) : (
                        <>
                          {botaoAvanco.label}
                          <ChevronRight size={16}/>
                        </>
                      )}
                    </button>
                  </div>
                )}
              </div>
            )}

            {/* ── [2] CHECKLIST ── */}
            {mostrarChecklist && (
              <div className="card-light overflow-hidden">
                <button
                  onClick={() => setPainelAberto(painelAberto === 'checklist' ? null : 'checklist')}
                  className="w-full flex items-center justify-between p-4 transition-colors hover:bg-[#F8FAFC]"
                >
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded flex items-center justify-center" style={{ backgroundColor: '#EEF0FF', border: '1px solid #C7CBF4' }}>
                      <ClipboardList size={18} style={{ color: '#4338CA' }} />
                    </div>
                    <div className="text-left">
                      <p className="text-sm font-bold" style={{ color: '#1E2D35' }}>
                        {status === 'em_pre_inicio' ? 'Checklist Pré-Saída' : 'Checklist Pós-Retorno'}
                      </p>
                      <p className="text-xs" style={{ color: '#6B7E8A' }}>
                        {checklistRespondidos}/{checklistItems.length} itens respondidos
                      </p>
                    </div>
                  </div>
                  <div className="flex items-center gap-2">
                    {checklistRespondidos === checklistItems.length && checklistItems.length > 0 && (
                      <CheckCircle2 size={16} style={{ color: '#1E7C52' }} />
                    )}
                    <ChevronDown size={15} style={{ color: '#C4CDD4', transform: painelAberto === 'checklist' ? 'rotate(180deg)' : 'none', transition: 'transform 0.2s' }}/>
                  </div>
                </button>

                {painelAberto === 'checklist' && (
                  <div className="border-t" style={{ borderColor: '#E2E8EC' }}>
                    {/* Input foto dos itens (compartilhado) */}
                    <input
                      ref={fotoChecklistRef}
                      type="file"
                      accept="image/*"
                      capture="environment"
                      className="hidden"
                      onChange={handleFotoChecklist}
                    />

                    {checklistItems.length === 0 ? (
                      <p className="text-center text-xs py-8" style={{ color: '#A8B8C2' }}>Nenhum item configurado.</p>
                    ) : (
                      <div className="divide-y divide-[#E2E8EC]">
                        {checklistItems.map((item, idx) => (
                          <div key={item.id} className="px-4 py-3 space-y-2">
                            {/* Cabeçalho do item */}
                            <div className="flex items-start justify-between gap-3">
                              <p className="text-sm flex-1" style={{ color: '#1E2D35' }}>
                                <span className="text-xs mr-1.5" style={{ color: '#C4CDD4' }}>{idx + 1}.</span>
                                {item.descricao_item}
                                {item.exige_foto && (
                                  <span className="ml-1.5 text-[10px] px-1.5 py-0.5 rounded" style={{ backgroundColor: '#FFF8E8', color: '#A07212' }}>Foto obrigatória</span>
                                )}
                              </p>
                              {/* Botões ✓ / ✗ — touch-friendly (min 44px) */}
                              <div className="flex gap-2 shrink-0">
                                <button
                                  onClick={() => setChecklistItems(its => its.map((i, ii) => ii === idx ? { ...i, resposta: true } : i))}
                                  className="rounded flex items-center justify-center transition-all border"
                                  style={{
                                    width: '44px', height: '44px',
                                    ...(item.resposta === true
                                      ? { backgroundColor: '#1E7C52', borderColor: '#1E7C52', color: '#fff' }
                                      : { backgroundColor: '#fff', borderColor: '#E2E8EC', color: '#C4CDD4' })
                                  }}
                                >
                                  <Check size={16}/>
                                </button>
                                <button
                                  onClick={() => setChecklistItems(its => its.map((i, ii) => ii === idx ? { ...i, resposta: false } : i))}
                                  className="rounded flex items-center justify-center transition-all border"
                                  style={{
                                    width: '44px', height: '44px',
                                    ...(item.resposta === false
                                      ? { backgroundColor: '#B83832', borderColor: '#B83832', color: '#fff' }
                                      : { backgroundColor: '#fff', borderColor: '#E2E8EC', color: '#C4CDD4' })
                                  }}
                                >
                                  <X size={16}/>
                                </button>
                              </div>
                            </div>

                            {/* Quando reprovado: observação + foto */}
                            {item.resposta === false && (
                              <div className="space-y-2 pl-5">
                                <input
                                  type="text"
                                  placeholder="Descreva a não conformidade *"
                                  value={item.observacao}
                                  onChange={e => setChecklistItems(its => its.map((i, ii) => ii === idx ? { ...i, observacao: e.target.value } : i))}
                                  className="input-light text-xs px-2"
                                  style={{ minHeight: '44px' }}
                                />

                                {/* Foto do item não conforme */}
                                {item.fotoPreview ? (
                                  <div className="relative rounded overflow-hidden border" style={{ borderColor: '#E2E8EC' }}>
                                    {/* eslint-disable-next-line @next/next/no-img-element */}
                                    <img src={item.fotoPreview} alt="foto item" className="w-full h-28 object-cover" />
                                    <div className="absolute bottom-0 left-0 right-0 px-2 py-1.5" style={{ backgroundColor: 'rgba(0,0,0,0.6)' }}>
                                      <p className="text-white font-mono text-[10px]">{new Date().toLocaleString('pt-BR')}</p>
                                    </div>
                                    <button
                                      onClick={() => limparFotoChecklistItem(idx)}
                                      className="absolute top-1.5 right-1.5 w-6 h-6 rounded flex items-center justify-center"
                                      style={{ backgroundColor: 'rgba(0,0,0,0.5)' }}
                                    >
                                      <X size={11} className="text-white"/>
                                    </button>
                                  </div>
                                ) : (
                                  <button
                                    onClick={() => {
                                      setChecklistFotoIdx(idx)
                                      setTimeout(() => fotoChecklistRef.current?.click(), 50)
                                    }}
                                    className="flex items-center gap-2 text-xs px-3 rounded border transition-colors w-full justify-center"
                                    style={{ borderColor: '#E2E8EC', color: '#6B7E8A', backgroundColor: '#F8FAFC', minHeight: '44px' }}
                                  >
                                    <Camera size={14} />
                                    {item.exige_foto ? 'Tirar foto (obrigatório)' : 'Tirar foto do problema'}
                                  </button>
                                )}
                              </div>
                            )}
                          </div>
                        ))}
                      </div>
                    )}

                    <div className="p-4 border-t" style={{ borderColor: '#E2E8EC' }}>
                      <button
                        onClick={salvarChecklist}
                        disabled={executando || checklistItems.length === 0}
                        className="btn-primary w-full flex items-center justify-center gap-2 disabled:opacity-50"
                      >
                        <CheckCircle2 size={15}/>
                        {executando ? 'Salvando...' : 'Concluir Checklist'}
                      </button>
                    </div>
                  </div>
                )}
              </div>
            )}

            {/* ── [3] REGISTRAR OCORRÊNCIA ── */}
            {mostrarOcorrencia && (
              <div className="card-light overflow-hidden">
                <button
                  onClick={() => setPainelAberto(painelAberto === 'ocorrencia' ? null : 'ocorrencia')}
                  className="w-full flex items-center justify-between p-4 transition-colors hover:bg-[#F8FAFC]"
                >
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded flex items-center justify-center" style={{ backgroundColor: '#FFF8E8', border: '1px solid #F5DAAE' }}>
                      <AlertTriangle size={18} style={{ color: '#A07212' }} />
                    </div>
                    <div className="text-left">
                      <p className="text-sm font-bold" style={{ color: '#1E2D35' }}>Registrar Ocorrência</p>
                      <p className="text-xs" style={{ color: '#6B7E8A' }}>Incidente, irregularidade ou desvio</p>
                    </div>
                  </div>
                  <ChevronDown size={15} style={{ color: '#C4CDD4', transform: painelAberto === 'ocorrencia' ? 'rotate(180deg)' : 'none', transition: 'transform 0.2s' }}/>
                </button>

                {painelAberto === 'ocorrencia' && (
                  <div className="px-4 pb-4 pt-3 border-t space-y-3" style={{ borderColor: '#E2E8EC' }}>
                    <div>
                      <label className="block text-[11px] font-black uppercase tracking-widest mb-1" style={{ color: '#6B7E8A' }}>Tipo *</label>
                      <select value={tipoOcId} onChange={e => setTipoOcId(e.target.value)} className="select-light" style={{ minHeight: '48px' }}>
                        <option value="">Selecione o tipo...</option>
                        {tiposOcorrencia.map(t => <option key={t.id} value={t.id}>{t.nome}</option>)}
                      </select>
                    </div>

                    <div>
                      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '4px' }}>
                        <label className="block text-[11px] font-black uppercase tracking-widest" style={{ color: '#6B7E8A' }}>Descrição *</label>
                        <div style={{ display: 'flex', gap: '4px' }}>
                          <VoiceInputButton onTranscript={t => setDescOcorrencia(v => v ? `${v} ${t}` : t)} />
                          <AiTextButton value={descOcorrencia} onChange={setDescOcorrencia} contexto="Descrição de ocorrência em escolta armada" />
                        </div>
                      </div>
                      <textarea
                        rows={4}
                        value={descOcorrencia}
                        onChange={e => setDescOcorrencia(e.target.value)}
                        placeholder="Descreva o que aconteceu com o máximo de detalhes..."
                        className="input-light resize-none"
                        style={{ minHeight: '96px' }}
                      />
                    </div>

                    {/* Foto da ocorrência */}
                    <div>
                      <label className="block text-[11px] font-black uppercase tracking-widest mb-1.5" style={{ color: '#6B7E8A' }}>
                        Foto da Ocorrência (recomendado)
                      </label>
                      <input ref={fotoOcorrenciaRef} type="file" accept="image/*" capture="environment"
                        className="hidden" onChange={handleFotoOcorrencia} />
                      <FotoCapture
                        label="Tirar foto da ocorrência"
                        sublabel="Data, hora e GPS serão registrados automaticamente"
                        captura={fotoOcorrencia}
                        onCapturar={handleFotoOcorrencia}
                        onLimpar={limparFotoOcorrencia}
                        fileRef={fotoOcorrenciaRef}
                      />
                    </div>

                    <button
                      onClick={registrarOcorrencia}
                      disabled={executando || !tipoOcId || !descOcorrencia.trim()}
                      className="btn-primary w-full flex items-center justify-center gap-2 disabled:opacity-50"
                    >
                      {executando ? 'Registrando...' : 'Registrar Ocorrência'}
                    </button>
                  </div>
                )}
              </div>
            )}
          </div>

          {/* ── EMERGÊNCIA ── */}
          {!['finalizada', 'cancelada'].includes(status) && (
            <div className="pt-1">
              {!emergConfirm ? (
                <button
                  onClick={() => setEmergConfirm(true)}
                  className="w-full rounded flex items-center justify-center gap-3 transition-all active:scale-[0.98]"
                  style={{ backgroundColor: '#FEF0EE', border: '2px solid #F5C4BF', minHeight: '64px' }}
                >
                  <Zap size={22} style={{ color: '#B83832' }}/>
                  <span className="text-base font-black uppercase tracking-widest" style={{ color: '#B83832' }}>
                    Acionar Emergência
                  </span>
                  <Zap size={22} style={{ color: '#B83832' }}/>
                </button>
              ) : (
                <div className="rounded p-5 space-y-4" style={{ border: '2px solid #F5C4BF', backgroundColor: '#FEF0EE' }}>
                  <div className="text-center">
                    <p className="text-base font-black" style={{ color: '#B83832' }}>Confirmar Emergência?</p>
                    <p className="text-xs mt-1" style={{ color: '#C9706A' }}>A central será notificada imediatamente. Use apenas em situação real.</p>
                  </div>
                  <div className="flex gap-3">
                    <button
                      onClick={() => setEmergConfirm(false)}
                      className="flex-1 rounded text-sm font-semibold border bg-white transition-colors"
                      style={{ borderColor: '#E2E8EC', color: '#5C6B73', minHeight: '52px' }}
                    >
                      Cancelar
                    </button>
                    <button
                      onClick={acionarEmergencia}
                      disabled={executando}
                      className="flex-1 rounded text-white font-black text-sm uppercase tracking-wider transition-colors disabled:opacity-50"
                      style={{ backgroundColor: '#B83832', minHeight: '52px' }}
                    >
                      {executando ? 'Acionando...' : 'CONFIRMAR'}
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}

          {/* ── Finalizado ── */}
          {status === 'finalizada' && (
            <div className="card-light p-6 text-center">
              <CheckCircle2 size={40} className="mx-auto mb-2" style={{ color: '#1E7C52' }}/>
              <p className="font-black uppercase tracking-widest" style={{ color: '#1E2D35' }}>Escolta Finalizada</p>
              <p className="text-xs mt-1" style={{ color: '#6B7E8A' }}>Esta operação foi concluída com sucesso.</p>
            </div>
          )}
        </>
      )}
    </div>
  )
}
