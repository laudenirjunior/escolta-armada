'use client'

/**
 * Seletor da cor do cliente (onda K; docs/14, 15.2 item 1). Só as 12 cores da paleta
 * fechada (lib/paleta-clientes.ts); a trigger da migration 216 normaliza qualquer outra
 * cor gravada (a master grava cor livre). A cor não é exclusiva (decisão S6): o seletor
 * avisa quando outro cliente ativo já usa a cor escolhida, sem impedir.
 */
import { Check } from 'lucide-react'
import { PALETA_CLIENTES, corDoCliente } from '@/lib/paleta-clientes'

export interface ClienteCor {
  id: string
  nome_cliente: string
  cor_destaque: string | null
  status: string
}

export function SeletorCorCliente({
  valor, onChange, clientes, clienteAtualId,
}: {
  valor: string | null | undefined
  onChange: (cor: string) => void
  /** Todos os clientes, para o aviso de cor já usada (só os ativos contam). */
  clientes: ClienteCor[]
  /** Cliente em edição (não conta para o aviso). */
  clienteAtualId?: string | null
}) {
  const atual = corDoCliente(valor)
  const usadaPor = clientes
    .filter(c => c.status === 'ativo' && c.id !== clienteAtualId && corDoCliente(c.cor_destaque) === atual)
    .map(c => c.nome_cliente)
  return (
    <div>
      <div className="flex flex-wrap gap-1.5" role="radiogroup" aria-label="Cor do cliente">
        {PALETA_CLIENTES.map(p => {
          const marcada = p.cor === atual
          return (
            <button
              key={p.cor}
              type="button"
              role="radio"
              aria-checked={marcada}
              aria-label={p.nome}
              title={p.nome}
              data-teste="cor-paleta"
              data-cor={p.cor}
              onClick={() => onChange(p.cor)}
              className="flex items-center justify-center"
              style={{
                width: '28px', height: '28px', borderRadius: '4px', backgroundColor: p.cor,
                outline: marcada ? '2px solid #0E1A33' : 'none', outlineOffset: '2px', cursor: 'pointer',
              }}
            >
              {marcada && <Check size={14} color="#FFFFFF" />}
            </button>
          )
        })}
      </div>
      {usadaPor.length > 0 && (
        <p data-teste="aviso-cor-usada" className="mt-1.5" style={{ fontSize: '11px', color: '#8A5A10' }}>
          Cor já usada por {usadaPor.join(', ')}. Pode manter, mas as escoltas desses clientes ficam com a mesma faixa.
        </p>
      )}
    </div>
  )
}
