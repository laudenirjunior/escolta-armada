# Crítica adversarial do plano, rodada 2

Objeto: `/opt/operacao/escolta-armada/docs/14 - Plano Lote 2026-10.md` (rodada 2, 259 linhas). Revisor independente, somente leitura, em 08/10/2026 (Brasília).
Conferido de novo contra o comando do lote, a nota de 03/10, o dump `database/esquema-producao-2026-10-08.sql` ("dump:N"), o código e os arquivos já criados na branch (`database/migrations/196` a `200`, `lib/fotos-url.ts`). `plano:N` é a linha do `docs/14`.

## Nota: 7 de 10

A rodada 2 resolveu de fato os dois bloqueantes e a maior parte dos importantes da rodada 1:
- a função interna ficou sem GRANT e tem teste de chamada direta (plano:105, plano:137);
- o backup da periodicidade foi para outro schema, sem tocar em `metadados` (plano:63);
- "Estou na base" entrou no mural (plano:114);
- as travas seguem ordem fixa, primeiro a escolta e depois o pedido, com `UPDATE ... WHERE status = 'pendente'` (plano:104);
- a liberação e o envio passaram para `pg_cron` (plano:92 e plano:106);
- o ponto entrou na RPC atômica (plano:204);
- foi criada a regra de rótulo para a M1 (plano:158);
- a 200 aborta diante de policy `FOR ALL` (plano:27);
- os backups ficam fora de `public` (plano:11);
- há blocos de DDL (plano:244-252), varredura do histórico do Git (`docs/13` 0.4) e tabelas de critérios de aceite.

Não encontrei bloqueante. As correções, porém, abriram 6 problemas importantes: duas afirmações do plano não se sustentam no código (cherry-pick por onda e a janela entre deploy e bloco 2), a nova dependência de `pg_cron`, `pg_net` e Vault não foi conferida em produção e pode silenciar o Telegram que hoje funciona, e T6 tem um furo. Há também uma questão de processo: a execução da onda A começou antes de o portão do plano passar.

## Problemas

### Importantes

**1. Dependência nova de `pg_cron`, `pg_net` e Vault sem conferência em produção e sem `CREATE EXTENSION`.**
Evidência: plano:92 baseia T3, T4 e a onda F inteira no banco (`net.http_post`, `vault.decrypted_secrets`, `pg_cron`). Os "fatos novos" confirmam as extensões só no Supabase local. O plano não diz se a 202 cria as extensões (`CREATE EXTENSION IF NOT EXISTS pg_cron` e `pg_net`, com o schema certo do Supabase hospedado) nem traz uma consulta de conferência em produção (`select extname, extversion from pg_extension`). Também não diz o que acontece se a criação for recusada.
Correção: acrescentar a consulta ao passo 1 da publicação (plano:248), junto com a das policies de `storage`, e pôr o `CREATE EXTENSION` com o schema certo na 202. Regra de decisão: sem `pg_cron`, a liberação segue só pelas consultas (o comando aceita) e T4 vira pendência declarada. Sem `pg_net`, a onda F não publica a troca dos providers (ver o item 2).

**2. A onda F pode calar o Telegram de presença e de check-in, que hoje funciona.**
Evidência: plano:212 tira dos providers a chamada a `/api/telegram` e passa a só enfileirar. Pelo plano:92, "Sem o segredo no Vault, as funções não enviam e os avisos ficam `pendente`", e o segredo depende de o Peçanha colar o token no SQL Editor (plano:249). Se o código de F entrar antes do segredo, ou se `pg_net` falhar, as presenças deixam de ir ao Telegram sem erro visível. Hoje vão, ainda que em dobro (H12). É regressão funcional.
Correção: o portão de produção de F inclui um envio real de teste pela fila (um aviso QA ao chat central, conferido como `enviado`) antes de considerar F publicada. Sem segredo ou sem `pg_net`, F sai do pacote ou os providers mantêm o caminho antigo. Incluir no relatório que o token passa a existir em dois lugares (Vercel e Vault), e que uma rotação precisa atualizar os dois.

**3. T6 pode ser contornada por `devolver_escolta` e `incluir_vigilante_na_minha_escolta`.**
Evidência: o comando (T6) diz que a escolta de escala fixa "só muda pela gestão". No plano:101, `devolver_escolta` e `incluir_vigilante_na_minha_escolta` mantêm "regra atual mais auditoria", e a regra atual deixa o comandante devolver ou incluir. O comandante de uma escala fixa devolve, e a escolta fica sem equipe. O `puxar` recusa por T6, mas a escala da gestão já foi desfeita. O comandante também inclui quem quiser numa escala fixa.
Correção: as duas RPCs recusam escala fixa para quem não é G4. Teste na tabela do plano:126: "comandante não devolve nem inclui em escala fixa".

**4. O cherry-pick por onda não é limpo como o plano afirma.**
Evidência: plano:7 ("Commits de cada onda só tocam os arquivos da onda") e plano:242. Vários arquivos são compartilhados entre ondas:
- `app/dashboard/escoltas/nova/page.tsx`: B (periodicidade, plano:69), C (escala fixa, plano:118), D (atalhos e pino, plano:156) e E (preservar o financeiro, plano:186);
- `app/dashboard/escoltas/[id]/page.tsx`: A, B, D, E e F;
- `app/dashboard/campo/page.tsx`: A e F;
- impressão: A e D.

F usa `lib/rotulo-ponto.ts`, criado por D (plano:213), e a tabela do plano:238 diz que F funciona "sem D" sem dizer qual código troca. Publicar sem uma onda exige resolver conflitos à mão, ou seja, código que nenhum portão viu. O plano:242 só repete os portões de código.
Correção: corrigir a afirmação e listar os arquivos compartilhados. Na branch de publicação, repetir também o portão funcional (Playwright das telas compartilhadas) e o portão do banco com o pacote reduzido, não só type-check, lint e build. Dizer explicitamente como F fica sem D: chamada condicional ao rótulo, ou F só grava o endereço e a exibição fica como hoje.

**5. A migration 200 só reconhece a policy ampla escrita exatamente como `bucket_id = 'fotos'`, e o teste de leitura anônima não mede o que importa.**
Evidência: `database/migrations/200_fechar_bucket_fotos.sql:32-50` compara o `qual` normalizado com `bucket_id='fotos'`. Uma SELECT ampla com outro texto, como o modelo comum do Supabase `bucket_id = 'fotos' AND auth.role() = 'authenticated'`, ou uma policy `TO public` com recorte de pasta, não é apagada nem faz a migration abortar. Com policy de SELECT para `public` ou `anon`, a chave anon, que é pública, baixa a foto por `/object/fotos/...` mesmo com o bucket privado. O teste do plano:44 só tenta a URL pública, que falha em qualquer bucket privado, e por isso não detecta esse caso. A regra "policy de INSERT ausente, aborta" (plano:29) não está implementada no arquivo da 200.
Correção: antes de fechar, a 200 lista toda policy de SELECT ou ALL em `storage.objects` que alcance o bucket `fotos` e tenha `anon` ou `public` entre os papéis, e aborta se houver. Implementar a checagem de INSERT. No critério de aceite, acrescentar `storage.from('fotos').download(caminho)` e `createSignedUrl` com a chave anon e sem sessão, esperando recusa.

**6. Execução antes do portão do plano.**
Evidência: na branch já existem `database/migrations/196` a `200` com as reversões, `lib/fotos-url.ts` e alterações em `app/dashboard/escoltas/[id]/page.tsx` e `.../print/page.tsx` (git status de 08/10). O comando (Fase 2, item 3, e seção 4.1) põe o portão do plano, com nota 9 ou mais, antes da Fase 3. O risco é o plano ser ajustado ao código já escrito, e não o contrário.
Correção: registrar no apêndice que esse código é rascunho anterior à aprovação do plano. Depois da nota 9, conferir os arquivos contra o plano final (por exemplo, a 200 ainda sem a checagem de INSERT do item 5) antes de qualquer commit.

### Menores

**7. A janela entre o deploy de C e o bloco 2 não se comporta como o plano diz.** O plano:252 afirma que o mural mostra "Atualização em andamento" ao assumir. Mas `assumir_escolta` existe com a mesma assinatura (dump:40) e só é trocada no bloco 2. Nessa janela, o diálogo novo, que diz "vira pedido", chama a RPC antiga, a troca de equipe é imediata e a resposta vem como `{ok: true}`, não `{status: 'pendente'}`. A mensagem só aparece para as RPCs novas. Correção: o diálogo reconhece o formato antigo da resposta, ou o "Assumir com equipe" fica escondido até `confirmar_presenca_base` existir. Corrigir o texto do plano:252.

**8. `registrar_etapa_escolta` sem parâmetro de data para reagendar.** O plano:210 inclui "cancelar e reagendar", mas o reagendamento grava `data_hora_prevista` e zera `observacao_fechamento` (`app/dashboard/escoltas/[id]/page.tsx:1414-1416`), e a assinatura do plano:204 não tem a data. Deixar o reagendamento fora da RPC ou acrescentar o parâmetro.

**9. Raio de 300 m no rótulo dos pontos.** No relatório impresso ao cliente, que é evidência, um ponto a 290 m do local salvo sai como "Local: JAMEF". O raio é grande para portão ou doca. Sugestão: raio de até 100 m, que também considere `precisao_metros`, com o texto "Próximo a <local>" e a coordenada do GPS mantida na linha.

**10. Testes da 199 na homologação.** A 199 aborta se os ids reais não existirem (plano:26), e o plano:47 fala em "contas fictícias com os mesmos papéis". A semente da homologação precisa criar as duas contas com esses mesmos UUIDs, senão a migration aborta e o portão do banco falha.

**11. Endereço da Sede diferente do informado.** O plano:150 grava "Rua Cândido de Figueiredo, 204". Bruno informou "Rua Cândido Figueiredo, 204" (nota de 03/10, 3.4). Pela regra 1.2, usar o texto informado, ou registrar a fonte da correção.

**12. Coordenada sugerida da decisão 6.** Engenhão, Galeão e Santos Dumont ficam com coordenada nula (plano:150), e a decisão 6 fala em "coordenada sugerida". Faz sentido pela regra 1.2, mas é um desvio da decisão e deve ser declarado como tal no relatório de prontidão.

**13. ESC-2026-0001 e ESC-2026-0007: "nenhuma outra coluna muda" não é exato.** O UPDATE da 201 dispara `tr_escoltas_atualizado_em` (dump:2998) e muda `atualizado_em`. A 203 acrescenta `escala_fixa = false`. As duas coisas são inofensivas, mas o plano:14 deve dizer isso, para o relatório não afirmar algo falso.

**14. Tipo de evento do pedido.** A 203 cria só `substituicao_equipe` (plano:94), mas o pedido também gera aviso no app à supervisão (plano:100), e `notificacoes.tipo_evento_id` é NOT NULL (dump:1973). Criar também o tipo do pedido e o da decisão.

**15. Indicador de substituições para a central.** "Substituições por operador" lê `mural_pedidos` (plano:119), cuja leitura exclui a central (plano:94), e a central vê Indicadores (`lib/permissions.ts:65`). Ela verá zero sem aviso. Esconder a tabela para a central ou servir os números por RPC agregada.

**16. Texto com HTML no Telegram montado no banco.** O plano:92 e o plano:205 não dizem que nomes e motivos (texto livre do operador) são escapados para `parse_mode` HTML. Usar uma função de escape no SQL, como o H13 fez no `/api/telegram`.

**17. Restritiva de UPDATE em `notificacoes`.** O plano:24 diz "usuario_dest_id inalterado", mas uma policy não enxerga OLD. A implementação (`197_escrita_do_operador.sql:104-109`) só exige que o destinatário novo seja o próprio usuário, o que basta para o objetivo. Ajustar o texto do plano. Ainda assim, o destinatário reescreve o `payload` da própria notificação, o que é inofensivo.

**18. Códigos repetidos nas pendências.** No plano:227, "M1, M2, M4, M5" são achados médios do `docs/13`, mas se confundem com as melhorias M1 a M4 da nota de 03/10, que estão sendo entregues. Escrever "achados médios M1, M2, M4, M5 do docs/13".

**19. Publicação pelo celular.** O plano:250 passa o push na master para o Peçanha, que fará 6 pushes, além dos dois blocos SQL e do segredo no Vault. O desvio em relação ao comando (Fase 5.4, "merge ... na ordem" pelo executor) é aceitável, mas deve ser declarado, e o relatório de prontidão deve trazer a sequência exata de comandos e respostas, curta o bastante para o celular.

## Conferido e resolvido

1. Problemas 1, 2, 3, 4, 6, 7, 10, 11, 12 e 13 da rodada 1: resolvidos no texto do plano. O 8 foi resolvido em parte (ver o item 5 acima) e o 9 também (ver o item 4 acima).
2. Problemas menores 14 a 26 da rodada 1: tratados, salvo as ressalvas dos itens 9, 12 e 17 acima.
3. A `REVOKE` de `authenticated` nas funções de trigger (plano:23) não quebra disparo. A evidência é `exigir_ponto_transito_retorno`, que só tem GRANT a `service_role` (dump:4588-4589) e funciona em produção.
4. A 197, a 199 e a 201 batem com o código atual. A edição pela tela Nova só vale para `rascunho` e `agendada` (`nova/page.tsx:426` e `:582`), o que sustenta o desvio declarado do combustível (plano:185).
