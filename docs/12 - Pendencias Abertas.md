# Pendências Abertas

Lista viva do que se sabe que está errado ou incompleto, com a razão de não ter sido resolvido. O histórico do que já foi feito fica em [`../LOG-ALTERACOES.md`](../LOG-ALTERACOES.md); aqui fica só o que continua em aberto.

Atualizado em 10/09/2026, depois do zeramento total da base e dos três commits do dia.

---

## 1. Fora do código

| # | Pendência | Situação |
|---|---|---|
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
