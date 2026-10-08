# Crítica adversarial do plano, rodada 9 (Parte 2, adendo 01)

Objeto: seções 9 a 18 de `/opt/operacao/escolta-armada/docs/14 - Plano Lote 2026-10.md` e os itens 0.7, 0.8, 8.1 e 8.2. Fiz a revisão como revisor independente, somente leitura, em 08/10/2026 (Brasília). Conferi item a item contra a crítica da rodada 8 (`rodada-8-critica.md`) e a versão criticada (`escolta-homolog/plano/docs14-rodada8-criticada.md`). Pelo diff, mudaram 9 trechos: cabeçalho, S8, 213.6, a linha "Volta uma etapa" da 12.6, os itens 2 e 4 da 16.2, o L7, os itens 4 e 5 da 18 e o apêndice. Os itens 0.7, 0.8, 8.1 e 8.2 não mudaram. Usei como referência o adendo 01, o código da branch `melhoria/2026-10-onda-f-divida` (no disco), o dump `esquema-producao-2026-10-08.sql` e as policies e chaves estrangeiras de `escoltas`, `escolta_efetivo` e `usuarios`. Nas referências, `plano:N` é a linha do `docs/14`.

## Nota: 9 de 10

Os dois importantes da rodada 8 foram resolvidos no ponto certo. O livro deixou de aceitar registro de quem nunca esteve na escolta: o vínculo perdido agora vem de `escolta_efetivo_saidas`, gravada por trigger, e quem nunca teve vínculo recebe `SEM_VINCULO`, sem linha e sem aviso. A emergência sem limite deu lugar ao aviso agrupado. A trava de INSERT da 213.6 deixou de conferir o carimbo e passou a aceitar o padrão de `versao_gestao`, com nomes de triggers e testes no portão. Os menores 1, 3, 4, 5 e 6 foram resolvidos; o 2 foi resolvido em parte, porque falta o teste.

As correções trouxeram pontos novos, todos menores. Não declaram as propriedades da tabela `escolta_efetivo_saidas` e da sua trigger (DEFINER, sem chave estrangeira), nem como sai o aviso agrupado quando não chega nova emergência. O `SEM_VINCULO` ainda alcança um caso legítimo, o da gestão fora da equipe com escolta arquivada. O motivo `arquivada` contradiz o L4. Na leitura final contra o adendo, um único ponto ficou sem plano no servidor: a decisão 1 ("arquivar, nunca apagar") convive com a `escoltas_delete`, e o plano agora usa essa exclusão como caso normal. Nada disso quebra produção nem descumpre critério de aceite como escrito, e a execução trata. Não há bloqueante nem importante.

## Conferência da rodada 8

| Item | Situação | Observação |
|---|---|---|
| I1 | resolvido | plano:548. Vínculo perdido só por `escolta_efetivo_saidas` (AFTER DELETE e AFTER UPDATE OF vigilante_id, inclusive na cascata) ou pelo efetivo de escolta arquivada, lido pela DEFINER. Sem vínculo nenhum, `SEM_VINCULO`, sem linha e sem aviso, e a mesma resposta para escolta inexistente, então não serve para descobrir se uma escolta existe. Emergência com aviso agrupado (1 na hora, depois 1 a cada 10 minutos por pessoa e escolta). Conferi no dump: `escoltas_update` (dump:4222) só deixa G4 ou efetivo, então o `FOR UPDATE` de quem não é do efetivo nem G4 não acha a linha e cai no livro, como o texto diz. L7 com os três testes pedidos (plano:593) |
| I2 | resolvido | plano:404. No INSERT, a trava recusa só valor diferente do padrão (nulo e 0 passam), e `status_escolta_no_registro` sai da trava de INSERT. Nomes `tr_carimbar_etapa_<tabela>` e `tr_travar_colunas_gestao_<tabela>`. Portão com a master: criar escolta e gravar ponto, checklist, ocorrência e emergência; `anulado_em` no INSERT recusado. Conferi no código: nenhum INSERT em `escoltas` copia linha existente (não há função de duplicar), então o padrão nunca é violado por caminho legítimo |
| Menor 1 | resolvido | plano:548: emergência que vira conflito ou é recusada pela RLS, com vínculo atual ou perdido, tem o aviso agrupado |
| Menor 2 | resolvido em parte | O livro guarda o código e a tela lê por `listar_conflitos` (DEFINER). O L4 não confere que a linha da arquivada mostra o código, como a rodada 8 pediu (ver menor 4) |
| Menor 3 | resolvido | plano:643: `escolta.historico_rpc` na lista da cadeia e teste de `via_rpc = true` |
| Menor 4 | resolvido | S8 (plano:278) com `dump:1350-1359` e `1362-1366`, conferidos no dump; caso do fluxo 1 na 12.6 (plano:462). O pedido de a prévia dizer que nada é anulado na etapa não vivida não entrou, mas isso é detalhe de execução |
| Menor 5 | resolvido | plano:645 com a divisão 2a, 2b e a 219 depois de L, sem contradição |
| Menor 6 | resolvido | plano:550: as listas de colunas da 219 excluem as colunas da 213 |

## Problemas bloqueantes

Nenhum.

## Problemas importantes

Nenhum.

## Problemas menores

1. **`escolta_efetivo_saidas` sem as propriedades que fazem a trigger funcionar.** O plano (plano:548) define as colunas e os eventos, mas não declara:
   - a função da trigger como SECURITY DEFINER. Pela regra 0.5, a tabela nasce com RLS e `REVOKE ALL`. Se a função for INVOKER, um DELETE direto em `escolta_efetivo` por G3 (a `escolta_efetivo_escrita`, dump:4148, continua permitindo) falha inteiro;
   - `escolta_id` sem chave estrangeira, na `escolta_efetivo_saidas` e no `registros_campo`. A trigger roda dentro da cascata de `escoltas` (`escolta_efetivo_escolta_id_fkey ... ON DELETE CASCADE`, dump:3381). Com chave estrangeira sem ação, o DELETE da escolta seria recusado; com CASCADE, a saída e o conflito sumiriam junto, e o caso `escolta_apagada` do L7 deixaria de existir.
   
   Os testes do L7 provavelmente pegariam os dois casos, mas convém escrever. A reversão da 219 também precisa listar a trigger e a tabela.
2. **Aviso agrupado de emergência sem mecanismo de envio.** "Os seguintes ... somados num único aviso a cada 10 minutos" (plano:548) e o L7 espera "1 aviso imediato e 1 agrupado" para 10 emergências seguidas. Se o agrupado só sair na próxima chamada depois da janela, as 9 emergências seguintes nunca viram aviso quando o aparelho para de enviar. Declarar quem fecha a janela (por exemplo, o cron de minuto da 212, que já roda) e onde ficam as contagens pendentes.
3. **`SEM_VINCULO` ainda alcança registro legítimo da gestão.** Pela onda I, G4 fora da equipe pode registrar no campo. Se um gestor, supervisor ou central fora do efetivo registra offline numa escolta agendada (o wizard parte de `agendada`) e outra pessoa a arquiva, o `FOR UPDATE` não acha a linha (RESTRICTIVE da 214.6), ele não está em `escolta_efetivo_saidas`, e o registro recebe `SEM_VINCULO`, fora da tela de conflitos. Isso contraria a premissa "um aparelho legítimo nunca está nesse caso" e, se a gestão usar o offline, o critério 10 do adendo ("nenhum registro some sem aparecer na lista de conflitos"). Correção simples: no livro, perfil G4 com escolta arquivada ou inexistente vira conflito, não `SEM_VINCULO`. G4 já pode criar emergência em qualquer escolta (`emergencias_all`), então isso não abre abuso. A alternativa é declarar na 16.1 que a fila é só do perfil operador.
4. **Motivo da arquivada: texto em conflito com o L4, e o aparelho fica sabendo do arquivamento.** A 16.2 grava `arquivada` (plano:548), e o L4 (plano:590) ainda espera `sem_acesso` para a escolta arquivada. O operador lê o próprio livro (SELECT o próprio), então passa a saber que a escolta foi arquivada. A rodada 8 tinha visto como vantagem juntar os dois motivos. Escolher uma forma, por exemplo `sem_acesso` para o operador e o motivo detalhado só pela `listar_conflitos`, e alinhar o L4. O mesmo L4 deve conferir que a linha da arquivada mostra o código (resto do menor 2 da rodada 8).
5. **`SEM_VINCULO` no aparelho sem plano nem teste.** A 16.2 diz que o aparelho "marca o registro como recusado e o mostra ao operador", mas a 16.3.2 (`envio.ts`) só trata sucesso e falha de rede, e nenhum teste de L1 a L9 cobre o caso no aparelho. Incluir o estado `recusado` na fila (para de reenviar e não expira com os recibos de 7 dias), a exibição no Painel e um passo no L4 ou no L7 pelo Playwright.
6. **Decisão 1 do adendo ("arquivar, nunca apagar") sem plano no servidor.** Hoje nenhuma tela apaga escolta (conferido no código), mas a policy `escoltas_delete` (dump:4194) deixa G2 apagar em qualquer status pela API. A cascata leva histórico, emergências, ocorrências, presenças e, pelas viaturas, pontos e checklists (dump:3165-3613), e a decisão 1 pede justamente "fotos, pontos e auditoria preservados". O plano não cita essa policy e agora trata a exclusão como caso normal (`escolta_apagada` no L7). Recomendo `DROP POLICY escoltas_delete`, ou restringir ao administrador em rascunho sem registro de campo, na 213 ou na 214 (compatível com a master, que não apaga escolta), com o teste "gestor DELETE em escolta recusado" na 12.6. O caso `escolta_apagada` da L fica só como defesa.

## Observações

- A leitura final das seções 9 a 18 contra o adendo cobre todos os itens: G (4.1, tarefas 1 a 5), J (4.2, 1 a 6), I (4.3, 1 a 9), H (4.4, 1 a 6; o Modo Guiado só tem texto genérico de KM em `lib/proximo-passo-operador.ts:52`, sem mudança necessária), K (4.5, 1 a 5), D (4.6, 1 a 5), L (4.7, 1 a 10), as mudanças da regra 1.10 (regra 0.7), a ordem (desvio declarado na 18.1), a confirmação única (18.5) e o registro e o ClickUp (18.6). O único ponto sem plano no servidor é o menor 6.
- Hoje 26 chaves estrangeiras para `usuarios` usam `ON DELETE SET NULL`, e `usuarios/page.tsx:457` apaga usuário. Se `anulado_por` e `arquivada_por` seguirem esse padrão, apagar um usuário que anulou ou arquivou algo dispara um UPDATE em cascata, e a trava BEFORE UPDATE da 213.6 o recusa. Na prática, isso já acontece hoje com quem tem pontos ou ocorrências (`lancado_por` e `registrado_por` sem ação), e preservar o autor é desejável. Mesmo assim, vale declarar a chave estrangeira dessas colunas sem ação (ou sem chave), para o erro ser o da chave e não o da trava.
- `SEM_VINCULO` dá a mesma resposta para escolta inexistente e para escolta alheia. Assim a função não serve para descobrir se uma escolta existe, e convém manter isso na execução.
