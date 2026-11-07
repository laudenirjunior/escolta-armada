# Crítica adversarial do plano, rodada 7 (Parte 2, adendo 01)

Objeto: seções 9 a 18 de `/opt/operacao/escolta-armada/docs/14 - Plano Lote 2026-10.md` e os itens 0.7, 0.8, 8.1 e 8.2 que a rodada mexeu. Fiz a revisão como revisor independente, somente leitura, em 08/10/2026 (Brasília). Conferi item a item contra a crítica da rodada 6 (`rodada-6-critica.md`) e a versão criticada (`escolta-homolog/plano/docs14-rodada6-criticada.md`, por diff). Usei como referência o adendo 01, o código da branch `melhoria/2026-10-onda-f-divida` (no disco), a master `2b3fff9` (por `git show`), o dump `esquema-producao-2026-10-08.sql` e as migrations 197, 207 e 209. Nas referências, `plano:N` é a linha do `docs/14`.

## Nota: 8 de 10

A rodada resolveu o bloqueante e os seis importantes da rodada 6, e os onze menores. As correções estão no lugar certo e quase todas vêm com teste:
- a comparação da 214 exclui as colunas geradas pelo catálogo;
- o destino do "voltar" deixou de depender do histórico;
- a edição não muda mais a versão;
- paradas e check-ins saíram da regra de conflito;
- o `lote_interno` agora tem privilégios fechados e não executa SQL dinâmico;
- o checklist de entrega é identificado pelo carimbo;
- o caminho padrão de publicação é o push único.

Sobra um problema importante, em parte criado pela correção do I2: o registro offline de quem perdeu acesso à escolta não chega ao livro de conflitos. Há também 7 menores.

## Conferência da rodada 6

| Item | Situação | Observação |
|---|---|---|
| B1 | resolvido | plano:412. A comparação exclui as chaves com `attgenerated <> ''`, deixa passar `auth.uid() IS NULL` e tem teste com UF e `interestadual`. Conferi que a 197 compara por lista fechada e não é afetada. O teste da janela da 18.3 não ganhou a escolta carregada pela 216 (menor 1) |
| I1 | resolvido | S8 (plano:278), plano:426-427, 213.7 e teste da linha forjada. A policy `historico_insert` não tem UPDATE, então `via_rpc` não pode ser trocado depois. Restam os menores 2 e 3 |
| I2 | resolvido | plano:420, 422 e 550, e caso no L4. O texto da 213.1 continua dizendo "toda ação" (menor 4). A troca para conflito por linha abriu o I1 desta rodada |
| I3 | resolvido | regra restrita aos pontos de etapa, `FOR UPDATE` e caso no L3 |
| I4 | resolvido | ramos estáticos com `jsonb_populate_record`, `ALTER DEFAULT PRIVILEGES`, dupla guarda na 213.6, limite de 5 avisos, consulta de `has_function_privilege` no portão e teste no L7 |
| I5 | resolvido | plano:435 e teste "voltar de `finalizada` mantém válidos os checklists do wizard" |
| I6 | resolvido | push único como padrão e teste "código novo sem o bloco 2". Ressalva sobre o caminho onda a onda no menor 6 |
| Menores 1 a 11 | resolvidos | flag com o valor guardado; `em_pre_inicio` tratado como zerar; nomes `origem_lat` e demais e complemento no texto (conferi `enderecoComComplemento` em `nova/page.tsx:102`); `lancado_por` pela trigger da 213.8 (o WITH CHECK roda depois dos BEFORE); exceção `auth.uid() IS NULL`; paleta (Lab, padrão, texto inválido, distribuição); 18.4 com a 203 e conferência das cadeias; reversão da 211 com as da 197; chunks pré-carregados; UF fora do polígono e função DEFINER; 0.8, cabeçalho e apêndice |

## Problemas bloqueantes

Nenhum.

## Problemas importantes

**I1. Quem perde o acesso à escolta durante o offline não consegue gravar o registro nem como conflito, e o registro não aparece na lista de conflitos.**

Onde está:
- plano:547: `livro_registrar` e `livro_resultado` "conferem que quem chama é do efetivo da escolta ou G4";
- plano:549: `registrar_campo` é INVOKER e faz `SELECT ... FOR UPDATE` na escolta;
- plano:550: "operador retirado do efetivo" e "viatura removida" estão entre os casos de conflito;
- plano:551: emergência recusada pela RLS "fica no livro com alerta";
- plano:415: a RESTRICTIVE da 214.6 esconde a escolta arquivada de todos, exceto do administrador.

O problema: um operador retirado do efetivo deixa de passar em `sou_do_efetivo` (dump:1268, função que confere `escolta_efetivo` na hora). Para ele:
1. a escolta some pela `escoltas_select` (dump:4208), e o `FOR UPDATE` do INVOKER não acha linha;
2. `livro_registrar` recusa, porque ele não é mais do efetivo;
3. nada é gravado no livro. O aparelho recebe erro e não ok, e reenvia para sempre;
4. a supervisão não vê nada na lista de conflitos. Isso descumpre o critério 10 do adendo, "nenhum registro some sem aparecer na lista de conflitos", e o 4.7.6.

A emergência também cai nesse caso: a `emergencias_all` (dump:4115) usa `sou_do_efetivo`, e o "fica no livro com alerta" do item 6 não acontece.

A correção do I2 deixou esse caminho mais comum. Como a edição não muda mais a versão, a retirada de membro pela `editar_escolta` (agora permitida em escolta iniciada) e a substituição de equipe pelo mural (onda C) só são detectadas "por linha", e a linha de quem saiu não entra no livro.

A arquivada dá no mesmo, porque fica invisível ao INVOKER. Hoje o L4 espera "conflito pela versão", mas o INVOKER não consegue ler a versão.

Nenhum teste cobre o caso: o L3 e o L4 não retiram ninguém do efetivo, e o L7 testa só a recusa.

Correção:
1. Em `livro_registrar`, autorizar também quem tinha vínculo com a escolta quando o aparelho fez o snapshot. Por exemplo: `client_id` novo, `usuario_id = get_meu_usuario_id()` e o usuário consta como membro em `logs_auditoria` da `editar_escolta` ou do mural, ou numa tabela `escolta_efetivo_saidas` gravada pelas RPCs que retiram membro. Nesse caso, gravar sempre `resultado = conflito`, com o limite de avisos do I4 da rodada 6.
2. Em `registrar_campo`, tratar "escolta não encontrada ou invisível" como conflito (motivo `sem_acesso` ou `arquivada`), nunca como erro.
3. Emergência sem acesso: gravar no livro como conflito com aviso imediato, sem o limite de 5.
4. Testes: L4 com "gestor retira o operador do efetivo de uma escolta em andamento durante o offline" e "substituição pelo mural". Nos dois, tudo vai para a lista de conflitos, o aparelho zera a fila e a emergência gera aviso. O caso "arquiva" do L4 passa a conferir o motivo `arquivada`.

## Problemas menores

1. **Teste da janela sem a escolta da carga da 216.** A correção do B1 tem teste próprio (plano:412), mas a 18.3 (plano:624) continua sem "escolta aberta, com coordenada, carregada pela 216", que era o item 3 da correção pedida. Com a master, só esse caso exercita a 214 com `interestadual` calculado.
2. **Quem liga `escolta.historico_rpc`.** A 213.7 (plano:405) diz "ligada pela 207". Só que a 207 (INVOKER, `207_etapa_atomica.sql:91`) não liga variável nenhuma e roda antes da 213 no bloco 1. Precisa ficar escrito qual migration recria `registrar_etapa_escolta` com o `set_config` (a 214, que já a recria). Incluir esse acréscimo na conferência das cadeias (plano:643). Sem ele, toda linha da 207 fica `via_rpc = false`, e a alternativa da anulação (c), "última linha `via_rpc`", nunca acha linha. As linhas anteriores à 213 também nascem `false`, então nos registros antigos a (c) depende só do ponto: em `em_pre_inicio` e em `finalizada` não há ponto. Declarar o que a (c) usa nesses casos (a prévia mostra, como o plano já prevê).
3. **Sequência do `fluxo_versao = 1`.** A trigger aceita `na_origem` para `no_destino` e `no_destino` para `retornando` no fluxo 1 (dump, `validar_transicao_status_escolta`). Pela sequência, o "voltar" de uma escolta do fluxo 1 que pulou etapa leva a um status que ela não viveu. Isso funciona, porque o fluxo 1 aceita seguir dali, mas declarar em S8 a sequência usada para o fluxo 1 e cobrir com um caso SQL.
4. **Texto da 213.1.** O plano:399 ainda diz que `versao_gestao` é "incrementada por toda ação da gestão desta onda", o que contradiz o plano:420 e o 422 (a edição não muda a versão). Ajustar.
5. **Colunas da 213 no INSERT e UF pelo operador.** A trava da 213.6 fala em "mudar". Ela não diz que recusa INSERT com `anulado_*` preenchido, e com isso o operador grava pela API um registro que aparece como "Anulado por <gestor>: motivo". A lista fechada de colunas da 219 também deve excluir as colunas da 213. Além disso, `origem_uf`, `destino_uf` e `uf_estimada` não estão na lista da 197, que vale para escolta agendada (a 214.3 cobre só a iniciada): o operador muda a UF da agendada pela API. Incluir na 216 uma recriação da lista da 197 ou declarar.
6. **Caminho onda a onda.** Com a divisão do bloco 2 pedida na rodada 6 (2b = 217, 218 e 219 depois do push de L), as RPCs da I, incluindo a edição pela Nova, ficam indisponíveis do push de I ao de L, que são cinco pushes com portão. Melhor: 217 e 218 logo depois do push de I, e 219 depois do de L.
7. **8.2 da Parte 1 desatualizada.** O plano:257-258 ainda descreve push "uma a uma" e bloco 2 só com a 204 e a 200. A 18.5 diz que "atualiza a 8.2". Acrescentar na 8.2 uma remissão à 18.5, para o roteiro de publicação não sair do texto antigo.

## Observações

- A dupla guarda da 213.6 não bloqueia nenhum caminho legítimo. Só RPCs G2, migrations e cron mudam aquelas colunas; o `status_escolta_no_registro` nasce por trigger de INSERT.
- O `SELECT ... FOR UPDATE` do INVOKER é compatível com a `escoltas_update` (dump:4222) para efetivo e G4, mas não para quem saiu do efetivo (I1).
- `exigir_ponto_transito_retorno` só age na ida de `retornando` para `na_base`, e por isso não atrapalha o "voltar".
