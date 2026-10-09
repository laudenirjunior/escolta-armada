'use client'

/**
 * Barra de filtros da lista e do mural (lote 2026-10, onda K). Selects nativos, combinados;
 * o estado e a memória por usuário ficam em hooks/useFiltrosEscoltas.ts.
 */
import { Search, X } from 'lucide-react'
import { LABELS_STATUS, SEQUENCIA_STATUS, STATUS } from '@/lib/fluxo-escolta'
import { type Filtros, type Periodo, filtrosAtivos } from '@/hooks/useFiltrosEscoltas'

interface Opcao { id: string; nome: string }

const ROTULO = 'block text-[10px] font-bold uppercase tracking-wider mb-1'

export function FiltrosEscoltas({
  filtros, definir, limpar, clientes, criadores, statusPermitidos,
}: {
  filtros: Filtros
  definir: (p: Partial<Filtros>) => void
  limpar: () => void
  clientes: Opcao[]
  criadores: Opcao[]
  /** Status oferecidos (o operador só vê os ativos). Padrão: os 12. */
  statusPermitidos?: string[]
}) {
  const todos = [...SEQUENCIA_STATUS, STATUS.CANCELADA]
  const status = statusPermitidos ?? todos
  const n = filtrosAtivos(filtros)
  return (
    <div className="card-light p-4 space-y-3" data-teste="barra-filtros">
      <div className="relative">
        <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2" style={{ color: '#A8B8C2' }} />
        <input type="text" data-teste="filtro-busca" placeholder="Buscar por código, endereço, cliente ou quem criou..."
          value={filtros.busca} onChange={(e) => definir({ busca: e.target.value })} className="input-light pl-9 w-full" />
      </div>
      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-2">
        <label className="min-w-0">
          <span className={ROTULO} style={{ color: '#6B7E8A' }}>Status</span>
          <select data-teste="filtro-status" className="select-light w-full" value={filtros.status}
            onChange={(e) => definir({ status: e.target.value })}>
            <option value="todos">Todos</option>
            {status.map(s => <option key={s} value={s}>{LABELS_STATUS[s] ?? s}</option>)}
            {status.includes(STATUS.FINALIZADA) && <option value="com_pendencias">Concluída com pendências</option>}
          </select>
        </label>
        <label className="min-w-0">
          <span className={ROTULO} style={{ color: '#6B7E8A' }}>Cliente</span>
          <select data-teste="filtro-cliente" className="select-light w-full" value={filtros.cliente}
            onChange={(e) => definir({ cliente: e.target.value })}>
            <option value="todos">Todos</option>
            {clientes.map(c => <option key={c.id} value={c.id}>{c.nome}</option>)}
          </select>
        </label>
        <label className="min-w-0">
          <span className={ROTULO} style={{ color: '#6B7E8A' }}>Período</span>
          <select data-teste="filtro-periodo" className="select-light w-full" value={filtros.periodo}
            onChange={(e) => definir({ periodo: e.target.value as Periodo })}>
            <option value="todos">Todos</option>
            <option value="hoje">Hoje</option>
            <option value="amanha">Amanhã</option>
            <option value="semana">Esta semana</option>
            <option value="intervalo">Intervalo</option>
          </select>
        </label>
        <label className="min-w-0">
          <span className={ROTULO} style={{ color: '#6B7E8A' }}>Quem criou</span>
          <select data-teste="filtro-criador" className="select-light w-full" value={filtros.criador}
            onChange={(e) => definir({ criador: e.target.value })}>
            <option value="todos">Todos</option>
            {criadores.map(c => <option key={c.id} value={c.id}>{c.nome}</option>)}
          </select>
        </label>
        <label className="min-w-0">
          <span className={ROTULO} style={{ color: '#6B7E8A' }}>Equipe</span>
          <select data-teste="filtro-equipe" className="select-light w-full" value={filtros.equipe}
            onChange={(e) => definir({ equipe: e.target.value as Filtros['equipe'] })}>
            <option value="todas">Todas</option>
            <option value="com">Com equipe</option>
            <option value="sem">Sem equipe</option>
          </select>
        </label>
        <label className="min-w-0">
          <span className={ROTULO} style={{ color: '#6B7E8A' }}>Interestadual</span>
          <select data-teste="filtro-interestadual" className="select-light w-full" value={filtros.interestadual}
            onChange={(e) => definir({ interestadual: e.target.value as Filtros['interestadual'] })}>
            <option value="todas">Todas</option>
            <option value="sim">Sim</option>
            <option value="nao">Não</option>
            <option value="indeterminado">Não determinado</option>
          </select>
        </label>
      </div>
      {filtros.periodo === 'intervalo' && (
        <div className="flex flex-wrap gap-2 items-end">
          <label>
            <span className={ROTULO} style={{ color: '#6B7E8A' }}>De</span>
            <input type="date" data-teste="filtro-de" className="input-light" value={filtros.de}
              onChange={(e) => definir({ de: e.target.value })} />
          </label>
          <label>
            <span className={ROTULO} style={{ color: '#6B7E8A' }}>Até</span>
            <input type="date" data-teste="filtro-ate" className="input-light" value={filtros.ate}
              onChange={(e) => definir({ ate: e.target.value })} />
          </label>
          <span className="text-[10px]" style={{ color: '#8A99A6' }}>Datas de Brasília, inclusive.</span>
        </div>
      )}
      {n > 0 && (
        <button type="button" data-teste="filtro-limpar" onClick={limpar}
          className="inline-flex items-center gap-1 px-3 text-[11px] font-bold"
          style={{ minHeight: '32px', border: '1px solid #C8D5DC', color: '#5A6A80', borderRadius: '2px' }}>
          <X size={12} /> Limpar filtros ({n})
        </button>
      )}
    </div>
  )
}
