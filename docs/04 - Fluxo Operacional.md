# Fluxo Operacional

## A jornada de 9 etapas

Antes havia 8 etapas e a transição da quarta para a quinta era recusada pelo banco.

| # | Etapa | Status | Ponto de controle gerado |
|---|---|---|---|
| 1 | Planejamento | `rascunho`, `agendada` | - |
| 2 | Pré-Início | `em_pre_inicio` | - |
| 3 | Em Trânsito | `em_andamento` | `base_saida` |
| 4 | Na Origem | `na_origem` | `origem` |
| 5 | Trânsito p/ Destino | `em_transito_destino` | `transito_destino` |
| 6 | No Destino | `no_destino` | `destino` |
| 7 | **Trânsito p/ Retorno** | **`em_transito_retorno`** | **`transito_retorno`** |
| 8 | Retorno | `retornando` | `retorno` |
| 9 | Concluída | `na_base`, `finalizada` | `base_retorno` |

Cancelamento é permitido a partir de qualquer etapa não terminal.

## Onde a regra mora

A fonte única no código é [`lib/fluxo-escolta.ts`](../lib/fluxo-escolta.ts). Antes existiam **quatro** definições divergentes: a tela de detalhe, a tela de campo, `utils/constants.ts` e a trigger do banco. A tela oferecia uma transição que o banco recusava, e era esse o erro relatado.

Quem garante a regra é a trigger `validar_transicao_status_escolta` no banco, não o cliente. O `lib/fluxo-escolta.ts` espelha a trigger para a tela desenhar o botão certo.

## A regra do retorno

Para **concluir** o retorno (`retornando -> na_base`) é preciso existir um ponto de controle do tipo `transito_retorno` naquela escolta. Garantido pela trigger `tr_exigir_transito_retorno`.

## Compatibilidade com as escoltas antigas

A coluna `escoltas.fluxo_versao` distingue os dois fluxos:

- **`1`**: as 16 escoltas que já existiam. Podem pular as duas etapas de trânsito, que não existiam quando começaram. Sem isso, as 3 que estavam em `retornando` travariam para sempre.
- **`2`** (padrão): escoltas novas, sob a regra completa.

Quando não restar nenhuma escolta versão 1 em estado não terminal, o ramo de compatibilidade pode sair da trigger e a coluna pode cair.

## Regra de fotos

**Até 5 fotos por ponto, no mínimo 1 obrigatória**, em todo ponto do fluxo.

O wizard de pré-início mantém regra própria: 5 fotos específicas da viatura (frente, traseira, laterais e painel), porque ali cada foto tem significado individual.

Antes, cinco handlers rotulavam a foto como obrigatória na tela e aceitavam sem ela. E o handler de chegada na base capturava a foto e a descartava, o que explica os 12 pontos de retorno sem foto no histórico.
