'use client'

/**
 * Indicador "Substituições por operador" (lote 2026-10, M5, T7). Lê mural_pedidos, que
 * a RLS só mostra a supervisor, gestor e administrador; para os demais o bloco não aparece.
 */
import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

interface Linha { operador: string; pedidos: number; executados: number; porTempo: number; recusados: number }

export function SubstituicoesPorOperador({ desde, ate }: { desde: string; ate: string }) {
  const [linhas, setLinhas] = useState<Linha[] | null>(null)
  useEffect(() => {
    let vivo = true
    ;(async () => {
      const { data, error } = await sb.from('mural_pedidos')
        .select('status, solicitante:vigilantes!solicitante_vigilante_id(nome_completo)')
        .gte('criado_em', desde).lte('criado_em', ate)
      if (!vivo || error) return
      const mapa = new Map<string, Linha>()
      for (const p of (data ?? []) as Array<{ status: string; solicitante: { nome_completo: string } | null }>) {
        const nome = p.solicitante?.nome_completo ?? '—'
        const l = mapa.get(nome) ?? { operador: nome, pedidos: 0, executados: 0, porTempo: 0, recusados: 0 }
        l.pedidos++
        if (p.status === 'aprovado' || p.status === 'liberado_por_tempo') l.executados++
        if (p.status === 'liberado_por_tempo') l.porTempo++
        if (p.status === 'recusado') l.recusados++
        mapa.set(nome, l)
      }
      setLinhas(Array.from(mapa.values()).sort((a, b) => b.pedidos - a.pedidos))
    })()
    return () => { vivo = false }
  }, [desde, ate])

  if (!linhas) return null
  return (
    <div className="bg-white" style={{ border: '1px solid #E2E8EC', borderRadius: '2px' }}>
      <p className="px-4 pt-3 text-[10px] font-black uppercase tracking-widest" style={{ color: '#5A6A80' }}>Substituições de equipe por operador</p>
      <table className="w-full text-xs mt-2">
        <thead>
          <tr style={{ color: '#5A6A80' }}>
            {['Operador', 'Pedidos', 'Substituiu', 'Liberado por tempo', 'Recusados'].map(h => <th key={h} className="text-left px-4 py-2 font-black uppercase tracking-wider">{h}</th>)}
          </tr>
        </thead>
        <tbody>
          {linhas.length === 0 && <tr><td colSpan={5} className="px-4 py-3" style={{ color: '#6B7E8A' }}>Nenhum pedido de substituição no período.</td></tr>}
          {linhas.map(l => (
            <tr key={l.operador} style={{ borderTop: '1px solid #EEF1F5' }}>
              <td className="px-4 py-2 font-bold">{l.operador}</td>
              <td className="px-4 py-2">{l.pedidos}</td>
              <td className="px-4 py-2">{l.executados}</td>
              <td className="px-4 py-2">{l.porTempo}</td>
              <td className="px-4 py-2">{l.recusados}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
