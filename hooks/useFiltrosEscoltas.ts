'use client'

/**
 * Filtros da lista e do mural de escoltas (lote 2026-10, onda K; docs/14, 15.2 item 3).
 *
 * Status, cliente, período, quem criou, equipe, interestadual e busca, combinados. Vão ao
 * servidor quando dá (status, cliente, período, quem criou, interestadual); equipe e busca
 * ficam no navegador (a equipe da gestão vem do efetivo embutido; a do operador, da
 * mural_info). Lembrados por usuário no aparelho, na chave `filtros-escoltas:<usuario_id>`
 * (id de usuarios, o mesmo do useAuth), no padrão de hooks/useModoGuiado.tsx: leitura e
 * escrita com try/catch, e a navegação privada cai no padrão. Outro usuário no mesmo
 * navegador tem outra chave e não herda nada.
 */
import { useCallback, useEffect, useState } from 'react'

export type Periodo = 'todos' | 'hoje' | 'amanha' | 'semana' | 'intervalo'

export interface Filtros {
  status: string          // código, 'todos' ou 'com_pendencias'
  cliente: string         // id ou 'todos'
  periodo: Periodo
  de: string              // AAAA-MM-DD (intervalo)
  ate: string             // AAAA-MM-DD (intervalo, inclusive)
  criador: string         // id de usuarios ou 'todos'
  equipe: 'todas' | 'com' | 'sem'
  interestadual: 'todas' | 'sim' | 'nao' | 'indeterminado'
  busca: string
}

export const FILTROS_PADRAO: Filtros = {
  status: 'todos', cliente: 'todos', periodo: 'todos', de: '', ate: '',
  criador: 'todos', equipe: 'todas', interestadual: 'todas', busca: '',
}

export function chaveFiltros(usuarioId: string) {
  return `filtros-escoltas:${usuarioId}`
}

function ler(usuarioId: string | null | undefined): Filtros {
  if (!usuarioId || typeof window === 'undefined') return FILTROS_PADRAO
  try {
    const bruto = window.localStorage.getItem(chaveFiltros(usuarioId))
    if (!bruto) return FILTROS_PADRAO
    const salvo = JSON.parse(bruto) as Partial<Filtros>
    return { ...FILTROS_PADRAO, ...(salvo && typeof salvo === 'object' ? salvo : {}) }
  } catch {
    return FILTROS_PADRAO
  }
}

// Brasília não tem horário de verão desde 2019: o dia começa às 03:00 UTC.
const FUSO = '-03:00'

function diaBrasilia(d: Date): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d)
}

function somarDias(dia: string, n: number): string {
  const d = new Date(`${dia}T12:00:00${FUSO}`)
  d.setUTCDate(d.getUTCDate() + n)
  return diaBrasilia(d)
}

/** Limites [de, até) do período, em ISO, contados em dias de Brasília. Nulo: sem limite. */
export function limitesPeriodo(f: Pick<Filtros, 'periodo' | 'de' | 'ate'>, agora = new Date()): { de: string | null; ate: string | null } {
  const hoje = diaBrasilia(agora)
  const inicio = (dia: string) => new Date(`${dia}T00:00:00${FUSO}`).toISOString()
  switch (f.periodo) {
    case 'hoje': return { de: inicio(hoje), ate: inicio(somarDias(hoje, 1)) }
    case 'amanha': return { de: inicio(somarDias(hoje, 1)), ate: inicio(somarDias(hoje, 2)) }
    case 'semana': {
      // Semana de segunda a domingo.
      const dow = new Date(`${hoje}T12:00:00${FUSO}`).getUTCDay() // 0 = domingo
      const seg = somarDias(hoje, dow === 0 ? -6 : 1 - dow)
      return { de: inicio(seg), ate: inicio(somarDias(seg, 7)) }
    }
    case 'intervalo': return {
      de: f.de ? inicio(f.de) : null,
      ate: f.ate ? inicio(somarDias(f.ate, 1)) : null,
    }
    default: return { de: null, ate: null }
  }
}

/**
 * Aplica no servidor o que dá. 'com_pendencias' fica por conta da tela (embed !inner),
 * como já era na onda I.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function aplicarFiltrosServidor(q: any, f: Filtros): any {
  if (f.status !== 'todos' && f.status !== 'com_pendencias') q = q.eq('status', f.status)
  if (f.cliente !== 'todos') q = q.eq('cliente_id', f.cliente)
  if (f.criador !== 'todos') q = q.eq('criada_por', f.criador)
  const { de, ate } = limitesPeriodo(f)
  if (de) q = q.gte('data_hora_prevista', de)
  if (ate) q = q.lt('data_hora_prevista', ate)
  if (f.interestadual === 'sim') q = q.eq('interestadual', true)
  else if (f.interestadual === 'nao') q = q.eq('interestadual', false)
  else if (f.interestadual === 'indeterminado') q = q.is('interestadual', null)
  return q
}

export function filtrosAtivos(f: Filtros): number {
  return (Object.keys(FILTROS_PADRAO) as (keyof Filtros)[])
    .filter(k => k !== 'de' && k !== 'ate' && f[k] !== FILTROS_PADRAO[k]).length
}

export function useFiltrosEscoltas(usuarioId: string | null | undefined) {
  const [filtros, setFiltros] = useState<Filtros>(() => ler(usuarioId))
  // Pronto: os filtros já são os do usuário atual (a tela só consulta depois disso).
  const [prontoPara, setProntoPara] = useState<string | null>(usuarioId ?? null)

  useEffect(() => {
    setFiltros(ler(usuarioId))
    setProntoPara(usuarioId ?? null)
  }, [usuarioId])

  const definir = useCallback((parcial: Partial<Filtros>) => {
    setFiltros(ant => {
      const novo = { ...ant, ...parcial }
      if (usuarioId) {
        try { window.localStorage.setItem(chaveFiltros(usuarioId), JSON.stringify(novo)) } catch { /* vale até recarregar */ }
      }
      return novo
    })
  }, [usuarioId])

  const limpar = useCallback(() => {
    setFiltros(FILTROS_PADRAO)
    if (usuarioId) {
      try { window.localStorage.removeItem(chaveFiltros(usuarioId)) } catch { /* sem armazenamento */ }
    }
  }, [usuarioId])

  return { filtros, definir, limpar, pronto: !!usuarioId && prontoPara === usuarioId }
}
