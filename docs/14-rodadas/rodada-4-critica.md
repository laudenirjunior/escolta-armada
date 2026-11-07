# Crítica adversarial do plano, rodada 4

Objeto: `/opt/operacao/escolta-armada/docs/14 - Plano Lote 2026-10.md` (rodada 4). Revisor independente, somente leitura, em 08/10/2026 (Brasília). Comparei esta rodada com a 3, linha a linha, e conferi as mudanças contra o comando, o código e o dump. `plano:N` é a linha do `docs/14` da rodada 4.

## Nota: 9 de 10

Os 8 itens da rodada 3 foram resolvidos:
1. Há agora regra de decisão do Telegram para C e F. Com o envio pelo banco ativo, o portão exige um aviso real. Sem ele, C e F publicam assim mesmo: C cai para `/api/telegram` nos avisos de pedido, aprovação e recusa, a liberação por tempo fica só no aplicativo, e o relatório diz qual caminho valeu (plano:93). O mural deixa de depender da infraestrutura do Telegram.
2. Na 200, policy sem filtro de bucket passa a contar como "alcança `fotos`", e o teste planta também uma `USING (true)` para `public` (plano:28 e plano:45).
3. Os segredos são criados pela tela do Vault, nunca pelo SQL Editor, e `avisos_telegram.erro` guarda só o código HTTP e a descrição, sem a URL, com conferência no portão do banco (plano:93).
4. O roteiro de push cobre a branch única de publicação e a master que andou, com rebase, portões repetidos e nunca push forçado (plano:253).
5. Entrou o teste "comandante devolve ou inclui em escala fixa: recusado; gestão consegue" (plano:137).
6. O texto da 197 agora descreve o que a policy realmente faz (plano:25).
7. A numeração foi corrigida.
8. A contagem de avisos em `erro` aparece na tela Substituições e no daily log (plano:93).

Não há problema bloqueante nem importante. Restam 3 menores, para corrigir durante a execução da onda C e da publicação, sem nova rodada do plano.

## Problemas menores

**1. Destino do fallback de C.** O plano:93 diz que, no fallback, o navegador chama `/api/telegram` "para o chat central". Só que a rota manda ao grupo do CLIENTE sempre que recebe `escolta_id` e o cliente tem `telegram_chat_id` (`app/api/telegram/route.ts:89-98`), e o operador não pode indicar `chat_id`, que é só para administrador e gestor (`:101`). Quem copiar o padrão dos providers atuais, que mandam `escolta_id`, levaria a disputa interna de equipe ao grupo do cliente.
Correção, na implementação de C:
- (a) chamar a rota sem `escolta_id`, só com o código da escolta no texto, ou acrescentar à rota um campo `destino: 'central'`, resolvido no servidor;
- (b) não usar `texto_completo` nesse caminho;
- (c) no portão funcional da homologação, testar o caminho com `envio_pelo_banco = false` e conferir no servidor falso do Telegram que o aviso chegou ao chat central e nenhum foi ao do cliente.

**2. Caminho da tela do Vault.** "Project Settings, Vault, Add new secret" (plano:93) pode não corresponder ao menu atual do painel do Supabase. Pela regra 1.2, conferir na documentação oficial do Supabase antes de pôr o caminho no roteiro do celular, ou escrever só "tela Vault do painel do Supabase", com o link direto do projeto.

**3. Teste do fallback da F.** A tabela da onda F (plano:221) testa a fila, mas não testa o caminho antigo com `avisos_pelo_banco_ativos()` falso. Acrescentar: "com o envio pelo banco desligado, presença e alerta continuam saindo por `/api/telegram`, uma vez por evento de quem gerou".

## Situação do portão do plano

Pela seção 4.1 do comando, nota 9 ou mais libera o portão. Sugiro registrar no apêndice: rodada 4, nota 9, 3 menores para a execução. Antes do primeiro commit da onda A, conferir o rascunho antecipado contra esta versão, como o próprio plano prevê (plano:16).
