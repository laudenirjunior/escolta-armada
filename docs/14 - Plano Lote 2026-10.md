# Plano Técnico do Lote 2026-10

Fase 2 do lote de 08/10/2026. Base: `docs/13 - Analise Completa 2026-10.md`. Decisões de Peçanha de 08/10/2026 10h48 (comando do lote, seção 2). Rodada 4, revisada depois das críticas das rodadas 1 (nota 5), 2 (nota 7) e 3 (nota 8). As rodadas e as notas estão no apêndice; as críticas completas, em `docs/14-rodadas/`.

## 0. Regras que valem para todas as ondas

1. Uma branch por onda, cada uma partindo da anterior: `melhoria/2026-10-onda-a-seguranca`, `-onda-b-checkin`, `-onda-c-mural`, `-onda-d-locais`, `-onda-e-combustivel`, `-onda-f-divida`. Arquivos compartilhados entre ondas (Nova, detalhe, Campo) recebem commits separados por onda, com mensagem que diz a onda, para permitir retirar uma onda por `git revert` (seção 8). Nenhum merge na master antes do "publicar".
2. Migrations em `database/migrations`, a partir de 196, idempotentes, com cabeçalho do porquê e reversão `NNN_..._reverter.sql`. Portão do banco por migration: `testar-migration.sh` aplica, reaplica (idempotência), reverte, compara o esquema (pg_dump de `public` e `storage`) com o anterior e reaplica.
3. SECURITY DEFINER: guarda `v_perfil IS NULL OR v_perfil NOT IN (...)` quando houver restrição de perfil; `REVOKE ALL ... FROM PUBLIC, anon`; `GRANT EXECUTE ... TO authenticated` só para RPC chamada pelo cliente; funções internas sem GRANT a ninguém; `SET search_path TO 'public', 'pg_temp'` (mais `extensions` ou `net` quando usar). Funções que gravam são VOLATILE.
4. Toda escrita nova no cliente confere linhas afetadas com `.select('id')`. Toda view nova com `security_invoker = on`.
5. Backups de reversão ficam no schema `backup_20261008` (não exposto pelo PostgREST, `REVOKE ALL` de `anon` e `authenticated`), como no backup de 19/08. Tabelas novas em `public` nascem com RLS ligada; as que só RPC acessa ficam sem policy e com `REVOKE ALL` de `anon` e `authenticated`.
6. Horário em mensagens geradas pelo banco: `to_char(x AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')`.
7. Proibido neste lote (regra 1.10): Caminho 2 (um escritor por etapa em `lib/etapas.ts`), gravações só na primeira viatura, fila offline, cache no service worker, migração de paleta, decomposição de `app/dashboard/escoltas/[id]/page.tsx`. Mudança na tela de detalhe só o mínimo, listado por onda.
8. ESC-2026-0001 e ESC-2026-0007: só a periodicidade é zerada (onda B), com backup fora da escolta. Mudam também, de forma automática e sem efeito de negócio, `atualizado_em` (trigger existente, no UPDATE da periodicidade) e a coluna nova `escala_fixa`, que nasce `false` em todas as escoltas. Status, histórico, equipe, pontos e `metadados` não mudam.
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

Trigger `impedir_combustivel_por_operador` em `escolta_veiculos` (BEFORE UPDATE, SECURITY DEFINER, sem GRANT): quem não é G4 não altera `abastecimento_litros` nem `abastecimento_valor`. CHECK de não negativo com `NOT VALID` e `VALIDATE`.

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

Publicar sem uma onda X: branch de publicação a partir da última onda com `git revert` dos commits de X (mais novos primeiro); conflito em arquivo compartilhado é resolvido à mão, mantendo o que as outras ondas fizeram; pacote SQL sem as migrations de X (e sem a 202 só se C e F saírem juntas). Na branch de publicação repetem-se todos os portões: código, banco (banco recriado do zero com o pacote reduzido) e funcional por perfil. Feito por mim antes de qualquer push.

### 8.2 Caminho de DDL e blocos

Não há conexão ao banco de produção configurada na VPS nem token da API de gerenciamento (Fase 0, item 4). O esquema de 08/10 foi exportado pelo Peçanha, no terminal dele, com a connection string digitada por ele. O pacote, portanto, é aplicado pelo Peçanha em dois blocos, cada um com uma resposta:

1. Antes de tudo: backup novo conferido e a consulta das policies de `storage`.
2. Bloco 1 (antes do deploy, tudo compatível com o código atual): 196, 197, 198, 199, 201, 202, 203, 205, 206, 207, 208, 209, mais o segredo do Telegram no Vault. Resposta: "aplicado 1".
3. Push das ondas para a master, uma a uma, pelo Peçanha: desvio declarado do comando ("merge das ondas na ordem" seria meu), porque o controle de permissões desta VPS bloqueia o meu push na master desde 29/09. Roteiro para o celular, um comando por onda, sempre o mesmo formato: `! git -C /opt/operacao/escolta-armada push origin melhoria/2026-10-onda-a-seguranca:master` (troca só a letra e o nome da onda); depois de cada um, eu rodo o portão de produção e digo "pode mandar a próxima" ou reverto. Com "publicar sem X", há uma branch única de publicação (`melhoria/2026-10-publicacao`): um push só, `! git -C /opt/operacao/escolta-armada push origin melhoria/2026-10-publicacao:master`, e o portão de produção roda os itens de todas as ondas publicadas nessa vez. Se a master tiver andado desde `2b3fff9`, o push é recusado (não é fast-forward): eu faço o rebase das branches sobre a master nova, repito todos os portões na homologação e mando o roteiro de novo; nunca push forçado.
4. Bloco 2 (logo depois do deploy de C e de A): 204 (RPCs do mural) e 200 (fechar o bucket). Resposta: "aplicado 2". Portão de produção do mural e das fotos.
5. Se parar entre o bloco 1 e o deploy, nada quebra: o bloco 1 é compatível com o código atual. Se parar entre o deploy e o bloco 2, o mural novo não oferece substituição de equipe ("Atualização em andamento", pela ausência de `mural_travas_ativas`), puxar escolta livre continua, e as fotos funcionam por URL assinada com o bucket ainda público.

## Apêndice: rodadas do portão do plano

| Rodada | Nota | Principais problemas |
|---|---|---|
| 1 | 5 | função interna exposta (operador pulava a aprovação); 201 gravava em `metadados` das escoltas protegidas; T2 sem mural; corrida entre decisões; liberação e Telegram dependentes de navegador; F1 sem o ponto; critério da M1 nos pontos; 200 podia apagar policy de upload; dependências entre ondas; backups em `public`; ordem de publicação; histórico do Git; testes por critério |
| 2 | 7 | extensões só confirmadas na homologação; F podia calar o Telegram atual; T6 com furo em devolver e incluir; arquivos compartilhados entre ondas; 200 só pegava a forma exata da policy; execução antecipada |
| 3 | 8 | onda C sem fallback de Telegram; policy de storage sem filtro de bucket; token no SQL Editor; roteiro de push na retirada de onda; numeração |
| 4 | 9 | aprovado no portão; menores tratados na execução: destino central no fallback de C, link do Vault, teste do fallback da F |
