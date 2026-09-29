/**
 * O que o Painel Operacional Guiado pede agora, para cada etapa da escolta.
 *
 * Nao e uma maquina de estados nova. A ordem das etapas vem de JORNADA_ETAPAS, a
 * transicao seguinte vem de PROXIMO_STATUS e o tipo de ponto de TIPO_PONTO_POR_STATUS,
 * todos em lib/fluxo-escolta.ts. Este arquivo so da nome, instrucao e lugar de
 * execucao ao que o fluxo ja define. O projeto ja teve quatro definicoes divergentes
 * do fluxo; esta nao pode virar a quinta.
 *
 * Nomes aprovados por Pecanha em 2026-09-29.
 */

import { JORNADA_ETAPAS, PROXIMO_STATUS, STATUS, TIPO_PONTO_POR_STATUS, indiceEtapa } from './fluxo-escolta'

/** Um nome por etapa de JORNADA_ETAPAS, na mesma ordem. */
const NOMES_ETAPA = [
  'Escolta Agendada',
  'Pré-início da Escolta',
  'Deslocamento para a Origem',
  'Na Origem',
  'Deslocamento para o Destino',
  'No Destino',
  'Saída do Destino',
  'Retorno à Base',
  'Chegada na Base',
] as const

if (NOMES_ETAPA.length !== JORNADA_ETAPAS.length) {
  // Falha cedo e alto: etapa nova no fluxo sem nome aqui deslocaria todos os rotulos.
  throw new Error('lib/proximo-passo-operador.ts: NOMES_ETAPA fora de sincronia com JORNADA_ETAPAS')
}

export const TOTAL_ETAPAS = JORNADA_ETAPAS.length

/** Rotulo do botao que REGISTRA a chegada a cada status. */
const ACAO_POR_DESTINO: Record<string, string> = {
  [STATUS.EM_PRE_INICIO]: 'Iniciar Pré-início da Escolta',
  [STATUS.EM_ANDAMENTO]: 'Registrar Saída da Base',
  [STATUS.NA_ORIGEM]: 'Registrar Chegada na Origem',
  [STATUS.EM_TRANSITO_DESTINO]: 'Registrar Saída para o Destino',
  [STATUS.NO_DESTINO]: 'Registrar Chegada no Destino',
  [STATUS.EM_TRANSITO_RETORNO]: 'Registrar Saída do Destino',
  [STATUS.RETORNANDO]: 'Registrar Retorno à Base',
  [STATUS.NA_BASE]: 'Registrar Chegada na Base',
  [STATUS.FINALIZADA]: 'Finalizar Escolta',
}

/** Frase curta do que fazer, na etapa atual. */
const INSTRUCAO_POR_STATUS: Record<string, string> = {
  [STATUS.RASCUNHO]: 'Esta escolta ainda está em planejamento. Aguarde a liberação.',
  [STATUS.AGENDADA]: 'Com a equipe na base, inicie o pré-início da escolta.',
  [STATUS.EM_PRE_INICIO]: 'Confira os equipamentos, registre as fotos da viatura e o KM inicial.',
  [STATUS.EM_ANDAMENTO]: 'Ao chegar na origem, tire a foto e registre a chegada.',
  [STATUS.NA_ORIGEM]: 'Ao sair para o destino, tire a foto e registre a saída.',
  [STATUS.EM_TRANSITO_DESTINO]: 'Ao chegar no destino, tire a foto e registre a chegada.',
  [STATUS.NO_DESTINO]: 'Ao deixar o destino, tire a foto e registre a saída.',
  [STATUS.EM_TRANSITO_RETORNO]: 'Com a equipe a caminho da base, tire a foto e registre o retorno.',
  [STATUS.RETORNANDO]: 'Ao chegar na base, registre a chegada, as fotos e o KM final.',
  [STATUS.NA_BASE]: 'Registre o checklist de entrega, as fotos da viatura e o relatório para finalizar.',
  [STATUS.FINALIZADA]: 'Esta escolta foi finalizada.',
  [STATUS.CANCELADA]: 'Esta escolta foi cancelada.',
}

/** Mensagem da tela de confirmacao, pelo status atingido. */
export const CONFIRMACAO_POR_DESTINO: Record<string, string> = {
  [STATUS.EM_ANDAMENTO]: 'Saída da Base registrada',
  [STATUS.NA_ORIGEM]: 'Chegada na Origem registrada',
  [STATUS.EM_TRANSITO_DESTINO]: 'Saída para o Destino registrada',
  [STATUS.NO_DESTINO]: 'Chegada no Destino registrada',
  [STATUS.EM_TRANSITO_RETORNO]: 'Saída do Destino registrada',
  [STATUS.RETORNANDO]: 'Retorno à Base registrado',
  [STATUS.NA_BASE]: 'Chegada na Base registrada',
  [STATUS.FINALIZADA]: 'Escolta finalizada',
}

/**
 * Onde cada registro acontece na primeira entrega (Caminho 1, aprovado em 29/09).
 *
 * `campo`: o proprio Painel Guiado grava, pelo mesmo avancarStatus da tela de Campo.
 * `detalhe`: o painel abre o dialogo que ja existe na tela de detalhe, que e o unico
 * escritor daquela etapa. Nenhuma gravacao nova e criada:
 *   - em_pre_inicio: o wizard de partida (equipamentos, 5 fotos, KM inicial);
 *   - em_andamento: sai pelo mesmo wizard, entao o painel manda para ele;
 *   - na_base: a chegada na base leva o KM final, que so o dialogo do detalhe grava;
 *   - finalizada: checklist de entrega, relatorio e fotos, so no detalhe.
 */
export type AcaoDetalhe = 'pre_inicio' | 'wizard' | 'chegada_base' | 'finalizar' | 'parada'

const DESTINO_NO_DETALHE: Record<string, AcaoDetalhe> = {
  [STATUS.EM_PRE_INICIO]: 'pre_inicio',
  [STATUS.EM_ANDAMENTO]: 'wizard',
  [STATUS.NA_BASE]: 'chegada_base',
  [STATUS.FINALIZADA]: 'finalizar',
}

export interface ProximaAcao {
  etapaNumero: number
  etapaNome: string
  instrucao: string
  /** Rotulo do botao principal, ou null quando nao ha acao a fazer. */
  botao: string | null
  onde: 'campo' | 'detalhe' | 'checkin' | 'nenhum'
  acaoDetalhe?: AcaoDetalhe
  statusDestino?: string
  /** Etapa que exige foto e ponto de controle. */
  exigeFoto: boolean
  urgente: boolean
}

export function nomeEtapa(status: string): string {
  const idx = indiceEtapa(status)
  if (status === STATUS.FINALIZADA) return 'Escolta Finalizada'
  if (status === STATUS.CANCELADA) return 'Escolta Cancelada'
  return idx >= 0 ? NOMES_ETAPA[idx] : status
}

export function numeroEtapa(status: string): number {
  return indiceEtapa(status) + 1
}

export function rotuloAcao(statusDestino: string): string {
  return ACAO_POR_DESTINO[statusDestino] ?? 'Registrar'
}

/**
 * A Proxima Acao da escolta. Check-in atrasado passa na frente de tudo, porque e a
 * unica pendencia com prazo vencido; o avanco de etapa volta a ser a acao seguinte.
 */
export function proximaAcao(status: string, opcoes: { minutosAteCheckin?: number | null } = {}): ProximaAcao {
  const base = {
    etapaNumero: numeroEtapa(status),
    etapaNome: nomeEtapa(status),
    exigeFoto: false,
    urgente: false,
  }

  const minutos = opcoes.minutosAteCheckin
  if (typeof minutos === 'number' && minutos <= 0) {
    return {
      ...base,
      instrucao: minutos === 0
        ? 'O check-in vence agora. Tire a foto e registre.'
        : `O check-in está atrasado há ${Math.abs(minutos)} min. Tire a foto e registre.`,
      botao: 'Registrar Check-in',
      onde: 'checkin',
      exigeFoto: true,
      urgente: true,
    }
  }

  const proximo = PROXIMO_STATUS[status]
  // em_pre_inicio e null na fonte unica porque atravessa pelo wizard.
  const destino = status === STATUS.EM_PRE_INICIO ? STATUS.EM_ANDAMENTO : proximo?.status ?? null
  const instrucao = INSTRUCAO_POR_STATUS[status] ?? ''

  if (!destino || status === STATUS.RASCUNHO) {
    return { ...base, instrucao, botao: null, onde: 'nenhum' }
  }

  const noDetalhe = status === STATUS.EM_PRE_INICIO ? 'wizard' : DESTINO_NO_DETALHE[destino]
  if (noDetalhe) {
    return {
      ...base,
      instrucao,
      botao: status === STATUS.EM_PRE_INICIO ? 'Abrir Pré-início da Escolta' : rotuloAcao(destino),
      onde: 'detalhe',
      acaoDetalhe: noDetalhe,
      statusDestino: destino,
    }
  }

  return {
    ...base,
    instrucao,
    botao: rotuloAcao(destino),
    onde: 'campo',
    statusDestino: destino,
    exigeFoto: destino in TIPO_PONTO_POR_STATUS,
  }
}
