# Crítica adversarial do plano, rodada 3

Objeto: `/opt/operacao/escolta-armada/docs/14 - Plano Lote 2026-10.md` (rodada 3, 262 linhas). Revisor independente, somente leitura, em 08/10/2026 (Brasília). Conferido de novo contra o comando do lote, a nota de 03/10, o dump de produção ("dump:N") e o código. `plano:N` é a linha do `docs/14`.

## Nota: 8 de 10

Os 19 itens da rodada 2 foram tratados, e conferi que as correções resolvem o que prometem:
- rascunho antecipado declarado (plano:8);
- extensões criadas pela 202, com registro quando falham (plano:93);
- fallback da onda F para `/api/telegram` (plano:214);
- teste real de aviso no portão de produção (plano:93);
- T6 em `devolver_escolta` e `incluir_vigilante_na_minha_escolta` (plano:102);
- retirada de onda por `git revert`, com todos os portões repetidos (plano:244);
- regra nova da 200, mais ampla, com teste da chave anon e de uma policy plantada (plano:28 e plano:45);
- `mural_travas_ativas` para a janela entre o deploy e o bloco 2 (plano:103);
- raio de 100 m no rótulo (plano:160);
- endereço da Sede com o texto do Bruno (plano:152);
- desvios declarados;
- tipos de evento do pedido e da decisão (plano:95);
- indicador de substituições escondido da central (plano:121);
- escape de HTML no texto do Telegram (plano:93).

Sobra 1 problema importante. Ele está numa regra de decisão que a própria correção criou: se o envio pelo banco não estiver ativo em produção, o portão da onda C reprova e a onda inteira do mural é revertida, mesmo com as travas funcionando. Os demais problemas são menores. Com o item 1 resolvido, o plano fica em condição de nota 9.

## Problemas

### Importante

**1. A onda C não tem fallback de Telegram e fica refém do Vault e do `pg_net`.**
Evidência: o plano:93 exige, no portão de produção de C e de F, que "um aviso de teste real ... chega ao chat central antes de dar a onda como publicada". O fallback para `/api/telegram` existe só na onda F (plano:214). Os avisos de C (pedido em T3, substituição em T4, plano:101 e plano:107) só saem pela fila. Se `envio_pelo_banco = false` (extensão recusada), se faltar o segredo no Vault ou se o token colado estiver errado, o portão de C reprova. Pela seção 4.6 do comando, isso obriga a reverter o merge e a migration da onda. O resultado seria a demanda principal do lote, a trava do mural, voltar atrás por um problema de infraestrutura do Telegram, com T1, T2, T3, T5, T6 e T7 funcionando. Se o portão for relaxado sem regra escrita, T3 e T4 ficam mudos no Telegram e ninguém fica sabendo.
Correção: escrever a regra de decisão para C. Há dois caminhos:
- (a) com `avisos_pelo_banco_ativos()` falso, os avisos de C também vão por `/api/telegram`, chamados por quem gerou o evento (pedido e aprovação; a liberação por tempo fica só no aplicativo), como na F;
- (b) C publica, e o aviso de C no Telegram vira pendência declarada no relatório de prontidão, com o aviso no aplicativo funcionando.

Nos dois casos, o portão de C confere o Telegram só quando o envio pelo banco estiver ativo, e o relatório diz qual caminho valeu.

### Menores

**2. Policy de leitura que não cita o bucket escapa da 200.** A regra do plano:28 só apaga a SELECT "cujo predicado mencione o bucket `fotos`". Uma policy de SELECT sem filtro de bucket (`USING (true)`, ou só `auth.role() = 'authenticated'`, ou `TO public`) alcança todos os buckets, inclusive `fotos`, e sobrevive. Com `anon` ou `public` entre os papéis, a chave anon baixa as fotos. O teste com a chave anon em produção (plano:45) pegaria o caso, mas só depois de publicado. Correção: tratar também como alcançando `fotos` toda policy de SELECT ou ALL em `storage.objects` sem `bucket_id` no predicado. A 200 aborta (ALL) ou guarda e apaga (SELECT), e o teste planta também uma `USING (true)`.

**3. O token do Telegram no SQL Editor.** O plano:93 e o plano:251 pedem ao Peçanha que cole o token no SQL Editor. O Supabase guarda o histórico e os trechos de SQL do editor, então o token ficaria gravado em texto claro fora do Vault (regra 1.9). Correção: criar o segredo pela tela do Vault no painel do Supabase, ou rodar `vault.create_secret` num trecho apagado logo depois, e dizer isso no roteiro. O token também vai na URL do `net.http_post` (`/bot<token>/sendMessage`). Conferir no portão do banco que nem os registros de erro do `pg_net` nem `conferir_avisos_telegram` gravam a URL em `avisos_telegram.erro`.

**4. Roteiro de push e retirada de onda não combinam.** O plano:252 empurra uma branch por onda (`melhoria/...-onda-X:master`), porque elas estão empilhadas. Com "publicar sem X", a publicação passa a ser uma branch única (plano:244), e o roteiro não diz o que o Peçanha empurra nesse caso nem como ficam os portões de produção por onda. Acrescentar o formato desse caso. Lembrar também que o push falha se a master tiver andado desde 2b3fff9, e o que fazer então.

**5. Teste da T6 nas RPCs do comandante.** A regra entrou (plano:102), mas falta a linha na tabela do plano:128: "comandante não devolve nem inclui em escala fixa; gestão sim".

**6. Texto da 197 desatualizado.** O plano:25 ainda diz "UPDATE só com `usuario_dest_id` inalterado", o que a policy não verifica. O plano:110 já explica o comportamento real. Alinhar o plano:25.

**7. Numeração.** O item "10" aparece entre o 1 e o 2 da seção 0 (plano:8) e entre o 2 e o 3 da seção 3.2 (plano:103). Renumerar, porque o relatório e os commits citam esses números.

**8. Erro de envio sem aviso.** Depois do teste inicial, um token revogado ou um chat errado deixa os avisos em `erro` em silêncio. `avisos_pelo_banco_ativos()` só confere se as peças existem, não se a entrega funciona. Sugestão: mostrar na tela Substituições a contagem de avisos em `erro` nas últimas 24 h, ou incluir isso no daily log.

## Conferido e mantido

1. As correções das rodadas 1 e 2 continuam coerentes com o dump: as triggers de `escoltas` (dump:2998 a dump:3096), o `assumir_escolta` de produção (dump:40), `notificacoes` (dump:1969 e dump:4312) e as FKs de `escolta_veiculos` (dump:3573).
2. `p_data_hora_prevista` na RPC de etapa (plano:206) resolve o reagendamento sem dar nada novo ao operador, que continua barrado pela trigger e pela RLS.
3. `mural_travas_ativas` fecha de fato a janela em que a `assumir_escolta` antiga trocaria a equipe na hora. Abas antigas, depois do bloco 2, mandam motivo de 5 caracteres e recebem recusa, o que é seguro.
4. A semente com os mesmos ids da 199 (plano:27) e o desvio declarado do push (plano:252) resolvem os itens 10 e 19 da rodada 2.
