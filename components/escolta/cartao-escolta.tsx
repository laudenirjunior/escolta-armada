'use client'

/**
 * Cartão padrão da escolta (lote 2026-10, onda K). Variante `linha` (linha da tabela no
 * computador) e `cartao` (celular, mural, painel inicial, Modo Guiado, lista do mapa e
 * arquivadas). Regras de exibição em lib/cartao-escolta.ts. As ações de cada visão entram
 * por `acoes` (e, no cartão, `rodape`), sem mudar o comportamento de cada tela.
 */
import type { ReactNode } from 'react'
import { ArrowRight, MapPin, Users, User } from 'lucide-react'
import {
  type CartaoEscolta as Dados, corCartao, dataHoraBrasilia, etiquetas, resumoEndereco, rotuloStatusCartao, textoEquipe,
} from '@/lib/cartao-escolta'

interface Props {
  escolta: Dados
  variante: 'linha' | 'cartao'
  perfil: string | null | undefined
  /** Operador: "sem equipe" vindo da mural_info (null quando não se sabe). */
  semEquipe?: boolean | null
  onAbrir?: () => void
  /** Selos extras ao lado do código (checklist pendente, já escalada). */
  selos?: ReactNode
  /** Botões de ação (na linha, a última coluna; no cartão, abaixo). */
  acoes?: ReactNode
  /** Conteúdo extra no fim do cartão (ex.: ação do mural). */
  rodape?: ReactNode
  /** Esconde a linha de status (quando a própria visão já mostra). */
  semStatus?: boolean
  destaque?: boolean
}

function Etiquetas({ escolta, perfil }: { escolta: Dados; perfil: string | null | undefined }) {
  const lista = etiquetas(escolta, perfil)
  if (!lista.length) return null
  return (
    <>
      {lista.map(t => (
        <span key={t.chave} className={`${t.classe} ml-2 text-[10px]`} data-teste={`etiqueta-${t.chave}`}>{t.texto}</span>
      ))}
    </>
  )
}

export function CartaoEscolta({ escolta: e, variante, perfil, semEquipe, onAbrir, selos, acoes, rodape, semStatus, destaque }: Props) {
  const cor = corCartao(e)
  const st = rotuloStatusCartao(e.status)
  const equipe = textoEquipe(e, perfil, semEquipe)
  const criador = e.criador?.nome_completo ?? null
  const origem = resumoEndereco(e.origem_endereco)
  const destino = resumoEndereco(e.destino_endereco)
  const quando = dataHoraBrasilia(e.data_hora_prevista)

  if (variante === 'linha') {
    return (
      <tr data-teste="cartao-escolta" data-codigo={e.codigo_escolta ?? ''} data-variante="linha"
        onClick={onAbrir} style={{ cursor: onAbrir ? 'pointer' : undefined }}>
        <td style={{ width: '6px', padding: 0 }}>
          <div data-teste="faixa-cliente" style={{ backgroundColor: cor, width: '5px', minHeight: '44px', height: '100%' }} />
        </td>
        <td>
          <span className="font-mono text-xs font-bold" style={{ color: '#1E2D35' }}>{e.codigo_escolta ?? 'Pendente'}</span>
          {selos}
          <Etiquetas escolta={e} perfil={perfil} />
        </td>
        <td>
          <span className="text-sm font-medium" style={{ color: '#1E2D35' }}>{e.cliente?.nome_cliente ?? '-'}</span>
          {criador && <p className="text-[10px]" style={{ color: '#8A99A6' }} data-teste="criador">Criada por {criador}</p>}
        </td>
        <td className="hidden md:table-cell">
          <div className="flex items-center gap-2 max-w-xs" title={`${e.origem_endereco ?? ''} → ${e.destino_endereco ?? ''}`}>
            <MapPin size={11} style={{ color: '#C8D5DC', flexShrink: 0 }} />
            <span className="text-xs truncate" style={{ color: '#6B7E8A' }} data-teste="origem">{origem}</span>
            <ArrowRight size={11} style={{ color: '#C8D5DC', flexShrink: 0 }} />
            <span className="text-xs truncate" style={{ color: '#6B7E8A' }} data-teste="destino">{destino}</span>
          </div>
        </td>
        <td className="hidden lg:table-cell">
          <span className="text-xs" style={{ color: '#6B7E8A' }} data-teste="quando">{quando}</span>
        </td>
        <td className="hidden lg:table-cell">
          {equipe && <span className="text-xs" style={{ color: '#6B7E8A' }} data-teste="equipe">{equipe}</span>}
        </td>
        <td>{!semStatus && <span className={st.classe} data-teste="status">{st.label}</span>}</td>
        <td>
          <div className="flex items-center justify-end gap-1" onClick={(ev) => ev.stopPropagation()}>{acoes}</div>
        </td>
      </tr>
    )
  }

  return (
    <div data-teste="cartao-escolta" data-codigo={e.codigo_escolta ?? ''} data-variante="cartao"
      className="bg-white relative overflow-hidden"
      style={{ border: `1px solid ${destaque ? cor : '#E2E8EC'}`, borderRadius: '6px', cursor: onAbrir ? 'pointer' : undefined }}
      onClick={onAbrir}>
      <div data-teste="faixa-cliente" aria-hidden
        style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: '5px', backgroundColor: cor }} />
      <div className="pl-4 pr-3 py-3 space-y-1.5">
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <span className="font-mono text-sm font-black" style={{ color: '#1E2D35' }}>{e.codigo_escolta ?? 'Pendente'}</span>
            {selos}
            <Etiquetas escolta={e} perfil={perfil} />
          </div>
          {!semStatus && <span className={`${st.classe} shrink-0`} data-teste="status">{st.label}</span>}
        </div>
        <p className="text-sm font-semibold truncate" style={{ color: '#0E1A33' }}>{e.cliente?.nome_cliente ?? '-'}</p>
        <p className="text-xs" style={{ color: '#5A6A80' }} data-teste="quando">{quando} (Brasília)</p>
        <div className="flex items-start gap-1 text-xs leading-snug" style={{ color: '#5A6A80' }}
          title={`${e.origem_endereco ?? ''} → ${e.destino_endereco ?? ''}`}>
          <MapPin size={11} className="mt-0.5 shrink-0" style={{ color: '#ABB5C9' }} />
          <span><span className="font-medium" data-teste="origem">{origem}</span>
            <ArrowRight size={10} className="inline mx-1" style={{ color: '#ABB5C9' }} />
            <span data-teste="destino">{destino}</span></span>
        </div>
        {(equipe || criador) && (
          <div className="flex flex-wrap gap-x-3 gap-y-0.5 text-[11px]" style={{ color: '#6B7E8A' }}>
            {equipe && <span className="inline-flex items-center gap-1" data-teste="equipe"><Users size={11} /> {equipe}</span>}
            {criador && <span className="inline-flex items-center gap-1" data-teste="criador"><User size={11} /> Criada por {criador}</span>}
          </div>
        )}
        {rodape && <div onClick={(ev) => ev.stopPropagation()}>{rodape}</div>}
        {acoes && <div className="flex gap-2 pt-2 border-t border-gray-100" onClick={(ev) => ev.stopPropagation()}>{acoes}</div>}
      </div>
    </div>
  )
}
