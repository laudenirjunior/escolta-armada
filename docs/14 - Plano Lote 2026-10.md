# Plano Técnico do Lote 2026-10

Fase 2 do lote de 08/10/2026. Base: `docs/13 - Analise Completa 2026-10.md`. Decisões de Peçanha de 08/10/2026 10h48 (comando do lote, seção 2). Rodada 4, revisada depois das críticas das rodadas 1 (nota 5), 2 (nota 7) e 3 (nota 8). As rodadas e as notas estão no apêndice; as críticas completas, em `docs/14-rodadas/`. Parte 2 (seções 9 a 18): adendo 01 de 08/10/2026 15h52, com as ondas G, J, I, H, K, L e os acréscimos da D, que passa de novo pelo portão do plano (rodada 5, nota 6; rodada 6, nota 7; rodada 7, nota 8; rodada 8, nota 8; rodada 9, nota 9, aprovado no portão, com os menores da rodada 9 incorporados na seção 18.8).

## 0. Regras que valem para todas as ondas

1. Uma branch por onda, cada uma partindo da anterior: `melhoria/2026-10-onda-a-seguranca`, `-onda-b-checkin`, `-onda-c-mural`, `-onda-d-locais`, `-onda-e-combustivel`, `-onda-f-divida`. Arquivos compartilhados entre ondas (Nova, detalhe, Campo) recebem commits separados por onda, com mensagem que diz a onda, para permitir retirar uma onda por `git revert` (seção 8). Nenhum merge na master antes do "publicar".
2. Migrations em `database/migrations`, a partir de 196, idempotentes, com cabeçalho do porquê e reversão `NNN_..._reverter.sql`. Portão do banco por migration: `testar-migration.sh` aplica, reaplica (idempotência), reverte, compara o esquema (pg_dump de `public` e `storage`) com o anterior e reaplica.
3. SECURITY DEFINER: guarda `v_perfil IS NULL OR v_perfil NOT IN (...)` quando houver restrição de perfil; `REVOKE ALL ... FROM PUBLIC, anon`; `GRANT EXECUTE ... TO authenticated` só para RPC chamada pelo cliente; funções internas sem GRANT a ninguém; `SET search_path TO 'public', 'pg_temp'` (mais `extensions` ou `net` quando usar). Funções que gravam são VOLATILE.
4. Toda escrita nova no cliente confere linhas afetadas com `.select('id')`. Toda view nova com `security_invoker = on`.
5. Backups de reversão ficam no schema `backup_20261008` (não exposto pelo PostgREST, `REVOKE ALL` de `anon` e `authenticated`), como no backup de 19/08. Tabelas novas em `public` nascem com RLS ligada; as que só RPC acessa ficam sem policy e com `REVOKE ALL` de `anon` e `authenticated`.
6. Horário em mensagens geradas pelo banco: `to_char(x AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')`.
7. Proibido neste lote (regra 1.10): Caminho 2 (um escritor por etapa em `lib/etapas.ts`), gravações só na primeira viatura, fila offline, cache no service worker, migração de paleta, decomposição de `app/dashboard/escoltas/[id]/page.tsx`. Mudança na tela de detalhe só o mínimo, listado por onda. Mudanças do adendo 01: KM inicial e foto do painel por viatura liberados (onda H; o resto das gravações da primeira viatura continua proibido); fila offline e cache no service worker liberados com o escopo da decisão 7 (onda L); a decomposição continua proibida. "Migração de paleta" é a paleta visual do app; a paleta fechada de cores de cliente da onda K não a altera.
8. ESC-2026-0001 e ESC-2026-0007: só a periodicidade é zerada (onda B), com backup fora da escolta. Mudam também, de forma automática e sem efeito de negócio, `atualizado_em` (trigger existente, no UPDATE da periodicidade) e a coluna nova `escala_fixa`, que nasce `false` em todas as escoltas. Status, histórico, equipe, pontos e `metadados` não mudam. As ondas do adendo também não as alteram: a carga de UF da 216 as exclui, as colunas novas da 213 e da 216 nascem com valor padrão (a coluna gerada `interestadual` reescreve a tabela inteira por dentro, mas sem disparar trigger e sem mudar `atualizado_em` nem nenhum valor existente), e a carga da 215 só lê as escoltas.
9. Testes: SQL em `database/testes/04_lote_2026_10_*.sql` (impersonação por `request.jwt.claims`, cada teste limpa o que cria) e ponta a ponta com Playwright (scripts em `/opt/operacao/escolta-homolog/e2e`, evidências em `.../evidencias/<onda>`), contra o Supabase local da VPS, com usuários `QA ` por perfil. A tabela de critérios de aceite de cada onda diz o teste e o que só pode ser conferido em produção.
10. Rascunho antecipado: as migrations 196 a 200, `lib/fotos-url.ts` e as trocas de URL em detalhe, impressão, Campo, notificações, provider, clientes, PDF, rota do Telegram, mapa e `telegram-test` foram escritos durante as rodadas 1 e 2, antes de o plano passar no portão (desvio da ordem do comando, registrado). Ficam sem commit até o plano passar; depois são conferidos item a item contra a versão final e só então entram na branch da onda A.

## 1. Onda A: segurança urgente

### 1.1 Migrations

| # | Arquivo | Conteúdo | Bloco |
|---|---|---|---|
| 196 | `196_identidade_e_higiene.sql` | `perfil_usuario_atual` e `sou_do_efetivo` passam a exigir `usuarios.status = 'ativo'` (H1); `sou_do_efetivo_veiculo` herda. `search_path` com `pg_temp` em `cadastrar_operador`, `criar_usuario_completo`, `excluir_auth_usuario`, `perfil_usuario_atual` (B2). `REVOKE ALL FROM PUBLIC, anon, authenticated` nas 12 funções de trigger (B1); trigger dispara sem EXECUTE de quem faz o UPDATE. `REVOKE ALL ON vw_operador_sem_vinculo FROM anon, authenticated` (B3). Antes de aplicar: consulta de conferência das pessoas do efetivo de escoltas abertas com `usuarios.status <> 'ativo'` (perdem acesso na hora; no backup de 08/10: 0). `vigilantes.status` não entra na regra: os 11 vínculos de 08/10 estão ativo/ativo, e incluir o status do vigilante muda a semântica de cadastro (pendência) | 1 |
| 197 | `197_escrita_do_operador.sql` | (a) `impedir_edicao_por_operador`: mantém as travas de produção e acrescenta, para quem não é G4, proibição de alterar `valor_cobrado`, `outros_custos`, `observacao_financeira`, `fluxo_versao`, `checklist_pendente_no_inicio`, `periodicidade_checkin_min`, `codigo_escolta`, `criada_por`, `escala_fixa` (por `to_jsonb`, vale antes de a coluna existir) e de mudar `status` para `cancelada` (H2). Depende da ordem alfabética das BEFORE UPDATE: `tr_impedir_edicao_por_operador` roda antes de `tr_verificar_checklist_pendente`, que grava `checklist_pendente_no_inicio`; comentário no código e teste "operador inicia escolta com checklist pendente". (b) Policies `AS RESTRICTIVE FOR DELETE` exigindo G4 em `emergencias`, `presencas`, `rastreamento`, `atualizacoes_status`, `checklists`, `checklist_respostas`, `escolta_veiculos` (H3). (c) `DROP POLICY logs_auditoria_insert`; restritivas em `notificacoes`: INSERT só G4; UPDATE só em linha do próprio usuário, e a linha resultante continua sendo dele (`usuario_dest_id` igual ao próprio usuário), ou por G4 (M3). (d) `impedir_autopromocao`: linha de administrador só por administrador (H4). (e) `redefinir_senha_usuario`: gestor não redefine senha de outro gestor (H4). Revogar sessões do alvo fica pendente | 1 |
| 198 | `198_fotos_leitura_por_escolta.sql` | `escolta_do_caminho(text)` (IMMUTABLE, SECURITY INVOKER, EXECUTE para authenticated porque é avaliada dentro da policy). Policy nova permissiva `fotos_select_por_escolta` em `fotos` (membro do efetivo pela escolta do caminho; cobre fotos 2 a 5, outra viatura e atualização de status) (H8). `fotos_leitura_autenticada` em `storage.objects` FOR SELECT TO authenticated: G4, `logos/%`, efetivo da escolta do caminho ou autor da foto. Aditiva | 1 |
| 199 | `199_troca_senha_obrigatoria.sql` | `troca_senha_obrigatoria = true` nas contas de ids `9b0c6047-d9eb-42a5-b980-d87ef7b5f611` (Douglas, administrador) e `130db52b-c966-44d9-aa35-622e24eb953c` (Bruno, gestor), lidos do backup de 08/10, só se ainda estiverem com `false`; aborta se algum id não existir com o perfil esperado. Não lê nem troca senha. Ids alterados registrados em `logs_auditoria` (`lote_2026_10_troca_senha`) para a reversão. Hoje: Douglas já está marcado, Bruno não. Na homologação, a semente cria contas fictícias com esses mesmos ids, para a migration rodar igual à de produção | 1 |
| 200 | `200_fechar_bucket_fotos.sql` | Regra: depois da 200, a única policy de leitura do bucket `fotos` é a `fotos_leitura_autenticada`. Uma policy "alcança `fotos`" quando o predicado menciona o bucket `fotos` ou não filtra `bucket_id` nenhum (por exemplo `USING (true)` ou só `auth.role()`). (1) Aborta sem mudar nada se houver policy `FOR ALL` em `storage.objects` que alcance `fotos` (pode ser a que libera o upload) ou se não houver nenhuma policy de INSERT que alcance o bucket (o upload já estaria quebrado). (2) Toda outra policy `FOR SELECT` que alcance `fotos` (qualquer escrita, qualquer papel, inclusive `anon` e `public`) é guardada em `backup_20261008.policies_storage` e apagada. (3) `storage.buckets.public = false` | 2 (depois do deploy) |

Regra de decisão sobre a consulta de policies de `storage` feita na publicação: só policies de SELECT e de INSERT, segue; policy ALL que mencione `fotos`, a 200 aborta e o fechamento vira pendência da onda A (as fotos continuam funcionando por URL assinada com o bucket ainda público); sem policy de INSERT, aborta e investiga.

### 1.2 Código

1. `lib/fotos-url.ts`: `caminhoDoArquivo` (caminho puro ou URL pública antiga do bucket), `urlsAssinadas` (uma chamada `createSignedUrls` por tela), `urlDoMapa`, `urlAssinada`. Validade: 1 hora nas telas e no Telegram, 2 horas na impressão.
2. Troca de `getPublicUrl` nos 7 grupos do `docs/13` 3.1: detalhe `:897` (`getFotoUrl` passa a ler um mapa assinado em lote, montado logo depois de `fotoPathMap`; mudança local) e `:1913`; impressão `:224`, `:260`; Campo `:1201`, `:1390`, `:1503`; notificações `:177`; `components/telegram-notificacoes-provider.tsx:37`; clientes `:177-182` (passa a gravar o caminho em `logo_url`; leitura por URL assinada, aceitando URL antiga); PDF de relatórios `:625` (logo).
3. Telegram: foto como URL assinada de 1 hora (o Telegram baixa na hora do envio). `/api/telegram`: `foto_url` aceita só o host do Supabase do projeto; `descricao` escapada (H13). `texto_completo` segue com HTML do próprio app (pendência).
4. `telegram-test`: só administrador (H14). Mapa: escape do popup (M7). `next.config.mjs`: sem `images.remotePatterns` (C1).
5. Chaves: arquivos atuais e histórico do Git sem chave (`docs/13` 0.4).

### 1.3 Critérios de aceite e testes

| Critério | Teste | Perfil | Evidência |
|---|---|---|---|
| Nenhuma chave real nos arquivos atuais | varredura de padrões (feita) | n/a | `docs/13` 0.4 |
| Leitura anônima do bucket recusada | homologação, depois da 200 e também com duas policies plantadas antes, uma SELECT para `anon` com recorte de pasta e uma `USING (true)` para `public` (a 200 deve apagar as duas): GET anônimo na URL pública dá erro; com a chave anon, `download`, `list` e `createSignedUrl` no bucket falham; produção: os mesmos testes com a chave anon pública do app, sem escrever dado | anon | log do teste |
| Todas as fotos aparecem para quem tem direito | Playwright com bucket fechado: timeline e galeria do detalhe, impressão (fotos 1 a 5), notificações, Painel Guiado, por operador do efetivo (inclusive outra viatura), supervisor e administrador; operador de fora não recebe URL | operador, supervisor, administrador | capturas |
| Upload continua com bucket fechado | Playwright: foto pelo Campo e pelo detalhe depois da 200 | operador | capturas |
| Douglas e Bruno obrigados a trocar a senha | homologação: contas fictícias com os mesmos papéis; produção: consulta de conferência da 199 | n/a | resultado da consulta |
| Operador não altera financeiro, fluxo, periodicidade nem cancela pela API; não apaga evidência | SQL `04_lote_2026_10_a.sql` como operador QA | operador | PASSOU/BLOQUEADO |
| Fluxo legítimo do operador intacto | Playwright: pré-início com checklist pendente, etapas, finalização | operador | capturas |
| Bloqueado perde acesso | SQL: operador bloqueado não lê a escolta | operador | PASSOU |
| Gestor não mexe em administrador nem redefine senha de gestor | SQL | gestor | BLOQUEADO |

### 1.4 Efeito por perfil, telas, riscos e reversão

Operador: mesmas fotos, por URL assinada, mais as fotos 2 a 5 dos colegas; perde caminhos de API que a tela não oferecia; bloqueado perde acesso. Supervisor e central: igual. Gestor: não mexe mais em administrador nem na senha de outro gestor. Anônimo: não lê foto depois da 200. Modo Guiado: só a URL da foto do Telegram. Detalhe: `getFotoUrl` e `notificarTelegram`. Mapa: escape do popup. Telegram: foto por URL assinada. Indicadores: nada. Relatórios e PDF: logo assinada; impressão com fotos assinadas. Dados: só `troca_senha_obrigatoria` de Bruno.

Riscos: (1) fechar o bucket antes do código novo quebra as fotos: a 200 é do bloco 2, depois do deploy e do portão; reversão reabre na hora. (2) Abas abertas com o código antigo mostram foto quebrada até recarregar: publicar fora de horário de escolta em rua e pedir no comunicado que recarreguem o aplicativo. (3) Restritivas de DELETE: o app não apaga essas tabelas pelo operador. Reversão: `_reverter.sql` de cada migration (corpos da 195), `git revert`.

## 2. Onda B: M4, check-in periódico

### 2.1 Migration 201 (`201_checkin_desligado.sql`, bloco 1)

1. `backup_20261008.periodicidade_checkin (escolta_id, periodicidade_checkin_min, gravado_em)` recebe as escoltas abertas com periodicidade preenchida; depois `UPDATE escoltas SET periodicidade_checkin_min = NULL` só nelas (8 em 08/10, inclusive ESC-2026-0001 e ESC-2026-0007, só esse campo; `metadados` não é tocado). A reversão devolve a partir do backup.
2. `alertas_dispensados (usuario_id, escolta_id, tipo, assinatura, dispensado_em)`, chave (usuario_id, escolta_id, tipo), RLS: cada um lê e grava só as próprias linhas.

### 2.2 Código

1. `lib/checkin.ts`: `periodicidadePadraoDoCliente(cliente)` lê `clientes.metadados.checkin_periodico_min`. Religar por cliente = preencher essa chave no cadastro do cliente (sem migration).
2. Nova: padrão `null`; campo escondido para todos os perfis, salvo cliente com a chave; edição mantém nulo (H11).
3. `components/checkin-alert-provider.tsx`: o X grava em `alertas_dispensados` a assinatura `status | referência do prazo | periodicidade`; o aviso só volta com mudança real (novo check-in, novo status, nova periodicidade). Trava visual separada do Telegram.
4. Detalhe: o "Alterar" da periodicidade só aparece com periodicidade já preenchida ou cliente com a chave (única mudança no detalhe).
5. Indicadores: "Check-ins Realizados" conta só `reporte_periodico` (M9). `docs/09`.

### 2.3 Critérios de aceite e testes

| Critério | Teste | Perfil |
|---|---|---|
| Nenhuma escolta nova nasce com periodicidade | Playwright: criar escolta, conferir no banco `periodicidade_checkin_min IS NULL`; editar escolta e conferir que continua nula | gestor |
| Nenhum aviso para escoltas abertas | SQL depois da 201: 0 abertas com periodicidade; Playwright: nenhum aviso no painel do supervisor | supervisor |
| Fechar um aviso não o faz voltar sozinho | escolta QA com periodicidade religada e atraso; fechar o X; recarregar e esperar dois ciclos de 60 s; aviso não volta; novo status faz voltar | supervisor |
| Fotos por etapa continuam obrigatórias | Playwright: avançar etapa sem foto é recusado | operador |
| Religar por cliente | cliente QA com `checkin_periodico_min = 30` mostra o campo com 30 | gestor |

### 2.4 Efeito, riscos e reversão

Operador: alerta e Próxima Ação de check-in somem; "Registrar Check-in" em Outras Ações continua. Gestão: campo some; alerta some. Cliente no Telegram: deixa de receber o alerta. Modo Guiado: sem passo de check-in com periodicidade nula. Detalhe: botão "Alterar" condicionado. Mapa, relatórios e PDF: nada. Risco baixo. Reversão: `201_..._reverter.sql` devolve a periodicidade do backup e apaga `alertas_dispensados`.

## 3. Onda C: M5, travas do mural

### 3.1 Estrutura

Migration `202_avisos_telegram.sql` (bloco 1, neutra, compartilhada com a onda F): `avisos_telegram` (fila) com `evento_chave text UNIQUE`, `destino` (`central` ou `cliente`), `escolta_id`, `texto`, `origem_usuario_id`, `criado_em`, `situacao` (`pendente`, `enviando`, `enviado`, `erro`), `enviado_em`, `pg_net_id`, `erro`; RLS ligada sem policy e `REVOKE ALL` de anon e authenticated. `configuracao_avisos` (linha única, sem policy de escrita): `telegram_api_base` (`https://api.telegram.org`, só muda pelo SQL Editor). Função interna `enviar_avisos_telegram()` (sem GRANT): pega até 20 `pendente` com `FOR UPDATE SKIP LOCKED`, marca `enviando`, chama `net.http_post` com o token lido do Vault (`vault.decrypted_secrets`, nome `telegram_bot_token`) e o chat central (`telegram_chat_central`) ou do cliente, e grava `pg_net_id`; função `conferir_avisos_telegram()` lê `net._http_response`, marca `enviado` ou `erro` (sem reenvio automático: no máximo uma mensagem por evento). `pg_cron` roda as duas a cada minuto. A 202 faz `CREATE EXTENSION IF NOT EXISTS pg_cron` e `pg_net` (no Supabase, permitido ao `postgres` do SQL Editor) e confere `vault.decrypted_secrets`; o bloco 1 começa por `select extname from pg_extension` e, se alguma extensão não puder ser criada, a 202 cria a fila mesmo assim e registra `configuracao_avisos.envio_pelo_banco = false`. Textos montados no banco passam por `escapar_html` (função interna). Criar os segredos é ação do Peçanha na publicação, pela tela Vault do painel do Supabase (caminho exato conferido na documentação oficial e posto como link direto do projeto no roteiro de publicação), com os nomes `telegram_bot_token` e `telegram_chat_central` e os valores das variáveis da Vercel; nunca pelo SQL Editor, que guarda o histórico do texto. O token vai na URL do `net.http_post`: `conferir_avisos_telegram` grava em `avisos_telegram.erro` só o código HTTP e a descrição devolvida pelo Telegram, nunca a URL, e o portão do banco confere isso. A partir daí o token existe nos dois lugares, e uma rotação futura atualiza os dois (registrado no `docs/07`). RPC `avisos_pelo_banco_ativos()` (authenticated, devolve só verdadeiro ou falso: extensões, segredo e cron presentes). Regra de decisão do Telegram de C e F: com `avisos_pelo_banco_ativos()` verdadeiro, o portão de produção exige um aviso de teste real ("Teste do lote 2026-10") que sai pela fila e chega ao chat central. Com ela falsa (extensão recusada ou segredo ausente), C e F publicam assim mesmo, porque as travas e o aviso no aplicativo não dependem do Telegram: na F, os providers continuam pelo `/api/telegram` (item 6.2.3); na C, o navegador de quem gerou o evento chama `/api/telegram` com `destino: 'central'` (parâmetro novo, resolvido no servidor para `TELEGRAM_CHAT_ID`, sem `escolta_id` decidindo o chat e sem `texto_completo`; teste com o servidor falso confirma que nada chega ao chat do cliente) nos avisos de pedido, aprovação e recusa, e a liberação por tempo fica só com o aviso no aplicativo; o relatório de prontidão e o de publicação dizem qual caminho valeu. Monitoramento: a tela Substituições mostra a contagem de avisos em `erro` nas últimas 24 h, e o daily log do dia registra essa contagem.

Migration `203_mural_travas_estrutura.sql` (bloco 1): `configuracoes_mural` (linha única: `janela_substituicao_min` 60, `aprovacao_tempo_limite_min` 15, `intervalo_comandante_h` 6, `presenca_ligada` true, `aviso_ligado` true; leitura autenticados, UPDATE só administrador e gestor; auditoria não é parâmetro, é sempre gravada). `escoltas.escala_fixa boolean NOT NULL DEFAULT false`. `mural_presencas` (escolta, vigilante, usuário, quando, GPS, `sem_gps`; única por escolta e vigilante; leitura G4 ou efetivo; escrita só por RPC). `mural_pedidos` (escolta, solicitante, acompanhantes, viatura, motivo com CHECK de 20 caracteres, `equipe_antes`, `status` pendente/aprovado/recusado/liberado_por_tempo/cancelado/invalidado, `criado_em`, `expira_em`, `decidido_por`, `decidido_em`, `observacao_decisao`, `antecedencia_min`; índice único parcial de um pendente por escolta; leitura supervisor, gestor, administrador ou o próprio solicitante; escrita só por RPC). Tipos de evento `pedido_substituicao`, `decisao_substituicao` e `substituicao_equipe` em `dom_tipos_evento`.

### 3.2 RPCs (migration `204_mural_travas_rpcs.sql`, bloco 2, depois do deploy)

Todas SECURITY DEFINER, `search_path` fixo, VOLATILE, `REVOKE` de PUBLIC e anon. Mensagens com hora de Brasília.

1. `assumir_escolta(p_escolta_id, p_acompanhantes, p_veiculo_id, p_motivo)`, mesma assinatura e `SELECT ... FOR UPDATE` da escolta. Ordem: sessão e perfil ativos; vigilante vinculado e ativo; status `agendada`; escala fixa recusa (T6); acompanhantes vigilantes ativos e viatura ativa. Sem equipe: T5 e assume na hora, com auditoria. Com equipe: quem chama não pode estar na equipe; motivo com 20 caracteres (requisito 2); T1 recusa antes de `data_hora_prevista - janela` ("Substituição liberada a partir de HH:MM"); T2 recusa com presença confirmada por alguém da equipe atual; T5; pedido pendente de outro recusa; senão cria pedido (T3), avisa a supervisão no app e enfileira aviso no chat central, e devolve `{status: 'pendente', pedido_id, expira_em}`.
2. `puxar_escolta`: regras de escolta sem equipe (T5, T6) e auditoria. `devolver_escolta` e `incluir_vigilante_na_minha_escolta`: regra atual mais auditoria e, em escolta de escala fixa, só gestão (T6: "só muda pela gestão").
3. `confirmar_presenca_base(p_escolta_id, p_lat, p_lng, p_precisao)` (T2): membro do efetivo, escolta `agendada`, a partir do início da janela; grava quem, quando e GPS (`sem_gps` se faltar).
4. `aprovar_pedido_mural(p_pedido_id, p_observacao)` e `recusar_pedido_mural(p_pedido_id, p_motivo)`: supervisor, gestor ou administrador, que não seja o solicitante. `cancelar_meu_pedido_mural(p_pedido_id)`: o solicitante.
5. Concorrência: toda decisão trava primeiro a escolta e depois o pedido (`FOR UPDATE`, sempre nessa ordem) e muda o status do pedido com `UPDATE ... WHERE status = 'pendente' RETURNING`; só segue se uma linha mudar. Aprovação e liberação simultâneas geram uma só substituição e uma só auditoria.
6. `_executar_substituicao(p_pedido_id, p_via)`: interna, sem GRANT a ninguém (REVOKE de PUBLIC, anon e authenticated). Só é chamada por `aprovar_pedido_mural` e `processar_pedidos_vencidos`, depois da troca de status sob trava. Confere de novo status, escala fixa, presença, equipe igual a `equipe_antes`, T5, vigilante ativo, acompanhantes e viatura; se algo mudou, o pedido vira `invalidado` com o motivo. Senão troca a equipe (na primeira viatura, como hoje; M10 pendente), grava auditoria `substituicao_de_equipe` com o pedido, avisa no app a equipe substituída e a supervisão e enfileira um aviso no chat central com `evento_chave = 'substituicao:' || pedido_id` (T4, uma mensagem por evento).
7. `processar_pedidos_vencidos()`: interna (sem GRANT), roda pelo `pg_cron` a cada minuto e também dentro das consultas abaixo. Libera os pendentes com `expira_em < now()` como `liberado_por_tempo`. Nunca depende do navegador.
8. `consultar_pedido_mural`, `listar_pedidos_mural`: VOLATILE (chamam a liberação), solicitante ou supervisão.
9. `marcar_aviso_lido(p_notificacao_id)`: só o destinatário, só muda `lida`. É o único caminho do app para "Ciente"; a policy restritiva de UPDATE da 197 só garante que a linha, depois do UPDATE, continue sendo do próprio usuário (ou de G4).
10. `mural_travas_ativas()`: devolve verdadeiro. Existe só depois do bloco 2; a tela nova a consulta e, enquanto ela não existir, não oferece "Assumir" em escolta com equipe (mostra "Atualização em andamento"), porque a `assumir_escolta` antiga ainda trocaria a equipe na hora. Puxar escolta livre continua.

T4 no Telegram: não existe chat por pessoa no sistema (`clientes.telegram_chat_id` é por cliente). A equipe substituída recebe pelo aplicativo e vê no chat central; limitação declarada.

### 3.3 Telas

1. Mural (`app/dashboard/escoltas/page.tsx`): "Assumir" só dentro da janela, sem presença, fora de escala fixa; antes, "Substituição a partir de HH:MM". Escala fixa some de Disponíveis para operador. "Estou na base" no card para quem é do efetivo, dentro da janela (T2 no mural). Pedido pendente com contagem e "Cancelar pedido". Avisos do mural no topo.
2. Diálogo: motivo de 20 caracteres; explica que vira pedido e sai sozinho em 15 min sem resposta. Erro de RPC inexistente (minutos entre deploy e bloco 2) vira "Atualização em andamento, tente em instantes".
3. Painel Guiado: "Estou na base" e avisos do mural.
4. `app/dashboard/substituicoes/page.tsx` (supervisor ou acima, item no menu): fila com Aprovar e Recusar; histórico (quem, de quem, quando, antecedência, motivo, aprovado por, liberado por tempo); parâmetros editáveis por gestor e administrador.
5. Edição (Nova, `?editar=`): caixa "Escala fixa" para supervisor ou acima (T6).
6. Indicadores, aba Pessoas: "Substituições por operador" a partir de `mural_pedidos`, mostrada só para supervisor, gestor e administrador (quem lê a tabela pela RLS).
7. `docs/09` e comunicado aos operadores.

### 3.4 Critérios de aceite e testes

SQL `04_lote_2026_10_c.sql` e script de concorrência (dois processos chamando a RPC pelo PostgREST com tokens de dois operadores QA), mais Playwright:

| Teste | Esperado |
|---|---|
| Assumir fora da janela | recusado, com a hora de Brasília |
| Assumir com presença confirmada (pelo mural e pelo Painel Guiado) | recusado |
| Pedido aprovado | equipe trocada, auditoria, aviso no app à equipe e à supervisão, 1 aviso na fila |
| Pedido recusado | equipe intacta, solicitante avisado |
| Pedido liberado por tempo (`expira_em` no passado, `processar_pedidos_vencidos` pelo cron) | equipe trocada como `liberado_por_tempo` |
| Sobreposição de 6 h (puxar e assumir) | recusado |
| Escala fixa | não aparece em Disponíveis; RPC recusa |
| Comandante devolve ou inclui em escala fixa | recusado; gestão consegue |
| Dois operadores ao mesmo tempo | um pedido só; o outro recusado |
| Aprovação e liberação simultâneas | uma substituição, uma auditoria |
| Operador chama `_executar_substituicao` e `processar_pedidos_vencidos` direto | permissão negada |
| Supervisor aprova o próprio pedido | recusado |
| Aviso único no Telegram | 1 linha por evento na fila; servidor falso do Telegram recebe 1 mensagem por evento |
| Auditoria completa | linha em `logs_auditoria` para puxar, assumir, devolver, incluir e substituir |

### 3.5 Efeito, riscos e reversão

Operador: puxa escolta livre como hoje (sem outra como comandante a menos de 6 h); substituir só a partir de 60 min antes, sem presença, com motivo de 20 caracteres, e vira pedido; equipe confirma "Estou na base"; recebe aviso quando é substituído. Supervisor: aprova ou recusa; tela Substituições; escala fixa. Gestor e administrador: também os parâmetros. Central: sem mudança. Telegram: avisos de pedido e de substituição no chat central, enviados pelo banco. Detalhe, mapa, relatórios e PDF: nada. Dados: `escala_fixa = false`. Riscos: operador sem supervisão (a liberação por tempo cobre); mudança de hábito (comunicado antes). Reversão: `204_..._reverter.sql` recria as RPCs de produção (195); `203_..._reverter.sql` guarda `mural_pedidos` e `mural_presencas` em `backup_20261008` e remove a estrutura; `202_..._reverter.sql` desagenda o cron e remove a fila.

## 4. Onda D: M2 e M1, locais salvos e geolocalização

### 4.1 Migration `205_locais_salvos.sql` (bloco 1)

`locais_salvos`: `nome` (único entre os não inativos), `endereco`, `complemento`, `latitude` e `longitude` (podem ser nulas só enquanto `aguardando_conferencia`; CHECK), `situacao` (`ativo`, `inativo`, `aguardando_conferencia`), `fonte_coordenada`, `conferido_por`, `conferido_em`, `criado_por`, `criado_em`, `atualizado_por`, `atualizado_em`. RLS: leitura autenticados (quem não é gestão vê só `ativo`); INSERT e UPDATE supervisor, gestor e administrador; sem DELETE. Trigger: passar para `ativo` exige perfil gestor ou administrador (decisão 6: conferência por Peçanha ou Bruno), grava `conferido_por` e `conferido_em`. Carga inicial `aguardando_conferencia`: JAMEF ("Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti", `-22.799521, -43.347756`, fonte: média de 5 pontos de GPS de campo com precisão até 15 m, `docs/13` 2.4) e Sede ("Rua Cândido Figueiredo, 204, Tanque, Rio de Janeiro", texto de Bruno, `-22.918625, -43.362670`, média de 11 pontos). Engenhão ("Rua das Oficinas, Cachambi, Rio de Janeiro"), Galeão e Santos Dumont com coordenada nula: desvio declarado da decisão 6 ("com coordenada sugerida"), porque não há medida de campo nem fonte citável para elas (regra 1.2); o pino é posto na conferência. CT do Botafogo fora.

### 4.2 Código

1. `components/endereco/atalhos-locais.tsx`: botões acima de origem e destino, só `ativo`; um toque preenche endereço, complemento e coordenada sem chamar a Mapbox.
2. `components/mapa/mapa-pino.tsx`: pino arrastável (mapbox-gl, import dinâmico); sem token, latitude e longitude editáveis e aviso "mapa indisponível".
3. Nova: sugestões com bairro e município em destaque; aviso "endereço sem número, confira no mapa"; mapa com pino abaixo de origem e destino; salvar exige "Conferido no mapa" para coordenada vinda da busca (local salvo ativo dispensa); "Salvar este endereço como local" (supervisor ou acima) cria `aguardando_conferencia`.
4. Tela `app/dashboard/configuracoes/locais/page.tsx` (comando: "tela de cadastro em Configurações"): lista, edição com pino, "Conferir no mapa e ativar" (gestor e administrador), inativar. Item "Locais salvos" no menu para supervisor, gestor e administrador; central lê pelos atalhos.
5. Rótulo dos pontos (critério da M1): `lib/rotulo-ponto.ts`. Ponto a até 100 m de um local salvo ativo mostra "Local: <nome>, <endereço> (a N m)"; senão mostra o rótulo reverso com a marca "aproximado, GPS ±N m". A coordenada continua exibida como está gravada. Usado na timeline do detalhe e na impressão (mudança de exibição de uma linha em cada).
6. API da Mapbox: sem troca (decisão 7; sem medida possível). Tarefa 868m89dv1 vinculada no LOG e no ClickUp.

### 4.3 Critérios de aceite e testes

| Critério | Teste |
|---|---|
| Criar escolta JAMEF para Galeão sem digitar endereço; coordenada igual à do local | Playwright (gestor) com JAMEF e Galeão conferidos e ativos na homologação; consulta no banco |
| Local inativo some dos atalhos | Playwright |
| Operador não cadastra local | SQL como operador QA: INSERT recusado; tela sem menu |
| Supervisor não ativa local; gestor ativa e grava `conferido_por` | SQL |
| Escolta com origem JAMEF exibe São João de Meriti | Playwright: detalhe e impressão |
| Ponto na JAMEF não mostra outro município, ou deixa claro que o rótulo é aproximado | Playwright: ponto QA a 20 m do local JAMEF mostra o local; ponto longe mostra "aproximado" |
| Mapa com pino | sem token na VPS, só o caminho "mapa indisponível" é testável; o pino arrastável é conferido no preview da Vercel, sem gravar escolta, ou na homologação com o Bruno |

### 4.4 Efeito, riscos e reversão

Operador: nenhum cadastro; vê o rótulo novo dos pontos. Supervisor: atalhos e cadastro. Gestor e administrador: também ativação. Central: atalhos. Modo Guiado: nada. Detalhe: uma linha de exibição do rótulo. Mapa, Indicadores, relatórios e PDF: nada (mesmas colunas). Telegram: nada. Risco: passo a mais no formulário. Reversão: `205_..._reverter.sql` guarda os locais em `backup_20261008.locais_salvos` e remove a tabela.

## 5. Onda E: M3, combustível

### 5.1 Migration `206_combustivel.sql` (bloco 1)

Trigger `impedir_combustivel_por_operador` em `escolta_veiculos` (BEFORE UPDATE, SECURITY DEFINER, sem GRANT): quem não é G4 não altera `abastecimento_litros` nem `abastecimento_valor`. (Na execução: os CHECK de não negativo já existiam em produção; a 206 não cria outro.)

### 5.2 Código

1. `components/escolta/combustivel-viaturas.tsx`: por viatura, litros e valor, gravação com `.select('id')`, na aba Financeiro do detalhe (`verFinanceiroDet`), disponível durante a escolta e depois da finalização. Desvio declarado: o comando fala em "seção financeira da edição e do fechamento"; a edição (Nova) só existe para escolta agendada e recria as viaturas, e o diálogo de finalização é aberto ao operador, então a entrada fica na aba Financeiro, que cumpre os dois momentos sem expor o valor ao operador. Mudança no detalhe: um import, uma linha na aba Financeiro e esconder litros e valor na aba Veículos para quem não vê financeiro.
2. Nova (edição): preserva `abastecimento_*` das viaturas que continuam e não grava financeiro quando quem edita não vê a seção (H18, parte financeira).
3. A parada do tipo "Abastecimento" não guarda valor (só ponto PARADA com foto e texto): não há segunda fonte.

### 5.3 Critérios de aceite e testes

Escolta QA com duas viaturas, valores lançados pela aba Financeiro: o resumo financeiro, os Indicadores (Financeiro e Frota) e o PDF mostram a mesma soma, sem duplicar; a impressão não mostra combustível (não mostrava). Operador: não vê os valores e não grava (SQL e Playwright). Central edita escolta sem apagar o financeiro (Playwright).

### 5.4 Efeito, riscos e reversão

Operador: não vê nem grava. Supervisor, gestor, administrador e central: lançam. Modo Guiado e mapa: nada. Detalhe: aba Financeiro e Veículos. Telegram: nada. Indicadores e PDF: passam a mostrar o valor lançado. Reversão: `206_..._reverter.sql` remove trigger e CHECK.

## 6. Onda F: dívida técnica de baixo risco

### 6.1 Migrations

| # | Arquivo | Conteúdo | Bloco |
|---|---|---|---|
| 202 | (compartilhada com C) | fila `avisos_telegram` e envio pelo banco | 1 |
| 207 | `207_etapa_atomica.sql` | `registrar_etapa_escolta(p_escolta_id, p_pontos jsonb, p_status_atual, p_status_novo, p_observacao, p_latitude, p_longitude, p_observacao_fechamento, p_data_hora_prevista)` (a última só para reagendar, que é da gestão pela RLS e pela trigger do operador): SECURITY INVOKER (roda com a RLS de quem chama, sem privilégio novo). Na mesma transação: insere os pontos recebidos (as fotos já foram enviadas; os ids vêm em `foto_id` e `observacoes.foto_ids`), atualiza o status com `WHERE status = p_status_atual` e grava o histórico com autor. Sem linha afetada, erro `ERRO_SEM_TRANSICAO` e nada fica gravado. `p_status_novo` nulo grava só o ponto (comboio: viatura que não é a última). Finalização preenche `data_finalizacao` | 1 |
| 208 | `208_avisos_pelo_servidor.sql` | `enfileirar_alerta_checkin(p_escolta_id)` (regra antiga: só com PARADA; chave por escolta e última PARADA) e `enfileirar_aviso_presenca(p_presenca_id)`, SECURITY DEFINER, guarda: G4 ou efetivo da escolta, texto montado no servidor, GRANT a authenticated | 1 |
| 209 | `209_historico_sem_trigger.sql` | `DROP TRIGGER IF EXISTS tr_registrar_historico_status ON escoltas` (sem efeito em produção; versiona a remoção) | 1 |

### 6.2 Código

1. Detalhe: nas 9 etapas e no avanço genérico, cancelar e reagendar, a sequência "pontos, status, histórico" vira uma chamada a `registrar_etapa_escolta`, com os mesmos dados que `gravarPontosPorViatura` já monta. A finalização passa o checklist de entrega antes, como hoje, e status e histórico juntos. Mudança mecânica nos trechos de gravação, sem reorganizar a tela. Não é o Caminho 2: cada tela continua com o próprio fluxo; só a gravação final fica atômica.
2. Campo `avancarStatus` (usado também pelo Painel Guiado): mesma troca.
3. Providers de check-in e de presença: se `avisos_pelo_banco_ativos()` for verdadeiro, chamam a RPC de enfileirar e o envio é do banco; senão continuam chamando `/api/telegram` como hoje. A onda F não cala o Telegram que funciona hoje enquanto o envio pelo banco não estiver configurado.
4. Campo: check-in grava endereço por extenso (`lib/geocodificacao.ts`, da própria onda F). A exibição usa a regra de rótulo da onda D quando D estiver publicada; sem D, aparece como os demais endereços de hoje.
5. Mapa: a rota (Directions) só é pedida quando muda a escolta selecionada (H15).
6. `docs/03` atualizado.

### 6.3 Critérios de aceite e testes

As 9 etapas pelo detalhe, pelo Campo e pelo Painel Guiado, com duas viaturas (comboio), em Playwright; SQL: transição recusada não deixa ponto nem histórico; check-in pelo Campo grava endereço; alerta e presença geram uma linha na fila mesmo com três sessões abertas; com o envio pelo banco desligado, presença e alerta continuam saindo por `/api/telegram` (servidor falso recebe a mensagem); mapa: contagem de chamadas à Mapbox no log de rede do Playwright em 3 minutos com escolta selecionada.

### 6.4 Efeito, riscos e reversão

Operador e gestão: mesmas telas; o registro de etapa deixa de ficar pela metade. Modo Guiado: mesma coisa. Telegram: alerta de check-in e presença saem uma vez, pelo banco. Mapa: menos chamadas. Indicadores e relatórios: histórico sem buraco. Risco médio no item 1 (trechos de gravação do detalhe): teste das 9 etapas; se não passar em três tentativas, a onda sai do pacote (Fase 4.3). Reversão: `git revert`; as funções novas são aditivas e as reversões as removem.

## 7. Pendências que ficam fora

Achados do `docs/13` que ficam pendentes: H5 (leitura ampla de `usuarios`, decisão), H6 (senhas em texto claro, decisão), H13 parcial (recorte de destino e `texto_completo` do `/api/telegram`), H18 parcial (efetivo pela central), achados médios 1, 2, 4, 5, 10 e 11 da tabela 1.3 do `docs/13`, baixos B4 a B8. Também: revogar sessões ao redefinir senha, `vigilantes.status` na RLS, Next 15 ou superior, rotação da `sb_secret` (pendente desde 10/09).

## 8. Dependências e publicação

### 8.1 Dependências entre ondas

| Onda | Depende de | Arquivos que divide com outras ondas | Pode sair? |
|---|---|---|---|
| A | nada | detalhe, Campo, impressão (URLs) | sim |
| B | nada | Nova, detalhe (botão Alterar), Indicadores | sim |
| C | 202 | Nova (escala fixa), Indicadores, mural | sim; a 202 entra mesmo sem C |
| D | nada | Nova, detalhe e impressão (rótulo) | sim |
| E | nada | Nova (edição), detalhe (aba Financeiro) | sim |
| F | 202 | detalhe, Campo, mapa | sim |

As ondas do adendo (G a L) e as restrições novas sobre C e F estão na tabela da seção 18.4, que prevalece.

Publicar sem uma onda X: branch de publicação a partir da última onda com `git revert` dos commits de X (mais novos primeiro); conflito em arquivo compartilhado é resolvido à mão, mantendo o que as outras ondas fizeram; pacote SQL sem as migrations de X (e sem a 202 só se C e F saírem juntas). Na branch de publicação repetem-se todos os portões: código, banco (banco recriado do zero com o pacote reduzido) e funcional por perfil. Feito por mim antes de qualquer push.

### 8.2 Caminho de DDL e blocos

Os blocos e a sequência de publicação com as ondas do adendo estão na seção 18.2 e 18.5, que prevalecem sobre a lista abaixo: o caminho padrão passou a ser um push único da última branch, e não mais o push onda a onda do item 3.

Não há conexão ao banco de produção configurada na VPS nem token da API de gerenciamento (Fase 0, item 4). O esquema de 08/10 foi exportado pelo Peçanha, no terminal dele, com a connection string digitada por ele. O pacote, portanto, é aplicado pelo Peçanha em dois blocos, cada um com uma resposta:

1. Antes de tudo: backup novo conferido e a consulta das policies de `storage`.
2. Bloco 1 (antes do deploy, tudo compatível com o código atual): 196, 197, 198, 199, 201, 202, 203, 205, 206, 207, 208, 209, mais o segredo do Telegram no Vault. Resposta: "aplicado 1".
3. Push das ondas para a master, uma a uma, pelo Peçanha: desvio declarado do comando ("merge das ondas na ordem" seria meu), porque o controle de permissões desta VPS bloqueia o meu push na master desde 29/09. Roteiro para o celular, um comando por onda, sempre o mesmo formato: `! git -C /opt/operacao/escolta-armada push origin melhoria/2026-10-onda-a-seguranca:master` (troca só a letra e o nome da onda); depois de cada um, eu rodo o portão de produção e digo "pode mandar a próxima" ou reverto. Com "publicar sem X", há uma branch única de publicação (`melhoria/2026-10-publicacao`): um push só, `! git -C /opt/operacao/escolta-armada push origin melhoria/2026-10-publicacao:master`, e o portão de produção roda os itens de todas as ondas publicadas nessa vez. Se a master tiver andado desde `2b3fff9`, o push é recusado (não é fast-forward): eu faço o rebase das branches sobre a master nova, repito todos os portões na homologação e mando o roteiro de novo; nunca push forçado.
4. Bloco 2 (logo depois do deploy de C e de A): 204 (RPCs do mural) e 200 (fechar o bucket). Resposta: "aplicado 2". Portão de produção do mural e das fotos.
5. Se parar entre o bloco 1 e o deploy, nada quebra: o bloco 1 é compatível com o código atual. Se parar entre o deploy e o bloco 2, o mural novo não oferece substituição de equipe ("Atualização em andamento", pela ausência de `mural_travas_ativas`), puxar escolta livre continua, e as fotos funcionam por URL assinada com o bucket ainda público.

# Parte 2: adendo 01 (ondas G, J, I, H, K, L e acréscimos da D)

Base: `2026-10-08 Comando VPS - Escolta Armada adendo 01.md` (15h52), que prevalece sobre o comando principal onde houver conflito, e as análises em `/opt/operacao/escolta-homolog/analise/onda-g.md`, `onda-i.md`, `ondas-h-j-k.md` e `onda-l.md`. As regras da seção 0 valem para todas as ondas novas, com as mudanças da regra 7 trazidas pelo adendo (item 7 da seção 0).

## 9. Decisões assumidas (sem perguntar, seção 3 do comando)

O comando proíbe perguntar durante o desenvolvimento. As análises deixaram pontos abertos; cada um foi decidido pela leitura mais conservadora do adendo e vai, com destaque, no relatório de prontidão, para o Peçanha confirmar ou mudar com "publicar sem X".

Confirmação do Peçanha (08/10/2026, na sessão): S1, S2, S3, S4 (Telegram na regra atual, pendência 0.3), S5 (a gestão acompanha o resto pela aba Atividade) e S6 confirmadas como estão. As demais seguem como decisões assumidas.

| Nº | Ponto aberto | Decisão assumida | Por quê |
|---|---|---|---|
| S1 | Onda H: o checklist do Passo 2 passa a ser por viatura? | Não. Só KM e foto do painel são por viatura; checklist de condições e as 5 fotos de ângulo continuam na primeira viatura (pendência 0.2) | O adendo libera "apenas para o bloco de KM inicial e foto do painel"; o restante do Caminho 2 continua proibido |
| S2 | Onda J: quem recebe o aviso de check-in vencido | Efetivo da escolta, administrador, gestor, supervisor e central | O critério fala do gestor; a central é quem acompanha a operação e hoje já vê o alerta |
| S3 | Onda J: um aviso por período vencido ou um por atraso | Um por período vencido (chave por escolta, referência e número do período; a 208 usa chave por escolta e última PARADA, porque segue a regra antiga) | Mesma ideia do que já foi homologado na F: um aviso por prazo perdido |
| S4 | Onda J: Telegram do check-in | Mesma regra e mesmo texto de hoje (208, regra antiga, pendência 0.3), só que disparado pelo cron do banco e não mais pelo navegador | O aviso no canto deixa de calcular atraso no navegador; o Telegram não pode depender dele. Não cria mensagem nova ao cliente |
| S5 | Onda J: gestão vê a caixa de avisos dos outros | Não. Cada um lê só os próprios avisos; a auditoria continua em `logs_auditoria` | Central de notificações é pessoal; contador de não lidas só faz sentido por pessoa |
| S6 | Onda K: cor exclusiva por cliente | Não exclusiva. Paleta fechada de 12 cores; a tela avisa quando a cor já está em uso por outro cliente ativo | "Uma cor por cliente" (decisão 6) é cada cliente com a sua cor; exclusividade limitaria a 12 clientes |
| S7 | Onda I: arquivar escolta em andamento | Recusado. Só arquiva rascunho, agendada, finalizada ou cancelada; em andamento, concluir (inclusive com pendências) ou cancelar antes | Arquivar some com a escolta do Modo Guiado com equipe na rua |
| S8 | Onda I: de onde parte e para onde vai o "voltar uma etapa" | Parte de qualquer status entre `em_pre_inicio` e `finalizada` (recusado em rascunho, agendada e cancelada: não há etapa anterior de campo, e "descancelar" não foi pedido). Destino: o antecessor na sequência do `fluxo_versao` da escolta (`statusAnterior`; para o fluxo 1, a mesma ordem linear das arestas comuns em `validar_transicao_status_escolta`, dump:1350-1359; os saltos legados do fluxo 1, dump:1362-1366, só valem para avançar, e uma escolta do fluxo 1 que pulou uma etapa volta para a etapa linear anterior e a percorre de novo, o que a trigger aceita); numa finalizada por conclusão antecipada, o `status_no_momento` gravado pela RPC em `escolta_conclusoes_antecipadas`. O histórico, que o efetivo também grava, serve só de conferência. Voltar de `em_pre_inicio` para `agendada` recebe o mesmo tratamento do zerar (S15) | É "a etapa imediatamente anterior"; nada é apagado; o destino não depende de dado que o operador consegue gravar |
| S9 | Onda I: remover viatura que já tem registro de campo, na edição | Recusado com mensagem; viatura sem registro pode sair. Trocar a placa de viatura com registro também é recusado | Remover apagaria em cascata pontos e checklists (prova); `emergencias` nem deixa |
| S10 | Onda I: supervisor e central perdem, no banco, a edição de escolta iniciada que hoje só a tela impede | Perdem (passa a valer no servidor o que já vale na tela). KM, combustível e periodicidade continuam com eles | Decisão 3: "supervisor e central continuam como hoje" (hoje, na tela) |
| S11 | Onda L: escopo das telas offline | Campo, Painel Guiado e a tela de detalhe das escoltas do operador. `registrar_campo` é só um envelope de transporte: cada tela continua montando o próprio conteúdo, exatamente as mesmas linhas de hoje, e o servidor grava essas linhas numa transação, sem regra de etapa nova e sem unificar os caminhos das duas telas (o Caminho 2, pendência 0.1, continua pendente). A finalização (checklist de entrega e relatório) continua exigindo internet. Desvio declarado no relatório de prontidão | O critério pede "da saída à chegada" sem internet, e saída da base, parada e chegada na base só existem no detalhe; criar painéis novos no Campo seria um segundo caminho de gravação |
| S12 | Onda L: resolução das fotos | Sem mudança (foto inteira, como hoje). A captura é bloqueada com aviso se o espaço do aparelho acabar | Reduzir resolução mexe na prova; fica como recomendação no relatório |
| S13 | Onda L: botão de SMS na emergência | Não. Só o botão de ligar para a central | O adendo pede "orienta usar o rádio ou telefone" |
| S14 | Onda G: ESC-2026-0008 (equipe trocada pelo mural em 07/10; no backup de 08/10 continua `agendada`, prevista para 06/10 20h de Brasília) e agendadas vencidas (ESC-0006, 0008, 0012 e 0013) | Nenhuma correção de dado. Vão no relatório como decisão da gestão, com as consultas de conferência | Regra 3.5.3: não alterar dado real fora do pacote; não há dado estrutural quebrado |
| S15 | Onda I: escolta zerada volta a `agendada` e reaparece no mural com a data passada | Volta ao mural com a etiqueta "Reiniciada pela gestão"; as presenças (T2) anteriores são anuladas; a janela T1 conta da `data_hora_prevista`, que a gestão pode reagendar na mesma tela | É o efeito natural de "voltar para agendada"; a gestão decide se reagenda |
| S16 | Onda H: diálogo "Saída da Base" fora do wizard (`handleStartBase`) | Sem mudança (continua pedindo KM e foto) | É o caminho fora do wizard (escolta que pulou o pré-início pelo fluxo antigo); o adendo trata do wizard |

## 10. Onda G: escolta com dois vigilantes

### 10.1 Causa (confirmada na homologação, `analise/onda-g.md`)

A gravação está certa: no backup de 08/10, 30 linhas de efetivo em 14 escoltas, 0 vigilantes sem conta, 0 duplicidades, 0 membros em viatura de outra escolta. O defeito está na lista do operador (`app/dashboard/escoltas/page.tsx`):

1. Corrida na escolha da aba (195-202): no primeiro carregamento o perfil ainda não chegou (`hooks/useAuth.ts:10`), a tela carrega como não operador, não calcula as escoltas dele, vê "nenhuma minha" e alguma disponível, troca para Disponíveis e a `ref` prende a escolha. O operador vê "1 escolta encontrada", a da outra dupla. Reproduzido: 8 de 9 entradas erradas com o mural como em produção; com as travas do lote, 9 de 9 certas, mas 8 de 8 erradas quando havia uma escolta vazia no mural.
2. Só em produção (master sem a 204): "sem equipe" é inferido do efetivo lido pelo operador (127-132), e a RLS `escolta_efetivo_select` esconde o efetivo dos colegas; a escolta da outra dupla aparece como livre, com "Puxar esta escolta para mim". Evidência: ESC-2026-0008 teve a equipe da gestão trocada em 07/10 00:04, oito minutos depois de o mesmo operador puxar a ESC-2026-0009, criada em par com ela.

O Painel Guiado não tem o defeito. A tela de criação aceita vigilante repetido, a mesma placa duas vezes e vigilante sem conta, sem aviso.

### 10.2 Migration `210_efetivo_unico.sql` (bloco 2, logo depois da 204)

Vai no bloco 2, não no 1 (revisão adversarial G, achado 2): o formulário da master não recusa vigilante nem placa repetidos e grava a escolta em várias requisições sem transação; com o índice já no ar, um engano desses deixaria a escolta pela metade na janela entre o bloco 1 e o deploy. Depois do deploy o formulário novo recusa a repetição antes de gravar, e as RPCs da 204 tratam o índice: placa de outra viatura da escolta recusada com mensagem, pedido que esbarrar no índice invalidado com o motivo, cada pedido vencido isolado em `processar_pedidos_vencidos`.

1. Consulta de conferência embutida: aborta, sem mudar nada, se houver vigilante repetido na mesma escolta ou veículo repetido na mesma escolta (hoje 0 e 0).
2. `CREATE UNIQUE INDEX IF NOT EXISTS escolta_efetivo_escolta_vigilante_uk ON escolta_efetivo (escolta_id, vigilante_id)` e `escolta_veiculos_escolta_veiculo_uk ON escolta_veiculos (escolta_id, veiculo_id)`. O `ON CONFLICT DO NOTHING` de `assumir_escolta` passa a valer de fato.
3. `devolver_escolta` ganha linha em `logs_auditoria` na 217 (bloco 2, depois da 204); a 210 só tem os índices.

Reversão: `DROP INDEX`.

### 10.3 Código

1. Lista (`escoltas/page.tsx`): `carregar()` sai cedo enquanto o usuário for nulo; a aba inicial é escolhida dentro de `carregar()`, depois de calcular as escoltas do operador; na aba Disponíveis, aviso "Você tem N escolta(s) em Minhas Escoltas".
2. "Sem equipe" só por `mural_info`; sem ela (minutos entre deploy e bloco 2), tratar como "com equipe", nunca como livre. Depende da onda C (seção 18.3).
3. Nova, `validar2`: recusa vigilante repetido (em qualquer viatura) e placa repetida; aviso "este vigilante não tem acesso ao aplicativo e não verá a escolta" quando `usuario_id` for nulo; o seletor esconde quem já foi escolhido.
4. A edição deixa de apagar e recriar (vira a RPC `editar_escolta` da onda I, transacional e por diferença).

### 10.4 Critérios de aceite e testes

| Critério | Teste |
|---|---|
| Duas escoltas com dois vigilantes cada aparecem para os quatro, na criação | Playwright `g_efetivo.js`: gestor cria as duas em sequência; cada um dos quatro vigilantes entra 5 vezes (cache limpo) e vê a própria em Minhas Escoltas, na primeira tela, e no Painel Guiado |
| Idem depois da edição | gestor edita as duas (troca a observação e uma viatura sem registro); os quatro veem |
| Idem depois de puxar pelo mural | terceira escolta sem equipe; um vigilante de fora puxa; ele vê a nova e os quatro continuam vendo as suas |
| Escolta com equipe nunca aparece como livre | Playwright com `mural_info` revogada (simula master sem a 204): a escolta da outra dupla não mostra "Puxar" |
| Repetição recusada | Playwright: mesmo vigilante duas vezes e mesma placa duas vezes recusados na tela; SQL: INSERT duplicado recusado pelo índice |
| Teste permanente | `e2e/g_efetivo.js` entra em `fase4-e2e.sh`; caso SQL em `04_lote_2026_10_g.sql` |

### 10.5 Efeito, riscos e reversão

Operador: abre em Minhas Escoltas quando tem escolta; a da outra dupla não aparece mais como livre. Gestão: formulário recusa repetição e avisa vigilante sem conta. Modo Guiado, detalhe, mapa, relatórios, Telegram: nada. Risco baixo. Reversão: `git revert` e `210_..._reverter.sql`.

## 11. Onda J (com a B): aviso de 2 segundos e central de notificações

### 11.1 Situação

O alerta de check-in é fixo até o X (`components/checkin-alert-provider.tsx`) e calcula atraso no navegador, com N+2 consultas por escolta por minuto. O sino da barra superior já existe (`components/layout/topbar.tsx:100-135`), mas o contador soma inserções em 5 tabelas desde a abertura da página e zera ao abrir Avisos (`layout.tsx:107-123`); a publicação `supabase_realtime` da homologação não tem tabela nenhuma. A página Avisos é um feed de atividade, sem destinatário nem estado de lida. A tabela `notificacoes` existe (vazia em produção), já recebe os avisos da onda C (`_avisar_app`, 204), mas não tem `lida_em`, texto nem chave de evento; a policy `notificacoes_escrita` é `FOR ALL` (destinatário e gestão podem apagar) e o `anon` tem TRUNCATE na tabela.

### 11.2 Migration `211_central_avisos.sql` (bloco 1, compatível com a master)

1. Schema `lote_interno` (fora dos schemas expostos pelo PostgREST; `REVOKE ALL ON SCHEMA lote_interno FROM PUBLIC, anon`; `GRANT USAGE` só a `authenticated` quando uma função SECURITY INVOKER precisar chamar algo dali, caso da onda L). Funções internas novas do adendo nascem nele.
2. `notificacoes`: colunas `lida_em timestamptz`, `titulo text`, `texto text`, `evento_chave text`. Gatilho de sincronia nos dois sentidos: se `lida` mudar para verdadeiro sem `lida_em`, grava `lida_em = now()`; se `lida_em` for preenchida, grava `lida = true` (a `marcar_aviso_lido` da 204, que faz `SET lida = true`, continua funcionando). `criado_em` continua sendo a "criada_em" do adendo (renomear quebraria a 204). Índice único `(evento_chave, usuario_dest_id) WHERE evento_chave IS NOT NULL`.
3. Tipos novos em `dom_tipos_evento`: `checkin_vencido`, `edicao_escolta`, `reset_escolta`, `conclusao_antecipada`, `arquivamento_escolta`, `recuperacao_escolta`, `conflito_offline`.
4. `lote_interno.notificar(p_chave, p_escolta_id, p_tipo, p_usuarios uuid[], p_titulo, p_texto)`: SECURITY DEFINER, sem GRANT, não depende de `auth.uid()` (roda pelo cron), `ON CONFLICT DO NOTHING`.
5. RPCs novas (authenticated): `meus_avisos(p_tipo, p_escolta_id, p_so_nao_lidas, p_limite, p_antes)`, `contar_avisos_nao_lidos()`, `marcar_todos_lidos(p_tipo)`. A `marcar_aviso_lido(p_notificacao_id)` da 204 não é tocada aqui (nome do parâmetro mantido).
6. RLS: SELECT só `usuario_dest_id = get_meu_usuario_id()` (S5); `DROP POLICY notificacoes_escrita` (FOR ALL) e das restritivas de INSERT e UPDATE da 197, que ficam sem objeto; `REVOKE ALL FROM anon`; `REVOKE INSERT, UPDATE, DELETE, TRUNCATE FROM authenticated`. Toda escrita por função. Compatível com a master, que não escreve em `notificacoes` (conferido: só RPC da 204, do bloco 2).

### 11.3 Migration `212_aviso_checkin_servidor.sql` (bloco 1)

1. `lote_interno.gerar_avisos_checkin()`, pelo `pg_cron` a cada minuto (job `lote2026_avisos_checkin`, só agenda se `pg_cron` existir, como a 202). Porte em SQL de `minutosAteCheckin` (`lib/checkin.ts`): status em `STATUS_COM_CHECKIN`, com periodicidade; referência = último ponto PARADA com `observacoes` JSON `tipo = reporte_periodico`, senão o primeiro ponto, senão `data_hora_prevista`; o cast de `observacoes` só quando começa por `{` (legado em texto puro nunca derruba o cron). A 212 não conhece arquivamento nem anulação (são da onda I); a 214 recria esta função com os dois filtros.
2. Para cada período vencido: `lote_interno.notificar` com chave `checkin:<escolta>:<epoch da referência>:<n do período>` para os destinatários de S2, texto com código, cliente, minutos de atraso e periodicidade, hora em DD/MM/AAAA HH:MM (Brasília).
3. Telegram (S4): o mesmo cron chama `lote_interno.enfileirar_alerta_checkin(escolta)`, corpo da 208 sem a guarda de perfil; `enfileirar_alerta_checkin` (208) passa a chamá-la depois da guarda. Mesma regra, mesma chave, mesmo texto.
4. Limpeza: lidas há mais de 90 dias apagadas pelo mesmo cron.
5. Teste de carga no portão do banco: 50 escoltas ativas, `EXPLAIN ANALYZE` do ciclo abaixo de 200 ms.
6. Na master, com periodicidade nula em todas as abertas (201), o cron não gera nada até um cliente ter a chave de check-in.

### 11.3a Migration `217_mural_central.sql` (bloco 2, depois da 204)

1. `_avisar_app` (204) passa a chamar `lote_interno.notificar`, com chave `<tipo>:<pedido_id>` e destinatário, mantendo `configuracoes_mural.aviso_ligado`.
2. `marcar_aviso_lido(p_notificacao_id)` passa a gravar `lida_em` (o gatilho acerta `lida`).
3. `devolver_escolta` com auditoria (onda G).
4. Reversão: recria os corpos da 204.

### 11.4 Código

1. `components/avisos-provider.tsx` (substitui o `CheckinAlertProvider` no layout): a cada 20 s, `contar_avisos_nao_lidos` e `meus_avisos(p_so_nao_lidas, desde o último visto)`; cada aviso novo aparece no canto e some sozinho em 2 s (sem botão; clique abre a escolta). "Já mostrado": ids em memória e o último `criado_em` em `localStorage` por usuário (try/catch), para não repetir ao recarregar nem em duas abas (`BroadcastChannel` entre abas; sem ele, o aviso pode aparecer nas duas abas, mas a linha é uma só). Expõe o contador por contexto.
2. Layout: o contador por inserções some; sino (topbar) e item Avisos da barra inferior mostram não lidas; o sino não zera ao clicar.
3. Página Avisos: aba padrão "Central" (lista paginada, filtro por tipo e por código da escolta, marcar como lida, marcar todas, link para a escolta, "Registrar check-in" no aviso de check-in); o feed atual vira a aba "Atividade" só para a gestão, fora do contador; "Chat" fica como está.
4. `checkin-alert-provider.tsx` e `alertas_dispensados`: aposentados no código; a tabela fica (a reversão da 201 a remove).
5. `components/escolta/avisos-mural.tsx`: igual (mesma tabela; ler na central tira do mural).
6. Ajuste da onda C: avisos de pedido, decisão e substituição caem na central pela `lote_interno.notificar` (217, bloco 2). Ajuste da onda B: o item 2.2.3 (X com assinatura) sai, porque o aviso não é mais fixo.

### 11.5 Critérios de aceite e testes

| Critério | Teste |
|---|---|
| Check-in vencido: aviso por 2 s, some, uma linha na central, contador sobe | Playwright `j_avisos.js`: escolta QA com periodicidade 5 min e referência há 6 min; cron roda; gestor vê o aviso, captura com 1 s e com 3 s (sumiu), contador +1, uma linha na central |
| Dois navegadores: notificação única | dois contextos do mesmo gestor e um do supervisor: uma linha por destinatário (`count(*)` por chave), contador igual nos dois |
| Próximo período gera novo aviso; o mesmo período não | SQL: rodar `gerar_avisos_checkin()` três vezes no mesmo período (1 linha); avançar o relógio da referência (2 linhas) |
| Avisos da onda C e da onda I na central | Playwright: pedido de substituição aparece para o supervisor na central e no sino |
| Marcar lida e marcar todas | Playwright: contador cai para 0 |
| Ninguém lê nem apaga aviso de outro | SQL: operador lê a própria caixa; DELETE e UPDATE diretos recusados; anon sem acesso |
| Telegram do check-in uma vez por período, sem navegador aberto | SQL e servidor falso: com nenhum navegador, o cron enfileira e a fila envia 1 mensagem |

### 11.6 Efeito, riscos e reversão

Todos os perfis: aviso no canto por 2 s; sino com não lidas; página Avisos com a Central. Gestão: feed vira a aba Atividade; deixa de ver a caixa dos outros. Operador: avisos do mural e de check-in na Central. Telegram: o alerta de check-in sai pelo cron (mesma regra). Riscos: 2 s é pouco para quem dirige (o aviso fica na Central e o check-in segue como pendência no Painel); volume de linhas (5 a 10 por período vencido; limpeza de 90 dias). Reversão: `217_..._reverter` (recria os corpos da 204), `212_..._reverter` (desagenda e remove a função), `211_..._reverter` (backup das colunas novas em `backup_20261008.notificacoes_central`, devolve as policies e os grants da 195 e recria as restritivas da 197, para o M3 não reabrir), `git revert`.

## 12. Onda I: poder total de gestor e administrador

Sigla: G2 = administrador e gestor.

### 12.1 Situação (`analise/onda-i.md`)

1. Registrar fora da equipe já funciona no banco para G4 (policies de pontos, fotos, checklists, ocorrências, emergências, histórico e `podeOperarEscolta`). O que a tela esconde: o Campo lista à gestão só as agendadas em que ela está na equipe; o botão "Voltar ao Painel Guiado" exige estar na equipe; Editar só em rascunho e agendada.
2. A edição apaga e recria `escolta_efetivo` e `escolta_veiculos` (nova:683-684), que cascateia pontos, checklists, rastreamento e armamentos: proibido em escolta iniciada.
3. A única trava real para reset e conclusão antecipada é `validar_transicao_status_escolta` (dump:1334).
4. Campo, Modo Guiado, `registrar_etapa_escolta` e `exigir_ponto_transito_retorno` contam pontos existentes: sem filtrar anulados, uma etapa desfeita avançaria sozinha sem foto nova.
5. `pontos_insert` não confere `lancado_por`.

### 12.2 Migration `213_poder_total_estrutura.sql` (bloco 1, aditiva, compatível com a master)

1. `escoltas`: `arquivada_em`, `arquivada_por`, `motivo_arquivamento`, `reiniciada_em` (S15) e `versao_gestao integer NOT NULL DEFAULT 0` (incrementada por voltar etapa, zerar, concluir antes, arquivar e recuperar, nunca pela edição; usada pela L para detectar conflito); índice parcial `WHERE arquivada_em IS NULL`. ADD COLUMN com DEFAULT constante não reescreve a linha nem dispara trigger: ESC-2026-0001 e ESC-2026-0007 não mudam.
2. Anulação em `pontos_controle`, `checklists`, `ocorrencias`, `emergencias`, `presencas`, `mural_presencas`, `atualizacoes_status`, `rastreamento`, `escolta_status_historico`: `anulado_em`, `anulado_por`, `motivo_anulacao`, `anulacao_id`. `fotos` e `checklist_respostas` herdam do pai.
3. Carimbo de etapa: `status_escolta_no_registro text` nas mesmas tabelas, preenchido por trigger BEFORE INSERT com o status da escolta no momento (não confia no cliente).
4. `escolta_resets` (id, escolta, de, para, tipo `voltar_etapa` ou `zerar`, motivo, feito_por, feito_em, `valores_anteriores` jsonb com KM, `checklist_pendente_no_inicio`, `data_finalizacao`, `observacao_fechamento`, contagem do que foi anulado). Leitura supervisor ou acima; escrita só por RPC.
5. `escolta_conclusoes_antecipadas` (id, escolta, `status_no_momento`, motivo, `concluida_por`, `concluida_em`, `pendencias` jsonb, `anulado_em`, `anulado_por`, `motivo_anulacao`; única por escolta entre as não anuladas) e view `vw_pendencias_conclusao` (`security_invoker`), uma linha por item (escolta, etapa, viatura, item, quem, quando, observação). Leitura supervisor ou acima; o efetivo lê a da própria escolta.
6. Trava das colunas: trigger BEFORE UPDATE recusa mudar `anulado_*`, `arquivada_*`, `versao_gestao`, `reiniciada_em` e `status_escolta_no_registro` fora das RPCs; no INSERT, recusa só valores diferentes do padrão em `anulado_*`, `arquivada_*`, `reiniciada_em` e `versao_gestao` (nulo e 0 passam; `status_escolta_no_registro` fica fora da trava de INSERT, porque é o carimbo da 213.3 que o preenche, e a ordem entre as duas triggers deixa de importar). Nomes: `tr_carimbar_etapa_<tabela>` e `tr_travar_colunas_gestao_<tabela>`. Portão da 213: com a master, criar escolta e gravar ponto, checklist, ocorrência e emergência funcionam; gravar `anulado_em` no INSERT é recusado. Dupla guarda: variável de transação `escolta.rpc_gestao` (ligada só pelas RPCs) e perfil G2 de quem chama (arquivar, recuperar, reset, conclusão) ou `auth.uid() IS NULL` (migrations, SQL Editor e cron, como na 197 e na 206). Ligar a variável sozinho, por qualquer caminho, não basta.
7. `escolta_status_historico.via_rpc boolean NOT NULL DEFAULT false`, preenchida por trigger BEFORE INSERT a partir da variável `escolta.historico_rpc` (a 214 recria `registrar_etapa_escolta` para ligá-la, e as RPCs da 218 também; conferido na verificação das cadeias, 18.4); linhas gravadas direto pelo cliente ficam `false`. A anulação por janela de tempo só usa linhas `via_rpc`.
8. `pontos_controle`: trigger BEFORE INSERT preenche `lancado_por := get_meu_usuario_id()` quando vier nulo (o perfil chega depois da sessão, `hooks/useAuth.ts:10`, e a master pode mandar `user?.id` nulo com sessão válida).

### 12.3 Migration `214_poder_total_travas.sql` (bloco 1, compatível com a master)

1. `validar_transicao_status_escolta`: ramo novo antes do RAISE: com `escolta.transicao_especial` em `reset` ou `conclusao_antecipada` (variável de transação ligada só pelas RPCs) e perfil G2, aceita a volta para a etapa calculada pela RPC e o salto para `finalizada`. Dupla guarda: variável e perfil. O botão genérico não pula etapas.
2. A mesma trigger recusa mudança de status em escolta arquivada.
3. `tr_impedir_edicao_escolta_iniciada` em `escoltas` (BEFORE UPDATE; em ordem alfabética roda antes de `tr_impedir_edicao_por_operador`, o que é indiferente, porque ela não grava nada em NEW e só recusa; teste que confere a ordem real e o resultado): com `OLD.status` fora de rascunho e agendada, mudar qualquer chave de `to_jsonb(NEW)` fora da lista de colunas livres exige G2 (S10). Comparação por `to_jsonb(OLD)` e `to_jsonb(NEW)`, como a 197: vale para colunas que ainda não existem (UF da K) sem as citar por nome. Colunas geradas ficam fora da comparação (em trigger BEFORE elas chegam nulas em NEW): a função exclui as chaves cujo `pg_attribute.attgenerated <> ''`, consultadas no próprio catálogo, e não depende de nome. `auth.uid() IS NULL` passa direto (migrations, cargas e cron). Teste com escolta iniciada com UF preenchida e `interestadual` calculado: operador, supervisor e central avançam o status. Colunas livres em escolta iniciada: `status`, `atualizado_em`, `periodicidade_checkin_min`, `checklist_pendente_no_inicio`, `data_finalizacao`, `observacao_fechamento`, `data_hora_prevista` (reagendar, que já é só da gestão) e as colunas da 213 (travadas pela trigger própria). O mesmo em `escolta_veiculos` (INSERT, DELETE, troca de `veiculo_id`; KM e combustível continuam livres) e `escolta_efetivo` (INSERT, DELETE, UPDATE). A master grava em escolta iniciada só colunas livres: em `escoltas`, status, fechamento (`data_finalizacao`, `observacao_fechamento`), `checklist_pendente_no_inicio` e periodicidade (`[id]/page.tsx:2010`); em `escolta_veiculos`, KM de saída e de retorno (`gravarKmViaturas`, `:1714`) e combustível, livres porque placa e escolta não mudam (nessa condição a 214 libera qualquer coluna da viatura, como diz esta letra); o resto são INSERTs de campo (pontos, checklists, respostas, fotos, ocorrências, emergências e histórico). Compatível (teste com o código de `2b3fff9`, revisão adversarial I, menor 16).
4. Filtro de anulado (`anulado_em IS NULL`) em `exigir_ponto_transito_retorno`, `verificar_checklist_pendente` e `registrar_etapa_escolta` (contagem do comboio e conferência de ponto já feito). Na master, sem anulados, o efeito é nenhum.
5. Recria `lote_interno.gerar_avisos_checkin` e `lote_interno.enfileirar_alerta_checkin` (J) e `enfileirar_aviso_presenca` (208) com os filtros de arquivada e de anulado.
6. RLS: policy RESTRICTIVE de SELECT em `escoltas`: `arquivada_em IS NULL OR (SELECT get_meu_perfil()) = 'administrador'`. Na master, sem arquivadas, o efeito é nenhum.
7. `pontos_controle`: policy RESTRICTIVE de INSERT `WITH CHECK (lancado_por = (SELECT get_meu_usuario_id()))`. Conferido: a master grava `lancado_por: user?.id ?? null`, e `user.id` é `usuarios.id` (`hooks/useAuth.ts`); o nulo com sessão válida é preenchido pela trigger da 213.8 antes da policy. A 207 e a 219 preenchem `lancado_por` no servidor. "Em nome de quem fez" fica garantido em pontos; em `checklists`, `ocorrencias` e histórico continua como hoje (pendência declarada).

### 12.4 Migration `218_poder_total_rpcs.sql` (bloco 2, depois da 204 e da 217)

Todas SECURITY DEFINER, `search_path` fixo, guarda `v_perfil IS NULL OR v_perfil NOT IN (...)`, motivo obrigatório (mínimo 10 caracteres), `SELECT ... FOR UPDATE` na escolta, `versao_gestao + 1` (só em voltar etapa, zerar, concluir antes, arquivar e recuperar; a edição não muda a versão), histórico (`via_rpc`), auditoria (`_auditar`, generalização de `_auditar_mural`) e aviso (`lote_interno.notificar` à supervisão e à equipe, `_enfileirar_aviso` ao chat central) na mesma transação; REVOKE de PUBLIC e anon; GRANT a authenticated.

1. `editar_escolta(p_escolta_id, p_campos jsonb, p_viaturas jsonb, p_motivo)`: em rascunho e agendada, os mesmos perfis e poderes de hoje pela RLS: campos para G4; viaturas e equipe só para G3 (a central edita os campos mas não a equipe, como hoje, `escolta_efetivo_escrita`, dump:4148); nos demais status, só G2. Campos por lista fechada (cliente, data, endereços, coordenadas, UF quando a coluna existir, observações, financeiro só para quem vê financeiro, escala fixa conforme a 203); `metadados` mesclado. Viaturas e equipe por diferença, pelo `escolta_veiculo_id` que o formulário passa a guardar: mantida = UPDATE; nova = INSERT; removida sem registro de campo = DELETE; removida com registro, ou troca de placa com registro = recusa (S9). Recusa vigilante ou placa repetidos (G). Preserva combustível (E). Auditoria com antes e depois. Não incrementa `versao_gestao` em nenhum status: registro offline feito antes de uma edição só vira conflito se a própria linha não puder ser gravada (membro retirado do efetivo, viatura removida), medido por linha na 219.
2. `pendencias_da_escolta(p_escolta_id) RETURNS jsonb` (G2, STABLE): etapas não alcançadas até `na_base` pela sequência do `fluxo_versao` da escolta; por viatura e etapa com ponto (`TIPO_PONTO_POR_STATUS`), ponto válido ausente; pré-início por viatura: checklists válidos, KM de saída e, se aplicável, KM de retorno. Formato `[{etapa, rotulo, viaturas:[{escolta_veiculo_id, placa, faltando:[...]}]}]`.
3. `concluir_escolta_antecipada(p_escolta_id, p_motivo)`: G2, calcula as pendências no servidor (não aceita lista do cliente), liga a variável, `finalizada` com `data_finalizacao` e `observacao_fechamento = motivo`, histórico, linha em `escolta_conclusoes_antecipadas`. Sem pendência, conclui normalmente sem a linha.
4. `voltar_etapa_escolta(p_escolta_id, p_motivo, p_previa boolean)` e `zerar_escolta(p_escolta_id, p_motivo, p_previa boolean)`. Com `p_previa = true`, só devolve a lista do que seria anulado (a tela mostra antes de confirmar).
   - Etapa de destino ao voltar: S8 (sequência do `fluxo_versao`, ou `status_no_momento` da conclusão antecipada). Zerar: `agendada`. Recusado em rascunho, agendada e cancelada.
   - Ao desfazer a entrada numa etapa X, com o mesmo `anulacao_id`, anula: (a) o que a entrada em X produziu, pela tabela abaixo; (b) tudo com `status_escolta_no_registro = X` (feito enquanto a escolta estava em X: paradas, check-ins, ocorrências, presenças); (c) registros antigos sem carimbo (anteriores à 213) com `data_hora` a partir do ponto que produziu X (ou, sem ele, da última linha `via_rpc` que levou a X; sem nenhuma das duas, como em `em_pre_inicio` e `finalizada` de escoltas antigas, nada é anulado por janela, e a prévia diz isso); a prévia mostra cada um, e a gestão confirma vendo a lista; (d) as linhas do histórico que levaram a X; e grava uma linha nova de volta com observação "Reset: motivo".

     | Entrada em X | Produz (anulado ao desfazer X) |
     |---|---|
     | `em_pre_inicio` | só a linha do histórico |
     | `em_andamento` | checklists `viatura` e `material` gravados em `em_pre_inicio` (carimbo, ou janela entre a entrada em `em_pre_inicio` e a em `em_andamento` nos antigos) e respostas (fotos herdam), pontos `base_saida`, `quilometragem_saida` de cada viatura (guardada), `checklist_pendente_no_inicio` volta ao valor guardado de antes da entrada (a Nova cria com `true`) |
     | `na_origem`, `em_transito_destino`, `no_destino`, `em_transito_retorno`, `retornando` | pontos do tipo `TIPO_PONTO_POR_STATUS[X]` |
     | `na_base` | pontos `base_retorno`, `quilometragem_retorno` (guardada) |
     | `finalizada` | checklist de entrega (também do tipo `viatura`: identificado pelo carimbo `na_base`, ou nos antigos pela janela depois da entrada em `na_base`; nunca pelo tipo) e respostas, fotos da finalização, `data_finalizacao` e `observacao_fechamento` (guardados), linha de conclusão antecipada (anulada) |

   - Zerar repete o desfazer etapa por etapa até `agendada`, anula as presenças do mural (T2) e grava `reiniciada_em` (S15). Equipe e viaturas continuam. Voltar uma etapa de `em_pre_inicio` para `agendada` faz o mesmo (S8).
   - Recusa com emergência aberta ("encerre a emergência antes").
5. `arquivar_escolta(p_escolta_id, p_motivo)` (G2; S7) e `recuperar_escolta(p_escolta_id, p_motivo)` (só administrador).
6. Filtro de arquivada nas funções da 204 (`mural_info`, `listar_pedidos_mural`, `processar_pedidos_vencidos`, `assumir`, `puxar`, `devolver`, `incluir`, `confirmar_presenca_base`, `_conflito_comandante`), nas da 202 (`enviar_avisos_telegram` não envia aviso de escolta arquivada depois do arquivamento) e na `registrar_etapa_escolta` (recusa). Ficam aqui, no bloco 2, porque a 204 só existe depois do bloco 2 (crítica B1); a 218 recria os corpos a partir da versão da 217.
7. Ações na auditoria: `EDITAR_ESCOLTA`, `VOLTAR_ETAPA`, `ZERAR_ESCOLTA`, `CONCLUSAO_ANTECIPADA`, `ARQUIVAR_ESCOLTA`, `RECUPERAR_ESCOLTA` (rótulos em `auditoria/page.tsx`).

### 12.5 Código

1. `lib/permissions.ts`: `PODE_PODER_TOTAL = ['administrador', 'gestor']`. `lib/fluxo-escolta.ts`: `SEQUENCIA_STATUS` e `statusAnterior`.
2. Detalhe (mínimo, regra 7): menu "Ações da gestão" (G2) no cabeçalho com Editar, Voltar uma etapa, Zerar para agendada, Concluir agora e Arquivar, num componente novo `components/escolta/acoes-gestao.tsx` (diálogos, prévia, motivo, confirmação explícita); a tela só importa e põe uma linha. Timeline: registros anulados com marcação ("Anulado em DD/MM/AAAA HH:MM (Brasília) por Nome: motivo", riscado) e fora das contagens; faixa "Concluída com pendências" e seção com a lista; o botão de volta ao Painel Guiado também para G2. Leituras do detalhe passam a trazer `anulado_em` (mesma consulta, coluna a mais).
3. Nova: modo edição guarda `escolta_veiculo_id`, abre para G2 em qualquer status, pede motivo fora de rascunho e agendada, salva pela RPC (G4 também, em rascunho e agendada).
4. Lista: Editar para G2 em qualquer status; etiqueta "Concluída com pendências" e filtro (K); arquivadas fora.
5. Páginas novas: `/dashboard/escoltas/arquivadas` (administrador; motivo, autor, data, Recuperar) e `/dashboard/escoltas/pendencias` (supervisor ou acima; período, cliente). Itens no menu por perfil.
6. Filtro de arquivada (`.is('arquivada_em', null)`) e de anulado nas leituras: painel inicial, Campo, mapa, indicadores (inclusive tempo médio, que passa a ignorar histórico anulado), relatórios, PDF, impressão (seção "Registros anulados" separada, nunca como válidos), notificações, checklists, `lib/checkin.ts`, Campo (`:687`, contagem do comboio), relatório final enviado ao Telegram na finalização (KM e pontos válidos), regra de conflito da onda L. Filhas lidas por data (indicadores, relatórios, PDF) passam a usar `escolta:escoltas!inner(...)` com o filtro.
7. Campo: gestão vê também as agendadas de qualquer equipe.
8. Impressão e PDF: seção "Pendências de conclusão".

### 12.6 Critérios de aceite e testes

| Critério | Teste |
|---|---|
| Gestor fora da equipe registra ponto, check-in, checklist, foto e etapa | Playwright `i_poder_total.js` (gestor QA fora do efetivo) pelo detalhe; banco com `lancado_por` = gestor |
| Edita escolta em andamento sem perder registro | Playwright: troca observação, data, destino e acrescenta viatura; contagem de pontos, checklists e fotos igual antes e depois; auditoria com antes e depois |
| Remover viatura com registro recusado | SQL e Playwright |
| Arquiva e o administrador recupera | Playwright: gestor arquiva; some da lista, mural, Campo, mapa, indicadores do gestor e do operador; administrador vê em Arquivadas e recupera; volta ao status em que estava |
| Volta uma etapa | Playwright: escolta em `no_destino` volta para `em_transito_destino`; ponto de destino anulado e marcado na timeline; Campo pede de novo a foto do destino (não avança sozinho). SQL: voltar de `em_andamento` anula checklists, `base_saida` e KM e devolve `checklist_pendente_no_inicio`; refazer o wizard não duplica checklist válido; voltar de uma finalizada por conclusão antecipada vai para o status em que ela estava e anula a linha de pendências; voltar de `finalizada` mantém válidos os checklists do wizard; linha de histórico forjada pelo operador (`status_anterior = agendada`, data antiga) não muda o destino nem a janela; voltar de agendada e de cancelada é recusado; escolta do fluxo 1 que pulou `em_transito_destino` volta de `no_destino` para `em_transito_destino` e avança de novo |
| Zera para agendada | Playwright: todos os registros anulados, nada apagado (contagem total igual), equipe e viaturas iguais, presença do mural anulada, etiqueta "Reiniciada pela gestão"; o pré-início é feito de novo do começo |
| Conclui com pendências e o PDF mostra | Playwright: escolta em `em_transito_destino` concluída; pop-up lista por etapa e viatura; detalhe, impressão e PDF com a lista; etiqueta na lista; tela de pendências |
| Operador sem nenhum desses poderes, inclusive pela API | SQL `04_lote_2026_10_i.sql` como operador, supervisor e central: as 7 RPCs recusadas; UPDATE direto de status para trás, de `anulado_*`, `arquivada_*` e `versao_gestao` recusado; edição de escolta iniciada recusada para supervisor e central; central não altera a equipe pela `editar_escolta` |
| Bloco 1 com a master | o código de `2b3fff9` (worktree só leitura, build na porta 3101) contra o banco com o bloco 1 aplicado: jornada completa do operador, criação e edição pela gestão, cadastro de cliente; nada quebra |
| Dupla guarda da máquina de estados | SQL: gestor com UPDATE direto de status para trás recusado (sem a variável); variável ligada por operador recusada (perfil) |
| Relatório, PDF e indicadores sem anulados como válidos | SQL e Playwright: escolta zerada e refeita conta uma vez |

### 12.7 Efeito, riscos e reversão

Gestor e administrador: editam em qualquer status, voltam etapa, zeram, concluem com pendências, arquivam (administrador recupera). Supervisor: tela de pendências; perde no servidor a edição de escolta iniciada que a tela já não oferecia (S10). Central: idem S10. Operador: nada novo; vê registros anulados marcados; na volta de etapa, refaz a etapa. Modo Guiado: ignora anulados. Telegram: aviso no chat central para cada ação da gestão. Riscos: contagem de pontos com anulados (teste prioritário); registro antigo sem carimbo depende do horário (a prévia mostra antes); ordem alfabética das triggers (teste). Reversão: `218`, `214` e `213` `_reverter` (213 guarda as colunas novas e as tabelas em `backup_20261008` antes de remover), `git revert`.

## 13. Onda H: KM e foto do painel no Passo 2

### 13.1 Situação

KM e foto por viatura já existem no wizard, no Passo 3 (`[id]/page.tsx:3015` e `:3030`, estado em `775-791`); `gravarPontosPorViatura` (1609) e `gravarKmViaturas` (1706) já gravam por viatura. O Campo não tem wizard (manda para o detalhe).

### 13.2 Código (só `app/dashboard/escoltas/[id]/page.tsx`, sem banco)

1. Passo 2: bloco "Por viatura", um cartão por viatura (placa) com KM inicial obrigatório (número maior que zero) e "Foto do painel com o hodômetro" obrigatória (câmera), reaproveitando `KmViaturasInput` e `FotosViaturasInput`; validação no avanço do Passo 2.
2. Passo 3: só "Observações gerais de saída *" (decisão 4), resumo só leitura do KM por viatura e "Confirmar e iniciar escolta".
3. `handleWizardSubmit`: mesmas validações (defesa), mensagens apontando o Passo 2; gravação igual: o ponto de saída de cada viatura nasce no Passo 3 com o KM e a foto daquela viatura.
4. Aviso de comboio do Passo 2: só as 5 fotos de ângulo e os checklists continuam na primeira viatura (S1).
5. `docs/09` e texto do passo.

### 13.3 Critérios de aceite e testes

Playwright `h_wizard.js`: escolta QA com duas viaturas; Passo 2 não avança sem KM e foto de cada uma; Passo 3 sem campo de KM nem foto, só observações (obrigatórias); banco: dois pontos `base_saida`, cada um com a foto e o KM da sua viatura, `quilometragem_saida` nas duas; impressão e PDF mostram o KM de saída de cada viatura; chegada na base com KM menor que a saída da viatura 2 é recusada.

### 13.4 Efeito, riscos e reversão

Operador: KM e foto do painel saem do Passo 3 e vão para o Passo 2, por viatura. Demais telas: nada (mesmas colunas). Risco baixo. Reversão: `git revert`.

## 14. Onda D, acréscimos (4.6 do adendo)

1. Atalhos em todos os formulários de endereço da escolta: criação e edição (o mesmo formulário Nova; conferir na edição de escolta iniciada da onda I) para todos os perfis que criam escolta; botões pequenos acima de origem e destino (já existem; ajuste de tamanho).
2. Um toque preenche endereço, complemento, coordenada e UF (UF da onda K, coluna `locais_salvos.uf`).
3. "Salvar este endereço" ao lado de cada campo, para supervisor ou acima (hoje existe só na tela de locais e como opção ao final): cria `aguardando_conferencia`, com o endereço, a coordenada e a UF do campo.
4. Ordenação pelos mais usados: migration `215_locais_uso.sql` (bloco 1): `locais_salvos.vezes_usado integer NOT NULL DEFAULT 0` e `uf text` (`CHECK ~ '^[A-Z]{2}$'`); trigger AFTER INSERT OR UPDATE OF origem_endereco, destino_endereco, origem_lat, origem_lng, destino_lat, destino_lng em `escoltas` (nomes conferidos na homologação; o complemento do atalho entra no texto do endereço, como a Nova já faz em `enderecoComComplemento`), que só age quando a origem ou o destino mudou de fato (`IS DISTINCT FROM`) e soma 1 ao local cujo endereço ou coordenada (até 100 m) bate com o novo valor (SECURITY DEFINER, sem GRANT); mudança de status, KM e as cargas não contam. Carga inicial a partir das escoltas existentes, só leitura delas (UPDATE só em `locais_salvos`). Atalhos ordenados por `vezes_usado DESC, nome`. UF dos 5 locais da carga: RJ.
5. Geolocalização: segue a M1 (sem mudança).

Teste: Playwright `d_locais.js` estendido: atalho preenche UF (quando a K estiver aplicada; sem K, o atalho preenche o resto e a UF fica fora); "Salvar este endereço" pelo supervisor cria aguardando; ordem muda depois de três escoltas para Galeão; avançar o status de uma escolta não muda `vezes_usado`. SQL: operador não altera `vezes_usado`. Reversão: `215_..._reverter`.

## 15. Onda K: cor por cliente, cartão padrão, filtros e interestadual

### 15.1 Migration `216_uf_e_paleta.sql` (bloco 1, compatível com a master)

1. `escoltas.origem_uf`, `destino_uf` (`CHECK ~ '^[A-Z]{2}$'`), `uf_estimada boolean NOT NULL DEFAULT false`, `interestadual boolean GENERATED ALWAYS AS (origem_uf <> 'RJ' OR destino_uf <> 'RJ') STORED` (nulo se as duas forem desconhecidas; o filtro trata nulo como "não determinado"), índice.
2. Malha das UFs: `lote_interno.malha_uf (uf, poligonos jsonb)` carregada da API de malhas do IBGE (`servicodados.ibge.gov.br/api/v3/malhas/estados/<código>`, qualidade mínima, GeoJSON), baixada uma vez, guardada em `database/dados/malha-uf-ibge-<data>.json` com a URL e a data no cabeçalho da migration; nunca desenhada à mão. `uf_da_coordenada(lat, lng)` (STABLE, SECURITY DEFINER porque lê `lote_interno.malha_uf`, `search_path` fixo, PL/pgSQL puro, teste de raio sobre as 27 UFs, caixa de cada polígono primeiro) devolve a UF e a distância aproximada à borda; ponto fora de todos os polígonos (baía, ilha, litoral na malha mínima) recebe a UF do polígono mais próximo, com `uf_estimada` e entrada na lista de conferência; RPC exposta a authenticated para o pino movido na Nova (criar escolta já exige internet).
3. Carga das escoltas existentes: UF pela coordenada, `uf_estimada = true`, exceto ESC-2026-0001 e ESC-2026-0007 (regra 1.11: não alterar), que ficam sem UF e vão listadas no relatório. Ponto a menos de 5 km da borda vai para `backup_20261008.uf_a_conferir` e para a lista do relatório. Sem coordenada, UF nula. A carga não aciona a trigger da 215 (ela só age em mudança de endereço) e muda `atualizado_em` das escoltas atualizadas pela trigger existente, sem efeito de negócio.
4. Paleta: tabela `paleta_clientes` (12 cores) e trigger BEFORE INSERT OR UPDATE OF cor_destaque em `clientes` que normaliza qualquer cor para a mais próxima da paleta (distância no espaço Lab, CIE76), sem diferenciar maiúscula; texto que não seja `#rrggbb` vira a cor padrão da paleta, nunca erro (a master grava cor livre: `cadastros/page.tsx:689`, `clientes/page.tsx:52`; continua funcionando e cai na paleta). `DEFAULT` da coluna trocado para a cor padrão da paleta. Carga: clientes ativos distribuídos sem repetir cor enquanto houver cor livre (cada um na mais próxima ainda livre), a antiga guardada em `backup_20261008.cores_clientes` e as trocas listadas no relatório. Sem CHECK.
5. Exibição quando `uf_estimada`: só "Interestadual" ou nada (sem mostrar a UF vizinha por extenso), porque é estimativa.
6. `impedir_edicao_por_operador` (197) recriada com `origem_uf`, `destino_uf` e `uf_estimada` na lista de colunas que o operador não altera (por `to_jsonb`, como as demais).

### 15.2 Código

1. `lib/paleta-clientes.ts`: as 12 cores, com contraste de texto branco de pelo menos 4,5:1 (script de conferência no teste). Seletor de paleta em `clientes/page.tsx` e `cadastros/page.tsx`, com aviso "cor já usada por X" (S6).
2. `components/escolta/cartao-escolta.tsx` (variantes `linha` e `cartao`) e `lib/cartao-escolta.ts` (consulta única): código, cliente com faixa lateral na cor, data e hora em Brasília, origem e destino resumidos (bairro e município), quem criou, equipe (quantidade e comandante para quem pode ver; "sem equipe" por `mural_info` para o operador), status por `lib/fluxo-escolta.ts` (acaba o `STATUS_MAP` duplicado sem `em_transito_retorno`), etiquetas Interestadual, Escala fixa, Concluída com pendências, Reiniciada pela gestão, Arquivada (só administrador). Usado na lista, no mural, no painel inicial, no Modo Guiado (agendadas e escolta ativa) e na lista lateral e no popup do mapa (o marcador continua com a cor do status).
3. Filtros (lista e mural): status, cliente, período (hoje, amanhã, esta semana, intervalo), quem criou, com ou sem equipe, interestadual, busca; combinados; no servidor quando possível; lembrados por usuário no aparelho (`localStorage`, chave `filtros-escoltas:<usuario_id>`, try/catch). `hooks/useFiltrosEscoltas.ts`.
4. UF na escolha do endereço (Nova): sugestão Mapbox (`context` `region.` com `short_code` `BR-RJ`), local salvo (`uf`), pino movido ou sugestão sem `region` (RPC `uf_da_coordenada`). Gravada no insert e na edição. Sem token da Mapbox na VPS, só o local salvo e a RPC são testáveis; a leitura do `short_code` é coberta por teste de unidade com respostas reais da Mapbox gravadas da documentação oficial, e conferida no preview ou com o Bruno (como a M1, seção 4.3).
5. Interestadual também no cabeçalho do detalhe (uma linha), na impressão e no PDF.

### 15.3 Critérios de aceite e testes

| Critério | Teste |
|---|---|
| Duas escoltas de clientes diferentes com cores diferentes em todas as visões | Playwright `k_visual.js`: lista, mural, painel, Modo Guiado e mapa (lista lateral); captura e leitura do estilo da faixa |
| Filtros combinam e ficam lembrados | Playwright: status + cliente + interestadual; recarregar mantém; outro usuário no mesmo navegador não herda |
| Rio para São Paulo mostra Interestadual; só RJ não mostra | Playwright e SQL; também no detalhe, impressão e PDF |
| UF pela coordenada | SQL: 30 pontos conhecidos (capitais, Juiz de Fora, Cachoeiro, Paraty, Resende, Itaperuna, Angra, Petrópolis, Campos) com o resultado esperado; ESC-2026-0001 e 0007 sem mudança (comparação linha a linha antes e depois) |
| Paleta | SQL: cor fora da paleta normalizada para a mais próxima; cadastro de cliente pelo código da master continua gravando; script de contraste |

### 15.4 Efeito, riscos e reversão

Todos: cartão igual em todas as visões, hora sempre de Brasília, etiqueta Interestadual. Gestão: filtros novos; paleta no cadastro (cores atuais trocadas pela mais próxima). Operador: mural com o mesmo cartão e filtros. Relatórios e PDF: etiqueta. Riscos: troca de 6 visões de uma vez (testes por visão); Mapbox sem `region` (função local); escolta antiga perto da divisa (lista de conferência). Reversão: `216_..._reverter` (devolve as cores do backup, remove colunas, trigger e malha), `git revert`.

## 16. Onda L: operação offline do operador

### 16.1 Escopo (decisão 7 e S11)

Ações de campo do operador: pré-início (wizard), saída da base, etapas, check-in, parada, ocorrência e emergência (só pelo Campo, onde existem), "estou na base" e chegada na base com KM. Pelo Campo, pelo Painel Guiado e pela tela de detalhe das escoltas do operador. Exigem internet: criar e editar escolta, ações da gestão, finalização (checklist de entrega e relatório final), login. Chave de liga e desliga: `configuracao_avisos.offline_ligado` (lida pelo app; desligada, o app volta a gravar direto, como hoje, e continua esvaziando a fila que já existir).

### 16.2 Migration `219_registro_campo.sql` (bloco 2, depois da 218)

1. `registros_campo` (livro, idempotência e conflitos): `client_id uuid PK` (gerado no aparelho), `usuario_id`, `escolta_id`, `escolta_veiculo_id`, `tipo`, `payload jsonb` (conteúdo completo, com ids das fotos), `versao_gestao_vista` (do snapshot), `data_hora_acao` (relógio do aparelho), `relogio jsonb` (desvio estimado), `recebido_em DEFAULT now()`, `resultado` (`aplicado`, `conflito`), `motivo`, `status_servidor_no_envio`, `tratado_por`, `tratado_em`, `tratamento`. RLS ligada: SELECT o próprio ou G4; sem INSERT, UPDATE nem DELETE diretos (`REVOKE` de anon e authenticated); tratamento só pela RPC `tratar_conflito` (supervisor ou acima). `registros_campo_aparelhos` (auth_user_id, aparelho_id, pendentes, informado_em): cada envio informa quantos registros ainda estão no aparelho (usado na reversão).
2. `registrar_campo(p_client_id, p_tipo, p_payload, p_versao_gestao, p_data_hora_acao, p_relogio)`, SECURITY INVOKER (as gravações rodam com a RLS e as triggers de quem chama, sem privilégio novo). O livro é gravado por `lote_interno.livro_registrar` e `lote_interno.livro_resultado` (SECURITY DEFINER, no schema `lote_interno`, que o PostgREST não expõe; `GRANT USAGE ON SCHEMA` a authenticated e `EXECUTE` só nessas duas, porque a função INVOKER precisa chamá-las; `ALTER DEFAULT PRIVILEGES IN SCHEMA lote_interno REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` antes de criar qualquer função ali, e REVOKE explícito em cada uma). Elas conferem `usuario_id = get_meu_usuario_id()`. Vínculo: com vínculo atual (efetivo ou G4) o registro segue para a gravação. Vínculo perdido: `escolta_efetivo_saidas` (escolta, vigilante, usuário, saiu_em, motivo), gravada por trigger AFTER DELETE e AFTER UPDATE OF vigilante_id em `escolta_efetivo` (inclusive na cascata de uma escolta apagada); quem está nela para aquela escolta, ou ainda está no efetivo de uma escolta arquivada (lido pela função DEFINER, sem a RLS), tem o registro aceito só como conflito (`sem_acesso`, `arquivada` ou `escolta_apagada`, com o payload inteiro), nunca aplicado. Quem nunca teve vínculo com a escolta recebe erro definitivo `SEM_VINCULO`, nada é gravado nem avisado, e o aparelho marca o registro como recusado e o mostra ao operador (nada some em silêncio). A `registrar_campo` trata "escolta não encontrada" no `FOR UPDATE` (invisível pela RLS ou apagada) chamando o livro, que decide entre conflito e `SEM_VINCULO`. O livro guarda também o código da escolta, para a tela de conflitos funcionar com a escolta arquivada ou apagada, e a tela lê por `listar_conflitos` (DEFINER, supervisor ou acima). O resultado (aplicado ou conflito) é decidido pela `registrar_campo`, que tenta a gravação numa subtransação e só então chama `livro_resultado`; a integridade depende de só ela chamar as funções do livro, o que vale porque nenhum caminho exposto executa SQL vindo do cliente (item 4). Avisos de conflito (`lote_interno.notificar`, fila do Telegram) são chamados por `livro_resultado`, com limite de 5 avisos por usuário a cada 10 minutos (os demais ficam só no livro e na tela de conflitos). Emergência que vira conflito ou é recusada pela RLS, com vínculo atual ou perdido: aviso agrupado, o primeiro na hora e os seguintes da mesma pessoa e escolta somados num único aviso a cada 10 minutos, marcado como emergência (fora do limite comum, mas sem alarme ilimitado). O portão do banco testa: `has_function_privilege('authenticated', oid, 'EXECUTE')` falso para toda função do `lote_interno` exceto as duas do livro; operador chamando cada função do `lote_interno` pela API (404); por SQL impersonado, operador só grava o próprio registro e não grava `resultado` de outro. No portão de produção, `POST /rest/v1/rpc/livro_registrar` como operador (404) e conferência dos schemas expostos.
3. Reenvio do mesmo `client_id` devolve o resultado gravado com `duplicado: true`. Ids das linhas vindos do aparelho.
4. Tipos (envelope de transporte, S11): `linhas` (inserts nas tabelas de campo permitidas, exatamente como a tela monta hoje: `fotos`, `pontos_controle`, `checklists`, `checklist_respostas`, `ocorrencias`, `emergencias`, e o UPDATE de KM em `escolta_veiculos`), opcionalmente seguida de `etapa` (a transição pela 207, com a hora da ação no histórico e `criado_offline = true` nos pontos), mais `presenca_base` (RPC da 204). Sem SQL dinâmico: um ramo estático por tabela (as listas de colunas não incluem as colunas da 213, que só as RPCs da gestão e as triggers gravam) (`INSERT INTO public.<tabela> (<colunas fixas>) SELECT <colunas fixas> FROM jsonb_populate_record(NULL::public.<tabela>, item)`), lista fechada de colunas por tabela escrita na função, nenhum identificador vindo do payload; o UPDATE de KM só nas duas colunas de KM, por `escolta_veiculo_id`. Nenhuma regra de etapa nova; a RLS e as triggers de quem chama valem para cada linha. Antes de conferir e gravar, `SELECT ... FOR UPDATE` na escolta (o efetivo já tem UPDATE pela `escoltas_update`), para dois aparelhos não passarem juntos pela conferência.
5. Conflito (nunca descarta): `p_versao_gestao` diferente de `escoltas.versao_gestao` (reset, arquivamento, recuperação ou conclusão antecipada pela gestão depois do snapshot, mesmo que o status tenha voltado ao esperado; a edição não muda a versão), status diferente do esperado, escolta cancelada ou finalizada, operador retirado do efetivo, viatura removida, ponto de etapa válido do mesmo tipo já existente na viatura (só os tipos de `TIPO_PONTO_POR_STATUS`, `base_saida` e `base_retorno`; paradas e check-ins se repetem e nunca entram nessa regra; anulados não contam), recusa de RLS ou trigger. Grava `resultado = conflito` com o payload inteiro, devolve ok ao aparelho (para de reenviar) e avisa a supervisão (tipo `conflito_offline` na Central e fila do Telegram com chave `conflito:<client_id>`).
6. Emergência nunca vira conflito por status nem por versão: grava sempre em `emergencias` (só a RLS recusa, e aí fica no livro com alerta).
7. Telegram dos registros de campo: reserva no banco por `campo:<client_id>` (padrão da 208), texto "Registrado às HH:MM sem conexão, enviado às HH:MM (Brasília)" quando `data_hora_acao` e `recebido_em` diferirem mais de 2 min.
8. `registrar_etapa_escolta` (207) ganha `p_data_hora_acao` por função interna compartilhada (a assinatura atual continua, para não quebrar abas antigas).

### 16.3 Aparelho

1. `lib/offline/fila.ts` (IndexedDB `escolta-campo`, versão 1, sem dependência nova): `registros` (seq, `client_id`, `auth_user_id`, escolta, tipo, payload, `versao_gestao` vista, fotos, hora e GPS da ação, prioridade, estado, tentativas, erro), `fotos` (blob carimbado gravado no momento da captura, caminho determinístico `campo/{escolta}/{foto_client_id}.jpg`), `snapshot` (perfil, escoltas do operador com `versao_gestao`), `recibos` (7 dias).
2. `lib/offline/envio.ts`: gatilhos `online`, `visibilitychange`, 30 s com o app aberto e após cada registro; exclusão entre abas por `navigator.locks`; emergência primeiro, depois na ordem de registro; para cada um, sobe as fotos (objeto já existente conta como sucesso), chama `registrar_campo`, marca o resultado; falha de rede para a fila com espera crescente; `auth.refreshSession()` antes; sessão que não renova para a fila e pede novo login do mesmo usuário; fila por `auth_user_id`; sair com pendentes avisa; informa a contagem de pendentes ao servidor.
3. `lib/offline/registro-campo.ts`: envelope de transporte (S11). Cada tela continua montando as próprias linhas, como hoje; a biblioteca só guarda e envia. Online, espera a resposta e devolve como hoje; offline, devolve "guardado no aparelho".
4. Leituras offline: o service worker guarda as respostas GET do Supabase REST das escoltas do operador (network-first, 4 s, cache por usuário, apagado no logout e na troca de usuário) e as telas aplicam por cima os pendentes da fila (`aplicarPendentes`: status otimista e pontos pendentes), no `carregar` do Campo e no `loadData` do detalhe. URLs assinadas das fotos (POST) não entram no cache: offline, as fotos já enviadas aparecem como "foto indisponível sem conexão" e as pendentes a partir do blob local.
5. `useAuth` offline: perfil do snapshot por `auth_user_id`, sem redirecionar ao login; `ultimo_acesso` só online.
6. Service worker (`public/sw.js`, versão por BUILD_ID gerada no build): `/_next/static/*` cache-first; navegação `/dashboard`, `/dashboard/campo` e `/dashboard/escoltas/<id>` network-first com fallback ao cache e `ignoreSearch` (o Painel abre o detalhe com `?volta=campo&acao=`); com internet, o SW pré-carrega o HTML do detalhe de cada escolta do snapshot e os scripts e estilos que esse HTML cita (e os do Campo e do Painel, lidos do manifesto do build), para a página abrir sem internet mesmo num aparelho que nunca abriu um detalhe nesta versão. Navegação feita pelo roteador do Next sem internet: o pedido do payload RSC falha e o roteador cai para navegação completa, que o SW atende pelo cache; conferido no teste L8 por clique no Painel, não por `goto`. Demais telas offline mostram "Esta tela precisa de internet. Volte ao Painel"; `/api/*` nunca em cache; chunks da versão anterior mantidos até as abas antigas fecharem. `navigator.storage.persist()` pedido no primeiro login.
7. Faixa fixa no topo ("Sem conexão. N registros guardados no aparelho"; âmbar enviando; some com zero) e contador no Painel. Confirmação offline: "Guardado no aparelho. Será enviado quando houver sinal", nunca "a central foi avisada".
8. Emergência offline (Campo): tela vermelha fixa "SEM CONEXÃO: NINGUÉM FOI AVISADO. Use o rádio ou ligue para a central agora", botão `tel:` (número da central de `configuracao_avisos` ou do cadastro; sem número, só o texto), envio prioritário ao voltar.
9. Tela `/dashboard/conflitos` (supervisor ou acima): lista, conteúdo completo, fotos por URL assinada, marcar tratado com justificativa. Operador vê "N registros não aceitos; a supervisão foi avisada", sem poder apagar.
10. Mudança no detalhe (mínima, regra 7 com a exceção do adendo): nos handlers de campo do detalhe (wizard, saída da base, parada, check-in, as 6 etapas intermediárias, chegada na base), o trecho de gravação passa as mesmas linhas a `registrarCampo` em vez de gravar direto; `loadData` chama `aplicarPendentes`; as fotos passam pela fila. Sem reorganizar a tela. Chamadas de rede desses handlers e o que acontece sem internet:

    | Chamada | Onde | Sem internet |
    |---|---|---|
    | `conferirEtapa` (leitura do status antes de gravar) | `:1490`, `:1643` | pula; a conferência fica no servidor (conflito) |
    | Upload de foto ao Storage | `uploadFotosPonto` e equivalentes | vai para a fila (blob) |
    | Endereço por extenso (Mapbox reverso) | `reverseGeocode` `:1852`, usado em `:1877`, `:1945`, `:2628` | pula; endereço nulo; o servidor não preenche depois |
    | `notificarTelegram` | handlers de etapa | não chama; o aviso sai pela reserva `campo:<client_id>` no envio |
    | `createSignedUrls` | `loadData` | item 4 |
    | Releitura `loadData` depois de gravar | todos | lê do cache e aplica os pendentes |

11. Defeitos atuais corrigidos no caminho: `carregar` do Campo sem leitura de erro (esvazia a tela sem sinal), ocorrência, checklists e respostas sem leitura de erro, foto do detalhe com hora do upload e `carimbo_aplicado: false`, check-in com a hora do envio.
12. Manual (`docs/09`) e relatório: no iPhone, envio só com o app aberto; instalar na tela de início; registro só no aparelho se perde se o aparelho for perdido ou limpo antes do envio; hora vem do relógio do aparelho; teste em aparelho real obrigatório antes de depender do offline.

### 16.4 Critérios de aceite e testes

Playwright com `context.setOffline` e `route.abort`, contexto com `serviceWorkers: 'allow'` e `PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1` (para interceptar o que passa pelo SW).

| Teste | Esperado |
|---|---|
| L1 Fluxo completo offline e volta | login online, abrir o Campo (instala o SW, o cache e o snapshot), offline, recarregar (abre do cache), abrir o detalhe pelo Painel (clique), wizard com duas viaturas, saída, etapas até a chegada na base com KM, check-in e parada pelo detalhe, ocorrência pelo Campo; faixa e contador; banco intocado; online; contador zera; cada registro uma vez, hora da ação menor que `recebido_em`, histórico na ordem, `criado_offline = true`, Telegram falso com uma mensagem por registro |
| L2 Queda no meio do envio de foto | rota que deixa o upload chegar e devolve erro ao aparelho, e rota que corta antes; depois de reconectar: um objeto, uma linha em `fotos`, um ponto |
| L3 Dois aparelhos da mesma escolta | qa_um e qa_dois offline registram a mesma etapa (cada um na sua viatura e os dois na mesma); reconexão alternada e simultânea; uma transição, um ponto por viatura, excedente em conflito com payload e fotos. Dois check-ins e duas paradas seguidos offline: todos aplicados |
| L4 Mudança pela gestão durante o offline | gestor zera; em outra rodada arquiva; em outra conclui; em outra volta uma etapa e avança de novo até o status que o registro esperava; reconecta; nada aplicado, tudo em conflito pela versão, visível ao supervisor, aviso na Central. Em outra, o gestor só edita a observação durante o offline: tudo aplicado, nada em conflito. Em outra, o operador é retirado do efetivo pela edição e, em outra, substituído pelo mural, e em outra a escolta é arquivada: tudo em conflito (`sem_acesso`), visível ao supervisor, e o aparelho para de reenviar; emergência nesse caso gera aviso imediato |
| L5 Fila com muitas fotos | 40 fotos de 3 a 5 MB offline, recarregar no meio, fechar durante o envio e reabrir; tudo sobe uma vez e na ordem; registra `navigator.storage.estimate()` |
| L6 Emergência offline | tela vermelha com o texto e o botão de ligar; primeira a subir ao reconectar |
| L7 Banco | SQL: mesmo `client_id` duas vezes, uma linha; operador não lê o livro dos outros, não grava no livro direto nem pelas funções do `lote_interno` em nome de outro, não muda `resultado`; conflito não é apagável; payload com nome de tabela ou coluna fora da lista é recusado; 20 conflitos forjados em 1 minuto geram no máximo 5 avisos; usuário sem nenhum vínculo com a escolta (inclusive com `escolta_id` inexistente) recebe `SEM_VINCULO` e nada é gravado nem avisado; 10 emergências seguidas de quem perdeu o vínculo geram 1 aviso imediato e 1 agrupado; escolta apagada pela gestão vira conflito `escolta_apagada` para quem estava no efetivo |
| L8 App abre offline em página nova | sim, no Campo e no detalhe de escolta do snapshot (por recarga e por clique no Painel); outras telas mostram o aviso |
| L9 Chave desligada | `offline_ligado = false`: grava direto como hoje; fila já existente continua sendo enviada |
| Aparelho real | não é possível na VPS (sem Android nem iPhone): registrado como pendente de teste em campo, com roteiro no manual |

### 16.5 Efeito, riscos e reversão

Operador: segue sem sinal com faixa e contador; registros sobem sozinhos; emergência offline avisa que ninguém foi avisado. Supervisor ou acima: tela de conflitos e aviso de conflito. Gestão: criar e editar continuam online. Telegram: mensagens de registros feitos offline saem na volta da conexão, com as duas horas. Detalhe: trechos de gravação dos handlers de campo trocados (risco médio, coberto pelas jornadas completas da Fase 4). Riscos que não dá para eliminar: aparelho perdido com fila, iPhone sem segundo plano, relógio do aparelho, espaço, primeira posição de GPS lenta sem dados.

Reversão em duas etapas, para não perder fila: (1) `offline_ligado = false` (nada novo entra na fila; os aparelhos continuam enviando o que guardaram); (2) só quando todos os aparelhos que informaram nos últimos 7 dias estiverem com zero pendentes em `registros_campo_aparelhos`, `git revert` com um `sw.js` de reversão que apaga os caches e se desregistra, e `219_..._reverter` (guarda o livro em `backup_20261008`).

## 17. Ondas existentes ajustadas pelo adendo

| Onda | Ajuste |
|---|---|
| B | Alerta fixo com X dá lugar ao aviso de 2 s e à Central (J); o item 2.2.3 sai. Periodicidade desligada continua |
| C | Avisos de pedido, decisão e substituição na Central e no sino (217); auditoria em `devolver_escolta` (217); filtro de arquivada nas RPCs (218) |
| D | Acréscimos da seção 14 |
| E | `editar_escolta` (218) preserva combustível, como a Nova já fazia |
| F | `registrar_etapa_escolta` passa a ignorar anulados (214), a recusar arquivada (218) e a aceitar a hora da ação (219) |

## 18. Branches, ordem, publicação e registro

1. Ordem de execução: G, J, I, H, D2, K, L, sobre a branch F (empilhadas: `melhoria/2026-10-onda-g-efetivo`, `-onda-j-avisos`, `-onda-i-gestao`, `-onda-h-passo2`, `-onda-d2-locais`, `-onda-k-visual`, `-onda-l-offline`). Desvio declarado da ordem final do adendo (A, G, B com J, C, I, H, D, K, E, F, L): as ondas A a F já estão prontas em branches empilhadas com PRs abertos, e o adendo manda ajustá-las "sem descartar o trabalho feito" (1.3); refazer a pilha para intercalar G e J custaria rebase de seis branches com conflito nos mesmos arquivos e a repetição de todos os portões, sem ganho para o Peçanha, porque a publicação é um pacote com uma confirmação (decisão 9). A D2 vem antes da K: o atalho preenche a UF só quando a coluna da 216 existir (o código confere), e o teste de UF no atalho roda depois da K.
2. Migrations e blocos (o bloco 1 é compatível com o código da master `2b3fff9`; o bloco 2 vem depois do deploy):

| Bloco | Ordem de aplicação |
|---|---|
| 1 | 196, 197, 198, 199, 201, 202, 203, 205, 206, 207, 208, 209, 211, 212, 213, 214, 215, 216 |
| 2 | 204, 210, 200, 201 (reaplicada), 217, 218, 219 |

   Reversões na ordem inversa. A homologação passa a aplicar as migrations na ordem dos blocos, não na numérica (`fase4-recriar-e-testar-banco.sh` lê a ordem do PACOTE), e o portão do banco de cada onda aplica a migration nova sobre o banco montado nessa ordem.
3. Teste da janela entre o bloco 1 e o deploy: worktree só leitura da master `2b3fff9` (build na porta 3101) contra o banco com o bloco 1 inteiro aplicado: jornada completa do operador pelo Campo e pelo detalhe, criação e edição pela gestão, cadastro de cliente com cor livre, mural antigo, numa escolta iniciada que recebeu UF pela carga da 216 (avançar status pelo operador, supervisor e central). Nada pode quebrar.
4. Dependências e "publicar sem X" (tabela 8.1 ampliada):

| Onda | Depende de | Pode sair sozinha? | Se sair |
|---|---|---|---|
| A | nada | não recomendado (segurança) | como na 8.1 |
| G | C (`mural_info`) | sim | volta a corrida da aba e a escolta da outra dupla como livre |
| B | nada | sim | como na 8.1; o aviso de 2 s (J) continua |
| J | 211 (fica sempre, porque C e I usam `lote_interno.notificar`) | sim, só a parte de tela e o cron 212 | alerta fixo de hoje volta; avisos do mural e da gestão continuam gravados e aparecem no mural, sem sino |
| C | 202 | não, se G, J ou I forem publicadas (217 e 218 alteram a 204) | |
| I | 211, 203 e 204 (C), 207 (F) | sim, se L também sair | sem reset, arquivo e conclusão; edição como hoje |
| H | nada | sim | KM e foto voltam ao Passo 3 |
| D | nada | sim, junto com D2 | |
| D2 | D | sim | atalhos sem uso e sem "salvar este endereço" ao lado do campo |
| K | nada | sim | sem cor padronizada, cartão, filtros e UF; D2 não preenche UF |
| E | nada | sim | |
| F | 202 | não, se I ou L forem publicadas (alteram a 207) | |
| L | 207 (F), 213, 214 e 218 (I), 211 | sim | grava direto como hoje |

   Cada combinação pedida passa por todos os portões na branch de publicação (seção 8.1), com o pacote reduzido aplicado do zero na ordem dos blocos. Funções reescritas em cadeia (`registrar_etapa_escolta`: 207, 214, 218 e 219; funções do mural: 204, 217 e 218; alertas: 208, 212 e 214): o portão do banco confere, no banco final, que o corpo de cada uma tem todos os acréscimos (filtro de anulado, recusa de arquivada, hora da ação, `lote_interno.notificar`, ligação da variável `escolta.historico_rpc`) e um teste confirma que o histórico gravado por elas sai com `via_rpc = true`.
5. Publicação (atualiza a 8.2): bloco 1 com uma resposta "aplicado 1"; caminho padrão: um push único da última branch da pilha (ou da branch de publicação, com "publicar sem X"), pelo Peçanha; bloco 2 com "aplicado 2" logo depois desse deploy; depois, o portão de produção de todas as ondas. É o único estado intermediário (bloco 1 com a master; código novo sem o bloco 2 por minutos), e os dois são testados (item 3 e o teste "código novo sem o bloco 2": mural, ações da gestão e offline mostram "Atualização em andamento", a edição pela Nova também, e nada grava pela metade). Se o Peçanha pedir onda a onda, o bloco 2 é dividido em 2a (204, 200, 201, logo depois do push de C; a 210 logo depois do push de G) e 2b (217, 218, 219, logo depois do push de L), e cada estado intermediário usado é testado antes (no caminho onda a onda, o 2b se divide em dois: 217 e 218 logo depois do push de I, e a 219 logo depois do push de L); portão de produção do mural, das fotos, das ações da gestão e do offline (só leitura e uma escolta de teste criada e arquivada pela gestão, se o Peçanha autorizar no "publicar"). Entre o deploy e o bloco 2, as telas novas que chamam RPC do bloco 2 mostram "Atualização em andamento" (mural, ações da gestão, offline desligado até `registrar_campo` existir).
6. Registro do adendo (seção 5 do adendo): subtarefas G, H, I, J, K e L na tarefa-mãe 868md6rr5 da lista 901114078269, com status de validação no relatório de prontidão; uma seção por onda nova no relatório de prontidão e no final, com o efeito por perfil; comunicado aos operadores e à gestão (`/opt/operacao/escolta-homolog/entrega/comunicado-operadores.md`) com Passo 2 e 3, notificações, reset e offline com as limitações.
7. Tamanho: G pequeno; H pequeno; D2 pequeno; J médio; K médio; I grande; L muito grande. Se uma onda não passar nos portões em três tentativas, sai do pacote e vai como pendente no relatório (Fase 4.3), respeitando a tabela do item 4.

8. Menores da rodada 9, incorporados antes da execução:
   1. A trigger que grava `escolta_efetivo_saidas` é SECURITY DEFINER (sem GRANT); `escolta_id` fica sem chave estrangeira nas saídas e no livro (o caso `escolta_apagada` depende disso); a reversão da 219 lista a trigger e a tabela.
   2. O aviso agrupado de emergência é fechado pelo cron de minuto da 212 (que passa a chamar `lote_interno.fechar_avisos_agrupados()` na 219).
   3. G4 que registrar pela fila e perder o acesso (escolta arquivada) tem o registro aceito como conflito, como o operador; `SEM_VINCULO` fica só para quem nunca teve vínculo nem é G4.
   4. O motivo visível ao operador no próprio livro é sempre `sem_acesso`; o detalhe (`arquivada`, `escolta_apagada`, `retirado`) vai em `motivo_detalhe`, sem SELECT para authenticated (GRANT por coluna), lido pela `listar_conflitos`. O L4 confere que a linha da escolta arquivada mostra o código.
   5. `envio.ts` tem o estado `recusado` (`SEM_VINCULO`): o registro fica visível ao operador em "Registros recusados" e não é reenviado; teste Playwright no L7.
   6. Decisão 1 do adendo ("arquivar, nunca apagar") no servidor: a 214 troca a `escoltas_delete` por uma RESTRICTIVE que só permite ao administrador apagar escolta em rascunho sem nenhum registro de campo; teste na 12.6 (gestor e administrador não apagam escolta agendada ou iniciada pela API).
   7. `anulado_por`, `arquivada_por`, `concluida_por` e `feito_por` com chave estrangeira sem ação para `usuarios` (não `SET NULL`): excluir um usuário que anulou ou arquivou algo é recusado com mensagem, em vez de esbarrar na trava da 213.6; o app já inativa em vez de excluir quando há vínculo.

## Apêndice: rodadas do portão do plano

| Rodada | Nota | Principais problemas |
|---|---|---|
| 1 | 5 | função interna exposta (operador pulava a aprovação); 201 gravava em `metadados` das escoltas protegidas; T2 sem mural; corrida entre decisões; liberação e Telegram dependentes de navegador; F1 sem o ponto; critério da M1 nos pontos; 200 podia apagar policy de upload; dependências entre ondas; backups em `public`; ordem de publicação; histórico do Git; testes por critério |
| 2 | 7 | extensões só confirmadas na homologação; F podia calar o Telegram atual; T6 com furo em devolver e incluir; arquivos compartilhados entre ondas; 200 só pegava a forma exata da policy; execução antecipada |
| 3 | 8 | onda C sem fallback de Telegram; policy de storage sem filtro de bucket; token no SQL Editor; roteiro de push na retirada de onda; numeração |
| 4 | 9 | aprovado no portão; menores tratados na execução: destino central no fallback de C, link do Vault, teste do fallback da F |
| 5 | 6 | Parte 2 (adendo 01): funções da 204 alteradas no bloco 1; dependências de colunas entre migrations; matriz de dependências; anulação do reset; SECURITY INVOKER chamando funções internas; conflito depois de reset; offline pela tela de detalhe; CHECK de paleta contra a master; ESC-0001 e 0007 na carga de UF; central editando equipe; reversão da L |
| 6 | 7 | coluna gerada na comparação da 214; destino do reset pelo histórico forjável; versão da gestão na edição; check-ins como conflito; SQL dinâmico e privilégios do `lote_interno`; checklist de entrega com o mesmo tipo; publicação em estados não testados |
| 7 | 8 | operador retirado ou escolta arquivada durante o offline sem conflito registrado; menores de texto, âncora da anulação antiga, fluxo 1, trava de INSERT, UF na trava do operador, divisão do bloco 2 onda a onda |
| 8 | 8 | livro aceitando conflito e emergência de quem nunca teve vínculo; trava de INSERT contra o carimbo e o padrão de `versao_gestao`; menores de aviso de emergência, tela de conflitos com arquivada, cadeia do `historico_rpc`, âncora do fluxo 1 |
| 9 | 9 | aprovado no portão; menores incorporados na seção 18.8 |
