'use client'

/**
 * Botões de atalho acima de origem e destino (M2): um toque preenche endereço, complemento,
 * coordenada e UF. Onda D2: botões pequenos e discretos, os mais usados primeiro (a ordem
 * vem de carregarLocaisAtivos: vezes_usado DESC, nome).
 */
import { Star } from 'lucide-react'
import type { LocalSalvo } from '@/lib/locais'

export function AtalhosLocais({ locais, selecionadoId, onEscolher, campo }: {
  locais: LocalSalvo[]
  selecionadoId?: string | null
  onEscolher: (l: LocalSalvo) => void
  /** origem ou destino, para os testes acharem a linha certa. */
  campo?: 'origem' | 'destino'
}) {
  if (locais.length === 0) return null
  return (
    <div className="flex flex-wrap gap-1 mb-1.5" data-teste="atalhos-locais" data-campo={campo}>
      {locais.map(l => {
        const sel = selecionadoId === l.id
        return (
          <button key={l.id} type="button" onClick={() => onEscolher(l)}
            className="inline-flex items-center gap-1 px-2 text-[10px] font-bold transition-all"
            style={{
              minHeight: '24px', borderRadius: '999px',
              border: `1px solid ${sel ? '#1E7C52' : '#E2E6EE'}`,
              backgroundColor: sel ? '#E8F5EE' : '#F7F8FA',
              color: sel ? '#1E7C52' : '#5A6A80',
            }}
            title={[l.endereco, l.complemento, l.uf].filter(Boolean).join(', ')}>
            <Star size={9} /> {l.nome}
          </button>
        )
      })}
    </div>
  )
}
