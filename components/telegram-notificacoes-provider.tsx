'use client'

import { useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { urlAssinada } from '@/lib/fotos-url'

const sb = createClient() as any

// Todos os eventos de pontos_controle, ocorrências e status agora têm chamadas
// diretas nos handlers das páginas (mais confiável). Este provider cobre apenas
// presenças de vigilantes, que não têm handler dedicado.

export function TelegramNotificacoesProvider() {
  useEffect(() => {
    const channel = sb.channel(`tg-presencas-${Date.now()}`)

    channel.on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'presencas' },
      async (ev: any) => {
        const row = ev.new
        // Lote 2026-10 (onda F): uma mensagem por presença, não uma por navegador aberto.
        // A reserva fica no banco; só o primeiro navegador recebe true e envia, com a foto.
        const { data: reservado, error: erroReserva } = await sb.rpc('reservar_aviso_presenca', { p_presenca_id: row.id })
        if (!erroReserva && !reservado) return
        const { data } = await sb
          .from('presencas')
          .select(`
            foto:fotos!foto_id(caminho_arquivo),
            vigilante:vigilantes!vigilante_id(nome_completo),
            escolta:escoltas!escolta_id!inner(
              id, codigo_escolta, status, arquivada_em, cliente:clientes(nome_cliente)
            )
          `)
          .eq('id', row.id)
          // Onda I: presença anulada ou de escolta arquivada não vai ao Telegram.
          .is('anulado_em', null)
          .is('escolta.arquivada_em', null)
          .maybeSingle()

        if (!data) return

        let fotoUrl: string | null = null
        if (data.foto?.caminho_arquivo) {
          // Lote 2026-10: URL assinada; o Telegram baixa a foto na hora do envio.
          fotoUrl = await urlAssinada(sb, data.foto.caminho_arquivo)
        }

        const { data: viatRowsPres } = await sb
          .from('escolta_veiculos')
          .select('id')
          .eq('escolta_id', row.escolta_id)
        const viatIdsPres = (viatRowsPres ?? []).map((v: any) => v.id)
        const efetivos: string[] = viatIdsPres.length > 0
          ? await sb
              .from('escolta_efetivo')
              .select('papel_na_escolta, vigilante:vigilantes(nome_completo)')
              .in('escolta_veiculo_id', viatIdsPres)
              .then(({ data }: any) =>
                (data ?? []).map((e: any) =>
                  `${e.vigilante?.nome_completo ?? '—'}${e.papel_na_escolta ? ` (${e.papel_na_escolta})` : ''}`
                )
              )
          : []

        fetch('/api/telegram', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tipo: 'presenca',
            titulo: 'Presença Confirmada',
            descricao: `${data.vigilante?.nome_completo ?? 'Vigilante'} confirmou presença na escolta`,
            escolta_id: data.escolta?.id,
            escolta_codigo: data.escolta?.codigo_escolta,
            cliente: data.escolta?.cliente?.nome_cliente,
            status_atual: data.escolta?.status,
            efetivos,
            foto_url: fotoUrl,
            data_hora: new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' }),
          }),
        }).catch(() => {})
      }
    )

    channel.subscribe()
    return () => { sb.removeChannel(channel) }
  }, [])

  return null
}
