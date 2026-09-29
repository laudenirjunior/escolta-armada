'use client'

/**
 * Painel Operacional Guiado: a camada visual do Modo Guiado sobre a tela de Campo.
 *
 * Este componente NAO grava nada. Todo registro sai pelas funcoes da propria tela de
 * Campo (avancarStatus, registrarOcorrencia, acionarEmergencia, check-in), recebidas
 * por props, e as etapas que so a tela de detalhe grava (pre-inicio, chegada na base
 * com KM final, finalizacao, parada) abrem o dialogo que ja existe la. Decisao de
 * Pecanha em 2026-09-29: camada sobre o fluxo atual, sem fluxo paralelo e sem
 * gravacao duplicada.
 *
 * Desenho para quem usa pouco o celular: uma acao principal por tela, botoes de no
 * minimo 56 px, texto de 16 px para cima, obrigatorio separado de opcional, e uma
 * tela de confirmacao que so aparece quando o registro foi de fato gravado.
 */

import { useRef, useState } from 'react'
import {
  AlertTriangle, ArrowLeft, Camera, Check, CheckCircle2, ChevronRight, Clock,
  FileText, Map as MapIcon, Octagon, Radio, Shield, X, Zap,
} from 'lucide-react'
import { FOTOS_POR_PONTO } from '@/lib/fluxo-escolta'
import { TOTAL_ETAPAS, type AcaoDetalhe, type ProximaAcao } from '@/lib/proximo-passo-operador'

// ─── Paleta Navy (app/globals.css), sem migrar paleta ─────────────────────────
const COR = {
  navy: '#1A294A',
  texto: '#0E1A33',
  apoio: '#5A6A80',
  borda: '#D6DAE5',
  fundo: '#FFFFFF',
  verde: '#1E7C52',
  verdeFundo: '#E6F4ED',
  ambar: '#8B6914',
  ambarFundo: '#FBF3DE',
  vermelho: '#B83832',
  vermelhoFundo: '#FEF0EE',
  cinza: '#EEF0F5',
}

export interface FotoGuiada {
  preview: string
  timestamp: string
  gps: { lat: number; lng: number; precisao: number } | null
}

export interface ViaturaGuiada { id: string; placa: string | null; modelo: string | null }

export interface EscoltaGuiada {
  id: string
  codigo: string | null
  cliente: string | null
  cor: string | null
  status: string
  origem: string
  destino: string
  prevista: string
}

export interface Pendencia { texto: string; nivel: 'alerta' | 'atencao' }

export interface Confirmacao {
  titulo: string
  detalhe?: string
  avisos: string[]
  horario: string
}

export type PainelAberto = 'checkpoint' | 'checklist' | 'ocorrencia' | 'checkin' | null

export interface PainelGuiadoProps {
  escolta: EscoltaGuiada | null
  escoltasParaEscolher: { id: string; codigo: string | null; cliente: string | null }[]
  onSelecionarEscolta: (id: string) => void
  agendadas: { id: string; codigo: string | null; cliente: string | null; prevista: string }[]
  semVinculoCadastro: boolean
  proxima: ProximaAcao | null
  /**
   * A acao da etapa, sem a prioridade do check-in. Com check-in atrasado a Proxima
   * Acao vira o check-in, mas o registro da etapa nao pode sumir: a equipe pode ter
   * chegado ao destino justamente agora.
   */
  acaoEtapa: ProximaAcao | null
  pendencias: Pendencia[]
  checkinDisponivel: boolean
  paradaDisponivel: boolean

  painel: PainelAberto
  onAbrirPainel: (p: PainelAberto) => void

  viaturas: ViaturaGuiada[]
  viaturaAlvoId: string | null
  onEscolherViatura: (id: string) => void
  /** Viaturas que ja registraram a etapa em curso. */
  viaturasJaRegistradas: string[]

  fotosEtapa: FotoGuiada[]
  onAdicionarFotosEtapa: (arquivos: File[]) => void
  onRemoverFotoEtapa: (idx: number) => void
  obsEtapa: string
  onObsEtapa: (v: string) => void
  onConfirmarEtapa: () => void

  fotosCheckin: FotoGuiada[]
  onAdicionarFotosCheckin: (arquivos: File[]) => void
  onRemoverFotoCheckin: (idx: number) => void
  obsCheckin: string
  onObsCheckin: (v: string) => void
  onConfirmarCheckin: () => void

  tiposOcorrencia: { id: string; nome: string }[]
  tipoOcId: string
  onTipoOc: (id: string) => void
  descOc: string
  onDescOc: (v: string) => void
  placeholderOc: string
  fotoOc: FotoGuiada | null
  onFotoOc: (arquivo: File) => void
  onLimparFotoOc: () => void
  onConfirmarOcorrencia: () => void

  emergConfirm: boolean
  onEmergIniciar: () => void
  onEmergCancelar: () => void
  onEmergConfirmar: () => void

  executando: boolean
  capturandoFoto: boolean
  confirmacao: Confirmacao | null
  onFecharConfirmacao: () => void

  onAbrirDetalhe: (acao?: AcaoDetalhe, escoltaId?: string) => void
  onVerEscoltas: () => void
  podeDesligar: boolean
  onDesligarModo: () => void
  carimbo: (timestamp: string, gps: FotoGuiada['gps']) => string
}

// ─── Peças visuais ────────────────────────────────────────────────────────────

function BotaoPrincipal({
  children, onClick, disabled, cor = COR.navy, icone,
}: {
  children: React.ReactNode
  onClick: () => void
  disabled?: boolean
  cor?: string
  icone?: React.ReactNode
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="w-full flex items-center justify-center gap-3 font-black uppercase tracking-wide text-white transition-transform active:scale-[0.98] disabled:opacity-40"
      style={{ backgroundColor: cor, minHeight: '64px', fontSize: '17px', padding: '12px 16px', borderRadius: '4px' }}
    >
      {icone}
      <span className="text-center leading-tight">{children}</span>
    </button>
  )
}

function BotaoSecundario({
  children, onClick, icone, destaque,
}: {
  children: React.ReactNode
  onClick: () => void
  icone: React.ReactNode
  destaque?: boolean
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="w-full flex items-center gap-3 text-left font-bold transition-colors active:scale-[0.99]"
      style={{
        minHeight: '56px', padding: '10px 14px', fontSize: '16px', borderRadius: '4px',
        color: destaque ? COR.vermelho : COR.texto,
        backgroundColor: destaque ? COR.vermelhoFundo : COR.fundo,
        border: `1.5px solid ${destaque ? '#F5C4BF' : COR.borda}`,
      }}
    >
      <span style={{ color: destaque ? COR.vermelho : COR.navy }}>{icone}</span>
      <span className="flex-1">{children}</span>
      <ChevronRight size={18} style={{ color: COR.apoio }} />
    </button>
  )
}

function Rotulo({ children }: { children: React.ReactNode }) {
  return (
    <p className="font-black uppercase" style={{ fontSize: '13px', letterSpacing: '0.06em', color: COR.apoio }}>
      {children}
    </p>
  )
}

function Cartao({ children, borda }: { children: React.ReactNode; borda?: string }) {
  return (
    <div className="p-4 space-y-3" style={{ backgroundColor: COR.fundo, border: `1.5px solid ${borda ?? COR.borda}`, borderRadius: '4px' }}>
      {children}
    </div>
  )
}

function Voltar({ onClick }: { onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex items-center gap-2 font-bold"
      style={{ minHeight: '48px', fontSize: '16px', color: COR.navy }}
    >
      <ArrowLeft size={20} /> Voltar
    </button>
  )
}

/** Captura de fotos: botao grande de camera, miniaturas e contador. */
function CapturaFotos({
  fotos, onAdicionar, onRemover, capturando, carimbo, rotulo,
}: {
  fotos: FotoGuiada[]
  onAdicionar: (arquivos: File[]) => void
  onRemover: (idx: number) => void
  capturando: boolean
  carimbo: PainelGuiadoProps['carimbo']
  rotulo: string
}) {
  const ref = useRef<HTMLInputElement>(null)
  const cheio = fotos.length >= FOTOS_POR_PONTO.max
  return (
    <div className="space-y-3">
      <input
        ref={ref}
        type="file"
        accept="image/*"
        capture="environment"
        className="hidden"
        onChange={(e) => {
          const arquivos = Array.from(e.target.files ?? [])
          // Zerar permite fotografar de novo o mesmo arquivo de camera.
          e.target.value = ''
          if (arquivos.length) onAdicionar(arquivos)
        }}
      />
      {fotos.length > 0 && (
        <div className="grid grid-cols-2 gap-2">
          {fotos.map((f, idx) => (
            <div key={f.preview} className="relative overflow-hidden" style={{ border: `1px solid ${COR.borda}`, borderRadius: '4px' }}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={f.preview} alt={`Foto ${idx + 1}`} className="w-full h-32 object-cover" />
              <p className="absolute bottom-0 left-0 right-0 px-2 py-1 text-white font-mono" style={{ fontSize: '10px', backgroundColor: 'rgba(0,0,0,0.6)' }}>
                {carimbo(f.timestamp, f.gps)}
              </p>
              <button
                type="button"
                onClick={() => onRemover(idx)}
                aria-label={`Remover foto ${idx + 1}`}
                className="absolute top-1 right-1 flex items-center justify-center"
                style={{ width: '40px', height: '40px', backgroundColor: 'rgba(0,0,0,0.55)', borderRadius: '4px' }}
              >
                <X size={18} className="text-white" />
              </button>
            </div>
          ))}
        </div>
      )}
      {!cheio && (
        <button
          type="button"
          onClick={() => ref.current?.click()}
          disabled={capturando}
          className="w-full flex flex-col items-center justify-center gap-2 transition-colors disabled:opacity-60"
          style={{ minHeight: '120px', border: `2px dashed ${fotos.length ? COR.borda : COR.navy}`, borderRadius: '4px', backgroundColor: '#F8F9FB' }}
        >
          <Camera size={36} style={{ color: COR.navy }} />
          <span className="font-black" style={{ fontSize: '17px', color: COR.navy }}>
            {capturando ? 'Pegando a localização, aguarde...' : fotos.length === 0 ? rotulo : 'Tirar Outra Foto'}
          </span>
          <span style={{ fontSize: '14px', color: COR.apoio }}>
            {capturando ? 'Pode levar alguns segundos.' : 'Data, hora e localização entram sozinhas na foto.'}
          </span>
        </button>
      )}
      <p style={{ fontSize: '15px', color: fotos.length >= FOTOS_POR_PONTO.min ? COR.verde : COR.apoio, fontWeight: 700 }}>
        {fotos.length >= FOTOS_POR_PONTO.min ? <Check size={16} className="inline mr-1" /> : null}
        {fotos.length} de {FOTOS_POR_PONTO.max} fotos. Obrigatório: ao menos {FOTOS_POR_PONTO.min}.
      </p>
    </div>
  )
}

/** Seletor de viatura: sugere a do usuario e permite trocar. */
function SeletorViatura({
  viaturas, alvo, onEscolher, jaRegistradas,
}: {
  viaturas: ViaturaGuiada[]
  alvo: string | null
  onEscolher: (id: string) => void
  jaRegistradas: string[]
}) {
  return (
    <div className="space-y-2">
      <Rotulo>Viatura deste registro (obrigatório)</Rotulo>
      <div className="grid gap-2">
        {viaturas.map((v) => {
          const feita = jaRegistradas.includes(v.id)
          const escolhida = alvo === v.id
          return (
            <button
              key={v.id}
              type="button"
              disabled={feita}
              onClick={() => onEscolher(v.id)}
              className="w-full flex items-center justify-between font-black disabled:opacity-60"
              style={{
                minHeight: '56px', padding: '8px 14px', fontSize: '17px', borderRadius: '4px',
                color: escolhida ? '#fff' : COR.texto,
                backgroundColor: escolhida ? COR.navy : COR.fundo,
                border: `2px solid ${escolhida ? COR.navy : COR.borda}`,
              }}
            >
              <span>{v.placa ?? 'Sem placa'}{v.modelo ? ` · ${v.modelo}` : ''}</span>
              {feita ? (
                <span className="flex items-center gap-1" style={{ fontSize: '14px', color: COR.verde }}><Check size={16} /> Já registrada</span>
              ) : escolhida ? <Check size={20} /> : null}
            </button>
          )
        })}
      </div>
      {!alvo && (
        <p style={{ fontSize: '15px', color: COR.ambar, fontWeight: 700 }}>Toque na viatura que você está registrando.</p>
      )}
    </div>
  )
}

function Observacao({ valor, onChange, rotulo }: { valor: string; onChange: (v: string) => void; rotulo: string }) {
  const [aberta, setAberta] = useState(false)
  if (!aberta) {
    return (
      <button type="button" onClick={() => setAberta(true)} className="font-bold underline" style={{ minHeight: '48px', fontSize: '15px', color: COR.apoio }}>
        {rotulo} (opcional)
      </button>
    )
  }
  return (
    <div className="space-y-2">
      <Rotulo>{rotulo} (opcional)</Rotulo>
      <textarea
        rows={3}
        value={valor}
        onChange={(e) => onChange(e.target.value)}
        className="input-light w-full resize-none"
        style={{ fontSize: '16px' }}
      />
    </div>
  )
}

function faltando(itens: [boolean, string][]): string[] {
  return itens.filter(([ok]) => !ok).map(([, t]) => t)
}

// ─── Painel ───────────────────────────────────────────────────────────────────

export function PainelGuiado(p: PainelGuiadoProps) {
  const { escolta, proxima } = p
  const multiViatura = p.viaturas.length > 1

  // ── Confirmacao: so existe quando a gravacao aconteceu ──
  if (p.confirmacao) {
    const c = p.confirmacao
    return (
      <div className="max-w-xl mx-auto space-y-4">
        <div className="p-6 text-center space-y-3" style={{ backgroundColor: COR.verdeFundo, border: `2px solid ${COR.verde}`, borderRadius: '4px' }}>
          <CheckCircle2 size={64} className="mx-auto" style={{ color: COR.verde }} />
          <p className="font-black" style={{ fontSize: '24px', color: COR.texto }}>{c.titulo}</p>
          <p style={{ fontSize: '17px', color: COR.apoio }}>Registrado às {c.horario}</p>
          {c.detalhe && <p style={{ fontSize: '16px', color: COR.texto }}>{c.detalhe}</p>}
        </div>
        {c.avisos.map((a) => (
          <div key={a} className="flex items-start gap-2 p-3" style={{ backgroundColor: COR.ambarFundo, border: '1.5px solid #E9C46A', borderRadius: '4px' }}>
            <AlertTriangle size={20} style={{ color: COR.ambar, flexShrink: 0 }} />
            <p style={{ fontSize: '16px', color: '#5C4510', fontWeight: 700 }}>{a}</p>
          </div>
        ))}
        {proxima?.botao && (
          <Cartao>
            <Rotulo>Próxima Ação</Rotulo>
            <p className="font-black" style={{ fontSize: '18px', color: COR.texto }}>{proxima.botao}</p>
          </Cartao>
        )}
        <BotaoPrincipal onClick={p.onFecharConfirmacao} cor={COR.verde} icone={<Check size={22} />}>OK</BotaoPrincipal>
      </div>
    )
  }

  // ── Sem escolta ──
  if (!escolta) {
    return (
      <div className="max-w-xl mx-auto space-y-4">
        <h1 className="font-black" style={{ fontSize: '22px', color: COR.texto }}>Painel Operacional Guiado</h1>
        {p.semVinculoCadastro ? (
          <Cartao borda="#E9C46A">
            <p className="font-black" style={{ fontSize: '18px', color: COR.texto }}>Seu cadastro não está ligado a um vigilante</p>
            <p style={{ fontSize: '16px', color: COR.apoio }}>Sem essa ligação o sistema não mostra suas escoltas. Avise a central.</p>
          </Cartao>
        ) : p.agendadas.length > 0 ? (
          p.agendadas.map((a) => (
            <Cartao key={a.id}>
              <Rotulo>Escolta Agendada</Rotulo>
              <p className="font-black" style={{ fontSize: '20px', color: COR.texto }}>{a.cliente ?? 'Cliente'}</p>
              <p className="flex items-center gap-2" style={{ fontSize: '16px', color: COR.apoio }}>
                <Clock size={16} />
                {new Date(a.prevista).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}
                {a.codigo ? ` · ${a.codigo}` : ''}
              </p>
              <p style={{ fontSize: '16px', color: COR.texto }}>Com a equipe na base, inicie o pré-início da escolta.</p>
              <BotaoPrincipal onClick={() => p.onAbrirDetalhe('pre_inicio', a.id)} icone={<ChevronRight size={22} />}>
                Iniciar Pré-início da Escolta
              </BotaoPrincipal>
            </Cartao>
          ))
        ) : (
          <Cartao>
            <p className="font-black" style={{ fontSize: '18px', color: COR.texto }}>Nenhuma escolta para você agora</p>
            <p style={{ fontSize: '16px', color: COR.apoio }}>Veja as escoltas disponíveis para assumir.</p>
            <BotaoPrincipal onClick={p.onVerEscoltas} icone={<Shield size={22} />}>Ver Escoltas Disponíveis</BotaoPrincipal>
          </Cartao>
        )}
        <Rodape {...p} />
      </div>
    )
  }

  const etapaNum = proxima?.etapaNumero ?? 0
  const escolhaViaturaOk = !multiViatura || !!p.viaturaAlvoId

  // ── Registro de etapa ──
  const etapa = p.acaoEtapa
  if (p.painel === 'checkpoint' && etapa?.onde === 'campo') {
    const faltas = faltando([
      [escolhaViaturaOk, 'escolher a viatura'],
      [!etapa.exigeFoto || p.fotosEtapa.length >= FOTOS_POR_PONTO.min, 'tirar ao menos 1 foto'],
    ])
    return (
      <div className="max-w-xl mx-auto space-y-4 pb-4">
        <Voltar onClick={() => p.onAbrirPainel(null)} />
        <h1 className="font-black" style={{ fontSize: '22px', color: COR.texto }}>{etapa.botao}</h1>
        <p style={{ fontSize: '17px', color: COR.apoio }}>{etapa.instrucao}</p>
        {multiViatura && (
          <Cartao>
            <SeletorViatura viaturas={p.viaturas} alvo={p.viaturaAlvoId} onEscolher={p.onEscolherViatura} jaRegistradas={p.viaturasJaRegistradas} />
          </Cartao>
        )}
        {etapa.exigeFoto && (
          <Cartao>
            <Rotulo>Fotos (obrigatório)</Rotulo>
            <CapturaFotos fotos={p.fotosEtapa} onAdicionar={p.onAdicionarFotosEtapa} onRemover={p.onRemoverFotoEtapa} capturando={p.capturandoFoto} carimbo={p.carimbo} rotulo="Tirar Foto" />
          </Cartao>
        )}
        <Observacao valor={p.obsEtapa} onChange={p.onObsEtapa} rotulo="Observação" />
        {faltas.length > 0 && (
          <p className="font-bold" style={{ fontSize: '16px', color: COR.ambar }}>Falta: {faltas.join(' e ')}.</p>
        )}
        <BotaoPrincipal onClick={p.onConfirmarEtapa} disabled={p.executando || p.capturandoFoto || faltas.length > 0} cor={COR.verde} icone={<Check size={22} />}>
          {p.executando ? 'Enviando, aguarde...' : `Confirmar: ${etapa.botao}`}
        </BotaoPrincipal>
      </div>
    )
  }

  // ── Check-in ──
  if (p.painel === 'checkin') {
    const faltas = faltando([
      [escolhaViaturaOk, 'escolher a viatura'],
      [p.fotosCheckin.length >= FOTOS_POR_PONTO.min, 'tirar ao menos 1 foto'],
    ])
    return (
      <div className="max-w-xl mx-auto space-y-4 pb-4">
        <Voltar onClick={() => p.onAbrirPainel(null)} />
        <h1 className="font-black" style={{ fontSize: '22px', color: COR.texto }}>Registrar Check-in</h1>
        <p style={{ fontSize: '17px', color: COR.apoio }}>Tire a foto do local. A localização é obrigatória no check-in.</p>
        {multiViatura && (
          <Cartao>
            <SeletorViatura viaturas={p.viaturas} alvo={p.viaturaAlvoId} onEscolher={p.onEscolherViatura} jaRegistradas={[]} />
          </Cartao>
        )}
        <Cartao>
          <Rotulo>Fotos (obrigatório)</Rotulo>
          <CapturaFotos fotos={p.fotosCheckin} onAdicionar={p.onAdicionarFotosCheckin} onRemover={p.onRemoverFotoCheckin} capturando={p.capturandoFoto} carimbo={p.carimbo} rotulo="Tirar Foto do Local" />
        </Cartao>
        <Observacao valor={p.obsCheckin} onChange={p.onObsCheckin} rotulo="Observação" />
        {faltas.length > 0 && (
          <p className="font-bold" style={{ fontSize: '16px', color: COR.ambar }}>Falta: {faltas.join(' e ')}.</p>
        )}
        <BotaoPrincipal onClick={p.onConfirmarCheckin} disabled={p.executando || p.capturandoFoto || faltas.length > 0} cor={COR.verde} icone={<Radio size={22} />}>
          {p.executando ? 'Enviando, aguarde...' : 'Confirmar Check-in'}
        </BotaoPrincipal>
      </div>
    )
  }

  // ── Ocorrencia ──
  if (p.painel === 'ocorrencia') {
    const faltas = faltando([
      [!!p.tipoOcId, 'escolher o tipo'],
      [!!p.descOc.trim(), 'descrever o que aconteceu'],
    ])
    return (
      <div className="max-w-xl mx-auto space-y-4 pb-4">
        <Voltar onClick={() => p.onAbrirPainel(null)} />
        <h1 className="font-black" style={{ fontSize: '22px', color: COR.texto }}>Registrar Ocorrência</h1>
        <Cartao>
          <Rotulo>1. Tipo (obrigatório)</Rotulo>
          <select value={p.tipoOcId} onChange={(e) => p.onTipoOc(e.target.value)} className="select-light w-full" style={{ minHeight: '56px', fontSize: '16px' }}>
            <option value="">Toque para escolher...</option>
            {p.tiposOcorrencia.map((t) => <option key={t.id} value={t.id}>{t.nome}</option>)}
          </select>
        </Cartao>
        <Cartao>
          <Rotulo>2. O que aconteceu (obrigatório)</Rotulo>
          {/* Ocorrencia nunca abre preenchida: existe porque algo fugiu do previsto. */}
          <textarea rows={4} value={p.descOc} onChange={(e) => p.onDescOc(e.target.value)} placeholder={p.placeholderOc} className="input-light w-full resize-none" style={{ fontSize: '16px' }} />
        </Cartao>
        <Cartao>
          <Rotulo>3. Foto (recomendado)</Rotulo>
          <CapturaFotos
            fotos={p.fotoOc ? [p.fotoOc] : []}
            onAdicionar={(arqs) => arqs[0] && p.onFotoOc(arqs[0])}
            onRemover={p.onLimparFotoOc}
            capturando={p.capturandoFoto}
            carimbo={p.carimbo}
            rotulo="Tirar Foto da Ocorrência"
          />
        </Cartao>
        {faltas.length > 0 && (
          <p className="font-bold" style={{ fontSize: '16px', color: COR.ambar }}>Falta: {faltas.join(' e ')}.</p>
        )}
        <BotaoPrincipal onClick={p.onConfirmarOcorrencia} disabled={p.executando || faltas.length > 0} cor={COR.navy} icone={<FileText size={22} />}>
          {p.executando ? 'Enviando, aguarde...' : 'Confirmar Ocorrência'}
        </BotaoPrincipal>
      </div>
    )
  }

  // ── Tela inicial do painel ──
  const destinoMapa = etapaNum <= 3 ? escolta.origem : etapaNum <= 5 ? escolta.destino : null

  return (
    <div className="max-w-xl mx-auto space-y-4">
      {p.escoltasParaEscolher.length > 1 && (
        <div className="space-y-2">
          <Rotulo>Escolha a escolta</Rotulo>
          <div className="flex flex-wrap gap-2">
            {p.escoltasParaEscolher.map((e) => (
              <button
                key={e.id}
                type="button"
                onClick={() => p.onSelecionarEscolta(e.id)}
                className="font-bold"
                style={{
                  minHeight: '48px', padding: '6px 14px', fontSize: '15px', borderRadius: '4px',
                  color: e.id === escolta.id ? '#fff' : COR.texto,
                  backgroundColor: e.id === escolta.id ? COR.navy : COR.fundo,
                  border: `1.5px solid ${e.id === escolta.id ? COR.navy : COR.borda}`,
                }}
              >
                {e.codigo ?? 'Sem código'}{e.cliente ? ` · ${e.cliente}` : ''}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Escolta e etapa */}
      <div style={{ backgroundColor: COR.fundo, border: `1.5px solid ${COR.borda}`, borderRadius: '4px', overflow: 'hidden' }}>
        <div style={{ height: '6px', backgroundColor: escolta.cor ?? COR.navy }} />
        <div className="p-4 space-y-2">
          <p className="font-black leading-tight" style={{ fontSize: '22px', color: COR.texto }}>{escolta.cliente ?? 'Escolta'}</p>
          <p style={{ fontSize: '14px', color: COR.apoio }}>{escolta.codigo ?? 'Sem código'}</p>
          {proxima && etapaNum > 0 && (
            <>
              <p className="font-bold" style={{ fontSize: '17px', color: COR.navy }}>
                Etapa {etapaNum} de {TOTAL_ETAPAS}: {proxima.etapaNome}
              </p>
              <div className="flex gap-1" aria-hidden>
                {Array.from({ length: TOTAL_ETAPAS }).map((_, i) => (
                  <div key={i} className="flex-1" style={{ height: '8px', borderRadius: '2px', backgroundColor: i < etapaNum - 1 ? COR.verde : i === etapaNum - 1 ? COR.navy : COR.cinza }} />
                ))}
              </div>
            </>
          )}
        </div>
      </div>

      {/* Proxima Acao */}
      {proxima && (
        <div className="p-4 space-y-3" style={{ backgroundColor: proxima.urgente ? COR.vermelhoFundo : '#F0F3FA', border: `2px solid ${proxima.urgente ? COR.vermelho : COR.navy}`, borderRadius: '4px' }}>
          <Rotulo>Próxima Ação</Rotulo>
          <p className="font-bold" style={{ fontSize: '18px', color: COR.texto, lineHeight: 1.35 }}>{proxima.instrucao}</p>
          {proxima.botao && (
            <BotaoPrincipal
              cor={proxima.urgente ? COR.vermelho : COR.navy}
              icone={proxima.onde === 'checkin' ? <Radio size={22} /> : proxima.exigeFoto ? <Camera size={22} /> : <ChevronRight size={22} />}
              onClick={() => {
                if (proxima.onde === 'checkin') p.onAbrirPainel('checkin')
                else if (proxima.onde === 'campo') p.onAbrirPainel('checkpoint')
                else if (proxima.onde === 'detalhe') p.onAbrirDetalhe(proxima.acaoDetalhe)
              }}
            >
              {proxima.botao}
            </BotaoPrincipal>
          )}
          {proxima.onde === 'detalhe' && (
            <p style={{ fontSize: '14px', color: COR.apoio }}>Abre a tela da escolta. Ao concluir, você volta para este painel.</p>
          )}
        </div>
      )}

      {/* Pendencias */}
      <Cartao>
        <Rotulo>Pendências da Escolta</Rotulo>
        {p.pendencias.length === 0 ? (
          <p className="flex items-center gap-2 font-bold" style={{ fontSize: '16px', color: COR.verde }}><Check size={18} /> Nenhuma pendência</p>
        ) : (
          <ul className="space-y-2">
            {p.pendencias.map((pd) => (
              <li key={pd.texto} className="flex items-start gap-2 font-bold" style={{ fontSize: '16px', color: pd.nivel === 'alerta' ? COR.vermelho : COR.ambar }}>
                <AlertTriangle size={18} style={{ flexShrink: 0, marginTop: '2px' }} /> {pd.texto}
              </li>
            ))}
          </ul>
        )}
      </Cartao>

      {/* Outras Acoes */}
      <div className="space-y-2">
        <Rotulo>Outras Ações</Rotulo>
        {p.checkinDisponivel && proxima?.onde !== 'checkin' && (
          <BotaoSecundario onClick={() => p.onAbrirPainel('checkin')} icone={<Radio size={20} />}>Registrar Check-in</BotaoSecundario>
        )}
        {p.paradaDisponivel && (
          <BotaoSecundario onClick={() => p.onAbrirDetalhe('parada')} icone={<Octagon size={20} />}>Registrar Parada</BotaoSecundario>
        )}
        {proxima?.onde === 'checkin' && etapa?.botao && (
          <BotaoSecundario
            onClick={() => (etapa.onde === 'campo' ? p.onAbrirPainel('checkpoint') : p.onAbrirDetalhe(etapa.acaoDetalhe))}
            icone={<Camera size={20} />}
          >
            {etapa.botao}
          </BotaoSecundario>
        )}
        <BotaoSecundario onClick={() => p.onAbrirPainel('ocorrencia')} icone={<FileText size={20} />}>Registrar Ocorrência</BotaoSecundario>
        {destinoMapa && (
          <BotaoSecundario
            onClick={() => window.open(`https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(destinoMapa)}`, '_blank', 'noopener')}
            icone={<MapIcon size={20} />}
          >
            Abrir Rota no Mapa
          </BotaoSecundario>
        )}
        <BotaoSecundario onClick={() => p.onAbrirDetalhe()} icone={<Shield size={20} />}>Ver Detalhes da Escolta</BotaoSecundario>
      </div>

      {/* Emergencia: fixa acima da barra inferior, dois toques */}
      <div className="sticky bottom-[calc(4.75rem_+_env(safe-area-inset-bottom))] md:bottom-4 z-30 pt-2">
        {!p.emergConfirm ? (
          <button
            type="button"
            onClick={p.onEmergIniciar}
            className="w-full flex items-center justify-center gap-3 font-black uppercase tracking-wide active:scale-[0.98]"
            style={{ minHeight: '64px', fontSize: '18px', color: '#fff', backgroundColor: COR.vermelho, borderRadius: '4px', boxShadow: '0 4px 16px rgba(184,56,50,0.35)' }}
          >
            <Zap size={24} /> Acionar Emergência
          </button>
        ) : (
          <div className="p-4 space-y-3" style={{ backgroundColor: COR.vermelhoFundo, border: `2px solid ${COR.vermelho}`, borderRadius: '4px' }}>
            <p className="text-center font-black" style={{ fontSize: '19px', color: COR.vermelho }}>Confirmar Emergência?</p>
            <p className="text-center" style={{ fontSize: '15px', color: COR.texto }}>A central será avisada agora. Use só em situação real.</p>
            <div className="flex gap-2">
              <button type="button" onClick={p.onEmergCancelar} className="flex-1 font-bold" style={{ minHeight: '56px', fontSize: '16px', backgroundColor: '#fff', border: `1.5px solid ${COR.borda}`, borderRadius: '4px', color: COR.texto }}>
                Cancelar
              </button>
              <button type="button" onClick={p.onEmergConfirmar} disabled={p.executando} className="flex-1 font-black uppercase disabled:opacity-50" style={{ minHeight: '56px', fontSize: '16px', backgroundColor: COR.vermelho, borderRadius: '4px', color: '#fff' }}>
                {p.executando ? 'Acionando...' : 'Confirmar'}
              </button>
            </div>
          </div>
        )}
      </div>

      <Rodape {...p} />
    </div>
  )
}

function Rodape(p: PainelGuiadoProps) {
  if (!p.podeDesligar) return null
  return (
    <div className="text-center pt-2 pb-2">
      <button type="button" onClick={p.onDesligarModo} className="underline" style={{ minHeight: '44px', fontSize: '14px', color: COR.apoio }}>
        Modo Guiado ligado. Ver tela completa
      </button>
    </div>
  )
}
