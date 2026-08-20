'use client'

import { useEffect, useState, useCallback, useRef, Suspense } from 'react'
import { useRouter, useSearchParams } from 'next/navigation'
import {
  ArrowLeft, ArrowRight, Plus, Trash2, CheckCircle,
  MapPin, Flag, FileText, Briefcase, Radio, Building2,
  Car, Shield, UserCheck, AlertTriangle, DollarSign
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { AiTextButton } from '@/components/ui/ai-text-button'

// ─── Palette ──────────────────────────────────────────────────────────────────
const P = {
  navy:     '#1A294A',
  navyMid:  '#253562',
  steel:    '#53648A',
  khaki:    '#9F906D',
  light:    '#ABB5C9',
  bg:       '#EEF0F5',
  surface:  '#FFFFFF',
  border:   '#D6DAE5',
  text:     '#0E1A33',
  sub:      '#5A6A80',
  success:  '#1E7C52',
  error:    '#B83832',
}

// ─── Types ────────────────────────────────────────────────────────────────────
interface ClienteOpt    { id: string; nome_cliente: string; cor_destaque: string; valor_padrao_escolta: number | null }
interface VeiculoOpt    { id: string; placa: string; modelo: string | null; tipo: { nome: string } | null }
interface VigilanteOpt  { id: string; nome_completo: string; funcao: { nome: string } | null; valor_padrao_pago: number | null }

interface MembroForm    { uid: string; vigilante_id: string; papel_na_escolta: 'comandante' | 'operador'; valor_pago: string }

const PERFIS_FINANCEIRO = ['administrador', 'gestor', 'supervisor']
interface ViaturaForm   { uid: string; veiculo_id: string; membros: MembroForm[] }
interface DadosBasicos  {
  cliente_id: string
  data_prevista: string
  hora_prevista_h: string
  hora_prevista_m: string
  origem_endereco: string
  origem_complemento: string
  origem_lat: number
  origem_lng: number
  destino_endereco: string
  destino_complemento: string
  destino_lat: number
  destino_lng: number
  observacoes: string
}

const sb = createClient() as any
const uid = () => Math.random().toString(36).slice(2)
const novaViatura = (): ViaturaForm => ({ uid: uid(), veiculo_id: '', membros: [] })
const novoMembro  = (): MembroForm  => ({ uid: uid(), vigilante_id: '', papel_na_escolta: 'operador', valor_pago: '' })
const HORAS = Array.from({ length: 24 }, (_, i) => String(i).padStart(2, '0'))
const MINS  = ['00','05','10','15','20','25','30','35','40','45','50','55']
const STEPS = ['Dados da Escolta', 'Efetivo e Veículos', 'Revisar e Confirmar']

// ─── Componentes de campo ─────────────────────────────────────────────────────
function FieldLabel({ children, required }: { children: React.ReactNode; required?: boolean }) {
  return (
    <label className="block text-[10px] font-black uppercase tracking-[0.14em] mb-1.5" style={{ color: P.sub }}>
      {children}{required && <span style={{ color: P.error }}> *</span>}
    </label>
  )
}

function FieldWrap({ children, icon }: { children: React.ReactNode; icon?: React.ReactNode }) {
  return (
    <div
      className="flex items-center gap-2.5 px-3 py-2.5 transition-all"
      style={{
        backgroundColor: P.surface,
        border: `1.5px solid ${P.border}`,
        borderRadius: '2px',
      }}
      onFocusCapture={e => (e.currentTarget.style.borderColor = P.steel)}
      onBlurCapture={e  => (e.currentTarget.style.borderColor = P.border)}
    >
      {icon && <span style={{ color: P.light, flexShrink: 0 }}>{icon}</span>}
      {children}
    </div>
  )
}

const inputCls = "bg-transparent border-0 outline-none w-full text-sm font-medium"
const inputStyle = { color: P.text }

const OBS_PADRAO = `Verificar na saída: (1) documentação do veículo e carga, (2) comunicação operacional ativa, (3) armamento e munição do efetivo, (4) rota principal e alternativa confirmadas. Reportar ao supervisor: saída da base, chegada na origem, saída para o destino e chegada ao destino.`

// O complemento é texto livre e nunca entra na busca da Mapbox nem na validação de
// coordenada: ele só se junta ao endereço na hora de gravar, para a equipe achar o
// apartamento, o portão ou a doca sem descobrir o resto por rádio.
const enderecoComComplemento = (endereco: string, complemento: string) =>
  [endereco.trim(), complemento.trim()].filter(Boolean).join(', ')

/**
 * O endereco vai concatenado com o complemento para a coluna, porque e assim que ele
 * precisa aparecer no mapa, no relatorio e na tela do operador. Mas o complemento
 * TAMBEM e guardado separado em `metadados`, e e de la que a edicao o recupera.
 *
 * O motivo e que separar de volta pela virgula seria adivinhacao: o endereco do Mapbox
 * ja vem cheio de virgulas ("Rua X, 100 - Centro, Jacarei - Sao Paulo, 12310, Brasil"),
 * entao nao ha como saber qual delas marca o inicio do complemento. Guardar a parte
 * separada custa um campo em JSON e elimina o palpite.
 */
interface ComplementosSalvos {
  origem_complemento?: string
  destino_complemento?: string
  observacoes?: string
}

// ─── Autocomplete de Endereço (Mapbox Geocoding) ──────────────────────────────
interface MapboxFeature {
  id: string
  place_name: string
  center: [number, number]
}

function AddressAutocomplete({
  value,
  onChange,
  placeholder,
  icon,
}: {
  value: string
  onChange: (address: string, lat?: number, lon?: number) => void
  placeholder: string
  icon?: React.ReactNode
}) {
  const [query, setQuery]             = useState(value)
  const [suggestions, setSuggestions] = useState<MapboxFeature[]>([])
  const [carregando, setCarregando]   = useState(false)
  const [erroApi, setErroApi]         = useState<string | null>(null)
  const [aberto, setAberto]           = useState(false)
  const debounceRef  = useRef<ReturnType<typeof setTimeout> | null>(null)
  const wrapRef      = useRef<HTMLDivElement>(null)
  const proximidade  = useRef('-43.1729,-22.9068') // lon,lat — RJ default, atualiza via GPS
  // Escolher uma sugestão troca o texto do input, e isso reentra no efeito de busca.
  // Sem esta marca a busca dispararia de novo e reabriria a lista já fechada.
  const puloRef      = useRef(false)
  // Sequência do ciclo de busca: resposta de ciclo antigo é descartada em vez de
  // sobrescrever o resultado do ciclo atual.
  const seqRef       = useRef(0)

  // Encerra o ciclo de busca em voo. Toda escrita de estado do ciclo passa antes pela
  // comparação de sequência, então basta avançar a sequência para que a resposta
  // atrasada não repovoe as sugestões nem reabra a lista. Cancela também o debounce,
  // porque uma busca que ainda nem saiu não deve sair, e desliga o spinner, já que o
  // finally daquele ciclo não vai mais rodar.
  const invalidarBusca = useCallback(() => {
    if (debounceRef.current) { clearTimeout(debounceRef.current); debounceRef.current = null }
    seqRef.current++
    setCarregando(false)
  }, [])

  useEffect(() => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return
    navigator.geolocation.getCurrentPosition(
      (p) => { proximidade.current = `${p.coords.longitude},${p.coords.latitude}` },
      () => {},
      { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 }
    )
  }, [])

  useEffect(() => { setQuery(value) }, [value])

  useEffect(() => {
    if (puloRef.current) { puloRef.current = false; return }

    if (debounceRef.current) clearTimeout(debounceRef.current)
    if (query.trim().length < 3) {
      // Invalidar antes de fechar: a resposta de uma busca já a caminho poderia chegar
      // depois e reabrir a lista de um campo que o usuário acabou de esvaziar.
      invalidarBusca()
      setSuggestions([])
      setAberto(false)
      setErroApi(null)
      return
    }

    const seq = ++seqRef.current
    const controller = new AbortController()

    debounceRef.current = setTimeout(async () => {
      setCarregando(true)
      setErroApi(null)
      try {
        const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN
        const q = encodeURIComponent(query.trim())
        const res = await fetch(
          `https://api.mapbox.com/geocoding/v5/mapbox.places/${q}.json?access_token=${token}&country=br&language=pt&autocomplete=true&proximity=${proximidade.current}&types=address,neighborhood,place,postcode,poi&limit=6`,
          { signal: controller.signal }
        )
        if (seq !== seqRef.current) return
        if (!res.ok) { setErroApi(`Erro ${res.status}`); return }
        const data = await res.json()
        if (seq !== seqRef.current) return
        if (data.message) { setErroApi(data.message); return }
        const features: MapboxFeature[] = data.features ?? []
        setSuggestions(features)
        setAberto(features.length > 0)
      } catch (e) {
        // Aborto é encerramento normal do ciclo, não falha de rede: não vira mensagem.
        if ((e as { name?: string } | null)?.name === 'AbortError') return
        if (seq !== seqRef.current) return
        setErroApi(e instanceof Error ? e.message : 'Erro de conexão')
      } finally {
        if (seq === seqRef.current) setCarregando(false)
      }
    }, 400)

    return () => {
      if (debounceRef.current) { clearTimeout(debounceRef.current); debounceRef.current = null }
      controller.abort()
    }
  }, [query, invalidarBusca])

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        // Fechar não basta: clicar fora não muda a query nem desmonta o campo, então o
        // ciclo em voo continua válido e a resposta atrasada reabriria a lista por cima
        // do resto do formulário. Invalidar junto com o fechamento, como na seleção.
        invalidarBusca()
        setAberto(false)
      }
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [invalidarBusca])

  // Ponto único de seleção. Invalida a busca em voo antes de fechar a lista, senão a
  // resposta que ainda estava a caminho reabriria as sugestões depois do clique.
  const selecionar = (f: MapboxFeature) => {
    invalidarBusca()
    puloRef.current = true
    const [lon, lat] = f.center
    setQuery(f.place_name)
    onChange(f.place_name, lat, lon)
    setSuggestions([])
    setAberto(false)
    setErroApi(null)
  }

  return (
    <div ref={wrapRef} style={{ position: 'relative' }}>
      <div
        className="flex items-center gap-2.5 px-3 py-2.5 transition-all"
        style={{ backgroundColor: P.surface, border: `1.5px solid ${aberto ? P.steel : P.border}`, borderRadius: '2px' }}
      >
        {icon && <span style={{ color: P.light, flexShrink: 0 }}>{icon}</span>}
        <input
          type="text"
          value={query}
          onChange={e => {
            // Digitação sempre volta a valer, inclusive quando o endereço escolhido era
            // idêntico ao texto já digitado e o efeito de busca não chegou a reentrar.
            puloRef.current = false
            setQuery(e.target.value)
            onChange(e.target.value)
          }}
          onFocus={() => suggestions.length > 0 && setAberto(true)}
          placeholder={placeholder}
          className={inputCls}
          style={inputStyle}
          autoComplete="off"
        />
        {carregando && (
          <div className="animate-spin shrink-0" style={{ width: '14px', height: '14px', border: '2px solid #D6DAE5', borderTopColor: P.steel, borderRadius: '50%' }} />
        )}
      </div>

      {erroApi && (
        <p style={{ fontSize: '10px', color: '#B83832', marginTop: '3px' }}>Mapbox: {erroApi}</p>
      )}

      {aberto && suggestions.length > 0 && (
        <div style={{
          position: 'absolute', top: 'calc(100% + 2px)', left: 0, right: 0, zIndex: 200,
          backgroundColor: P.surface, border: `1.5px solid ${P.steel}`,
          boxShadow: '0 8px 24px rgba(26,41,74,0.18)', maxHeight: '280px', overflowY: 'auto',
        }}>
          {suggestions.map((f, i) => {
            const partes = f.place_name.split(',')
            const principal   = partes.slice(0, 2).join(',').trim()
            const secundario  = partes.slice(2).join(',').trim()
            return (
              <button
                key={f.id}
                type="button"
                // preventDefault no mousedown impede o blur do input de competir com o clique
                onMouseDown={e => e.preventDefault()}
                onClick={() => selecionar(f)}
                className="w-full text-left"
                style={{
                  display: 'block', padding: '9px 12px',
                  borderBottom: i < suggestions.length - 1 ? `1px solid ${P.border}` : 'none',
                  cursor: 'pointer',
                }}
                onMouseEnter={e => (e.currentTarget as HTMLElement).style.backgroundColor = P.bg}
                onMouseLeave={e => (e.currentTarget as HTMLElement).style.backgroundColor = ''}
              >
                <p style={{ fontSize: '12px', fontWeight: 600, color: P.text }}>{principal}</p>
                {secundario && <p style={{ fontSize: '10px', color: P.light, marginTop: '2px' }}>{secundario}</p>}
              </button>
            )
          })}
          <div style={{ padding: '4px 10px', borderTop: `1px solid ${P.border}`, backgroundColor: '#F8FAFC', textAlign: 'right' }}>
            <span style={{ fontSize: '9px', color: '#A8B8C2' }}>© Mapbox © OpenStreetMap</span>
          </div>
        </div>
      )}
    </div>
  )
}

// ─── Page ─────────────────────────────────────────────────────────────────────

/**
 * `useSearchParams` obriga a um limite de Suspense no App Router: sem ele, o
 * `next build` falha na pre-renderizacao desta rota. O componente de dentro e quem le
 * o parametro `editar`.
 */
export default function NovaEscoltaPage() {
  return (
    <Suspense fallback={
      <div className="max-w-3xl mx-auto py-16 text-center">
        <p className="text-sm" style={{ color: P.sub }}>Carregando…</p>
      </div>
    }>
      <FormularioEscolta />
    </Suspense>
  )
}

function FormularioEscolta() {
  const router  = useRouter()
  const { user } = useAuth()

  const [step, setStep]         = useState<1|2|3>(1)
  const [erros, setErros]       = useState<string[]>([])
  const [salvando, setSalvando] = useState(false)

  const [dados, setDados] = useState<DadosBasicos>({
    cliente_id: '', data_prevista: '',
    hora_prevista_h: '08', hora_prevista_m: '00',
    origem_endereco: '', origem_complemento: '', origem_lat: 0, origem_lng: 0,
    destino_endereco: '', destino_complemento: '', destino_lat: 0, destino_lng: 0,
    observacoes: OBS_PADRAO,
  })
  const [viaturas,    setViaturas]    = useState<ViaturaForm[]>([novaViatura()])
  const [clientes,    setClientes]    = useState<ClienteOpt[]>([])
  const [veiculos,    setVeiculos]    = useState<VeiculoOpt[]>([])
  const [vigilantes,  setVigilantes]  = useState<VigilanteOpt[]>([])

  // ── Modo edicao ───────────────────────────────────────────────────────────
  //
  // Decisao de Pecanha em 2026-08-19: enquanto a escolta nao comecou, a gestao edita
  // tudo, inclusive viatura, local e vigilante. Nao existia edicao nenhuma no sistema:
  // o botao "Editar" da lista so abria a tela de detalhe.
  //
  // Esta tela e reaproveitada em vez de se criar uma segunda, porque ela ja tem o
  // seletor de endereco corrigido, o campo de complemento, as viaturas e o efetivo.
  // Duas telas com os mesmos campos divergem no primeiro ajuste que alguem esquecer
  // de replicar, e este projeto ja pagou esse preco.
  const params = useSearchParams()
  const editandoId = params.get('editar')
  const [carregandoEdicao, setCarregandoEdicao] = useState(!!editandoId)
  const [bloqueioEdicao, setBloqueioEdicao] = useState<string | null>(null)
  const [valorCobrado, setValorCobrado] = useState('')
  const [outrosCustos, setOutrosCustos] = useState('')
  const [obsFinanceiro, setObsFinanceiro] = useState('')
  const [periodicidadeCheckin, setPeriodicidadeCheckin] = useState('30')
  const verFinanceiro = PERFIS_FINANCEIRO.includes((user?.perfil?.codigo ?? '') as any)

  const carregar = useCallback(async () => {
    const [{ data: cls }, { data: vcs }, { data: vgs }] = await Promise.all([
      sb.from('clientes').select('id, nome_cliente, cor_destaque, valor_padrao_escolta').eq('status', 'ativo').order('nome_cliente'),
      sb.from('veiculos').select('id, placa, modelo, tipo:dom_tipos_veiculo(nome)').eq('status', 'ativo').order('placa'),
      sb.from('vigilantes').select('id, nome_completo, funcao:dom_funcoes(nome), valor_padrao_pago').eq('status', 'ativo').order('nome_completo'),
    ])
    setClientes(cls ?? [])
    setVeiculos(vcs ?? [])
    setVigilantes(vgs ?? [])
  }, [])

  useEffect(() => { carregar() }, [carregar])

  /**
   * Carrega a escolta para edicao e desmonta o endereco de volta em base e complemento.
   *
   * O banco guarda os dois juntos numa coluna so, entao o complemento e reconhecido pelo
   * separador usado na gravacao. Se o endereco nao tiver o separador, ele vai inteiro
   * para o campo base e o complemento fica vazio, que e o comportamento certo para as
   * escoltas criadas antes de o campo existir.
   */
  const carregarParaEdicao = useCallback(async () => {
    if (!editandoId) return
    setCarregandoEdicao(true)
    try {
      const { data: e, error } = await sb
        .from('escoltas')
        .select(`
          id, cliente_id, status, data_hora_prevista, metadados,
          origem_endereco, origem_lat, origem_lng,
          destino_endereco, destino_lat, destino_lng,
          periodicidade_checkin_min, valor_cobrado, outros_custos, observacao_financeira,
          veiculos:escolta_veiculos(
            id, veiculo_id,
            efetivo:escolta_efetivo(id, vigilante_id, papel_na_escolta, valor_pago_vigilante)
          )
        `)
        .eq('id', editandoId)
        .maybeSingle()

      if (error) throw new Error(error.message)
      if (!e) { setBloqueioEdicao('Escolta não encontrada.'); return }

      // A trava real esta no banco; aqui e so para nao abrir um formulario que nao vai
      // conseguir salvar.
      if (!['rascunho', 'agendada'].includes(e.status)) {
        setBloqueioEdicao('Esta escolta já começou e não pode mais ser editada. Para corrigir algo, fale com a gestão.')
        return
      }

      const dt = new Date(e.data_hora_prevista)
      const meta = (e.metadados ?? {}) as ComplementosSalvos

      // O complemento vem de `metadados`, nao de dividir o endereco pela virgula: o
      // endereco do Mapbox ja tem virgulas proprias e nao ha como distinguir.
      // Escolta criada antes deste campo existir simplesmente vem sem complemento, com
      // o endereco inteiro no campo base, que e o correto.
      const origComp = meta.origem_complemento ?? ''
      const destComp = meta.destino_complemento ?? ''
      const tirarSufixo = (completo: string, comp: string) =>
        comp && completo.endsWith(`, ${comp}`)
          ? completo.slice(0, -(comp.length + 2))
          : completo

      setDados({
        cliente_id: e.cliente_id ?? '',
        data_prevista: dt.toISOString().slice(0, 10),
        hora_prevista_h: String(dt.getHours()).padStart(2, '0'),
        hora_prevista_m: String(dt.getMinutes()).padStart(2, '0'),
        origem_endereco: tirarSufixo(e.origem_endereco ?? '', origComp),
        origem_complemento: origComp,
        origem_lat: Number(e.origem_lat ?? 0), origem_lng: Number(e.origem_lng ?? 0),
        destino_endereco: tirarSufixo(e.destino_endereco ?? '', destComp),
        destino_complemento: destComp,
        destino_lat: Number(e.destino_lat ?? 0), destino_lng: Number(e.destino_lng ?? 0),
        observacoes: meta.observacoes ?? '',
      })

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const vts = (e.veiculos ?? []) as any[]
      setViaturas(vts.length
        ? vts.map((v) => ({
            uid: uid(),
            veiculo_id: v.veiculo_id ?? '',
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            membros: (v.efetivo ?? []).map((m: any) => ({
              uid: uid(),
              vigilante_id: m.vigilante_id ?? '',
              papel_na_escolta: (m.papel_na_escolta === 'comandante' ? 'comandante' : 'operador') as 'comandante' | 'operador',
              valor_pago: m.valor_pago_vigilante != null ? String(m.valor_pago_vigilante) : '',
            })),
          }))
        : [novaViatura()])

      setPeriodicidadeCheckin(e.periodicidade_checkin_min != null ? String(e.periodicidade_checkin_min) : '30')
      setValorCobrado(e.valor_cobrado != null ? String(e.valor_cobrado) : '')
      setOutrosCustos(e.outros_custos != null ? String(e.outros_custos) : '')
      setObsFinanceiro(e.observacao_financeira ?? '')
    } catch (err) {
      setBloqueioEdicao(err instanceof Error ? err.message : 'Não foi possível carregar a escolta.')
    } finally {
      setCarregandoEdicao(false)
    }
  }, [editandoId])

  useEffect(() => { carregarParaEdicao() }, [carregarParaEdicao])

  // ── Validações ────────────────────────────────────────────────────────────
  const validar1 = () => {
    const e: string[] = []
    if (!dados.cliente_id)              e.push('Selecione o cliente contratante.')
    if (!dados.data_prevista)           e.push('Informe a data de partida.')
    if (!dados.origem_endereco.trim())  e.push('Informe o endereço de origem.')
    // Coordenada zerada cai no golfo da Guiné e envenena mapa, rota e indicadores.
    else if (!dados.origem_lat || !dados.origem_lng)
      e.push('Origem sem coordenada. Selecione o endereço na lista de sugestões para fixar as coordenadas.')
    if (!dados.destino_endereco.trim()) e.push('Informe o endereço de destino.')
    else if (!dados.destino_lat || !dados.destino_lng)
      e.push('Destino sem coordenada. Selecione o endereço na lista de sugestões para fixar as coordenadas.')
    return e
  }

  /**
   * A equipe passou a ser OPCIONAL, e isso e o que faz o mural existir de verdade.
   *
   * Enquanto escalar vigilante era obrigatorio, toda escolta nascia com equipe, e o mural
   * (que so mostra agendada SEM equipe) ficava permanentemente vazio: o operador nunca
   * tinha o que puxar. O recurso existia e era inalcancavel.
   *
   * Agora: viatura continua obrigatoria, porque sem ela o operador nao consegue registrar
   * ponto de controle nenhum e `puxar_escolta` recusa. Vigilante fica de fora: deixar em
   * branco manda a escolta para o mural. Quem for preenchido, porem, tem de estar
   * completo, e uma viatura com gente precisa de comandante.
   */
  const validar2 = () => {
    const e: string[] = []
    if (!viaturas.length) { e.push('Adicione ao menos uma viatura.'); return e }
    viaturas.forEach((v, i) => {
      if (!v.veiculo_id) e.push(`Viatura ${i+1}: selecione o veículo.`)
      v.membros.forEach((m, j) => {
        if (!m.vigilante_id) e.push(`Viatura ${i+1}, membro ${j+1}: selecione o vigilante ou remova a linha.`)
      })
      if (v.membros.length > 0 && !v.membros.some(m => m.papel_na_escolta === 'comandante'))
        e.push(`Viatura ${i+1}: defina um Comandante entre os vigilantes escalados.`)
    })
    return e
  }

  /** Verdadeiro quando nenhuma viatura tem gente: a escolta vai para o mural. */
  const iraParaOMural = viaturas.every(v => v.membros.length === 0)

  const avancar = () => {
    const e = step === 1 ? validar1() : step === 2 ? validar2() : []
    if (e.length) { setErros(e); return }
    setErros([])
    setStep(s => (s + 1) as 1|2|3)
  }

  const voltar = () => { setErros([]); setStep(s => (s - 1) as 1|2|3) }

  // ── Salvar ────────────────────────────────────────────────────────────────
  const salvar = async () => {
    setSalvando(true)
    setErros([])
    try {
      const dtStr = `${dados.data_prevista}T${dados.hora_prevista_h}:${dados.hora_prevista_m}:00`

      // O complemento vai junto no endereco, para aparecer no mapa e no relatorio, E
      // separado em metadados, para a edicao conseguir recuperar sem adivinhar onde ele
      // comeca. Ver o comentario de ComplementosSalvos.
      const meta: ComplementosSalvos = {}
      if (dados.observacoes.trim()) meta.observacoes = dados.observacoes.trim()
      if (dados.origem_complemento.trim()) meta.origem_complemento = dados.origem_complemento.trim()
      if (dados.destino_complemento.trim()) meta.destino_complemento = dados.destino_complemento.trim()

      const camposEscolta = {
        cliente_id:          dados.cliente_id,
        data_hora_prevista:  new Date(dtStr).toISOString(),
        origem_endereco:     enderecoComComplemento(dados.origem_endereco, dados.origem_complemento),
        origem_lat:          dados.origem_lat,
        origem_lng:          dados.origem_lng,
        destino_endereco:    enderecoComComplemento(dados.destino_endereco, dados.destino_complemento),
        destino_lat:         dados.destino_lat,
        destino_lng:         dados.destino_lng,
        metadados:           Object.keys(meta).length ? meta : null,
        periodicidade_checkin_min: periodicidadeCheckin ? Number(periodicidadeCheckin) : null,
        valor_cobrado:       verFinanceiro && valorCobrado ? parseFloat(valorCobrado) : null,
        outros_custos:       verFinanceiro && outrosCustos ? parseFloat(outrosCustos) : 0,
        observacao_financeira: verFinanceiro && obsFinanceiro.trim() ? obsFinanceiro.trim() : null,
      }

      let escoltaId: string

      if (editandoId) {
        // A precondicao de status vive junto do update: se a escolta tiver comecado
        // enquanto o formulario estava aberto, nenhuma linha casa e o salvamento para,
        // em vez de sobrescrever dados de uma operacao em andamento.
        const { data: atualizadas, error: eU } = await sb
          .from('escoltas')
          .update(camposEscolta)
          .eq('id', editandoId)
          .in('status', ['rascunho', 'agendada'])
          .select('id')
        if (eU) throw new Error(eU.message)
        if (!atualizadas || atualizadas.length === 0) {
          throw new Error('A escolta já começou enquanto você editava. Recarregue a página: as alterações não foram salvas.')
        }
        escoltaId = editandoId

        // Viaturas e efetivo sao substituidos por inteiro. Trocar linha a linha exigiria
        // casar o que ficou, o que saiu e o que entrou, e o ganho nao paga o risco de
        // deixar vinculo orfao. Como a escolta ainda nao comecou, nao ha ponto de
        // controle nem foto apontando para essas linhas.
        await sb.from('escolta_efetivo').delete().eq('escolta_id', editandoId)
        const { error: eDel } = await sb.from('escolta_veiculos').delete().eq('escolta_id', editandoId)
        if (eDel) throw new Error('Não foi possível atualizar as viaturas: ' + eDel.message)
      } else {
        const { data: nova, error: e1 } = await sb
          .from('escoltas')
          .insert({
            ...camposEscolta,
            data_solicitacao: new Date().toISOString(),
            status: 'agendada',
            checklist_pendente_no_inicio: true,
            criada_por: user?.id,
          })
          .select('id').single()

        if (e1 || !nova) throw new Error('Erro ao criar a escolta.')
        escoltaId = nova.id
      }

      for (const v of viaturas) {
        const { data: ev, error: e2 } = await sb
          .from('escolta_veiculos')
          .insert({
            escolta_id: escoltaId,
            veiculo_id: v.veiculo_id,
          })
          .select('id').single()

        if (e2 || !ev) throw new Error('Erro ao vincular viatura.')

        for (const m of v.membros) {
          const { error: e3 } = await sb.from('escolta_efetivo').insert({
            escolta_id:         escoltaId,
            escolta_veiculo_id: ev.id,
            vigilante_id:       m.vigilante_id,
            papel_na_escolta:   m.papel_na_escolta,
            confirmado:         false,
            valor_pago_vigilante: verFinanceiro && m.valor_pago ? parseFloat(m.valor_pago) : null,
          })
          // Antes o erro era engolido: a escolta nascia com viatura e sem equipe, e
          // ninguem ficava sabendo ate a hora de sair da base.
          if (e3) throw new Error('Erro ao escalar vigilante: ' + e3.message)
        }
      }

      router.push(`/dashboard/escoltas/${escoltaId}`)
    } catch (err) {
      setErros([err instanceof Error ? err.message : 'Erro inesperado.'])
      setSalvando(false)
    }
  }

  // ── Helpers de viatura ────────────────────────────────────────────────────
  const updV = (id: string, p: Partial<ViaturaForm>) =>
    setViaturas(vs => vs.map(v => v.uid === id ? { ...v, ...p } : v))
  const addM  = (vid: string) =>
    setViaturas(vs => vs.map(v => v.uid === vid ? { ...v, membros: [...v.membros, novoMembro()] } : v))
  const updM  = (vid: string, mid: string, p: Partial<MembroForm>) =>
    setViaturas(vs => vs.map(v =>
      v.uid === vid ? { ...v, membros: v.membros.map(m => m.uid === mid ? { ...m, ...p } : m) } : v
    ))
  const rmM   = (vid: string, mid: string) =>
    setViaturas(vs => vs.map(v =>
      v.uid === vid ? { ...v, membros: v.membros.filter(m => m.uid !== mid) } : v
    ))

  const cliente = clientes.find(c => c.id === dados.cliente_id)
  const dtLabel = dados.data_prevista
    ? new Date(`${dados.data_prevista}T${dados.hora_prevista_h}:${dados.hora_prevista_m}`).toLocaleString('pt-BR')
    : '—'

  // ── Render ────────────────────────────────────────────────────────────────

  // Editando: nao renderiza o formulario antes de os dados chegarem, senao o usuario ve
  // campos vazios por um instante e pode comecar a digitar por cima do que esta vindo.
  if (carregandoEdicao) {
    return (
      <div className="max-w-3xl mx-auto py-16 text-center">
        <p className="text-sm" style={{ color: P.sub }}>Carregando escolta para edição…</p>
      </div>
    )
  }

  if (bloqueioEdicao) {
    return (
      <div className="max-w-3xl mx-auto py-12 px-3">
        <div className="p-5 text-center" style={{ border: `1px solid ${P.border}`, backgroundColor: P.surface }}>
          <AlertTriangle size={26} className="mx-auto mb-3" style={{ color: '#C8813A' }} />
          <p className="text-sm font-semibold mb-1" style={{ color: P.text }}>Não é possível editar</p>
          <p className="text-xs leading-relaxed mb-5" style={{ color: P.sub }}>{bloqueioEdicao}</p>
          <button onClick={() => router.back()} className="btn-outline">
            <ArrowLeft size={14} /> Voltar
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="max-w-3xl mx-auto space-y-5 pb-10 px-3 md:px-0">

      {/* Header */}
      <div className="flex items-center gap-3">
        <button
          onClick={() => router.back()}
          className="w-9 h-9 flex items-center justify-center border transition-colors shrink-0"
          style={{ borderColor: P.border, borderRadius: '2px', backgroundColor: P.surface, color: P.sub }}
          onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = P.navy; (e.currentTarget as HTMLElement).style.color = '#fff'; (e.currentTarget as HTMLElement).style.borderColor = P.navy }}
          onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = P.surface; (e.currentTarget as HTMLElement).style.color = P.sub; (e.currentTarget as HTMLElement).style.borderColor = P.border }}
        >
          <ArrowLeft size={15} />
        </button>
        <div>
          <h2 className="text-lg font-black uppercase tracking-widest" style={{ color: P.text }}>
            {editandoId ? 'Editar Escolta' : 'Nova Escolta'}
          </h2>
          <p className="text-[11px] uppercase tracking-widest" style={{ color: P.sub }}>{STEPS[step-1]}</p>
        </div>
      </div>

      {/* Editando: a escolta ja existe, entao vale avisar o que sera substituido. */}
      {editandoId && !bloqueioEdicao && (
        <div className="p-3" style={{ border: `1px solid ${P.border}`, backgroundColor: '#FFF7E6' }}>
          <p className="text-[11px] leading-relaxed" style={{ color: '#8A6100' }}>
            Você está alterando uma escolta que já existe. As viaturas e a equipe são
            substituídas pelo que estiver aqui ao salvar. A edição só é possível enquanto
            a escolta não começar.
          </p>
        </div>
      )}

      {/* Stepper */}
      <div className="grid grid-cols-3 gap-2">
        {([1,2,3] as const).map(s => {
          const active    = s === step
          const completed = s < step
          return (
            <div
              key={s}
              style={{
                borderRadius: '2px',
                border: `1.5px solid ${active ? P.steel : completed ? P.success : P.border}`,
                backgroundColor: active ? '#EBF0F8' : completed ? '#E6F4ED' : P.surface,
                padding: '10px 12px',
                position: 'relative',
                overflow: 'hidden',
              }}
            >
              <div style={{
                position: 'absolute', top: 0, left: 0, right: 0, height: '3px',
                backgroundColor: active ? P.steel : completed ? P.success : 'transparent',
              }} />
              <div className="flex items-center justify-between">
                <span className="text-[9px] md:text-[10px] font-black uppercase tracking-widest" style={{ color: P.sub }}>
                  FASE 0{s}
                </span>
                {completed && <CheckCircle size={12} style={{ color: P.success }} />}
              </div>
              <p className="text-[10px] md:text-xs font-black uppercase tracking-wide mt-1 leading-tight"
                style={{ color: active ? P.navy : completed ? P.success : P.sub }}>
                {STEPS[s-1]}
              </p>
            </div>
          )
        })}
      </div>

      {/* Erros */}
      {erros.length > 0 && (
        <div style={{ backgroundColor: '#FAEAE9', border: `1.5px solid #EAB5B0`, borderRadius: '2px', padding: '12px 16px' }}>
          <div className="flex items-center gap-2 mb-1.5">
            <AlertTriangle size={13} style={{ color: P.error }} />
            <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.error }}>
              Atenção — Corrija os erros abaixo:
            </span>
          </div>
          {erros.map((e, i) => <p key={i} className="text-xs pl-5" style={{ color: P.error }}>{e}</p>)}
        </div>
      )}

      {/* ══════════ STEP 1 ══════════ */}
      {step === 1 && (
        <div
          className="animate-in fade-in zoom-in-95 p-4 md:p-6"
          style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', animationDuration: '400ms', animationFillMode: 'both' }}
        >

          {/* Divider label */}
          <div className="flex items-center gap-3 mb-5">
            <div style={{ width: '3px', height: '18px', backgroundColor: P.navy, borderRadius: '2px' }} />
            <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.navy }}>Identificação da Missão</span>
          </div>

          <div className="space-y-4">
            {/* Cliente */}
            <div>
              <FieldLabel required>Cliente Contratante</FieldLabel>
              <FieldWrap icon={<Briefcase size={15} />}>
                <select
                  value={dados.cliente_id}
                  onChange={e => {
                    const cid = e.target.value
                    setDados(d => ({ ...d, cliente_id: cid }))
                    if (verFinanceiro) {
                      const cli = clientes.find(c => c.id === cid)
                      if (cli?.valor_padrao_escolta != null) setValorCobrado(cli.valor_padrao_escolta.toString())
                    }
                  }}
                  className={inputCls} style={{ ...inputStyle, cursor: 'pointer' }}
                >
                  <option value="">Selecione o cliente...</option>
                  {clientes.map(c => <option key={c.id} value={c.id}>{c.nome_cliente}</option>)}
                </select>
              </FieldWrap>
            </div>

            {/* Data + Hora */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <FieldLabel required>Data de Partida</FieldLabel>
                <input
                  type="date"
                  value={dados.data_prevista}
                  onChange={e => setDados(d => ({ ...d, data_prevista: e.target.value }))}
                  className="w-full text-sm font-medium px-3 h-12 md:h-11 transition-all outline-none"
                  style={{
                    backgroundColor: P.surface, border: `1.5px solid ${P.border}`,
                    borderRadius: '2px', color: P.text,
                  }}
                  onFocus={e => (e.currentTarget.style.borderColor = P.steel)}
                  onBlur={e  => (e.currentTarget.style.borderColor = P.border)}
                />
              </div>

              <div>
                <FieldLabel required>Hora de Partida</FieldLabel>
                <div
                  className="flex items-center gap-2 px-3 h-12 md:h-11"
                  style={{ backgroundColor: P.surface, border: `1.5px solid ${P.border}`, borderRadius: '2px' }}
                >
                  <select
                    value={dados.hora_prevista_h}
                    onChange={e => setDados(d => ({ ...d, hora_prevista_h: e.target.value }))}
                    className="bg-transparent border-0 outline-none text-sm font-black text-center"
                    style={{ color: P.text, width: '52px' }}
                  >
                    {HORAS.map(h => <option key={h} value={h}>{h}</option>)}
                  </select>
                  <span className="font-black text-lg" style={{ color: P.steel }}>:</span>
                  <select
                    value={dados.hora_prevista_m}
                    onChange={e => setDados(d => ({ ...d, hora_prevista_m: e.target.value }))}
                    className="bg-transparent border-0 outline-none text-sm font-black text-center"
                    style={{ color: P.text, width: '52px' }}
                  >
                    {MINS.map(m => <option key={m} value={m}>{m}</option>)}
                  </select>
                  <span className="text-[10px] ml-1" style={{ color: P.sub }}>HRS</span>
                </div>
              </div>
            </div>

            {/* Origem */}
            <div>
              <FieldLabel required>Endereço de Origem</FieldLabel>
              <AddressAutocomplete
                value={dados.origem_endereco}
                onChange={(addr, lat, lon) => setDados(d => ({
                  ...d,
                  origem_endereco: addr,
                  // Digitar depois de escolher invalida a coordenada: sem isto a escolta
                  // nasceria com o endereço de um lugar e a coordenada de outro.
                  origem_lat: lat ?? 0,
                  origem_lng: lon ?? 0,
                }))}
                placeholder="Rua, número, bairro, cidade..."
                icon={<MapPin size={15} />}
              />
            </div>

            {/* Complemento da origem: campo separado de propósito, para que digitar aqui
                nunca invalide a coordenada já fixada pela lista de sugestões. */}
            <div>
              <FieldLabel>Complemento da Origem (opcional)</FieldLabel>
              <FieldWrap icon={<Building2 size={15} />}>
                <input
                  type="text"
                  maxLength={80}
                  value={dados.origem_complemento}
                  onChange={e => setDados(d => ({ ...d, origem_complemento: e.target.value }))}
                  placeholder="Apto, bloco, portão, doca, galpão..."
                  className={inputCls}
                  style={inputStyle}
                />
              </FieldWrap>
              <p style={{ fontSize: '10px', color: P.sub, marginTop: '4px' }}>
                Entra junto do endereço no cadastro. Não altera a coordenada escolhida na lista.
              </p>
            </div>

            {/* Destino */}
            <div>
              <FieldLabel required>Endereço de Destino</FieldLabel>
              <AddressAutocomplete
                value={dados.destino_endereco}
                onChange={(addr, lat, lon) => setDados(d => ({
                  ...d,
                  destino_endereco: addr,
                  // Mesma regra da origem: texto editado à mão perde a coordenada antiga.
                  destino_lat: lat ?? 0,
                  destino_lng: lon ?? 0,
                }))}
                placeholder="Rua, número, bairro, cidade..."
                icon={<Flag size={15} />}
              />
            </div>

            {/* Complemento do destino: mesma regra da origem. */}
            <div>
              <FieldLabel>Complemento do Destino (opcional)</FieldLabel>
              <FieldWrap icon={<Building2 size={15} />}>
                <input
                  type="text"
                  maxLength={80}
                  value={dados.destino_complemento}
                  onChange={e => setDados(d => ({ ...d, destino_complemento: e.target.value }))}
                  placeholder="Apto, bloco, portão, doca, galpão..."
                  className={inputCls}
                  style={inputStyle}
                />
              </FieldWrap>
              <p style={{ fontSize: '10px', color: P.sub, marginTop: '4px' }}>
                Entra junto do endereço no cadastro. Não altera a coordenada escolhida na lista.
              </p>
            </div>

            {/* Observações */}
            <div>
              <FieldLabel>Observações Operacionais</FieldLabel>
              <div
                className="flex gap-2.5 px-3 py-2.5 transition-all"
                style={{ backgroundColor: P.surface, border: `1.5px solid ${P.border}`, borderRadius: '2px' }}
                onFocusCapture={e => (e.currentTarget.style.borderColor = P.steel)}
                onBlurCapture={e  => (e.currentTarget.style.borderColor = P.border)}
              >
                <FileText size={15} style={{ color: P.light, flexShrink: 0, marginTop: '2px' }} />
                <textarea
                  rows={3}
                  value={dados.observacoes}
                  onChange={e => setDados(d => ({ ...d, observacoes: e.target.value }))}
                  placeholder="Instruções especiais, contatos, restrições de rota..."
                  className="bg-transparent border-0 outline-none w-full text-sm font-medium resize-none min-h-[100px]"
                  style={{ color: P.text }}
                />
              </div>
            </div>

            {/* Periodicidade de check-in */}
            <div>
              <FieldLabel>Periodicidade de Check-in em Rota</FieldLabel>
              <FieldWrap icon={<Radio size={13} />}>
                <select
                  value={periodicidadeCheckin}
                  onChange={e => setPeriodicidadeCheckin(e.target.value)}
                  className={inputCls} style={inputStyle}
                >
                  <option value="">Sem check-in obrigatório</option>
                  {[10,15,20,30,45,60,90,120].map(m => (
                    <option key={m} value={String(m)}>A cada {m} minutos</option>
                  ))}
                </select>
              </FieldWrap>
              <p style={{ fontSize: '10px', color: P.sub, marginTop: '4px' }}>
                Define com que frequência o operador deve confirmar a posição da escolta. Gera alerta no painel e no Telegram quando o prazo vence.
              </p>
            </div>

            {/* Seção Financeira — supervisor+ */}
            {verFinanceiro && (
              <div style={{ borderTop: `1.5px solid ${P.border}`, paddingTop: '16px', marginTop: '4px' }}>
                <div className="flex items-center gap-2 mb-4">
                  <DollarSign size={13} style={{ color: P.success }} />
                  <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.success }}>Dados Financeiros</span>
                  <span style={{ fontSize: '9px', backgroundColor: '#E6F4ED', color: P.success, padding: '2px 8px', borderRadius: '2px', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.1em' }}>
                    Visível apenas supervisores+
                  </span>
                </div>
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <div>
                    <FieldLabel>Valor Cobrado do Cliente (R$)</FieldLabel>
                    <FieldWrap icon={<DollarSign size={13} />}>
                      <input
                        type="number" min="0" step="0.01"
                        value={valorCobrado}
                        onChange={e => setValorCobrado(e.target.value)}
                        placeholder="0,00"
                        className={inputCls} style={inputStyle}
                      />
                    </FieldWrap>
                  </div>
                  <div>
                    <FieldLabel>Outros Custos (R$)</FieldLabel>
                    <FieldWrap icon={<DollarSign size={13} />}>
                      <input
                        type="number" min="0" step="0.01"
                        value={outrosCustos}
                        onChange={e => setOutrosCustos(e.target.value)}
                        placeholder="0,00"
                        className={inputCls} style={inputStyle}
                      />
                    </FieldWrap>
                  </div>
                </div>
                <div style={{ marginTop: '12px' }}>
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '6px' }}>
                    <span style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.14em', color: P.sub }}>Observação Financeira</span>
                    <div style={{ display: 'flex', gap: '4px' }}>
                      <AiTextButton value={obsFinanceiro} onChange={setObsFinanceiro} contexto="Observação financeira de contrato de escolta armada" />
                    </div>
                  </div>
                  <FieldWrap>
                    <input
                      type="text"
                      value={obsFinanceiro}
                      onChange={e => setObsFinanceiro(e.target.value)}
                      placeholder="Condições de pagamento, parcelas, etc."
                      className={inputCls} style={inputStyle}
                    />
                  </FieldWrap>
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      {/* ══════════ STEP 2 ══════════ */}
      {step === 2 && (
        <div className="space-y-3 animate-in fade-in slide-in-from-right-4" style={{ animationDuration: '400ms', animationFillMode: 'both' }}>
          {viaturas.map((viatura, vi) => (
            <div
              key={viatura.uid}
              className="p-4 md:p-5"
              style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px' }}
            >
              {/* Viatura header */}
              <div className="flex items-center justify-between mb-4">
                <div className="flex items-center gap-2">
                  <div style={{ width: '3px', height: '18px', backgroundColor: P.khaki, borderRadius: '2px' }} />
                  <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.navy }}>
                    Viatura 0{vi + 1}
                  </span>
                </div>
                {viaturas.length > 1 && (
                  <button
                    onClick={() => setViaturas(vs => vs.filter(v => v.uid !== viatura.uid))}
                    className="flex items-center gap-1 text-[11px] px-3 font-bold transition-all"
                    style={{ color: P.error, border: `1px solid #EAB5B0`, borderRadius: '2px', backgroundColor: '#FAEAE9', minHeight: '44px' }}
                  >
                    <Trash2 size={11} /> Remover
                  </button>
                )}
              </div>

              <div className="space-y-4">
                <div>
                  <FieldLabel required>Veículo Operacional</FieldLabel>
                  <FieldWrap icon={<Car size={15} />}>
                    <select
                      value={viatura.veiculo_id}
                      onChange={e => updV(viatura.uid, { veiculo_id: e.target.value })}
                      className={inputCls} style={{ ...inputStyle, cursor: 'pointer' }}
                    >
                      <option value="">Selecione o veículo...</option>
                      {veiculos.map(v => (
                        <option key={v.id} value={v.id}>
                          {v.placa}{v.modelo ? ` — ${v.modelo}` : ''} {v.tipo?.nome ? `(${v.tipo.nome})` : ''}
                        </option>
                      ))}
                    </select>
                  </FieldWrap>
                </div>

                {/* Efetivo */}
                <div>
                  <div className="flex items-center justify-between mb-2">
                    <FieldLabel required>Efetivo da Viatura</FieldLabel>
                    <button
                      onClick={() => addM(viatura.uid)}
                      className="flex items-center gap-1 text-[11px] px-3 font-bold transition-all"
                      style={{ color: P.navy, border: `1px solid ${P.border}`, borderRadius: '2px', backgroundColor: P.surface, minHeight: '44px' }}
                      onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = P.navy; (e.currentTarget as HTMLElement).style.color = '#fff'; (e.currentTarget as HTMLElement).style.borderColor = P.navy }}
                      onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = P.surface; (e.currentTarget as HTMLElement).style.color = P.navy; (e.currentTarget as HTMLElement).style.borderColor = P.border }}
                    >
                      <Plus size={11} /> Adicionar Vigilante
                    </button>
                  </div>

                  {viatura.membros.length === 0 ? (
                    <div className="py-5 px-4 text-center" style={{ border: `1.5px dashed #C8813A`, borderRadius: '2px', backgroundColor: '#FFFBEB' }}>
                      <p className="text-xs font-bold mb-1" style={{ color: '#8A5A10' }}>
                        Sem vigilante escalado: vai para o mural
                      </p>
                      <p className="text-[11px] leading-relaxed" style={{ color: P.sub }}>
                        Deixando em branco, esta escolta aparece para os operadores como
                        disponível, e o primeiro que puxar vira o comandante. Se você já
                        sabe quem vai, escale aqui e ela não entra no mural.
                      </p>
                    </div>
                  ) : (
                    <div className="space-y-2">
                      {viatura.membros.map(m => (
                        <div
                          key={m.uid}
                          className="flex flex-col sm:flex-row sm:items-center gap-2"
                          style={{ paddingBottom: '8px', borderBottom: `1px solid ${P.border}` }}
                        >
                          {/* Seleção de vigilante — full-width */}
                          <div className="w-full sm:flex-1 sm:min-w-0">
                            <FieldWrap icon={<Shield size={14} />}>
                              <select
                                value={m.vigilante_id}
                                onChange={e => {
                                  const vid = e.target.value
                                  const vig = vigilantes.find(v => v.id === vid)
                                  updM(viatura.uid, m.uid, {
                                    vigilante_id: vid,
                                    valor_pago: verFinanceiro && vig?.valor_padrao_pago != null ? vig.valor_padrao_pago.toString() : m.valor_pago,
                                  })
                                }}
                                className={inputCls} style={{ ...inputStyle, cursor: 'pointer', height: '44px' }}
                              >
                                <option value="">Selecione o vigilante...</option>
                                {vigilantes.map(v => (
                                  <option key={v.id} value={v.id}>
                                    {v.nome_completo}{v.funcao?.nome ? ` · ${v.funcao.nome}` : ''}
                                  </option>
                                ))}
                              </select>
                            </FieldWrap>
                          </div>

                          {/* Papel + valor + botão remover em linha no mobile */}
                          <div className="flex items-center gap-2">
                            <div className="flex-1 sm:w-[140px] sm:flex-none">
                              <FieldWrap icon={<UserCheck size={14} />}>
                                <select
                                  value={m.papel_na_escolta}
                                  onChange={e => updM(viatura.uid, m.uid, { papel_na_escolta: e.target.value as 'comandante'|'operador' })}
                                  className={inputCls} style={{ ...inputStyle, cursor: 'pointer', height: '44px' }}
                                >
                                  <option value="operador">Operador</option>
                                  <option value="comandante">Comandante</option>
                                </select>
                              </FieldWrap>
                            </div>
                            {verFinanceiro && (
                              <div className="w-[100px] shrink-0">
                                <FieldWrap icon={<DollarSign size={13} />}>
                                  <input
                                    type="number" min="0" step="0.01"
                                    value={m.valor_pago}
                                    onChange={e => updM(viatura.uid, m.uid, { valor_pago: e.target.value })}
                                    placeholder="0,00"
                                    className={inputCls} style={{ ...inputStyle, fontSize: '12px', height: '44px' }}
                                  />
                                </FieldWrap>
                              </div>
                            )}
                            <button
                              onClick={() => rmM(viatura.uid, m.uid)}
                              className="flex items-center justify-center transition-all shrink-0"
                              style={{ color: P.sub, border: `1px solid ${P.border}`, borderRadius: '2px', backgroundColor: P.surface, width: '44px', height: '44px' }}
                              onMouseEnter={e => { (e.currentTarget as HTMLElement).style.color = P.error; (e.currentTarget as HTMLElement).style.borderColor = '#EAB5B0'; (e.currentTarget as HTMLElement).style.backgroundColor = '#FAEAE9' }}
                              onMouseLeave={e => { (e.currentTarget as HTMLElement).style.color = P.sub; (e.currentTarget as HTMLElement).style.borderColor = P.border; (e.currentTarget as HTMLElement).style.backgroundColor = P.surface }}
                            >
                              <Trash2 size={14} />
                            </button>
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            </div>
          ))}

          <button
            onClick={() => setViaturas(vs => [...vs, novaViatura()])}
            className="w-full py-4 text-sm font-bold uppercase tracking-widest transition-all flex items-center justify-center gap-2"
            style={{ color: P.navy, border: `1.5px dashed ${P.border}`, borderRadius: '2px', backgroundColor: P.surface }}
            onMouseEnter={e => { (e.currentTarget as HTMLElement).style.borderColor = P.navy; (e.currentTarget as HTMLElement).style.backgroundColor = '#E6EAF2' }}
            onMouseLeave={e => { (e.currentTarget as HTMLElement).style.borderColor = P.border; (e.currentTarget as HTMLElement).style.backgroundColor = P.surface }}
          >
            <Plus size={15} /> Adicionar Viatura
          </button>
        </div>
      )}

      {/* ══════════ STEP 3 ══════════ */}
      {step === 3 && (
        <div className="space-y-4 animate-in fade-in zoom-in-95" style={{ animationDuration: '400ms', animationFillMode: 'both' }}>
          {/* Cabeçalho navy */}
          <div style={{ backgroundColor: P.navy, borderRadius: '2px', padding: '16px 20px' }}>
            <p className="text-[9px] font-black uppercase tracking-[0.2em] mb-1" style={{ color: 'rgba(255,255,255,0.4)' }}>
              REVISÃO FINAL
            </p>
            <p className="text-sm font-black text-white uppercase tracking-wide">Confirme todos os dados antes de criar a operação</p>
          </div>

          {/* Sem equipe em nenhuma viatura: a escolta nasce no mural. Avisar aqui, e nao
              so na tela anterior, porque e a ultima chance antes de gravar. */}
          {iraParaOMural && (
            <div className="p-4" style={{ border: '1.5px solid #C8813A', backgroundColor: '#FFFBEB', borderRadius: '2px' }}>
              <p className="text-xs font-black uppercase tracking-wide mb-1" style={{ color: '#8A5A10' }}>
                Esta escolta vai para o mural
              </p>
              <p className="text-[11px] leading-relaxed" style={{ color: P.sub }}>
                Nenhum vigilante foi escalado. Ela aparecerá como disponível para os
                operadores, e o primeiro que puxar assume como comandante e escolhe o
                companheiro de viatura. Para designar a equipe você mesmo, volte ao passo
                anterior.
              </p>
            </div>
          )}

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4 items-start">
            {/* Dados da missão */}
            <div style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px' }}>
              <div className="flex items-center gap-2 px-4 py-3" style={{ borderBottom: `1px solid ${P.border}`, backgroundColor: '#F5F7FA' }}>
                <Briefcase size={13} style={{ color: P.navy }} />
                <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.navy }}>Dados da Missão</span>
              </div>
              <div className="p-4 space-y-0">
                {cliente && (
                  <div className="flex items-center gap-2 py-3" style={{ borderBottom: `1px solid ${P.border}` }}>
                    <div style={{ width: '10px', height: '10px', backgroundColor: cliente.cor_destaque, borderRadius: '2px', flexShrink: 0 }} />
                    <span className="text-sm font-black" style={{ color: P.navy }}>{cliente.nome_cliente}</span>
                  </div>
                )}
                {[
                  { label: 'Partida Prevista', value: dtLabel },
                  // Mostra o texto exatamente como será gravado, com o complemento já junto.
                  { label: 'Origem', value: enderecoComComplemento(dados.origem_endereco, dados.origem_complemento) },
                  { label: 'Destino', value: enderecoComComplemento(dados.destino_endereco, dados.destino_complemento) },
                ].map(r => (
                  <div key={r.label} className="py-2.5" style={{ borderBottom: `1px solid ${P.border}` }}>
                    <p className="text-[9px] font-black uppercase tracking-widest mb-0.5" style={{ color: P.sub }}>{r.label}</p>
                    <p className="text-xs font-semibold" style={{ color: P.text }}>{r.value}</p>
                  </div>
                ))}
                {dados.observacoes && (
                  <div className="py-2.5">
                    <p className="text-[9px] font-black uppercase tracking-widest mb-1" style={{ color: P.sub }}>Observações</p>
                    <p className="text-xs leading-relaxed" style={{ color: P.text }}>{dados.observacoes}</p>
                  </div>
                )}
              </div>
            </div>

            {/* Viaturas */}
            <div className="space-y-3">
              {viaturas.map((v, i) => {
                const veic = veiculos.find(vv => vv.id === v.veiculo_id)
                return (
                  <div key={v.uid} style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px' }}>
                    <div className="flex items-center justify-between px-4 py-3" style={{ borderBottom: `1px solid ${P.border}`, backgroundColor: '#F5F7FA' }}>
                      <div className="flex items-center gap-2">
                        <Car size={13} style={{ color: P.steel }} />
                        <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.navy }}>Viatura 0{i+1}</span>
                      </div>
                      <span className="font-mono text-xs font-black" style={{ color: P.steel }}>{veic?.placa ?? '—'}</span>
                    </div>
                    <div className="p-4 space-y-2">
                      <div className="flex items-center justify-between text-xs" style={{ borderBottom: `1px solid ${P.border}`, paddingBottom: '8px' }}>
                        <span style={{ color: P.sub }}>Veículo</span>
                        <span className="font-semibold text-right" style={{ color: P.text }}>{veic?.modelo ?? '—'} {veic?.tipo?.nome ? `(${veic.tipo.nome})` : ''}</span>
                      </div>
                      <div className="flex items-center justify-between text-xs" style={{ borderBottom: `1px solid ${P.border}`, paddingBottom: '8px' }}>
                        <span style={{ color: P.sub }}>Efetivo</span>
                        {v.membros.length === 0 ? (
                          <span className="font-black text-right" style={{ color: '#8A5A10' }}>
                            a definir · vai para o mural
                          </span>
                        ) : (
                          <span className="font-black" style={{ color: P.text }}>{v.membros.length} vigilante{v.membros.length !== 1 ? 's' : ''}</span>
                        )}
                      </div>
                      <div className="space-y-1.5 pt-1">
                        {v.membros.map(m => {
                          const vig = vigilantes.find(vv => vv.id === m.vigilante_id)
                          return (
                            <div key={m.uid} className="flex items-center justify-between">
                              <span className="text-xs" style={{ color: P.text }}>{vig?.nome_completo ?? '—'}</span>
                              <span
                                className="text-[10px] font-black uppercase tracking-wide px-2 py-0.5"
                                style={{
                                  borderRadius: '2px',
                                  backgroundColor: m.papel_na_escolta === 'comandante' ? '#E6EAF2' : '#F5F7FA',
                                  color: m.papel_na_escolta === 'comandante' ? P.navy : P.sub,
                                  border: `1px solid ${m.papel_na_escolta === 'comandante' ? P.steel : P.border}`,
                                }}
                              >
                                {m.papel_na_escolta}
                              </span>
                            </div>
                          )
                        })}
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        </div>
      )}

      {/* ── Navegação ── */}
      <div className="flex flex-col-reverse sm:flex-row sm:items-center sm:justify-between gap-3 pt-4" style={{ borderTop: `1px solid ${P.border}` }}>
        <button
          onClick={step === 1 ? () => router.back() : voltar}
          className="flex items-center justify-center gap-2 px-4 text-sm font-bold uppercase tracking-wider transition-all h-12 md:h-11 w-full sm:w-auto"
          style={{ color: P.sub, border: `1.5px solid ${P.border}`, borderRadius: '2px', backgroundColor: P.surface }}
          onMouseEnter={e => { (e.currentTarget as HTMLElement).style.borderColor = P.navy; (e.currentTarget as HTMLElement).style.color = P.navy }}
          onMouseLeave={e => { (e.currentTarget as HTMLElement).style.borderColor = P.border; (e.currentTarget as HTMLElement).style.color = P.sub }}
        >
          <ArrowLeft size={14} />
          {step === 1 ? 'Cancelar' : 'Voltar'}
        </button>

        {step < 3 ? (
          <button
            onClick={avancar}
            className="flex items-center justify-center gap-2 px-6 text-sm font-black uppercase tracking-wider text-white transition-all h-12 md:h-11 w-full sm:w-auto"
            style={{ backgroundColor: P.navy, borderRadius: '2px' }}
            onMouseEnter={e => (e.currentTarget as HTMLElement).style.backgroundColor = P.navyMid}
            onMouseLeave={e => (e.currentTarget as HTMLElement).style.backgroundColor = P.navy}
          >
            Próximo <ArrowRight size={14} />
          </button>
        ) : (
          <button
            onClick={salvar}
            disabled={salvando}
            className="flex items-center justify-center gap-2 px-6 text-sm font-black uppercase tracking-wider text-white transition-all disabled:opacity-50 w-full sm:w-auto"
            style={{ backgroundColor: P.success, borderRadius: '2px', minHeight: '56px' }}
          >
            <CheckCircle size={14} />
            {salvando ? 'Criando...' : 'Confirmar e Criar Escolta'}
          </button>
        )}
      </div>
    </div>
  )
}
