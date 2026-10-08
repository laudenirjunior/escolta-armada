# Crítica adversarial do plano, rodada 5 (Parte 2, adendo 01)

Objeto: seções 0 (item 7), 9 a 18 de `/opt/operacao/escolta-armada/docs/14 - Plano Lote 2026-10.md`, que incorporam o adendo 01 de 08/10/2026 15h52 ao comando do lote. Fiz a revisão como revisor independente, somente leitura, em 08/10/2026 (Brasília). Conferi contra o adendo, o comando, as análises `onda-g.md`, `onda-i.md`, `ondas-h-j-k.md` e `onda-l.md`, o código da branch `melhoria/2026-10-onda-f-divida` (lido no disco), o código da master `2b3fff9` (por `git show`, só leitura), o dump `esquema-producao-2026-10-08.sql`, as migrations 196 a 209, o `PACOTE_2026-10-08.sql` e o banco de homologação. Nas referências, `plano:N` é a linha do `docs/14`.

## Nota: 6 de 10

As decisões S1 a S14 são, em geral, defensáveis diante da regra "não pergunte" e do texto do adendo. A Onda G tem causa confirmada e conferi as linhas citadas (`escoltas/page.tsx:195-202` e `:125-132`, `nova/page.tsx:683-684`, `topbar.tsx`, `layout.tsx:107-123`, `[id]/page.tsx:1609`, `:1706`, `:3015`, `:3030`). A cobertura do adendo, item a item, está quase completa. O problema está na publicação em blocos: a Parte 2 altera, no bloco 1, funções que só nascem no bloco 2. Há também dependências entre migrations e ondas fora de ordem, um erro de etapa na anulação do reset e lacunas de segurança e viabilidade na Onda L. Encontrei 1 problema bloqueante, 10 importantes e 13 menores.

## Problemas bloqueantes

**B1. A 211 e a 214 (bloco 1) alteram funções da 204, que é do bloco 2. A 204 depois sobrescreve essas alterações, e a homologação não pega o problema.**

Onde está: plano:333 (`_avisar_app` "passa a chamá-la"), plano:334 (`marcar_aviso_lido(p_id)` "já existe"), plano:397 (filtro de arquivada em `mural_info`, `listar_pedidos_mural`, `processar_pedidos_vencidos`, `assumir`, `puxar`, `devolver`, `incluir`, `confirmar_presenca_base`, `_conflito_comandante`) e plano:567 (211 e 214 no bloco 1). Essas funções são criadas em `204_mural_travas_rpcs.sql:50-671`, e a 204 está no bloco 2 (`PACOTE_2026-10-08.sql:1301-1308`).

O que acontece em produção:
- (a) Na hora do bloco 1, as funções ainda não existem. Para a 211 e a 214 rodarem, teriam de criar já as RPCs novas do mural, como a `assumir_escolta` com pedido. É justamente o que a 204 evita ao ficar no bloco 2: a `assumir_escolta` nova junto com o diálogo antigo da master.
- (b) No bloco 2, a 204 recria as funções com o corpo antigo, sem `_notificar` e sem o filtro de arquivada.
- (c) Com o gatilho da 211 (`lida = (lida_em IS NOT NULL)`, plano:331), a `marcar_aviso_lido` da 204 (`SET lida = true`, 204:650) passa a não ter efeito: o "Ciente" do mural nunca fica gravado.
- (d) Trocar o nome do parâmetro de `p_notificacao_id` para `p_id` não é aceito por `CREATE OR REPLACE`, e a tela chama a função com `p_notificacao_id` (`components/escolta/avisos-mural.tsx:31`).

A homologação aplica as migrations em ordem numérica (plano:15 e Fase 4.1 do comando, "todas as migrations em ordem"), com a 204 antes da 211. Por isso tudo passa lá e quebra só na ordem real dos blocos.

Correção:
1. Escrever essas mudanças na própria 204, que ainda não foi publicada, como já se fez com a auditoria de `devolver_escolta` (plano:297), ou passá-las para a 215, no bloco 2, depois da 204.
2. Manter o nome `p_notificacao_id`.
3. Nos portões do banco e na Fase 4, aplicar as migrations na ordem dos blocos (bloco 1 inteiro, depois o bloco 2), e não na ordem numérica.
4. Acrescentar um teste que simule a janela "bloco 1 aplicado e código da master", usando o código de `2b3fff9`.

## Problemas importantes

**I1. Migrations dependem de colunas criadas por migrations ou ondas posteriores.**

- A 212 (J) filtra "ponto PARADA válido (não anulado)" (plano:340), mas `anulado_em` só nasce na 213 (I). Na branch de J, que vem antes de I (plano:566), a coluna não existe.
- A 214.3 (bloco 1) e a 215 tratam "UF" (plano:395 e plano:405), mas `origem_uf` e `destino_uf` só nascem na 217 (K).
  - Se a trigger de 214.3 ler `NEW.origem_uf`, todo UPDATE em `escoltas` falha entre a 214 e a 217.
  - Com "publicar sem K", passa a falhar para sempre, inclusive o avanço de status da master.
- O plano:568 diz "K antes do acréscimo 2 da D", mas o plano:566 executa a D2 antes da K.

Correção:
1. Na 214, comparar as colunas por `to_jsonb(OLD)` e `to_jsonb(NEW)`, como a 197 já faz (`197_escrita_do_operador.sql:66-67`).
2. Pôr o filtro de anulado da 212 na 214 (que já reescreve as funções de I), ou mover as colunas.
3. Alinhar a ordem das branches com as dependências declaradas.

**I2. A matriz de dependências e o "publicar sem X" estão desatualizados.**

A tabela 8.1 (plano:236-243) continua dizendo que C e F "podem sair". Só que:
- A Onda G decide "sem equipe" só por `mural_info` (plano:304), que é da 204 (C, `204:615`). Sem C, nenhuma escolta aparece como livre e o operador não consegue puxar escolta.
- A 211 (J) e a 214 (I) alteram funções da C.
- A 214.4 e a 218 alteram a 207 (F).
- Sem I, a 212 lê uma coluna que não existe, e K e L perdem etiquetas e conflitos.

O plano:568 só trata das ondas novas.

Correção: acrescentar G a L à tabela 8.1, revisar as linhas de C e F, e dizer quais combinações de "publicar sem X" são possíveis e quais não são. Cada combinação possível precisa passar pelos portões, porque a seção 8.1 já exige repeti-los na branch de publicação.

**I3. O reset anula o conjunto errado de registros e volta de `finalizada` para a etapa errada.**

Onde está: plano:408 e plano:274.

- Os checklists do wizard e `checklist_pendente_no_inicio` são gravados na transição `em_pre_inicio -> em_andamento` (`handleWizardSubmit`, `[id]/page.tsx:1184`; `verificar_checklist_pendente`, dump:1391). O plano só os anula "desfazendo `em_pre_inicio`". Ao voltar de `em_andamento`, esses checklists continuam válidos. Quando o wizard é refeito, eles se duplicam, e a flag continua `true`, porque a trigger nunca a volta para `false`.
- O mesmo acontece ao voltar de `finalizada`: o checklist de entrega e as fotos finais, gravados ainda em `na_base`, continuam válidos.
- S8 manda `finalizada` para `na_base` mesmo numa escolta concluída antes da hora (por exemplo em `em_transito_destino`). Com isso a escolta vai para `na_base` sem prova das etapas e a linha de pendências é removida.
- Escoltas com `fluxo_versao = 1` têm outras arestas (dump:1361-1366), e `statusAnterior` (plano:414) as ignora.
- Faltam leitores do filtro de anulado:
  - `enfileirar_alerta_checkin` e `_enfileirar_alerta_checkin_interno`, que são o "corpo da 208" (plano:342);
  - o relatório final enviado ao Telegram;
  - a regra de conflito da L, "ponto do mesmo tipo já existente" (plano:516).

Correção:
1. Definir, para cada etapa X, os "registros produzidos pela entrada em X". Para `em_andamento`: checklists `viatura` e `material`, respostas, fotos do wizard, pontos `base_saida`, KM e a flag. Para `finalizada`: checklist de entrega e fotos finais.
2. Tirar a etapa de destino do reset do `status_anterior` da última linha válida do histórico, que é `status_no_momento` na conclusão antecipada, e não da sequência fixa.
3. Anular a linha de conclusão antecipada, em vez de removê-la.
4. Acrescentar esses leitores ao 12.5.6 e aos testes.

**I4. Na Onda L, a função SECURITY INVOKER não consegue chamar funções internas sem GRANT, e dar o GRANT expõe essas funções.**

`registrar_campo` é SECURITY INVOKER e grava o livro por "função interna DEFINER" (plano:515). No caminho de conflito, também chama `_notificar` e a fila do Telegram (plano:516), que são internas e sem GRANT (plano:333, plano:9). O EXECUTE é conferido contra quem chama, então a chamada falha com "permission denied". Se a função receber GRANT a `authenticated` no schema `public`, ela fica exposta em `/rpc`, e o operador consegue gravar no livro, forjar conflitos e disparar avisos.

Correção: pôr as funções internas usadas por funções INVOKER num schema que o PostgREST não expõe, com GRANT a `authenticated` e conferências próprias (`usuario_id = get_meu_usuario_id()`, `resultado` decidido só no servidor). Incluir no portão do banco um teste do operador chamando cada uma delas pela API.

**I5. Conflito depois de reset quando o status volta a coincidir (adendo 4.7.6).**

Se a gestão volta a escolta exatamente para o status que o registro offline esperava, o registro é aplicado como válido, e não vai para conflito. O plano cita "zerada ou com etapa voltada" (plano:516), mas não diz como detectar isso, e a hora do aparelho não serve como prova.

Correção: criar o contador `escoltas.versao_gestao`, incrementado por reset, arquivamento, recuperação e conclusão antecipada. O valor vai no snapshot e no payload; se não bater com o do servidor, é conflito. Acrescentar ao L4 o caso "voltar uma etapa para o status esperado".

**I6. A Onda L pela tela de detalhe (S11) subestima o escopo e esbarra no Caminho 2 (atenção especial c).**

Não vejo contradição com "decomposição proibida", porque nada é dividido. O adendo libera as mudanças mínimas necessárias para a L. Mas:
- (1) A rota `/dashboard/escoltas/[id]` é dinâmica e o Painel abre essa tela por navegação no cliente (`?volta=campo&acao=`). O SW só guarda o HTML de uma navegação completa, e o payload RSC é "só rede" (plano:528). Sem internet, o detalhe de uma escolta aberta só por navegação no cliente não abre. O L1 (plano:540) abre a escolta por `goto`, o que esconde o problema.
- (2) Antes de gravar, os handlers fazem chamadas de rede que o plano não trata: `conferirEtapa` (:1490), upload, geocodificação reversa da Mapbox (:1852), `notificarTelegram` e `createSignedUrls`, que é POST e não entra no cache, no `loadData`. "Uma chamada em cada" (plano:526 e plano:532) não basta.
- (3) O plano:532 lista ocorrência e emergência entre os handlers do detalhe, mas o detalhe só as lista (`:866`); não as grava.
- (4) A frase "única porta de gravação de campo das duas telas" (plano:525), junto com o tipo `wizard_partida` montado no servidor (plano:515), cabe na definição da pendência 0.1, "função única usada pelas duas telas" (`docs/12:15`). O adendo manteve proibido "o restante do Caminho 2".

Correção:
1. Fazer o SW pré-carregar o HTML do detalhe das escoltas do snapshot, com `ignoreSearch`, e testar a abertura por navegação no cliente.
2. Listar, por handler, cada chamada de rede e o que acontece com ela sem internet.
3. Tirar ocorrência e emergência da lista do detalhe.
4. Declarar em S11 que `registrar_campo` é só um envelope de transporte e que cada tela continua montando o próprio conteúdo. `wizard_partida` grava exatamente as linhas que o wizard montou, sem regra nova. Registrar isso como desvio declarado no relatório de prontidão.

**I7. Bloco 1 incompatível com a master na 217 (atenção especial a).**

O `CHECK (cor_destaque IN (...12 cores))` (plano:481) entra antes do deploy. A master grava cor livre: `cadastros/page.tsx:689` usa `<input type="color">` com padrão `'#3b82f6'` (`:37`), e `clientes/page.tsx:52` usa `'#3B82F6'`. Cadastrar ou editar cliente falha da aplicação do bloco 1 até o deploy da K, e para sempre com "publicar sem K".

Correção: levar o CHECK para o bloco 2, ou usar `NOT VALID` com uma trigger que normalize para a cor mais próxima da paleta, sem diferenciar maiúscula de minúscula.

**I8. ESC-2026-0001 e ESC-2026-0007 mudam sem aviso na seção 0.8.**

A carga da 217 (plano:480) atualiza `origem_uf`, `destino_uf` e `uf_estimada` em todas as escoltas. Isso também dispara `atualizado_em` e a trigger da 216, que soma `vezes_usado`. A seção 0.8 (plano:14), que lista o que pode mudar nessas duas escoltas, não foi atualizada (regra 1.11 do comando).

Correção: tirar as duas da carga, com `WHERE codigo_escolta NOT IN (...)`, e listá-las no relatório, ou declarar a mudança na 0.8.

**I9. `editar_escolta` dá à central um poder que hoje ela não tem.**

Para rascunho e agendada, a RPC vale para G4 (plano:405) e é SECURITY DEFINER. Hoje a RLS não deixa a central escrever a equipe (`escolta_efetivo_escrita` só para administrador, gestor e supervisor, dump:4148). A RPC daria à central a edição da equipe, contra a decisão 3 ("central como hoje").

Correção: dentro da RPC, equipe só para G3; teste SQL com a central.

**I10. A reversão da Onda L por `git revert` perde registros (critério 4.7.10).**

Ao reverter (plano:552), o código antigo não tem a rotina de envio da fila: registros guardados no IndexedDB e ainda não enviados somem sem ir para a lista de conflitos. O Cache Storage também continua com respostas do Supabase por usuário, mesmo em aparelho compartilhado.

Correção: a reversão vira uma chave que desliga a entrada na fila e mantém o envio até esvaziar. Antes de reverter de fato, conferir em `registros_campo` que nada ficou pendente. O `sw.js` de reversão apaga os caches.

## Problemas menores

1. O nome `tr_impedir_edicao_iniciada` vem antes de `tr_impedir_edicao_por_operador` na ordem alfabética ("i" antes de "p"), e não entre ela e `tr_validar_...` como diz o plano:395. A lista real na homologação: `..._atualizado_em, _exigir..., _gerar..., _impedir_edicao_por_operador, _proteger_escala_fixa, _validar..., _verificar...`. Corrigir o texto e o teste, ou o nome.
2. A trigger da 216, `AFTER INSERT OR UPDATE` (plano:469), soma 1 a cada UPDATE da escolta, inclusive a cada mudança de status e na carga da 217. Limitar a INSERT e a `UPDATE OF` origem e destino, com `IS DISTINCT FROM`.
3. O plano:259 cita "item 11 da seção 0"; o certo é o item 7.
4. A seção 5 do adendo não está no plano: subtarefas G a L na tarefa-mãe 868md6rr5, uma seção por onda nos relatórios, e o comunicado com Passo 2 e 3, notificações, reset e offline com as limitações. Acrescentar um item na seção 18.
5. A seção 8.2 não foi atualizada para 13 ondas: falta dizer quando a 215 e a 218 entram no bloco 2 (dependem da 204 e da 211) e a sequência de push e de portão de produção de G a L.
6. A RESTRICTIVE de `pontos_insert` (plano:399; atenção especial b) é compatível com a master, porque `user.id` é `usuarios.id` (`hooks/useAuth.ts`). Ressalvas:
   - a master grava `lancado_por: user?.id ?? null` (`[id]/page.tsx:1689` e `:1834` em `2b3fff9`), e esse nulo passa a ser recusado;
   - a 207 e a 218 devem preencher `lancado_por` no servidor;
   - escrever a policy com `(SELECT get_meu_usuario_id())`;
   - declarar que "em nome de quem fez" não está garantido em `checklists`, `ocorrencias` e no histórico.
7. Na Onda H, `handleStartBase` (`:1729`, diálogo `:4618-4626`) ainda pede KM e foto na saída. Decidir e declarar. O plano:462 diz "Modo Guiado: nada"; conferir o texto de `lib/proximo-passo-operador.ts:52`.
8. Na Onda K, a UF pela `region` da Mapbox não pode ser testada na VPS sem token: declarar como no plano:174. Os vértices do RJ devem vir da malha do IBGE baixada, citada e guardada, nunca desenhados à mão. A "UF vizinha por caixas" pode errar: exibir só "RJ" ou "fora do RJ" quando `uf_estimada`.
9. O plano:536 omite `PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1`, que a análise (`onda-l.md` 4.9) dá como necessário para interceptar o que passa pelo SW.
10. S14: dizer o status atual da ESC-2026-0008. Se já foi executada, voltar a equipe falsificaria o registro, o que reforça a decisão de não corrigir.
11. Ao zerar, a escolta volta a `agendada` e reaparece no mural (`escoltas_select` libera agendada a todos), com `data_hora_prevista` passada: a janela T1 está aberta e a presença T2 antiga continua valendo. Definir como fica (anular `mural_presencas` e mostrar "reiniciada pela gestão").
12. "Remove a linha de conclusão antecipada" (plano:408) contraria "nada é apagado" (decisão 2): anular a linha.
13. S3 diz "igual à 208", mas a chave de 212.2 é outra (plano:341): ajustar o texto.

## Atenções especiais pedidas

- (a) A 213 e a 214, quanto às colunas e às travas, são compatíveis com a master: os únicos UPDATE em `escoltas` são de status e de fechamento, e o reagendar só funciona a partir de agendada. As exceções são B1 (funções da 204), I1 (UF) e I7 (217).
- (b) A RESTRICTIVE está correta; ver o menor 6.
- (c) Não contradiz "decomposição proibida", mas precisa da delimitação do I6 para não virar o Caminho 2.
- (d) Ver I3.
- (e) O desvio de ordem do plano:566 é defensível pelo item 1.3 do adendo ("sem descartar o trabalho feito") e pela confirmação única. As consequências, porém, não foram levadas para as seções 8.1, 8.2 e 18.3 (I1, I2 e menor 5).
