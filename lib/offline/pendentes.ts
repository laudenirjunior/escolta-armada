/**
 * Sobreposição dos registros guardados no aparelho sobre o que a tela leu (Lote 2026-10,
 * onda L; docs/14, seção 16.3.4). Usada no carregar do Campo e no loadData do detalhe:
 * status otimista igual ao destino da última etapa pendente e pontos pendentes somados aos
 * lidos, com a marca "pendente", para a Próxima Ação e as pendências não pedirem de novo o
 * que já foi registrado sem sinal.
 */
import { pendentesDoUsuario, type RegistroFila } from './fila.ts'

type Linha = Record<string, unknown>

export interface PontoPendente extends Linha {
  id: string
  escolta_veiculo_id: string
  tipo_ponto_id: string
  data_hora: string
  pendente: true
  client_id: string
}

export interface EscoltaSobreposta {
  status_otimista?: boolean
  registros_pendentes?: number
}

export interface OpcoesSobreposicao {
  /** Viaturas (escolta_veiculo_id) de cada escolta, para o comboio: a etapa só avança, como no servidor, quando todas registraram. */
  viaturasPorEscolta?: Record<string, string[]>
}

function lista(v: unknown): Linha[] { return Array.isArray(v) ? (v as Linha[]) : [] }

/** Pontos de um registro (linhas.pontos_controle e etapa.pontos), marcados como pendentes. */
export function pontosDoRegistro(r: RegistroFila): PontoPendente[] {
  const p = r.payload as { linhas?: { pontos_controle?: unknown }; etapa?: { pontos?: unknown } }
  return [...lista(p.linhas?.pontos_controle), ...lista(p.etapa?.pontos)].map(x => ({
    ...x,
    id: String(x.id ?? r.client_id),
    escolta_veiculo_id: String(x.escolta_veiculo_id ?? ''),
    tipo_ponto_id: String(x.tipo_ponto_id ?? ''),
    data_hora: String(x.data_hora ?? r.data_hora_acao),
    pendente: true as const,
    client_id: r.client_id,
  }))
}

/**
 * Aplica os pendentes (estado pendente ou enviando), na ordem de registro, às escoltas e
 * aos pontos lidos. Não muda nada fora da memória da tela.
 */
export function aplicarPendentes<E extends { id: string; status: string }, P extends Linha>(
  escoltas: E[],
  pontos: P[],
  pendentes: RegistroFila[],
  opcoes: OpcoesSobreposicao = {},
): { escoltas: Array<E & EscoltaSobreposta>; pontos: Array<P | PontoPendente> } {
  const ativos = pendentes
    .filter(r => r.estado === 'pendente' || r.estado === 'enviando')
    .sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0))
  const pontosSaida: Array<P | PontoPendente> = [...pontos]
  const idsLidos = new Set(pontos.map(p => String(p.id ?? '')))
  const porEscolta = new Map<string, RegistroFila[]>()
  for (const r of ativos) porEscolta.set(r.escolta_id, [...(porEscolta.get(r.escolta_id) ?? []), r])

  const escoltasSaida = escoltas.map(e => {
    const regs = porEscolta.get(e.id)
    if (!regs?.length) return e as E & EscoltaSobreposta
    let status = e.status
    let otimista = false
    for (const r of regs) {
      for (const pt of pontosDoRegistro(r)) {
        if (!idsLidos.has(pt.id)) { pontosSaida.push(pt); idsLidos.add(pt.id) }
      }
      const etapa = (r.payload as { etapa?: { status_atual?: string; status_novo?: string; tipo_ponto_todas?: string } }).etapa
      if (r.tipo !== 'etapa' || !etapa?.status_novo) continue
      if (etapa.status_atual && etapa.status_atual !== status) continue   // no servidor vira conflito
      const viaturas = opcoes.viaturasPorEscolta?.[e.id]
      if (etapa.tipo_ponto_todas && viaturas?.length) {
        const todas = viaturas.every(v => pontosSaida.some(p =>
          String(p.escolta_veiculo_id) === v && String(p.tipo_ponto_id) === etapa.tipo_ponto_todas && !(p as Linha).anulado_em))
        if (!todas) continue
      }
      status = etapa.status_novo
      otimista = true
    }
    return { ...e, status, status_otimista: otimista || undefined, registros_pendentes: regs.length }
  })
  return { escoltas: escoltasSaida, pontos: pontosSaida }
}

/** Pendentes do usuário (para passar a aplicarPendentes); vazio se a fila não abrir. */
export async function lerPendentes(authUserId: string): Promise<RegistroFila[]> {
  try { return await pendentesDoUsuario(authUserId) } catch { return [] }
}
