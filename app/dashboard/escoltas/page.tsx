'use client'

import { useEffect, useState, useCallback, useRef } from 'react'
import { useRouter } from 'next/navigation'
import { Plus, Eye, Pencil, MapPin, Clock, Truck, CheckCircle2, Shield, FileDown } from 'lucide-react'
import { printEscolta } from '@/utils/print'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { PODE_CRIAR_ESCOLTA, PODE_EDITAR_ESCOLTA, PODE_PODER_TOTAL } from '@/lib/permissions'
import { DialogoAssumirEscolta } from '@/components/escolta/dialogo-assumir-escolta'
import { AcaoMural } from '@/components/escolta/acao-mural'
import { AvisosMural } from '@/components/escolta/avisos-mural'
import { MapaInfoMural, lerInfoMural, confirmarPresencaBase, horaBrasilia } from '@/lib/mural'
import { CartaoEscolta } from '@/components/escolta/cartao-escolta'
import { FiltrosEscoltas } from '@/components/escolta/filtros-escoltas'
import { SELECT_CARTAO, type CartaoEscolta as CartaoDados, temEquipeGestao, completarCoresClientes } from '@/lib/cartao-escolta'
import { STATUS_ATIVOS } from '@/lib/fluxo-escolta'
import { useFiltrosEscoltas, aplicarFiltrosServidor } from '@/hooks/useFiltrosEscoltas'

// Onda K: o cartão padrão (lib/cartao-escolta.ts) traz cliente, UF, etiquetas, criador e
// equipe; status e rótulos vêm de lib/fluxo-escolta.ts (acabou o STATUS_MAP duplicado).
type EscoltaRow = CartaoDados

const GRUPO_NAO_INICIADAS = ['rascunho', 'agendada', 'em_pre_inicio']
const GRUPO_ATIVAS = ['em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando', 'na_base']
const GRUPO_HISTORICO = ['finalizada', 'cancelada', 'com_pendencias']

const PODE_CRIAR = PODE_CRIAR_ESCOLTA

const supabase = createClient()
const sb = supabase as any

export default function EscoltasPage() {
  const [escoltas, setEscoltas] = useState<EscoltaRow[]>([])
  // Onda K: filtros combinados e lembrados por usuário no aparelho.
  const [opcoesClientes, setOpcoesClientes] = useState<{ id: string; nome: string }[]>([])
  const [opcoesCriadores, setOpcoesCriadores] = useState<{ id: string; nome: string }[]>([])
  const [loading, setLoading] = useState(true)
  // Operador: alternador "Minhas / Disponíveis / Todas".
  //
  // "Disponíveis" é o mural, decidido com Pecanha em 2026-08-19: escolta agendada e ainda
  // sem equipe pode ser puxada por qualquer operador, que vira comandante. A visibilidade
  // vem da política `escoltas_select` (migration 191); aqui é só o recorte da tela.
  const [modoLista, setModoLista] = useState<'minhas' | 'disponiveis' | 'todas'>('minhas')
  const [minhasEscoltaIds, setMinhasEscoltaIds] = useState<string[]>([])
  const [semEquipeIds, setSemEquipeIds] = useState<string[]>([])
  const [souComandanteIds, setSouComandanteIds] = useState<string[]>([])
  const [puxando, setPuxando] = useState<string | null>(null)
  const [avisoMural, setAvisoMural] = useState<{ tipo: 'ok' | 'erro'; texto: string } | null>(null)
  // Escolta que o operador esta assumindo agora, e o vigilante vinculado a ele.
  const [assumindo, setAssumindo] = useState<EscoltaRow | null>(null)
  const [meuVigilanteId, setMeuVigilanteId] = useState<string | null>(null)
  // Lote 2026-10 (M5): estado das travas, lido do servidor (mural_info).
  const [infoMural, setInfoMural] = useState<MapaInfoMural>({})
  const [travasAtivas, setTravasAtivas] = useState(false)
  const { user, loading: carregandoAuth } = useAuth()
  const router = useRouter()
  const perfil = (user?.perfil?.codigo ?? '') as any
  const { filtros, definir: definirFiltros, limpar: limparFiltros, pronto: filtrosProntos } = useFiltrosEscoltas(user?.id ?? null)
  const filtroStatus = filtros.status
  const seqCarga = useRef(0)
  // Onda G: sem perfil a lista não carrega (sairia como não operador). Se o perfil não
  // chegar (conta sem perfil, leitura falhou, sessão perdida), a tela não fica presa em
  // "Carregando": mostra a mensagem depois do login terminar, ou de 15 s no máximo.
  const [semPerfil, setSemPerfil] = useState(false)
  useEffect(() => {
    if (perfil) { setSemPerfil(false); return }
    if (!carregandoAuth) { setSemPerfil(true); setLoading(false); return }
    const t = setTimeout(() => { setSemPerfil(true); setLoading(false) }, 15_000)
    return () => clearTimeout(t)
  }, [perfil, carregandoAuth])

  // Onda G: decide a aba inicial do operador só uma vez, depois da primeira carga feita
  // já como operador (ver o fim de carregar()).
  const jaEscolheuModo = useRef(false)

  const carregar = useCallback(async () => {
    // Onda G: enquanto o login não termina, o perfil é vazio e a carga sairia como se
    // fosse de não operador, sem as escoltas dele. Espera o usuário e o perfil chegarem.
    if (!user || !perfil || !filtrosProntos) return
    const seq = ++seqCarga.current
    setLoading(true)
    // Onda I: "Concluída com pendências" é filtrada no banco (embed !inner com a conclusão
    // válida), não no navegador: o limite de linhas do PostgREST não esconde as antigas.
    const soComPendencias = filtroStatus === 'com_pendencias'
    let q = sb
      .from('escoltas')
      .select(soComPendencias
        ? SELECT_CARTAO.replace('conclusao:escolta_conclusoes_antecipadas(', 'conclusao:escolta_conclusoes_antecipadas!inner(')
        : SELECT_CARTAO)
      // Onda I: arquivada fora (o administrador as vê em Arquivadas).
      .is('arquivada_em', null)
      .order('data_hora_prevista', { ascending: false })

    if (soComPendencias) {
      q = q.eq('status', 'finalizada').is('conclusao.anulado_em', null)
    }
    // Onda K: status, cliente, período, quem criou e interestadual no servidor.
    q = aplicarFiltrosServidor(q, filtros)

    const { data } = await q
    if (seq !== seqCarga.current) return
    let rows = (data ?? []) as EscoltaRow[]

    let escoltaIdsOperador: string[] = []
    // Filtragem de Visibilidade (Operador vê apenas escoltas ativas)
    if (perfil === 'operador') {
      rows = rows.filter((e) =>
        ['rascunho', 'agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando', 'na_base'].includes(e.status)
      )

      // Resolve as escoltas em que este operador está escalado (via vigilante)
      const { data: vig } = await sb.from('vigilantes').select('id').eq('usuario_id', user?.id).maybeSingle()
      setMeuVigilanteId(vig?.id ?? null)
      let escoltaIds: string[] = []
      let comandoIds: string[] = []
      if (vig) {
        const { data: efet } = await sb
          .from('escolta_efetivo')
          .select('escolta_id, papel_na_escolta')
          .eq('vigilante_id', vig.id)
        escoltaIds = Array.from(new Set((efet ?? []).map((e: any) => e.escolta_id).filter(Boolean)))
        comandoIds = Array.from(new Set((efet ?? [])
          .filter((e: any) => e.papel_na_escolta === 'comandante')
          .map((e: any) => e.escolta_id).filter(Boolean)))
      }
      escoltaIdsOperador = escoltaIds
      setMinhasEscoltaIds(escoltaIds)
      setSouComandanteIds(comandoIds)
    }

    // Mural: agendadas que ainda não têm ninguém escalado. Onda G: "sem equipe" vem só do
    // servidor (mural_info). O efetivo lido pelo próprio operador não serve, porque a RLS
    // esconde o efetivo dos colegas e toda escolta de outra dupla pareceria livre. Sem
    // mural_info (minutos entre o deploy e o bloco 2), toda escolta conta como com equipe.
    const agendadas = rows.filter(e => e.status === 'agendada').map(e => e.id)
    // Falha passageira (rede, tempo esgotado), já com uma nova tentativa: mantém o último
    // estado lido e não escolhe a aba com base nela.
    const lido = await lerInfoMural(sb, agendadas)
    const livres = lido.ativo ? agendadas.filter(id => lido.info[id] && !lido.info[id].tem_equipe) : []
    if (lido.falhou) {
      setSemEquipeIds(ant => ant.filter(id => agendadas.includes(id)))
    } else {
      setTravasAtivas(lido.ativo)
      setInfoMural(lido.info)
      setSemEquipeIds(livres)
    }

    // Operador sem escolta nenhuma cai numa lista vazia e não descobre sozinho que existe
    // uma aba com escoltas para pegar. Nesse caso a tela já abre no mural. Onda G: a
    // escolha é feita aqui, com as escoltas dele já calculadas, e uma vez só; depois
    // disso a escolha é dele.
    if (perfil === 'operador' && !jaEscolheuModo.current && !lido.falhou) {
      jaEscolheuModo.current = true
      const minhas = rows.filter(e => escoltaIdsOperador.includes(e.id)).length
      const livresVisiveis = livres.filter(id => !escoltaIdsOperador.includes(id) && !lido.info[id]?.escala_fixa)
      if (minhas === 0 && livresVisiveis.length > 0) setModoLista('disponiveis')
    }

    // Onda K: cor do cliente que a RLS esconde do operador (mural de outras equipes).
    rows = await completarCoresClientes(sb, rows)
    if (seq !== seqCarga.current) return
    setEscoltas(rows)
    setLoading(false)
  }, [filtros, filtroStatus, filtrosProntos, perfil, user])

  // Opções dos filtros de cliente e de quem criou. O operador só lê os clientes das escoltas
  // em que está escalado (RLS); os das linhas carregadas entram também.
  useEffect(() => {
    if (!user) return
    ;(async () => {
      const [{ data: cls }, { data: us }] = await Promise.all([
        sb.from('clientes').select('id, nome_cliente').order('nome_cliente'),
        sb.from('usuarios').select('id, nome_completo').eq('status', 'ativo').order('nome_completo'),
      ])
      setOpcoesClientes((cls ?? []).map((c: any) => ({ id: c.id, nome: c.nome_cliente })))
      setOpcoesCriadores((us ?? []).map((u: any) => ({ id: u.id, nome: u.nome_completo })))
    })()
  }, [user])

  useEffect(() => { carregar() }, [carregar])

  // Pedido, presença e janela mudam com o tempo: o estado do mural é relido a cada 30 s.
  useEffect(() => {
    const t = setInterval(async () => {
      const ids = escoltas.filter(e => e.status === 'agendada').map(e => e.id)
      const lido = await lerInfoMural(sb, ids)
      if (lido.falhou) return
      setTravasAtivas(lido.ativo)
      setInfoMural(lido.info)
      setSemEquipeIds(lido.ativo ? ids.filter(id => lido.info[id] && !lido.info[id].tem_equipe) : [])
    }, 30_000)
    return () => clearInterval(t)
  }, [escoltas])

  // Sem as travas no banco (entre o deploy e a migration 204), puxar não passa pelo
  // diálogo de assumir: a assumir_escolta antiga trocaria a equipe na hora. A
  // puxar_escolta recusa escolta com equipe também na versão antiga.
  const puxar = async (e: EscoltaRow) => {
    if (travasAtivas) { abrirAssumir(e); return }
    setPuxando(e.id)
    setAvisoMural(null)
    const { error } = await sb.rpc('puxar_escolta', { p_escolta_id: e.id })
    setAvisoMural(error ? { tipo: 'erro', texto: error.message ?? 'Não foi possível puxar a escolta.' } : { tipo: 'ok', texto: 'Escolta puxada. Você é o comandante.' })
    setPuxando(null)
    await carregar()
  }

  const estouNaBase = async (id: string) => {
    setPuxando(id)
    setAvisoMural(null)
    const erro = await confirmarPresencaBase(sb, id)
    setAvisoMural(erro ? { tipo: 'erro', texto: erro } : { tipo: 'ok', texto: 'Presença na base confirmada. Com a equipe na base, ninguém assume esta escolta.' })
    setPuxando(null)
    await carregar()
  }

  const cancelarPedido = async (pedidoId: string, escoltaId: string) => {
    setPuxando(escoltaId)
    const { error } = await sb.rpc('cancelar_meu_pedido_mural', { p_pedido_id: pedidoId })
    setAvisoMural(error ? { tipo: 'erro', texto: error.message } : { tipo: 'ok', texto: 'Pedido cancelado.' })
    setPuxando(null)
    await carregar()
  }

  const ehOperador = perfil === 'operador'
  const qtdMinhas = escoltas.filter(e => minhasEscoltaIds.includes(e.id)).length
  // Contador da aba Disponíveis: o mesmo recorte da lista (escala fixa some do mural).
  const qtdDisponiveis = semEquipeIds.filter(id => !infoMural[id]?.escala_fixa && !minhasEscoltaIds.includes(id)).length
  const podeEditar = PODE_EDITAR_ESCOLTA.includes(perfil)

  /**
   * Abre o dialogo de assumir. Ele mostra a equipe ja escalada, pede confirmacao e
   * exige motivo quando ha alguem a substituir. Escolta vazia passa direto.
   *
   * Antes daqui saia uma chamada direta que RECUSAVA escolta com equipe. A regra mudou
   * a pedido de Pecanha: a dupla escalada pode faltar, e a escolta nao pode parar por
   * isso quando a gestao nao esta disponivel para reescalar.
   */
  const abrirAssumir = (e: EscoltaRow) => {
    setAvisoMural(null)
    setAssumindo(e)
  }

  /** Devolve ao mural. So enquanto nao comecou, e so o comandante. */
  const devolver = async (id: string) => {
    setPuxando(id)
    setAvisoMural(null)
    const { error } = await sb.rpc('devolver_escolta', { p_escolta_id: id })
    if (error) {
      setAvisoMural({ tipo: 'erro', texto: error.message ?? 'Não foi possível devolver a escolta.' })
    } else {
      setAvisoMural({ tipo: 'ok', texto: 'Escolta devolvida ao mural.' })
    }
    setPuxando(null)
    await carregar()
  }

  const escoltasFiltradas = escoltas.filter((e) => {
    if (ehOperador && modoLista === 'minhas' && !minhasEscoltaIds.includes(e.id)) return false
    // Mural: toda escolta agendada, tenha equipe ou nao.
    //
    // Antes mostrava apenas as sem equipe. A regra mudou a pedido de Pecanha: a dupla
    // escalada pode faltar, e quem esta na base precisa conseguir assumir sem depender
    // da gestao. As que ja tem equipe aparecem marcadas, e assumir uma delas pede
    // confirmacao e motivo, que ficam no historico.
    if (ehOperador && modoLista === 'disponiveis'
        && (e.status !== 'agendada' || minhasEscoltaIds.includes(e.id))) return false
    // T6: escala fixa some do mural para o operador.
    if (ehOperador && modoLista === 'disponiveis' && infoMural[e.id]?.escala_fixa) return false
    // Onda K: equipe e busca no navegador. Equipe da gestão pelo efetivo embutido; do
    // operador, só pela mural_info (agendada sem equipe), nunca pelo efetivo que ele lê.
    if (filtros.equipe !== 'todas') {
      const tem = ehOperador ? !semEquipeIds.includes(e.id) : temEquipeGestao(e)
      if (filtros.equipe === 'com' ? !tem : tem) return false
    }
    const busca = filtros.busca.trim()
    if (!busca) return true
    const termo = busca.toLowerCase()
    return Boolean(
      e.codigo_escolta?.toLowerCase().includes(termo) ||
      (e.origem_endereco ?? '').toLowerCase().includes(termo) ||
      (e.destino_endereco ?? '').toLowerCase().includes(termo) ||
      e.cliente?.nome_cliente?.toLowerCase().includes(termo) ||
      e.criador?.nome_completo?.toLowerCase().includes(termo)
    )
  })

  const opcoesClientesTela = (() => {
    const m = new Map(opcoesClientes.map(c => [c.id, c.nome]))
    escoltas.forEach(e => { if (e.cliente?.id && !m.has(e.cliente.id)) m.set(e.cliente.id, e.cliente.nome_cliente) })
    return Array.from(m, ([id, nome]) => ({ id, nome })).sort((a, b) => a.nome.localeCompare(b.nome))
  })()

  // Cálculos dos Cards
  const countNaoIniciadas = escoltas.filter(e => ['rascunho', 'agendada', 'em_pre_inicio'].includes(e.status)).length
  const countEmAndamento = escoltas.filter(e => e.status === 'em_andamento').length
  const countOrigemDestino = escoltas.filter(e => ['na_origem', 'em_transito_destino', 'no_destino'].includes(e.status)).length
  const countRetornoBase = escoltas.filter(e => ['retornando', 'na_base'].includes(e.status)).length

  // Segmentação por tabelas
  const naoIniciadas = escoltasFiltradas.filter(e => GRUPO_NAO_INICIADAS.includes(e.status))
  const ativas = escoltasFiltradas.filter(e => GRUPO_ATIVAS.includes(e.status))
  const concluidas = escoltasFiltradas.filter(e => ['finalizada', 'cancelada'].includes(e.status))

  const podeEditarLinha = (e: EscoltaRow) => podeEditar && (['rascunho', 'agendada'].includes(e.status) || PODE_PODER_TOTAL.includes(perfil))

  // Selos de cada tela ao lado do código (as etiquetas da onda K vêm do cartão).
  const selos = (e: EscoltaRow) => (
    <>
      {e.checklist_pendente_no_inicio && <span className="badge-warning ml-2 text-[10px]">Checklist</span>}
      {/* Aviso antes do clique: assumir esta pede confirmacao e motivo. */}
      {ehOperador && e.status === 'agendada' && !semEquipeIds.includes(e.id) && (
        <span className="ml-2 text-[9px] font-black uppercase tracking-wider px-1 py-0.5"
          style={{ backgroundColor: '#FFF7E6', color: '#8A5A10' }}>já escalada</span>
      )}
    </>
  )

  // Mural: puxar e devolver, so para operador e so em escolta agendada. Quem valida de
  // verdade sao as RPCs, que travam a linha da escolta antes de escalar.
  const acaoMural = (e: EscoltaRow, compacto: boolean) => ehOperador && e.status === 'agendada' ? (
    <AcaoMural compacto={compacto} semEquipe={semEquipeIds.includes(e.id)} souComandante={souComandanteIds.includes(e.id)}
      info={infoMural[e.id]} travasAtivas={travasAtivas} ocupado={puxando === e.id}
      onPuxar={() => puxar(e)} onPedir={() => abrirAssumir(e)} onDevolver={() => devolver(e.id)}
      onEstouNaBase={() => estouNaBase(e.id)} onCancelarPedido={(pid) => cancelarPedido(pid, e.id)} />
  ) : null

  const renderTabelaEscoltas = (lista: EscoltaRow[], tituloVazio: string) => {
    if (lista.length === 0) {
      return (
        <div className="py-8 text-center bg-white rounded border border-slate-100">
          <p className="text-xs font-semibold text-[#6B7E8A]">{tituloVazio}</p>
        </div>
      )
    }

    const botaoIcone = (titulo: string, rotulo: string, onClick: () => void, icone: React.ReactNode, fundo: string, cor: string) => (
      <button
        onClick={onClick}
        className="flex items-center justify-center transition-all"
        style={{ color: '#6B7E8A', width: '36px', height: '36px', borderRadius: '2px' }}
        onMouseEnter={(ev) => { (ev.currentTarget as HTMLElement).style.backgroundColor = fundo; (ev.currentTarget as HTMLElement).style.color = cor }}
        onMouseLeave={(ev) => { (ev.currentTarget as HTMLElement).style.backgroundColor = ''; (ev.currentTarget as HTMLElement).style.color = '#6B7E8A' }}
        title={titulo}
        aria-label={rotulo}
      >
        {icone}
      </button>
    )

    return (
      <>
        {/* Tabela: visível apenas em desktop (md+) */}
        <div className="hidden md:block card-light overflow-x-auto">
          <table className="table-content">
            <thead>
              <tr>
                <th style={{ width: '6px', padding: 0 }} aria-label="Cor do cliente" />
                <th>Código</th>
                <th>Cliente</th>
                <th className="hidden md:table-cell">Origem → Destino</th>
                <th className="hidden lg:table-cell">Data / Hora (Brasília)</th>
                <th className="hidden lg:table-cell">Equipe</th>
                <th>Status</th>
                <th className="text-right">Ações</th>
              </tr>
            </thead>
            <tbody>
              {lista.map((e) => (
                <CartaoEscolta key={e.id} variante="linha" escolta={e} perfil={perfil}
                  semEquipe={ehOperador && e.status === 'agendada' && travasAtivas ? semEquipeIds.includes(e.id) : null}
                  onAbrir={() => router.push(`/dashboard/escoltas/${e.id}`)}
                  selos={selos(e)}
                  acoes={<>
                    {acaoMural(e, true)}
                    {botaoIcone('Ver detalhes', 'Ver detalhes da escolta', () => router.push(`/dashboard/escoltas/${e.id}`), <Eye size={14} />, '#EBF3FC', '#2166A8')}
                    {/* Onda I: gestor e administrador editam em qualquer status. */}
                    {podeEditarLinha(e) && botaoIcone('Editar', 'Editar escolta', () => router.push(`/dashboard/escoltas/nova?editar=${e.id}`), <Pencil size={13} />, '#EBF7F1', '#1E7C52')}
                    {botaoIcone('Exportar PDF', 'Exportar PDF da escolta', () => printEscolta(e.id), <FileDown size={13} />, '#F0F4FA', '#1A2F4A')}
                  </>} />
              ))}
            </tbody>
          </table>
        </div>

        {/* Cartões no celular */}
        <div className="md:hidden space-y-3">
          {lista.map((e) => (
            <CartaoEscolta key={e.id} variante="cartao" escolta={e} perfil={perfil}
              semEquipe={ehOperador && e.status === 'agendada' && travasAtivas ? semEquipeIds.includes(e.id) : null}
              onAbrir={() => router.push(`/dashboard/escoltas/${e.id}`)}
              selos={selos(e)}
              // Puxar e devolver no celular, que e onde o operador de fato usa: largura inteira,
              // separado dos demais para ninguem puxar escolta por engano ao mirar em Ver.
              rodape={acaoMural(e, false)}
              acoes={<>
                <button
                  onClick={() => router.push(`/dashboard/escoltas/${e.id}`)}
                  className="flex-1 flex items-center justify-center gap-1.5 rounded-lg text-xs font-semibold transition-colors"
                  style={{ minHeight: '44px', backgroundColor: '#EBF3FC', color: '#2166A8' }}
                  aria-label="Ver detalhes da escolta"
                >
                  <Eye size={14} />
                  Ver
                </button>
                {podeEditarLinha(e) && (
                  <button
                    onClick={() => router.push(`/dashboard/escoltas/nova?editar=${e.id}`)}
                    className="flex-1 flex items-center justify-center gap-1.5 rounded-lg text-xs font-semibold transition-colors"
                    style={{ minHeight: '44px', backgroundColor: '#EBF7F1', color: '#1E7C52' }}
                    aria-label="Editar escolta"
                  >
                    <Pencil size={13} />
                    Editar
                  </button>
                )}
                <button
                  onClick={() => printEscolta(e.id)}
                  className="flex items-center justify-center rounded-lg transition-colors"
                  style={{ minHeight: '44px', minWidth: '44px', backgroundColor: '#F0F4FA', color: '#1A2F4A' }}
                  aria-label="Exportar PDF da escolta"
                >
                  <FileDown size={14} />
                </button>
              </>} />
          ))}
        </div>
      </>
    )
  }

  return (
    <div className="space-y-6">

      {/* ── Header ── */}
      <div className="flex items-start justify-between">
        <div>
          <div className="eyebrow-tag mb-2">
            <Shield size={10} />
            Gestão de Operações
          </div>
          <h1 className="page-title">Escoltas</h1>
          <p className="page-subtitle">
            {escoltasFiltradas.length} escolta{escoltasFiltradas.length !== 1 ? 's' : ''} encontrada{escoltasFiltradas.length !== 1 ? 's' : ''}
          </p>
        </div>
        {PODE_CRIAR.includes(perfil) && (
          <button
            onClick={() => router.push('/dashboard/escoltas/nova')}
            className="btn-gradient"
          >
            <Plus size={15} />
            <span className="hidden sm:inline">Nova Escolta</span>
            <span className="sm:hidden">Nova</span>
          </button>
        )}
      </div>

      {/* Avisos do mural (pedidos, decisões e substituições) para a gestão. */}
      {!ehOperador && <AvisosMural />}

      {/* ── Alternador Minhas ⇄ Disponíveis ⇄ Todas (operador) ── */}
      {ehOperador && (
        <div className="space-y-2">
          <div className="inline-flex p-1 rounded-lg" style={{ backgroundColor: '#EEF0F5', border: '1px solid #E2E8EC' }}>
            {([
              { val: 'minhas' as const, label: `Minha${minhasEscoltaIds.length > 1 ? 's' : ''} Escolta${minhasEscoltaIds.length > 1 ? 's' : ''}` },
              { val: 'disponiveis' as const, label: `Disponíveis${qtdDisponiveis ? ` (${qtdDisponiveis})` : ''}` },
              { val: 'todas' as const, label: 'Todas as Ativas' },
            ]).map(opt => (
              <button
                key={opt.val}
                onClick={() => { setModoLista(opt.val); setAvisoMural(null) }}
                className="px-4 py-2 rounded-md text-xs font-bold transition-all"
                style={{
                  backgroundColor: modoLista === opt.val ? '#1A294A' : 'transparent',
                  color: modoLista === opt.val ? '#fff' : '#5A6A80',
                }}
              >
                {opt.label}
              </button>
            ))}
          </div>

          {modoLista === 'disponiveis' && (
            <p className="text-[11px] leading-relaxed" style={{ color: '#6B7E8A' }}>
              Escoltas agendadas. Ao puxar uma escolta livre, você vira o comandante e escolhe
              quem vai junto. As marcadas como <strong>já escalada</strong> têm equipe
              designada: a partir de 60 minutos antes do horário, e se a equipe não tiver
              confirmado presença na base, você pode pedir para assumir, com o motivo. O pedido
              vai para a supervisão; sem resposta em 15 minutos, é liberado sozinho.
              Pode devolver enquanto não começar.
            </p>
          )}

          {/* Onda G: quem tem escolta e está no mural sabe que as dele estão na outra aba. */}
          {modoLista === 'disponiveis' && qtdMinhas > 0 && (
            <button type="button" onClick={() => { setModoLista('minhas'); setAvisoMural(null) }}
              className="block w-full text-left p-2.5 rounded text-[11px] font-bold leading-relaxed"
              style={{ backgroundColor: '#EBF3FC', border: '1px solid #B8D3EE', color: '#2166A8' }}>
              Você tem {qtdMinhas} escolta{qtdMinhas > 1 ? 's' : ''} em Minhas Escoltas. Toque para ver.
            </button>
          )}

          <AvisosMural />

          {avisoMural && (
            <div className="p-2.5 rounded text-[11px] leading-relaxed" style={{
              backgroundColor: avisoMural.tipo === 'ok' ? 'rgba(30,124,82,0.08)' : 'rgba(184,56,50,0.08)',
              border: `1px solid ${avisoMural.tipo === 'ok' ? 'rgba(30,124,82,0.3)' : 'rgba(184,56,50,0.3)'}`,
              color: avisoMural.tipo === 'ok' ? '#1E7C52' : '#B83832',
            }}>
              {avisoMural.texto}
            </div>
          )}
        </div>
      )}

      {/* ── Stat Cards ── */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        {([
          {
            label: 'Não Iniciadas',
            count: countNaoIniciadas,
            sub: 'rascunho · agendada · pré-início',
            icon: Clock,
            dark: false,
            iconBg: '#E6EAF2',
            iconCor: '#1A294A',
          },
          {
            label: 'Em Andamento',
            count: countEmAndamento,
            sub: 'em trânsito agora',
            icon: Truck,
            dark: true,
            iconBg: 'rgba(255,255,255,0.10)',
            iconCor: '#ABB5C9',
          },
          {
            label: 'Na Origem / Destino',
            count: countOrigemDestino,
            sub: 'na origem · no destino',
            icon: MapPin,
            dark: false,
            iconBg: '#EBF0F8',
            iconCor: '#53648A',
          },
          {
            label: 'Retornando / Na Base',
            count: countRetornoBase,
            sub: 'retornando · na base',
            icon: CheckCircle2,
            dark: false,
            iconBg: '#E6EAF2',
            iconCor: '#1A294A',
          },
        ] as const).map((c, i) => {
          const Icon = c.icon
          return (
            <div
              key={i}
              className={c.dark ? 'glow-active' : ''}
              style={{
                borderRadius: '2px',
                padding: '20px',
                minHeight: '148px',
                display: 'flex',
                flexDirection: 'column',
                justifyContent: 'space-between',
                transition: 'transform 400ms cubic-bezier(0.32,0.72,0,1), box-shadow 400ms cubic-bezier(0.32,0.72,0,1)',
                cursor: 'default',
                ...(c.dark
                  ? {
                      backgroundColor: '#1A294A',
                      outline: '1px solid rgba(255,255,255,0.08)',
                      boxShadow: '0 2px 8px rgba(0,0,0,0.15)',
                    }
                  : {
                      backgroundColor: '#fff',
                      border: '1px solid #D6DAE5',
                      boxShadow: '0 1px 3px rgba(0,0,0,0.05)',
                    }),
              }}
              onMouseEnter={e => {
                const el = e.currentTarget as HTMLElement
                el.style.transform = 'translateY(-3px)'
                el.style.boxShadow = c.dark
                  ? '0 12px 32px rgba(0,0,0,0.35)'
                  : '0 12px 32px rgba(26,41,74,0.12)'
              }}
              onMouseLeave={e => {
                const el = e.currentTarget as HTMLElement
                el.style.transform = 'translateY(0)'
                el.style.boxShadow = c.dark
                  ? '0 2px 8px rgba(0,0,0,0.15)'
                  : '0 1px 3px rgba(0,0,0,0.05)'
              }}
            >
              {/* Topo: ícone + badge LIVE */}
              <div className="flex items-start justify-between">
                <div
                  style={{
                    width: '40px', height: '40px',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    backgroundColor: c.iconBg,
                    borderRadius: '2px',
                  }}
                >
                  <Icon size={19} style={{ color: c.iconCor }} />
                </div>
                {c.dark && (
                  <span style={{
                    backgroundColor: 'rgba(255,255,255,0.06)',
                    border: '1px solid rgba(255,255,255,0.12)',
                    borderRadius: '2px',
                    fontSize: '9px', fontWeight: 900,
                    letterSpacing: '0.1em', textTransform: 'uppercase',
                    color: 'rgba(255,255,255,0.45)',
                    padding: '3px 7px',
                  }}>
                    LIVE
                  </span>
                )}
              </div>

              {/* Rodapé: número + label */}
              <div>
                <p
                  className="text-3xl font-black tabular-nums"
                  style={{ color: c.dark ? '#fff' : '#0E1A33', lineHeight: 1 }}
                >
                  {loading ? '—' : c.count}
                </p>
                <p
                  className="text-[11px] font-semibold uppercase tracking-widest mt-1.5"
                  style={{ color: c.dark ? 'rgba(255,255,255,0.45)' : '#53648A' }}
                >
                  {c.label}
                </p>
                <p
                  className="text-[10px] mt-0.5 hidden sm:block"
                  style={{ color: c.dark ? 'rgba(255,255,255,0.25)' : '#ABB5C9' }}
                >
                  {c.sub}
                </p>
              </div>
            </div>
          )
        })}
      </div>

      {/* ── Filtros (onda K): combinados e lembrados por usuário neste aparelho ── */}
      <FiltrosEscoltas filtros={filtros} definir={definirFiltros} limpar={limparFiltros}
        clientes={opcoesClientesTela} criadores={opcoesCriadores}
        statusPermitidos={ehOperador ? ['rascunho', ...STATUS_ATIVOS] : undefined} />

      {/* ── Listagem de Escoltas ── */}
      {semPerfil ? (
        <div className="py-12 px-4 text-center space-y-3" data-aviso="sem-perfil">
          <p className="text-sm font-bold" style={{ color: '#B83832' }}>
            Não foi possível carregar o seu perfil de acesso.
          </p>
          <p className="text-xs" style={{ color: '#6B7E8A' }}>
            Recarregue a página ou entre de novo. Se continuar, fale com o administrador.
          </p>
          <button type="button" onClick={() => window.location.reload()}
            className="px-4 text-xs font-bold" style={{ minHeight: '44px', border: '1px solid #C8D5DC', color: '#5A6A80' }}>
            Recarregar
          </button>
        </div>
      ) : loading ? (
        <div className="py-16 flex items-center justify-center gap-3">
          <div className="w-5 h-5 rounded border-2 border-t-transparent animate-spin"
            style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
          <span className="text-sm" style={{ color: '#6B7E8A' }}>Carregando escoltas...</span>
        </div>
      ) : (
        <div className="space-y-6">
          {/* Seção 1: Não Iniciadas */}
          {filtroStatus === 'todos' || GRUPO_NAO_INICIADAS.includes(filtroStatus) ? (
            <div className="space-y-0">
              <div className="cc-panel-header">
                <div style={{ width: '6px', height: '6px', borderRadius: '1px', backgroundColor: '#D97706', flexShrink: 0 }} />
                Escoltas Não Iniciadas
                <span className="badge-warning ml-auto">{naoIniciadas.length}</span>
              </div>
              {renderTabelaEscoltas(naoIniciadas, 'Nenhuma escolta pendente ou não iniciada no momento.')}
            </div>
          ) : null}

          {/* Seção 2: Ativas */}
          {filtroStatus === 'todos' || GRUPO_ATIVAS.includes(filtroStatus) ? (
            <div className="space-y-0">
              <div className="cc-panel-header">
                <div style={{ width: '6px', height: '6px', borderRadius: '1px', backgroundColor: '#53648A', flexShrink: 0 }} />
                Escoltas Ativas / Em Rota
                <span className="badge-info ml-auto">{ativas.length}</span>
              </div>
              {renderTabelaEscoltas(ativas, 'Nenhuma escolta ativa ou em rota no momento.')}
            </div>
          ) : null}

          {/* Seção 3: Histórico */}
          {filtroStatus === 'todos' || GRUPO_HISTORICO.includes(filtroStatus) ? (
            <div className="space-y-0">
              <div className="cc-panel-header">
                <div style={{ width: '6px', height: '6px', borderRadius: '1px', backgroundColor: '#ABB5C9', flexShrink: 0 }} />
                Histórico de Escoltas
                <span className="badge-neutral ml-auto">{concluidas.length}</span>
              </div>
              {renderTabelaEscoltas(concluidas, 'Nenhuma escolta registrada no histórico.')}
            </div>
          ) : null}
        </div>
      )}

      {/* Assumir escolta do mural. O dialogo decide sozinho se pede confirmacao e
          motivo, conforme haja ou nao equipe escalada. */}
      {assumindo && (
        <DialogoAssumirEscolta
          escoltaId={assumindo.id}
          codigo={assumindo.codigo_escolta}
          meuVigilanteId={meuVigilanteId}
          onFechar={() => setAssumindo(null)}
          onAssumido={async (r) => {
            setAssumindo(null)
            if (!r.pedido) setModoLista('minhas')
            setAvisoMural({
              tipo: 'ok',
              texto: r.pedido
                ? `Pedido enviado à supervisão. Se ninguém responder até ${horaBrasilia(r.pedido.expira_em)}, ele é liberado e você assume.`
                : r.substituiu
                  ? 'Escolta assumida. A equipe anterior foi substituída e o registro ficou no histórico.'
                  : 'Escolta assumida. Você é o comandante e já pode iniciar o pré-início.',
            })
            await carregar()
          }}
        />
      )}
    </div>
  )
}
