/**
 * Textos padrao das caixas de observacao.
 *
 * Pecanha pediu que cada campo de texto abrisse ja preenchido com uma frase curta
 * adequada aquela atividade, alteravel pelo operador. Isso vale para os campos de
 * rotina, e a distincao importa mais do que parece.
 *
 * DUAS FAMILIAS, POR UM MOTIVO DE SEGURANCA OPERACIONAL
 *
 * 1. TEXTO_PADRAO_* entra como VALOR INICIAL. Sao campos de rotina, sem validacao
 *    por tras, cujo conteudo esperado e mesmo "sem alteracoes". Pre-preencher poupa
 *    digitacao na estrada e nao esconde nada.
 *
 * 2. PLACEHOLDER entra como DICA, nunca como valor. Sao os campos cuja unica barreira
 *    e `if (!campo.trim())`. Por um texto de fabrica no valor deles anularia essa
 *    validacao e liberaria a jornada inteira sem uma linha digitada: o wizard de
 *    pre-inicio, a parada, o cancelamento, o reagendamento e o relatorio final
 *    passariam a ser confirmaveis no automatico. Ali o texto orienta, nao preenche.
 *
 * 3. CAMPOS_SEM_TEXTO_PADRAO sao os que nao recebem nem sugestao no valor, porque
 *    existem justamente para registrar o que fugiu do previsto. Ocorrencia,
 *    emergencia, cancelamento e item de checklist nao conforme. Um texto pronto ali
 *    facilita registro falso exatamente onde o registro precisa ser verdadeiro.
 *
 * As duas telas, detalhe e campo, leem daqui. A frase nunca e escrita duas vezes.
 */

import { STATUS } from './fluxo-escolta'

/**
 * Texto por status de DESTINO da transicao, para o campo de observacao do avanco.
 * Chaveado pelo status que a escolta vai atingir, nao pelo atual.
 */
export const TEXTO_PADRAO_ETAPA: Record<string, string> = {
  [STATUS.EM_PRE_INICIO]: 'Pré-início iniciado. Efetivo, viatura e armamento em conferência.',
  [STATUS.EM_ANDAMENTO]: 'Escolta iniciada. Saída da base sem alterações.',
  [STATUS.NA_ORIGEM]: 'Chegada na origem sem alterações.',
  [STATUS.EM_TRANSITO_DESTINO]: 'Trânsito ao destino iniciado, sem alterações.',
  [STATUS.NO_DESTINO]: 'Chegada no destino sem alterações.',
  [STATUS.EM_TRANSITO_RETORNO]: 'Trânsito de retorno iniciado, sem alterações.',
  [STATUS.RETORNANDO]: 'Retorno em curso, sem alterações.',
  [STATUS.NA_BASE]: 'Chegada na base sem alterações.',
  [STATUS.FINALIZADA]: 'Escolta finalizada sem intercorrências.',
}

/**
 * Texto por dialogo dedicado da jornada. Mais especifico que o de etapa, porque cada
 * dialogo pede a confirmacao de coisas diferentes.
 */
export const TEXTO_PADRAO_PONTO = {
  startBase: 'Saída da base sem alterações. Efetivo, viatura e armamento conferidos.',
  origem: 'Chegada na origem sem alterações. Cliente e carga conferidos, local seguro.',
  transitoDestino: 'Início do trânsito ao destino sem alterações. Carga conferida e rota confirmada.',
  destino: 'Chegada no destino sem alterações. Entrega conferida.',
  transitoRetorno: 'Início do trânsito de retorno sem alterações. Nenhuma ocorrência no destino.',
  retorno: 'Retorno em curso sem alterações. Rota de regresso normal.',
  chegadaBase: 'Chegada na base sem alterações. Viatura recolhida e armamento devolvido.',
  checkin: 'Check-in de rotina. Equipe em deslocamento normal, sem alterações.',
} as const

/**
 * Sugestao por tipo de parada, oferecida por clique e NUNCA como valor inicial.
 * O campo de parada tem validacao propria (`if (!obsParada.trim())`), entao preencher
 * o valor derrubaria a unica barreira que existe ali.
 *
 * Quatro tipos ficam de fora de proposito: manutencao, ocorrencia, bloqueio e
 * fiscalizacao sao eventos de desvio, com valor probatorio, e exigem relato real.
 */
export const SUGESTAO_PARADA: Record<string, string> = {
  reporte_periodico: 'Reporte periódico de posição. Equipe em rota, sem alterações.',
  registro_parada: 'Parada de rotina, sem alterações.',
  em_transito: 'Deslocamento normal, sem alterações.',
  parada_curta: 'Parada curta de rotina, sem alterações. Equipe permanece na viatura.',
  solicitacao: 'Parada solicitada pelo cliente ou escoltado, sem alterações de segurança.',
  ligacao: 'Contato telefônico com a central. Sem alterações.',
  abastecimento: 'Parada para abastecimento em posto sinalizado, sem alterações.',
  refeicao: 'Parada para refeição e descanso do efetivo, sem alterações.',
  inspecao: 'Inspeção visual da carga realizada. Lacres íntegros, sem alterações.',
  aguardando: 'Aguardando autorização para prosseguir. Sem alterações.',
}

/**
 * Dica de preenchimento. Entra em `placeholder`, jamais em `value`.
 * Cada um destes campos tem validacao de texto obrigatorio por tras.
 */
export const PLACEHOLDER = {
  obsMateriais:
    'Descreva a conferência de materiais e equipamentos: coletes, rádios, lanternas. Registre qualquer não conformidade.',
  obsViatura:
    'Descreva o estado do veículo, documentação, equipamentos obrigatórios e as não conformidades encontradas.',
  obsPartida:
    'Rota principal e alternativa, condições de clima e tráfego, e o que mais for relevante para a saída.',
  obsParada: 'Motivo real da parada, local, duração prevista e providência tomada.',
  motivoCancelamento: 'Motivo do cancelamento: o que aconteceu, quem determinou e quando.',
  motivoReagendamento: 'Motivo do reagendamento e quem autorizou a nova data.',
  descOcorrencia: 'Descreva o que aconteceu com o máximo de detalhes: o quê, quando, onde, quem estava envolvido e qual providência foi tomada.',
  itemNaoConforme: 'Descreva a não conformidade encontrada.',
} as const

/**
 * Campos que nao recebem texto padrao nem sugestao no valor, em nenhuma hipotese.
 * Lista explicita para que a proxima pessoa que generalizar o pre-preenchimento
 * saiba o que precisa ficar de fora, e por que.
 */
export const CAMPOS_SEM_TEXTO_PADRAO = [
  'app/dashboard/campo/page.tsx: descricao da ocorrencia',
  'app/dashboard/campo/page.tsx: observacao de item de checklist nao conforme',
  'app/dashboard/escoltas/[id]/page.tsx: observacao de item nao conforme do checklist de entrega',
  'app/dashboard/escoltas/[id]/page.tsx: obsMateriais do wizard de pre-inicio',
  'app/dashboard/escoltas/[id]/page.tsx: obsViatura do wizard de pre-inicio',
  'app/dashboard/escoltas/[id]/page.tsx: obsPartida do wizard de pre-inicio',
  'app/dashboard/escoltas/[id]/page.tsx: motivo de cancelamento',
  'app/dashboard/escoltas/[id]/page.tsx: motivo de reagendamento',
  'app/dashboard/escoltas/[id]/page.tsx: observacao da parada',
  'app/dashboard/escoltas/[id]/page.tsx: relatorio final da escolta',
  'emergencia: o acionamento nao tem campo de texto, e um toque; o relato pertence ao encerramento pela central',
] as const

/**
 * Modelo do relatorio final, por decisao de Pecanha em 2026-08-19.
 *
 * Vem preenchido e editavel. Diferente dos outros textos padrao, este monta as linhas
 * com os dados reais da escolta: um relatorio que so diz "sem alteracao" nao serve como
 * documento para o cliente, enquanto um que ja traz trajeto, horarios e equipe da ao
 * supervisor uma base para completar em vez de uma folha em branco.
 *
 * Consequencia assumida: o campo tinha `if (!relatorioFinal.trim())` como unica barreira,
 * e vir preenchido faz essa barreira deixar de recusar qualquer coisa. A escolha e de
 * Pecanha, pela agilidade de fechar a escolta em campo.
 */
export function modeloRelatorioFinal(dados: {
  codigo?: string | null
  cliente?: string | null
  origem?: string | null
  destino?: string | null
  inicio?: string | null
  fim?: string | null
  equipe?: string[]
  viaturas?: string[]
  ocorrencias?: number
  paradas?: number
}): string {
  const hora = (v?: string | null) =>
    v ? new Date(v).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' }) : 'não registrado'

  const linhas = [
    `RELATÓRIO FINAL${dados.codigo ? ` - ${dados.codigo}` : ''}`,
    '',
    `Cliente: ${dados.cliente || 'não informado'}`,
    `Origem: ${dados.origem || 'não informada'}`,
    `Destino: ${dados.destino || 'não informado'}`,
    `Início: ${hora(dados.inicio)}`,
    `Término: ${hora(dados.fim)}`,
  ]

  if (dados.viaturas?.length) linhas.push(`Viatura(s): ${dados.viaturas.join(', ')}`)
  if (dados.equipe?.length) linhas.push(`Equipe: ${dados.equipe.join(', ')}`)

  linhas.push('')
  linhas.push(
    dados.ocorrencias
      ? `Ocorrências registradas: ${dados.ocorrencias}. Descrever abaixo o desfecho de cada uma.`
      : 'Escolta realizada sem alterações. Nenhuma ocorrência registrada.'
  )
  if (dados.paradas) linhas.push(`Paradas no trajeto: ${dados.paradas}.`)
  linhas.push('Carga entregue no destino e viatura recolhida à base sem intercorrências.')

  return linhas.join('\n')
}

/**
 * Verdadeiro quando o texto e exatamente o padrao daquela etapa, ou seja, o operador
 * nao escreveu nada de proprio.
 *
 * Serve para a notificacao do Telegram: o banco guarda o registro completo, mas a
 * mensagem so destaca a observacao quando ela foge da rotina. Sem isto, toda etapa
 * mandaria "sem alteracoes" para o cliente e a notificacao viraria ruido.
 */
export function ehTextoPadrao(texto: string | null | undefined, padrao: string | undefined): boolean {
  if (!texto || !padrao) return false
  return texto.trim() === padrao.trim()
}

/**
 * Junta as partes de uma observacao descartando as vazias.
 *
 * Existe porque as montagens antigas concatenavam com `'Obs: ' + texto` e, com o
 * texto vazio, gravavam a string `Obs: ` orfa no banco. O separador nunca pode ser
 * `{` nem `[` no inicio, senao muda o ramo de parseObservacao da tela de notificacoes.
 */
export function comporObservacao(...partes: (string | null | undefined)[]): string | null {
  const limpas = partes.map((p) => (p ?? '').trim()).filter(Boolean)
  return limpas.length ? limpas.join(' · ') : null
}
