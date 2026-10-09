'use client'

/**
 * "Salvar este endereço" ao lado do campo de origem ou destino (onda D2, decisão 5):
 * supervisor ou acima guarda o endereço do campo, com complemento, coordenada e UF, como
 * local salvo aguardando conferência. Só vira atalho depois que gestor ou administrador
 * conferir o pino em Configurações, Locais salvos (decisão 6).
 */
import { useState } from 'react'
import { Star } from 'lucide-react'
import { UFS } from '@/lib/locais'

export function SalvarEnderecoLocal({ campo, endereco, uf, onSalvar }: {
  campo: 'origem' | 'destino'
  endereco: string
  /** UF do campo (do atalho ou, com a onda K, da busca); o supervisor pode trocar. */
  uf: string
  onSalvar: (nome: string, uf: string) => Promise<{ ok: boolean; texto: string }>
}) {
  const [aberto, setAberto] = useState(false)
  const [nome, setNome] = useState('')
  const [ufLocal, setUfLocal] = useState('')
  const [salvando, setSalvando] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; texto: string } | null>(null)
  const semEndereco = !endereco.trim()

  return (
    <div className="flex flex-col items-end" data-teste={`salvar-endereco-${campo}`}>
      {!aberto && (
        <button type="button" disabled={semEndereco}
          onClick={() => { setAberto(true); setMsg(null); setNome(''); setUfLocal(uf) }}
          title={semEndereco ? 'Preencha o endereço primeiro' : 'Guardar como local salvo (aguarda conferência)'}
          className="inline-flex items-center gap-1 px-2 text-[10px] font-bold disabled:opacity-40"
          style={{ minHeight: '22px', border: '1px solid #E2E6EE', borderRadius: '4px', color: '#5A6A80', backgroundColor: '#fff' }}>
          <Star size={9} /> Salvar este endereço
        </button>
      )}
      {aberto && (
        <div className="flex flex-wrap gap-1.5 items-center justify-end">
          <input value={nome} onChange={e => setNome(e.target.value)} maxLength={40} placeholder="Nome do atalho (ex.: JAMEF)"
            aria-label="Nome do atalho" className="input-light text-xs" style={{ minHeight: '30px', width: '170px' }} />
          <select value={ufLocal} onChange={e => setUfLocal(e.target.value)} aria-label="UF do local"
            className="input-light text-xs" style={{ minHeight: '30px', width: '64px' }}>
            <option value="">UF</option>
            {UFS.map(u => <option key={u} value={u}>{u}</option>)}
          </select>
          <button type="button" disabled={salvando || nome.trim().length < 2}
            onClick={async () => {
              setSalvando(true)
              const r = await onSalvar(nome.trim(), ufLocal)
              setMsg(r); setSalvando(false)
              if (r.ok) setAberto(false)
            }}
            className="px-2 text-[11px] font-bold text-white disabled:opacity-50"
            style={{ minHeight: '30px', borderRadius: '4px', backgroundColor: '#1E2D35' }}>
            Salvar local
          </button>
          <button type="button" onClick={() => setAberto(false)} className="px-2 text-[11px] font-bold"
            style={{ minHeight: '30px', border: '1px solid #C8D5DC', borderRadius: '4px', color: '#5A6A80' }}>
            Cancelar
          </button>
        </div>
      )}
      {msg && <p className="text-right mt-1" style={{ fontSize: '10px', color: msg.ok ? '#1E7C52' : '#B83832', maxWidth: '320px' }}>{msg.texto}</p>}
    </div>
  )
}
