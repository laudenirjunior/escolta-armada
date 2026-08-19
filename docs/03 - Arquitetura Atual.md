# Arquitetura Atual

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
