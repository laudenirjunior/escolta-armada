'use client'

import { useEffect, useRef, useState } from 'react'
import { usePathname, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { Bell, Radio, X } from 'lucide-react'
import {
  STATUS_COM_CHECKIN, TIPO_PONTO_PARADA_ID, inicioOperacaoEm, minutosAteCheckin, ultimoCheckinEm,
} from '@/lib/checkin'
import { useModoGuiado } from '@/hooks/useModoGuiado'

const sb = createClient() as any

interface AlertaCheckin {
  escolta_id: string
  codigo: string
  cliente: string
  minutos_atraso: number
  /** Estado da escolta quando o aviso foi gerado (status | referência do prazo | periodicidade). */
  assinatura: string
}

export function CheckinAlertProvider({ perfil }: { perfil?: string | null }) {
  // Trava do Telegram, separada da trava visual (lote 2026-10). A visual fica no banco,
  // em alertas_dispensados, e vale até mudar o estado da escolta.
  const alertasEnviadosRef = useRef<Set<string>>(new Set())
  const meuUsuarioIdRef = useRef<string | null>(null)
  const [alertas, setAlertas] = useState<AlertaCheckin[]>([])
  const router = useRouter()
  const pathname = usePathname()
  const { ligado: modoGuiado } = useModoGuiado()

  // O alerta nao so avisa: leva direto ao registro. O operador no Modo Guiado vai ao
  // check-in do Painel; os demais, ao dialogo da tela de detalhe, onde a gestao ve a
  // escolta inteira antes de registrar. Ja estando no Campo, navegar para a mesma
  // rota nao remonta a pagina, entao o pedido vai por evento.
  const registrar = (escoltaId: string) => {
    setAlertas(prev => prev.filter(x => x.escolta_id !== escoltaId))
    if (perfil === 'operador' && modoGuiado) {
      if (pathname === '/dashboard/campo') {
        window.dispatchEvent(new CustomEvent('campo:registrar-checkin', { detail: { escoltaId } }))
      } else {
        router.push(`/dashboard/campo?escolta=${escoltaId}&acao=checkin`)
      }
      return
    }
    router.push(`/dashboard/escoltas/${escoltaId}?acao=checkin`)
  }

  useEffect(() => {
    const verificar = async () => {
      const { data: escoltas } = await sb
        .from('escoltas')
        .select('id, codigo_escolta, periodicidade_checkin_min, data_hora_prevista, cliente:clientes(nome_cliente), status')
        .not('periodicidade_checkin_min', 'is', null)
        .in('status', STATUS_COM_CHECKIN)

      if (!escoltas?.length) { setAlertas([]); return }

      // Avisos fechados por este usuário, com a assinatura do estado em que foram fechados.
      const { data: dispensados } = await sb
        .from('alertas_dispensados')
        .select('escolta_id, assinatura')
        .eq('tipo', 'checkin')
      const dispensadoEm = new Map<string, string>(
        (dispensados ?? []).map((d: { escolta_id: string; assinatura: string }) => [d.escolta_id, d.assinatura]))

      const novosAlertas: AlertaCheckin[] = []

      for (const esc of escoltas) {
        // Busca último check-in periódico desta escolta
        const { data: viaturas } = await sb
          .from('escolta_veiculos')
          .select('id')
          .eq('escolta_id', esc.id)

        const viaturaIds = (viaturas ?? []).map((v: any) => v.id)
        if (!viaturaIds.length) continue

        // Regra unica de lib/checkin.ts, a mesma da tela de detalhe e do Painel Guiado.
        // Antes contava qualquer PARADA como check-in e ignorava a escolta que ainda nao
        // tinha nenhum.
        const { data: pontos } = await sb
          .from('pontos_controle')
          .select('data_hora, observacoes, tipo_ponto_id')
          .in('escolta_veiculo_id', viaturaIds)

        const lista = (pontos ?? []) as { data_hora: string; observacoes: string | null; tipo_ponto_id: string }[]
        const ultimoCheckin = ultimoCheckinEm(lista.filter(p => p.tipo_ponto_id === TIPO_PONTO_PARADA_ID))
        const inicioOperacao = inicioOperacaoEm(lista)
        const minutos = minutosAteCheckin({
          periodicidadeMin: esc.periodicidade_checkin_min,
          status: esc.status,
          ultimoCheckin,
          inicioOperacao,
          dataHoraPrevista: esc.data_hora_prevista,
        })
        // Mudança real de estado = novo check-in, novo status ou nova periodicidade.
        const assinatura = `${esc.status}|${ultimoCheckin ?? inicioOperacao ?? esc.data_hora_prevista}|${esc.periodicidade_checkin_min}`
        if (minutos === null) continue
        const minutosAtraso = -minutos

        if (minutosAtraso < 1) continue

        // Telegram so pela regra ANTIGA, ate Pecanha aprovar a mudanca: qualquer
        // PARADA zera o prazo e escolta sem nenhuma nao notifica. A regra nova
        // passaria a notificar o Telegram em casos novos; na tela o aviso ja segue a
        // regra nova. Cada navegador aberto envia o proprio aviso (limite antigo,
        // registrado em docs/12).
        const ultimaParada = lista
          .filter(p => p.tipo_ponto_id === TIPO_PONTO_PARADA_ID)
          .map(p => p.data_hora)
          .sort()
          .pop()
        const atrasoRegraAntiga = ultimaParada
          ? Math.floor((Date.now() - new Date(ultimaParada).getTime() - esc.periodicidade_checkin_min * 60000) / 60000)
          : null
        const notificarTelegram = atrasoRegraAntiga !== null && atrasoRegraAntiga >= 1

        // Aviso na tela: some enquanto o usuário o tiver fechado neste mesmo estado.
        if (dispensadoEm.get(esc.id) !== assinatura) {
          novosAlertas.push({
            escolta_id: esc.id,
            codigo: esc.codigo_escolta ?? '—',
            cliente: esc.cliente?.nome_cliente ?? '—',
            minutos_atraso: minutosAtraso,
            assinatura,
          })
        }

        // Telegram: trava antiga por janela de 5 min nesta aba (a onda F leva o envio ao servidor).
        const janelaAlerta = `${esc.id}-${Math.floor(minutosAtraso / 5)}`
        if (alertasEnviadosRef.current.has(janelaAlerta)) continue
        alertasEnviadosRef.current.add(janelaAlerta)

        // Notificar Telegram — efetivos via escolta_veiculos para filtro correto
        const efetivos: string[] = viaturaIds.length > 0
          ? await sb
              .from('escolta_efetivo')
              .select('papel_na_escolta, vigilante:vigilantes(nome_completo)')
              .in('escolta_veiculo_id', viaturaIds)
              .then(({ data }: any) =>
                (data ?? []).map((e: any) =>
                  `${e.vigilante?.nome_completo ?? '—'}${e.papel_na_escolta ? ` (${e.papel_na_escolta})` : ''}`
                )
              )
          : []

        const statusLabel: Record<string, string> = {
          em_andamento: 'Em Rota', na_origem: 'Na Origem',
          em_transito_destino: 'Trânsito p/ Destino',
          no_destino: 'No Destino', retornando: 'Em Retorno',
        }
        if (notificarTelegram) fetch('/api/telegram', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tipo: 'alerta_checkin',
            titulo: `Alerta: Check-in em Atraso (${atrasoRegraAntiga} min)`,
            descricao: `A escolta não realizou check-in há ${atrasoRegraAntiga} minuto${(atrasoRegraAntiga ?? 0) > 1 ? 's' : ''}. Periodicidade configurada: a cada ${esc.periodicidade_checkin_min} min.`,
            escolta_id: esc.id,
            escolta_codigo: esc.codigo_escolta,
            cliente: esc.cliente?.nome_cliente,
            status_atual: statusLabel[esc.status] ?? esc.status,
            efetivos,
            data_hora: new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' }),
          }),
        }).catch(() => {})
      }

      setAlertas(novosAlertas)
    }

    verificar()
    const interval = setInterval(verificar, 60000)
    return () => clearInterval(interval)
  }, [])

  // O X grava a dispensa no banco; o aviso só volta com mudança real de estado.
  const dispensar = async (a: AlertaCheckin) => {
    setAlertas(prev => prev.filter(x => x.escolta_id !== a.escolta_id))
    if (!meuUsuarioIdRef.current) {
      const { data } = await sb.rpc('get_meu_usuario_id')
      meuUsuarioIdRef.current = (data as string | null) ?? null
    }
    if (!meuUsuarioIdRef.current) return
    const { data, error } = await sb.from('alertas_dispensados')
      .upsert({ usuario_id: meuUsuarioIdRef.current, escolta_id: a.escolta_id, tipo: 'checkin', assinatura: a.assinatura, dispensado_em: new Date().toISOString() })
      .select('escolta_id')
    if (error || !data?.length) console.warn('[checkin] dispensa do aviso nao foi gravada', error?.message)
  }

  if (!alertas.length) return null

  return (
    <div style={{ position: 'fixed', top: '64px', right: '16px', zIndex: 9000, display: 'flex', flexDirection: 'column', gap: '8px', maxWidth: '360px' }}>
      {alertas.map(a => (
        <div key={a.escolta_id} style={{
          backgroundColor: '#fff',
          border: '1.5px solid #F5C6C4',
          borderLeft: '4px solid #B83832',
          borderRadius: '4px',
          padding: '12px 14px',
          boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
          display: 'flex',
          gap: '10px',
          alignItems: 'flex-start',
        }}>
          <Bell size={15} style={{ color: '#B83832', flexShrink: 0, marginTop: '2px' }} />
          <div style={{ flex: 1 }}>
            <p style={{ fontSize: '11px', fontWeight: 800, color: '#B83832', textTransform: 'uppercase', letterSpacing: '0.08em' }}>
              Check-in Atrasado
            </p>
            <p style={{ fontSize: '12px', fontWeight: 600, color: '#0E1A33', marginTop: '2px' }}>
              {a.codigo} — {a.cliente}
            </p>
            <p style={{ fontSize: '13px', color: '#5A6A80', marginTop: '2px' }}>
              Check-in atrasado há {a.minutos_atraso} min
            </p>
            <button
              type="button"
              onClick={() => registrar(a.escolta_id)}
              className="w-full flex items-center justify-center gap-2 font-black uppercase text-white"
              style={{ marginTop: '8px', minHeight: '48px', fontSize: '14px', backgroundColor: '#B83832', borderRadius: '4px' }}
            >
              <Radio size={16} /> Registrar Check-in
            </button>
          </div>
          <button
            onClick={() => dispensar(a)}
            aria-label="Fechar aviso"
            style={{ padding: '6px', color: '#A8B8C2', flexShrink: 0 }}
          >
            <X size={16} />
          </button>
        </div>
      ))}
    </div>
  )
}
