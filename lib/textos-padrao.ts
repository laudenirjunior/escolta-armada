/**
 * Textos padrao das caixas de observacao.
 *
 * Pecanha pediu que cada campo de texto abrisse ja preenchido com uma frase curta
 * adequada aquela atividade, alteravel pelo operador. Isso vale para os campos de
 * rotina, e a distincao importa mais do que parece.
 *
 * TRES FAMILIAS, POR UM MOTIVO DE SEGURANCA OPERACIONAL
 *
 * 1. TEXTO_PADRAO_* entra como VALOR INICIAL. Sao campos de rotina, sem validacao
 *    por tras, cujo conteudo esperado e mesmo "sem alteracoes". Pre-preencher poupa
 *    digitacao na estrada e nao esconde nada.
 *
 * 2. SUGESTOES entram apenas depois de um toque do operador e continuam editaveis.
 *    Sao atalhos para campos obrigatorios, nunca valor inicial. O componente de
 *    sugestoes nao confirma nem libera o campo sozinho.
 *
 * 3. CATEGORIAS orientam ocorrencia e emergencia sem criar relato. O que aconteceu
 *    continua sendo escrito por quem presenciou o fato.
 *
 * PLACEHOLDER e apenas dica visual, nunca valor. Os campos obrigatorios (wizard de
 * pre-inicio, parada, cancelamento, reagendamento e relatorio final) tem como unica
 * barreira `if (!campo.trim())`: um texto de fabrica no valor deles anularia essa
 * validacao e liberaria a jornada sem uma linha digitada. Por isso as SUGESTOES so
 * entram por toque (onda M, D9), e a categoria da ocorrencia nao conta como relato
 * (relatoAlemDaCategoria). CAMPOS_SEM_TEXTO_PADRAO registra as excecoes que nunca
 * recebem valor automatico. As duas telas, detalhe e campo, leem daqui; a frase nunca
 * e escrita duas vezes. A excecao conhecida e TEXTO_PADRAO_MATERIAIS (pedido de
 * Pecanha em 10/09, custo explicado abaixo).
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
  reporte_periodico: 'Check-in de posição. Equipe em rota, sem alterações.',
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

/** Sugestões de um toque para os três passos do pré-início. */
export const SUGESTOES_WIZARD = {
  materiais: [
    'Materiais e equipamentos conferidos, sem alterações.',
    'Materiais conferidos. A não conformidade encontrada está descrita no campo.',
  ],
  viatura: [
    'Viatura conferida, sem avarias aparentes e com documentação regular.',
    'Viatura conferida. A avaria ou pendência encontrada está descrita no campo.',
  ],
  partida: [
    'Rota principal e alternativa conferidas. Condições favoráveis para a saída.',
    'Rota conferida. A condição de tráfego ou segurança relevante está descrita no campo.',
  ],
} as const

/** Sugestões gerais para parada quando o tipo escolhido não possui frase própria. */
export const SUGESTOES_PARADA = [
  'Parada iniciada no local informado. Equipe e carga permanecem seguras.',
  'Parada concluída sem alterações. Deslocamento retomado.',
  'Parada solicitada pelo cliente. Motivo e autorização registrados no campo.',
] as const

export const SUGESTOES_CANCELAMENTO = [
  'Cancelamento determinado pelo cliente. Motivo e horário registrados no campo.',
  'Cancelamento determinado pela central. Motivo e horário registrados no campo.',
  'Cancelamento por condição de segurança. Situação e responsável registrados no campo.',
] as const

export const SUGESTOES_REAGENDAMENTO = [
  'Reagendamento solicitado pelo cliente. Nova data e autorização registradas no campo.',
  'Reagendamento determinado pela central. Nova data e motivo registrados no campo.',
  'Reagendamento por indisponibilidade operacional. Motivo registrado no campo.',
] as const

/** Trechos opcionais, nunca um relatório completo nem valor inicial. */
export const SUGESTOES_RELATORIO_FINAL = [
  'Carga entregue sem ressalvas no destino informado.',
  'Equipe retornou à base sem intercorrências após a entrega.',
  'As ocorrências e providências adotadas estão detalhadas no histórico da escolta.',
] as const

/** Categorias ajudam a classificar; não descrevem o fato ocorrido. */
export const CATEGORIAS_OCORRENCIA = [
  'Acidente de trânsito',
  'Ameaça ou tentativa de abordagem',
  'Avaria ou violação da carga',
  'Desvio ou bloqueio de rota',
  'Falha mecânica',
  'Fiscalização ou documentação',
  'Outra ocorrência',
] as const

/** Emergência recebe só categoria. O acionamento nunca ganha relato automático. */
export const CATEGORIAS_EMERGENCIA = [
  'Risco imediato à equipe',
  'Tentativa de roubo ou abordagem',
  'Acidente com vítima',
  'Pane em local inseguro',
  'Perda de contato com a central',
  'Outra emergência',
] as const

/**
 * Texto modelo do checklist de materiais do wizard de pre-inicio.
 *
 * MUDANCA DE DECISAO, 10/09/2026, a pedido de Pecanha.
 *
 * Este campo estava na familia 2, so com PLACEHOLDER, e listado em
 * CAMPOS_SEM_TEXTO_PADRAO. Pecanha pediu que abrisse preenchido com um texto modelo,
 * pela mesma razao que levou o relatorio final a vir pronto: agilidade de quem esta
 * na base prestes a sair.
 *
 * CUSTO ASSUMIDO, e ele e real: a unica barreira do campo era `if (!obsMateriais.trim())`.
 * Com valor de fabrica, essa barreira deixa de recusar qualquer coisa, e o Passo 1 do
 * wizard passa a ser confirmavel sem uma linha digitada. O que continua barrando a
 * saida sem conferencia e a foto obrigatoria dos materiais, que nao tem texto de fabrica
 * possivel. Quem trocar isso de novo precisa saber que a foto virou a unica prova.
 *
 * O PLACEHOLDER.obsMateriais continua existindo, para quando o operador limpar o campo.
 */
export const TEXTO_PADRAO_MATERIAIS =
  'Materiais e equipamentos conferidos, sem alterações. Coletes, rádios, lanternas, armamento, munição e equipamentos de suporte em conformidade e operacionais.'

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
  // obsMateriais saiu desta lista em 10/09/2026. Ver TEXTO_PADRAO_MATERIAIS.
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

/**
 * Onda M (D9): junta a frase da sugestão ao que já foi escrito. Campo vazio recebe a frase;
 * com texto, a frase entra no fim, separada por espaço. Nunca apaga o que o operador digitou.
 */
export function juntarSugestao(atual: string, frase: string): string {
  const a = atual.trim()
  return a ? `${a} ${frase}` : frase
}

/**
 * Categoria da ocorrência (D9): entra como prefixo "Categoria: X. " e é trocada, não somada,
 * se outra for escolhida. A categoria sozinha não conta como relato: o botão de registrar
 * confere relatoAlemDaCategoria, que precisa ter texto escrito por quem viu o fato.
 */
const PREFIXO_CATEGORIA = /^\s*Categoria: [^.\n]*\.\s*/

export function comCategoria(atual: string, categoria: string): string {
  return `Categoria: ${categoria}. ${atual.replace(PREFIXO_CATEGORIA, '')}`
}

export function relatoAlemDaCategoria(texto: string): string {
  return texto.replace(PREFIXO_CATEGORIA, '').trim()
}

/**
 * Revisão cruzada da onda M (achado grave 2.1): a sugestão não pode liberar sozinha um campo
 * obrigatório quando ela própria pede o fato ("... registrados no campo", "... descrita no
 * campo") ou quando é só um trecho do relatório final. Tira do texto todas as frases da lista
 * e devolve o que sobrou, escrito por quem registra. Frases completas (por exemplo, "Viatura
 * conferida, sem avarias aparentes...") continuam valendo sozinhas, como antes da onda M.
 */
export function faltaComplementoDaSugestao(texto: string, sugestoes: readonly string[], sempre = false): boolean {
  let resto = texto
  let pedeFato = sempre
  for (const frase of sugestoes) {
    if (!frase || !resto.includes(frase)) continue
    if (/no campo\.?$/.test(frase)) pedeFato = true
    resto = resto.split(frase).join(' ')
  }
  return pedeFato && resto.replace(/[\s.,;:-]+/g, '').length < 3
}

export const MENSAGEM_COMPLETAR_SUGESTAO =
  'Complete a sugestão com o que aconteceu (motivo, horário, responsável ou o detalhe pedido). A frase sozinha não basta.'
