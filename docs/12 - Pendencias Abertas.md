# Pendências Abertas

Lista viva do que se sabe que está errado ou incompleto, com a razão de não ter sido resolvido. O histórico do que já foi feito fica em [`../LOG-ALTERACOES.md`](../LOG-ALTERACOES.md); aqui fica só o que continua em aberto.

Atualizado em 10/09/2026, depois do zeramento total da base e dos três commits do dia. Seção 0 acrescentada em 29/09/2026, com a publicação do Modo Guiado.

---

## 0. Modo Guiado: o que ficou para depois

Publicado em 29/09/2026 (commits `b5baa89` a `2b3fff9`). Estes itens foram deixados de fora de propósito, por decisão de Pecanha ou para não ampliar o risco da primeira entrega. Detalhes na entrada de 29/09 do [`../LOG-ALTERACOES.md`](../LOG-ALTERACOES.md).

| # | Pendência | Situação |
|---|---|---|
| 0.1 | **Caminho 2: um escritor por etapa** | Aprovado para depois da validação com operadores reais. Hoje a mesma etapa é gravada por dois ou três caminhos: saída da base (wizard e `handleStartBase`), chegada na base e as etapas de trânsito (Campo `avancarStatus` e diálogos da tela de detalhe). Proposta: extrair `gravarPontosPorViatura` e a transição para `lib/etapas.ts`, usada pelas duas telas. Mexe nas funções de gravação da tela de detalhe, de cerca de 5400 linhas: pedir autorização explícita antes |
| 0.2 | **Gravações que ainda vão só para a primeira viatura** | Entram no Caminho 2: passo 1 (checklist de material) e passo 2 (fotos e checklist da viatura) do wizard de pré-início, checklist de entrega da finalização e registro de parada. Check-in já grava na viatura escolhida |
| 0.3 | **Telegram do alerta de check-in pela regra nova** | Decisão de Pecanha. O aviso na tela já usa a regra única de `lib/checkin.ts` (último check-in, senão a saída da base, senão a data prevista). O envio ao Telegram continua pela regra antiga (qualquer PARADA zera o prazo; escolta sem nenhuma não notifica), para não criar mensagem nova ao cliente sem aprovação |
| 0.4 | **Alerta de check-in enviado por cada navegador aberto** | Limite antigo. O `CheckinAlertProvider` roda no navegador de cada usuário logado, e a trava contra repetição é por aba. Cada sessão aberta manda o próprio aviso ao Telegram. Correção: travar o envio no servidor, por coluna ou tabela de último alerta |
| 0.5 | **Opção A da chave: supervisor define quem pode desligar o Modo Guiado** | Não implementada por decisão de 29/09 (opção B em uso). Exige migration: hoje o próprio usuário consegue gravar a própria linha de `usuarios`, então a trava em `metadados` seria contornável. O código já lê `metadados.modo_guiado.pode_desligar` e, se vier `false`, força o modo ligado |
| 0.6 | **Ajustes a partir do uso real** | Coletar com os operadores o que ficou confuso (textos, ordem das telas, tamanho dos botões) e ajustar em branch própria, com teste no preview antes da master |
| 0.7 | **Check-in pelo Campo sem endereço** | O check-in do Painel Guiado grava coordenada, mas não o endereço textual (reverse geocode do Mapbox), que a tela de detalhe grava. O mapa não rotula esse ponto. Mesma lacuna do item 5 da pendência de endereço dos pontos do Campo |

---

## 1. Fora do código

| # | Pendência | Situação |
|---|---|---|
| 1.0 | **Aplicar a migration 193 no SQL Editor** | `database/migrations/193_vinculo_operador.sql`. Repara o vínculo `vigilantes.usuario_id` dos operadores já cadastrados e cria as duas triggers que impedem a recorrência, mais a view `vw_operador_sem_vinculo`. Sem isso, operador não lança foto, checklist nem ponto, e a tela de Campo fica vazia. Aditivo e idempotente. Depois, validar com credencial real de operador, do pré-início ao fechamento |
| 1.0b | **Migrations 193 e 194 aplicadas em 29/09; Modo Guiado testado por Pecanha no preview e publicado na master (2b3fff9)** | A Fase 0 (29/09, com a 193 já aplicada) mostrou `pontos_insert` só na própria viatura; KM (`escolta_veiculos`) e etapa (`escoltas` UPDATE) já valem para a escolta inteira. A 194 acrescenta gravação e leitura de ponto por qualquer viatura da mesma escolta, só no próprio nome. Depois, teste com credencial real de operador num comboio de duas viaturas |
| 1.1 | **Rotacionar a chave `sb_secret`** | A chave de acesso total ao banco foi colada num chat para viabilizar o diagnóstico e a limpeza de 10/09. Continua válida. Rotacionar no painel do Supabase, em Settings, API Keys |
| 1.2 | **Worktree preso em `.git/worktrees`** | `agent-ae374c2302e3f9032` não pôde ser apagado, com `Permission denied`, em todo commit do dia. Não afeta o repositório. Resolver com `git worktree prune` depois de fechar o processo que segura a pasta |
| 1.3 | **Cadastros zerados** | Decisão de Pecanha: quem for operar cadastra cliente, viatura, vigilante e armamento antes de lançar a primeira escolta. Não é para recadastrar por antecipação |

---

## 2. Fotos e prova

| # | Pendência | Situação |
|---|---|---|
| 2.1 | **`carimbo_aplicado` na tela de detalhe** | Resolvido no Campo em 10/09, com `lib/carimbo-foto.ts`. Falta a tela de detalhe: ela grava `false` fixo mesmo quando carimba, no caminho de vídeo ao vivo, e não carimba nada no caminho de seletor de arquivo. Corrigir exige passar a informação do `CameraInput` até o `uploadFoto`, atravessando um arquivo de 5 mil linhas |
| 2.2 | **Bucket `fotos` é público para leitura** | Foto operacional com GPS acessível por URL a quem tiver o link. Fechar exige trocar `getPublicUrl` por URL assinada em 9 pontos e enviar os bytes ao Telegram em `multipart`, porque o `sendPhoto` busca a URL anonimamente |
| 2.3 | **Storage sem backup** | Os dumps em `database/backups/` guardam só os metadados da foto: caminho, GPS, data e hora. As 72 imagens apagadas em 10/09 não voltam |

---

## 3. Checklist

| # | Pendência | Situação |
|---|---|---|
| 3.1 | **O wizard de pré-início ainda grava `modelo_id: null`** | Corrigido apenas na tela de Campo em 10/09. O wizard da tela de detalhe usa constantes no código, `ITENS_CHECKLIST_MATERIAL` e `ITENS_CHECKLIST_VIATURA`, e não consulta modelo nenhum. Enquanto for assim, o checklist de partida não é configurável pela tela de Checklists |
| 3.2 | **`obsMateriais` vem preenchido e a validação deixou de barrar** | Decisão consciente de Pecanha, registrada em `lib/textos-padrao.ts`. **A foto obrigatória dos materiais é hoje a única prova de que houve conferência.** Tornar a foto opcional transforma o Passo 1 em formalidade |
| 3.3 | **Só existe um modelo ativo por tipo** | `material` com 8 itens, `viatura` com 6. Os outros quatro modelos do banco antigo estão em `database/backups/2026-09-10 - Antes do Zeramento Total` e podem ser repostos |

---

## 4. Herdadas, anteriores a 10/09

Levantadas em `docs/03 - Arquitetura Atual.md` e no LOG, ainda sem solução.

> **Aviso sobre esta seção.** Ela foi montada em 10/09 copiando os "Débitos conhecidos" de `docs/03 - Arquitetura Atual.md`, **sem verificar contra o código**. Dois itens já estavam resolvidos havia semanas. A verificação foi feita depois, item a item, e o resultado está abaixo. Lição registrada: aquele documento descreve o estado de quando foi escrito, não o de hoje.

| # | Pendência | Situação |
|---|---|---|
| 4.1 | ~~APIs sem autenticação~~ | **Já resolvido.** As duas rotas chamam `exigirSessao()` de `lib/api-auth.ts`, com limite por usuário. A do Telegram ainda checa perfil: só administrador e gestor mandam para chat arbitrário ou listam conversas |
| 4.2 | ~~`middleware.ts` com `matcher: []`~~ | **Já resolvido.** O matcher cobre tudo menos estático, imagem, manifesto e `api/`. Renova a sessão e barra quem não está logado antes de a página existir |
| 4.3 | **Histórico de status gravado em dobro** | Real e confirmado: a trigger insere e o app insere de novo em 10 pontos das telas de campo e de detalhe. **Precisa do SQL Editor**, porque a decisão certa depende de ler o corpo da trigger, e o PostgREST não lê `pg_proc`. Simplesmente apagar os inserts do app perderia o autor e a observação, que a trigger não tem como saber. **A base está zerada agora: é a melhor janela que vai existir para resolver isso** |
| 4.4 | **`viaturas[0]` em 19 pontos** | Escolta com duas viaturas só registra ponto de controle para a primeira |
| 4.5 | **Sem fila offline** | Não existe. Sem rede, o registro não acontece. `criado_offline` é literal `false` |
| 4.6 | **Sem gráficos nos indicadores** | Só cartões e tabelas. Não há biblioteca de gráficos no `package.json` |
| 4.7 | **Quatro rotas órfãs, e NÃO são redundantes** | `/dashboard/clientes`, `/dashboard/veiculos`, `/dashboard/vigilantes` e `/dashboard/configuracoes/telegram-test`, 1364 linhas, nenhuma alcançável por menu. **Iam ser apagadas em 10/09 e não foram**: a de clientes era a única tela com quatro campos que a aba de Cadastros não tinha. Os campos foram levados para a aba; agora falta reconferir veículos e vigilantes antes de apagar as três |

---

## 5. Acesso ao banco, para quem retomar

O conector do Supabase da claude.ai **não enxerga** o projeto `qthoyxujyzskydulvcfy`. Ele lista apenas `atalaia-os` e `projeto-compasso`, e responde "You do not have permission to perform this action" para este. É problema de conta ou de organização na autorização, não de conexão.

Os dois caminhos que funcionam:

1. **SQL Editor do Supabase**, no navegador. Roda como `postgres` e ignora RLS. Não depende de token.
2. **PostgREST com a chave `sb_secret`**. As ferramentas de leitura e backup estão em [`../database/ferramentas/`](../database/ferramentas/), com README próprio. Os scripts destrutivos de 10/09 ficam junto do backup daquele dia, fora do git.

Atenção para uma limitação do PostgREST: ele não executa DDL. Backup em schema, criação de tabela e leitura de `pg_constraint` só pelo SQL Editor. O backup de 10/09 foi feito como exportação JSON por essa razão.

---

*Ao resolver um item, mover a explicação para o `LOG-ALTERACOES.md` e apagar a linha daqui.*
