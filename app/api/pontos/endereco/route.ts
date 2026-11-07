import { NextRequest, NextResponse } from 'next/server'
import { exigirSessao, dentroDoLimite } from '@/lib/api-auth'
import { createClient } from '@/lib/supabase/server'
import { enderecoPorExtenso } from '@/lib/geocodificacao'
import { lerObservacao } from '@/lib/pontos-controle'

/**
 * Onda M (B2): endereço por extenso depois do envio.
 *
 * Ponto que chegou ao banco só com a coordenada (registro feito sem internet, ou check-in
 * do Campo sem resposta da Mapbox, docs/12 item 0.7) recebe o endereço uma única vez,
 * aqui, pelo servidor. O aparelho chama esta rota quando termina de enviar a fila, com as
 * escoltas dos registros aplicados.
 *
 * - Sessão obrigatória e limite por usuário (6 chamadas por minuto, até 20 pontos cada).
 * - Os pontos são lidos com a RLS de quem chama: ninguém enxerga ponto alheio por aqui.
 * - A gravação é pela preencher_endereco_ponto (220), que só grava quando o endereço está
 *   vazio e só para o autor do ponto ou a gestão.
 * - A coordenada do GPS continua sendo a verdade; o texto é rótulo ("endereço aproximado").
 */
const LIMITE_POR_MINUTO = 6
const MAX_ESCOLTAS = 10
const MAX_PONTOS = 20
const JANELA_HORAS = 48
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export async function POST(req: NextRequest) {
  const auth = await exigirSessao()
  if (!auth.ok) return NextResponse.json({ error: auth.erro }, { status: auth.status })
  if (!dentroDoLimite('endereco:' + auth.sessao.usuarioId, LIMITE_POR_MINUTO, 60_000)) {
    return NextResponse.json({ error: 'Muitas solicitações. Aguarde um minuto.' }, { status: 429 })
  }

  let escoltas: string[] = []
  try {
    const corpo = await req.json()
    escoltas = Array.isArray(corpo?.escoltas) ? corpo.escoltas : []
  } catch {
    return NextResponse.json({ error: 'Pedido inválido.' }, { status: 400 })
  }
  escoltas = Array.from(new Set(escoltas.filter((e) => typeof e === 'string' && UUID.test(e)))).slice(0, MAX_ESCOLTAS)
  if (escoltas.length === 0) return NextResponse.json({ preenchidos: 0, pendentes: 0 })

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const sb = createClient() as any
  const desde = new Date(Date.now() - JANELA_HORAS * 3600_000).toISOString()
  const { data, error } = await sb
    .from('pontos_controle')
    .select('id, latitude, longitude, observacoes, escolta_veiculos!inner(escolta_id)')
    .in('escolta_veiculos.escolta_id', escoltas)
    .is('anulado_em', null)
    .not('latitude', 'is', null)
    .not('longitude', 'is', null)
    .gte('criado_em', desde)
    .order('criado_em', { ascending: true })
    .limit(200)
  if (error) return NextResponse.json({ error: 'Não foi possível ler os pontos.' }, { status: 502 })

  const semEndereco = ((data ?? []) as Array<{ id: string; latitude: number; longitude: number; observacoes: string | null }>)
    .filter((p) => !lerObservacao(p.observacoes).endereco)
  const lote = semEndereco.slice(0, MAX_PONTOS)

  let preenchidos = 0
  for (const p of lote) {
    const texto = await enderecoPorExtenso(Number(p.latitude), Number(p.longitude))
    if (!texto) continue
    const r = await sb.rpc('preencher_endereco_ponto', { p_ponto_id: p.id, p_endereco: texto })
    // Função ausente (bloco 1 sem a 220): para sem erro; o ponto fica só com a coordenada.
    if (r.error) break
    if (r.data === true) preenchidos++
  }
  return NextResponse.json({ preenchidos, pendentes: semEndereco.length - preenchidos })
}
