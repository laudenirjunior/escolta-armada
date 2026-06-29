'use client'

import { useEffect, useRef, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { Bell, X } from 'lucide-react'

const sb = createClient() as any

interface AlertaCheckin {
  escolta_id: string
  codigo: string
  cliente: string
  minutos_atraso: number
}

export function CheckinAlertProvider() {
  const alertasEnviadosRef = useRef<Set<string>>(new Set())
  const [alertas, setAlertas] = useState<AlertaCheckin[]>([])

  useEffect(() => {
    const verificar = async () => {
      const { data: escoltas } = await sb
        .from('escoltas')
        .select('id, codigo_escolta, periodicidade_checkin_min, cliente:clientes(nome_cliente), status')
        .not('periodicidade_checkin_min', 'is', null)
        .in('status', ['em_andamento', 'na_origem', 'no_destino', 'retornando'])

      if (!escoltas?.length) return

      const novosAlertas: AlertaCheckin[] = []

      for (const esc of escoltas) {
        // Busca último check-in periódico desta escolta
        const { data: viaturas } = await sb
          .from('escolta_veiculos')
          .select('id')
          .eq('escolta_id', esc.id)

        const viaturaIds = (viaturas ?? []).map((v: any) => v.id)
        if (!viaturaIds.length) continue

        const { data: ultimoPonto } = await sb
          .from('pontos_controle')
          .select('data_hora')
          .in('escolta_veiculo_id', viaturaIds)
          .eq('tipo_ponto_id', 'e1601f15-5ef9-44e8-abd0-17f65b3aa760') // PARADA
          .order('data_hora', { ascending: false })
          .limit(1)
          .maybeSingle()

        const referencia = ultimoPonto ? new Date(ultimoPonto.data_hora) : null
        if (!referencia) continue

        const msDecorrido = Date.now() - referencia.getTime()
        const msLimite = esc.periodicidade_checkin_min * 60 * 1000
        const minutosAtraso = Math.floor((msDecorrido - msLimite) / 60000)

        if (minutosAtraso < 1) continue

        // Janela de alerta: evita spam — alerta a cada 5 min de atraso
        const janelaAlerta = `${esc.id}-${Math.floor(minutosAtraso / 5)}`
        if (alertasEnviadosRef.current.has(janelaAlerta)) continue
        alertasEnviadosRef.current.add(janelaAlerta)

        novosAlertas.push({
          escolta_id: esc.id,
          codigo: esc.codigo_escolta ?? '—',
          cliente: esc.cliente?.nome_cliente ?? '—',
          minutos_atraso: minutosAtraso,
        })

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
          no_destino: 'No Destino', retornando: 'Em Retorno',
        }
        fetch('/api/telegram', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tipo: 'alerta_checkin',
            titulo: `Alerta: Check-in em Atraso (${minutosAtraso} min)`,
            descricao: `A escolta não realizou check-in há ${minutosAtraso} minuto${minutosAtraso > 1 ? 's' : ''}. Periodicidade configurada: a cada ${esc.periodicidade_checkin_min} min.`,
            escolta_id: esc.id,
            escolta_codigo: esc.codigo_escolta,
            cliente: esc.cliente?.nome_cliente,
            status_atual: statusLabel[esc.status] ?? esc.status,
            efetivos,
            data_hora: new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' }),
          }),
        }).catch(() => {})
      }

      if (novosAlertas.length > 0) {
        setAlertas(prev => {
          const idsExistentes = new Set(prev.map(a => a.escolta_id))
          return [...prev, ...novosAlertas.filter(a => !idsExistentes.has(a.escolta_id))]
        })
      }
    }

    verificar()
    const interval = setInterval(verificar, 60000)
    return () => clearInterval(interval)
  }, [])

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
            <p style={{ fontSize: '11px', color: '#5A6A80', marginTop: '2px' }}>
              Sem check-in há {a.minutos_atraso} min
            </p>
          </div>
          <button
            onClick={() => setAlertas(prev => prev.filter(x => x.escolta_id !== a.escolta_id))}
            style={{ padding: '2px', color: '#A8B8C2', flexShrink: 0 }}
          >
            <X size={13} />
          </button>
        </div>
      ))}
    </div>
  )
}
