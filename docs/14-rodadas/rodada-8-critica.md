# Crítica adversarial do plano, rodada 8 (Parte 2, adendo 01)

Objeto: seções 9 a 18 de `/opt/operacao/escolta-armada/docs/14 - Plano Lote 2026-10.md` e os itens 0.7, 0.8, 8.1 e 8.2 que a rodada mexeu. Fiz a revisão como revisor independente, somente leitura, em 08/10/2026 (Brasília). Conferi item a item contra a crítica da rodada 7 (`rodada-7-critica.md`) e a versão criticada (`escolta-homolog/plano/docs14-rodada7-criticada.md`, por diff: 12 trechos mudaram). Usei como referência o adendo 01 (itens 6, 7 e 10 da onda L), o código da branch `melhoria/2026-10-onda-f-divida` (no disco; as migrations 213 em diante ainda não existem), o dump `esquema-producao-2026-10-08.sql` e as policies de `storage.objects` no banco de homologação. Nas referências, `plano:N` é a linha do `docs/14`.

## Nota: 8 de 10

A rodada tratou o I1 da rodada 7 no ponto certo: quem perde o vínculo durante o offline passa a ter o registro gravado como conflito, e o aparelho para de reenviar. Com isso o critério 10 do adendo deixa de ser descumprido nesse caminho. Os menores 1, 4, 6 e 7 foram resolvidos, e os menores 2, 3 e 5 foram resolvidos em parte.

Só que a correção do I1 foi mais larga do que o pedido. A rodada 7 propôs aceitar o registro de quem tinha vínculo quando o aparelho fez o snapshot. O plano aceita o de qualquer usuário autenticado, sobre qualquer escolta, e ainda tira o limite de avisos quando o tipo é emergência. Isso reabre o abuso que o I4 da rodada 6 tinha fechado, agora com alerta de emergência (I1). A trava de INSERT da 213.6, que corrigiu o menor 5, contradiz a trigger de carimbo da 213.3 e pode recusar toda gravação de campo (I2). Há também 6 menores.

## Conferência da rodada 7

| Item | Situação | Observação |
|---|---|---|
| I1 | resolvido no efeito, com problema novo | plano:548, 590. O registro sem vínculo vira conflito `sem_acesso`, "escolta não encontrada" no `FOR UPDATE` deixa de ser erro, a emergência gera aviso e o L4 ganhou os três casos (retirado pela edição, substituído pelo mural, arquivada). Faltou o recorte pelo vínculo anterior, e esse é o I1 desta rodada. O motivo único `sem_acesso` para arquivada e para retirado é aceitável, porque não revela ao aparelho que a escolta foi arquivada |
| Menor 1 | resolvido | plano:625, escolta iniciada com UF da carga da 216, avançada pelos três perfis |
| Menor 2 | resolvido em parte | plano:405: a 214 recria `registrar_etapa_escolta` com o `set_config`, e a (c) declara o caso sem âncora (plano:427). Só que a lista de acréscimos que a 18.4 confere (plano:643) não inclui o `escolta.historico_rpc`, embora a 213.7 diga "conferido na verificação das cadeias". Ver menor 3 |
| Menor 3 | resolvido em parte | S8 (plano:278) declara a sequência do fluxo 1, mas a âncora `dump:1361-1366` aponta justamente para os saltos legados, e não para as arestas lineares (dump:1350-1359, que valem para todos os fluxos). O caso SQL pedido não entrou na 12.6. Ver menor 4 |
| Menor 4 | resolvido | plano:399 |
| Menor 5 | resolvido em parte | a trava passou a ser BEFORE INSERT OR UPDATE (plano:404), e a 216.6 põe a UF na lista da 197 (plano:515). A redação nova criou o I2 |
| Menor 6 | resolvido | plano:645, com a redação a corrigir (menor 5) |
| Menor 7 | resolvido | plano:251, remissão da 8.2 à 18.5 |

## Problemas bloqueantes

Nenhum.

## Problemas importantes

**I1. Qualquer usuário autenticado grava conflito em qualquer escolta e dispara aviso de emergência sem limite.**

Onde está:
- plano:548. Sem vínculo atual, "o livro aceita o registro do próprio usuário, mas só como conflito", e a emergência sem vínculo atual tem aviso "sempre, sem o limite abaixo, marcado como emergência";
- plano:592 (L7). O teste do limite usa só "20 conflitos forjados", sem emergência.

O problema: a única conferência que sobrou é `usuario_id = get_meu_usuario_id()`. "Sem vínculo atual" cobre o operador retirado durante o offline, que é o caso legítimo, mas cobre também qualquer operador que nunca esteve na escolta. A `registrar_campo` está exposta pela API. Então qualquer conta autenticada pode chamar `POST /rest/v1/rpc/registrar_campo` com um `escolta_id` qualquer, um `p_tipo` de emergência e um `client_id` novo a cada chamada. Cada chamada:
1. grava uma linha no livro, com o payload que o chamador escreveu;
2. aparece na tela de conflitos da supervisão;
3. dispara um aviso "marcado como emergência" à supervisão, na Central e na fila do Telegram, sem limite.

Hoje a `emergencias_all` (dump:4115) não deixa quem não é do efetivo nem G4 criar emergência na escolta. Por esse caminho, a pessoa passa a ter o efeito que importa, que é o alarme à supervisão. Numa escolta armada, um falso alarme de emergência gera resposta operacional. Uma rajada também enche a fila do Telegram, que é a mesma das emergências reais, e as reais ficam atrasadas atrás das forjadas. O I4 da rodada 6 tinha fechado exatamente esse abuso com o limite de 5 avisos. A exceção da emergência o reabre, e para o pior tipo de aviso. A autoria fica gravada, o que reduz o risco mas não impede o efeito.

Há um efeito secundário. O livro não tem limite de linhas por usuário, e um `escolta_id` inexistente não tem tratamento declarado: sem chave estrangeira, entra lixo; com ela, dá erro e o aparelho reenvia para sempre. O caso legítimo existe, porque a `escoltas_delete` (dump:4194) deixa gestor apagar escolta em qualquer status.

Correção:
1. Aceitar "sem vínculo atual" só de quem teve vínculo. Por exemplo, uma tabela `escolta_efetivo_saidas (escolta_id, usuario_id, saiu_em, por)`, gravada por trigger AFTER DELETE em `escolta_efetivo`, que cobre a edição, o mural e qualquer outro caminho sem depender de cada RPC. A arquivada entra nos casos de vínculo atual, conferido pelo DEFINER sem o filtro da RESTRICTIVE. Para quem nunca teve vínculo, recusar com erro definitivo (`sem_vinculo`): o aparelho marca como recusado e não reenvia. Um aparelho legítimo nunca está nesse caso, porque o snapshot só traz as escoltas do operador.
2. Emergência sem vínculo atual: aviso imediato só para quem teve vínculo, com agrupamento por escolta e usuário (por exemplo, um aviso a cada 5 minutos com a contagem) em vez de "sem limite".
3. Escolta apagada: declarar `escolta_id` sem chave estrangeira no livro, e conflito com motivo `escolta_apagada` quando o DEFINER não acha a linha.
4. Testes no L7: operador sem vínculo com a escolta chama `registrar_campo` (emergência e linha) e recebe a recusa, sem aviso e sem linha no livro; ex-membro manda 20 emergências em 1 minuto e a supervisão recebe o aviso agrupado; escolta apagada durante o offline vira conflito.

**I2. A trava de INSERT da 213.6 recusa o carimbo gravado pela trigger da 213.3, e com isso pode recusar toda gravação de campo, inclusive no bloco 1 com a master.**

Onde está:
- plano:403 (213.3): `status_escolta_no_registro` é "preenchido por trigger BEFORE INSERT", em toda inserção nas nove tabelas, inclusive as que o operador grava pela master;
- plano:404 (213.6): trigger "BEFORE INSERT OR UPDATE" recusa "gravar ou mudar ... `status_escolta_no_registro` fora das RPCs", e a dupla guarda exige `escolta.rpc_gestao` e G2.

O problema: as duas são BEFORE INSERT na mesma tabela, e o Postgres as roda em ordem alfabética de nome. Se a do carimbo rodar primeiro, a trava vê o carimbo em NEW e recusa a inserção de qualquer operador, supervisor ou central em `pontos_controle`, `checklists`, `ocorrencias`, `emergencias`, `presencas`, `mural_presencas` e nas demais. Isso vale também para as RPCs DEFINER da 204 e da 207, que não ligam `rpc_gestao`. Nomes naturais como `tr_carimbar_etapa` e `tr_travar_colunas_gestao` dão essa ordem. A 213 está no bloco 1, que precisa ser compatível com a master. O mesmo vale para `escoltas`: no INSERT, o DEFAULT 0 de `versao_gestao` já chega em NEW antes das triggers, e "recusa gravar `versao_gestao`" recusaria toda criação de escolta, a menos que a trava compare com o valor padrão, o que o texto não diz.

O teste da janela (18.3) provavelmente pegaria o erro. Mesmo assim, o texto se contradiz, e a correção é uma decisão de desenho, não de execução.

Correção: no INSERT, a trava confere só `anulado_*` (recusa valor não nulo), `arquivada_*` e `reiniciada_em` (recusa valor não nulo) e `versao_gestao` (recusa valor diferente de 0). `status_escolta_no_registro` sai da trava de INSERT, porque a trigger do carimbo sempre sobrescreve o que o cliente mandar, e a trava continua a proteger essa coluna no UPDATE. Declarar os nomes das duas triggers e a ordem esperada. Incluir no portão da 213 dois testes: "operador insere ponto, checklist e emergência com a 213 aplicada" e "operador insere com `anulado_em` preenchido e é recusado".

## Problemas menores

1. **Emergência com vínculo e recusa de RLS.** O item 6 da 16.2 (plano:552) diz que a emergência "fica no livro com alerta", e o item 2 tira o limite só para quem está sem vínculo atual. Declarar se a recusa de RLS ou de trigger com vínculo atual também tem aviso imediato, com o mesmo agrupamento do I1, para não ficar presa no limite de 5.
2. **Conflito de escolta arquivada na tela do supervisor.** O L4 espera o conflito da arquivada "visível ao supervisor". O livro é lido pela policy própria, mas a RESTRICTIVE da 214.6 esconde a escolta de todos, exceto do administrador. Uma junção com `escoltas` na `/dashboard/conflitos` vem nula: sem código, cliente nem data. Declarar que o livro guarda `codigo_escolta` na gravação, ou que a tela lê por função DEFINER, e conferir no L4 que a linha mostra o código.
3. **Cadeia de `registrar_etapa_escolta` sem o `historico_rpc`.** A 18.4 (plano:643) lista os acréscimos conferidos no corpo final (filtro de anulado, recusa de arquivada, hora da ação, `lote_interno.notificar`), mas não o `set_config('escolta.historico_rpc', ...)`, e a 213.7 conta com essa conferência. A 218 e a 219 recriam a função, e é aí que o acréscimo se perde. Incluir na lista e num teste SQL (etapa pela RPC grava `via_rpc = true`).
4. **Âncora e teste do fluxo 1.** Em S8 (plano:278), trocar `dump:1361-1366` (são os saltos legados) por `dump:1350-1359` (as arestas lineares, comuns a todos os fluxos). Acrescentar na 12.6 o caso pedido na rodada 7: escolta do fluxo 1 que saltou de `na_origem` para `no_destino` volta para `em_transito_destino` e depois para `na_origem`, sem anular nada na etapa não vivida, com a prévia dizendo isso.
5. **Redação da 18.5.** plano:645: "a 2b vira 2b, com 217 e 218 ..." e, na mesma frase, a 2b ainda aparece como "217, 218, 219, logo depois do push de L". Reescrever com uma lista só: 2a (204, 200, 201 depois de C), 2b (217, 218 depois de I) e 2c (219 depois de L).
6. **Lista de colunas da 219 e colunas da 213.** O menor 5 da rodada 7 pedia que a lista fechada de colunas de cada ramo da 219 exclua `anulado_*` e `status_escolta_no_registro`. Com a trava de INSERT corrigida (I2) isso deixa de ser falha, mas vale escrever, para o `jsonb_populate_record` não levar ao INSERT uma coluna que a trava recusa.

## Observações

- A policy de upload `fotos_upload_autenticado` (homologação) só confere o bucket. O ex-membro consegue subir as fotos antes de chamar `registrar_campo`, e o fluxo do aparelho (fotos primeiro, depois o registro) não trava no caso `sem_acesso`. Isso já valia antes; a leitura da foto pela supervisão é pela `fotos_leitura_autenticada`, que libera G4.
- Juntar arquivada e retirado no mesmo motivo `sem_acesso` evita que o aparelho descubra o arquivamento. Na tela de conflitos, a supervisão pode ver o motivo detalhado, gravado pelo DEFINER.
- A 216.6 recria a 197 com a UF. Como `interestadual` é gerada, ela continua fora da comparação da 197 por chave fixa. Isso é coerente com a exclusão por `attgenerated` da 214.3.
