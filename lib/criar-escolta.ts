/**
 * Criação de escolta (pedido de Peçanha em 2026-11-13, migration 224).
 *
 * Antes, a tela gravava escolta, viaturas e equipe com três INSERTs separados direto do
 * navegador e trocava o erro do banco por "Erro ao criar a escolta.". O erro real era o código
 * ESC-AAAA-NNNN repetido: a trigger calculava o maior código VISÍVEL + 1, e a escolta excluída
 * (221) some da RLS mas continua no banco.
 *
 * Agora: uma chamada à RPC criar_escolta (tudo ou nada, numa transação), nova tentativa
 * automática se o código colidir e a mensagem real do banco na tela.
 * Rodar os testes: node --test tests/criar-escolta.test.ts
 */

export interface ErroBanco {
  code?: string | null
  message?: string | null
  details?: string | null
  hint?: string | null
}

export interface ClienteRpc {
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: ErroBanco | null }>
}

export type ResultadoCriacao =
  | { ok: true; id: string; codigo: string | null; tentativas: number }
  | { ok: false; ausente: true }

/** Função ausente no PostgREST (PGRST202) ou no banco (42883): migration 224 ainda não aplicada. */
export function funcaoAusente(erro: ErroBanco | null | undefined): boolean {
  return !!erro?.code && ['PGRST202', '42883'].includes(erro.code)
}

/** Colisão do código da escolta (restrição única escoltas_codigo_escolta_key). */
export function ehColisaoCodigo(erro: ErroBanco | null | undefined): boolean {
  if (!erro || erro.code !== '23505') return false
  const texto = `${erro.message ?? ''} ${erro.details ?? ''}`
  return /codigo_escolta/.test(texto)
}

/**
 * Mensagem para a tela: o texto real do banco, com uma explicação curta antes quando o código
 * técnico é conhecido. Mensagem das RPCs (RAISE EXCEPTION, P0001) já é escrita para o usuário e
 * vai como está. Nunca devolve só "Erro ao criar a escolta.".
 */
export function mensagemErroBanco(erro: ErroBanco | Error | null | undefined, acao = 'salvar a escolta'): string {
  if (!erro) return `Não foi possível ${acao}: o servidor não respondeu.`
  if (erro instanceof Error) return erro.message || `Não foi possível ${acao}.`
  const real = [erro.message, erro.details, erro.hint].filter(t => !!t && String(t).trim()).join(' ')
  const codigo = erro.code ? ` [${erro.code}]` : ''
  const detalhe = real ? ` Detalhe: ${real}${codigo}` : codigo
  if (/failed to fetch|networkerror|load failed|network request failed/i.test(erro.message ?? '')) {
    return `Sem conexão com o servidor: não foi possível ${acao}. Confira a internet e tente de novo.${detalhe}`
  }
  if (ehColisaoCodigo(erro)) {
    return `O número da escolta já estava em uso e as novas tentativas também colidiram. Nada foi gravado; tente salvar de novo.${detalhe}`
  }
  switch (erro.code) {
    case 'P0001': return real || `Não foi possível ${acao}.`
    case '42501': return `Sem permissão para ${acao} com o seu perfil.${detalhe}`
    case '23503': return `Um cadastro escolhido (cliente, veículo ou vigilante) não existe mais. Atualize a página e escolha de novo.${detalhe}`
    case '23505': return `Registro repetido: ${real || 'o banco recusou um dado duplicado'}${codigo}`
    case '23502': return `Falta um campo obrigatório.${detalhe}`
    case '22P02':
    case '22007':
    case '22008': return `Valor inválido em um dos campos.${detalhe}`
    default: return real ? `Não foi possível ${acao}: ${real}${codigo}` : `Não foi possível ${acao}.${codigo}`
  }
}

/** Campos e viaturas, no formato da RPC criar_escolta (migration 224). */
export interface MembroCriacao { vigilante_id: string; papel_na_escolta: string; valor_pago_vigilante?: number | null }
export interface ViaturaCriacao { veiculo_id: string; membros: MembroCriacao[] }

/**
 * Chama criar_escolta e tenta de novo, até `maxTentativas` vezes no total, se o código colidir
 * (a RPC já tenta 5 vezes dentro da transação; esta é a segunda camada, para o caso raro de a
 * colisão escapar). Outro erro sai na hora, com a mensagem real.
 * Função ausente: devolve { ok: false, ausente: true } para a tela usar o caminho antigo.
 */
export async function criarEscolta(
  sb: ClienteRpc,
  campos: Record<string, unknown>,
  viaturas: ViaturaCriacao[],
  maxTentativas = 3,
): Promise<ResultadoCriacao> {
  let ultimo: ErroBanco | null = null
  for (let tentativa = 1; tentativa <= maxTentativas; tentativa++) {
    const { data, error } = await sb.rpc('criar_escolta', { p_campos: campos, p_viaturas: viaturas })
    if (!error) {
      const r = (data ?? {}) as { id?: string; codigo_escolta?: string | null }
      if (!r.id) throw new Error('O servidor não devolveu a escolta criada. Confira a lista de escoltas antes de tentar de novo.')
      return { ok: true, id: r.id, codigo: r.codigo_escolta ?? null, tentativas: tentativa }
    }
    if (funcaoAusente(error)) return { ok: false, ausente: true }
    ultimo = error
    if (!ehColisaoCodigo(error)) break
  }
  throw new Error(mensagemErroBanco(ultimo, 'criar a escolta'))
}

/**
 * Trava contra o duplo clique: o estado do React (salvando) só muda no próximo render, então
 * dois cliques no mesmo instante passavam os dois. A trava é síncrona.
 */
export function criarTrava() {
  let ocupada = false
  return {
    tentar(): boolean { if (ocupada) return false; ocupada = true; return true },
    soltar(): void { ocupada = false },
    get ocupada() { return ocupada },
  }
}

/** Data e hora de partida (campos do formulário) em ISO; null se a combinação for inválida. */
export function dataHoraPrevistaISO(data: string, h: string, m: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(data) || !/^\d{1,2}$/.test(h) || !/^\d{1,2}$/.test(m)) return null
  const d = new Date(`${data}T${h.padStart(2, '0')}:${m.padStart(2, '0')}:00`)
  return isNaN(d.getTime()) ? null : d.toISOString()
}
