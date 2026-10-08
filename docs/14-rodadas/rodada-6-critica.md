# Crítica adversarial do plano, rodada 6 (Parte 2, adendo 01)

Objeto: seções 9 a 18 de `/opt/operacao/escolta-armada/docs/14 - Plano Lote 2026-10.md` e os itens 0.7, 0.8, 8.1 e 8.2 que a rodada mexeu. Fiz a revisão como revisor independente, somente leitura, em 08/10/2026 (Brasília). Conferi item a item contra a crítica da rodada 5 (`rodada-5-critica.md`) e a versão criticada (`escolta-homolog/plano/parte2-adendo01-rodada5.md`). Usei como referência o adendo 01, as análises `onda-i.md`, `onda-l.md` e `ondas-h-j-k.md`, o código da branch `melhoria/2026-10-onda-f-divida` (no disco), a master `2b3fff9` (por `git show`), o dump `esquema-producao-2026-10-08.sql`, as migrations 197, 201, 204, 206, 207, 208 e 209 e o banco de homologação (PostgreSQL 17.11, só consultas). Nas referências, `plano:N` é a linha do `docs/14`.

## Nota: 7 de 10

A rodada resolveu bem a maior parte da crítica anterior:
- B1 está resolvido: a 211 não toca na 204, a 217 vai para o bloco 2, o nome `p_notificacao_id` foi mantido, a homologação passa a aplicar as migrations na ordem dos blocos e há o teste da janela com a master.
- I2, I5, I7 a I10 e 12 dos 13 menores foram tratados.
- A tabela de anulação por etapa, a versão de gestão e o envelope de transporte da L estão no caminho certo.

A correção do I1, porém, criou um bloqueante: a comparação por `to_jsonb(NEW)` da 214 enxerga a coluna gerada `interestadual` da 216 como nula num gatilho BEFORE do PL/pgSQL e trava o avanço de status das escoltas iniciadas. A homologação não pega o problema na janela com a master. Há também 6 problemas importantes e 11 menores, quase todos novos ou parciais.

## Conferência da rodada 5

| Item | Situação | Observação |
|---|---|---|
| B1 | resolvido | plano:335-357, 616-622 |
| I1 | resolvido, com efeito colateral | a 212 não lê `anulado_em`; a 214.5 recria as funções; a UF vem por `to_jsonb`; a D2 antes da K está justificada. O `to_jsonb` gerou o B1 desta rodada |
| I2 | resolvido | tabela 18.4. Ressalva: a I também depende da 203 (`mural_presencas`) |
| I3 | parcial | ver I5 e I6 desta rodada e os menores 1 e 2 |
| I4 | parcial | ver I4 desta rodada |
| I5 | resolvido no conceito | `versao_gestao` e L4. A regra de incremento ficou contraditória (I2 desta rodada) |
| I6 | resolvido | pré-carga do SW, tabela de chamadas de rede, ocorrência e emergência só no Campo, S11 como envelope. Conferi: o roteador do Next, quando falha o pedido RSC, cai para navegação completa. Lacuna dos chunks no menor 9 |
| I7 | resolvido | gatilho que normaliza a cor, sem CHECK. Ressalvas no menor 6 |
| I8 | resolvido | a carga exclui 0001 e 0007 (plano:14 e 510). Ressalva de texto no menor 11 |
| I9 | resolvido | equipe só para G3 em `editar_escolta`; teste com a central |
| I10 | resolvido | reversão em duas etapas e `registros_campo_aparelhos` |
| Menores 1, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13 | resolvidos | |
| Menor 2 | resolvido na lógica | os nomes de coluna saíram errados (menor 3 desta rodada) |
| Menor 6 | parcial | ver menor 4 desta rodada |

## Problemas bloqueantes

**B1. A 214 trava toda mudança de status em escolta iniciada que tenha UF, pela coluna gerada `interestadual` (atenção especial b).**

Onde está: plano:410 e plano:508.
- A 214.3 recusa, para quem não é G2, "mudar qualquer chave de `to_jsonb(NEW)` fora da lista de colunas livres".
- A 216 cria `interestadual boolean GENERATED ALWAYS AS (...) STORED`.

Num gatilho BEFORE, o PL/pgSQL entrega as colunas geradas STORED como NULL em `NEW`. A documentação do PostgreSQL 17 (trigger-definition) diz que "o `NEW` ainda não contém o novo valor gerado e não deve ser lido", e o `pl_exec.c` zera esse campo no ramo UPDATE. Em `OLD` fica o valor antigo. Assim, quando `interestadual` não é nulo, `to_jsonb(NEW)->'interestadual'` (null) difere de `to_jsonb(OLD)->'interestadual'`. Isso vale para toda escolta com as duas UFs, ou com uma UF fora do RJ.

Efeito em produção:
1. Já com o bloco 1 e a master: as escoltas abertas que recebem UF na carga da 216 travam a partir de `em_pre_inicio` para operador, supervisor e central. O wizard (`em_pre_inicio` para `em_andamento`) e todas as etapas seguintes passam a ser recusados. Só gestor e administrador avançam.
2. Depois do deploy da K: toda escolta nova, porque a Nova grava UF.

A homologação não pega o problema na janela com a master (plano:464 e 622):
- as 36 escoltas da homologação estão todas canceladas;
- as escoltas que a master cria não têm UF, então `OLD` e `NEW` ficam nulos e iguais.

O problema só apareceria na K ou na L, depois de todo o bloco 1 estar decidido.

Correção:
1. Na 214, excluir da comparação as colunas com `attgenerated <> ''`, lidas de `pg_attribute` na própria função, ou acrescentar `interestadual` à lista de colunas livres.
2. Declarar a regra, porque vale para qualquer coluna gerada futura.
3. Teste SQL: operador avança uma escolta iniciada com `origem_uf = 'SP'`. Acrescentar ao teste da janela (18.3) uma escolta aberta, com coordenada, carregada pela 216.

## Problemas importantes

**I1. O destino do "voltar uma etapa" sai de uma tabela que o próprio operador grava.**

Onde está: plano:278 (S8) e plano:424.

A etapa de destino é o `status_anterior` da última linha válida de `escolta_status_historico`. A anulação (c) usa a `data_hora` dessa linha. Só que a policy `historico_insert` (dump:4272) deixa qualquer membro do efetivo inserir uma linha com `status_anterior`, `status_novo`, `data_hora` e `alterado_por` livres. A master faz isso hoje no cancelar e no reagendar (`[id]/page.tsx:1385` e `:1419` em `2b3fff9`).

Pela API, um operador planta `status_novo = <atual>, status_anterior = 'agendada'` com data antiga. O "voltar uma etapa" da gestão leva então a escolta para `agendada` e anula, pela janela de tempo, registros que não pertencem à etapa desfeita. O ramo especial da 214.1 aceita "a etapa calculada pela RPC", seja ela qual for.

Há mais dois pontos:
- No backup há 56 linhas de histórico para 14 escoltas. Pelo comentário da 207, os inserts antigos de histórico ignoravam erro. Escolta sem a linha esperada fica sem destino definido.
- O plano não diz de quais status o "voltar" parte. A partir de `cancelada`, ele "descancela", e nada no adendo pede isso.

Correção:
1. Destino = antecessor na sequência do `fluxo_versao` (`statusAnterior`, plano:444).
2. Para `finalizada` com conclusão antecipada, destino = `status_no_momento` de `escolta_conclusoes_antecipadas`, tabela que só a RPC grava.
3. O histórico serve só de conferência.
4. A anulação (c) usa só linhas escritas por RPC: acrescentar a coluna `via_rpc`, preenchida por gatilho a partir da variável de transação. Ou, então, revogar o INSERT direto em `escolta_status_historico` no bloco 2, depois do deploy de F.
5. Recusar o "voltar" a partir de `rascunho`, `agendada` e `cancelada`, ou declarar a escolha.
6. Teste SQL com uma linha forjada pelo operador.

**I2. `versao_gestao` muda na edição de escolta iniciada, mas a L diz que não muda: o conflito sai falso.**

A seção 12.4 (plano:418) põe `versao_gestao + 1` em "todas" as RPCs, e `editar_escolta` "não incrementa em rascunho e agendada" (plano:420), ou seja, incrementa nos demais status. Já a 219.5 (plano:548) e o adendo 4.7.6 falam só de "reset, arquivamento ou conclusão".

Exemplo: o gestor corrige a observação de uma escolta em trânsito. Com isso, tudo o que os operadores registraram offline desde o snapshot vai para conflito, sem ser aplicado. Com o app online, a próxima ação de quem estava com a tela aberta também cai em conflito.

Correção: `editar_escolta` não mexe em `versao_gestao`. Se alterar equipe ou viatura de escolta iniciada, o conflito é medido por viatura e por membro, não pela versão. Acrescentar ao L4 o caso "gestor edita a observação durante o offline: nada vai para conflito".

**I3. A regra "ponto válido do mesmo tipo já existente na viatura" manda para conflito o segundo check-in e a segunda parada.**

Onde está: plano:548. Parada e check-in são `pontos_controle` do tipo PARADA (208:33) e se repetem várias vezes por viatura. Do jeito que está escrita, a regra joga para conflito todo check-in periódico depois do primeiro, e cada um gera aviso à supervisão.

Também falta a trava: `registrar_campo` com `linhas` e sem `etapa` não diz se faz `SELECT ... FOR UPDATE` na escolta antes de conferir. Dois aparelhos enviando ao mesmo tempo passam os dois pela conferência.

Correção:
1. Restringir a regra aos tipos de `TIPO_PONTO_POR_STATUS` (ponto de etapa) e a `base_saida` e `base_retorno`.
2. Trava `FOR UPDATE` na escolta em todo `registrar_campo`. O operador já tem UPDATE pela `escoltas_update`.
3. Caso no L3 com dois check-ins seguidos offline: os dois aplicados.

**I4. Onda L: o `lote_interno` com USAGE para `authenticated` fica protegido só por não estar exposto, e o plano não fecha o caminho por SQL dinâmico (atenção especial a).**

Pela API não há abuso direto:
- o PostgREST da homologação expõe `public` e `graphql_public`;
- o `pg_graphql` só reflete schemas do `search_path`.

Mesmo assim:
- (1) O envelope `linhas` (plano:547) recebe do aparelho a tabela, as colunas e os valores. Se a 219 montar o SQL com `format`/`EXECUTE` a partir do payload, uma injeção roda como o operador, com USAGE no `lote_interno` e EXECUTE nas funções `livro_*`. Daria para gravar `resultado = aplicado` num registro que não foi aplicado e esconder o conflito. Daria também para ligar `set_config('escolta.rpc_gestao', ...)`, porque a trava da 213.6 (plano:404) confere só a variável e não o perfil, e mudar `anulado_*` e `versao_gestao`.
- (2) "`resultado` decidido dentro delas" (plano:545) não tem como ser implementado assim: a função DEFINER não tem como saber se a gravação feita pela INVOKER deu certo. O resultado é decidido pela `registrar_campo`. A integridade depende de só ela chamar `livro_*`, e isso precisa estar escrito.
- (3) Função criada no `lote_interno` nasce com EXECUTE para PUBLIC. Com o USAGE dado, toda função interna (`notificar`, `gerar_avisos_checkin` e as demais) fica executável por `authenticated` sempre que alguém esquecer um REVOKE.
- (4) O operador gera conflitos à vontade (payload inválido, `client_id` novo), e cada um vai à Central e ao Telegram da supervisão.

Correção:
1. `linhas` com um ramo estático por tabela permitida (`INSERT ... SELECT * FROM jsonb_populate_record(NULL::public.<tabela>, ...)`), lista fechada de colunas por tabela e nenhum identificador vindo do payload.
2. `ALTER DEFAULT PRIVILEGES IN SCHEMA lote_interno REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`, e EXECUTE a `authenticated` só nas duas funções `livro_*`.
3. Dupla guarda (variável e perfil G2) também na trava da 213.6.
4. Limite de avisos de conflito por usuário e janela (por exemplo 5 por 10 minutos, os demais só no livro).
5. No portão do banco, consulta de `has_function_privilege('authenticated', oid, 'EXECUTE')` para todas as funções do `lote_interno`. No portão de produção, `POST /rest/v1/rpc/livro_registrar` como operador (404) e conferência dos schemas expostos no painel.

**I5. Ao desfazer `finalizada`, o checklist de entrega não se distingue do checklist do wizard.**

Onde está: plano:430 e 433. A finalização grava o checklist de entrega com `tipo: 'viatura'` (`[id]/page.tsx:2537-2541` na branch), o mesmo tipo do checklist do wizard (`:1268`). A tabela diz "checklist de entrega" sem dizer como identificá-lo. Uma implementação pelo tipo, que é o que a linha `em_andamento` sugere, anula também o checklist de partida.

Correção: identificar a entrega pelo carimbo `status_escolta_no_registro = 'na_base'` e, nos registros antigos, pela janela depois da linha de `na_base`. Teste SQL: voltar de `finalizada` mantém válidos os checklists do wizard.

**I6. A publicação passa por estados intermediários que nenhum teste cobre, e o bloco 2 espera até a última onda.**

Onde está: plano:642. O bloco 2 entra "logo depois do deploy das ondas A, C, I e L", e os pushes vão "na ordem da pilha", com portão de produção depois de cada um. Com a pilha A-F, G, J, I, H, D2, K, L, o mural novo de C fica em "Atualização em andamento" do push de C até o de L, ou seja, nove pushes e nove portões de produção. Durante esse tempo:
- os portões de C, I e L não passam, porque dependem de RPCs do bloco 2;
- a edição de escolta pela Nova (I chama `editar_escolta`, que é do bloco 2) fica indisponível, e isso não está listado;
- o teste da janela (plano:622) cobre só "master e bloco 1", não "branch X e bloco 1".

Correção: tornar o push único da última branch o caminho padrão (o próprio plano:642 já o admite), com o bloco 2 logo depois. Se o Peçanha preferir onda a onda, dividir o bloco 2 em 2a (204, 200, 201, depois do push de C) e 2b (217, 218, 219, depois do de L). A 217 é compatível com o código de C, porque grava na mesma tabela. Testar cada estado intermediário que for usado.

## Problemas menores

1. **Flag de checklist pendente.** A tabela manda voltar `checklist_pendente_no_inicio` a `false` (plano:430), mas a Nova cria a escolta com `true` (master `nova/page.tsx:604`, branch `:693`), e a trigger só grava `true`. Uma escolta que passou por reset fica com uma semântica diferente das demais. Restaurar o valor guardado em `valores_anteriores`, ou declarar a mudança.
2. **Voltar de `em_pre_inicio` para `agendada`.** Na prática é um "zerar", mas não anula as presenças T2 nem grava `reiniciada_em` (plano:435). Aplicar o mesmo tratamento da S15.
3. **Nomes de coluna errados na 215.** O gatilho cita `origem_latitude`, `origem_longitude`, `destino_latitude` e `destino_longitude` (plano:499). As colunas reais são `origem_lat`, `origem_lng`, `destino_lat` e `destino_lng` (homologação e 197), e `CREATE TRIGGER ... UPDATE OF` com coluna inexistente falha. Além disso, `escoltas` não tem `complemento`: dizer onde o complemento do atalho vai parar.
4. **`lancado_por` nulo.** "O nulo só acontece sem sessão" (plano:414) contradiz a própria 10.1.1: o perfil chega depois da sessão (`hooks/useAuth.ts:10`), e `user?.id` pode ser nulo com sessão válida. Acrescentar um BEFORE INSERT que preencha `lancado_por := get_meu_usuario_id()` quando vier nulo. A RESTRICTIVE continua recusando um valor diferente.
5. **Exceção para migrations e cron não escrita.** A 214.3 e a 213.6 não dizem que deixam passar `auth.uid() IS NULL`, como a 197 e a 206 fazem. A carga da 216 e a reaplicação da 201 atualizam escoltas finalizadas e iniciadas e dependem dessa exceção.
6. **Paleta (atenção especial d).** Pontos que a 216 precisa definir:
   - (a) a carga pela "mais próxima" pode juntar clientes de cores parecidas na mesma cor da paleta, contra "uma cor por cliente". Distribuir sem repetir enquanto houver cor livre e listar as trocas;
   - (b) o padrão da coluna (`'#3B82F6'`, NOT NULL) não está na paleta: trocar o DEFAULT;
   - (c) dizer o que o gatilho faz com texto que não é `#rrggbb`: normalizar para uma cor padrão, nunca levantar erro, para não quebrar a master;
   - (d) dizer qual distância é usada (RGB ou Lab).
7. **Seção 18.4 incompleta.** A linha da I não cita a 203 (`mural_presencas`, plano:403). As funções da 207 são reescritas em cadeia: 207, 214, 218 e 219. Incluir um teste que confira, no banco final, que o corpo de `registrar_etapa_escolta` tem os três acréscimos: filtro de anulado, recusa de arquivada e hora da ação.
8. **Reversão da 211.** A reversão "devolve policies e grants da 195" (plano:383), mas a 211 apaga também as RESTRICTIVE da 197. Revertida só a 211, o buraco M3 volta a abrir. A reversão deve recriar as policies da 197.
9. **Chunks da rota do detalhe.** A pré-carga do HTML do detalhe (plano:560) não traz os chunks JS da rota. Num aparelho que nunca abriu um detalhe nesta versão, a página abre em branco sem internet. Pré-carregar os scripts citados no HTML ou listados no manifesto do build. O L8 já testa, mas a regra precisa estar no plano.
10. **UF fora de todo polígono.** `uf_da_coordenada` não diz o que devolve para ponto fora de todos os polígonos, como baía, ilha ou litoral numa malha de qualidade mínima. Devolver a UF mais próxima com `uf_estimada` e mandar o ponto para a lista de conferência. A função também deve ser DEFINER, porque lê o `lote_interno.malha_uf`.
11. **Texto e cabeçalho.** A 0.8 (plano:14) diz que as colunas novas "nascem sem reescrever a linha", mas `interestadual` STORED reescreve a tabela inteira, embora sem gatilho e sem mudar `atualizado_em`. Ajustar o texto. O cabeçalho (plano:3) e o apêndice continuam na rodada 4: falta a rodada 5 (nota 6).

## Atenções especiais pedidas

- **(a)** Pela API não há abuso direto: o `lote_interno` não está exposto e as funções `livro_*` só são chamadas pela `registrar_campo`. Os riscos reais são SQL dinâmico no envelope `linhas`, o EXECUTE padrão para PUBLIC, a trava da 213.6 só por variável e o volume de conflitos (I4). Nenhuma RPC DEFINER do `public` repassa argumentos do usuário para o `lote_interno` sem conferência. A 208 tem guarda de perfil ou efetivo.
- **(b)** A lista de colunas livres cobre tudo o que a master grava em escolta iniciada: status, cancelar (`observacao_fechamento`), reagendar (só em agendada), finalizar e periodicidade (`[id]/page.tsx` em `2b3fff9`). A 207 só grava colunas livres, e as RPCs da 204 só agem em `agendada`. O problema é a coluna gerada (B1).
- **(c)** A tabela confere com o código em `em_pre_inicio` (só histórico), `em_andamento` (wizard em `:1245-1330`, `base_saida`, `quilometragem_saida`) e `na_base`. Em `finalizada`, não há pontos na finalização. Divergências: checklist de entrega com o mesmo tipo (I5), flag (menor 1) e destino pelo histórico (I1).
- **(d)** A normalização por gatilho mantém a master funcionando. Ressalvas no menor 6.
