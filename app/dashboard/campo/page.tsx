'use client'

import { useEffect, useState, useRef, useCallback } from 'react'
import {
  MapPin, Camera, ClipboardList, CheckCircle2, AlertTriangle,
  Zap, X, Check, ChevronDown, ChevronRight,
  Shield, Navigation, Home, Package, Flag, RotateCcw,
  Clock, User, Crosshair
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import {
  PROXIMO_STATUS as PROXIMO_STATUS_FLUXO,
  STATUS,
  FOTOS_POR_PONTO,
  rotuloStatus,
} from '@/lib/fluxo-escolta'
import { TEXTO_PADRAO_ETAPA, PLACEHOLDER, ehTextoPadrao } from '@/lib/textos-padrao'
import { serializarObservacao } from '@/lib/pontos-controle'
import { useAuth } from '@/hooks/useAuth'
import { AiTextButton } from '@/components/ui/ai-text-button'

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
  BASE_SAIDA:       '18ce0259-8471-46ac-bc12-6602678fa910',
  ORIGEM:           'e1aec874-4d4e-4aa2-bae2-de4e711a9f9f',
  TRANSITO_DESTINO: '86935442-a8d5-4a06-8664-ad51bf7d1e5c',
  DESTINO:          'e4623e3e-a210-4c17-942a-80f01cc28f2d',
  TRANSITO_RETORNO: 'fb0dfca6-5495-4009-aff8-4fb279c4b7fc',
  RETORNO:          '4316fb15-8abe-4cfb-a605-753134178225',
  BASE_RETORNO:     'c9bc3e19-d55d-4174-8acb-12fe1e2b50b7',
}

// Ao avançar para o status X, qual ponto foi atingido?
const STATUS_TO_TIPO_PONTO: Record<string, string> = {
  em_andamento:        TIPO_PONTO.BASE_SAIDA,
  na_origem:           TIPO_PONTO.ORIGEM,
  em_transito_destino: TIPO_PONTO.TRANSITO_DESTINO,
  no_destino:          TIPO_PONTO.DESTINO,
  em_transito_retorno: TIPO_PONTO.TRANSITO_RETORNO,
  retornando:          TIPO_PONTO.RETORNO,
  na_base:             TIPO_PONTO.BASE_RETORNO,
}

// Etapas que o fluxo nao associa a ponto de controle nenhum. Sem ponto nao ha quem
// referencie a foto, entao nelas a foto nao e exigida nem enviada. Constante de
// modulo porque a regra vale nos dois lugares: na validacao e no que a tela mostra.
//
// 'finalizada' saiu daqui junto com a saida de na_base do PROXIMO_STATUS: esta tela
// nao finaliza mais escolta, entao a excecao virou letra morta e manter uma excecao
// morta e o que faz alguem reintroduzir o caminho por engano.
const SEM_PONTO_DE_CONTROLE = ['em_pre_inicio']

// ─── Types ────────────────────────────────────────────────────────────────────
interface ViaturaEscolta {
  id: string
  placa: string | null
  modelo: string | null
}

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
  // So o ramo administrativo preenche esta lista. O vigilante ja chega vinculado a uma
  // viatura pelo efetivo, e para ele nao existe escolha a fazer.
  viaturas?: ViaturaEscolta[]
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
// Derivado de lib/fluxo-escolta.ts. Antes esta tela tinha o proprio mapa, que
// omitia a etapa de transito de retorno: a escolta travava aqui e, pior, o
// codigo nao lia o erro do update e gravava historico de uma transicao que
// o banco tinha recusado.
// A cor e a unica coisa que continua local: ela pertence a esta tela, nao ao fluxo.
const COR_AVANCO: Record<string, string> = {
  em_pre_inicio:       '#1A294A',
  em_andamento:        '#1E7C52',
  na_origem:           '#2563EB',
  em_transito_destino: '#9F906D',
  no_destino:          '#53648A',
  em_transito_retorno: '#53648A',
  retornando:          '#1E7C52',
  na_base:             '#1E7C52',
}

// Duas etapas da jornada NAO acontecem por esta tela, por decisao de Pecanha em
// 2026-08-19. As duas exigem registro que so existe nos dialogos da tela de detalhe,
// e o banco aceita as duas transicoes sem pre-condicao, entao a barreira precisa
// estar aqui.
//
// 1. `em_pre_inicio` ja e null na fonte unica, porque a tela de detalhe atravessa
//    essa etapa pelo wizard. Antes esta tela reintroduzia a etapa localmente, o que
//    permitia sair da base com uma foto e uma observacao, sem conferencia de
//    material, sem conferencia de viatura, sem as 5 fotos de angulo e sem o KM de
//    saida. A escolta comecava sem registro nenhum do estado da viatura.
//
// 2. `na_base` sai pelo mesmo motivo: a finalizacao exige checklist de entrega,
//    relatorio final e as 5 fotos de angulo. Deixar o botao aqui encerrava a escolta
//    sem prova e sem gravar data_finalizacao.
const PROXIMO_STATUS: Record<string, string> = {
  ...Object.fromEntries(
    Object.entries(PROXIMO_STATUS_FLUXO)
      .filter(([k, v]) => v !== null && k !== STATUS.NA_BASE)
      .map(([k, v]) => [k, (v as { status: string }).status])
  ),
}

// Derivado, e nao escrito a mao: o mapa manual omitia em_transito_retorno e travava a
// escolta no meio da jornada. Etapa nova acrescentada ao fluxo passa a aparecer aqui
// sozinha, sem ninguem lembrar de editar esta tela.
const BOTAO_AVANCO: Record<string, { label: string; cor: string }> = Object.fromEntries(
  Object.keys(PROXIMO_STATUS).map(k => [k, {
    label: PROXIMO_STATUS_FLUXO[k]?.label ?? rotuloStatus(PROXIMO_STATUS[k]),
    cor: COR_AVANCO[k] ?? '#1A294A',
  }])
)

const JORNADA = [
  { status: 'em_pre_inicio',       label: 'Base\nSaída',    icon: <Home size={13}/> },
  { status: 'em_andamento',        label: 'A Caminho\nOrigem', icon: <Navigation size={13}/> },
  { status: 'na_origem',           label: 'Na\nOrigem',    icon: <Package size={13}/> },
  { status: 'em_transito_destino', label: 'Rumo ao\nDestino', icon: <Navigation size={13}/> },
  { status: 'no_destino',          label: 'No\nDestino',   icon: <Flag size={13}/> },
  { status: 'em_transito_retorno', label: 'Rumo à' + String.fromCharCode(10) + 'Base', icon: <Navigation size={13}/> },
  { status: 'retornando',          label: 'Retornando',    icon: <RotateCcw size={13}/> },
  { status: 'na_base',             label: 'Base\nChegada', icon: <Home size={13}/> },
]

const STATUS_IDX: Record<string, number> = {
  em_pre_inicio: 0, em_andamento: 1, na_origem: 2,
  em_transito_destino: 3, no_destino: 4, em_transito_retorno: 5,
  retornando: 6, na_base: 7, finalizada: 8,
}

const STATUS_LABELS: Record<string, string> = {
  em_pre_inicio: 'Pré-Início', em_andamento: 'Em Andamento',
  na_origem: 'Na Origem', em_transito_destino: 'Trânsito p/ Destino', no_destino: 'No Destino',
  em_transito_retorno: 'Trânsito p/ Retorno',
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

// ─── Miniatura de foto já capturada (usada nas listas de até 5 fotos) ────────
function FotoMiniatura({
  captura,
  onRemover,
}: {
  captura: FotoCaptura
  onRemover: () => void
}) {
  return (
    <div className="relative rounded overflow-hidden border border-[#E2E8EC]">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={captura.preview} alt="foto" className="w-full h-28 object-cover" />
      <div className="absolute bottom-0 left-0 right-0 bg-black/65 px-2 py-1">
        <p className="text-white font-mono text-[9px] leading-tight break-all">
          {formatarCarimbo(captura.timestamp, captura.gps)}
        </p>
      </div>
      <button
        onClick={onRemover}
        className="absolute top-1.5 right-1.5 w-7 h-7 bg-black/50 hover:bg-black/70 rounded flex items-center justify-center transition-all"
      >
        <X size={12} className="text-white"/>
      </button>
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

  // Fotos do checkpoint (avançar status). Lista, nunca foto única: a regra do fluxo
  // é de FOTOS_POR_PONTO.min a FOTOS_POR_PONTO.max por ponto de controle.
  const [fotosCheckpoint, setFotosCheckpoint] = useState<FotoCaptura[]>([])
  const [obsAvanco, setObsAvanco] = useState('')
  // Viatura que recebe o ponto de controle. Nasce nula de proposito: com mais de uma
  // viatura na escolta, deixar uma pre-selecionada faria o registro sair para a viatura
  // errada sem que ninguem percebesse.
  const [viaturaAlvoId, setViaturaAlvoId] = useState<string | null>(null)
  // A captura de GPS tenta alta precisao e so depois baixa, o que pode levar dezenas
  // de segundos. Sem este estado o operador acha que falhou e toca de novo.
  const [capturandoFoto, setCapturandoFoto] = useState(false)
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

  // ── Qual viatura recebe o ponto de controle ───────────────────────────────
  // Decisao de Pecanha em 2026-08-19: cada viatura tem o proprio ponto de controle,
  // com foto e localizacao proprias.
  //
  // Escolhido o seletor, e nao a gravacao de um ponto por viatura com as mesmas fotos:
  // quem esta no dashboard nao esta na estrada e nao tem foto propria de cada viatura,
  // entao repetir a mesma foto nas duas criaria prova falsa de que ambas foram vistas.
  // Com o seletor, o ponto diz a verdade sobre o que foi observado, e a outra viatura
  // recebe o dela quando alguem de fato a observar.
  //
  // Para o vigilante nada disso vale: ele ja vem vinculado a uma viatura pelo efetivo, e
  // `viaturas` nem e preenchida no ramo dele.
  const viaturasDaEscolta = escoltaAtiva?.viaturas ?? []
  const precisaEscolherViatura = isAdmin && viaturasDaEscolta.length > 1
  const viaturaAlvo = precisaEscolherViatura
    ? viaturasDaEscolta.find(v => v.id === viaturaAlvoId) ?? null
    : null
  // Com uma viatura so, ou no caminho do vigilante, segue valendo o vinculo que ja veio
  // na consulta. Com mais de uma, nada e assumido enquanto a escolha nao for feita.
  const escoltaVeiculoIdAlvo = precisaEscolherViatura
    ? viaturaAlvo?.id ?? null
    : escoltaAtiva?.escolta_veiculo_id ?? null
  const placaAlvo = precisaEscolherViatura
    ? viaturaAlvo?.placa ?? null
    : escoltaAtiva?.veiculo_placa ?? null

  const showToast = (tipo: 'ok' | 'erro', texto: string) => {
    setToast({ tipo, texto })
    setTimeout(() => setToast(null), 4000)
  }

  // ── Carregar dados ────────────────────────────────────────────────────────
  const carregar = useCallback(async () => {
    if (!user) return
    setLoading(true)

    const ATIVOS = ['em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando', 'na_base']

    if (isAdmin) {
      // A viatura entra na consulta porque sem `escolta_veiculo_id` o ponto de controle
      // era descartado em silencio para administrador, gestor, supervisor e central: a
      // escolta avancava de etapa e nao sobrava prova nenhuma.
      const { data: esc } = await sb
        .from('escoltas')
        .select('id, codigo_escolta, status, origem_endereco, destino_endereco, data_hora_prevista, cliente:clientes(nome_cliente, cor_destaque), escolta_veiculos(id, veiculo:veiculos(placa, modelo))')
        .in('status', ATIVOS)
        .order('data_hora_prevista')

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const lista: EscoltaAtiva[] = ((esc ?? []) as any[]).map((e: any) => {
        // Decisao de Pecanha em 2026-08-19: cada viatura tem o proprio ponto de
        // controle, com foto e localizacao proprias. Por isso a tela carrega TODAS as
        // viaturas da escolta, e nao mais so a primeira. Quem e perfil administrativo
        // escolhe no painel de checkpoint qual viatura recebe o registro.
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const viaturas: ViaturaEscolta[] = ((e.escolta_veiculos ?? []) as any[]).map((v: any) => ({
          id: v.id,
          placa: v.veiculo?.placa ?? null,
          modelo: v.veiculo?.modelo ?? null,
        }))
        const primeiraViatura = viaturas[0]
        return {
          ...e,
          viaturas,
          // Continua existindo para a escolta de viatura unica, onde nao ha escolha a
          // fazer e nenhum seletor aparece.
          escolta_veiculo_id: primeiraViatura?.id,
          veiculo_placa: primeiraViatura?.placa ?? undefined,
          veiculo_modelo: primeiraViatura?.modelo ?? undefined,
        } as EscoltaAtiva
      })
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

  // Texto padrão da etapa, reaplicado toda vez que o painel de checkpoint abre.
  // A chave é o status de DESTINO da transição, não o atual: o operador descreve
  // a etapa que está atingindo. Campo de rotina, sem validação por trás, por isso
  // pode entrar como valor inicial sem afrouxar barreira nenhuma.
  useEffect(() => {
    if (painelAberto !== 'checkpoint') return
    const destino = PROXIMO_STATUS[escoltaAtiva?.status ?? '']
    setObsAvanco(destino ? (TEXTO_PADRAO_ETAPA[destino] ?? '') : '')
  }, [painelAberto, escoltaAtiva?.status])

  // Trocar de escolta zera a viatura escolhida. Sem isto, o id de uma viatura da escolta
  // anterior continuaria selecionado e o proximo registro sairia para a escolta errada.
  useEffect(() => { setViaturaAlvoId(null) }, [escoltaAtiva?.id])

  // ── Helper: capturar foto com GPS + timestamp ─────────────────────────────
  const capturarFoto = async (file: File): Promise<FotoCaptura> => {
    const preview = URL.createObjectURL(file)
    const timestamp = new Date().toISOString()
    let gps: { lat: number; lng: number; precisao: number } | null = null
    try {
      gps = await obterGPS()
    } catch {
      // A foto vale mesmo sem coordenada, e o carimbo mostra a ausencia. O que nao
      // pode e a falha passar em silencio, como passava antes.
      gps = null
      showToast('erro', 'Foto registrada sem coordenadas: sem sinal de GPS.')
    }
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
    // Antes retornava null em silencio e o status avancava sem foto. Em estrada
    // com rede ruim esse era o caminho mais provavel.
    if (upErr) throw new Error('Falha ao enviar a foto: ' + upErr.message)

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
    const arquivos = Array.from(e.target.files ?? [])
    if (arquivos.length === 0) return

    const espaco = FOTOS_POR_PONTO.max - fotosCheckpoint.length
    if (espaco <= 0) {
      showToast('erro', `Máximo de ${FOTOS_POR_PONTO.max} fotos por ponto de controle.`)
      return
    }
    if (arquivos.length > espaco) {
      showToast('erro', `Só cabem mais ${espaco} foto(s) neste ponto. As demais foram descartadas.`)
    }

    setCapturandoFoto(true)
    try {
      const capturas = await Promise.all(arquivos.slice(0, espaco).map(capturarFoto))
      setFotosCheckpoint(fs => {
        // O teto e aplicado aqui dentro, onde o estado e confiavel. O `espaco`
        // calculado la em cima veio do closure do render: entre ele e esta gravacao
        // existe o await da captura, e um segundo toque no botao passaria de
        // FOTOS_POR_PONTO.max sem que nenhuma das duas chamadas percebesse.
        const juntas = [...fs, ...capturas]
        if (juntas.length <= FOTOS_POR_PONTO.max) return juntas
        juntas.slice(FOTOS_POR_PONTO.max).forEach(f => URL.revokeObjectURL(f.preview))
        return juntas.slice(0, FOTOS_POR_PONTO.max)
      })
    } finally {
      setCapturandoFoto(false)
      // Zerar o input permite fotografar duas vezes o mesmo arquivo de câmera.
      if (fotoCheckpointRef.current) fotoCheckpointRef.current.value = ''
    }
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

  const removerFotoCheckpoint = (idx: number) => {
    setFotosCheckpoint(fs => {
      const alvo = fs[idx]
      if (alvo) URL.revokeObjectURL(alvo.preview)
      return fs.filter((_, i) => i !== idx)
    })
    if (fotoCheckpointRef.current) fotoCheckpointRef.current.value = ''
  }

  const limparFotosCheckpoint = () => {
    setFotosCheckpoint(fs => {
      fs.forEach(f => URL.revokeObjectURL(f.preview))
      return []
    })
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

    // ── Pre-requisitos conferidos ANTES de qualquer escrita ────────────────
    // Lista explicita, e nao "se o mapa nao tiver a chave, pula o ponto": era
    // exatamente essa condicao permissiva que fazia o ponto de controle sumir em
    // silencio. Sao as duas unicas etapas que o fluxo nao associa a ponto nenhum.
    // Que a tela de campo possa finalizar uma escolta e decisao pendente com
    // Pecanha (plano, secao 6, item 9); aqui apenas nao se inventa um ponto que
    // o fluxo nao preve.
    const tipoPontoId = STATUS_TO_TIPO_PONTO[proximo]
    const exigePonto = !SEM_PONTO_DE_CONTROLE.includes(proximo)
    if (exigePonto && !tipoPontoId) {
      showToast('erro', `Etapa sem tipo de ponto de controle definido (${proximo}). Avise a central.`)
      return
    }

    // A foto so e exigida onde existe ponto de controle para referencia-la. Nas
    // etapas sem ponto a foto nao teria dono: subia para o bucket e criava linha
    // em `fotos` que nenhuma outra tabela aponta, virando lixo permanente.
    if (exigePonto && fotosCheckpoint.length < FOTOS_POR_PONTO.min) {
      showToast('erro', `Registre ao menos ${FOTOS_POR_PONTO.min} foto para o checkpoint.`)
      return
    }
    // Com mais de uma viatura na escolta, o ponto so sai depois que quem registra disser
    // qual viatura observou. Nao ha escolha padrao: cada viatura tem o proprio ponto.
    if (precisaEscolherViatura && !viaturaAlvo) {
      showToast('erro', 'Escolha a viatura que recebe este ponto de controle.')
      return
    }
    if (!escoltaVeiculoIdAlvo) {
      showToast('erro', 'Escolta sem viatura vinculada. Vincule a viatura antes de registrar o ponto.')
      return
    }
    if (!user?.id) {
      showToast('erro', 'Sessão expirada. Faça login novamente.')
      return
    }

    setExecutando(true)
    try {
      // GPS. Decisao de Pecanha: sem sinal nao bloqueia o avanco, mas tambem nao
      // inventa coordenada. Grava latitude e longitude nulas com sem_sinal_gps
      // verdadeiro, e a tela avisa. A coordenada sentinela 0,0 esta proibida:
      // cai no golfo da Guine e polui mapa e indicador de precisao com dado falso.
      let gps = fotosCheckpoint.find(f => f.gps)?.gps ?? null
      if (!gps) {
        try { gps = await obterGPS() } catch { gps = null }
      }
      const semSinalGps = !gps
      const avisos: string[] = []
      if (semSinalGps) avisos.push('Posição não capturada: sem sinal de GPS.')

      // Upload das fotos do checkpoint. A primeira vai para pontos_controle.foto_id,
      // que e escalar; as demais ficam nos foto_ids serializados em observacoes.
      // So sobe foto onde existe ponto para referencia-la: sem ponto, cada avanco
      // deixaria arquivo no bucket e linha orfa em `fotos`.
      const fotoIds: string[] = []
      let fotoId: string | null = null
      if (exigePonto) {
        for (const captura of fotosCheckpoint) {
          const id = await uploadFoto(captura, TIPO_FOTO.PONTO_CONTROLE)
          if (id) fotoIds.push(id)
        }
        fotoId = fotoIds[0] ?? null
        // uploadFoto devolve null quando o registro em `fotos` nao volta com id. Sem
        // nenhuma foto gravada o ponto perde o valor probatorio, entao o avanco para
        // aqui em vez de seguir com a coluna vazia.
        if (fotoIds.length === 0) {
          showToast('erro', 'Não foi possível registrar as fotos do checkpoint. Tente novamente.')
          setExecutando(false)
          return
        }
      }

      // Reconfere o status logo antes de gravar, ja com as fotos subidas.
      //
      // O upload das fotos leva segundos, e nesse intervalo o supervisor no painel ou
      // o proprio operador em outra aba podem ter avancado a etapa. Sem esta conferencia
      // o ponto seria gravado e so entao o update falharia, deixando um ponto a mais no
      // relatorio que ninguem consegue remover: pontos_controle nao tem policy de DELETE,
      // de proposito, porque apagar ponto de controle quebra a cadeia de custodia.
      //
      // Isto reduz a janela de segundos para milissegundos, nao a elimina. Fechar de vez
      // exige gravar ponto, status e historico numa unica transacao no banco, por RPC.
      const { data: statusConferido, error: confErr } = await sb
        .from('escoltas')
        .select('status')
        .eq('id', escoltaAtiva.id)
        .maybeSingle()
      if (confErr) {
        showToast('erro', confErr.message ?? 'Não foi possível conferir a etapa atual.')
        setExecutando(false)
        return
      }
      if (!statusConferido || statusConferido.status !== statusAtual) {
        showToast('erro', 'A etapa já foi avançada em outra tela. Recarregue a página antes de continuar.')
        setExecutando(false)
        return
      }

      // Ponto de controle ANTES do status, e sem condicao que o torne opcional.
      // Antes o insert vinha depois e so acontecia se houvesse GPS e viatura: a
      // escolta avancava de etapa e a prova simplesmente nao existia. Se o ponto
      // falhar, o status nao anda; ponto orfao se reaproveita, status avancado sem
      // prova nao se desfaz.
      if (exigePonto && tipoPontoId) {
        const { error: pontoErr } = await sb.from('pontos_controle').insert({
          escolta_veiculo_id: escoltaVeiculoIdAlvo,
          tipo_ponto_id: tipoPontoId,
          data_hora: fotosCheckpoint[0]?.timestamp ?? new Date().toISOString(),
          latitude: gps?.lat ?? null,
          longitude: gps?.lng ?? null,
          precisao_metros: gps?.precisao ?? null,
          sem_sinal_gps: semSinalGps,
          foto_id: fotoId,
          observacoes: serializarObservacao({ observacao: obsAvanco, fotoIds }),
          lancado_por: user.id,
          sincronizado: true,
          criado_offline: false,
        })
        if (pontoErr) {
          showToast('erro', pontoErr.message ?? 'Não foi possível registrar o ponto de controle.')
          setExecutando(false)
          return
        }
      }

      // O status so avanca quando TODAS as viaturas da escolta tiverem ponto nesta
      // etapa. Sem isso a decisao de "um registro por viatura" nao se sustentaria aqui:
      // o primeiro registro avancaria a etapa, o botao sumiria, e a segunda viatura
      // ficaria para sempre sem o ponto daquela etapa.
      //
      // Com uma viatura so, que e quase toda escolta, a primeira ja e a ultima e nada
      // muda em relacao ao comportamento anterior.
      if (exigePonto && tipoPontoId && viaturasDaEscolta.length > 1) {
        const { data: pontosDaEtapa, error: contagemErr } = await sb
          .from('pontos_controle')
          .select('escolta_veiculo_id')
          .eq('tipo_ponto_id', tipoPontoId)
          .in('escolta_veiculo_id', viaturasDaEscolta.map(v => v.id))
        if (contagemErr) {
          showToast('erro', contagemErr.message ?? 'Não foi possível conferir os registros das viaturas.')
          setExecutando(false)
          return
        }
        const comPonto = new Set((pontosDaEtapa ?? []).map((p: { escolta_veiculo_id: string }) => p.escolta_veiculo_id))
        const faltando = viaturasDaEscolta.filter(v => !comPonto.has(v.id))
        if (faltando.length > 0) {
          const placas = faltando.map(v => v.placa ?? 'sem placa').join(', ')
          showToast(
            'ok',
            `Ponto registrado. A etapa avança quando as demais viaturas registrarem: ${placas}.`
          )
          limparFotosCheckpoint()
          setObsAvanco('')
          setViaturaAlvoId(null)
          setPainelAberto(null)
          setExecutando(false)
          await carregar()
          return
        }
      }

      // Atualiza status da escolta.
      // Ler o erro aqui nao e detalhe: a trigger do banco recusa transicao
      // invalida, e sem esta checagem o codigo seguia gravando ponto de
      // controle e historico de uma transicao que nunca aconteceu.
      const { data: escoltasAtualizadas, error: statusErr } = await sb
        .from('escoltas')
        .update({ status: proximo })
        .eq('id', escoltaAtiva.id)
        .eq('status', statusAtual)
        .select('id')
      if (statusErr) {
        showToast('erro', statusErr.message ?? 'Não foi possível avançar o status.')
        setExecutando(false)
        return
      }
      // Sem o `select`, o PostgREST devolve erro nulo quando o filtro de status nao
      // casa linha nenhuma, e a tela anunciaria uma transicao que nao aconteceu.
      // Com o ponto de controle ja gravado acima, isso deixaria um ponto a mais no
      // relatorio: exatamente a regressao que este projeto ja teve.
      if (!escoltasAtualizadas || escoltasAtualizadas.length === 0) {
        // Corrida perdida por milissegundos, depois da conferencia acima. O ponto de
        // controle ja esta gravado e nao pode ser removido daqui, entao a mensagem
        // avisa em vez de mandar repetir, que criaria um segundo ponto.
        showToast('erro', 'A etapa foi avançada em outra tela enquanto este registro era enviado. O ponto de controle ficou salvo. Recarregue a página e confira a etapa antes de registrar de novo.')
        setExecutando(false)
        return
      }

      // Histórico de status
      const { error: histErr } = await sb.from('escolta_status_historico').insert({
        escolta_id: escoltaAtiva.id,
        status_anterior: statusAtual,
        status_novo: proximo,
        alterado_por: user.id,
        data_hora: new Date().toISOString(),
        latitude: gps?.lat ?? null,
        longitude: gps?.lng ?? null,
        observacao: obsAvanco.trim() || null,
      })
      // O status ja mudou: aqui nao cabe abortar, cabe nao mentir que deu tudo certo.
      if (histErr) avisos.push('Histórico não registrado: ' + (histErr.message ?? 'erro desconhecido'))

      // Notificar Telegram — sempre dispara após qualquer avanço de status.
      // Faltava em_transito_retorno nos dois mapas: a mensagem que chega ao cliente
      // saia com o codigo cru do status. O fallback agora e o rotulo do fluxo, nunca
      // mais o codigo.
      const STATUS_TG_TITULO: Record<string, string> = {
        em_pre_inicio:       'Pré-Início Iniciado',
        em_andamento:        'Saída da Base',
        na_origem:           'Chegada na Origem',
        em_transito_destino: 'Trânsito ao Destino Iniciado',
        no_destino:          'Chegada no Destino',
        em_transito_retorno: 'Trânsito de Retorno Iniciado',
        retornando:          'Retorno Iniciado',
        na_base:             'Chegada na Base',
        finalizada:          'Escolta Finalizada',
      }
      const STATUS_TG_LABEL: Record<string, string> = {
        em_pre_inicio:       'Pré-Início',
        em_andamento:        'Em Rota',
        na_origem:           'Na Origem',
        em_transito_destino: 'Trânsito p/ Destino',
        no_destino:          'No Destino',
        em_transito_retorno: 'Trânsito p/ Retorno',
        retornando:          'Em Retorno',
        na_base:             'Na Base',
        finalizada:          'Finalizada',
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
          titulo: STATUS_TG_TITULO[proximo] ?? rotuloStatus(proximo),
          // O banco guarda a observacao inteira; a mensagem so destaca o que fugiu da
          // rotina. Sem isto, toda etapa mandaria "sem alterações" e viraria ruído.
          descricao: ehTextoPadrao(obsAvanco, TEXTO_PADRAO_ETAPA[proximo])
            ? undefined
            : obsAvanco.trim() || undefined,
          escolta_id: escoltaAtiva.id,
          escolta_codigo: escoltaAtiva.codigo_escolta,
          cliente: escoltaAtiva.cliente?.nome_cliente,
          status_atual: STATUS_TG_LABEL[proximo] ?? rotuloStatus(proximo),
          efetivos,
          // A placa da mensagem e a da viatura que recebeu o ponto, nao a primeira da
          // lista: com duas viaturas, avisar a placa errada e desmentir o proprio registro.
          veiculo: placaAlvo ?? undefined,
          foto_url: fotoTgUrl,
          data_hora: dataHoraFmt,
        }),
      }).catch(() => {})

      setEscoltaAtiva({ ...escoltaAtiva, status: proximo })
      if (isAdmin) setTodasEscoltas(ts => ts.map(t => t.id === escoltaAtiva.id ? { ...t, status: proximo } : t))

      limparFotosCheckpoint()
      setObsAvanco('')
      // Cada ponto de controle exige escolha propria de viatura: a escolha da etapa
      // anterior nao pode valer como padrao silencioso da seguinte.
      setViaturaAlvoId(null)
      setPainelAberto(null)

      const msgs: Record<string, string> = {
        em_pre_inicio: 'Pré-início registrado.',
        em_andamento: 'Saída registrada! Em deslocamento.',
        na_origem: 'Chegada na Origem confirmada!',
        em_transito_destino: 'Partiu para o Destino!',
        no_destino: 'Chegada no Destino confirmada!',
        // no_destino nao vai mais para retornando: entre os dois existe a etapa de
        // transito de retorno, e cada mensagem passou a descrever a sua propria etapa.
        em_transito_retorno: 'Entrega confirmada. Iniciando retorno...',
        retornando: 'Retorno confirmado.',
        na_base: 'Chegada na Base confirmada!',
        finalizada: 'Escolta finalizada com sucesso!',
      }
      const msgBase = msgs[proximo] ?? 'Status atualizado.'
      if (avisos.length > 0) showToast('erro', `${msgBase} ${avisos.join(' ')}`)
      else showToast('ok', msgBase)
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
      // Ocorrencia nao bloqueia por GPS: o relato vale por si, e as colunas de
      // coordenada da tabela aceitam nulo. O que muda e que a ausencia deixa de
      // passar despercebida, e aparece no aviso ao operador.
      let gps = fotoOcorrencia?.gps ?? null
      if (!gps) {
        try { gps = await obterGPS() } catch { gps = null }
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
      showToast(
        gps ? 'ok' : 'erro',
        gps
          ? 'Ocorrência registrada com sucesso.'
          : 'Ocorrência registrada. Posição não capturada: sem sinal de GPS.'
      )
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
      // REGRA DELIBERADA, DIFERENTE DE TODO O RESTO DA TELA: emergência nunca é
      // bloqueada por GPS. Falta de sinal aciona assim mesmo, grava coordenada nula
      // e a ausência aparece no aviso. Emergência é um toque, e qualquer atraso aqui
      // pode custar caro.
      let gps: { lat: number; lng: number; precisao: number } | null = null
      try { gps = await obterGPS() } catch { gps = null }

      if (!escoltaAtiva?.id || !user?.id) {
        showToast('erro', 'FALHA AO ACIONAR: sessão ou escolta indisponível. Ligue para a central agora.')
        setExecutando(false)
        return
      }

      // O retorno PRECISA ser lido. O supabase-js nunca lança: ele devolve
      // { data, error }, então o try/catch em volta não vê falha nenhuma. Sem esta
      // checagem a tela anunciava "EMERGÊNCIA ACIONADA" com o insert recusado pelo
      // banco e nada gravado, exatamente no cenário em que o botão mais importa.
      const { error: emergErr } = await sb.from('emergencias').insert({
        escolta_id: escoltaAtiva.id,
        escolta_veiculo_id: escoltaAtiva.escolta_veiculo_id ?? null,
        acionado_por: user.id,
        data_hora: new Date().toISOString(),
        latitude: gps?.lat ?? null,
        longitude: gps?.lng ?? null,
        sem_sinal_gps: !gps,
        status: 'aberta',
      })
      if (emergErr) {
        showToast('erro', `FALHA AO ACIONAR A EMERGÊNCIA: ${emergErr.message}. LIGUE PARA A CENTRAL AGORA.`)
        setExecutando(false)
        return
      }

      // A mensagem dizia "Central notificada" e nada era enviado a ninguém: não há
      // trigger nem webhook em emergencias, só o contador da tela de indicadores.
      // O envio é disparado sem await de propósito: o acionamento já está gravado, e
      // esperar a rede aqui atrasaria a confirmação para quem está em emergência.
      fetch('/api/telegram', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          tipo: 'emergencia',
          titulo: 'EMERGÊNCIA ACIONADA',
          descricao: gps
            ? `Posição: ${gps.lat.toFixed(6)}, ${gps.lng.toFixed(6)} (precisão ${Math.round(gps.precisao)} m)`
            : 'SEM SINAL DE GPS. Posição não capturada no acionamento.',
          escolta_id: escoltaAtiva.id,
          escolta_codigo: escoltaAtiva.codigo_escolta,
          cliente: escoltaAtiva.cliente?.nome_cliente,
          status_atual: escoltaAtiva.status,
          veiculo: escoltaAtiva.veiculo_placa,
          data_hora: new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' }),
        }),
      }).catch(() => {})

      setEmergConfirm(false)
      showToast(
        'ok',
        gps
          ? 'EMERGÊNCIA REGISTRADA! Central acionada com sua posição.'
          : 'EMERGÊNCIA REGISTRADA! Central acionada. Sem sinal de GPS: informe sua posição por rádio ou telefone.'
      )
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
  const proximoStatus = PROXIMO_STATUS[status]
  const podeAvancar = !!proximoStatus
  // Mesma regra da validacao: onde nao ha ponto de controle, a foto nao e exigida.
  // Sem isto o botao ficaria travado para sempre nessas etapas.
  const exigeFotoCheckpoint = !!proximoStatus && !SEM_PONTO_DE_CONTROLE.includes(proximoStatus)
  const mostrarChecklist = ['em_pre_inicio', 'na_base'].includes(status)
  const mostrarOcorrencia = ['em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando'].includes(status)
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
                {/* Com mais de uma viatura, o card mostra todas. Mostrar so a primeira
                    dava a entender que a escolta tinha uma viatura, e quem registrasse o
                    ponto acharia que ele valia pela escolta inteira. */}
                {viaturasDaEscolta.length > 1 ? (
                  <div className="flex items-start gap-1.5">
                    <Shield size={12} className="mt-0.5 shrink-0" style={{ color: '#A8B8C2' }} />
                    <span className="leading-relaxed">
                      {viaturasDaEscolta.length} viaturas: {viaturasDaEscolta.map(v => v.placa ?? 'Sem placa').join(', ')}
                    </span>
                  </div>
                ) : escoltaAtiva.veiculo_placa ? (
                  <div className="flex items-center gap-1.5">
                    <Shield size={12} style={{ color: '#A8B8C2' }} />
                    <span>{escoltaAtiva.veiculo_placa}{escoltaAtiva.veiculo_modelo ? ` · ${escoltaAtiva.veiculo_modelo}` : ''}</span>
                  </div>
                ) : null}
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

            {/* ── [0] PRE-INICIO: a saida da base nao acontece nesta tela ──
                O pre-inicio exige conferencia de material, conferencia de viatura, as
                5 fotos de angulo e o KM de saida, que so existem no wizard da tela de
                detalhe. Decisao de Pecanha em 2026-08-19. */}
            {status === STATUS.EM_PRE_INICIO && (
              <div className="card-light p-4" style={{ border: '1.5px solid rgba(212,160,23,0.35)', backgroundColor: '#FFFBEB' }}>
                <div className="flex items-start gap-3">
                  <div className="w-10 h-10 rounded flex items-center justify-center shrink-0" style={{ backgroundColor: '#FEF3C7', border: '1px solid #FDE68A' }}>
                    <Home size={18} style={{ color: '#B45309' }} />
                  </div>
                  <div>
                    <p className="text-sm font-bold" style={{ color: '#1E2D35' }}>Aguardando liberação da base</p>
                    <p className="text-xs mt-1 leading-relaxed" style={{ color: '#6B7E8A' }}>
                      A saída da base é liberada pelo supervisor, na tela de detalhe, com a
                      conferência do material, a conferência da viatura e as fotos dos cinco
                      ângulos. Assim que ele confirmar, o registro dos pontos aparece aqui.
                    </p>
                  </div>
                </div>
              </div>
            )}

            {/* ── [0] NA BASE: a finalizacao nao acontece nesta tela ──
                O botao de finalizar foi retirado daqui porque encerrava a escolta sem
                checklist de entrega, sem relatorio final e sem as 5 fotos de angulo da
                viatura, que so existem no dialogo da tela de detalhe. Sem este aviso o
                operador ficaria diante de uma tela sem acao e sem explicacao. */}
            {status === STATUS.NA_BASE && (
              <div className="card-light p-4" style={{ border: '1.5px solid rgba(212,160,23,0.35)', backgroundColor: '#FFFBEB' }}>
                <div className="flex items-start gap-3">
                  <div className="w-10 h-10 rounded flex items-center justify-center shrink-0" style={{ backgroundColor: '#FEF3C7', border: '1px solid #FDE68A' }}>
                    <Home size={18} style={{ color: '#B45309' }} />
                  </div>
                  <div>
                    <p className="text-sm font-bold" style={{ color: '#1E2D35' }}>Viatura recolhida na base</p>
                    <p className="text-xs mt-1 leading-relaxed" style={{ color: '#6B7E8A' }}>
                      A finalização da escolta é feita pelo supervisor, na tela de detalhe,
                      com o checklist de entrega, o relatório final e as fotos da viatura.
                      Avise a central que a viatura chegou.
                    </p>
                  </div>
                </div>
              </div>
            )}

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
                        {!exigeFotoCheckpoint
                          ? 'Esta etapa não gera ponto de controle: foto não é exigida.'
                          : fotosCheckpoint.length < FOTOS_POR_PONTO.min
                            ? `Foto obrigatória (mínimo ${FOTOS_POR_PONTO.min}, até ${FOTOS_POR_PONTO.max})`
                            // Sem a viatura escolhida o registro nao esta pronto, e dizer que
                            // esta faria o operador tocar num botao desabilitado sem entender.
                            : precisaEscolherViatura && !viaturaAlvo
                              ? `${fotosCheckpoint.length} foto(s) registrada(s). Falta escolher a viatura.`
                              : `✓ ${fotosCheckpoint.length} de ${FOTOS_POR_PONTO.max} registradas, pronto para confirmar${viaturaAlvo?.placa ? ` (${viaturaAlvo.placa})` : ''}`}
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

                    {/* Seletor de viatura. So aparece quando ha mais de uma viatura na
                        escolta e quem registra e perfil administrativo: com uma viatura
                        so, e no caminho do vigilante, nao ha escolha a fazer. */}
                    {precisaEscolherViatura && (
                      <div className="space-y-2">
                        <label className="block text-[11px] font-black uppercase tracking-widest" style={{ color: '#6B7E8A' }}>
                          Viatura deste registro
                        </label>
                        <div className="flex flex-wrap gap-2">
                          {viaturasDaEscolta.map(v => (
                            <button
                              key={v.id}
                              onClick={() => setViaturaAlvoId(v.id)}
                              className="px-3 py-2 rounded text-xs font-semibold border transition-all"
                              style={
                                viaturaAlvoId === v.id
                                  ? { backgroundColor: '#2166A8', color: '#fff', borderColor: '#2166A8' }
                                  : { backgroundColor: '#fff', color: '#5C6B73', borderColor: '#E2E8EC' }
                              }
                            >
                              {v.placa ?? 'Sem placa'}{v.modelo ? ` · ${v.modelo}` : ''}
                            </button>
                          ))}
                        </div>
                        <p className="text-xs leading-relaxed" style={{ color: viaturaAlvo ? '#6B7E8A' : '#B45309' }}>
                          {viaturaAlvo
                            ? 'O ponto de controle, as fotos e a posição vão só para esta viatura. As demais recebem o registro delas quando forem observadas.'
                            : 'Escolha a viatura antes de confirmar. Cada viatura tem o próprio ponto de controle, com foto e posição próprias.'}
                        </p>
                      </div>
                    )}

                    {/* Sem ponto de controle nao ha quem referencie a foto, e o
                        avanco nem chega a envia-la: entao a captura nem aparece,
                        em vez de recolher foto que seria descartada. */}
                    {exigeFotoCheckpoint && (
                      <div className="space-y-2">
                        <div className="flex items-center justify-between">
                          <label className="block text-[11px] font-black uppercase tracking-widest" style={{ color: '#6B7E8A' }}>
                            Fotos do Checkpoint (mínimo {FOTOS_POR_PONTO.min}, até {FOTOS_POR_PONTO.max})
                          </label>
                          <span className="text-[11px] font-semibold" style={{ color: '#6B7E8A' }}>
                            {fotosCheckpoint.length} de {FOTOS_POR_PONTO.max} registradas
                          </span>
                        </div>

                        {fotosCheckpoint.length > 0 && (
                          <div className="grid grid-cols-2 gap-2">
                            {fotosCheckpoint.map((f, idx) => (
                              <FotoMiniatura
                                key={f.preview}
                                captura={f}
                                onRemover={() => removerFotoCheckpoint(idx)}
                              />
                            ))}
                          </div>
                        )}

                        {fotosCheckpoint.length < FOTOS_POR_PONTO.max && (
                          <button
                            onClick={() => fotoCheckpointRef.current?.click()}
                            disabled={capturandoFoto}
                            className="w-full py-6 border-2 border-dashed border-[#E2E8EC] rounded flex flex-col items-center gap-2 hover:border-[#4A90A4] hover:bg-[#F8FAFC] transition-all disabled:opacity-50 disabled:hover:border-[#E2E8EC] disabled:hover:bg-transparent"
                          >
                            <Camera size={26} className="text-[#C4CDD4]"/>
                            <span className="text-sm font-semibold text-[#6B7E8A]">
                              {capturandoFoto
                                ? 'Registrando foto...'
                                : fotosCheckpoint.length === 0 ? 'Tirar foto do checkpoint' : 'Adicionar outra foto'}
                            </span>
                            <span className="text-xs text-[#A8B8C2]">
                              {capturandoFoto ? 'Capturando posição do GPS, aguarde.' : 'GPS será capturado automaticamente'}
                            </span>
                          </button>
                        )}
                      </div>
                    )}

                    <div>
                      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '4px' }}>
                        <label className="block text-[11px] font-black uppercase tracking-widest" style={{ color: '#6B7E8A' }}>
                          Observação (opcional)
                        </label>
                        <div style={{ display: 'flex', gap: '4px' }}>
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
                      disabled={executando || capturandoFoto || (exigeFotoCheckpoint && fotosCheckpoint.length < FOTOS_POR_PONTO.min) || (precisaEscolherViatura && !viaturaAlvo)}
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
                                {/* Item nao conforme nunca recebe valor inicial: o campo
                                    existe para dizer o que fugiu do previsto, e texto
                                    pronto ali facilita registro falso. So placeholder. */}
                                <label className="block text-[10px] font-black uppercase tracking-widest" style={{ color: '#B83832' }}>
                                  Não conformidade *
                                </label>
                                <input
                                  type="text"
                                  placeholder={PLACEHOLDER.itemNaoConforme}
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
                          <AiTextButton value={descOcorrencia} onChange={setDescOcorrencia} contexto="Descrição de ocorrência em escolta armada" />
                        </div>
                      </div>
                      {/* Ocorrencia nunca abre preenchida: ela existe justamente porque
                          algo saiu do previsto. O texto orienta, nao preenche. */}
                      <textarea
                        rows={4}
                        value={descOcorrencia}
                        onChange={e => setDescOcorrencia(e.target.value)}
                        placeholder={PLACEHOLDER.descOcorrencia}
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
