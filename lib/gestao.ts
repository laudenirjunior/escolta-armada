/**
 * Lote 2026-10, onda I: utilitários das ações da gestão (voltar etapa, zerar, concluir com
 * pendências, arquivar) e da marcação de registros anulados. A regra está no banco
 * (migrations 213, 214 e 218); aqui só o que as telas mostram.
 */

/** Função ausente no PostgREST (PGRST202) ou no banco (42883): bloco 2 ainda não aplicado. */
export const FUNCAO_AUSENTE = ['PGRST202', '42883']

export const MSG_ATUALIZACAO = 'Atualização em andamento: esta ação fica disponível em alguns minutos. Tente de novo mais tarde.'

export function ehFuncaoAusente(erro: { code?: string } | null | undefined): boolean {
  return !!erro?.code && FUNCAO_AUSENTE.includes(erro.code)
}

/** DD/MM/AAAA HH:MM no horário de Brasília. */
export function horaBR(iso: string | null | undefined): string {
  if (!iso) return ''
  return new Date(iso).toLocaleString('pt-BR', {
    timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
  }).replace(',', '')
}

/** Registro anulado, como as telas o mostram (riscado, com este texto ao lado). */
export interface Anulacao { anulado_em?: string | null; motivo_anulacao?: string | null; anulador?: { nome_completo?: string | null } | null }

export function textoAnulado(r: Anulacao | null | undefined): string | null {
  if (!r?.anulado_em) return null
  const quem = r.anulador?.nome_completo ? ` por ${r.anulador.nome_completo}` : ''
  return `Anulado em ${horaBR(r.anulado_em)} (Brasília)${quem}: ${r.motivo_anulacao ?? 'sem motivo'}`
}

/** Colunas de anulação para os selects das tabelas de campo (mesma consulta, coluna a mais). */
export const COLUNAS_ANULACAO = 'anulado_em, motivo_anulacao, anulador:usuarios!anulado_por(nome_completo)'

/** Pendências de uma conclusão antecipada (calculadas no servidor, lote_interno.pendencias). */
export interface PendenciaViatura { escolta_veiculo_id: string; placa: string; faltando: string[] }
export interface PendenciaEtapa { etapa: string; rotulo: string; viaturas: PendenciaViatura[] }

export interface ConclusaoAntecipada {
  id: string
  status_no_momento: string
  motivo: string
  concluida_em: string
  pendencias: PendenciaEtapa[]
  autor?: { nome_completo?: string | null } | null
}

export function totalItensPendentes(p: PendenciaEtapa[] | null | undefined): number {
  return (p ?? []).reduce((s, e) => s + e.viaturas.reduce((t, v) => t + v.faltando.length, 0), 0)
}
