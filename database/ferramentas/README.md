# Ferramentas de banco

Dois scripts Node, somente leitura, escritos em 10/09/2026 para o diagnóstico e o backup que precederam o zeramento da base. Ficam aqui porque o projeto não tinha ferramenta de backup nenhuma e passou a depender destes.

Nenhum dos dois guarda chave. A credencial entra por variável de ambiente e nunca é escrita em arquivo.

## Por que existem, em vez do caminho normal

O conector do Supabase da claude.ai **não enxerga** o projeto `qthoyxujyzskydulvcfy`. Lista apenas outros dois e responde "You do not have permission to perform this action" para este. Sobram dois caminhos: o SQL Editor no navegador, e o PostgREST com a chave secreta, que é o que estes scripts usam.

**Limitação que define o desenho deles:** o PostgREST não executa DDL. `create schema`, `create table` e leitura de `pg_proc` ou `pg_constraint` só pelo SQL Editor. Foi por isso que o backup virou exportação JSON tabela a tabela, e não schema de backup como o `docs/07 - Runbook.md` descreve.

## `backup.mjs`

Exporta as 34 tabelas do schema `public` para JSON, uma por arquivo, mais um `_manifesto.json` com a contagem de linhas e a data.

```bash
SB_KEY='sb_secret_...' node backup.mjs "caminho/da/pasta/destino"
```

Sai com código 1 se qualquer tabela falhar, e diz qual. Rode antes de qualquer operação destrutiva e **confira o manifesto** antes de prosseguir.

**O que ele não faz:** não copia os arquivos do bucket `fotos`. Guarda só os metadados, ou seja, caminho, GPS, data e hora. Foto apagada do Storage não volta. Foi exatamente o que aconteceu com 117 arquivos em 19/08 e com 72 em 10/09.

Ao acrescentar tabela nova ao schema, acrescente à lista `TABELAS`. A `usuarios_credenciais` ficou de fora do primeiro backup de 10/09 por esse motivo, e a falha só apareceu quando ela virou uma das tabelas que precisavam sobreviver.

## `diagnostico.mjs`

Inventário completo, somente leitura. Imprime usuários com perfil e situação, autoria por tabela, as escoltas uma a uma, os cadastros e o volume de cada tabela.

```bash
SB_KEY='sb_secret_...' node diagnostico.mjs
```

Serve para responder "quem criou o quê" antes de decidir qualquer limpeza. Cuidado ao colar a saída em lugar público: ela mostra e-mail de usuário e nome de vigilante.

## Onde estão os scripts destrutivos

Não ficam aqui, de propósito. `zerar.mjs` e `repor.mjs` estão junto do backup que precedeu a operação, em `database/backups/2026-09-10 - Antes do Zeramento Total`, que é ignorado pelo git. São registro do que foi feito naquele dia, não ferramenta de uso corrente.

Se um dia precisar repetir, leia antes o `docs/11 - Plano de Limpeza de Base.md`, principalmente as ordens de exclusão das folhas para a raiz e a armadilha das fotos referenciadas apenas dentro do JSON de `pontos_controle.observacoes`.
