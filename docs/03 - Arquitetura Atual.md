# Arquitetura Atual

> **Atualização do lote 2026-10 (08/10/2026).** Números de 08/10 antes do lote: 34 tabelas no `public` (a `usuarios_credenciais` entrou depois deste documento), 73 policies, 31 funções. As rotas `/api/telegram` e `/api/ai/melhorar-texto` exigem sessão e o `middleware.ts` está ativo (ver `docs/12`, 4.1 e 4.2). O histórico de status **não** é mais gravado em dobro: a trigger `tr_registrar_historico_status` foi removida de produção antes de 08/10 e a remoção ficou versionada na migration 209; desde a onda F, status e histórico de cada etapa são gravados juntos pela RPC `registrar_etapa_escolta` (207). O bucket `fotos` passa a privado na onda A (migration 200), com leitura por URL assinada. As seções abaixo descrevem o estado anterior e ficam como registro; a análise atual está em `docs/13 - Analise Completa 2026-10.md`.

**Projeto Supabase:** `qthoyxujyzskydulvcfy` (escolta-armada, us-east-2, plano Free, branch `main` em produção)

Next.js 14 App Router, Supabase (Postgres 17), Tailwind 3, Mapbox GL. Sem biblioteca de gráficos.

## Aviso sobre migrations

O schema real **só existia no Supabase**, sem versionamento. Os 7 arquivos que estavam em `database/migrations/` descreviam uma v1 que nunca existiu neste banco: chaves `SMALLINT`, `usuarios.auth_id`, `escoltas.status_id`.

Foram para `database/_legado_v1/`. **Não execute nenhum deles.** O `007` redefine `auth.uid()` como `SELECT auth.uid()`, recursão infinita que sobrescreveria a função do próprio Supabase e quebraria toda a autenticação.

As migrations válidas começam no número 100 e são aplicadas via MCP, registradas em `supabase_migrations.schema_migrations`.

## Tabelas

33 no schema `public`, **todas com RLS ligada**.

| Grupo | Tabelas |
|---|---|
| Domínio | `dom_perfis`, `dom_funcoes`, `dom_calibres`, `dom_tipos_armamento`, `dom_tipos_veiculo`, `dom_tipos_ocorrencia`, `dom_tipos_evento`, `dom_tipos_foto`, `dom_tipos_ponto` |
| Acesso | `usuarios`, `vigilantes` |
| Cadastros | `clientes`, `veiculos`, `armamentos` |
| Operação | `escoltas`, `escolta_veiculos`, `escolta_efetivo`, `escolta_armamentos` |
| Campo | `pontos_controle`, `rastreamento`, `presencas`, `fotos`, `ocorrencias`, `emergencias` |
| Checklists | `checklist_modelos`, `checklist_modelo_itens`, `checklists`, `checklist_respostas` |
| Sistema | `escolta_status_historico`, `atualizacoes_status`, `notificacoes`, `logs_auditoria`, `chat_mensagens` |

## Ligações que confundem

| Coluna | Referencia | Cuidado |
|---|---|---|
| `escolta_efetivo.vigilante_id` | **`vigilantes(id)`** | As políticas antigas faziam `JOIN usuarios u ON u.id = ee.vigilante_id`, que nunca casava nada. O caminho correto passa por `vigilantes.usuario_id` |
| `pontos_controle.escolta_veiculo_id` | `escolta_veiculos(id)` | Não aponta para `escoltas` direto |
| `checklists.escolta_veiculo_id` | `escolta_veiculos(id)` | `checklists` **não tem** `escolta_id` |
| `pontos_controle.foto_id` | `fotos(id)` | Escalar. O schema comporta uma foto por ponto; as demais ficam num JSON em `observacoes` |
| `escolta_efetivo (escolta_id, vigilante_id)` e `escolta_veiculos (escolta_id, veiculo_id)` | índices únicos da 210 (lote 2026-10, onda G, bloco 2) | O mesmo vigilante entra uma vez só em cada escolta, em qualquer viatura, e a mesma placa uma vez só por escolta. As RPCs do mural (204) recusam a repetição com mensagem e invalidam o pedido que esbarrar no índice |

## Funções

19 no `public`. Nenhuma `SECURITY DEFINER` é executável por `anon`.

| Categoria | Funções | Regra de acesso |
|---|---|---|
| Resolvedores de identidade | `perfil_usuario_atual`, `get_meu_perfil`, `get_meu_usuario_id`, `get_meu_vigilante_id` | `authenticated` mantido: **as políticas de RLS dependem delas** |
| Escopo de efetivo | `sou_do_efetivo`, `sou_do_efetivo_veiculo` | `authenticated` |
| RPC de cliente | `criar_usuario_por_login`, `cadastrar_operador`, `redefinir_senha_usuario`, `excluir_auth_usuario` | `authenticated`, com guarda `IS NULL OR` de perfil |
| Trigger | `validar_transicao_status_escolta`, `exigir_ponto_transito_retorno`, `impedir_autopromocao`, `registrar_historico_status_escolta`, `verificar_checklist_pendente`, `gerar_codigo_escolta`, `update_atualizado_em`, `sync_auth_user_on_usuarios` | Sem semântica de chamada |
| Obsoleta | `criar_usuario_completo` | **Revogada.** Criava contas sem `auth.identities`, que nasciam sem conseguir entrar |

**A regra que não pode ser esquecida:** toda função `SECURITY DEFINER` nova precisa de `REVOKE EXECUTE FROM anon, PUBLIC`, guarda `IF perfil IS NULL OR perfil NOT IN (...)` e `SET search_path`. Em SQL, `NULL NOT IN (...)` é NULL, e `IF NULL THEN` não dispara: foi assim que qualquer anônimo podia criar um administrador.

## Central de avisos e schema `lote_interno` (lote 2026-10, onda J)

- **`notificacoes` é a central de avisos de cada pessoa** (migration 211): uma linha por destinatário e por evento, com `titulo`, `texto`, `criado_em`, `lida_em` e `evento_chave` (índice único `(evento_chave, usuario_dest_id)`). `lida` continua existindo e o gatilho `tr_notificacoes_sincronizar_lida` a mantém em acordo com `lida_em` nos dois sentidos. Lidos há mais de 90 dias são apagados pelo cron.
- **Acesso:** SELECT só da própria caixa (`usuario_dest_id = get_meu_usuario_id()`, decisão S5: a gestão não lê a caixa dos outros; a auditoria continua em `logs_auditoria`). Nenhuma escrita direta: `anon` sem privilégio nenhum, `authenticated` sem INSERT, UPDATE, DELETE e TRUNCATE. O app lê e marca só por RPC: `meus_avisos(p_tipo, p_escolta_id, p_so_nao_lidas, p_limite, p_antes)`, `contar_avisos_nao_lidos()`, `marcar_aviso_lido(p_notificacao_id)` (204, grava `lida_em` desde a 217) e `marcar_todos_lidos(p_tipo)`.
- **Quem grava:** só `lote_interno.notificar(p_chave, p_escolta_id, p_tipo, p_usuarios, p_titulo, p_texto, p_extra)`, SECURITY DEFINER, sem `auth.uid()`, `ON CONFLICT DO NOTHING`. Chamam: o cron do check-in (212) e `_avisar_app` do mural (217, chave `<tipo>:<pedido_id>`).
- **Schema `lote_interno`:** funções internas do adendo 01 (fora dos schemas do PostgREST). Nenhuma função dele é executável por `anon` ou `authenticated`: o `ALTER DEFAULT PRIVILEGES ... IN SCHEMA` da 211 não retira o EXECUTE global de PUBLIC (limite do PostgreSQL), então **toda função nova no `lote_interno` precisa de `REVOKE ALL ... FROM PUBLIC, anon, authenticated` explícito** (conferido em `04_lote_2026_10_j.sql`).
- **Cron `lote2026_avisos_checkin`** (pg_cron, a cada minuto, 212): `lote_interno.gerar_avisos_checkin()` calcula o check-in vencido no banco (porte de `minutosAteCheckin`: referência = último PARADA `reporte_periodico`, senão o primeiro ponto, senão a data prevista), grava um aviso por período vencido (chave `checkin:<escolta>:<epoch da referência>:<n do período>`) para o efetivo, administrador, gestor, supervisor e central (S2) e enfileira o Telegram pela regra antiga da 208 (`lote_interno.enfileirar_alerta_checkin`; S4, pendência 0.3). O navegador não calcula mais atraso nem manda Telegram de check-in.
- **App:** `components/avisos-provider.tsx` (no layout) lê o contador e os não lidos a cada 20 s, mostra cada aviso novo no canto por 2 s e alimenta o sino e o item Avisos da barra inferior; a página Avisos tem a aba Central (`components/avisos/central-avisos.tsx`), a Atividade (feed antigo, só gestão) e o Chat. `checkin-alert-provider.tsx` saiu; `alertas_dispensados` ficou sem uso (sai com a reversão da 201).

## Triggers em `escoltas`

| Trigger | Momento | Papel |
|---|---|---|
| `tr_gerar_codigo_escolta` | BEFORE INSERT | Gera `ESC-AAAA-NNNN` |
| `tr_validar_transicao_status` | BEFORE UPDATE OF status | A máquina de estados de 9 etapas |
| `tr_exigir_transito_retorno` | BEFORE UPDATE OF status | Exige o ponto de trânsito antes de concluir o retorno |
| `tr_verificar_checklist_pendente` | BEFORE UPDATE OF status | Marca pendência de checklist |
| `tr_registrar_historico_status` | AFTER UPDATE OF status | Grava o histórico |

**Defeito conhecido, não corrigido:** o histórico é gravado em dobro. A trigger insere e o app insere de novo em 12 pontos. São 111 linhas onde deveria haver cerca de 71, com 58 sem autor.

## RLS

70 políticas, 52 usando a forma `(select fn())`, que vira InitPlan e é avaliada uma vez por consulta em vez de por linha.

Modelo geral:

- **Gestão** (`administrador`, `gestor`, `supervisor`, `central`): vê tudo do operacional
- **Operador**: vê apenas o das escoltas em que está no efetivo
- **`usuarios`**: cada um lê a própria linha; gestão lê todas; ninguém altera o próprio perfil
- **`dom_*`**: leitura livre para autenticado, porque alimentam o menu e são listas fixas
- **`chat_mensagens`**: só remetente e destinatário

## Storage

Bucket único `fotos`, **público**. Não foi fechado: fechá-lo quebraria o `sendPhoto` do Telegram, que busca a URL anonimamente do servidor deles. A solução seria enviar os bytes em `multipart` e usar URL assinada nas telas, o que ficou pendente.

## Débitos conhecidos

| Item | Situação |
|---|---|
| `/api/telegram` e `/api/ai/melhorar-texto` | Sem autenticação. Proxy aberto e faturado |
| `middleware.ts` | `matcher: []`, nunca roda |
| Bucket `fotos` público | Foto operacional com GPS acessível por URL |
| Histórico em dobro | 111 linhas, ~40 duplicatas |
| Offline | Não existe. `criado_offline` é literal `false` |
| `rastreamento`, `presencas` | Praticamente sem uso |
