'use client'

/**
 * Lançamento do custo real de combustível por viatura (lote 2026-10, M3, decisão 8).
 *
 * Fica na aba Financeiro da tela de detalhe, que só a gestão vê, e serve tanto durante
 * a escolta quanto no fechamento. Grava nas colunas que Indicadores, PDF e resumo
 * financeiro já somam (escolta_veiculos.abastecimento_*), sem segunda fonte. O banco
 * recusa o operador (migration 206).
 */
import { useEffect, useState } from 'react'
import { Fuel, Save } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

export interface ViaturaCombustivel { id: string; rotulo: string; litros: number | null; valor: number | null }

export function CombustivelViaturas({ viaturas, onSalvo }: { viaturas: ViaturaCombustivel[]; onSalvo: () => void }) {
  const [valores, setValores] = useState<Record<string, { litros: string; valor: string }>>({})
  const [salvando, setSalvando] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; texto: string } | null>(null)
  // Só recarrega os campos quando o valor gravado muda, não a cada renderização da tela.
  const chave = viaturas.map(v => `${v.id}:${v.litros}:${v.valor}`).join('|')
  useEffect(() => {
    setValores(Object.fromEntries(viaturas.map(v => [v.id, { litros: v.litros?.toString() ?? '', valor: v.valor?.toString() ?? '' }])))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chave])

  // Formato brasileiro: "1.250,50" e "1.250" são mil duzentos e cinquenta; "12,5" é doze e meio.
  const numero = (s: string) => {
    const t = s.trim().replace(/\s|R\$/g, '')
    if (t === '') return null
    if (/^\d{1,3}(\.\d{3})+(,\d+)?$/.test(t)) return Number(t.replace(/\./g, '').replace(',', '.'))
    return Number(t.replace(',', '.'))
  }

  const salvar = async () => {
    setSalvando(true); setMsg(null)
    let gravadas = 0
    for (const v of viaturas) {
      const litros = numero(valores[v.id]?.litros ?? ''), valor = numero(valores[v.id]?.valor ?? '')
      if ((litros != null && (!Number.isFinite(litros) || litros < 0)) || (valor != null && (!Number.isFinite(valor) || valor < 0))) {
        setMsg({ ok: false, texto: `${v.rotulo}: informe números não negativos.` }); setSalvando(false); return
      }
      if (litros === v.litros && valor === v.valor) continue
      const { data, error } = await sb.from('escolta_veiculos')
        .update({ abastecimento_litros: litros, abastecimento_valor: valor }).eq('id', v.id).select('id')
      if (error || !data?.length) {
        setMsg({ ok: false, texto: `${v.rotulo}: não foi possível salvar (${error?.message ?? 'sem permissão'}).${gravadas ? ' As viaturas anteriores foram salvas.' : ''}` })
        setSalvando(false); if (gravadas) onSalvo(); return
      }
      gravadas++
    }
    setMsg(gravadas
      ? { ok: true, texto: 'Combustível salvo. Já entra no custo total, nos Indicadores e no PDF.' }
      : { ok: true, texto: 'Nada mudou: os valores já estavam salvos.' })
    setSalvando(false); if (gravadas) onSalvo()
  }

  return (
    <div className="card-light overflow-hidden" data-teste="combustivel-viaturas">
      <div className="cc-panel-header"><Fuel size={12} /> Combustível por viatura (custo real)</div>
      <div className="p-4 space-y-3">
        {viaturas.map(v => (
          <div key={v.id} className="grid grid-cols-1 md:grid-cols-3 gap-2 items-end">
            <p className="text-xs font-bold" style={{ color: '#1E2D35' }}>{v.rotulo}</p>
            <label className="text-[10px] uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Litros
              <input inputMode="decimal" value={valores[v.id]?.litros ?? ''} onChange={e => setValores(s => ({ ...s, [v.id]: { ...s[v.id], litros: e.target.value } }))} className="input-light w-full text-sm mt-1" />
            </label>
            <label className="text-[10px] uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Valor (R$)
              <input inputMode="decimal" value={valores[v.id]?.valor ?? ''} onChange={e => setValores(s => ({ ...s, [v.id]: { ...s[v.id], valor: e.target.value } }))} className="input-light w-full text-sm mt-1" />
            </label>
          </div>
        ))}
        <div className="flex items-center gap-3">
          <button type="button" onClick={salvar} disabled={salvando} className="inline-flex items-center gap-1.5 px-4 text-xs font-black uppercase text-white disabled:opacity-50" style={{ minHeight: '40px', backgroundColor: '#1E7C52' }}>
            <Save size={13} /> {salvando ? 'Salvando...' : 'Salvar combustível'}
          </button>
          {msg && <p className="text-xs" style={{ color: msg.ok ? '#1E7C52' : '#B83832' }}>{msg.texto}</p>}
        </div>
      </div>
    </div>
  )
}
