/**
 * Serializacao unica do campo `pontos_controle.observacoes`.
 *
 * A coluna e polimorfica por historico: ora guarda JSON, ora texto livre. Pior, as
 * chaves do JSON divergiam entre quem grava e quem le. Os pontos gravavam
 * `observacao` e a pagina de impressao procurava `justificativa`, entao o texto do
 * operador sumia do relatorio que vai para o cliente.
 *
 * Daqui em diante todo insert usa `serializarObservacao` e toda leitura usa
 * `lerObservacao`, que aceita as tres formas encontradas em producao:
 *   1. JSON no formato atual
 *   2. JSON legado com a chave `justificativa`
 *   3. texto puro, gravado antes de existir JSON
 *
 * Isso importa porque a coluna tambem carrega os `foto_ids`, que hoje sao a unica
 * pista de que um ponto tem mais de uma foto: `pontos_controle.foto_id` e escalar e
 * so aponta a primeira.
 */

export interface ObservacaoPonto {
  tipo: string | null
  tipoLabel: string | null
  observacao: string | null
  foto_ids: string[]
  /**
   * Endereco textual do reverse geocode do Mapbox, quando houve.
   *
   * Nao existe coluna para ele em pontos_controle: so latitude e longitude
   * sobrevivem fora deste JSON. app/dashboard/mapa/page.tsx usa esse texto para
   * rotular o ultimo ponto da escolta no mapa e no painel lateral, e sem ele o
   * rotulo fica vazio, porque recuperar o endereco exigiria nova chamada paga ao
   * Mapbox para cada ponto.
   */
  endereco: string | null
  /**
   * KM do hodometro informado junto com o ponto, so na saida da base e na chegada
   * na base.
   *
   * A coluna escolta_veiculos.quilometragem_* guarda so o ultimo valor, sem autor e
   * sem horario. Aqui o KM viaja com o ponto, que ja tem lancado_por, data_hora,
   * tipo (a etapa) e escolta_veiculo_id: e o registro de auditoria. Os relatorios
   * continuam lendo a coluna. Como pontos_controle nao tem UPDATE nem DELETE, um KM
   * corrigido depois muda so a coluna, e o ponto preserva o que foi informado.
   */
  km: number | null
}

/** Monta o JSON gravado na coluna. Chaves fixas, sempre as mesmas seis. */
export function serializarObservacao(dados: {
  tipo?: string | null
  tipoLabel?: string | null
  observacao?: string | null
  fotoIds?: string[] | null
  endereco?: string | null
  km?: number | null
}): string {
  const payload: ObservacaoPonto = {
    tipo: dados.tipo ?? null,
    tipoLabel: dados.tipoLabel ?? null,
    observacao: dados.observacao?.trim() || null,
    foto_ids: dados.fotoIds ?? [],
    endereco: dados.endereco?.trim() || null,
    km: typeof dados.km === 'number' && Number.isFinite(dados.km) ? dados.km : null,
  }
  return JSON.stringify(payload)
}

/**
 * Leitura tolerante. Nunca lanca: ponto legado com texto puro devolve o texto em
 * `observacao` e lista de fotos vazia, que e exatamente o que a tela deve mostrar.
 */
export function lerObservacao(bruto: string | null | undefined): ObservacaoPonto {
  const vazio: ObservacaoPonto = {
    tipo: null,
    tipoLabel: null,
    observacao: null,
    foto_ids: [],
    endereco: null,
    km: null,
  }
  const texto = (bruto ?? '').trim()
  if (!texto) return vazio

  // Texto puro legado: nao tenta parsear o que claramente nao e JSON.
  if (!texto.startsWith('{') && !texto.startsWith('[')) {
    return { ...vazio, observacao: texto }
  }

  try {
    const obj = JSON.parse(texto)
    if (!obj || typeof obj !== 'object') return { ...vazio, observacao: texto }
    return {
      tipo: obj.tipo ?? null,
      tipoLabel: obj.tipoLabel ?? null,
      // `justificativa` e a chave legada que a pagina de impressao procurava.
      observacao: obj.observacao ?? obj.justificativa ?? null,
      foto_ids: Array.isArray(obj.foto_ids) ? obj.foto_ids.filter(Boolean) : [],
      endereco: obj.endereco ?? null,
      km: typeof obj.km === 'number' ? obj.km : null,
    }
  } catch {
    // JSON malformado: preserva o texto em vez de descartar informacao operacional.
    return { ...vazio, observacao: texto }
  }
}

/** Todos os ids de foto de um ponto, comecando pelo escalar da coluna `foto_id`. */
export function fotoIdsDoPonto(ponto: {
  foto_id?: string | null
  observacoes?: string | null
}): string[] {
  const { foto_ids } = lerObservacao(ponto.observacoes)
  const ids = [...foto_ids]
  if (ponto.foto_id && !ids.includes(ponto.foto_id)) ids.unshift(ponto.foto_id)
  return ids
}
