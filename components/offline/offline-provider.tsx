'use client'

/**
 * Onda L (Lote 2026-10; docs/14, seções 16.3.2 e 16.3.7): liga o envio automático da fila de
 * campo para o usuário logado, pede ao service worker as telas de campo para abrir sem
 * internet e mostra a faixa fixa ("Sem conexão. N registros guardados no aparelho"; âmbar
 * enviando; some com zero). ContadorFila é o contador do Painel.
 *
 * Com a fila vazia e internet, nada disto chama o servidor além de config_offline (uma vez).
 */
import { useEffect, useSyncExternalStore } from 'react'
import { createClient } from '@/lib/supabase/client'
import {
  assinarEstadoEnvio, iniciarEnvioAutomatico, lerConfigOffline, lerEstadoEnvio,
  type ClienteOffline, type EstadoEnvio,
} from '@/lib/offline/envio'
import { filaDisponivel, lerSnapshot, limparRecibos } from '@/lib/offline/fila'
import { precarregarTelas } from '@/lib/offline/sessao'

function useEstadoFila(): EstadoEnvio {
  return useSyncExternalStore(assinarEstadoEnvio, lerEstadoEnvio, lerEstadoEnvio)
}

/** Escoltas do operador guardadas pelo Campo (snapshot "escoltas"): o detalhe delas abre sem internet. */
async function telasDoSnapshot(authUserId: string): Promise<string[]> {
  try {
    const s = await lerSnapshot<Array<{ id: string }>>(authUserId, 'escoltas')
    return (s?.dados ?? []).filter(e => e && typeof e.id === 'string').map(e => `/dashboard/escoltas/${e.id}`)
  } catch { return [] }
}

export function OfflineProvider({ authUserId, modoOffline }: { authUserId: string | null; modoOffline: boolean }) {
  useEffect(() => {
    if (!authUserId || !filaDisponivel()) return
    const sb = createClient() as unknown as ClienteOffline
    const parar = iniciarEnvioAutomatico({ supabase: sb, authUserId })
    if (!modoOffline) {
      void lerConfigOffline(sb)
      void telasDoSnapshot(authUserId).then(detalhes => precarregarTelas(['/dashboard/campo', '/dashboard', ...detalhes]))
    }
    void limparRecibos().catch(() => 0)
    return parar
  }, [authUserId, modoOffline])
  return <FaixaOffline />
}

function plural(n: number, um: string, varios: string) { return n === 1 ? um : varios }

export function FaixaOffline() {
  const e = useEstadoFila()
  const n = e.pendentes
  const qtd = n > 0 ? `${n} ${plural(n, 'registro guardado', 'registros guardados')} no aparelho.` : ''
  let texto: string | null = null
  let cor = '#B83832'
  if (!e.online) {
    texto = `Sem conexão.${qtd ? ' ' + qtd : ''}`
  } else if (n > 0 && e.precisaLogin) {
    texto = `Entre de novo para enviar ${n} ${plural(n, 'registro guardado', 'registros guardados')} no aparelho.`
    cor = '#9A6A00'
  } else if (n > 0 && e.atualizacaoEmAndamento) {
    texto = `Atualização em andamento. ${qtd}`
    cor = '#9A6A00'
  } else if (n > 0) {
    texto = `${e.enviando ? 'Enviando' : 'Aguardando envio:'} ${n} ${plural(n, 'registro guardado', 'registros guardados')} no aparelho.`
    cor = '#9A6A00'
  }
  if (!texto) return null
  return (
    <div
      role="status"
      aria-live="polite"
      data-teste="faixa-offline"
      data-estado={!e.online ? 'offline' : 'enviando'}
      className="w-full text-center font-bold"
      style={{ backgroundColor: cor, color: '#fff', fontSize: '14px', padding: '6px 12px', paddingTop: 'calc(6px + env(safe-area-inset-top))', zIndex: 60 }}
    >
      {texto}
    </div>
  )
}

/** Contador do Painel: guardados, não aceitos (conflito) e recusados. Some com tudo zero. */
export function ContadorFila() {
  const e = useEstadoFila()
  if (e.pendentes === 0 && e.conflitos === 0 && e.recusados === 0) return null
  return (
    <div data-teste="contador-fila" className="p-3 space-y-1" style={{ backgroundColor: '#FFF8E6', border: '1.5px solid #E9C46A', borderRadius: '4px' }}>
      {e.pendentes > 0 && (
        <p data-teste="contador-pendentes" className="font-bold" style={{ fontSize: '16px', color: '#5C4510' }}>
          {e.pendentes} {plural(e.pendentes, 'registro guardado', 'registros guardados')} no aparelho{e.online ? '' : ', aguardando sinal'}.
        </p>
      )}
      {e.conflitos > 0 && (
        <p data-teste="contador-conflitos" className="font-bold" style={{ fontSize: '16px', color: '#B83832' }}>
          {e.conflitos} {plural(e.conflitos, 'registro não aceito', 'registros não aceitos')}; a supervisão foi avisada.
        </p>
      )}
      {e.recusados > 0 && (
        <p data-teste="contador-recusados" className="font-bold" style={{ fontSize: '16px', color: '#B83832' }}>
          {e.recusados} {plural(e.recusados, 'registro recusado', 'registros recusados')}: você não tem vínculo com a escolta. Avise a central.
        </p>
      )}
    </div>
  )
}
