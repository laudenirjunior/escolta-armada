'use client'

/**
 * Onda L (Lote 2026-10; docs/14, seções 16.3.2 e 16.3.7): liga o envio automático da fila de
 * campo para o usuário logado, pede ao service worker as telas de campo para abrir sem
 * internet e mostra a faixa fixa ("Sem conexão. N registros guardados no aparelho"; âmbar
 * enviando; some com zero). ContadorFila é o contador do Painel.
 *
 * Com a fila vazia e internet, nada disto chama o servidor além de config_offline (uma vez).
 */
import { useEffect, useState, useSyncExternalStore } from 'react'
import { createClient } from '@/lib/supabase/client'
import {
  assinarEstadoEnvio, iniciarEnvioAutomatico, lerConfigOffline, lerEstadoEnvio,
  type ClienteOffline, type EstadoEnvio,
} from '@/lib/offline/envio'
import { filaDisponivel, lerSnapshot, limparRecibos, registrosDoUsuario, type RegistroFila } from '@/lib/offline/fila'
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

const ROTULO_TIPO: Record<string, string> = {
  etapa: 'Etapa', linhas: 'Registro de campo', presenca_base: 'Presença na base', emergencia: 'Emergência',
}

/** DD/MM/AAAA HH:MM no horário de Brasília. */
function horaBr(iso: string | null | undefined): string {
  if (!iso) return '-'
  return new Date(iso).toLocaleString('pt-BR', {
    timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
  }).replace(',', '')
}

/** Registros não aceitos e recusados que ficam no aparelho (o operador vê; não há como apagar). */
function useNaoAceitos(authUserId: string | null, chave: string): RegistroFila[] {
  const [lista, setLista] = useState<RegistroFila[]>([])
  useEffect(() => {
    let ativo = true
    if (!authUserId || !filaDisponivel()) { setLista([]); return }
    registrosDoUsuario(authUserId)
      .then(rs => { if (ativo) setLista(rs.filter(r => r.estado === 'conflito' || r.estado === 'recusado').sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0))) })
      .catch(() => {})
    return () => { ativo = false }
  }, [authUserId, chave])
  return lista
}

/** Contador do Painel: guardados, não aceitos (conflito) e recusados. Some com tudo zero. */
export function ContadorFila() {
  const e = useEstadoFila()
  const naoAceitos = useNaoAceitos(e.authUserId, `${e.conflitos}:${e.recusados}`)
  if (e.pendentes === 0 && e.conflitos === 0 && e.recusados === 0) return null
  const recusados = naoAceitos.filter(r => r.estado === 'recusado')
  const conflitos = naoAceitos.filter(r => r.estado === 'conflito')
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
      {conflitos.length > 0 && (
        <details data-teste="lista-nao-aceitos">
          <summary className="font-bold cursor-pointer" style={{ fontSize: '14px', color: '#5C4510' }}>Registros não aceitos</summary>
          <ul className="mt-1 space-y-1" style={{ fontSize: '14px', color: '#5C4510' }}>
            {conflitos.map(r => (
              <li key={r.client_id}>{ROTULO_TIPO[r.tipo] ?? r.tipo} de {horaBr(r.data_hora_acao)}: guardado no servidor e enviado à supervisão.</li>
            ))}
          </ul>
        </details>
      )}
      {recusados.length > 0 && (
        <div data-teste="lista-recusados">
          <p className="font-bold" style={{ fontSize: '14px', color: '#B83832' }}>Registros recusados</p>
          <ul className="mt-1 space-y-1" style={{ fontSize: '14px', color: '#5C4510' }}>
            {recusados.map(r => (
              <li key={r.client_id} data-teste="registro-recusado">
                {ROTULO_TIPO[r.tipo] ?? r.tipo} de {horaBr(r.data_hora_acao)}: {r.ultimo_erro === 'SEM_VINCULO' ? 'sem vínculo com a escolta' : (r.ultimo_erro ?? 'recusado pelo sistema')}. Ficou só neste aparelho.
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
