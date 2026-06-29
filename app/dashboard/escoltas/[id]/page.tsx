'use client'

import { useEffect, useState, useCallback, useRef } from 'react'
import { useRouter, useParams } from 'next/navigation'
import {
  ArrowLeft, Truck, Users, Clock, AlertTriangle,
  MapPin, ArrowRight, CheckCircle2, XCircle,
  UserCheck, Camera, ClipboardList, Navigation,
  ChevronRight, Shield, AlertCircle, Play, Octagon,
  RotateCcw, Home, CalendarClock, Radio, Locate, FileDown
} from 'lucide-react'
import { printEscolta } from '@/utils/print'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { formatarDataHora, formatarPlaca } from '@/utils/formatters'
import { TextAreaWithTools } from '@/components/ui/textarea-with-tools'
import {
  PODE_AVANCAR_ESCOLTA,
  PODE_CANCELAR_ESCOLTA,
  PODE_VER_FINANCEIRO,
} from '@/lib/permissions'

// ─── Tipos ───────────────────────────────────────────────────────────────────

interface EscoltaDetalhe {
  id: string
  codigo_escolta: string | null
  status: string
  data_hora_prevista: string
  data_finalizacao: string | null
  origem_endereco: string
  destino_endereco: string
  observacao_fechamento: string | null
  checklist_pendente_no_inicio: boolean
  criada_por: string
  criado_em: string
  cliente: { id: string; nome_cliente: string; cor_destaque: string; telefone: string } | null
  valor_cobrado: number | null
  outros_custos: number | null
  observacao_financeira: string | null
  periodicidade_checkin_min: number | null
}

interface ViaturaDetalhe {
  id: string
  veiculo_id: string
  quilometragem_saida: number
  quilometragem_retorno: number | null
  abastecimento_litros: number | null
  abastecimento_valor: number | null
  veiculo: { placa: string; modelo: string | null; tipo: { nome: string } | null } | null
  efetivo: EfetivoItem[]
}

interface EfetivoItem {
  id: string
  vigilante_id: string
  papel_na_escolta: string
  confirmado: boolean
  valor_pago_vigilante: number | null
  vigilante: { nome_completo: string } | null
}

interface HistoricoItem {
  id: string
  status_anterior: string
  status_novo: string
  data_hora: string
  observacao: string | null
  alterado_por: string | null
  autor: { nome_completo: string } | null
}

interface ParadaItem {
  id: string
  tipo: string
  tipoLabel: string
  justificativa: string
  data_hora: string
  latitude: number | null
  longitude: number | null
  fotoUrls: string[]
  autor: string
  veiculo: string
}

interface ChecklistRespostaDetalhe {
  descricao_item: string
  conforme: boolean
  observacao: string | null
  foto_url: string | null
}

interface ChecklistDetalhe {
  tipo: string
  modelo: string | null
  data_conclusao: string
  autor: string
  placa?: string
  respostas: ChecklistRespostaDetalhe[]
}

interface TimelineItem {
  id: string
  tipo: 'status' | 'ponto_controle' | 'presenca' | 'checklist' | 'ocorrencia'
  data_hora: string
  titulo: string
  descricao: string | null
  usuario: string | null
  coordenadas?: { lat: number; lng: number } | null
  foto_url?: string | null
  extra?: Record<string, unknown>
}

interface OcorrenciaItem {
  id: string
  descricao: string
  data_hora: string
  tipo: { nome: string } | null
  autor: { nome_completo: string } | null
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function calcDuracao(inicio: string, fim?: string | null): string {
  const ms = new Date(fim ?? new Date()).getTime() - new Date(inicio).getTime()
  if (ms < 0) return '—'
  const h = Math.floor(ms / 3_600_000)
  const m = Math.floor((ms % 3_600_000) / 60_000)
  return h > 0 ? `${h}h ${m}min` : `${m}min`
}

function nowLocalStr() {
  const d = new Date()
  return d.toLocaleDateString('pt-BR') + ' às ' + d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })
}

const TIPO_PONTO_IDS = {
  BASE_SAIDA:   '18ce0259-8471-46ac-bc12-6602678fa910',
  ORIGEM:       'e1aec874-4d4e-4aa2-bae2-de4e711a9f9f',
  DESTINO:      'e4623e3e-a210-4c17-942a-80f01cc28f2d',
  BASE_RETORNO: 'c9bc3e19-d55d-4174-8acb-12fe1e2b50b7',
  PARADA:       'e1601f15-5ef9-44e8-abd0-17f65b3aa760',
} as const

const TIPO_FOTO_IDS = {
  PONTO_CONTROLE:      'db608f8f-322e-4748-b4f8-fef572a6c1e6',
  CHECKLIST_MATERIAL:  '0b3e6a7a-26d7-43a6-ae03-a0ccb938bf3c',
  CHECKLIST_VIATURA:   'bcaae1bb-5cb0-420c-a436-80b777082625',
  VIAT_FRENTE:         'd01d67c3-6d44-4ba7-81cb-ff75c1ad29c9',
  VIAT_TRASEIRA:       '4e38ffd0-68de-43de-a0a0-de648d63c4c3',
  VIAT_LAT_ESQ:        'bc950651-865f-4f01-86ae-9048baced9e8',
  VIAT_LAT_DIR:        'add816e1-218f-4538-8eef-7ea25107f4e0',
  VIAT_PAINEL:         '405bceff-db5d-4c10-b4ba-89aa16929fb4',
} as const

const FOTOS_VIATURA_DEF = [
  { key: 'frente',   label: 'Frontal',           tipoId: 'd01d67c3-6d44-4ba7-81cb-ff75c1ad29c9' },
  { key: 'traseira', label: 'Traseira',           tipoId: '4e38ffd0-68de-43de-a0a0-de648d63c4c3' },
  { key: 'lat_esq',  label: 'Lateral Esquerda',  tipoId: 'bc950651-865f-4f01-86ae-9048baced9e8' },
  { key: 'lat_dir',  label: 'Lateral Direita',   tipoId: 'add816e1-218f-4538-8eef-7ea25107f4e0' },
  { key: 'painel',   label: 'Painel / Interior', tipoId: '405bceff-db5d-4c10-b4ba-89aa16929fb4' },
] as const

const ITENS_CHECKLIST_VIATURA = [
  { key: 'pneus',        label: 'Pneus e estepe calibrados e em bom estado' },
  { key: 'oleo',         label: 'Nível de óleo do motor e líquido de arrefecimento' },
  { key: 'farois',       label: 'Faróis, setas, lanternas e sirene funcionais' },
  { key: 'armamentos',   label: 'Armas e munições guardadas e travadas no cofre' },
  { key: 'combustivel',  label: 'Combustível suficiente para a operação' },
  { key: 'cintos',       label: 'Cintos de segurança funcionais em todos os assentos' },
  { key: 'documentacao', label: 'Documentação do veículo em dia (CRLV, seguro)' },
  { key: 'limpeza',      label: 'Conservação de limpeza e higiene geral' },
]

const TIPO_ICON_MAP: Record<string, { color: string; bg: string; label: string }> = {
  status:        { color: '#1A294A', bg: 'rgba(26,41,74,0.10)',  label: 'Mudança de Status' },
  ponto_controle:{ color: '#1E7C52', bg: 'rgba(30,124,82,0.10)', label: 'Ponto de Controle' },
  presenca:      { color: '#7C3AED', bg: 'rgba(124,58,237,0.10)',label: 'Presença' },
  checklist:     { color: '#53648A', bg: 'rgba(83,100,138,0.10)',label: 'Checklist de Início' },
  ocorrencia:    { color: '#A07212', bg: 'rgba(160,114,18,0.10)',label: 'Ocorrência' },
}

// ─── CameraInput ─────────────────────────────────────────────────────────────

function CameraInput({
  onChange,
  max = 1,
  prefixoNome = 'foto',
}: {
  onChange: (files: File[]) => void
  max?: number
  prefixoNome?: string
}) {
  const [fotos, setFotos] = useState<Array<{ file: File; url: string }>>([])
  const [aberto, setAberto] = useState(false)
  const [stream, setStream] = useState<MediaStream | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const videoRef = useRef<HTMLVideoElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)

  const abrirCamera = async () => {
    if (fotos.length >= max) return
    setErro(null)
    setAberto(true)
    try {
      const s = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } },
        audio: false,
      })
      setStream(s)
    } catch {
      setErro('Permissão de câmera negada ou câmera não encontrada.')
    }
  }

  useEffect(() => {
    if (stream && videoRef.current) {
      videoRef.current.srcObject = stream
      videoRef.current.play().catch(() => {})
    }
  }, [stream])

  const capturar = () => {
    if (!videoRef.current || !canvasRef.current) return
    const v = videoRef.current
    const c = canvasRef.current
    c.width = v.videoWidth
    c.height = v.videoHeight
    const ctx = c.getContext('2d')
    if (!ctx) return
    ctx.drawImage(v, 0, 0)
    const agora = new Date()
    const ts = agora.toLocaleDateString('pt-BR') + ' ' + agora.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit', second: '2-digit' })
    const fs = Math.max(14, Math.floor(c.width * 0.022))
    ctx.font = `bold ${fs}px monospace`
    const tw = ctx.measureText(ts).width + 20
    ctx.fillStyle = 'rgba(0,0,0,0.55)'
    ctx.fillRect(8, c.height - fs * 2.2, tw, fs * 1.8)
    ctx.fillStyle = '#FFFFFF'
    ctx.fillText(ts, 16, c.height - fs * 0.5)
    c.toBlob((blob) => {
      if (!blob) return
      const tsStr = agora.toISOString().replace(/[:.]/g, '-').slice(0, 19)
      const file = new File([blob], `${prefixoNome}_${tsStr}.jpg`, { type: 'image/jpeg' })
      const novas = [...fotos, { file, url: URL.createObjectURL(blob) }]
      setFotos(novas)
      onChange(novas.map(f => f.file))
      if (novas.length >= max) fechar()
    }, 'image/jpeg', 0.92)
  }

  const remover = (idx: number) => {
    URL.revokeObjectURL(fotos[idx].url)
    const novas = fotos.filter((_, i) => i !== idx)
    setFotos(novas)
    onChange(novas.map(f => f.file))
  }

  const fechar = () => {
    stream?.getTracks().forEach(t => t.stop())
    setStream(null)
    setAberto(false)
    setErro(null)
  }

  useEffect(() => () => { stream?.getTracks().forEach(t => t.stop()) }, [stream])

  const cols = Math.min(fotos.length + (fotos.length < max ? 1 : 0), 4)

  return (
    <>
      {fotos.length > 0 && (
        <div style={{ display: 'grid', gridTemplateColumns: `repeat(${cols}, 1fr)`, gap: '6px', marginBottom: '6px' }}>
          {fotos.map((f, idx) => (
            <div key={idx} style={{ position: 'relative', aspectRatio: '1' }}>
              <img src={f.url} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
              <button type="button" onClick={() => remover(idx)}
                style={{ position: 'absolute', top: 2, right: 2, backgroundColor: '#B83832', color: '#fff', width: '16px', height: '16px', fontSize: '12px', display: 'flex', alignItems: 'center', justifyContent: 'center', border: 'none', cursor: 'pointer', lineHeight: 1 }}>
                ×
              </button>
              <div style={{ position: 'absolute', bottom: 2, left: 2, backgroundColor: 'rgba(0,0,0,0.6)', color: '#fff', fontSize: '8px', fontWeight: 700, padding: '1px 4px' }}>
                {idx + 1}/{max}
              </div>
            </div>
          ))}
          {fotos.length < max && (
            <button type="button" onClick={abrirCamera}
              style={{ aspectRatio: '1', backgroundColor: '#F5F7FA', border: '1.5px dashed #D6DAE5', color: '#5A6A80', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: '4px', cursor: 'pointer' }}>
              <Camera size={16} />
              <span style={{ fontSize: '8px', fontWeight: 700, textTransform: 'uppercase' }}>+ Foto</span>
            </button>
          )}
        </div>
      )}
      {fotos.length === 0 && (
        <button type="button" onClick={abrirCamera}
          className="flex items-center justify-center gap-2 w-full font-black uppercase tracking-widest text-white transition-all active:scale-[0.98]"
          style={{ height: '42px', backgroundColor: '#1A294A', fontSize: '10px', letterSpacing: '0.12em' }}
          onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#253562' }}
          onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#1A294A' }}>
          <Camera size={15} /> Abrir Câmera
        </button>
      )}
      {fotos.length >= max && (
        <div className="flex items-center gap-1.5 mt-1">
          <CheckCircle2 size={11} style={{ color: '#1E7C52' }} />
          <span style={{ fontSize: '10px', fontWeight: 700, color: '#1E7C52' }}>{fotos.length} foto(s) capturada(s)</span>
        </div>
      )}
      {aberto && (
        <div style={{ position: 'fixed', inset: 0, zIndex: 99999, backgroundColor: 'rgba(0,0,0,0.95)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: '1rem', padding: '1rem' }}>
          {erro ? (
            <div style={{ textAlign: 'center', color: '#fff' }}>
              <p style={{ fontSize: '14px', marginBottom: '1rem' }}>{erro}</p>
              <button type="button" onClick={fechar} style={{ padding: '0.5rem 1.5rem', backgroundColor: '#53648A', color: '#fff', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em' }}>Fechar</button>
            </div>
          ) : (
            <>
              <p style={{ color: 'rgba(255,255,255,0.5)', fontSize: '10px', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.12em' }}>
                {stream ? `Foto ${fotos.length + 1} de ${max} — Enquadre e capture` : 'Iniciando câmera...'}
              </p>
              <video ref={videoRef} playsInline autoPlay muted style={{ width: '100%', maxWidth: '480px', maxHeight: '60vh', objectFit: 'cover', backgroundColor: '#111' }} />
              <canvas ref={canvasRef} style={{ display: 'none' }} />
              <div style={{ display: 'flex', gap: '0.75rem', width: '100%', maxWidth: '480px' }}>
                <button type="button" onClick={capturar} disabled={!stream}
                  style={{ flex: 1, height: '48px', backgroundColor: stream ? '#1E7C52' : '#333', color: '#fff', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '8px' }}>
                  <Camera size={16} /> Capturar Foto
                </button>
                <button type="button" onClick={fechar}
                  style={{ height: '48px', padding: '0 1.25rem', backgroundColor: fotos.length > 0 ? '#1A294A' : '#B83832', color: '#fff', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em' }}>
                  {fotos.length > 0 ? 'Concluir' : 'Cancelar'}
                </button>
              </div>
            </>
          )}
        </div>
      )}
    </>
  )
}

// ─── Mapeamentos ──────────────────────────────────────────────────────────────

const STATUS_INFO: Record<string, { label: string; cls: string }> = {
  rascunho:      { label: 'Rascunho',     cls: 'badge-neutral' },
  agendada:      { label: 'Agendada',     cls: 'badge-info' },
  em_pre_inicio: { label: 'Pré-Início',   cls: 'badge-warning' },
  em_andamento:  { label: 'Em Andamento', cls: 'badge-info' },
  na_origem:     { label: 'Na Origem',    cls: 'badge-info' },
  no_destino:    { label: 'No Destino',   cls: 'badge-success' },
  retornando:    { label: 'Retornando',   cls: 'badge-warning' },
  na_base:       { label: 'Na Base',      cls: 'badge-success' },
  finalizada:    { label: 'Finalizada',   cls: 'badge-success' },
  cancelada:     { label: 'Cancelada',    cls: 'badge-danger' },
}

const TIPOS_PARADA = [
  { value: 'reporte_periodico', label: 'Reporte Periódico',    cor: '#1E7C52' },
  { value: 'registro_parada',   label: 'Registro de Parada',   cor: '#8B6914' },
  { value: 'em_transito',       label: 'Em Trânsito',          cor: '#53648A' },
  { value: 'parada_curta',      label: 'Parada Curta',         cor: '#8B6914' },
  { value: 'manutencao',        label: 'Manutenção de Veículo',cor: '#B83832' },
  { value: 'solicitacao',       label: 'Solicitação de Parada',cor: '#9F906D' },
  { value: 'ligacao',           label: 'Ligação Telefônica',   cor: '#1A294A' },
  { value: 'abastecimento',     label: 'Abastecimento',        cor: '#1E7C52' },
  { value: 'refeicao',          label: 'Refeição / Descanso',  cor: '#7C3AED' },
  { value: 'inspecao',          label: 'Inspeção de Carga',    cor: '#0891B2' },
  { value: 'ocorrencia',        label: 'Ocorrência / Acidente',cor: '#B83832' },
  { value: 'bloqueio',          label: 'Bloqueio na Via',      cor: '#A07212' },
  { value: 'fiscalizacao',      label: 'Fiscalização / Blitz', cor: '#1A294A' },
  { value: 'aguardando',        label: 'Aguardando Autorização',cor: '#5A6A80' },
]

const NEXT_STATUS: Record<string, { status: string; label: string } | null> = {
  rascunho:      { status: 'agendada',      label: 'Agendar Escolta' },
  agendada:      { status: 'em_pre_inicio', label: 'Iniciar Pré-Início' },
  em_pre_inicio: null,
  em_andamento:  { status: 'na_origem',     label: 'Confirmar na Origem' },
  na_origem:     { status: 'no_destino',    label: 'Confirmar no Destino' },
  no_destino:    { status: 'retornando',    label: 'Iniciar Retorno' },
  retornando:    { status: 'na_base',       label: 'Confirmar na Base' },
  na_base:       { status: 'finalizada',    label: 'Finalizar Escolta' },
  finalizada:    null,
  cancelada:     null,
}

const JORNADA_ETAPAS = [
  { statuses: ['rascunho', 'agendada'],      label: 'Planejamento' },
  { statuses: ['em_pre_inicio'],             label: 'Pré-Início' },
  { statuses: ['em_andamento'],              label: 'Em Trânsito' },
  { statuses: ['na_origem'],                 label: 'Na Origem' },
  { statuses: ['no_destino'],                label: 'No Destino' },
  { statuses: ['retornando'],                label: 'Retorno' },
  { statuses: ['na_base', 'finalizada'],     label: 'Concluída' },
]

const PODE_AVANCAR = PODE_AVANCAR_ESCOLTA
const PODE_CANCELAR = PODE_CANCELAR_ESCOLTA

type Tab = 'geral' | 'timeline' | 'efetivo' | 'veiculos' | 'ocorrencias' | 'financeiro'

const PERFIS_FINANCEIRO_DET = PODE_VER_FINANCEIRO

// ─── Componente Principal ─────────────────────────────────────────────────────

export default function EscoltaDetalhePage() {
  const router = useRouter()
  const params = useParams()
  const id = params.id as string
  const { user } = useAuth()
  const supabase = createClient()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const sb = supabase as any

  const [escolta, setEscolta] = useState<EscoltaDetalhe | null>(null)
  const [viaturas, setViaturas] = useState<ViaturaDetalhe[]>([])
  const [historico, setHistorico] = useState<HistoricoItem[]>([])
  const [ocorrencias, setOcorrencias] = useState<OcorrenciaItem[]>([])
  const [timeline, setTimeline] = useState<TimelineItem[]>([])
  const [loading, setLoading] = useState(true)
  const [tab, setTab] = useState<Tab>('geral')
  const [selectedPhoto, setSelectedPhoto] = useState<{ url: string; titulo: string } | null>(null)
  const [selectedTimelineItem, setSelectedTimelineItem] = useState<TimelineItem | null>(null)
  const [checklistModal, setChecklistModal] = useState<TimelineItem | null>(null)
  const [agora, setAgora] = useState(new Date())

  useEffect(() => {
    const t = setInterval(() => setAgora(new Date()), 60_000)
    return () => clearInterval(t)
  }, [])

  const [dialogAvanco, setDialogAvanco] = useState(false)
  const [motivoAvanco, setMotivoAvanco] = useState('')
  const [avancando, setAvancando] = useState(false)
  const [dialogCancelar, setDialogCancelar] = useState(false)
  const [abaDialogCancelar, setAbaDialogCancelar] = useState<'cancelar' | 'reagendar'>('cancelar')
  const [motivoCancelamento, setMotivoCancelamento] = useState('')
  const [motivoReagendamento, setMotivoReagendamento] = useState('')
  const [novaDataReagendamento, setNovaDataReagendamento] = useState('')
  const [novaHoraReagendamento, setNovaHoraReagendamento] = useState('08:00')
  const [cancelando, setCancelando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  // Dialogs de Ações do Operador
  const [dialogStartBase, setDialogStartBase] = useState(false)
  const [dialogParada, setDialogParada] = useState(false)
  const [dialogChegadaOrigem, setDialogChegadaOrigem] = useState(false)
  const [dialogChegadaDestino, setDialogChegadaDestino] = useState(false)
  const [dialogIniciarRetorno, setDialogIniciarRetorno] = useState(false)
  const [dialogChegadaBase, setDialogChegadaBase] = useState(false)
  const [dialogFinalizacao, setDialogFinalizacao] = useState(false)

  // Estados dos formulários de ações
  const [fotoStartBase, setFotoStartBase] = useState<File | null>(null)
  const [kmStartBase, setKmStartBase] = useState('')
  const [obsStartBase, setObsStartBase] = useState('')

  const [tipoParada, setTipoParada] = useState('parada_curta')
  const [obsParada, setObsParada] = useState('')
  const [fotosParada, setFotosParada] = useState<File[]>([])
  const [paradas, setParadas] = useState<ParadaItem[]>([])
  const [paradaSelecionada, setParadaSelecionada] = useState<ParadaItem | null>(null)

  // Check-in periódico
  const [dialogCheckin, setDialogCheckin] = useState(false)
  const [fotoCheckin, setFotoCheckin] = useState<File | null>(null)
  const [obsCheckin, setObsCheckin] = useState('')
  const [gpsCheckin, setGpsCheckin] = useState<{ lat: number; lng: number; precisao: number; endereco: string } | null>(null)
  const [gpsCheckinLoading, setGpsCheckinLoading] = useState(false)

  // Periodicidade de check-in
  const [editandoPeriodicidade, setEditandoPeriodicidade] = useState(false)
  const [periodicidadeEdit, setPeriodicidadeEdit] = useState<string>('')
  const [minutosAteCheckin, setMinutosAteCheckin] = useState<number | null>(null)

  const [fotoOrigem, setFotoOrigem] = useState<File | null>(null)
  const [obsOrigem, setObsOrigem] = useState('')
  const [opcoesOrigem, setOpcoesOrigem] = useState<string[]>([])

  const [fotoDestino, setFotoDestino] = useState<File | null>(null)
  const [obsDestino, setObsDestino] = useState('')

  const [obsRetorno, setObsRetorno] = useState('')
  const [fotoRetorno, setFotoRetorno] = useState<File | null>(null)

  const [kmChegadaBase, setKmChegadaBase] = useState('')
  const [obsChegadaBase, setObsChegadaBase] = useState('')
  const [fotoChegadaBase, setFotoChegadaBase] = useState<File | null>(null)

  // Estados da finalização
  const [relatorioFinal, setRelatorioFinal] = useState('')
  const [fotosViaturaFinal, setFotosViaturaFinal] = useState<Record<string, File | null>>(
    Object.fromEntries(FOTOS_VIATURA_DEF.map(f => [f.key, null]))
  )
  const [checklistFinal, setChecklistFinal] = useState<Record<string, { resposta: boolean; obs: string }>>({
    pneus: { resposta: true, obs: '' },
    oleo_agua: { resposta: true, obs: '' },
    farois: { resposta: true, obs: '' },
    armamentos: { resposta: true, obs: '' },
    limpeza: { resposta: true, obs: '' }
  })

  // Designação e Wizard de Inicialização
  const [designando, setDesignando] = useState(false)
  const [usuariosOperacionais, setUsuariosOperacionais] = useState<any[]>([])

  const [wizardStep, setWizardStep] = useState(1)
  const [checkMateriais, setCheckMateriais] = useState<Record<string, boolean>>({
    coletes: false,
    radios: false,
    lanternas: false
  })
  const [fotoMateriais, setFotoMateriais] = useState<File | null>(null)
  const [obsMateriais, setObsMateriais] = useState('')

  const [checkViatura, setCheckViatura] = useState<Record<string, boolean>>(
    Object.fromEntries(ITENS_CHECKLIST_VIATURA.map(i => [i.key, false]))
  )
  const [fotosViatura, setFotosViatura] = useState<Record<string, File | null>>(
    Object.fromEntries(FOTOS_VIATURA_DEF.map(f => [f.key, null]))
  )
  const [obsViatura, setObsViatura] = useState('')

  const [kmPartida, setKmPartida] = useState('')
  const [fotoPartida, setFotoPartida] = useState<File | null>(null)
  const [obsPartida, setObsPartida] = useState('')

  const carregar = useCallback(async () => {
    setLoading(true)
    setErro(null)

    // ── Escolta principal ──────────────────────────────────────────────────────
    const { data: esc, error: escErr } = await sb
      .from('escoltas')
      .select(`
        id, codigo_escolta, status, data_hora_prevista, data_finalizacao,
        origem_endereco, destino_endereco, observacao_fechamento,
        checklist_pendente_no_inicio, criada_por, criado_em,
        valor_cobrado, outros_custos, observacao_financeira,
        periodicidade_checkin_min,
        cliente:clientes(id, nome_cliente, cor_destaque, telefone)
      `)
      .eq('id', id)
      .maybeSingle()

    if (escErr) {
      setErro(`Erro ao carregar: ${escErr.message}`)
      setLoading(false)
      return
    }

    setEscolta(esc as EscoltaDetalhe | null)
    if (!esc) { setLoading(false); return }

    // ── Carregar Usuários para designar responsabilidade ───────────────────────
    const { data: usr } = await sb
      .from('usuarios')
      .select('id, nome_completo, email')
      .order('nome_completo')
    if (usr) {
      setUsuariosOperacionais(usr)
    }

    // ── Viaturas ──────────────────────────────────────────────────────────────
    const { data: viats } = await sb
      .from('escolta_veiculos')
      .select(`
        id, veiculo_id, quilometragem_saida, quilometragem_retorno,
        abastecimento_litros, abastecimento_valor,
        veiculo:veiculos(placa, modelo, tipo:dom_tipos_veiculo(nome))
      `)
      .eq('escolta_id', id)

    const viatsNorm = (viats ?? []) as Omit<ViaturaDetalhe, 'efetivo'>[]
    const viaturaIds = viatsNorm.map((v) => v.id)

    // ── Efetivo ───────────────────────────────────────────────────────────────
    const { data: efet } = viaturaIds.length > 0
      ? await sb
          .from('escolta_efetivo')
          .select(`id, vigilante_id, papel_na_escolta, confirmado, valor_pago_vigilante, escolta_veiculo_id, vigilante:vigilantes(nome_completo)`)
          .in('escolta_veiculo_id', viaturaIds)
      : { data: null }

    const efetNorm = (efet ?? []) as (EfetivoItem & { escolta_veiculo_id: string })[]
    setViaturas(viatsNorm.map((v) => ({ ...v, efetivo: efetNorm.filter((e) => e.escolta_veiculo_id === v.id) })))

    // ── Histórico de status ───────────────────────────────────────────────────
    const { data: hist } = await sb
      .from('escolta_status_historico')
      .select(`id, status_anterior, status_novo, data_hora, observacao, alterado_por, autor:usuarios!alterado_por(nome_completo)`)
      .eq('escolta_id', id)
      .order('data_hora', { ascending: true })

    const histNorm = (hist ?? []) as HistoricoItem[]
    setHistorico(histNorm)

    // ── Ocorrências ───────────────────────────────────────────────────────────
    const { data: ocorrs } = await sb
      .from('ocorrencias')
      .select(`id, descricao, data_hora, registrado_por, tipo:dom_tipos_ocorrencia(nome), autor:usuarios!registrado_por(nome_completo)`)
      .eq('escolta_id', id)
      .order('data_hora', { ascending: false })

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    setOcorrencias((ocorrs ?? []) as any[])

    // ── Pontos de controle ────────────────────────────────────────────────────
    const { data: pts } = viaturaIds.length > 0
      ? await sb
          .from('pontos_controle')
          .select(`id, escolta_veiculo_id, data_hora, latitude, longitude, lancado_por, observacoes, tipo:dom_tipos_ponto(codigo, nome_exibicao), foto:fotos(id, caminho_arquivo), autor:usuarios!lancado_por(nome_completo)`)
          .in('escolta_veiculo_id', viaturaIds)
      : { data: null }

    // ── Presenças ─────────────────────────────────────────────────────────────
    const { data: pres } = await sb
      .from('presencas')
      .select(`id, escolta_id, vigilante_id, data_hora, latitude, longitude, vigilante:vigilantes(nome_completo), foto:fotos(id, caminho_arquivo), autor:usuarios!criado_por(nome_completo)`)
      .eq('escolta_id', id)

    // ── Checklists ────────────────────────────────────────────────────────────
    const { data: chks } = viaturaIds.length > 0
      ? await sb
          .from('checklists')
          .select(`id, escolta_veiculo_id, tipo, concluido, data_conclusao, modelo:checklist_modelos(nome), autor:usuarios!responsavel_id(nome_completo), respostas:checklist_respostas(id, descricao_item, conforme, observacao, foto:fotos(id, caminho_arquivo))`)
          .in('escolta_veiculo_id', viaturaIds)
      : { data: null }

    // ── Montar timeline integrada ─────────────────────────────────────────────
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const getFotoUrl = (foto: any) => {
      if (!foto) return null
      const path = foto.caminho_arquivo as string
      if (path.startsWith('http://') || path.startsWith('https://')) return path
      return supabase.storage.from('fotos').getPublicUrl(path).data.publicUrl
    }

    const tl: TimelineItem[] = []

    histNorm.forEach((h) => {
      tl.push({
        id: h.id,
        tipo: 'status',
        data_hora: h.data_hora,
        titulo: `${STATUS_INFO[h.status_anterior]?.label ?? h.status_anterior} → ${STATUS_INFO[h.status_novo]?.label ?? h.status_novo}`,
        descricao: h.observacao,
        usuario: h.autor?.nome_completo ?? 'Sistema',
        extra: { status_anterior: h.status_anterior, status_novo: h.status_novo },
      })
    })

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(pts ?? []).forEach((p: any) => {
      const viat = viatsNorm.find((v) => v.id === p.escolta_veiculo_id)
      const placa = viat?.veiculo?.placa ? ` (${formatarPlaca(viat.veiculo.placa)})` : ''
      tl.push({
        id: p.id,
        tipo: 'ponto_controle',
        data_hora: p.data_hora,
        titulo: `${p.tipo?.nome_exibicao ?? 'Ponto de Controle'}${placa}`,
        descricao: null,
        usuario: p.autor?.nome_completo ?? 'Operador',
        coordenadas: p.latitude && p.longitude ? { lat: Number(p.latitude), lng: Number(p.longitude) } : null,
        foto_url: getFotoUrl(p.foto),
      })
    })

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(pres ?? []).forEach((p: any) => {
      tl.push({
        id: p.id,
        tipo: 'presenca',
        data_hora: p.data_hora,
        titulo: `Presença confirmada — ${p.vigilante?.nome_completo ?? 'Vigilante'}`,
        descricao: null,
        usuario: p.autor?.nome_completo ?? 'Sistema',
        coordenadas: p.latitude && p.longitude ? { lat: Number(p.latitude), lng: Number(p.longitude) } : null,
        foto_url: getFotoUrl(p.foto),
      })
    })

    // Consolidar TODOS os checklists em UM único entry na timeline
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const checklistsConcluidos = (chks ?? []).filter((c: any) => !!c.data_conclusao)
    if (checklistsConcluidos.length > 0) {
      // Foto representativa — primeira foto encontrada em qualquer checklist
      let primeiraFotoUrl: string | null = null
      const checklistsDetalhes: ChecklistDetalhe[] = []

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      checklistsConcluidos.forEach((c: any) => {
        const viat = viatsNorm.find((v) => v.id === c.escolta_veiculo_id)
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const respostas: ChecklistRespostaDetalhe[] = (c.respostas ?? []).map((r: any) => {
          const fotoUrl = r.foto ? getFotoUrl(r.foto) : null
          if (!primeiraFotoUrl && fotoUrl) primeiraFotoUrl = fotoUrl
          return {
            descricao_item: r.descricao_item,
            conforme: r.conforme,
            observacao: r.observacao ?? null,
            foto_url: fotoUrl,
          }
        })
        checklistsDetalhes.push({
          tipo: c.tipo,
          modelo: c.modelo?.nome ?? null,
          data_conclusao: c.data_conclusao,
          autor: c.autor?.nome_completo ?? 'Supervisor',
          placa: viat?.veiculo?.placa,
          respostas,
        })
      })

      // Data mais antiga entre os checklists concluídos
      const dataHora = checklistsConcluidos
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        .map((c: any) => c.data_conclusao as string)
        .sort()[0]

      const totalItens = checklistsDetalhes.reduce((s, c) => s + c.respostas.length, 0)
      const totalConformes = checklistsDetalhes.reduce((s, c) => s + c.respostas.filter(r => r.conforme).length, 0)

      tl.push({
        id: 'checklist-inicio',
        tipo: 'checklist',
        data_hora: dataHora,
        titulo: 'Checklist de Início concluído',
        descricao: `${checklistsConcluidos.length} checklist(s) · ${totalConformes}/${totalItens} itens conformes`,
        usuario: checklistsDetalhes[0]?.autor ?? 'Supervisor',
        foto_url: primeiraFotoUrl,
        extra: { checklists: checklistsDetalhes },
      })
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(ocorrs ?? []).forEach((o: any) => {
      tl.push({
        id: o.id,
        tipo: 'ocorrencia',
        data_hora: o.data_hora,
        titulo: `Ocorrência: ${o.tipo?.nome ?? 'Geral'}`,
        descricao: o.descricao,
        usuario: o.autor?.nome_completo ?? 'Operador',
      })
    })

    tl.sort((a, b) => new Date(b.data_hora).getTime() - new Date(a.data_hora).getTime())
    setTimeline(tl)

    // ── Paradas registradas ────────────────────────────────────────────────────
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const paradasFiltradas = (pts ?? []).filter((p: any) => {
      try { const parsed = JSON.parse(p.observacoes ?? ''); return parsed?.tipo && TIPOS_PARADA.some(t => t.value === parsed.tipo) } catch { return false }
    })

    // Coletar todos os foto_ids de todas as paradas para busca em lote
    const todosFotoIds: string[] = []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    paradasFiltradas.forEach((p: any) => {
      try {
        const parsed = JSON.parse(p.observacoes ?? '{}')
        if (parsed.foto_ids?.length) todosFotoIds.push(...parsed.foto_ids)
      } catch {}
    })

    // Buscar caminhos de todas as fotos em lote
    const fotoPathMap: Record<string, string> = {}
    if (todosFotoIds.length > 0) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data: fotosData } = await sb.from('fotos').select('id, caminho_arquivo').in('id', todosFotoIds)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      fotosData?.forEach((f: any) => { fotoPathMap[f.id] = f.caminho_arquivo })
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const paradasProcessadas: ParadaItem[] = paradasFiltradas.map((p: any) => {
      let tipoVal = 'parada_curta', tipoLbl = 'Parada', justificativa = ''
      const fotoIds: string[] = []
      try {
        const parsed = JSON.parse(p.observacoes ?? '{}')
        if (parsed.tipo) { tipoVal = parsed.tipo; tipoLbl = parsed.tipoLabel ?? tipoVal; justificativa = parsed.justificativa ?? ''; fotoIds.push(...(parsed.foto_ids ?? [])) }
      } catch { justificativa = p.observacoes ?? '' }
      const tp = TIPOS_PARADA.find(t => t.value === tipoVal)
      const viat = viatsNorm.find((v) => v.id === p.escolta_veiculo_id)
      const fotoUrls = fotoIds
        .map(fid => {
          const caminho = fotoPathMap[fid]
          if (!caminho) return null
          return supabase.storage.from('fotos').getPublicUrl(caminho).data.publicUrl
        })
        .filter((u): u is string => u !== null)
      if (fotoUrls.length === 0 && p.foto) fotoUrls.push(getFotoUrl(p.foto) as string)
      return {
        id: p.id,
        tipo: tipoVal,
        tipoLabel: tp?.label ?? tipoLbl,
        justificativa,
        data_hora: p.data_hora,
        latitude: p.latitude ?? null,
        longitude: p.longitude ?? null,
        fotoUrls,
        autor: p.autor?.nome_completo ?? 'Sistema',
        veiculo: viat?.veiculo?.placa ?? '—',
      }
    })
    setParadas(paradasProcessadas)
    setLoading(false)
  }, [id, sb, supabase])

  useEffect(() => { carregar() }, [carregar])

  // ── Countdown para próximo check-in ──────────────────────────────────────────
  useEffect(() => {
    if (!escolta?.periodicidade_checkin_min || !['em_andamento', 'na_origem', 'no_destino', 'retornando'].includes(escolta.status)) {
      setMinutosAteCheckin(null)
      return
    }
    const calcular = () => {
      const ultimoCheckin = paradas
        .filter(p => p.tipo === 'reporte_periodico')
        .sort((a, b) => new Date(b.data_hora).getTime() - new Date(a.data_hora).getTime())[0]
      const referencia = ultimoCheckin ? new Date(ultimoCheckin.data_hora) : new Date(escolta.data_hora_prevista)
      const diff = escolta.periodicidade_checkin_min! * 60 * 1000 - (Date.now() - referencia.getTime())
      setMinutosAteCheckin(Math.floor(diff / 60000))
    }
    calcular()
    const t = setInterval(calcular, 30000)
    return () => clearInterval(t)
  }, [escolta, paradas])

  // ── Avançar status ───────────────────────────────────────────────────────────
  const avancarStatus = async () => {
    if (!escolta) return
    const proximo = NEXT_STATUS[escolta.status]
    if (!proximo) return
    setAvancando(true)
    setErro(null)

    const { error } = await sb
      .from('escoltas')
      .update({ status: proximo.status })
      .eq('id', escolta.id)

    if (error) {
      setErro(error.message ?? 'Erro ao avançar status.')
      setAvancando(false)
      return
    }

    await sb.from('escolta_status_historico').insert({
      escolta_id: escolta.id,
      status_anterior: escolta.status,
      status_novo: proximo.status,
      observacao: motivoAvanco.trim() || null,
      alterado_por: user?.id ?? null,
    })

    setDialogAvanco(false)
    setMotivoAvanco('')
    setAvancando(false)
    carregar()
  }

  // ── Designar Responsável (sem efeito — coluna removida do schema) ──────────
  const handleDesignar = async (_usuarioId: string) => {
    setDesignando(true)
    try {
      carregar()
    } finally {
      setDesignando(false)
    }
  }

  // ── Submeter Wizard de Inicialização ─────────────────────────────────────────
  const handleWizardSubmit = async () => {
    if (!escolta || viaturas.length === 0) return
    if (!fotoMateriais) {
      setErro('A foto dos materiais e equipamentos é obrigatória no Passo 1.')
      return
    }
    if (!obsMateriais.trim()) {
      setErro('A observação do checklist de materiais é obrigatória no Passo 1.')
      return
    }
    const fotosFaltando = FOTOS_VIATURA_DEF.filter(f => !fotosViatura[f.key])
    if (fotosFaltando.length > 0) {
      setErro(`Fotos obrigatórias da viatura: ${fotosFaltando.map(f => f.label).join(', ')}.`)
      return
    }
    if (!obsViatura.trim()) {
      setErro('As observações do checklist de viatura são obrigatórias no Passo 2.')
      return
    }
    if (!fotoPartida) {
      setErro('A foto do hodômetro/saída é obrigatória no Passo 3.')
      return
    }
    if (!kmPartida) {
      setErro('O KM de partida é obrigatório no Passo 3.')
      return
    }
    if (!obsPartida.trim()) {
      setErro('As observações de partida são obrigatórias no Passo 3.')
      return
    }

    setLoading(true)
    setErro(null)
    try {
      const { lat, lng, precisao } = await obterGPS()

      // 1. Upload Fotos
      const fotoMatId = await uploadFoto(fotoMateriais, 'wizard_materiais', lat, lng, precisao, TIPO_FOTO_IDS.CHECKLIST_MATERIAL)
      const fotoPartId = await uploadFoto(fotoPartida, 'wizard_partida', lat, lng, precisao)

      // Upload das 5 fotos obrigatórias da viatura
      const fotosViaturaIds: Record<string, string | null> = {}
      for (const def of FOTOS_VIATURA_DEF) {
        const file = fotosViatura[def.key]
        if (file) {
          fotosViaturaIds[def.key] = await uploadFoto(file, `wizard_viatura_${def.key}`, lat, lng, precisao, def.tipoId)
        }
      }

      // 2. Salvar Checklist Materiais
      const { data: clMat, error: clMatErr } = await sb.from('checklists').insert({
        escolta_veiculo_id: viaturas[0].id,
        modelo_id: null,
        tipo: 'material',
        concluido: true,
        data_conclusao: new Date().toISOString(),
        responsavel_id: user?.id,
        sincronizado: true,
      }).select('id').single()
      if (clMatErr) throw new Error(clMatErr.message)

      const itensMat = [
        { key: 'coletes', label: 'Coletes balísticos (nível III-A) em conformidade' },
        { key: 'radios', label: 'Rádios comunicadores (HT) carregados' },
        { key: 'lanternas', label: 'Lanternas táticas e baterias sobressalentes' }
      ]
      for (const item of itensMat) {
        await sb.from('checklist_respostas').insert({
          checklist_id: clMat.id,
          descricao_item: item.label,
          conforme: checkMateriais[item.key] || false,
          observacao: obsMateriais.trim(),
          foto_id: fotoMatId,
        })
      }

      // 3. Salvar Checklist Viatura
      const { data: clViat, error: clViatErr } = await sb.from('checklists').insert({
        escolta_veiculo_id: viaturas[0].id,
        modelo_id: null,
        tipo: 'viatura',
        concluido: true,
        data_conclusao: new Date().toISOString(),
        responsavel_id: user?.id,
        sincronizado: true,
      }).select('id').single()
      if (clViatErr) throw new Error(clViatErr.message)

      // Inserir respostas do checklist viatura — cada item leva a foto correspondente (se houver)
      const fotoKeyPorItem: Record<string, string> = {
        pneus: 'lat_esq', oleo: 'painel', farois: 'frente',
        armamentos: 'painel', combustivel: 'painel', cintos: 'painel',
        documentacao: 'painel', limpeza: 'traseira',
      }
      for (const item of ITENS_CHECKLIST_VIATURA) {
        const fotoKey = fotoKeyPorItem[item.key] ?? 'frente'
        await sb.from('checklist_respostas').insert({
          checklist_id: clViat.id,
          descricao_item: item.label,
          conforme: checkViatura[item.key] || false,
          observacao: obsViatura.trim(),
          foto_id: fotosViaturaIds[fotoKey] ?? null,
        })
      }
      // Inserir uma resposta para cada foto tirada (registro fotográfico)
      for (const def of FOTOS_VIATURA_DEF) {
        if (fotosViaturaIds[def.key]) {
          await sb.from('checklist_respostas').insert({
            checklist_id: clViat.id,
            descricao_item: `Foto obrigatória — ${def.label}`,
            conforme: true,
            observacao: null,
            foto_id: fotosViaturaIds[def.key],
          })
        }
      }

      // 4. Atualizar KM saída da viatura
      await sb.from('escolta_veiculos')
        .update({ quilometragem_saida: Number(kmPartida) })
        .eq('id', viaturas[0].id)

      // 5. Atualizar status escolta
      await sb.from('escoltas')
        .update({ status: 'em_andamento' })
        .eq('id', escolta.id)

      // 6. Registrar Ponto de Controle (Saída)
      await sb.from('pontos_controle').insert({
        escolta_veiculo_id: viaturas[0].id,
        tipo_ponto_id: TIPO_PONTO_IDS.BASE_SAIDA,
        data_hora: new Date().toISOString(),
        latitude: lat,
        longitude: lng,
        precisao_metros: precisao,
        foto_id: fotoPartId,
        lancado_por: user?.id ?? null,
        observacoes: obsPartida.trim(),
        sincronizado: true,
      })

      // 7. Histórico de status
      await sb.from('escolta_status_historico').insert({
        escolta_id: escolta.id,
        status_anterior: escolta.status,
        status_novo: 'em_andamento',
        observacao: obsPartida.trim(),
        alterado_por: user?.id ?? null,
      })

      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao salvar checklists de partida.')
      setLoading(false)
    }
  }

  // ── Cancelar escolta ─────────────────────────────────────────────────────────
  const cancelarEscolta = async () => {
    if (!motivoCancelamento.trim()) { setErro('Informe o motivo do cancelamento.'); return }
    setCancelando(true)
    setErro(null)
    try {
      const { error } = await sb
        .from('escoltas')
        .update({ status: 'cancelada', observacao_fechamento: motivoCancelamento.trim() })
        .eq('id', escolta!.id)
      if (error) throw new Error(error.message)

      await sb.from('escolta_status_historico').insert({
        escolta_id: escolta!.id,
        status_anterior: escolta!.status,
        status_novo: 'cancelada',
        observacao: `Cancelamento: ${motivoCancelamento.trim()}`,
        alterado_por: user?.id ?? null,
      })

      setDialogCancelar(false)
      setMotivoCancelamento('')
      setAbaDialogCancelar('cancelar')
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao cancelar.')
    } finally {
      setCancelando(false)
    }
  }

  // ── Reagendar escolta ────────────────────────────────────────────────────────
  const reagendarEscolta = async () => {
    if (!motivoReagendamento.trim()) { setErro('Informe o motivo do reagendamento.'); return }
    if (!novaDataReagendamento) { setErro('Informe a nova data.'); return }
    setCancelando(true)
    setErro(null)
    try {
      const novaDataHora = new Date(`${novaDataReagendamento}T${novaHoraReagendamento}:00`).toISOString()

      const { error } = await sb
        .from('escoltas')
        .update({ status: 'agendada', data_hora_prevista: novaDataHora, observacao_fechamento: null })
        .eq('id', escolta!.id)
      if (error) throw new Error(error.message)

      await sb.from('escolta_status_historico').insert({
        escolta_id: escolta!.id,
        status_anterior: escolta!.status,
        status_novo: 'agendada',
        observacao: `Reagendamento para ${new Date(novaDataHora).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}. Motivo: ${motivoReagendamento.trim()}`,
        alterado_por: user?.id ?? null,
      })

      setDialogCancelar(false)
      setMotivoReagendamento('')
      setNovaDataReagendamento('')
      setNovaHoraReagendamento('08:00')
      setAbaDialogCancelar('cancelar')
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao reagendar.')
    } finally {
      setCancelando(false)
    }
  }

  // ── Obter GPS local com fallback ─────────────────────────────────────────────
  const obterGPS = async (): Promise<{ lat: number; lng: number; precisao: number }> => {
    return new Promise((resolve) => {
      if (!navigator.geolocation) {
        resolve({ lat: -19.916681, lng: -43.934493, precisao: 99 }) // Default: Belo Horizonte
        return
      }
      navigator.geolocation.getCurrentPosition(
        (pos) => resolve({
          lat: pos.coords.latitude,
          lng: pos.coords.longitude,
          precisao: pos.coords.accuracy,
        }),
        () => resolve({ lat: -19.916681, lng: -43.934493, precisao: 99 }),
        { enableHighAccuracy: true, timeout: 5000 }
      )
    })
  }

  // ── Upload de Foto ───────────────────────────────────────────────────────────
  const uploadFoto = async (file: File, prefix: string, lat: number, lng: number, prec: number, tipoFotoId: string = TIPO_FOTO_IDS.PONTO_CONTROLE) => {
    const ext = file.name.split('.').pop() ?? 'jpg'
    const path = `${prefix}/${escolta!.id}/${Date.now()}.${ext}`
    const { error: upErr } = await sb.storage.from('fotos').upload(path, file)
    if (upErr) throw new Error(`Erro no upload da foto: ${upErr.message}`)

    const { data: fotoInsert, error: dbErr } = await sb.from('fotos').insert({
      caminho_arquivo: path,
      tipo_foto_id: tipoFotoId,
      latitude: lat,
      longitude: lng,
      precisao_metros: prec,
      data_hora_captura: new Date().toISOString(),
      carimbo_aplicado: false,
      enviada_telegram: false,
      sincronizada: true,
      criado_por: user?.id ?? null,
    }).select('id').single()

    if (dbErr) throw new Error(`Erro ao salvar foto no BD: ${dbErr.message}`)
    return fotoInsert?.id ?? null
  }

  // ── 1. Iniciar Operação (Sair da Base) ────────────────────────────────────────
  const handleStartBase = async () => {
    if (!escolta) return
    setLoading(true)
    try {
      const { lat, lng, precisao } = await obterGPS()
      let fotoId: string | null = null

      if (fotoStartBase) {
        fotoId = await uploadFoto(fotoStartBase, 'partida', lat, lng, precisao)
      }

      // Atualizar status da escolta
      const { error: escErr } = await sb
        .from('escoltas')
        .update({ status: 'em_andamento' })
        .eq('id', escolta.id)
      if (escErr) throw new Error(escErr.message)

      // Atualizar KM de saída da viatura vinculada
      if (kmStartBase && viaturas.length > 0) {
        const { error: viatErr } = await sb
          .from('escolta_veiculos')
          .update({ quilometragem_saida: Number(kmStartBase) })
          .eq('id', viaturas[0].id)
        if (viatErr) throw new Error(viatErr.message)
      }

      // Registrar Ponto de Controle (Base de Saída)
      const { error: ptErr } = await sb.from('pontos_controle').insert({
        escolta_veiculo_id: viaturas[0]?.id,
        tipo_ponto_id: TIPO_PONTO_IDS.BASE_SAIDA,
        data_hora: new Date().toISOString(),
        latitude: lat,
        longitude: lng,
        precisao_metros: precisao,
        foto_id: fotoId,
        lancado_por: user?.id ?? null,
        observacoes: obsStartBase.trim() || 'Saída da base confirmada pelo operador.',
        sincronizado: true,
      })
      if (ptErr) throw new Error(ptErr.message)

      // Registrar Histórico de Status
      await sb.from('escolta_status_historico').insert({
        escolta_id: escolta.id,
        status_anterior: escolta.status,
        status_novo: 'em_andamento',
        observacao: obsStartBase.trim() || 'Saída da base confirmada.',
        alterado_por: user?.id ?? null,
      })

      setDialogStartBase(false)
      setFotoStartBase(null)
      setKmStartBase('')
      setObsStartBase('')
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao iniciar operação.')
      setLoading(false)
    }
  }

  // ── 2. Registrar Parada ──────────────────────────────────────────────────────
  const handleParada = async () => {
    if (!escolta || viaturas.length === 0) return
    if (!obsParada.trim()) { setErro('A justificativa é obrigatória.'); return }
    setLoading(true)
    try {
      const { lat, lng, precisao } = await obterGPS()
      const tipoInfo = TIPOS_PARADA.find(t => t.value === tipoParada)

      let fotoIdPrincipal: string | null = null
      const fotosIds: string[] = []
      for (const foto of fotosParada) {
        const fid = await uploadFoto(foto, 'parada', lat, lng, precisao)
        if (fid) { fotosIds.push(fid); if (!fotoIdPrincipal) fotoIdPrincipal = fid }
      }

      const observacoesJSON = JSON.stringify({
        tipo: tipoParada,
        tipoLabel: tipoInfo?.label ?? tipoParada,
        justificativa: obsParada.trim(),
        foto_ids: fotosIds,
      })

      const { error: ptErr } = await sb.from('pontos_controle').insert({
        escolta_veiculo_id: viaturas[0].id,
        tipo_ponto_id: TIPO_PONTO_IDS.PARADA,
        data_hora: new Date().toISOString(),
        latitude: lat,
        longitude: lng,
        precisao_metros: precisao,
        foto_id: fotoIdPrincipal,
        lancado_por: user?.id ?? null,
        observacoes: observacoesJSON,
        sincronizado: true,
      })
      if (ptErr) throw new Error(ptErr.message)

      notificarTelegram({
        titulo: `Parada em Rota — ${tipoInfo?.label ?? tipoParada}`,
        descricao: obsParada.trim(),
        fotoId: fotoIdPrincipal,
      })

      setDialogParada(false)
      setObsParada('')
      setFotosParada([])
      setTipoParada('parada_curta')
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao registrar parada.')
      setLoading(false)
    }
  }

  // ── Check-in Periódico ────────────────────────────────────────────────────────
  const reverseGeocode = async (lat: number, lng: number): Promise<string> => {
    try {
      const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN
      const res = await fetch(
        `https://api.mapbox.com/geocoding/v5/mapbox.places/${lng},${lat}.json?access_token=${token}&language=pt&types=address,neighborhood,place&limit=1`
      )
      const data = await res.json()
      return data.features?.[0]?.place_name ?? `${lat.toFixed(5)}, ${lng.toFixed(5)}`
    } catch {
      return `${lat.toFixed(5)}, ${lng.toFixed(5)}`
    }
  }

  const abrirDialogCheckin = async () => {
    setErro(null)
    setGpsCheckin(null)
    setFotoCheckin(null)
    setObsCheckin('')
    setDialogCheckin(true)
    setGpsCheckinLoading(true)
    try {
      const { lat, lng, precisao } = await obterGPS()
      const endereco = await reverseGeocode(lat, lng)
      setGpsCheckin({ lat, lng, precisao, endereco })
    } catch {
      // GPS falhou — usuário pode tentar novamente
    } finally {
      setGpsCheckinLoading(false)
    }
  }

  // ── Helper: notificar Telegram após qualquer check-in / status change ────────
  const notificarTelegram = async (params: {
    titulo: string
    tipo?: string
    descricao?: string
    status_atual?: string
    fotoId?: string | null
  }) => {
    try {
      let fotoUrl: string | null = null
      if (params.fotoId) {
        const { data: f } = await sb.from('fotos').select('caminho_arquivo').eq('id', params.fotoId).maybeSingle()
        if (f?.caminho_arquivo) {
          const { data: pub } = sb.storage.from('fotos').getPublicUrl(f.caminho_arquivo)
          fotoUrl = pub?.publicUrl ?? null
        }
      }
      const viatIds = viaturas.map(v => v.id)
      const { data: efetivosData } = viatIds.length > 0
        ? await sb
            .from('escolta_efetivo')
            .select('papel_na_escolta, vigilante:vigilantes(nome_completo)')
            .in('escolta_veiculo_id', viatIds)
        : { data: [] }
      const efetivos: string[] = (efetivosData ?? []).map((e: any) =>
        `${e.vigilante?.nome_completo ?? '—'}${e.papel_na_escolta ? ` (${e.papel_na_escolta})` : ''}`
      )
      const dataHora = new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })
      fetch('/api/telegram', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          tipo: params.tipo ?? 'ponto_controle',
          titulo: params.titulo,
          descricao: params.descricao,
          escolta_id: escolta!.id,
          escolta_codigo: escolta!.codigo_escolta,
          cliente: escolta!.cliente?.nome_cliente,
          status_atual: params.status_atual ?? escolta!.status,
          efetivos,
          veiculo: viaturas[0]?.veiculo?.placa ?? null,
          foto_url: fotoUrl,
          data_hora: dataHora,
        }),
      }).catch(() => {})
    } catch { /* fire-and-forget */ }
  }

  const salvarPeriodicidade = async () => {
    if (!escolta) return
    const mins = periodicidadeEdit === '' ? null : Number(periodicidadeEdit)
    await sb.from('escoltas').update({ periodicidade_checkin_min: mins }).eq('id', escolta.id)
    setEditandoPeriodicidade(false)
    carregar()
  }

  const handleCheckin = async () => {
    if (!escolta || viaturas.length === 0) return
    if (!fotoCheckin) { setErro('A foto é obrigatória para o check-in.'); return }
    if (!gpsCheckin) { setErro('Aguardando localização GPS. Tente novamente.'); return }
    setLoading(true)
    try {
      const fotoId = await uploadFoto(fotoCheckin, 'checkin', gpsCheckin.lat, gpsCheckin.lng, gpsCheckin.precisao)

      const observacoesJSON = JSON.stringify({
        tipo: 'reporte_periodico',
        tipoLabel: 'Reporte Periódico',
        endereco: gpsCheckin.endereco,
        latitude: gpsCheckin.lat,
        longitude: gpsCheckin.lng,
        precisao_metros: gpsCheckin.precisao,
        observacao: obsCheckin.trim(),
        foto_ids: fotoId ? [fotoId] : [],
      })

      const { error } = await sb.from('pontos_controle').insert({
        escolta_veiculo_id: viaturas[0].id,
        tipo_ponto_id: TIPO_PONTO_IDS.PARADA,
        data_hora: new Date().toISOString(),
        latitude: gpsCheckin.lat,
        longitude: gpsCheckin.lng,
        precisao_metros: gpsCheckin.precisao,
        foto_id: fotoId,
        lancado_por: user?.id ?? null,
        observacoes: observacoesJSON,
        sincronizado: true,
      })
      if (error) throw new Error(error.message)

      notificarTelegram({
        titulo: 'Check-in Periódico',
        descricao: [obsCheckin.trim(), gpsCheckin?.endereco].filter(Boolean).join(' · '),
        status_atual: escolta.status === 'na_origem' ? 'Na Origem' : escolta.status === 'no_destino' ? 'No Destino' : 'Em Rota',
        fotoId,
      })

      setDialogCheckin(false)
      setFotoCheckin(null)
      setObsCheckin('')
      setGpsCheckin(null)
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao registrar check-in.')
      setLoading(false)
    }
  }

  // ── 3. Chegar na Origem ──────────────────────────────────────────────────────
  const handleChegadaOrigem = async () => {
    if (!escolta) return
    setLoading(true)
    try {
      const { lat, lng, precisao } = await obterGPS()
      let fotoId: string | null = null

      if (fotoOrigem) {
        fotoId = await uploadFoto(fotoOrigem, 'origem', lat, lng, precisao)
      }

      // Atualizar status
      const { error: escErr } = await sb
        .from('escoltas')
        .update({ status: 'na_origem' })
        .eq('id', escolta.id)
      if (escErr) throw new Error(escErr.message)

      // Registrar Ponto de Controle (Origem/Chegada)
      const { error: ptErr } = await sb.from('pontos_controle').insert({
        escolta_veiculo_id: viaturas[0]?.id,
        tipo_ponto_id: TIPO_PONTO_IDS.ORIGEM,
        data_hora: new Date().toISOString(),
        latitude: lat,
        longitude: lng,
        precisao_metros: precisao,
        foto_id: fotoId,
        lancado_por: user?.id ?? null,
        observacoes: `Chegada na origem confirmada. ${opcoesOrigem.join(', ')}. Obs: ${obsOrigem}`,
        sincronizado: true,
      })
      if (ptErr) throw new Error(ptErr.message)

      // Registrar Histórico
      await sb.from('escolta_status_historico').insert({
        escolta_id: escolta.id,
        status_anterior: escolta.status,
        status_novo: 'na_origem',
        observacao: `Chegada na origem confirmada. ${opcoesOrigem.join(', ')}`,
        alterado_por: user?.id ?? null,
      })

      notificarTelegram({ titulo: 'Chegada na Origem', status_atual: 'Na Origem', fotoId, descricao: obsOrigem.trim() || undefined })

      setDialogChegadaOrigem(false)
      setFotoOrigem(null)
      setObsOrigem('')
      setOpcoesOrigem([])
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao registrar chegada.')
      setLoading(false)
    }
  }

  // ── 4. Chegar no Destino ─────────────────────────────────────────────────────
  const handleChegadaDestino = async () => {
    if (!escolta) return
    setLoading(true)
    try {
      const { lat, lng, precisao } = await obterGPS()
      let fotoId: string | null = null

      if (fotoDestino) {
        fotoId = await uploadFoto(fotoDestino, 'destino', lat, lng, precisao)
      }

      // Atualizar status
      const { error: escErr } = await sb
        .from('escoltas')
        .update({ status: 'no_destino' })
        .eq('id', escolta.id)
      if (escErr) throw new Error(escErr.message)

      // Registrar Ponto de Controle
      const { error: ptErr } = await sb.from('pontos_controle').insert({
        escolta_veiculo_id: viaturas[0]?.id,
        tipo_ponto_id: TIPO_PONTO_IDS.DESTINO,
        data_hora: new Date().toISOString(),
        latitude: lat,
        longitude: lng,
        precisao_metros: precisao,
        foto_id: fotoId,
        lancado_por: user?.id ?? null,
        observacoes: `Chegada no destino confirmada. Obs: ${obsDestino}`,
        sincronizado: true,
      })
      if (ptErr) throw new Error(ptErr.message)

      // Registrar Histórico
      await sb.from('escolta_status_historico').insert({
        escolta_id: escolta.id,
        status_anterior: escolta.status,
        status_novo: 'no_destino',
        observacao: `Chegada no destino confirmada.`,
        alterado_por: user?.id ?? null,
      })

      notificarTelegram({ titulo: 'Chegada no Destino', status_atual: 'No Destino', fotoId, descricao: obsDestino.trim() || undefined })

      setDialogChegadaDestino(false)
      setFotoDestino(null)
      setObsDestino('')
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao registrar chegada ao destino.')
      setLoading(false)
    }
  }

  // ── 5. Iniciar Retorno ───────────────────────────────────────────────────────
  const handleIniciarRetorno = async () => {
    if (!escolta) return
    setLoading(true)
    try {
      const { lat, lng, precisao } = await obterGPS()

      // Atualizar status
      const { error: escErr } = await sb
        .from('escoltas')
        .update({ status: 'retornando' })
        .eq('id', escolta.id)
      if (escErr) throw new Error(escErr.message)

      // Registrar Ponto de Controle
      const { error: ptErr } = await sb.from('pontos_controle').insert({
        escolta_veiculo_id: viaturas[0]?.id,
        tipo_ponto_id: TIPO_PONTO_IDS.BASE_RETORNO,
        data_hora: new Date().toISOString(),
        latitude: lat,
        longitude: lng,
        precisao_metros: precisao,
        lancado_por: user?.id ?? null,
        observacoes: `Retorno iniciado. Obs: ${obsRetorno}`,
        sincronizado: true,
      })
      if (ptErr) throw new Error(ptErr.message)

      // Registrar Histórico
      await sb.from('escolta_status_historico').insert({
        escolta_id: escolta.id,
        status_anterior: escolta.status,
        status_novo: 'retornando',
        observacao: `Retorno iniciado.`,
        alterado_por: user?.id ?? null,
      })

      notificarTelegram({ titulo: 'Retorno Iniciado', status_atual: 'Em Retorno', descricao: obsRetorno.trim() || undefined })

      setDialogIniciarRetorno(false)
      setObsRetorno('')
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao iniciar retorno.')
      setLoading(false)
    }
  }

  // ── 6. Chegada na Base ───────────────────────────────────────────────────────
  const handleChegadaBase = async () => {
    if (!escolta) return

    if (kmChegadaBase && viaturas.length > 0) {
      const kmRetorno = Number(kmChegadaBase)
      const kmSaida = viaturas[0].quilometragem_saida ?? 0
      if (kmRetorno < kmSaida) {
        setErro(`KM de chegada (${kmRetorno.toLocaleString('pt-BR')}) não pode ser menor que o KM de saída (${kmSaida.toLocaleString('pt-BR')}).`)
        return
      }
    }

    setLoading(true)
    try {
      const { lat, lng, precisao } = await obterGPS()

      // Atualizar status
      const { error: escErr } = await sb
        .from('escoltas')
        .update({ status: 'na_base' })
        .eq('id', escolta.id)
      if (escErr) throw new Error(escErr.message)

      // Atualizar KM de retorno
      if (kmChegadaBase && viaturas.length > 0) {
        const { error: viatErr } = await sb
          .from('escolta_veiculos')
          .update({ quilometragem_retorno: Number(kmChegadaBase) })
          .eq('id', viaturas[0].id)
        if (viatErr) throw new Error(viatErr.message)
      }

      // Registrar Ponto de Controle
      const { error: ptErr } = await sb.from('pontos_controle').insert({
        escolta_veiculo_id: viaturas[0]?.id,
        tipo_ponto_id: TIPO_PONTO_IDS.BASE_RETORNO,
        data_hora: new Date().toISOString(),
        latitude: lat,
        longitude: lng,
        precisao_metros: precisao,
        lancado_por: user?.id ?? null,
        observacoes: `Chegada na base confirmada. Obs: ${obsChegadaBase}`,
        sincronizado: true,
      })
      if (ptErr) throw new Error(ptErr.message)

      // Registrar Histórico
      await sb.from('escolta_status_historico').insert({
        escolta_id: escolta.id,
        status_anterior: escolta.status,
        status_novo: 'na_base',
        observacao: `Chegada na base confirmada.`,
        alterado_por: user?.id ?? null,
      })

      notificarTelegram({ titulo: 'Chegada na Base', status_atual: 'Na Base', descricao: obsChegadaBase.trim() || undefined })

      setDialogChegadaBase(false)
      setKmChegadaBase('')
      setObsChegadaBase('')
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao registrar chegada na base.')
      setLoading(false)
    }
  }

  // ── 7. Finalização com Checklist e Relatório Diário ──────────────────────────

  const enviarRelatorioFinalTelegram = async () => {
    try {
      // Efetivos já carregados no estado — apenas quem foi escalado para esta escolta
      const efetivos: string[] = viaturas
        .flatMap(v => v.efetivo)
        .map(e => `${e.vigilante?.nome_completo ?? '—'}${e.papel_na_escolta ? ` (${e.papel_na_escolta})` : ''}`)

      // Última foto de qualquer ponto de controle (mais recente)
      const ultimaFotoUrl = [...paradas]
        .sort((a, b) => new Date(b.data_hora).getTime() - new Date(a.data_hora).getTime())
        .find(p => p.fotoUrls.length > 0)
        ?.fotoUrls[0] ?? null

      // Duração: desde o primeiro status em_andamento
      const inicioAndamento = [...historico]
        .sort((a, b) => new Date(a.data_hora).getTime() - new Date(b.data_hora).getTime())
        .find(h => h.status_novo === 'em_andamento')
      const duracaoStr = inicioAndamento ? calcDuracao(inicioAndamento.data_hora) : null

      // KM percorrido
      const kmSaida = viaturas[0]?.quilometragem_saida
      const kmRetorno = viaturas[0]?.quilometragem_retorno
      const kmPercorrido = (kmSaida != null && kmRetorno != null) ? kmRetorno - kmSaida : null

      // Escape HTML para texto do usuário
      const esc = (s: string) =>
        (s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

      const fmt = (iso: string) =>
        new Date(iso).toLocaleString('pt-BR', {
          timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit',
          hour: '2-digit', minute: '2-digit',
        })

      // Linha do tempo completa a partir da timeline
      const eventos = [...timeline]
        .filter(t => t.tipo !== 'presenca')
        .sort((a, b) => new Date(a.data_hora).getTime() - new Date(b.data_hora).getTime())
        .map(t => {
          let label = ''
          if (t.tipo === 'status') {
            const match = t.titulo.match(/→\s*(.+)/)
            label = match ? match[1].trim() : esc(t.titulo)
          } else if (t.tipo === 'ocorrencia') {
            label = `⚠️ ${esc(t.titulo)}`
          } else {
            label = esc(t.titulo)
          }
          const obs = t.descricao ? ` — <i>${esc(t.descricao.slice(0, 80))}</i>` : ''
          return `  • ${fmt(t.data_hora)} — ${label}${obs}`
        })

      // Adicionar evento de finalização (ainda não está na timeline)
      const agora = new Date()
      eventos.push(`  • ${fmt(agora.toISOString())} — Escolta Finalizada`)

      const dataHoraFim = agora.toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })
      const appUrl = process.env.NEXT_PUBLIC_APP_URL ?? ''

      // Montar mensagem executiva
      let texto = `✅ <b>ESCOLTA FINALIZADA</b>\n\n`
      if (escolta!.codigo_escolta) texto += `🔖 <b>Escolta:</b> <code>${esc(escolta!.codigo_escolta)}</code>\n`
      if (escolta!.cliente?.nome_cliente) texto += `🏢 <b>Cliente:</b> ${esc(escolta!.cliente.nome_cliente)}\n`
      texto += `🏁 <b>Finalização:</b> ${dataHoraFim}\n`
      if (duracaoStr) texto += `⏱ <b>Duração total:</b> ${duracaoStr}\n`
      if (kmPercorrido != null) texto += `📏 <b>KM percorrido:</b> ${kmPercorrido.toLocaleString('pt-BR')} km\n`
      if (escolta!.origem_endereco && escolta!.destino_endereco) {
        texto += `📍 <b>Rota:</b> ${esc(escolta!.origem_endereco.split(',')[0])} → ${esc(escolta!.destino_endereco.split(',')[0])}\n`
      }

      if (efetivos.length > 0) {
        texto += `\n👥 <b>Efetivos (${efetivos.length}):</b>\n`
        for (const e of efetivos) texto += `  • ${esc(e)}\n`
      }

      if (eventos.length > 0) {
        texto += `\n📋 <b>Linha do Tempo (${eventos.length} eventos):</b>\n`
        for (const ev of eventos) texto += `${ev}\n`
      }

      const numOcorr = ocorrencias.length
      texto += `\n${numOcorr > 0
        ? `⚠️ <b>Ocorrências registradas: ${numOcorr}</b>`
        : `✅ <b>Sem ocorrências registradas</b>`
      }\n`

      if (relatorioFinal.trim()) {
        texto += `\n📝 <b>Relatório Final:</b>\n<i>${esc(relatorioFinal.trim().slice(0, 600))}</i>\n`
      }

      if (appUrl && escolta!.id) {
        texto += `\n🔗 <a href="${appUrl}/dashboard/escoltas/${escolta!.id}">Abrir Escolta ${esc(escolta!.codigo_escolta ?? '')}</a>`
      }

      // Respeitar limite de 4096 chars do Telegram
      if (texto.length > 4000) {
        texto = texto.slice(0, 3990) + '\n<i>…(mensagem truncada)</i>'
      }

      fetch('/api/telegram', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          tipo: 'finalizacao',
          titulo: `Escolta Finalizada`,
          texto_completo: texto,
          escolta_id: escolta!.id,
          escolta_codigo: escolta!.codigo_escolta,
          foto_url: ultimaFotoUrl,
          data_hora: dataHoraFim,
        }),
      }).catch(() => {})
    } catch { /* fire-and-forget */ }
  }

  const handleFinalizacao = async () => {
    if (!escolta || viaturas.length === 0) return

    const fotosFaltando = FOTOS_VIATURA_DEF.filter(f => !fotosViaturaFinal[f.key])
    if (fotosFaltando.length > 0) {
      setErro(`Fotos obrigatórias da viatura: ${fotosFaltando.map(f => f.label).join(', ')}.`)
      return
    }
    if (!relatorioFinal.trim()) {
      setErro('O relatório diário é obrigatório para finalizar a escolta.')
      return
    }
    setLoading(true)
    try {
      const { lat, lng, precisao } = await obterGPS()

      // Upload das 5 fotos obrigatórias da viatura (entrega)
      const fotosViatFinalIds: Record<string, string | null> = {}
      for (const def of FOTOS_VIATURA_DEF) {
        const file = fotosViaturaFinal[def.key]
        if (file) {
          fotosViatFinalIds[def.key] = await uploadFoto(file, `final_viatura_${def.key}`, lat, lng, precisao, def.tipoId)
        }
      }

      // 1. Criar registro de checklist de entrega de viatura
      const { data: cl, error: clErr } = await sb.from('checklists').insert({
        escolta_veiculo_id: viaturas[0].id,
        modelo_id: null,
        tipo: 'viatura',
        concluido: true,
        data_conclusao: new Date().toISOString(),
        responsavel_id: user?.id,
        sincronizado: true,
      }).select('id').single()
      if (clErr) throw new Error(clErr.message)

      if (cl) {
        const fotoKeyPorItemFinal: Record<string, string> = {
          pneus: 'lat_esq', oleo_agua: 'painel', farois: 'frente',
          armamentos: 'painel', limpeza: 'traseira',
        }
        const itensChecklist = [
          { key: 'pneus',       label: 'Pneus e estepe calibrados?' },
          { key: 'oleo_agua',   label: 'Nível de óleo e água?' },
          { key: 'farois',      label: 'Faróis e sirene funcionando?' },
          { key: 'armamentos',  label: 'Armamentos e munições conferidos?' },
          { key: 'limpeza',     label: 'Limpeza e conservação geral?' },
        ]

        for (const item of itensChecklist) {
          const resp = checklistFinal[item.key]
          const fotoKey = fotoKeyPorItemFinal[item.key] ?? 'frente'
          await sb.from('checklist_respostas').insert({
            checklist_id: cl.id,
            descricao_item: item.label,
            conforme: resp?.resposta ?? true,
            observacao: resp?.obs?.trim() || null,
            foto_id: fotosViatFinalIds[fotoKey] ?? null,
          })
        }

        // Registro fotográfico dos 5 ângulos
        for (const def of FOTOS_VIATURA_DEF) {
          if (fotosViatFinalIds[def.key]) {
            await sb.from('checklist_respostas').insert({
              checklist_id: cl.id,
              descricao_item: `Foto entrega — ${def.label}`,
              conforme: true,
              observacao: null,
              foto_id: fotosViatFinalIds[def.key],
            })
          }
        }
      }

      // 2. Atualizar status da escolta para finalizada
      const { error: escErr } = await sb
        .from('escoltas')
        .update({
          status: 'finalizada',
          observacao_fechamento: relatorioFinal.trim(),
          data_finalizacao: new Date().toISOString()
        })
        .eq('id', escolta.id)
      if (escErr) throw new Error(escErr.message)

      // 3. Registrar Histórico de Status
      await sb.from('escolta_status_historico').insert({
        escolta_id: escolta.id,
        status_anterior: escolta.status,
        status_novo: 'finalizada',
        observacao: `Escolta finalizada. Relatório gerado pelo supervisor.`,
        alterado_por: user?.id ?? null,
      })

      // 4. Enviar relatório executivo completo ao Telegram
      enviarRelatorioFinalTelegram()

      setDialogFinalizacao(false)
      setRelatorioFinal('')
      setFotosViaturaFinal(Object.fromEntries(FOTOS_VIATURA_DEF.map(f => [f.key, null])))
      carregar()
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Erro ao finalizar escolta.')
      setLoading(false)
    }
  }

  if (!escolta) {
    return (
      <div className="card-light p-12 text-center">
        <AlertCircle size={32} className="mx-auto mb-3" style={{ color: '#C8D5DC' }} />
        <p className="font-semibold" style={{ color: '#1E2D35' }}>Escolta não encontrada</p>
        {erro && <p className="text-xs mt-1" style={{ color: '#B83832' }}>{erro}</p>}
        <button onClick={() => router.back()} className="btn-outline mt-5">
          <ArrowLeft size={14} /> Voltar
        </button>
      </div>
    )
  }

  const perfil = (user?.perfil?.codigo ?? '') as any
  const isSupervisorOrOperador = ['supervisor', 'operador'].includes(perfil)
  const isUnstarted = ['rascunho', 'agendada', 'em_pre_inicio'].includes(escolta.status)


  const si = STATUS_INFO[escolta.status] ?? { label: escolta.status, cls: 'badge-neutral' }
  const proximo = NEXT_STATUS[escolta.status]
  const cor = escolta.cliente?.cor_destaque ?? '#53648A'
  const etapaAtual = JORNADA_ETAPAS.findIndex((e) => e.statuses.includes(escolta.status))
  const totalEfetivo = viaturas.reduce((acc, v) => acc + v.efetivo.length, 0)
  const isFinalizado = ['finalizada', 'cancelada'].includes(escolta.status)

  const verFinanceiroDet = PERFIS_FINANCEIRO_DET.includes((user?.perfil?.codigo ?? '') as any)

  const TABS: { key: Tab; label: string; count?: number }[] = [
    { key: 'geral',       label: 'Visão Geral' },
    { key: 'timeline',    label: 'Timeline',    count: timeline.length },
    { key: 'efetivo',     label: 'Efetivo',     count: totalEfetivo },
    { key: 'veiculos',    label: 'Veículos',    count: viaturas.length },
    { key: 'ocorrencias', label: 'Ocorrências', count: ocorrencias.length },
    ...(verFinanceiroDet ? [{ key: 'financeiro' as Tab, label: '💰 Financeiro' }] : []),
  ]

  // ── Renderização do Wizard Guiado de Partida (Checklist) ─────────────────────
  const renderGuidedWizard = () => {
    return (
      <div className="space-y-6 max-w-xl mx-auto py-4">
        {/* Progress Timeline */}
        <div className="card-light p-5">
          <div className="flex justify-between items-center mb-6">
            <h2 className="font-black text-sm text-[#0E1A33] uppercase tracking-wide">
              Preparação Operacional de Partida
            </h2>
            <span className="text-[10px] uppercase font-bold tracking-wider text-amber-500 bg-amber-500/10 px-2.5 py-1 rounded">
              Passo {wizardStep} de 3
            </span>
          </div>

          <div className="flex items-center justify-between relative px-2">
            <div className="absolute left-6 right-6 top-5 h-0.5 bg-[#D6DAE5] z-0" />
            <div className="absolute left-6 top-5 h-0.5 bg-[#53648A] transition-all z-0" style={{ width: `${(wizardStep - 1) * 50}%` }} />
            
            {[
              { step: 1, label: 'Equipamentos' },
              { step: 2, label: 'Viatura' },
              { step: 3, label: 'Saída' }
            ].map((s) => (
              <div key={s.step} className="flex flex-col items-center gap-1 z-10">
                <div className={`w-10 h-10 rounded flex items-center justify-center font-bold border transition-all text-xs ${
                  wizardStep === s.step
                    ? 'bg-[#53648A] text-white border-[#53648A] shadow-md scale-105'
                    : wizardStep > s.step
                    ? 'bg-emerald-500 text-white border-emerald-500'
                    : 'bg-white text-slate-400 border-slate-200'
                }`}>
                  {wizardStep > s.step ? <CheckCircle2 size={16} /> : s.step}
                </div>
                <span className={`text-[10px] font-bold uppercase tracking-wider ${
                  wizardStep === s.step ? 'text-[#53648A]' : 'text-[#5A6A80]'
                }`}>{s.label}</span>
              </div>
            ))}
          </div>
        </div>

        {/* Wizard content */}
        <div className="card-light p-6 space-y-5">
          {erro && (
            <p className="text-xs p-3 rounded" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
          )}

          {/* STEP 1: MATERIAIS */}
          {wizardStep === 1 && (
            <div className="space-y-4">
              <h3 className="font-bold text-xs text-[#53648A] uppercase tracking-wider">Passo 1: Checklist de Equipamentos e Materiais</h3>
              
              <div className="space-y-2">
                {[
                  { key: 'coletes', label: 'Coletes balísticos (nível III-A) em conformidade' },
                  { key: 'radios', label: 'Rádios comunicadores (HT) operacionais' },
                  { key: 'lanternas', label: 'Lanternas táticas com baterias carregadas' }
                ].map((item) => (
                  <label key={item.key} className="flex items-start gap-3 p-3 bg-[#F5F7FA] rounded cursor-pointer hover:bg-[#D6DAE5]/70 border border-[#D6DAE5] transition-colors">
                    <input
                      type="checkbox"
                      checked={checkMateriais[item.key]}
                      onChange={(e) => setCheckMateriais({ ...checkMateriais, [item.key]: e.target.checked })}
                      className="rounded mt-0.5 text-[#53648A] focus:ring-[#53648A] border-slate-300"
                    />
                    <div>
                      <span className="text-xs font-semibold text-[#0E1A33]">{item.label}</span>
                    </div>
                  </label>
                ))}
              </div>

              <div>
                <label className="block text-xs font-bold mb-1.5 text-[#5A6A80] uppercase tracking-wide">
                  Foto dos Materiais / Equipamentos * (Use a Câmera)
                </label>
                <CameraInput onChange={(fs) => setFotoMateriais(fs[0] ?? null)} />
              </div>

              <div>
                <label className="block text-xs font-bold mb-1.5 text-[#5A6A80] uppercase tracking-wide">
                  Observações / Justificativas *
                </label>
                <TextAreaWithTools
                  value={obsMateriais}
                  onChange={(v) => setObsMateriais(v)}
                  placeholder="Relatório de entrega e conformidade dos materiais..."
                  rows={3}
                  textareaClassName="input-light resize-none text-xs"
                  contextoAI="Relatório de entrega e conformidade de materiais de escolta armada"
                />
              </div>

              <div className="flex justify-end pt-3 border-t">
                <button
                  type="button"
                  onClick={() => {
                    if (!fotoMateriais) { setErro('A foto dos materiais é obrigatória.'); return }
                    if (!obsMateriais.trim()) { setErro('As observações são obrigatórias.'); return }
                    setErro(null)
                    setWizardStep(2)
                  }}
                  className="btn-gradient px-6"
                >
                  Avançar Passo
                </button>
              </div>
            </div>
          )}

          {/* STEP 2: VIATURA */}
          {wizardStep === 2 && (
            <div className="space-y-5">
              <div>
                <h3 className="font-bold text-xs text-[#53648A] uppercase tracking-wider">Passo 2: Checklist do Veículo (VTR)</h3>
                <p className="text-[11px] mt-1" style={{ color: '#7A8FA6' }}>
                  Fotografe a viatura em <strong>5 ângulos obrigatórios</strong> e marque todos os itens do checklist. A viatura só é liberada para saída após a conclusão completa deste passo.
                </p>
              </div>

              {/* 5 Fotos obrigatórias */}
              <div>
                <div className="flex items-center gap-2 mb-3 pb-2" style={{ borderBottom: '1px solid #EEF1F7' }}>
                  <div style={{ width: '3px', height: '14px', backgroundColor: '#1A294A' }} />
                  <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: '#1A294A' }}>Registro Fotográfico Obrigatório</span>
                </div>
                <div className="grid grid-cols-1 gap-4">
                  {FOTOS_VIATURA_DEF.map((def) => {
                    const temFoto = !!fotosViatura[def.key]
                    return (
                      <div key={def.key} style={{ border: `1.5px solid ${temFoto ? '#1E7C52' : '#D6DAE5'}`, padding: '12px', backgroundColor: temFoto ? 'rgba(30,124,82,0.04)' : '#F8FAFC' }}>
                        <div className="flex items-center gap-2 mb-2">
                          {temFoto
                            ? <CheckCircle2 size={14} style={{ color: '#1E7C52', flexShrink: 0 }} />
                            : <Camera size={14} style={{ color: '#B83832', flexShrink: 0 }} />
                          }
                          <span className="text-xs font-black uppercase tracking-wide" style={{ color: temFoto ? '#1E7C52' : '#B83832' }}>
                            {def.label} {temFoto ? '— Registrada' : '— Obrigatória *'}
                          </span>
                        </div>
                        <CameraInput
                          prefixoNome={`vtr_${def.key}`}
                          onChange={(fs) => setFotosViatura(prev => ({ ...prev, [def.key]: fs[0] ?? null }))}
                        />
                      </div>
                    )
                  })}
                </div>
                <div className="flex items-center gap-2 mt-2 px-1">
                  <div style={{ width: '8px', height: '8px', flexShrink: 0, backgroundColor: fotosViatura && FOTOS_VIATURA_DEF.every(f => fotosViatura[f.key]) ? '#1E7C52' : '#B83832' }} />
                  <span className="text-[10px] font-bold" style={{ color: FOTOS_VIATURA_DEF.every(f => fotosViatura[f.key]) ? '#1E7C52' : '#B83832' }}>
                    {FOTOS_VIATURA_DEF.filter(f => fotosViatura[f.key]).length} / 5 fotos registradas
                  </span>
                </div>
              </div>

              {/* Checklist de itens */}
              <div>
                <div className="flex items-center gap-2 mb-3 pb-2" style={{ borderBottom: '1px solid #EEF1F7' }}>
                  <div style={{ width: '3px', height: '14px', backgroundColor: '#1A294A' }} />
                  <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: '#1A294A' }}>Checklist de Condições</span>
                </div>
                <div className="space-y-2">
                  {ITENS_CHECKLIST_VIATURA.map((item) => (
                    <label key={item.key} className="flex items-start gap-3 p-3 cursor-pointer transition-colors"
                      style={{ backgroundColor: checkViatura[item.key] ? 'rgba(30,124,82,0.06)' : '#F5F7FA', border: `1px solid ${checkViatura[item.key] ? '#1E7C52' : '#D6DAE5'}` }}>
                      <input
                        type="checkbox"
                        checked={checkViatura[item.key]}
                        onChange={(e) => setCheckViatura({ ...checkViatura, [item.key]: e.target.checked })}
                        className="mt-0.5 shrink-0"
                      />
                      <span className="text-xs font-semibold" style={{ color: checkViatura[item.key] ? '#1E7C52' : '#0E1A33' }}>{item.label}</span>
                    </label>
                  ))}
                </div>
                <div className="flex items-center gap-2 mt-2 px-1">
                  <div style={{ width: '8px', height: '8px', flexShrink: 0, backgroundColor: Object.values(checkViatura).every(Boolean) ? '#1E7C52' : '#8B6914' }} />
                  <span className="text-[10px] font-bold" style={{ color: Object.values(checkViatura).every(Boolean) ? '#1E7C52' : '#8B6914' }}>
                    {Object.values(checkViatura).filter(Boolean).length} / {ITENS_CHECKLIST_VIATURA.length} itens conformes
                  </span>
                </div>
              </div>

              {/* Observações */}
              <div>
                <label className="block text-xs font-bold mb-1.5 uppercase tracking-wide" style={{ color: '#5A6A80' }}>
                  Observações / Não Conformidades *
                </label>
                <TextAreaWithTools
                  value={obsViatura}
                  onChange={(v) => setObsViatura(v)}
                  placeholder="Descreva o estado geral do veículo, irregularidades encontradas ou confirmação de conformidade..."
                  rows={3}
                  textareaClassName="input-light resize-none text-xs"
                  contextoAI="Inspeção de viatura para escolta armada"
                />
              </div>

              <div className="flex justify-between pt-3 border-t">
                <button type="button" onClick={() => { setErro(null); setWizardStep(1) }} className="btn-outline px-5">
                  Voltar
                </button>
                <button
                  type="button"
                  onClick={() => {
                    const faltando = FOTOS_VIATURA_DEF.filter(f => !fotosViatura[f.key])
                    if (faltando.length > 0) { setErro(`Fotos obrigatórias: ${faltando.map(f => f.label).join(', ')}.`); return }
                    if (!obsViatura.trim()) { setErro('As observações são obrigatórias.'); return }
                    setErro(null)
                    setWizardStep(3)
                  }}
                  className="btn-gradient px-6"
                >
                  Viatura Liberada — Avançar
                </button>
              </div>
            </div>
          )}

          {/* STEP 3: SAÍDA DA BASE */}
          {wizardStep === 3 && (
            <div className="space-y-4">
              <h3 className="font-bold text-xs text-[#53648A] uppercase tracking-wider">Passo 3: Registro de Partida (Saída da Base)</h3>
              
              <div>
                <label className="block text-xs font-bold mb-1.5 text-[#5A6A80] uppercase tracking-wide">
                  Quilometragem Inicial (KM) da Viatura *
                </label>
                <input
                  type="number"
                  value={kmPartida}
                  onChange={(e) => setKmPartida(e.target.value)}
                  placeholder="Ex: 104500"
                  className="input-light text-xs w-full"
                />
              </div>

              <div>
                <label className="block text-xs font-bold mb-1.5 text-[#5A6A80] uppercase tracking-wide">
                  Foto do Hodômetro / Painel * (Use a Câmera)
                </label>
                <CameraInput onChange={(fs) => setFotoPartida(fs[0] ?? null)} />
              </div>

              <div>
                <label className="block text-xs font-bold mb-1.5 text-[#5A6A80] uppercase tracking-wide">
                  Observações Gerais de Saída *
                </label>
                <TextAreaWithTools
                  value={obsPartida}
                  onChange={(v) => setObsPartida(v)}
                  placeholder="Observações da rota, condições climáticas ou do tráfego..."
                  rows={3}
                  textareaClassName="input-light resize-none text-xs"
                  contextoAI="Observações gerais de saída para escolta armada"
                />
              </div>

              <div className="flex justify-between pt-3 border-t">
                <button type="button" onClick={() => setWizardStep(2)} className="btn-outline px-5">
                  Voltar
                </button>
                <button
                  type="button"
                  onClick={handleWizardSubmit}
                  disabled={loading}
                  className="btn-gradient px-6"
                >
                  {loading ? 'Iniciando...' : 'Confirmar e Iniciar Escolta'}
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    )
  }

  // ── Render ───────────────────────────────────────────────────────────────────
  return (
    <div className="space-y-5">

      {/* ── Painel de Designação de Responsabilidade ── */}
      {['rascunho', 'agendada'].includes(escolta.status) && (
        <div className="card-light p-5 space-y-4 border-l-4 border-amber-500">
          <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
            <div>
              <h2 className="font-bold text-sm text-[#0E1A33] uppercase tracking-wide">Designação de Responsável</h2>
              <p className="text-xs text-[#5A6A80] mt-1">
                Esta escolta está pendente de início. É necessário definir o operador responsável para liberar o checklist.
              </p>
            </div>
            
            <div className="flex flex-wrap items-center gap-3">
            </div>
          </div>
        </div>
      )}

      {/* Em pré-início: wizard obrigatório para TODOS os perfis (checklist EPI + VTR + saída) */}
      {escolta.status === 'em_pre_inicio' ? (
        renderGuidedWizard()
      ) : (
        <>
          {/* ── Header Card ── */}
          <div className="card-light overflow-visible" style={{ borderLeft: `4px solid ${cor}` }}>
            <div className="p-5">
              <div className="flex items-start justify-between gap-4 flex-wrap">
                <div className="flex items-start gap-3">
              <button
                onClick={() => router.back()}
                className="w-8 h-8 flex items-center justify-center rounded mt-0.5 transition-colors"
                style={{ color: '#6B7E8A' }}
                onMouseEnter={(e) => { (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F2F4' }}
                onMouseLeave={(e) => { (e.currentTarget as HTMLElement).style.backgroundColor = '' }}
              >
                <ArrowLeft size={16} />
              </button>
              <div>
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="font-mono text-sm font-bold" style={{ color: '#1E2D35' }}>
                    {escolta.codigo_escolta ?? 'Sem código'}
                  </span>
                  <span className={si.cls}>{si.label}</span>
                  {escolta.checklist_pendente_no_inicio && (
                    <span className="badge-warning">Checklist pendente</span>
                  )}
                </div>
                {escolta.cliente && (
                  <p className="text-sm mt-0.5" style={{ color: '#6B7E8A' }}>
                    {escolta.cliente.nome_cliente}
                    {escolta.cliente.telefone && ` · ${escolta.cliente.telefone}`}
                  </p>
                )}
              </div>
            </div>

            <div className="flex items-center gap-2.5 flex-shrink-0">
              <button
                onClick={() => printEscolta(escolta.id)}
                className="flex items-center gap-1.5 font-black text-[10px] uppercase tracking-widest px-4 py-2 transition-all active:scale-95"
                style={{ backgroundColor: '#F0F4FA', color: '#1A2F4A', border: '1px solid #D0DAEB', borderRadius: '1px' }}
                onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#E2EAF7' }}
                onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F4FA' }}
                title="Exportar PDF"
              >
                <FileDown size={13} /> PDF
              </button>
              {PODE_CANCELAR.includes(perfil) && !isFinalizado && (
                <button
                  onClick={() => { setErro(null); setDialogCancelar(true) }}
                  className="bg-[#FAEAE9] hover:bg-[#F5D5D3] text-[#B83832] border border-[#EAB5B0] font-black text-[10px] uppercase tracking-widest px-4 py-2 flex items-center gap-1.5 transition-all active:scale-95"
                  style={{ borderRadius: '1px' }}
                >
                  <XCircle size={14} /> Cancelar
                </button>
              )}
              {PODE_AVANCAR.includes(perfil) && proximo && (
                <button
                  onClick={() => { setErro(null); setDialogAvanco(true) }}
                  className="text-white font-black text-[10px] uppercase tracking-widest px-5 py-2 flex items-center gap-1.5 transition-all active:scale-95"
                  style={{ backgroundColor: '#1A294A', borderRadius: '1px', boxShadow: '0 2px 8px rgba(26,41,74,0.25)' }}
                  onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#253562' }}
                  onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#1A294A' }}
                >
                  {proximo.label} <ChevronRight size={14} />
                </button>
              )}
            </div>
          </div>

          {/* ── Jornada: barra de progresso visual ── */}
          <div className="mt-5 pt-4 border-t" style={{ borderColor: '#E2E8EC' }}>
            {/* Linha de progresso contínua */}
            <div className="relative flex items-center gap-0 overflow-x-auto pb-1">
              {JORNADA_ETAPAS.map((etapa, idx) => {
                const ativo    = idx === etapaAtual
                const concluido = idx < etapaAtual
                const cor = concluido ? '#1E7C52' : ativo ? '#53648A' : '#C8D5DC'
                return (
                  <div key={idx} className="flex items-center flex-shrink-0">
                    {/* Conector */}
                    {idx > 0 && (
                      <div style={{ width: '24px', height: '2px', backgroundColor: concluido ? '#1E7C52' : '#E2E8EC', flexShrink: 0 }} />
                    )}
                    {/* Etapa */}
                    <div className="flex flex-col items-center gap-1.5" style={{ minWidth: '64px' }}>
                      {/* Círculo/ícone */}
                      <div style={{ position: 'relative' }}>
                        {ativo && (
                          <div style={{
                            position: 'absolute', inset: '-5px',
                            borderRadius: '1px',
                            border: '2px solid #53648A',
                            opacity: 0.35,
                            animation: 'pulse 1.8s ease-in-out infinite',
                          }} />
                        )}
                        <div style={{
                          width: '32px', height: '32px',
                          backgroundColor: concluido ? '#1E7C52' : ativo ? '#1A294A' : '#EEF0F5',
                          border: `2px solid ${cor}`,
                          display: 'flex', alignItems: 'center', justifyContent: 'center',
                          position: 'relative', zIndex: 1,
                          boxShadow: ativo ? '0 4px 14px rgba(26,41,74,0.3)' : 'none',
                          transition: 'all 0.3s ease',
                        }}>
                          {concluido
                            ? <CheckCircle2 size={14} color="#fff" />
                            : <span style={{ fontSize: '11px', fontWeight: 900, color: ativo ? '#fff' : '#A8B8C2' }}>{idx + 1}</span>
                          }
                        </div>
                      </div>
                      {/* Label */}
                      <span style={{
                        fontSize: '9px', fontWeight: 900,
                        textTransform: 'uppercase', letterSpacing: '0.1em',
                        color: concluido ? '#1E7C52' : ativo ? '#1A294A' : '#A8B8C2',
                        textAlign: 'center', lineHeight: 1.2,
                        whiteSpace: 'nowrap',
                      }}>
                        {etapa.label}
                      </span>
                      {/* Indicador ATUAL */}
                      {ativo && (
                        <div style={{
                          width: '20px', height: '2px',
                          backgroundColor: '#53648A',
                          animation: 'pulse 1.8s ease-in-out infinite',
                        }} />
                      )}
                    </div>
                  </div>
                )
              })}
            </div>
            {/* Duração da operação */}
            <div className="flex items-center gap-2 mt-3">
              <Clock size={11} style={{ color: '#A8B8C2' }} />
              <span style={{ fontSize: '10px', color: '#A8B8C2', fontWeight: 700, letterSpacing: '0.05em' }}>
                {isFinalizado ? 'Duração total:' : 'Em operação há:'}
              </span>
              <span style={{ fontSize: '10px', color: '#0E1A33', fontWeight: 900, letterSpacing: '0.05em' }}>
                {calcDuracao(escolta.criado_em, escolta.data_finalizacao ?? undefined)}
              </span>
            </div>

            {/* Paradas registradas */}
            {paradas.length > 0 && (
              <div className="mt-3 pt-3 border-t" style={{ borderColor: '#E2E8EC' }}>
                <div className="flex items-center gap-2 mb-2">
                  <Octagon size={10} style={{ color: '#8B6914' }} />
                  <span style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#8B6914' }}>
                    Paradas Registradas ({paradas.length})
                  </span>
                </div>
                <div className="flex flex-wrap gap-2">
                  {paradas.map((p, idx) => {
                    const tp = TIPOS_PARADA.find(t => t.value === p.tipo)
                    const cor = tp?.cor ?? '#8B6914'
                    return (
                      <button key={p.id} type="button" onClick={() => setParadaSelecionada(p)}
                        style={{ display: 'flex', alignItems: 'center', gap: '5px', padding: '3px 8px', backgroundColor: `${cor}18`, border: `1px solid ${cor}40`, color: cor, cursor: 'pointer', transition: 'all 0.15s' }}
                        onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = `${cor}30` }}
                        onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = `${cor}18` }}>
                        <span style={{ fontSize: '8px', fontWeight: 900, backgroundColor: cor, color: '#fff', width: '14px', height: '14px', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>{idx + 1}</span>
                        <span style={{ fontSize: '9px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.06em' }}>{p.tipoLabel}</span>
                        <span style={{ fontSize: '9px', color: '#5A6A80', fontWeight: 600 }}>
                          {new Date(p.data_hora).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                        </span>
                      </button>
                    )
                  })}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* ── PAINEL DE AÇÕES DO OPERADOR ── */}
      {!isFinalizado && (
        <div className="card-light p-5 space-y-4">
          <div className="flex items-center justify-between border-b pb-3" style={{ borderColor: '#E2E8EC' }}>
            <h3 className="text-xs font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>
              Painel de Ações do Operador
            </h3>
            <span className="badge-info">Operação em Andamento</span>
          </div>

          {/* Periodicidade de check-in */}
          <div className="flex items-center gap-3 p-3 rounded" style={{ backgroundColor: '#F0FAF5', border: '1.5px solid rgba(30,124,82,0.2)' }}>
            <Radio size={14} style={{ color: '#1E7C52', flexShrink: 0 }} />
            <div className="flex-1 min-w-0">
              <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#1E7C52' }}>
                Periodicidade de Check-in
              </p>
              {editandoPeriodicidade ? (
                <div className="flex items-center gap-2 mt-1">
                  <select
                    value={periodicidadeEdit}
                    onChange={e => setPeriodicidadeEdit(e.target.value)}
                    className="text-xs border rounded px-2 py-1"
                    style={{ borderColor: '#D6DAE5', backgroundColor: '#fff', color: '#0E1A33' }}
                  >
                    <option value="">Desativado</option>
                    {[10,15,20,30,45,60,90,120].map(m => (
                      <option key={m} value={String(m)}>A cada {m} min</option>
                    ))}
                  </select>
                  <button onClick={salvarPeriodicidade} className="text-xs font-bold px-3 py-1 text-white rounded" style={{ backgroundColor: '#1E7C52' }}>Salvar</button>
                  <button onClick={() => setEditandoPeriodicidade(false)} className="text-xs px-2 py-1" style={{ color: '#5A6A80' }}>Cancelar</button>
                </div>
              ) : (
                <div className="flex items-center gap-2 mt-0.5">
                  <span style={{ fontSize: '11px', fontWeight: 600, color: '#0E1A33' }}>
                    {escolta.periodicidade_checkin_min ? `A cada ${escolta.periodicidade_checkin_min} min` : 'Desativado'}
                  </span>
                  <button onClick={() => { setPeriodicidadeEdit(escolta.periodicidade_checkin_min ? String(escolta.periodicidade_checkin_min) : ''); setEditandoPeriodicidade(true) }}
                    style={{ fontSize: '10px', color: '#1E7C52', textDecoration: 'underline' }}>
                    Alterar
                  </button>
                  {minutosAteCheckin !== null && (
                    <span className="px-2 py-0.5 rounded font-bold" style={{
                      fontSize: '9px',
                      backgroundColor: minutosAteCheckin <= 0 ? '#FEF0EE' : minutosAteCheckin <= 5 ? '#FFF8E6' : '#E6F4ED',
                      color: minutosAteCheckin <= 0 ? '#B83832' : minutosAteCheckin <= 5 ? '#8B6914' : '#1E7C52',
                    }}>
                      {minutosAteCheckin <= 0 ? '⚠ CHECK-IN ATRASADO' : `Próximo em ${minutosAteCheckin} min`}
                    </span>
                  )}
                </div>
              )}
            </div>
          </div>

          <div className="flex gap-2 flex-wrap">
            {/* Iniciar Operação: esta ação só é acessível via o wizard de pré-início (checklist obrigatório) */}

            {/* Check-in Periódico */}
            {['em_andamento', 'na_origem', 'no_destino', 'retornando'].includes(escolta.status) && (
              <button onClick={abrirDialogCheckin}
                className="h-9 px-5 font-black text-[10px] uppercase tracking-widest flex items-center gap-2 text-white active:scale-95 transition-all"
                style={{
                  backgroundColor: minutosAteCheckin !== null && minutosAteCheckin <= 0 ? '#B83832' : '#1E7C52',
                  boxShadow: minutosAteCheckin !== null && minutosAteCheckin <= 0 ? '0 2px 8px rgba(184,56,50,0.35)' : '0 2px 8px rgba(30,124,82,0.25)',
                }}
                onMouseEnter={e=>(e.currentTarget as HTMLElement).style.opacity='0.85'}
                onMouseLeave={e=>(e.currentTarget as HTMLElement).style.opacity='1'}>
                <Radio size={13} />
                {minutosAteCheckin !== null && minutosAteCheckin <= 0 ? 'CHECK-IN ATRASADO' : 'Check-in'}
              </button>
            )}

            {/* 2. Registrar Parada */}
            {['em_andamento', 'na_origem', 'no_destino', 'retornando'].includes(escolta.status) && (
              <button onClick={() => { setErro(null); setDialogParada(true) }}
                className="h-9 px-5 font-black text-[10px] uppercase tracking-widest flex items-center gap-2 active:scale-95 transition-all"
                style={{ backgroundColor: '#FBF3DE', color: '#8B6914', border: '1.5px solid rgba(139,105,20,0.25)' }}
                onMouseEnter={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#F5E8B8'}
                onMouseLeave={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#FBF3DE'}>
                <Octagon size={13} /> Registrar Parada
              </button>
            )}

            {/* 3. Chegada na Origem */}
            {escolta.status === 'em_andamento' && (
              <button onClick={() => { setErro(null); setDialogChegadaOrigem(true) }}
                className="h-9 px-5 font-black text-[10px] uppercase tracking-widest flex items-center gap-2 text-white active:scale-95 transition-all"
                style={{ backgroundColor: '#53648A', boxShadow: '0 2px 8px rgba(83,100,138,0.25)' }}
                onMouseEnter={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#3F4E6D'}
                onMouseLeave={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#53648A'}>
                <MapPin size={13} /> Chegada na Origem
              </button>
            )}

            {/* 4. Chegada no Destino */}
            {escolta.status === 'na_origem' && (
              <button onClick={() => { setErro(null); setDialogChegadaDestino(true) }}
                className="h-9 px-5 font-black text-[10px] uppercase tracking-widest flex items-center gap-2 text-white active:scale-95 transition-all"
                style={{ backgroundColor: '#9F906D', boxShadow: '0 2px 8px rgba(159,144,109,0.25)' }}
                onMouseEnter={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#7A6D51'}
                onMouseLeave={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#9F906D'}>
                <Truck size={13} /> Chegada no Destino
              </button>
            )}

            {/* 5. Iniciar Retorno */}
            {escolta.status === 'no_destino' && (
              <button onClick={() => { setErro(null); setDialogIniciarRetorno(true) }}
                className="h-9 px-5 font-black text-[10px] uppercase tracking-widest flex items-center gap-2 text-white active:scale-95 transition-all"
                style={{ backgroundColor: '#53648A', boxShadow: '0 2px 8px rgba(83,100,138,0.25)' }}
                onMouseEnter={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#3F4E6D'}
                onMouseLeave={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#53648A'}>
                <RotateCcw size={13} /> Iniciar Retorno
              </button>
            )}

            {/* 6. Chegada na Base */}
            {escolta.status === 'retornando' && (
              <button onClick={() => { setErro(null); setDialogChegadaBase(true) }}
                className="h-9 px-5 font-black text-[10px] uppercase tracking-widest flex items-center gap-2 text-white active:scale-95 transition-all"
                style={{ backgroundColor: '#1A294A', boxShadow: '0 2px 8px rgba(26,41,74,0.25)' }}
                onMouseEnter={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#253562'}
                onMouseLeave={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#1A294A'}>
                <Home size={13} /> Chegada na Base
              </button>
            )}

            {/* 7. Finalizar Escolta */}
            {escolta.status === 'na_base' && (
              <button onClick={() => { setErro(null); setDialogFinalizacao(true) }}
                className="h-9 px-5 font-black text-[10px] uppercase tracking-widest flex items-center gap-2 text-white active:scale-95 transition-all"
                style={{ backgroundColor: '#1E7C52', boxShadow: '0 2px 8px rgba(30,124,82,0.3)' }}
                onMouseEnter={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#166040'}
                onMouseLeave={e=>(e.currentTarget as HTMLElement).style.backgroundColor='#1E7C52'}>
                <CheckCircle2 size={13} /> Finalizar Escolta
              </button>
            )}
          </div>
        </div>
      )}

      {/* ── Quick Stats ── */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <div className="card-light p-4 col-span-2">
          <div className="flex items-center gap-2 mb-3">
            <Navigation size={14} style={{ color: '#53648A' }} />
            <span className="text-xs font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Rota</span>
          </div>
          <div className="space-y-2">
            <div className="flex items-start gap-2">
              <div className="w-2 h-2 rounded mt-1.5 flex-shrink-0" style={{ backgroundColor: '#53648A' }} />
              <p className="text-sm font-medium" style={{ color: '#1E2D35' }}>{escolta.origem_endereco}</p>
            </div>
            <div className="ml-1 w-px h-3" style={{ backgroundColor: '#E2E8EC' }} />
            <div className="flex items-start gap-2">
              <MapPin size={8} className="mt-1.5 flex-shrink-0" style={{ color: '#1E7C52' }} />
              <p className="text-sm font-medium" style={{ color: '#1E2D35' }}>{escolta.destino_endereco}</p>
            </div>
          </div>
        </div>

        <div className="card-light p-4">
          <div className="flex items-center gap-2 mb-2">
            <Clock size={14} style={{ color: '#53648A' }} />
            <span className="text-xs font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Previsão</span>
          </div>
          <p className="text-sm font-semibold" style={{ color: '#1E2D35' }}>
            {new Date(escolta.data_hora_prevista).toLocaleDateString('pt-BR')}
          </p>
          <p className="text-xs mt-0.5" style={{ color: '#6B7E8A' }}>
            {new Date(escolta.data_hora_prevista).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
          </p>
          {escolta.data_finalizacao && (
            <div className="mt-2 pt-2 border-t" style={{ borderColor: '#E2E8EC' }}>
              <p className="text-[10px] font-semibold uppercase" style={{ color: '#1E7C52' }}>Finalizada</p>
              <p className="text-xs mt-0.5" style={{ color: '#6B7E8A' }}>{formatarDataHora(escolta.data_finalizacao)}</p>
            </div>
          )}
        </div>

        <div className="card-light p-4">
          <div className="flex items-center gap-2 mb-2">
            <Shield size={14} style={{ color: '#53648A' }} />
            <span className="text-xs font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Efetivo</span>
          </div>
          <div className="flex items-baseline gap-1">
            <span className="text-2xl font-black" style={{ color: '#1E2D35' }}>{totalEfetivo}</span>
            <span className="text-xs" style={{ color: '#6B7E8A' }}>vigilantes</span>
          </div>
          <div className="flex items-center gap-1.5 mt-1">
            <Truck size={11} style={{ color: '#A8B8C2' }} />
            <span className="text-xs" style={{ color: '#6B7E8A' }}>{viaturas.length} viatura{viaturas.length !== 1 ? 's' : ''}</span>
          </div>
        </div>
      </div>

      {/* ── Tabs ── */}
      <div className="flex gap-0 border-b overflow-x-auto" style={{ borderColor: '#E2E8EC' }}>
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className="px-4 py-2.5 text-xs font-semibold whitespace-nowrap border-b-2 -mb-px transition-colors"
            style={
              tab === t.key
                ? { color: '#53648A', borderBottomColor: '#53648A', backgroundColor: 'transparent' }
                : { color: '#6B7E8A', borderBottomColor: 'transparent', backgroundColor: 'transparent' }
            }
          >
            {t.label}
            {t.count !== undefined && t.count > 0 && (
              <span className="ml-1.5 text-[10px] rounded px-1.5 py-0.5" style={{ backgroundColor: '#F0F2F4', color: '#6B7E8A' }}>
                {t.count}
              </span>
            )}
          </button>
        ))}
      </div>

      {/* ── TAB: Visão Geral ── */}
      {tab === 'geral' && (
        <div className="space-y-4">
          <div className="card-light p-5">
            <h3 className="text-xs font-bold uppercase tracking-wider mb-4" style={{ color: '#6B7E8A' }}>Detalhes</h3>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#A8B8C2' }}>Criada em</p>
                <p className="text-sm font-medium mt-0.5" style={{ color: '#1E2D35' }}>{formatarDataHora(escolta.criado_em)}</p>
              </div>
              {escolta.data_finalizacao && (
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#A8B8C2' }}>Finalizada em</p>
                  <p className="text-sm font-medium mt-0.5" style={{ color: '#1E2D35' }}>{formatarDataHora(escolta.data_finalizacao)}</p>
                </div>
              )}
              {escolta.cliente?.telefone && (
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#A8B8C2' }}>Telefone do cliente</p>
                  <p className="text-sm font-medium mt-0.5" style={{ color: '#1E2D35' }}>{escolta.cliente.telefone}</p>
                </div>
              )}
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#A8B8C2' }}>Status atual</p>
                <div className="mt-1"><span className={si.cls}>{si.label}</span></div>
              </div>
            </div>
            {escolta.observacao_fechamento && (
              <div className="mt-4 pt-4 border-t" style={{ borderColor: '#E2E8EC' }}>
                <p className="text-[10px] font-semibold uppercase tracking-wider mb-1" style={{ color: '#A8B8C2' }}>
                  {escolta.status === 'cancelada' ? 'Motivo do cancelamento' : 'Observação de fechamento'}
                </p>
                <p className="text-sm" style={{ color: '#1E2D35' }}>{escolta.observacao_fechamento}</p>
              </div>
            )}
          </div>

          <div className="card-light p-5">
            <h3 className="text-xs font-bold uppercase tracking-wider mb-4" style={{ color: '#6B7E8A' }}>Rota</h3>
            <div className="relative pl-6">
              <div className="absolute left-2 top-2 bottom-2 w-px" style={{ backgroundColor: '#E2E8EC' }} />
              <div className="space-y-5">
                <div className="relative">
                  <div className="absolute -left-6 w-4 h-4 rounded flex items-center justify-center border-2 border-white"
                    style={{ backgroundColor: '#53648A', boxShadow: '0 0 0 2px #E2E8EC' }}>
                    <div className="w-1.5 h-1.5 rounded bg-white" />
                  </div>
                  <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#53648A' }}>Origem</p>
                  <p className="text-sm font-medium mt-0.5" style={{ color: '#1E2D35' }}>{escolta.origem_endereco}</p>
                </div>
                <div className="relative">
                  <div className="absolute -left-6 w-4 h-4 rounded flex items-center justify-center border-2 border-white"
                    style={{ backgroundColor: '#1E7C52', boxShadow: '0 0 0 2px #E2E8EC' }}>
                    <MapPin size={7} className="text-white" />
                  </div>
                  <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#1E7C52' }}>Destino</p>
                  <p className="text-sm font-medium mt-0.5" style={{ color: '#1E2D35' }}>{escolta.destino_endereco}</p>
                </div>
              </div>
            </div>
          </div>

          {historico.length > 0 && (
            <div className="card-light p-5">
              <h3 className="text-[10px] font-black uppercase tracking-widest mb-3" style={{ color: '#5A6A80' }}>Histórico de Status</h3>
              <div>
                {[...historico].reverse().map((h) => (
                  <div key={h.id} className="flex items-center py-2 border-b last:border-0" style={{ borderColor: '#EEF0F5' }}>
                    {/* Badge ANTERIOR — largura fixa */}
                    <div style={{ width: '110px', flexShrink: 0 }}>
                      <span className={STATUS_INFO[h.status_anterior]?.cls ?? 'badge-neutral'} style={{ width: '100%', justifyContent: 'center' }}>
                        {STATUS_INFO[h.status_anterior]?.label ?? h.status_anterior}
                      </span>
                    </div>
                    {/* Seta */}
                    <div style={{ width: '28px', flexShrink: 0, display: 'flex', justifyContent: 'center' }}>
                      <ArrowRight size={11} style={{ color: '#C8D5DC' }} />
                    </div>
                    {/* Badge NOVO — largura fixa */}
                    <div style={{ width: '110px', flexShrink: 0 }}>
                      <span className={STATUS_INFO[h.status_novo]?.cls ?? 'badge-neutral'} style={{ width: '100%', justifyContent: 'center' }}>
                        {STATUS_INFO[h.status_novo]?.label ?? h.status_novo}
                      </span>
                    </div>
                    {/* Data — resto do espaço, alinhada à direita */}
                    <span className="flex-1 text-right text-[10px] font-mono" style={{ color: '#A8B8C2' }}>
                      {new Date(h.data_hora).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {/* ── TAB: Timeline ── */}
      {tab === 'timeline' && (
        <div>
          {timeline.length === 0 ? (
            <div className="card-light p-12 text-center">
              <Clock size={24} className="mx-auto mb-3" style={{ color: '#C8D5DC' }} />
              <p className="text-sm font-semibold" style={{ color: '#5A6A80' }}>Nenhum evento operacional registrado.</p>
              <p className="text-xs mt-1" style={{ color: '#A8B8C2' }}>Os eventos aparecerão aqui conforme a operação avança.</p>
            </div>
          ) : (
            <div className="card-light" style={{ overflow: 'hidden' }}>
              {/* Header */}
              <div className="px-6 py-4 border-b flex items-center justify-between" style={{ borderColor: '#DDE3EC', backgroundColor: '#F4F6FA' }}>
                <div>
                  <span className="text-[11px] font-black uppercase tracking-widest" style={{ color: '#1A294A' }}>
                    Histórico da Operação
                  </span>
                  <p className="text-[10px] mt-0.5" style={{ color: '#7A8FA6' }}>{timeline.length} eventos · mais recente no topo</p>
                </div>
                <div className="flex items-center gap-4">
                  {Object.entries(TIPO_ICON_MAP).map(([tipo, m]) => (
                    timeline.some(t => t.tipo === tipo) ? (
                      <div key={tipo} className="flex items-center gap-1.5">
                        <div style={{ width: '8px', height: '8px', backgroundColor: m.color, flexShrink: 0 }} />
                        <span style={{ fontSize: '10px', color: '#7A8FA6', fontWeight: 600 }}>{m.label}</span>
                      </div>
                    ) : null
                  ))}
                </div>
              </div>

              {/* Lista */}
              <div className="px-6 py-5">
                <div className="relative">
                  {/* Linha vertical da timeline */}
                  <div className="absolute top-0 bottom-0" style={{ left: '19px', width: '2px', backgroundColor: '#D0D8E8', zIndex: 0 }} />

                  <div style={{ display: 'flex', flexDirection: 'column', gap: '0px' }}>
                    {timeline.map((item, idx) => {
                      const meta = TIPO_ICON_MAP[item.tipo] ?? TIPO_ICON_MAP.status
                      let Icon = Shield
                      if (item.tipo === 'ponto_controle')   Icon = MapPin
                      else if (item.tipo === 'presenca')    Icon = UserCheck
                      else if (item.tipo === 'checklist')   Icon = ClipboardList
                      else if (item.tipo === 'ocorrencia')  Icon = AlertTriangle

                      const isMaisRecente = idx === 0
                      const extraStatus = item.extra as Record<string, string> | undefined
                      const isChecklist = item.tipo === 'checklist'

                      return (
                        <div key={item.id} style={{ position: 'relative', zIndex: 1, paddingBottom: idx < timeline.length - 1 ? '0px' : '0px' }}>
                          <button
                            onClick={() => isChecklist ? setChecklistModal(item) : setSelectedTimelineItem(item)}
                            className="w-full text-left transition-colors"
                            style={{ display: 'flex', gap: '16px', alignItems: 'flex-start', padding: '14px 0', borderBottom: idx < timeline.length - 1 ? '1px solid #EEF1F7' : 'none' }}
                            onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#F8FAFC' }}
                            onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '' }}
                          >
                            {/* Ícone quadrado */}
                            <div style={{ flexShrink: 0, width: '40px', display: 'flex', justifyContent: 'center', paddingTop: '1px' }}>
                              <div style={{
                                width: '40px', height: '40px',
                                backgroundColor: isMaisRecente ? meta.color : meta.bg,
                                border: `2px solid ${meta.color}`,
                                display: 'flex', alignItems: 'center', justifyContent: 'center',
                                position: 'relative', zIndex: 2,
                                flexShrink: 0,
                              }}>
                                <Icon size={16} style={{ color: isMaisRecente ? '#fff' : meta.color }} />
                              </div>
                            </div>

                            {/* Conteúdo */}
                            <div style={{ flex: 1, minWidth: 0 }}>
                              {/* Cabeçalho do evento */}
                              <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: '12px', marginBottom: '6px' }}>
                                <div style={{ minWidth: 0, flex: 1 }}>
                                  <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '4px', flexWrap: 'wrap' }}>
                                    <span style={{
                                      fontSize: '9px', fontWeight: 900, letterSpacing: '0.12em',
                                      textTransform: 'uppercase', color: meta.color,
                                      padding: '2px 6px', backgroundColor: meta.bg,
                                      border: `1px solid ${meta.color}`,
                                      flexShrink: 0,
                                    }}>
                                      {meta.label}
                                    </span>
                                    {isMaisRecente && (
                                      <span style={{
                                        fontSize: '8px', fontWeight: 900, letterSpacing: '0.1em',
                                        color: '#fff', textTransform: 'uppercase',
                                        padding: '2px 6px', backgroundColor: '#1E7C52',
                                        flexShrink: 0,
                                      }}>
                                        MAIS RECENTE
                                      </span>
                                    )}
                                  </div>
                                  <h4 style={{ fontSize: '13px', fontWeight: 800, color: '#0E1A33', margin: 0, letterSpacing: '0.01em', lineHeight: 1.3 }}>
                                    {item.titulo}
                                  </h4>
                                  {item.descricao && (
                                    <p style={{ fontSize: '12px', color: '#5A6A80', margin: '3px 0 0', lineHeight: 1.4 }}>{item.descricao}</p>
                                  )}
                                  {item.usuario && (
                                    <p style={{ fontSize: '11px', color: '#9AAABB', margin: '3px 0 0' }}>por {item.usuario}</p>
                                  )}
                                </div>

                                {/* Data/hora */}
                                <div style={{ flexShrink: 0, textAlign: 'right', paddingTop: '2px' }}>
                                  <p style={{ fontSize: '14px', fontWeight: 800, color: '#1A294A', margin: 0, fontVariantNumeric: 'tabular-nums' }}>
                                    {new Date(item.data_hora).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                                  </p>
                                  <p style={{ fontSize: '10px', color: '#A8B8C2', margin: '2px 0 0', fontFamily: 'monospace' }}>
                                    {new Date(item.data_hora).toLocaleDateString('pt-BR')}
                                  </p>
                                  {item.coordenadas && (
                                    <div style={{ marginTop: '4px', display: 'flex', justifyContent: 'flex-end' }}>
                                      <span style={{ fontSize: '8px', fontWeight: 700, color: '#1E7C52', backgroundColor: 'rgba(30,124,82,0.08)', padding: '1px 5px', border: '1px solid rgba(30,124,82,0.25)', letterSpacing: '0.08em' }}>GPS</span>
                                    </div>
                                  )}
                                </div>
                              </div>

                              {/* Transição de status */}
                              {item.tipo === 'status' && extraStatus && (
                                <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginTop: '6px' }}>
                                  <span style={{
                                    fontSize: '10px', fontWeight: 700, padding: '3px 10px',
                                    border: '1.5px solid #9AAABB', color: '#5A6A80',
                                    backgroundColor: '#F4F6FA', letterSpacing: '0.04em',
                                    whiteSpace: 'nowrap',
                                  }}>
                                    {STATUS_INFO[extraStatus.status_anterior]?.label ?? extraStatus.status_anterior}
                                  </span>
                                  <div style={{ display: 'flex', alignItems: 'center', gap: '2px', color: '#1A294A' }}>
                                    <div style={{ width: '18px', height: '2px', backgroundColor: '#1A294A' }} />
                                    <div style={{ width: 0, height: 0, borderTop: '5px solid transparent', borderBottom: '5px solid transparent', borderLeft: '7px solid #1A294A' }} />
                                  </div>
                                  <span style={{
                                    fontSize: '10px', fontWeight: 800, padding: '3px 10px',
                                    border: `1.5px solid ${meta.color}`, color: meta.color,
                                    backgroundColor: meta.bg, letterSpacing: '0.04em',
                                    whiteSpace: 'nowrap',
                                  }}>
                                    {STATUS_INFO[extraStatus.status_novo]?.label ?? extraStatus.status_novo}
                                  </span>
                                </div>
                              )}

                              {/* Foto thumbnail */}
                              {item.foto_url && (
                                <div style={{ marginTop: '10px', display: 'flex', alignItems: 'flex-start', gap: '10px' }}>
                                  <div style={{ position: 'relative', display: 'inline-block' }}>
                                    {/* eslint-disable-next-line @next/next/no-img-element */}
                                    <img
                                      src={item.foto_url}
                                      alt="Foto do evento"
                                      style={{ width: '80px', height: '60px', objectFit: 'cover', border: '1.5px solid #DDE3EC', display: 'block' }}
                                      onClick={e => { e.stopPropagation(); setSelectedPhoto({ url: item.foto_url!, titulo: item.titulo }) }}
                                    />
                                    {isChecklist && (
                                      <div style={{ position: 'absolute', inset: 0, backgroundColor: 'rgba(26,41,74,0.35)', display: 'flex', alignItems: 'center', justifyContent: 'center', pointerEvents: 'none' }}>
                                        <Camera size={14} color="#fff" />
                                      </div>
                                    )}
                                  </div>
                                  {isChecklist && (
                                    <div style={{ padding: '4px 8px', backgroundColor: 'rgba(83,100,138,0.08)', border: '1px solid rgba(83,100,138,0.2)', display: 'flex', alignItems: 'center', gap: '5px' }}>
                                      <ChevronRight size={11} style={{ color: '#53648A' }} />
                                      <span style={{ fontSize: '9px', fontWeight: 900, color: '#53648A', textTransform: 'uppercase', letterSpacing: '0.1em' }}>Ver detalhes completos</span>
                                    </div>
                                  )}
                                </div>
                              )}
                              {/* Sem foto mas é checklist: mostrar indicador clicável */}
                              {!item.foto_url && isChecklist && (
                                <div style={{ marginTop: '8px', display: 'inline-flex', alignItems: 'center', gap: '5px', padding: '5px 10px', backgroundColor: 'rgba(83,100,138,0.08)', border: '1px solid rgba(83,100,138,0.2)' }}>
                                  <ClipboardList size={11} style={{ color: '#53648A' }} />
                                  <span style={{ fontSize: '9px', fontWeight: 900, color: '#53648A', textTransform: 'uppercase', letterSpacing: '0.1em' }}>Ver todos os itens do checklist</span>
                                  <ChevronRight size={11} style={{ color: '#53648A' }} />
                                </div>
                              )}
                            </div>
                          </button>
                        </div>
                      )
                    })}
                  </div>
                </div>
              </div>
            </div>
          )}
        </div>
      )}

      {/* ── TAB: Efetivo ── */}
      {tab === 'efetivo' && (
        <div className="space-y-4">
          {viaturas.length === 0 ? (
            <div className="card-light p-12 text-center">
              <Users size={24} className="mx-auto mb-2" style={{ color: '#C8D5DC' }} />
              <p className="text-sm" style={{ color: '#6B7E8A' }}>Nenhuma viatura cadastrada.</p>
            </div>
          ) : viaturas.map((v, i) => (
            <div key={v.id} className="card-light p-5">
              <div className="flex items-center gap-2 mb-4 pb-3 border-b" style={{ borderColor: '#E2E8EC' }}>
                <Truck size={16} style={{ color: '#53648A' }} />
                <span className="font-semibold text-sm" style={{ color: '#1E2D35' }}>
                  Viatura {i + 1}
                  {v.veiculo && (
                    <span className="font-mono ml-2 text-xs font-normal" style={{ color: '#6B7E8A' }}>
                      {formatarPlaca(v.veiculo.placa)}
                    </span>
                  )}
                </span>
              </div>
              {v.efetivo.length === 0 ? (
                <p className="text-xs" style={{ color: '#A8B8C2' }}>Nenhum vigilante vinculado.</p>
              ) : (
                <div className="space-y-2">
                  {v.efetivo.map((e) => (
                    <div key={e.id} className="flex items-center justify-between py-2 border-b last:border-0" style={{ borderColor: '#F0F2F4' }}>
                      <div className="flex items-center gap-2">
                        <div className="w-8 h-8 rounded flex items-center justify-center" style={{ backgroundColor: '#F0F2F4' }}>
                          <Users size={13} style={{ color: '#6B7E8A' }} />
                        </div>
                        <span className="text-sm font-medium" style={{ color: '#1E2D35' }}>{e.vigilante?.nome_completo ?? '—'}</span>
                      </div>
                      <div className="flex items-center gap-2">
                        <span className={e.papel_na_escolta === 'comandante' ? 'badge-info' : 'badge-neutral'}>
                          {e.papel_na_escolta === 'comandante' ? 'Comandante' : 'Operador'}
                        </span>
                        {e.confirmado
                          ? <CheckCircle2 size={15} style={{ color: '#1E7C52' }} />
                          : <Clock size={15} style={{ color: '#C8D5DC' }} />}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* ── TAB: Veículos ── */}
      {tab === 'veiculos' && (
        <div className="space-y-4">
          {viaturas.length === 0 ? (
            <div className="card-light p-12 text-center">
              <Truck size={24} className="mx-auto mb-2" style={{ color: '#C8D5DC' }} />
              <p className="text-sm" style={{ color: '#6B7E8A' }}>Nenhum veículo cadastrado.</p>
            </div>
          ) : viaturas.map((v, i) => (
            <div key={v.id} className="card-light p-5">
              <div className="flex items-center gap-3 mb-4">
                <div className="w-10 h-10 rounded flex items-center justify-center" style={{ backgroundColor: '#F0F2F4' }}>
                  <Truck size={18} style={{ color: '#53648A' }} />
                </div>
                <div>
                  <p className="font-bold text-sm" style={{ color: '#1E2D35' }}>
                    {v.veiculo ? formatarPlaca(v.veiculo.placa) : `Viatura ${i + 1}`}
                  </p>
                  <p className="text-xs" style={{ color: '#6B7E8A' }}>
                    {v.veiculo?.modelo ?? '—'} · {v.veiculo?.tipo?.nome ?? '—'}
                  </p>
                </div>
              </div>
              <div className="grid grid-cols-2 gap-3 pt-3 border-t" style={{ borderColor: '#E2E8EC' }}>
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#A8B8C2' }}>KM Saída</p>
                  <p className="text-sm font-medium mt-0.5" style={{ color: '#1E2D35' }}>{v.quilometragem_saida.toLocaleString('pt-BR')} km</p>
                </div>
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#A8B8C2' }}>KM Retorno</p>
                  <p className="text-sm font-medium mt-0.5" style={{ color: v.quilometragem_retorno != null ? '#1E2D35' : '#C8D5DC' }}>
                    {v.quilometragem_retorno != null ? `${v.quilometragem_retorno.toLocaleString('pt-BR')} km` : '—'}
                  </p>
                </div>
                {v.abastecimento_litros != null && (
                  <div>
                    <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#A8B8C2' }}>Abastecimento</p>
                    <p className="text-sm font-medium mt-0.5" style={{ color: '#1E2D35' }}>{v.abastecimento_litros} L</p>
                  </div>
                )}
                {v.abastecimento_valor != null && (
                  <div>
                    <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#A8B8C2' }}>Combustível</p>
                    <p className="text-sm font-medium mt-0.5" style={{ color: '#1E2D35' }}>
                      {v.abastecimento_valor.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })}
                    </p>
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {/* ── TAB: Ocorrências ── */}
      {tab === 'ocorrencias' && (
        <div className="space-y-3">
          {ocorrencias.length === 0 ? (
            <div className="card-light p-12 text-center">
              <AlertCircle size={24} className="mx-auto mb-2" style={{ color: '#C8D5DC' }} />
              <p className="text-sm" style={{ color: '#6B7E8A' }}>Nenhuma ocorrência registrada.</p>
            </div>
          ) : ocorrencias.map((o) => (
            <div key={o.id} className="card-light p-5">
              <div className="flex items-start justify-between gap-3">
                <div className="flex items-center gap-2">
                  <AlertTriangle size={15} style={{ color: '#A07212' }} />
                  <span className="font-semibold text-sm" style={{ color: '#1E2D35' }}>{o.tipo?.nome ?? 'Ocorrência'}</span>
                </div>
                <span className="text-xs flex-shrink-0" style={{ color: '#6B7E8A' }}>{formatarDataHora(o.data_hora)}</span>
              </div>
              <p className="text-sm mt-2" style={{ color: '#6B7E8A' }}>{o.descricao}</p>
              {o.autor?.nome_completo && (
                <p className="text-xs mt-2" style={{ color: '#A8B8C2' }}>Por: {o.autor.nome_completo}</p>
              )}
            </div>
          ))}
        </div>
      )}

      {/* ── TAB: Financeiro ── */}
      {tab === 'financeiro' && verFinanceiroDet && (() => {
        const custoVigilantes = viaturas.flatMap(v => v.efetivo).reduce((s, e) => s + (e.valor_pago_vigilante ?? 0), 0)
        const custoCombustivel = viaturas.reduce((s, v) => s + (v.abastecimento_valor ?? 0), 0)
        const outrosCusts = escolta.outros_custos ?? 0
        const totalCusto = custoVigilantes + custoCombustivel + outrosCusts
        const receita = escolta.valor_cobrado ?? 0
        const margem = receita - totalCusto
        const txMargem = receita > 0 ? (margem / receita) * 100 : null
        const fmtBRL = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })

        return (
          <div className="space-y-4">
            {/* KPI row */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
              {[
                { label: 'Receita', value: fmtBRL(receita), color: receita > 0 ? '#1E7C52' : '#A8B8C2', sub: 'Cobrado do cliente' },
                { label: 'Custo Total', value: fmtBRL(totalCusto), color: '#B83832', sub: `Pessoal + combustível + outros` },
                { label: 'Margem Bruta', value: fmtBRL(margem), color: margem >= 0 ? '#1E7C52' : '#B83832', sub: txMargem != null ? `${txMargem.toFixed(1)}% da receita` : '—' },
                { label: 'Tx. Margem', value: txMargem != null ? `${txMargem.toFixed(1)}%` : '—', color: txMargem == null ? '#A8B8C2' : txMargem >= 30 ? '#1E7C52' : txMargem >= 0 ? '#D97706' : '#B83832', sub: receita > 0 ? 'Margem sobre receita' : 'Sem receita definida' },
              ].map(k => (
                <div key={k.label} className="card-light p-4">
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.18em', color: '#A8B8C2', marginBottom: '6px' }}>{k.label}</p>
                  <p style={{ fontSize: '20px', fontWeight: 900, color: k.color, fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{k.value}</p>
                  <p style={{ fontSize: '10px', color: '#6B7E8A', marginTop: '4px' }}>{k.sub}</p>
                </div>
              ))}
            </div>

            {/* Breakdown */}
            <div className="card-light overflow-hidden">
              <div className="cc-panel-header">
                <div style={{ width: '4px', height: '4px', borderRadius: '50%', backgroundColor: '#53648A' }} />
                Detalhamento de Custos
              </div>
              <div className="p-4 space-y-3">
                {/* Vigilantes */}
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '8px' }}>
                    <p style={{ fontSize: '11px', fontWeight: 700, color: '#1E2D35' }}>Pessoal (Vigilantes)</p>
                    <p style={{ fontSize: '13px', fontWeight: 900, color: '#B83832' }}>{fmtBRL(custoVigilantes)}</p>
                  </div>
                  {viaturas.flatMap(v => v.efetivo).map(e => (
                    <div key={e.id} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '6px 12px', backgroundColor: '#F5F7FA', borderRadius: '2px', marginBottom: '4px' }}>
                      <div>
                        <p style={{ fontSize: '12px', fontWeight: 600, color: '#1E2D35' }}>{e.vigilante?.nome_completo ?? '—'}</p>
                        <p style={{ fontSize: '10px', color: '#6B7E8A', textTransform: 'capitalize' }}>{e.papel_na_escolta}</p>
                      </div>
                      <p style={{ fontSize: '12px', fontWeight: 700, color: e.valor_pago_vigilante != null ? '#1E2D35' : '#C8D5DC' }}>
                        {e.valor_pago_vigilante != null ? fmtBRL(e.valor_pago_vigilante) : 'Não definido'}
                      </p>
                    </div>
                  ))}
                </div>

                <div style={{ borderTop: '1px solid #E2E8EC', paddingTop: '12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <p style={{ fontSize: '11px', fontWeight: 700, color: '#1E2D35' }}>Combustível</p>
                  <p style={{ fontSize: '13px', fontWeight: 900, color: custoCombustivel > 0 ? '#B83832' : '#C8D5DC' }}>{fmtBRL(custoCombustivel)}</p>
                </div>

                <div style={{ borderTop: '1px solid #E2E8EC', paddingTop: '12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <p style={{ fontSize: '11px', fontWeight: 700, color: '#1E2D35' }}>Outros Custos</p>
                  <p style={{ fontSize: '13px', fontWeight: 900, color: outrosCusts > 0 ? '#B83832' : '#C8D5DC' }}>{fmtBRL(outrosCusts)}</p>
                </div>

                <div style={{ borderTop: '2px solid #1A294A', paddingTop: '12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <p style={{ fontSize: '12px', fontWeight: 900, color: '#1A294A', textTransform: 'uppercase', letterSpacing: '0.08em' }}>Total de Custos</p>
                  <p style={{ fontSize: '16px', fontWeight: 900, color: '#B83832' }}>{fmtBRL(totalCusto)}</p>
                </div>
              </div>
            </div>

            {/* Margem Visual */}
            {receita > 0 && (
              <div className="card-light p-4">
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.18em', color: '#A8B8C2', marginBottom: '12px' }}>Composição da Receita</p>
                <div style={{ display: 'flex', height: '12px', borderRadius: '2px', overflow: 'hidden', backgroundColor: '#F0F2F4' }}>
                  <div style={{ width: `${Math.min((custoVigilantes / receita) * 100, 100)}%`, backgroundColor: '#B83832' }} />
                  <div style={{ width: `${Math.min((custoCombustivel / receita) * 100, 100)}%`, backgroundColor: '#D97706' }} />
                  <div style={{ width: `${Math.min((outrosCusts / receita) * 100, 100)}%`, backgroundColor: '#A8B8C2' }} />
                  {margem > 0 && <div style={{ flex: 1, backgroundColor: '#1E7C52' }} />}
                </div>
                <div style={{ display: 'flex', gap: '16px', flexWrap: 'wrap', marginTop: '10px' }}>
                  {[
                    { label: 'Pessoal', value: custoVigilantes, color: '#B83832' },
                    { label: 'Combustível', value: custoCombustivel, color: '#D97706' },
                    { label: 'Outros', value: outrosCusts, color: '#A8B8C2' },
                    { label: 'Margem', value: margem, color: margem >= 0 ? '#1E7C52' : '#B83832' },
                  ].map(l => (
                    <div key={l.label} style={{ display: 'flex', alignItems: 'center', gap: '5px' }}>
                      <div style={{ width: '8px', height: '8px', borderRadius: '2px', backgroundColor: l.color, flexShrink: 0 }} />
                      <span style={{ fontSize: '10px', color: '#6B7E8A' }}>{l.label}: <strong style={{ color: '#1E2D35' }}>{fmtBRL(l.value)}</strong></span>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Obs financeira */}
            {escolta.observacao_financeira && (
              <div className="card-light p-4">
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.18em', color: '#A8B8C2', marginBottom: '8px' }}>Observação Financeira</p>
                <p style={{ fontSize: '13px', color: '#1E2D35' }}>{escolta.observacao_financeira}</p>
              </div>
            )}
          </div>
        )
      })()}

      {/* ── Modal: Detalhe de Item da Timeline ── */}
      {selectedTimelineItem && (() => {
        const item = selectedTimelineItem
        const meta = TIPO_ICON_MAP[item.tipo] ?? TIPO_ICON_MAP.status
        let Icon = Shield
        if (item.tipo === 'ponto_controle')   Icon = MapPin
        else if (item.tipo === 'presenca')    Icon = UserCheck
        else if (item.tipo === 'checklist')   Icon = ClipboardList
        else if (item.tipo === 'ocorrencia')  Icon = AlertTriangle
        return (
          <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center p-4" style={{ backgroundColor: 'rgba(14,26,51,0.7)' }}
            onClick={() => setSelectedTimelineItem(null)}>
            <div className="w-full max-w-lg bg-white overflow-hidden animate-in slide-in-from-bottom-4 fade-in"
              style={{ boxShadow: '0 32px 80px rgba(0,0,0,0.25)', animationDuration: '250ms' }}
              onClick={e => e.stopPropagation()}>

              {/* Header colorido */}
              <div className="px-5 py-4 flex items-center justify-between" style={{ backgroundColor: meta.color }}>
                <div className="flex items-center gap-3">
                  <div style={{ width: '36px', height: '36px', backgroundColor: 'rgba(255,255,255,0.15)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                    <Icon size={18} color="#fff" />
                  </div>
                  <div>
                    <p style={{ fontSize: '9px', fontWeight: 900, letterSpacing: '0.15em', textTransform: 'uppercase', color: 'rgba(255,255,255,0.65)' }}>{meta.label}</p>
                    <h3 className="font-black text-sm text-white" style={{ letterSpacing: '0.02em' }}>{item.titulo}</h3>
                  </div>
                </div>
                <button onClick={() => setSelectedTimelineItem(null)}
                  style={{ width: '32px', height: '32px', backgroundColor: 'rgba(255,255,255,0.15)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff' }}>
                  <XCircle size={16} />
                </button>
              </div>

              {/* Corpo */}
              <div className="p-5 space-y-4">
                {/* Data / Hora / Usuário */}
                <div className="grid grid-cols-2 gap-3">
                  <div className="p-3" style={{ backgroundColor: '#F5F7FA' }}>
                    <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#A8B8C2' }}>Data e Hora</p>
                    <p style={{ fontSize: '13px', fontWeight: 900, color: '#0E1A33', marginTop: '3px' }}>
                      {new Date(item.data_hora).toLocaleDateString('pt-BR')}
                    </p>
                    <p style={{ fontSize: '11px', fontWeight: 700, color: '#5A6A80' }}>
                      {new Date(item.data_hora).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                    </p>
                  </div>
                  {item.usuario && (
                    <div className="p-3" style={{ backgroundColor: '#F5F7FA' }}>
                      <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#A8B8C2' }}>Registrado por</p>
                      <p style={{ fontSize: '12px', fontWeight: 900, color: '#0E1A33', marginTop: '3px' }}>{item.usuario}</p>
                    </div>
                  )}
                </div>

                {/* Transição de status */}
                {item.tipo === 'status' && item.extra && (
                  <div className="flex items-center gap-3 p-3" style={{ backgroundColor: '#F5F7FA' }}>
                    <div style={{ flex: 1 }}>
                      <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', color: '#A8B8C2', letterSpacing: '0.1em', marginBottom: '4px' }}>De</p>
                      <span className={STATUS_INFO[(item.extra as Record<string,string>).status_anterior]?.cls ?? 'badge-neutral'}>
                        {STATUS_INFO[(item.extra as Record<string,string>).status_anterior]?.label ?? (item.extra as Record<string,string>).status_anterior}
                      </span>
                    </div>
                    <ArrowRight size={16} style={{ color: '#C8D5DC', flexShrink: 0 }} />
                    <div style={{ flex: 1 }}>
                      <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', color: '#A8B8C2', letterSpacing: '0.1em', marginBottom: '4px' }}>Para</p>
                      <span className={STATUS_INFO[(item.extra as Record<string,string>).status_novo]?.cls ?? 'badge-neutral'}>
                        {STATUS_INFO[(item.extra as Record<string,string>).status_novo]?.label ?? (item.extra as Record<string,string>).status_novo}
                      </span>
                    </div>
                  </div>
                )}

                {/* Descrição */}
                {item.descricao && (
                  <div>
                    <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#A8B8C2', marginBottom: '6px' }}>Descrição / Observação</p>
                    <p style={{ fontSize: '13px', color: '#0E1A33', lineHeight: 1.6, whiteSpace: 'pre-wrap' }}>{item.descricao}</p>
                  </div>
                )}

                {/* Foto */}
                {item.foto_url && (
                  <div>
                    <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#A8B8C2', marginBottom: '6px' }}>Foto Registrada</p>
                    <button onClick={() => { setSelectedPhoto({ url: item.foto_url!, titulo: item.titulo }); setSelectedTimelineItem(null) }}
                      className="relative overflow-hidden w-full transition-all active:scale-[0.99]"
                      style={{ height: '180px', backgroundColor: '#000' }}>
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img src={item.foto_url} alt={item.titulo} className="w-full h-full object-cover opacity-90 hover:opacity-100 transition-opacity" />
                      <div className="absolute bottom-2 right-2 flex items-center gap-1 px-2 py-1" style={{ backgroundColor: 'rgba(0,0,0,0.6)' }}>
                        <Camera size={10} color="#fff" />
                        <span style={{ fontSize: '9px', color: '#fff', fontWeight: 700 }}>Ampliar</span>
                      </div>
                    </button>
                  </div>
                )}

                {/* GPS */}
                {item.coordenadas && (
                  <div>
                    <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#A8B8C2', marginBottom: '6px' }}>Localização GPS</p>
                    <a href={`https://www.google.com/maps/search/?api=1&query=${item.coordenadas.lat},${item.coordenadas.lng}`}
                      target="_blank" rel="noopener noreferrer"
                      className="flex items-center gap-2 h-9 px-4 text-white font-black text-[10px] uppercase tracking-widest w-fit"
                      style={{ backgroundColor: '#1A294A', textDecoration: 'none' }}>
                      <MapPin size={12} /> Ver no Maps
                    </a>
                  </div>
                )}
              </div>

              <div className="px-5 py-3 border-t flex justify-end" style={{ borderColor: '#EEF0F5', backgroundColor: '#F8F9FB' }}>
                <button onClick={() => setSelectedTimelineItem(null)} className="btn-outline">Fechar</button>
              </div>
            </div>
          </div>
        )
      })()}

      {/* ── Modal: Checklist de Início ── */}
      {checklistModal && (() => {
        const checklists = (checklistModal.extra?.checklists ?? []) as ChecklistDetalhe[]
        const todasFotos = checklists.flatMap(c => c.respostas.filter(r => r.foto_url).map(r => ({ url: r.foto_url!, titulo: r.descricao_item })))
        return (
          <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center p-4" style={{ backgroundColor: 'rgba(14,26,51,0.75)' }}
            onClick={() => setChecklistModal(null)}>
            <div className="w-full max-w-2xl bg-white overflow-hidden animate-in slide-in-from-bottom-4 fade-in"
              style={{ boxShadow: '0 32px 80px rgba(0,0,0,0.3)', animationDuration: '250ms', maxHeight: '90vh', display: 'flex', flexDirection: 'column' }}
              onClick={e => e.stopPropagation()}>

              {/* Header */}
              <div className="px-5 py-4 flex items-center justify-between flex-shrink-0" style={{ backgroundColor: '#53648A' }}>
                <div className="flex items-center gap-3">
                  <div style={{ width: '36px', height: '36px', backgroundColor: 'rgba(255,255,255,0.15)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                    <ClipboardList size={18} color="#fff" />
                  </div>
                  <div>
                    <p style={{ fontSize: '9px', fontWeight: 900, letterSpacing: '0.15em', textTransform: 'uppercase', color: 'rgba(255,255,255,0.65)' }}>Checklist de Início</p>
                    <h3 className="font-black text-sm text-white" style={{ letterSpacing: '0.02em' }}>Detalhes Completos</h3>
                  </div>
                </div>
                <button onClick={() => setChecklistModal(null)}
                  style={{ width: '36px', height: '36px', backgroundColor: 'rgba(255,255,255,0.15)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', flexShrink: 0 }}>
                  <XCircle size={18} />
                </button>
              </div>

              {/* Horário + autor */}
              <div className="grid grid-cols-2 gap-px flex-shrink-0" style={{ backgroundColor: '#EEF1F7' }}>
                <div className="px-5 py-3" style={{ backgroundColor: '#F8F9FB' }}>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#A8B8C2' }}>Horário de Conclusão</p>
                  <p style={{ fontSize: '16px', fontWeight: 900, color: '#0E1A33', marginTop: '3px', fontVariantNumeric: 'tabular-nums' }}>
                    {new Date(checklistModal.data_hora).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                  </p>
                  <p style={{ fontSize: '11px', color: '#5A6A80', fontFamily: 'monospace' }}>
                    {new Date(checklistModal.data_hora).toLocaleDateString('pt-BR')}
                  </p>
                </div>
                <div className="px-5 py-3" style={{ backgroundColor: '#F8F9FB' }}>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#A8B8C2' }}>Responsável</p>
                  <p style={{ fontSize: '14px', fontWeight: 900, color: '#0E1A33', marginTop: '3px' }}>{checklistModal.usuario}</p>
                  <p style={{ fontSize: '11px', color: '#5A6A80' }}>{checklistModal.descricao}</p>
                </div>
              </div>

              {/* Corpo scrollável */}
              <div style={{ overflowY: 'auto', flex: 1, padding: '20px', display: 'flex', flexDirection: 'column', gap: '20px' }}>

                {/* Galeria de fotos */}
                {todasFotos.length > 0 && (
                  <div>
                    <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#A8B8C2', marginBottom: '10px' }}>
                      Fotos Registradas ({todasFotos.length})
                    </p>
                    <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
                      {todasFotos.map((f, fi) => (
                        <button key={fi} onClick={() => { setSelectedPhoto({ url: f.url, titulo: f.titulo }); setChecklistModal(null) }}
                          style={{ position: 'relative', width: '80px', height: '70px', overflow: 'hidden', border: '1.5px solid #DDE3EC', flexShrink: 0, backgroundColor: '#000' }}>
                          {/* eslint-disable-next-line @next/next/no-img-element */}
                          <img src={f.url} alt={f.titulo} style={{ width: '100%', height: '100%', objectFit: 'cover', opacity: 0.9 }} />
                          <div style={{ position: 'absolute', inset: 0, backgroundColor: 'rgba(26,41,74,0)', transition: 'background-color 0.15s' }}
                            onMouseEnter={e => (e.currentTarget as HTMLElement).style.backgroundColor = 'rgba(26,41,74,0.3)'}
                            onMouseLeave={e => (e.currentTarget as HTMLElement).style.backgroundColor = 'rgba(26,41,74,0)'} />
                        </button>
                      ))}
                    </div>
                  </div>
                )}

                {/* Um bloco por checklist */}
                {checklists.map((c, ci) => {
                  const conformes = c.respostas.filter(r => r.conforme).length
                  const total = c.respostas.length
                  const tipoLabel = c.tipo === 'viatura' ? 'Checklist de Viatura' : c.tipo === 'material' ? 'Checklist de Equipamentos (EPI)' : `Checklist — ${c.tipo}`
                  return (
                    <div key={ci}>
                      {/* Header da seção */}
                      <div className="cc-panel-header" style={{ marginBottom: '8px' }}>
                        <div style={{ width: '6px', height: '6px', backgroundColor: '#53648A', borderRadius: '50%', flexShrink: 0 }} />
                        {tipoLabel}
                        {c.placa && <span style={{ fontSize: '9px', fontFamily: 'monospace', color: '#ABB5C9' }}>· {formatarPlaca(c.placa)}</span>}
                        <span className="badge-info ml-auto">{conformes}/{total} conformes</span>
                      </div>

                      {c.respostas.length === 0 ? (
                        <p style={{ fontSize: '12px', color: '#A8B8C2', padding: '8px 0' }}>Nenhum item registrado</p>
                      ) : (
                        <div style={{ border: '1px solid #EEF1F7' }}>
                          {c.respostas.map((r, ri) => (
                            <div key={ri} style={{
                              display: 'flex', alignItems: 'flex-start', gap: '12px',
                              padding: '10px 14px',
                              borderBottom: ri < c.respostas.length - 1 ? '1px solid #EEF1F7' : 'none',
                              backgroundColor: r.conforme ? '#fff' : 'rgba(184,56,50,0.03)',
                            }}>
                              {/* Ícone conforme/não conforme */}
                              <div style={{ flexShrink: 0, marginTop: '1px' }}>
                                {r.conforme
                                  ? <CheckCircle2 size={15} style={{ color: '#1E7C52' }} />
                                  : <XCircle size={15} style={{ color: '#B83832' }} />
                                }
                              </div>
                              {/* Item */}
                              <div style={{ flex: 1, minWidth: 0 }}>
                                <p style={{ fontSize: '12px', fontWeight: 700, color: r.conforme ? '#0E1A33' : '#B83832', lineHeight: 1.4 }}>
                                  {r.descricao_item}
                                </p>
                                {!r.conforme && r.observacao && (
                                  <p style={{ fontSize: '11px', color: '#B83832', marginTop: '2px', fontStyle: 'italic' }}>{r.observacao}</p>
                                )}
                              </div>
                              {/* Miniatura */}
                              {r.foto_url && (
                                <button onClick={() => { setSelectedPhoto({ url: r.foto_url!, titulo: r.descricao_item }); setChecklistModal(null) }}
                                  style={{ flexShrink: 0, width: '44px', height: '36px', overflow: 'hidden', border: '1px solid #DDE3EC' }}>
                                  {/* eslint-disable-next-line @next/next/no-img-element */}
                                  <img src={r.foto_url} alt={r.descricao_item} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
                                </button>
                              )}
                            </div>
                          ))}
                        </div>
                      )}
                    </div>
                  )
                })}
              </div>

              {/* Footer */}
              <div className="px-5 py-3 border-t flex justify-end" style={{ borderColor: '#EEF0F5', backgroundColor: '#F8F9FB', flexShrink: 0 }}>
                <button onClick={() => setChecklistModal(null)} className="btn-outline">Fechar</button>
              </div>
            </div>
          </div>
        )
      })()}

      {/* ── Dialog: Avançar Status ── */}
      {dialogAvanco && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-md rounded bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)' }}>
            <div className="px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="font-bold text-base" style={{ color: '#1E2D35' }}>{proximo?.label}</h2>
            </div>
            <div className="px-6 py-5 space-y-4">
              {erro && (
                <p className="text-xs p-3 rounded" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}
              <p className="text-sm" style={{ color: '#6B7E8A' }}>
                Alterar de <strong style={{ color: '#1E2D35' }}>{si.label}</strong> para{' '}
                <strong style={{ color: '#1E2D35' }}>{proximo ? STATUS_INFO[proximo.status]?.label : ''}</strong>.
              </p>
              <div>
                <label className="block text-xs font-semibold mb-1.5" style={{ color: '#6B7E8A' }}>Observação (opcional)</label>
                <TextAreaWithTools
                  value={motivoAvanco}
                  onChange={(v) => setMotivoAvanco(v)}
                  placeholder="Informe uma observação..."
                  rows={2}
                  textareaClassName="input-light resize-none"
                  contextoAI="Observação de avanço de status da escolta armada"
                />
              </div>
            </div>
            <div className="px-6 py-4 border-t flex justify-end gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button onClick={() => setDialogAvanco(false)} className="btn-outline">Cancelar</button>
              <button onClick={avancarStatus} disabled={avancando} className="btn-gradient">
                {avancando ? 'Processando...' : 'Confirmar'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Cancelar / Reagendar ── */}
      {dialogCancelar && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-md bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.2)' }}>
            {/* Header */}
            <div className="px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="font-bold text-base" style={{ color: '#1E2D35' }}>O que deseja fazer com esta escolta?</h2>
              <p className="text-xs mt-0.5" style={{ color: '#8B9BAD' }}>{escolta.codigo_escolta} — {escolta.cliente?.nome_cliente}</p>
            </div>

            {/* Seleção de ação */}
            <div className="grid grid-cols-2 gap-0 border-b" style={{ borderColor: '#E2E8EC' }}>
              <button
                onClick={() => { setAbaDialogCancelar('cancelar'); setErro(null) }}
                className="py-3 text-xs font-black uppercase tracking-widest transition-colors"
                style={{
                  backgroundColor: abaDialogCancelar === 'cancelar' ? '#FEF0EE' : '#F8F9FB',
                  color: abaDialogCancelar === 'cancelar' ? '#B83832' : '#8B9BAD',
                  borderBottom: abaDialogCancelar === 'cancelar' ? '2px solid #B83832' : '2px solid transparent',
                }}
              >
                <XCircle size={13} className="inline mr-1.5" style={{ verticalAlign: '-2px' }} />
                Cancelar Escolta
              </button>
              <button
                onClick={() => { setAbaDialogCancelar('reagendar'); setErro(null) }}
                className="py-3 text-xs font-black uppercase tracking-widest transition-colors"
                style={{
                  backgroundColor: abaDialogCancelar === 'reagendar' ? 'rgba(83,100,138,0.07)' : '#F8F9FB',
                  color: abaDialogCancelar === 'reagendar' ? '#1A294A' : '#8B9BAD',
                  borderBottom: abaDialogCancelar === 'reagendar' ? '2px solid #1A294A' : '2px solid transparent',
                }}
              >
                <CalendarClock size={13} className="inline mr-1.5" style={{ verticalAlign: '-2px' }} />
                Reagendar
              </button>
            </div>

            <div className="px-6 py-5 space-y-4">
              {erro && (
                <p className="text-xs p-3" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}

              {/* ABA: Cancelar */}
              {abaDialogCancelar === 'cancelar' && (
                <>
                  <div className="flex items-start gap-3 p-3" style={{ backgroundColor: '#FEF0EE' }}>
                    <XCircle size={15} style={{ color: '#B83832', flexShrink: 0, marginTop: 1 }} />
                    <p className="text-xs font-semibold" style={{ color: '#B83832' }}>
                      Esta ação é irreversível. A escolta será marcada como cancelada e registrada no histórico.
                    </p>
                  </div>
                  <div>
                    <label className="block text-xs font-bold mb-1.5 uppercase tracking-wide" style={{ color: '#6B7E8A' }}>Motivo do Cancelamento *</label>
                    <TextAreaWithTools
                      value={motivoCancelamento}
                      onChange={(v) => setMotivoCancelamento(v)}
                      placeholder="Descreva o motivo do cancelamento..."
                      rows={4}
                      textareaClassName="input-light resize-none"
                      contextoAI="Motivo de cancelamento de escolta armada"
                    />
                  </div>
                </>
              )}

              {/* ABA: Reagendar */}
              {abaDialogCancelar === 'reagendar' && (
                <>
                  <div className="flex items-start gap-3 p-3" style={{ backgroundColor: 'rgba(83,100,138,0.07)', border: '1px solid rgba(83,100,138,0.15)' }}>
                    <CalendarClock size={15} style={{ color: '#53648A', flexShrink: 0, marginTop: 1 }} />
                    <p className="text-xs font-semibold" style={{ color: '#1A294A' }}>
                      A escolta será reagendada para a nova data. O motivo e o histórico de alteração serão registrados.
                    </p>
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <label className="block text-xs font-bold mb-1.5 uppercase tracking-wide" style={{ color: '#6B7E8A' }}>Nova Data *</label>
                      <input
                        type="date"
                        value={novaDataReagendamento}
                        onChange={(e) => setNovaDataReagendamento(e.target.value)}
                        min={new Date().toISOString().split('T')[0]}
                        className="input-light w-full text-sm"
                      />
                    </div>
                    <div>
                      <label className="block text-xs font-bold mb-1.5 uppercase tracking-wide" style={{ color: '#6B7E8A' }}>Horário *</label>
                      <input
                        type="time"
                        value={novaHoraReagendamento}
                        onChange={(e) => setNovaHoraReagendamento(e.target.value)}
                        className="input-light w-full text-sm"
                      />
                    </div>
                  </div>
                  <div>
                    <label className="block text-xs font-bold mb-1.5 uppercase tracking-wide" style={{ color: '#6B7E8A' }}>Motivo do Reagendamento *</label>
                    <TextAreaWithTools
                      value={motivoReagendamento}
                      onChange={(v) => setMotivoReagendamento(v)}
                      placeholder="Descreva o motivo do reagendamento..."
                      rows={3}
                      textareaClassName="input-light resize-none"
                      contextoAI="Motivo de reagendamento de escolta armada"
                    />
                  </div>
                </>
              )}
            </div>

            <div className="px-6 py-4 border-t flex justify-between items-center" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button
                onClick={() => { setDialogCancelar(false); setErro(null); setAbaDialogCancelar('cancelar') }}
                className="btn-outline"
              >
                Fechar
              </button>
              {abaDialogCancelar === 'cancelar' ? (
                <button onClick={cancelarEscolta} disabled={cancelando} className="btn-danger">
                  {cancelando ? 'Cancelando...' : 'Confirmar Cancelamento'}
                </button>
              ) : (
                <button
                  onClick={reagendarEscolta}
                  disabled={cancelando}
                  className="text-white font-black text-[10px] uppercase tracking-widest px-5 py-2 flex items-center gap-1.5 transition-all active:scale-95"
                  style={{ backgroundColor: '#1A294A' }}
                  onMouseEnter={e => (e.currentTarget as HTMLElement).style.backgroundColor = '#253562'}
                  onMouseLeave={e => (e.currentTarget as HTMLElement).style.backgroundColor = '#1A294A'}
                >
                  <CalendarClock size={13} /> Confirmar Reagendamento
                </button>
              )}
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Start Base (Sair da Base) ── */}
      {dialogStartBase && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-md rounded bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)' }}>
            <div className="px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="font-bold text-base text-[#0E1A33]">Iniciar Operação (Saída da Base)</h2>
            </div>
            <div className="px-6 py-5 space-y-4">
              {erro && (
                <p className="text-xs p-3" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}
              <div className="flex items-center gap-2 p-3" style={{ backgroundColor: '#F5F7FA' }}>
                <Clock size={13} style={{ color: '#53648A', flexShrink: 0 }} />
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#A8B8C2' }}>Data/Hora do Registro</p>
                  <p style={{ fontSize: '12px', fontWeight: 900, color: '#0E1A33' }}>{nowLocalStr()}</p>
                </div>
              </div>
              <p className="text-sm text-[#5A6A80]">
                Registre as informações de partida para iniciar a escolta em trânsito.
              </p>
              
              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Foto da Viatura na Base *</label>
                <CameraInput onChange={(fs) => setFotoStartBase(fs[0] ?? null)} />
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">KM de Saída da Viatura</label>
                <input
                  type="number"
                  value={kmStartBase}
                  onChange={(e) => setKmStartBase(e.target.value)}
                  placeholder="Ex: 104500"
                  className="input-light w-full"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Observações de Partida *</label>
                <TextAreaWithTools
                  value={obsStartBase}
                  onChange={(v) => setObsStartBase(v)}
                  placeholder="Descreva observações da saída..."
                  rows={2}
                  textareaClassName="input-light resize-none"
                  contextoAI="Observações de partida da base em escolta armada"
                />
              </div>
            </div>
            <div className="px-6 py-4 border-t flex justify-end gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button onClick={() => setDialogStartBase(false)} className="btn-outline">Cancelar</button>
              <button
                onClick={handleStartBase}
                disabled={loading}
                className="btn-gradient"
              >
                {loading ? 'Confirmando...' : 'Confirmar Saída'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Check-in Periódico ── */}
      {dialogCheckin && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-md rounded bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)' }}>

            {/* Header */}
            <div className="px-6 py-4 border-b flex items-center gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F0FAF5' }}>
              <div className="w-8 h-8 rounded-full flex items-center justify-center" style={{ backgroundColor: '#1E7C52' }}>
                <Radio size={14} className="text-white" />
              </div>
              <div>
                <h2 className="font-bold text-sm text-[#0E1A33]">Check-in Operacional</h2>
                <p style={{ fontSize: '10px', color: '#5A6A80' }}>{nowLocalStr()}</p>
              </div>
            </div>

            <div className="px-6 py-5 space-y-4 overflow-y-auto" style={{ maxHeight: '75vh' }}>
              {erro && (
                <p className="text-xs p-3" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}

              {/* GPS Status */}
              <div className="p-3 rounded" style={{ backgroundColor: gpsCheckin ? '#F0FAF5' : '#F5F7FA', border: `1.5px solid ${gpsCheckin ? '#1E7C5240' : '#E2E8EC'}` }}>
                <div className="flex items-start gap-2">
                  <Locate size={13} style={{ color: gpsCheckin ? '#1E7C52' : '#A8B8C2', flexShrink: 0, marginTop: '2px' }} />
                  <div className="flex-1 min-w-0">
                    <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: gpsCheckin ? '#1E7C52' : '#A8B8C2' }}>
                      {gpsCheckinLoading ? 'Obtendo localização...' : gpsCheckin ? 'Localização capturada' : 'Localização não disponível'}
                    </p>
                    {gpsCheckin && (
                      <>
                        <p style={{ fontSize: '11px', fontWeight: 600, color: '#0E1A33', marginTop: '2px', lineHeight: 1.4 }}>{gpsCheckin.endereco}</p>
                        <p style={{ fontSize: '9px', color: '#A8B8C2', marginTop: '2px' }}>
                          {gpsCheckin.lat.toFixed(6)}, {gpsCheckin.lng.toFixed(6)} · ±{gpsCheckin.precisao.toFixed(0)}m
                        </p>
                      </>
                    )}
                    {gpsCheckinLoading && (
                      <div className="flex items-center gap-1.5 mt-1">
                        <div className="animate-spin" style={{ width: '10px', height: '10px', border: '1.5px solid #D6DAE5', borderTopColor: '#1E7C52', borderRadius: '50%' }} />
                        <span style={{ fontSize: '10px', color: '#A8B8C2' }}>Aguardando GPS e endereço...</span>
                      </div>
                    )}
                    {!gpsCheckinLoading && !gpsCheckin && (
                      <button
                        type="button"
                        onClick={abrirDialogCheckin}
                        style={{ fontSize: '10px', color: '#1E7C52', marginTop: '4px', textDecoration: 'underline' }}
                      >
                        Tentar novamente
                      </button>
                    )}
                  </div>
                </div>
              </div>

              {/* Foto */}
              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Foto do Local / Situação *</label>
                <CameraInput onChange={(fs) => setFotoCheckin(fs[0] ?? null)} max={1} prefixoNome="checkin" />
              </div>

              {/* Observações */}
              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Observações (opcional)</label>
                <TextAreaWithTools
                  value={obsCheckin}
                  onChange={(v) => setObsCheckin(v)}
                  placeholder="Informe qualquer detalhe relevante da situação atual..."
                  rows={3}
                  textareaClassName="input-light resize-none"
                  contextoAI="Check-in de escolta armada em rota"
                />
              </div>
            </div>

            <div className="px-6 py-4 border-t flex justify-end gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button onClick={() => { setDialogCheckin(false); setErro(null) }} className="btn-outline">Cancelar</button>
              <button
                onClick={handleCheckin}
                disabled={loading || gpsCheckinLoading || !gpsCheckin}
                className="h-9 px-5 font-black text-[10px] uppercase tracking-widest text-white active:scale-95 transition-all disabled:opacity-50"
                style={{ backgroundColor: '#1E7C52' }}
              >
                {loading ? 'Registrando...' : 'Confirmar Check-in'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Parada ── */}
      {dialogParada && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-md rounded bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)' }}>
            <div className="px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="font-bold text-base text-[#0E1A33]">Registrar Parada na Rota</h2>
            </div>
            <div className="px-6 py-5 space-y-4">
              {erro && (
                <p className="text-xs p-3" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}
              <div className="flex items-center gap-2 p-3" style={{ backgroundColor: '#F5F7FA' }}>
                <Clock size={13} style={{ color: '#53648A', flexShrink: 0 }} />
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#A8B8C2' }}>Data/Hora do Registro</p>
                  <p style={{ fontSize: '12px', fontWeight: 900, color: '#0E1A33' }}>{nowLocalStr()}</p>
                </div>
              </div>
              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Tipo de Parada *</label>
                <select
                  value={tipoParada}
                  onChange={(e) => setTipoParada(e.target.value)}
                  className="input-light w-full"
                >
                  {TIPOS_PARADA.map(t => (
                    <option key={t.value} value={t.value}>{t.label}</option>
                  ))}
                </select>
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Fotos da Parada (até 4) *</label>
                <CameraInput onChange={(fs) => setFotosParada(fs)} max={4} prefixoNome="parada" />
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Justificativa da Parada *</label>
                <TextAreaWithTools
                  value={obsParada}
                  onChange={(v) => setObsParada(v)}
                  placeholder="Escreva o motivo da parada ou observações..."
                  rows={3}
                  textareaClassName="input-light resize-none"
                  contextoAI="Justificativa de parada em escolta armada"
                />
              </div>
            </div>
            <div className="px-6 py-4 border-t flex justify-end gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button onClick={() => setDialogParada(false)} className="btn-outline">Cancelar</button>
              <button
                onClick={handleParada}
                disabled={loading}
                className="btn-gradient"
              >
                {loading ? 'Gravando...' : 'Registrar Parada'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Chegada na Origem ── */}
      {dialogChegadaOrigem && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-md rounded bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)' }}>
            <div className="px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="font-bold text-base text-[#0E1A33]">Confirmar Chegada na Origem</h2>
            </div>
            <div className="px-6 py-5 space-y-4">
              {erro && (
                <p className="text-xs p-3" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}
              <div className="flex items-center gap-2 p-3" style={{ backgroundColor: '#F5F7FA' }}>
                <Clock size={13} style={{ color: '#53648A', flexShrink: 0 }} />
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#A8B8C2' }}>Data/Hora do Registro</p>
                  <p style={{ fontSize: '12px', fontWeight: 900, color: '#0E1A33' }}>{nowLocalStr()}</p>
                </div>
              </div>
              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Foto do Local de Origem *</label>
                <CameraInput onChange={(fs) => setFotoOrigem(fs[0] ?? null)} />
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Opções de Chegada</label>
                <div className="space-y-2">
                  {[
                    'Cliente pronto para embarque',
                    'Viatura estacionada em local seguro',
                    'Carga verificada e lacrada',
                  ].map((opcao) => (
                    <label key={opcao} className="flex items-center gap-2 text-xs text-[#5A6A80] cursor-pointer">
                      <input
                        type="checkbox"
                        checked={opcoesOrigem.includes(opcao)}
                        onChange={(e) => {
                          if (e.target.checked) {
                            setOpcoesOrigem([...opcoesOrigem, opcao])
                          } else {
                            setOpcoesOrigem(opcoesOrigem.filter((o) => o !== opcao))
                          }
                        }}
                        className="rounded border-[#E2E8EC] text-[#53648A] focus:ring-[#53648A]"
                      />
                      {opcao}
                    </label>
                  ))}
                </div>
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Observações de Chegada *</label>
                <TextAreaWithTools
                  value={obsOrigem}
                  onChange={(v) => setObsOrigem(v)}
                  placeholder="Relatório ou observações adicionais..."
                  rows={2}
                  textareaClassName="input-light resize-none"
                  contextoAI="Observações de chegada na origem em escolta armada"
                />
              </div>
            </div>
            <div className="px-6 py-4 border-t flex justify-end gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button onClick={() => setDialogChegadaOrigem(false)} className="btn-outline">Cancelar</button>
              <button
                onClick={handleChegadaOrigem}
                disabled={loading}
                className="btn-gradient"
              >
                {loading ? 'Confirmando...' : 'Confirmar Chegada'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Chegada no Destino ── */}
      {dialogChegadaDestino && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-md rounded bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)' }}>
            <div className="px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="font-bold text-base text-[#0E1A33]">Confirmar Chegada no Destino</h2>
            </div>
            <div className="px-6 py-5 space-y-4">
              {erro && (
                <p className="text-xs p-3" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}
              <div className="flex items-center gap-2 p-3" style={{ backgroundColor: '#F5F7FA' }}>
                <Clock size={13} style={{ color: '#53648A', flexShrink: 0 }} />
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#A8B8C2' }}>Data/Hora do Registro</p>
                  <p style={{ fontSize: '12px', fontWeight: 900, color: '#0E1A33' }}>{nowLocalStr()}</p>
                </div>
              </div>
              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Foto do Local de Entrega/Destino *</label>
                <CameraInput onChange={(fs) => setFotoDestino(fs[0] ?? null)} />
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Observações de Destino *</label>
                <TextAreaWithTools
                  value={obsDestino}
                  onChange={(v) => setObsDestino(v)}
                  placeholder="Relatório ou observações adicionais sobre o destino..."
                  rows={3}
                  textareaClassName="input-light resize-none"
                  contextoAI="Observações de chegada no destino em escolta armada"
                />
              </div>
            </div>
            <div className="px-6 py-4 border-t flex justify-end gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button onClick={() => setDialogChegadaDestino(false)} className="btn-outline">Cancelar</button>
              <button
                onClick={handleChegadaDestino}
                disabled={loading}
                className="btn-gradient"
              >
                {loading ? 'Confirmando...' : 'Confirmar Chegada'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Iniciar Retorno ── */}
      {dialogIniciarRetorno && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-md rounded bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)' }}>
            <div className="px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="font-bold text-base text-[#0E1A33]">Iniciar Retorno da Escolta</h2>
            </div>
            <div className="px-6 py-5 space-y-4">
              {erro && (
                <p className="text-xs p-3 rounded" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}
              <p className="text-sm text-[#5A6A80]">
                Confirmar que a equipe iniciou a rota de regresso à base operacional.
              </p>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Foto de Início de Retorno *</label>
                <CameraInput onChange={(fs) => setFotoRetorno(fs[0] ?? null)} />
              </div>
              
              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Observações / Justificativa *</label>
                <TextAreaWithTools
                  value={obsRetorno}
                  onChange={(v) => setObsRetorno(v)}
                  placeholder="Digite observações sobre a rota de retorno..."
                  rows={3}
                  textareaClassName="input-light resize-none"
                  contextoAI="Observações de retorno em escolta armada"
                />
              </div>
            </div>
            <div className="px-6 py-4 border-t flex justify-end gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button onClick={() => setDialogIniciarRetorno(false)} className="btn-outline">Cancelar</button>
              <button
                onClick={handleIniciarRetorno}
                disabled={loading}
                className="btn-gradient"
              >
                {loading ? 'Iniciando...' : 'Confirmar Retorno'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Chegada na Base ── */}
      {dialogChegadaBase && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-md rounded bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)' }}>
            <div className="px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="font-bold text-base text-[#0E1A33]">Confirmar Chegada na Base (Retorno)</h2>
            </div>
            <div className="px-6 py-5 space-y-4">
              {erro && (
                <p className="text-xs p-3 rounded" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Foto de Chegada na Base *</label>
                <CameraInput onChange={(fs) => setFotoChegadaBase(fs[0] ?? null)} />
              </div>
              
              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">KM de Chegada / Retorno *</label>
                <input
                  type="number"
                  value={kmChegadaBase}
                  onChange={(e) => setKmChegadaBase(e.target.value)}
                  placeholder="Ex: 104650"
                  className="input-light w-full"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Observações / Justificativa *</label>
                <TextAreaWithTools
                  value={obsChegadaBase}
                  onChange={(v) => setObsChegadaBase(v)}
                  placeholder="Observações da chegada..."
                  rows={2}
                  textareaClassName="input-light resize-none"
                  contextoAI="Observações de chegada na base em escolta armada"
                />
              </div>
            </div>
            <div className="px-6 py-4 border-t flex justify-end gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button onClick={() => setDialogChegadaBase(false)} className="btn-outline">Cancelar</button>
              <button
                onClick={handleChegadaBase}
                disabled={loading}
                className="btn-gradient"
              >
                {loading ? 'Confirmando...' : 'Confirmar Chegada'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Finalizacao ── */}
      {dialogFinalizacao && (
        <div className="fixed inset-0 z-40 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }}>
          <div className="w-full max-w-lg rounded bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)' }}>
            <div className="px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="font-bold text-base text-[#0E1A33]">Finalizar Escolta e Relatório Diário</h2>
            </div>
            <div className="px-6 py-5 space-y-4 max-h-[70vh] overflow-y-auto">
              {erro && (
                <p className="text-xs p-3 rounded" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>
              )}
              
              {/* Fotos obrigatórias — entrega de viatura */}
              <div>
                <div className="flex items-center gap-2 mb-3 pb-2" style={{ borderBottom: '1px solid #EEF1F7' }}>
                  <div style={{ width: '3px', height: '14px', backgroundColor: '#1A294A' }} />
                  <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: '#1A294A' }}>Registro Fotográfico — Entrega da Viatura</span>
                </div>
                <p className="text-[11px] mb-3" style={{ color: '#7A8FA6' }}>
                  Fotografe a viatura em <strong>5 ângulos obrigatórios</strong> para registrar as condições de entrega.
                </p>
                <div className="grid grid-cols-1 gap-3">
                  {FOTOS_VIATURA_DEF.map((def) => {
                    const temFoto = !!fotosViaturaFinal[def.key]
                    return (
                      <div key={def.key} style={{ border: `1.5px solid ${temFoto ? '#1E7C52' : '#D6DAE5'}`, padding: '10px', backgroundColor: temFoto ? 'rgba(30,124,82,0.04)' : '#F8FAFC' }}>
                        <div className="flex items-center gap-2 mb-2">
                          {temFoto
                            ? <CheckCircle2 size={13} style={{ color: '#1E7C52', flexShrink: 0 }} />
                            : <Camera size={13} style={{ color: '#B83832', flexShrink: 0 }} />
                          }
                          <span className="text-xs font-black uppercase tracking-wide" style={{ color: temFoto ? '#1E7C52' : '#B83832' }}>
                            {def.label} {temFoto ? '— OK' : '— Obrigatória *'}
                          </span>
                        </div>
                        <CameraInput
                          prefixoNome={`final_${def.key}`}
                          onChange={(fs) => setFotosViaturaFinal(prev => ({ ...prev, [def.key]: fs[0] ?? null }))}
                        />
                      </div>
                    )
                  })}
                </div>
                <div className="flex items-center gap-2 mt-2 px-1">
                  <div style={{ width: '8px', height: '8px', flexShrink: 0, backgroundColor: FOTOS_VIATURA_DEF.every(f => fotosViaturaFinal[f.key]) ? '#1E7C52' : '#B83832' }} />
                  <span className="text-[10px] font-bold" style={{ color: FOTOS_VIATURA_DEF.every(f => fotosViaturaFinal[f.key]) ? '#1E7C52' : '#B83832' }}>
                    {FOTOS_VIATURA_DEF.filter(f => fotosViaturaFinal[f.key]).length} / 5 fotos registradas
                  </span>
                </div>
              </div>

              {/* Checklist de entrega de viatura */}
              <div className="bg-[#53648A]/5 p-3 border border-[#53648A]/15">
                <h3 className="text-xs font-bold text-[#53648A] uppercase tracking-wider mb-2">Checklist de Entrega de Viatura</h3>
                <div className="space-y-3 divide-y divide-[#E2E8EC]">
                  {[
                    { key: 'pneus',      label: 'Pneus e estepe calibrados?' },
                    { key: 'oleo_agua',  label: 'Nível de óleo e água?' },
                    { key: 'farois',     label: 'Faróis e sirene funcionando?' },
                    { key: 'armamentos', label: 'Armamentos e munições conferidos?' },
                    { key: 'limpeza',    label: 'Limpeza e conservação geral?' },
                  ].map((item) => (
                    <div key={item.key} className="pt-2.5 first:pt-0">
                      <div className="flex items-center justify-between">
                        <span className="text-xs text-[#0E1A33] font-semibold">{item.label}</span>
                        <div className="flex gap-2">
                          <button
                            type="button"
                            onClick={() => setChecklistFinal(prev => ({ ...prev, [item.key]: { ...prev[item.key], resposta: true } }))}
                            className={`px-2 py-1 rounded text-[10px] font-bold border transition-colors ${
                              checklistFinal[item.key]?.resposta === true
                                ? 'bg-green-500/10 text-green-600 border-green-500/30'
                                : 'bg-[#F8F9FB] text-slate-400 border-[#E2E8EC]'
                            }`}
                          >Sim</button>
                          <button
                            type="button"
                            onClick={() => setChecklistFinal(prev => ({ ...prev, [item.key]: { ...prev[item.key], resposta: false } }))}
                            className={`px-2 py-1 rounded text-[10px] font-bold border transition-colors ${
                              checklistFinal[item.key]?.resposta === false
                                ? 'bg-red-500/10 text-red-600 border-red-500/30'
                                : 'bg-[#F8F9FB] text-slate-400 border-[#E2E8EC]'
                            }`}
                          >Não</button>
                        </div>
                      </div>
                      {checklistFinal[item.key]?.resposta === false && (
                        <input
                          type="text"
                          value={checklistFinal[item.key]?.obs || ''}
                          onChange={(e) => setChecklistFinal(prev => ({ ...prev, [item.key]: { ...prev[item.key], obs: e.target.value } }))}
                          placeholder="Informe a irregularidade..."
                          className="input-light w-full text-xs h-8 mt-1.5"
                        />
                      )}
                    </div>
                  ))}
                </div>
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Relatório Diário da Operação *</label>
                <TextAreaWithTools
                  value={relatorioFinal}
                  onChange={(v) => setRelatorioFinal(v)}
                  placeholder="Redija o relatório sobre o andamento e as informações do dia..."
                  rows={4}
                  textareaClassName="input-light resize-none"
                  contextoAI="Relatório diário da operação de escolta armada"
                />
              </div>
            </div>
            <div className="px-6 py-4 border-t flex justify-end gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button onClick={() => setDialogFinalizacao(false)} className="btn-outline">Cancelar</button>
              <button
                onClick={handleFinalizacao}
                disabled={loading}
                className="btn-gradient"
              >
                {loading ? 'Finalizando...' : 'Finalizar Operação'}
              </button>
            </div>
          </div>
        </div>
      )}

        </>
      )}

      {/* ── Modal: Detalhe da Parada ── */}
      {paradaSelecionada && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4" style={{ backgroundColor: 'rgba(28,43,53,0.7)' }}>
          <div className="w-full max-w-md bg-white overflow-hidden" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.25)', maxHeight: '90vh', overflowY: 'auto' }}>
            <div className="px-5 py-4 border-b flex items-center justify-between" style={{ borderColor: '#E2E8EC', backgroundColor: '#1A294A' }}>
              <div>
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.14em', color: 'rgba(255,255,255,0.45)' }}>Detalhe da Parada</p>
                <h3 style={{ fontSize: '14px', fontWeight: 900, color: '#fff', marginTop: '2px' }}>{paradaSelecionada.tipoLabel}</h3>
              </div>
              <button type="button" onClick={() => setParadaSelecionada(null)} style={{ color: 'rgba(255,255,255,0.55)', background: 'none', border: 'none', cursor: 'pointer', fontSize: '22px', lineHeight: 1, padding: '0 4px' }}>×</button>
            </div>
            <div className="p-5 space-y-4">
              <div className="flex items-center gap-2 p-3" style={{ backgroundColor: '#F5F7FA' }}>
                <Clock size={13} style={{ color: '#53648A' }} />
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#A8B8C2' }}>Data / Hora</p>
                  <p style={{ fontSize: '13px', fontWeight: 900, color: '#0E1A33' }}>
                    {new Date(paradaSelecionada.data_hora).toLocaleDateString('pt-BR')} às {new Date(paradaSelecionada.data_hora).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                  </p>
                </div>
              </div>
              <div>
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#5A6A80', marginBottom: '4px' }}>Tipo de Parada</p>
                <span className="badge-base" style={{ backgroundColor: `${TIPOS_PARADA.find(t => t.value === paradaSelecionada.tipo)?.cor ?? '#53648A'}15`, color: TIPOS_PARADA.find(t => t.value === paradaSelecionada.tipo)?.cor ?? '#53648A', borderColor: `${TIPOS_PARADA.find(t => t.value === paradaSelecionada.tipo)?.cor ?? '#53648A'}35` }}>
                  {paradaSelecionada.tipoLabel}
                </span>
              </div>
              {paradaSelecionada.justificativa && (
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#5A6A80', marginBottom: '4px' }}>Justificativa</p>
                  <p style={{ fontSize: '13px', color: '#0E1A33', lineHeight: 1.5 }}>{paradaSelecionada.justificativa}</p>
                </div>
              )}
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#5A6A80', marginBottom: '4px' }}>Registrado por</p>
                  <p style={{ fontSize: '12px', fontWeight: 700, color: '#0E1A33' }}>{paradaSelecionada.autor}</p>
                </div>
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#5A6A80', marginBottom: '4px' }}>Veículo</p>
                  <p style={{ fontSize: '12px', fontWeight: 700, color: '#0E1A33' }}>{paradaSelecionada.veiculo}</p>
                </div>
              </div>
              {paradaSelecionada.latitude && (
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#5A6A80', marginBottom: '4px' }}>Localização GPS</p>
                  <p style={{ fontSize: '11px', color: '#5A6A80', fontFamily: 'monospace' }}>{paradaSelecionada.latitude.toFixed(6)}, {paradaSelecionada.longitude?.toFixed(6)}</p>
                </div>
              )}
              {paradaSelecionada.fotoUrls.length > 0 && (
                <div>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#5A6A80', marginBottom: '6px' }}>Fotos ({paradaSelecionada.fotoUrls.length})</p>
                  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: '6px' }}>
                    {paradaSelecionada.fotoUrls.map((url, idx) => (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img key={idx} src={url} alt={`Foto ${idx + 1}`}
                        style={{ width: '100%', aspectRatio: '4/3', objectFit: 'cover', cursor: 'pointer' }}
                        onClick={() => setSelectedPhoto({ url, titulo: `Parada — ${paradaSelecionada.tipoLabel}` })} />
                    ))}
                  </div>
                </div>
              )}
            </div>
            <div className="px-5 py-4 border-t" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
              <button type="button" onClick={() => setParadaSelecionada(null)} className="btn-outline w-full">Fechar</button>
            </div>
          </div>
        </div>
      )}

      {/* ── Lightbox ── */}
      {selectedPhoto && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center p-4 cursor-pointer"
          style={{ backgroundColor: 'rgba(0,0,0,0.85)' }}
          onClick={() => setSelectedPhoto(null)}
        >
          <div className="relative max-w-2xl w-full cursor-default" onClick={(e) => e.stopPropagation()}>
            <button
              onClick={() => setSelectedPhoto(null)}
              className="absolute -top-9 right-0 text-sm transition-colors"
              style={{ color: 'rgba(255,255,255,0.6)' }}
              onMouseEnter={(e) => { (e.currentTarget as HTMLElement).style.color = '#fff' }}
              onMouseLeave={(e) => { (e.currentTarget as HTMLElement).style.color = 'rgba(255,255,255,0.6)' }}
            >
              Fechar ✕
            </button>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={selectedPhoto.url} alt={selectedPhoto.titulo} className="w-full rounded" />
            <p className="text-center text-sm mt-2" style={{ color: 'rgba(255,255,255,0.6)' }}>{selectedPhoto.titulo}</p>
          </div>
        </div>
      )}

    </div>
  )
}
