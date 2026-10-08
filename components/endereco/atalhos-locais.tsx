'use client'

/** Botões de atalho acima de origem e destino (M2): um toque preenche endereço e coordenada. */
import { Star } from 'lucide-react'
import type { LocalSalvo } from '@/lib/locais'

export function AtalhosLocais({ locais, selecionadoId, onEscolher }: {
  locais: LocalSalvo[]
  selecionadoId?: string | null
  onEscolher: (l: LocalSalvo) => void
}) {
  if (locais.length === 0) return null
  return (
    <div className="flex flex-wrap gap-1.5 mb-1.5" data-teste="atalhos-locais">
      {locais.map(l => (
        <button key={l.id} type="button" onClick={() => onEscolher(l)}
          className="inline-flex items-center gap-1 px-2.5 text-[11px] font-bold transition-all"
          style={{
            minHeight: '32px', borderRadius: '999px',
            border: `1.5px solid ${selecionadoId === l.id ? '#1E7C52' : '#D6DAE5'}`,
            backgroundColor: selecionadoId === l.id ? '#E8F5EE' : '#fff',
            color: selecionadoId === l.id ? '#1E7C52' : '#1E2D35',
          }}
          title={l.endereco}>
          <Star size={11} /> {l.nome}
        </button>
      ))}
    </div>
  )
}
