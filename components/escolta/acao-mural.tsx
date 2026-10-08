'use client'

/**
 * Botões do mural para o operador, lote 2026-10 (M5). Um componente só para a tabela
 * (compacto) e para o cartão do celular (largura inteira), para as duas telas mostrarem
 * a mesma regra. Quem valida de verdade são as RPCs da migration 204.
 */
import { CheckCircle2, Clock, Hourglass } from 'lucide-react'
import { InfoMural, horaBrasilia } from '@/lib/mural'

export function AcaoMural({
  semEquipe, souComandante, info, travasAtivas, ocupado, compacto,
  onPuxar, onPedir, onDevolver, onEstouNaBase, onCancelarPedido,
}: {
  semEquipe: boolean
  souComandante: boolean
  info: InfoMural | undefined
  /** Falso entre o deploy e a migration 204: substituição desligada na tela. */
  travasAtivas: boolean
  ocupado: boolean
  compacto?: boolean
  onPuxar: () => void
  onPedir: () => void
  onDevolver: () => void
  onEstouNaBase: () => void
  onCancelarPedido: (pedidoId: string) => void
}) {
  const base = compacto
    ? 'px-3 h-9 text-[10px] font-black uppercase tracking-wider transition-all disabled:opacity-50'
    : 'w-full flex items-center justify-center gap-2 rounded-lg text-xs font-black uppercase tracking-wider mb-2 disabled:opacity-50'
  const alto = compacto ? {} : { minHeight: '44px' }
  const agora = Date.now()
  const janelaAberta = info ? agora >= new Date(info.janela_inicio).getTime() : false
  const sinal = (texto: string, cor: string, fundo: string, icone?: React.ReactNode) => (
    <span className={compacto ? 'px-2 h-9 inline-flex items-center gap-1 text-[10px] font-black uppercase tracking-wider'
                              : 'w-full flex items-center justify-center gap-2 rounded-lg text-xs font-bold mb-2 px-2 text-center'}
      style={{ ...alto, color: cor, backgroundColor: fundo }}>{icone}{texto}</span>
  )

  // Escolta em que estou: devolver (comandante) e, na janela, "Estou na base".
  if (info?.sou_da_equipe || souComandante) {
    return (
      <>
        {travasAtivas && janelaAberta && !info?.eu_confirmei && (
          <button type="button" onClick={onEstouNaBase} disabled={ocupado} className={`${base} text-white`}
            style={{ ...alto, backgroundColor: '#1E7C52', borderRadius: compacto ? '2px' : undefined }}
            title="Confirmar que a equipe está na base">
            {compacto ? 'Estou na base' : <><CheckCircle2 size={16} /> Estou na base</>}
          </button>
        )}
        {travasAtivas && info?.eu_confirmei && sinal('Presença confirmada', '#1E7C52', '#E8F5EE', compacto ? null : <CheckCircle2 size={14} />)}
        {souComandante && (
          <button type="button" onClick={onDevolver} disabled={ocupado} className={base}
            style={{ ...alto, border: '1px solid #C8813A', color: '#8A5A10', borderRadius: compacto ? '2px' : undefined }}
            title="Devolver ao mural, enquanto não começou">
            {ocupado ? '...' : compacto ? 'Devolver' : 'Devolver ao mural'}
          </button>
        )}
      </>
    )
  }

  if (semEquipe) {
    return (
      <button type="button" onClick={onPuxar} disabled={ocupado} className={`${base} text-white`}
        style={{ ...alto, backgroundColor: '#1E7C52', borderRadius: compacto ? '2px' : undefined }}
        title="Assumir esta escolta como comandante">
        {compacto ? 'Puxar' : 'Puxar esta escolta para mim'}
      </button>
    )
  }

  // Escolta de colega: substituição só pelas travas.
  if (!travasAtivas) return sinal('Atualização em andamento', '#5A6A80', '#EEF1F5')
  if (info?.pedido?.meu) {
    return (
      <>
        {sinal(`Pedido enviado. Liberado às ${horaBrasilia(info.pedido.expira_em)} se ninguém responder`, '#8A5A10', '#FFF7E6', compacto ? null : <Hourglass size={14} />)}
        <button type="button" onClick={() => onCancelarPedido(info.pedido!.id)} disabled={ocupado} className={base}
          style={{ ...alto, border: '1px solid #C8D5DC', color: '#5A6A80', borderRadius: compacto ? '2px' : undefined }}>
          Cancelar pedido
        </button>
      </>
    )
  }
  if (info?.pedido) return sinal('Pedido de outro operador em análise', '#5A6A80', '#EEF1F5')
  if (info?.presenca) return sinal('Equipe na base', '#1E7C52', '#E8F5EE', compacto ? null : <CheckCircle2 size={14} />)
  if (!janelaAberta) return sinal(`Substituição a partir das ${horaBrasilia(info?.janela_inicio)}`, '#5A6A80', '#EEF1F5', compacto ? null : <Clock size={14} />)
  return (
    <button type="button" onClick={onPedir} disabled={ocupado} className={`${base} text-white`}
      style={{ ...alto, backgroundColor: '#C8813A', borderRadius: compacto ? '2px' : undefined }}
      title="Pedir à supervisão para assumir esta escolta">
      {compacto ? 'Pedir' : 'Pedir para assumir (equipe escalada)'}
    </button>
  )
}
