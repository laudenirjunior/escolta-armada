# Log de Alterações

Ordem cronológica inversa. Cada entrada registra o que mudou, por quê, e como foi verificado.

Plano de referência: `~/.claude/plans/fa-a-um-planejamento-detalhado-greedy-wirth.md`
Projeto Supabase: `qthoyxujyzskydulvcfy` (escolta-armada, us-east-2)
Branch de trabalho: `fase0-seguranca`

---

## 2026-08-19 - Limpeza da base operacional para testes

### Migration 170 - `backup_pre_limpeza`

**O quê:** schema `backup_20260819` com cópia integral de 15 tabelas operacionais mais os metadados dos objetos do bucket `fotos`.

**Por quê:** Pecanha pediu a base zerada para começar os testes do fluxo novo de 9 etapas. Exclusão em produção não se faz sem cópia recuperável, conforme a regra do `CLAUDE.md` de `Documents`. Backup em schema, e não em arquivo de texto, porque não passa por serialização e volta com `INSERT INTO ... SELECT`.

**Verificação:** contagem por tabela conferida contra a origem antes de qualquer exclusão. Todas bateram: escoltas 16, escolta_veiculos 18, escolta_efetivo 44, escolta_armamentos 6, pontos_controle 63, fotos 120, checklists 27, checklist_respostas 171, ocorrencias 1, presencas 1, escolta_status_historico 71, storage_objetos 117.

O schema tem `REVOKE ALL ... FROM anon, authenticated, PUBLIC`, então não é alcançável pela API.

### Exclusão dos dados operacionais

**O quê:** `DELETE` em 16 tabelas dentro de uma transação, das folhas para a raiz, e remoção dos 117 objetos do bucket `fotos`.

Apagado: checklist_respostas (171), checklists (27), pontos_controle (63), ocorrencias (1), emergencias (0), presencas (1), rastreamento (0), atualizacoes_status (0), escolta_status_historico (71), notificacoes (0), escolta_armamentos (6), escolta_efetivo (44), escolta_veiculos (18), escoltas (16), fotos (120). Mais 117 arquivos no Storage.

Preservado: usuarios (3), clientes (5), vigilantes (11), veiculos (6), armamentos (10), checklist_modelos (6), checklist_modelo_itens (35), logs_auditoria (10) e as tabelas de domínio.

**Por quê essa fronteira:** sem cliente, viatura e modelo de checklist não é possível criar a primeira escolta, e o pedido era deixar pronto para testar, não para recadastrar. As notificações entraram na exclusão por decisão de Pecanha na confirmação.

**Sobre os arquivos do Storage:** o backup guarda os metadados (id, nome, bucket, data, `metadata`), **não os bytes**. Os 117 arquivos foram removidos definitivamente e não têm cópia. Isso foi declarado a Pecanha antes da execução e a exclusão foi autorizada.

A remoção usou listagem recursiva pela própria API de Storage, não uma lista transcrita, e conferiu o bucket vazio depois. `storage.objects` para o bucket `fotos` ficou em 0.

**Verificação, com JWT real de administrador:**

| Prova | Resultado |
|---|---|
| 15 tabelas operacionais | 0 linhas cada |
| Bucket `fotos` | 0 objetos, no banco e no storage |
| Cadastros base | intactos, todos legíveis com HTTP 200 |
| `vw_historico_divergente` | vazia |
| Listar escoltas, pontos, fotos e checklists com base vazia | HTTP 200, sem erro |
| Criar escolta pela API | HTTP 201 |
| Código gerado | `ESC-2026-0001`, sequência reiniciada corretamente |
| `fluxo_versao` da escolta nova | 2, ou seja, já nasce sob a regra do trânsito de retorno |
| Apagar a escolta de teste | HTTP 200, 1 linha |

A escolta de teste foi removida em seguida, e a base ficou de fato em zero.

**Como restaurar**, se for preciso voltar atrás:

```sql
-- ordem inversa da exclusao: raiz primeiro, folhas depois
insert into public.fotos select * from backup_20260819.fotos;
insert into public.escoltas select * from backup_20260819.escoltas;
insert into public.escolta_veiculos select * from backup_20260819.escolta_veiculos;
insert into public.escolta_efetivo select * from backup_20260819.escolta_efetivo;
insert into public.escolta_armamentos select * from backup_20260819.escolta_armamentos;
insert into public.pontos_controle select * from backup_20260819.pontos_controle;
insert into public.checklists select * from backup_20260819.checklists;
insert into public.checklist_respostas select * from backup_20260819.checklist_respostas;
insert into public.ocorrencias select * from backup_20260819.ocorrencias;
insert into public.presencas select * from backup_20260819.presencas;
insert into public.escolta_status_historico select * from backup_20260819.escolta_status_historico;
```

**Limite da restauração:** ela devolve as linhas, **não as fotos**. Os registros de `fotos` voltariam apontando para caminhos que não existem mais no bucket, e toda galeria mostraria imagem quebrada. Restaurar só faz sentido para recuperar dado operacional (datas, GPS, observações, checklists), não a prova fotográfica.

**Risco assumido:** os 11 vigilantes continuam com `usuario_id` nulo. Nenhum deles tem conta, então **nenhum login de perfil operador enxerga escolta hoje**, porque toda a RLS de campo depende desse vínculo. Para testar o fluxo de campo é preciso criar um operador pela tela de usuários, que cria o vínculo automaticamente.

---

## 2026-08-19 - Fase 0: Guardrails e hotfix de segurança

### Migration 100 - `hotfix_seguranca_security_definer`

**O quê:** guarda `IS NULL OR` em `criar_usuario_completo` e `cadastrar_operador`, mais `REVOKE EXECUTE ... FROM anon, PUBLIC` nas quatro RPCs de cliente e nos quatro resolvedores de identidade.

**Por quê:** as duas funções de criação conferiam permissão com `IF perfil NOT IN ('administrador','gestor')`. Para chamador anônimo, `perfil_usuario_atual()` devolve NULL, e em SQL `NULL NOT IN (...)` é NULL, não `true`, então o `IF` não disparava e a exceção nunca era levantada. Somado ao `EXECUTE` que `anon` possuía, **qualquer pessoa com a chave pública do navegador podia criar uma conta de administrador**. Ligar RLS não resolveria, porque `SECURITY DEFINER` ignora RLS.

**Como foi feito:** o corpo das funções foi preservado. A migration lê `pg_get_functiondef`, substitui só o `IF` e reexecuta a definição, abortando se a guarda esperada não for encontrada. Isso evita transcrever 4145 caracteres à mão.

**Cuidado tomado:** `authenticated` foi **mantido** nos resolvedores `perfil_usuario_atual`, `get_meu_perfil`, `get_meu_usuario_id` e `get_meu_vigilante_id`. Retirar quebraria as 42 políticas de RLS que os chamam.

**Verificação:**

```
POST /rest/v1/rpc/criar_usuario_completo  (chave anon)  -> HTTP 401
  {"code":"42501","message":"permission denied for function criar_usuario_completo"}
POST /rest/v1/rpc/cadastrar_operador      (chave anon)  -> HTTP 401
  {"code":"42501","message":"permission denied for function cadastrar_operador"}
```

Dados conferidos depois do teste: 3 auth.users, 3 usuarios, **0 invasores**, 16 escoltas, 120 fotos, 63 pontos, 11 vigilantes. Nada alterado.

### Migration 101 - `hotfix_escalada_gestor_administrador`

**O quê:** `redefinir_senha_usuario` passa a conferir o perfil do **alvo**, não só o de quem chama.

**Por quê:** a função só validava que o chamador era administrador ou gestor. Um gestor podia redefinir a senha de um administrador e entrar como ele. O sistema tem um gestor (Bruno) e dois administradores.

**Regra nova:** apenas um administrador redefine a senha de outro administrador.

### Migration 102 - `search_path_funcoes`

**O quê:** `SET search_path = public, pg_temp` nas 9 funções que estavam com `proconfig` nulo.

**Por quê:** função com `search_path` mutável pode ser induzida a resolver um nome para um objeto plantado por quem a chama.

### Migration 103 - `revoke_trigger_function_anon`

**O quê:** `REVOKE EXECUTE` de `anon` e `PUBLIC` em `registrar_historico_status_escolta`.

**Por quê:** é `SECURITY DEFINER` e função de trigger. Ninguém precisa chamá-la diretamente. Será removida na Fase 4 junto com a trigger.

### Resultado nos advisors de segurança

| Aviso | Antes | Depois |
|---|---|---|
| `function_search_path_mutable` | 9 | **0** |
| `anon_security_definer_function_executable` | 9 | **0** |
| `authenticated_security_definer_function_executable` | 9 | 9 (esperado: as políticas precisam) |
| `rls_disabled_in_public` | 33 | 33 (Fase 2) |
| `policy_exists_rls_disabled` | 32 | 32 (Fase 2) |
| `auth_leaked_password_protection` | 1 | 1 (Fase 2) |
| **Total** | **93** | **75** |

### Código

| Arquivo | Mudança | Motivo |
|---|---|---|
| `app/dashboard/relatorios/pdf/page.tsx` | Conteúdo movido para `RelatoriosPDFConteudo`, com `export default` envolvendo em `<Suspense>` | `useSearchParams()` sem limite de Suspense fazia `next build` **falhar na pré-renderização**. O build nunca tinha passado: não existia `.next/BUILD_ID` |
| `.eslintrc.json` | Criado (`next/core-web-vitals` + `next/typescript`) | Não existia nenhuma configuração de ESLint, então `npm run lint` não rodava e o gate de verificação era fictício |
| `tsconfig.json` | `exclude` passa a incluir `.claude` e `database/_legado_v1` | A cópia obsoleta em `.claude/worktrees/` estava sendo typecheckada. **`.next` não foi excluído**, porque o `include` depende de `.next/types/**/*.ts` para os tipos de rota do Next 14 e o `exclude` vence o `include` |
| `app/dashboard/page.tsx` | Dois `<a>` para rotas internas viram `<Link>` | Erro de lint `no-html-link-for-pages` |
| `app/dashboard/sistema/telegram/page.tsx` | Aspas escapadas como `&quot;` | Erro de lint `react/no-unescaped-entities` |
| `indicadores`, `mapa`, `relatorios` | `let` para `const` em 3 variáveis nunca reatribuídas | Erro de lint `prefer-const` |
| `components/ui/textarea.tsx` | `interface` vazia vira `type` | Erro de lint `no-empty-object-type` |

**Verificação:** `npx tsc --noEmit` exit 0. `npx next build` **verde**, pela primeira vez no projeto.

Achados confirmados pelo próprio lint, que reforçam o diagnóstico do plano: `CabecalhoLogos` definido e nunca usado, e `paginaAtual`/`totalPaginas` do rodapé declarados e nunca recebidos.

### Pendências da Fase 0

| Item | Situação |
|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | **Bloqueado.** Precisa ser copiada do painel do Supabase. A Fase 5 depende dela |
| Backup lógico com teste de restauração | A fazer antes da Fase 2 |
| Branch do Supabase para validar RLS | A fazer antes da Fase 2 |
| Regerar `types/supabase.ts` | Fase 1 |

---

## 2026-08-19 - Fases 1, 3, 4 (parcial) e 6.1

### Fase 1 - Reconciliar o banco

- Os 7 arquivos SQL v1 e o seed foram para `database/_legado_v1/`, com um README explicando que descrevem um schema que **nunca existiu** neste banco, e alertando que `007` redefine `auth.uid()` recursivamente e quebraria toda a autenticação se executado.
- `types/supabase.ts` regenerado a partir do banco real: **805 -> 1981 linhas**. Passa a conhecer `chat_mensagens`, que era usada pelo código e não existia nos tipos.

### Fase 3 - Máquina de estados única, com a etapa nova

**Migrations 110, 111 e 112.**

- `escoltas.fluxo_versao SMALLINT NOT NULL DEFAULT 2`, com as 16 escoltas existentes marcadas como `1`. Sem isso, as 3 escoltas em `retornando` travariam para sempre, porque não têm nem podem ter o ponto de trânsito de retorno.
- CHECK de status aceita `em_transito_retorno`.
- `dom_tipos_ponto` ganha `transito_retorno` e `retorno`. O segundo resolve a colisão em que `base_retorno` servia a dois eventos diferentes.
- Trigger de transição reescrita com o mapa completo. Corrige o erro relatado e acrescenta as arestas do retorno. Escolta `fluxo_versao = 1` continua podendo pular as etapas de trânsito.
- Trigger nova `tr_exigir_transito_retorno`: `retornando -> na_base` só passa se existir ponto `transito_retorno`. Vale só para `fluxo_versao = 2`.

**Código.** `lib/fluxo-escolta.ts` passa a ser a fonte única: status, rótulos, classes de badge, transições válidas, próximo status, as 9 etapas e o tipo de ponto por status. Antes havia quatro definições divergentes. A tela de detalhe passou a importar daqui.

Etapa nova na interface: estado, handler `handleIniciarTransitoRetorno`, diálogo com GPS e fotos, e os botões "Iniciar Trânsito de Retorno" e "Confirmar Retorno".

**Teste de fluxo executado no banco:**

| Caso | Resultado |
|---|---|
| `na_origem -> em_transito_destino` (o erro relatado) | PASSOU |
| `no_destino -> em_transito_retorno` (etapa nova) | PASSOU |
| Concluir retorno **sem** o ponto de trânsito | BLOQUEADO |
| Concluir retorno **com** o ponto | PASSOU |
| Transição inválida (`finalizada -> em_andamento`) | BLOQUEADO |
| Escolta antiga (v1) conclui sem o ponto novo | Não travou |
| Dados de teste removidos | OK |

Distribuição das 16 escoltas conferida antes e depois: idêntica.

### Fase 4 (parcial) - Fotos obrigatórias

- Guarda bloqueante nos cinco handlers que rotulavam a foto como obrigatória e aceitavam sem: saída da base, chegada na origem, trânsito ao destino, chegada no destino e chegada na base.
- **`handleChegadaBase` corrigido.** A foto era capturada e descartada: `uploadFoto` nunca era chamado e o insert do ponto não tinha `foto_id`. É a causa dos 12 pontos `base_retorno` sem foto.
- `uploadFotosPonto` novo, respeitando o limite de 5 por ponto.
- Os pontos de retorno passam a gravar `observacoes` como JSON com `foto_ids`, no mesmo formato já usado pelas paradas.

### Fase 6.1 - Os quatro defeitos do relatório PDF

Todos no mesmo arquivo, e precisavam sair juntos: consertar um revelava o próximo.

| # | Defeito | Correção |
|---|---|---|
| 1 | `select` pedia `papel`, coluna inexistente | `papel_na_escolta`, e a interface TypeScript junto |
| 2 | `.in('escolta_id', ...)` sobre `checklists`, que não tem essa coluna | Sem viatura, devolve vazio em vez de consultar |
| 3 | Sub-select de veículos não pedia `id`, `veiculo_id` nem a placa | Acrescentados. `escVeicIds` era sempre vazio e a seção Frota mostrava sempre `—` |
| 4 | `checklist_respostas` sem alias, mas o render lê `c.respostas` | Alias `respostas:` |

**Comprovação por HTTP:**

```
ANTES:  GET .../escoltas?select=id,efetivo:escolta_efetivo(papel)
        HTTP 400  {"code":"42703","message":"column escolta_efetivo_1.papel does not exist"}

DEPOIS: GET .../escoltas?select=...papel_na_escolta...veiculo:veiculos(placa,modelo)
        HTTP 200  dados reais, com placa e efetivo preenchidos
```

### Verificação

`npx tsc --noEmit` exit 0. `npx next build` compilado com sucesso, `.next/BUILD_ID` presente.

---

## 2026-08-19 - Fase 5: Cadastro de usuário e conserto das contas

Feito **sem** a `SUPABASE_SERVICE_ROLE_KEY`. Eu havia tratado a chave como bloqueio e estava errado: o acesso privilegiado ao banco permite corrigir a própria função de criação, o que resolve a causa em vez de contorná-la.

### Diagnóstico comprovado por probe HTTP

Login com senha propositalmente errada, antes de qualquer alteração:

| Conta | HTTP | Leitura |
|---|---|---|
| laudenirjunior@gmail.com | **400** | credencial inválida, conta sadia |
| douglasbraido@... | **500** | GoTrue quebra antes de conferir a senha |
| bruno@grupoesquematiza... | **500** | idem |

O 500 confirma o defeito das colunas de texto nulas. Depois do reparo, as três devolvem 400.

### Migration 120 - reparar as contas

Dois defeitos, ambos presentes:

1. `email_change`, `email_change_token_new` e outras colunas de texto estavam **NULL**. O GoTrue as lê em tipo não anulável e devolve 500. Normalizadas para string vazia, como na conta que funciona. `confirmation_token` e `recovery_token` estavam com hash preenchido e foram zerados.
2. **Sem linha em `auth.identities`.** O login por e-mail resolve o usuário por ela. Criada no formato do provider `email`.

Senha definida como `123456` com troca obrigatória.

**Resultado:** Douglas e Bruno fazem login e recebem token. As três contas agora têm `identities = 1` e `last_sign_in_at` preenchido. Douglas e Bruno nunca tinham conseguido entrar.

### Migration 121 - `criar_usuario_por_login`

Função nova com a assinatura do cadastro reduzido: nome, CPF, telefone e perfil.

- Gera o login `primeiro_ultimo`, sem acento, com desambiguação por sufixo numérico.
- E-mail interno `<login>@operador.local`, invisível ao usuário. A tela de login já completa o domínio quando não há `@`.
- Cria `auth.users` **com todas as colunas de texto preenchidas** e a linha em `auth.identities`. É o que faltava na função antiga.
- Valida CPF (11 dígitos e unicidade), nome e perfil.
- Senha `123456` com `troca_senha_obrigatoria = true`.
- Nasce sob a regra de classe da Fase 0: guarda `IS NULL OR`, `REVOKE` de `anon` e `PUBLIC`, `search_path` fixado.

### Teste de ponta a ponta executado

| Passo | Resultado |
|---|---|
| Admin cria usuário com 4 campos | HTTP 200, login `jose_teste` gerado |
| Login com o login gerado e `123456` | **OK**, token emitido, identities 1 |
| Trocar por senha de 6 caracteres | HTTP 200 |
| Login com a senha nova | **OK** |
| CPF com menos de 11 dígitos | recusado |
| CPF duplicado | recusado |
| Sem nome / sem perfil | recusados |
| Anônimo tenta criar | **HTTP 401** |
| Usuário de teste removido | OK |

### Código

| Arquivo | Mudança |
|---|---|
| `utils/validators.ts` | `validarSenha` passa a exigir só o mínimo de 6, sem complexidade, e proíbe reusar a provisória. Constantes `SENHA_MINIMO` e `SENHA_PROVISORIA` |
| `app/auth/trocar-senha/page.tsx` | Usa `validarSenha` em vez do 8 fixo |
| `app/dashboard/usuarios/page.tsx` | Formulário de 4 campos. Campo de e-mail removido. CPF obrigatório com máscara e validação em tempo real pelo `validarCPF`, que existia e nunca era usado. Telefone com máscara. Mostra o login previsto e a senha provisória antes de salvar. Chama `criar_usuario_por_login` |

### Ressalva registrada

A RPC manipula tabelas internas do GoTrue (`auth.users` e `auth.identities`). Funciona e está testada, mas é acoplada à estrutura interna do Supabase. Quando a `SUPABASE_SERVICE_ROLE_KEY` estiver configurada, o caminho suportado é migrar para uma Route Handler com `auth.admin.createUser()`. A função atual fica como está até lá.

### Verificação

`tsc` exit 0, `next build` compilado, 7 rotas testadas com HTTP 200.

---

## 2026-08-19 - Fase 2 (RLS), Fase 6 (impressão) e Fase 7 (honestidade dos indicadores)

### Fase 2 - RLS: substituir as políticas e ligar, em três lotes

O diagnóstico dizia "políticas criadas porém inertes". Estava incompleto: **33 das 78 políticas tinham predicado `true`**, e como políticas permissivas são combinadas por OU, elas anulavam as restritas na mesma tabela. Ligar RLS sem trocá-las teria zerado os advisors sem proteger nada.

**Defeito estrutural encontrado nas políticas antigas.** Elas escopavam por efetivo com `JOIN usuarios u ON u.id = ee.vigilante_id`, mas `escolta_efetivo.vigilante_id` referencia `vigilantes(id)`, não `usuarios(id)`. Essas políticas nunca casavam nada. Se eu tivesse apenas removido as permissivas, o operador ficaria sem ver a própria escolta. Criei `sou_do_efetivo()` e `sou_do_efetivo_veiculo()` com o caminho correto, passando por `vigilantes.usuario_id`.

| Migration | Lote |
|---|---|
| 130 | Helpers de efetivo |
| 131 | `usuarios` (não tinha política nenhuma) + trigger contra autopromoção |
| 132 | `clientes`, `vigilantes`, `fotos` |
| 133 | `escoltas`, `escolta_veiculos`, `escolta_efetivo`, `escolta_armamentos` |
| 134 | Dados de campo: pontos, checklists, ocorrências, emergências, presenças, histórico, rastreamento |
| 135 | Domínio e sistema: `dom_*`, veículos, armamentos, modelos, auditoria, notificações, chat |
| 136 | Revoke das funções de trigger e da RPC obsoleta |

**Cuidado deliberado em duas tabelas.** `usuarios` precisa permitir a leitura da própria linha, porque `useAuth.ts:17-23` resolve o perfil da sessão com select direto e `layout.tsx:107` bloqueia a renderização se voltar vazio. `dom_perfis` precisa continuar legível por autenticado, porque `layout.tsx:126` filtra todo item de menu por ele. Negar qualquer uma das duas trancaria o operador fora do sistema ou deixaria a navegação vazia.

**Verificação com JWT real de cada perfil**, antes e depois:

| Tabela | anon antes | anon depois | operador depois | admin |
|---|---|---|---|---|
| `usuarios` | 4 | **0** | 1 (a própria) | 4 |
| `clientes` | 5 | **0** | 1 (o da escolta dele) | 5 |
| `vigilantes` | 11 | **0** | 3 (o efetivo dele) | 11 |
| `fotos` | 120 | **0** | 1 | 120 |
| `escoltas` | 16 | **0** | 1 | 16 |
| `pontos_controle` | 63 | **0** | 1 | 63 |

**Testes de violação:**

| Tentativa | Resultado |
|---|---|
| Operador se promove a administrador | **HTTP 400**, "Voce nao pode alterar o proprio perfil de acesso" |
| Operador lê o CPF de outro usuário | `[]` |
| Operador grava ponto na própria escolta | **HTTP 201** |
| Operador grava ponto em escolta alheia | **HTTP 403**, viola a política |
| Operador resolve o próprio perfil (useAuth) | funciona |
| Operador lê `dom_perfis` (menu) | funciona |

**Advisors: 93 -> 14, e nenhum ERROR.** Os 13 WARN restantes são `SECURITY DEFINER` executável por autenticado, o que é necessário: as políticas chamam os resolvedores e as RPCs precisam ser chamáveis. O 14º é a proteção contra senha vazada, que conflita com a senha `123456` decidida.

**33 de 33 tabelas com RLS ligada.** 70 políticas, 52 usando a forma `(select fn())` que vira InitPlan e é avaliada uma vez por consulta em vez de por linha.

### Fase 6 - Impressão

`app/print.css` novo, importado pelo `globals.css`, então vale para **todas** as páginas. Antes só existiam dois blocos inline nas duas telas dedicadas, e imprimir qualquer outra saía com sidebar, topbar e bottom nav.

Cobre: `@page` A4 com margem inferior maior para reservar espaço ao rodapé fixo; variante paisagem por classe; `print-color-adjust` em `*` e não só em `body`; `thead` repetido; `break-inside: avoid` em linha, imagem e card; título com `break-after: avoid` para não ficar órfão; `orphans`/`widows`; expansão de link externo; contêiner com rolagem aberto; animação e sombra desligadas; e numeração de página com `counter(page)`.

Corrigido em `relatorios/pdf`: `@page { margin: 0 }`, que jogava o conteúdo na área não imprimível e fazia o rodapé fixo sobrepor o texto; e `page-break-after: always` em toda seção, que gastava uma folha para uma seção de cinco linhas.

Conferido que as regras chegam ao CSS final do build, e não são descartadas pelo `@import`.

### Fase 7 - Honestidade dos indicadores

| Problema | Correção |
|---|---|
| Setas de tendência eram comparação com limiar (`taxaConclusao >= 80 ? 'up' : 'down'`), lidas como variação de período | Removidas. Sem base de comparação, não se desenha seta |
| "Taxa SLA: 100%" quando não havia nenhuma escolta ativa | Passa a exibir traço e a legenda "nenhuma escolta ativa agora" |
| Badge "LIVE" em dado estático, sem realtime nem polling | Vira "PERÍODO" e "AGORA" |
| Gráfico de 12 meses com fator `* 1.2` na altura, fazendo o mês de pico vazar o trilho | Fator removido |

### Verificação

`tsc` exit 0, `next build` compilado, **18 rotas em HTTP 200 com a RLS ligada**. Dados de teste removidos: 3 usuários, 11 vigilantes, 16 escoltas, 63 pontos, 120 fotos, iguais ao início.

---

## 2026-08-19 - Fechamento: cadastro de vigilante, documentação e testes

### Migration 140 - `cadastrar_operador_com_identity`

`cadastrar_operador`, usada ao cadastrar um vigilante em `/dashboard/cadastros`, tinha **o mesmo defeito** da função de usuário: inseria em `auth.users` sem criar `auth.identities` e sem preencher as colunas de texto do GoTrue. Todo vigilante cadastrado pela tela nasceria sem conseguir entrar.

Corrigida preservando o corpo, com o mesmo método da migration 100: lê a definição, insere só o que falta e aborta se os padrões esperados não forem encontrados.

**Teste de ponta a ponta:** cadastrar vigilante devolveu HTTP 200 com `login: vigilante_prova`, e o login com `123456` funcionou, com `identities: 1`. Dados de teste removidos.

### Verificações estruturais, todas passando

| Verificação | Resultado |
|---|---|
| Tabelas sem RLS | nenhuma |
| `SECURITY DEFINER` executável por `anon` | nenhuma |
| Política com predicado `true` em tabela sensível | nenhuma |
| RPC sem a guarda `IS NULL OR` | nenhuma |
| Conta sem `auth.identities` | nenhuma |

### Documentação

Pasta `docs/` criada, para ser recortada ao final:

| Arquivo | Conteúdo |
|---|---|
| `00 - INDICE.md` | Índice |
| `01 - Design System.md` | Paleta Navy, tokens, e o estado real (duas paletas convivendo, ~1840 hexes inline, CSS morto) |
| `02 - Skills e Metodologia.md` | O ciclo de crítica adversarial e as notas de cada rodada, com os erros que ele pegou |
| `03 - Arquitetura Atual.md` | Schema real, funções, triggers, RLS, storage e os débitos conhecidos |
| `04 - Fluxo Operacional.md` | A jornada de 9 etapas e as regras de foto |
| `05 - Decisoes Tecnicas.md` | Cada decisão com a alternativa descartada e o custo assumido |
| `06 - Guia de Impressao.md` | Como as folhas de impressão funcionam |
| `07 - Runbook.md` | Setup, variáveis, cadastro, recuperação de senha e diagnóstico |

### Testes

`database/testes/` com dois arquivos idempotentes: o fluxo das 9 etapas com as tentativas de violação, e as cinco verificações estruturais da RLS. `database/migrations/README.md` documenta as 17 migrations aplicadas e a regra obrigatória para funções `SECURITY DEFINER` novas.

### O que continua pendente

| Item | Motivo |
|---|---|
| Gráficos nos indicadores | Só as correções de honestidade foram feitas |
| Varredura página a página | Duas paletas, ~1840 hexes inline, acessibilidade |
| Autenticação em `/api/telegram` e `/api/ai/melhorar-texto` | Continuam aceitando chamada sem sessão |
| `middleware.ts` | Continua com `matcher: []` |
| Bucket `fotos` público | Fechar quebraria o `sendPhoto` do Telegram |
| Histórico gravado em dobro | Não corrigido |
| Fila offline | Não existe |

---

## 2026-08-19 - Correção das regressões apontadas na revisão

Uma revisão adversarial da implementação deu **nota 5** e apontou regressões que eu havia introduzido. As bloqueantes foram corrigidas.

### R1 - A tela de Campo travaria toda escolta nova, e falsificava histórico

`campo/page.tsx` mantinha o próprio mapa de status, com `no_destino -> retornando`. A trigger nova só aceita essa aresta para `fluxo_versao = 1`, e o default é 2. **Toda escolta criada a partir de agora travaria em `no_destino` justamente na tela para onde o operador é redirecionado.**

Pior: `:431` fazia `await sb.from('escoltas').update(...)` **sem ler o erro**. A trigger recusava, o código seguia e inseria a linha de histórico afirmando uma transição que não aconteceu. O operador via sucesso, a escolta não andava e o histórico ficava falso.

Corrigido: mapa derivado de `lib/fluxo-escolta.ts`, tipos de ponto `transito_retorno` e `retorno` acrescentados, jornada com 8 passos, e o update passa a ler o erro e a usar precondição de status antes de gravar qualquer coisa.

O upload de foto em `:340` também engolia a falha e deixava o status avançar sem foto. Agora lança.

### R2 - O cadastro novo criava operadores que a RLS trancava

`criar_usuario_por_login` não criava linha em `vigilantes`. Toda a RLS de campo depende de `sou_do_efetivo()`, que caminha `escolta_efetivo -> vigilantes.usuario_id -> usuarios.auth_user_id`. Operador sem vigilante não enxergava escolta nenhuma: tela de Campo permanentemente vazia.

Migration 152: a função passa a criar o vigilante vinculado quando o perfil é operador. Testado, devolve `vigilante_id: CRIADO`.

Registro do que **não** foi resolvido: os 11 vigilantes existentes têm `usuario_id` nulo. Não é backfill possível, porque são pessoas sem conta no sistema (há 3 usuários, todos de gestão). Quando algum deles precisar de acesso, o cadastro tem de ser feito pelo fluxo que cria o vínculo.

### S1 - A escalada gestor para administrador continuava aberta, e por uma porta que eu mesmo abri

A migration 121 aceitava **qualquer** `p_perfil_id`. Como a senha inicial é a constante `123456`, um gestor criava uma conta de administrador e entrava nela. A trigger `impedir_autopromocao` era só de UPDATE, não cobria INSERT.

Migration 151: trigger `BEFORE INSERT` em `usuarios` impedindo criação de perfil administrador por quem não é administrador.

```
GESTOR tenta criar ADMINISTRADOR -> HTTP 400, "Apenas um administrador pode criar outra conta de administrador"
GESTOR cria OPERADOR             -> HTTP 200
```

### S2 - Qualquer usuário logado apagava qualquer foto

As políticas do bucket eram `USING (bucket_id = 'fotos')` para `authenticated`, em DELETE e UPDATE. Em cadeia de custódia isso invalida o acervo: qualquer operador apagava prova de escolta alheia.

Migration 150: apagar e sobrescrever passam a exigir perfil de gestão.

**O bucket continua público para leitura.** Fechar quebraria o `sendPhoto` do Telegram, que busca a URL anonimamente. Continua pendente.

### R3, R4 - Nome do autor sumia da interface para central e operador

A política restrita de `usuarios` fazia todos os embeds `autor:usuarios!fk(nome_completo)` voltarem null, na timeline, nos relatórios e nas notificações, e deixava a lista de contatos do chat vazia. Para o perfil central, que monitora todas as escoltas, é perda direta de função.

Migration 153: leitura ampla entre autenticados. **Trade-off assumido e comentado na própria política:** expõe CPF e telefone entre funcionários. É sistema interno, todos são da mesma empresa, e o estado anterior era qualquer anônimo lendo tudo. A escrita continua restrita e a autopromoção continua bloqueada.

### R5, R6 - Telas fingiam ter salvo

Com RLS ligada, UPDATE ou DELETE negado devolve 204 com zero linhas e **sem erro**. O diálogo fechava, a lista recarregava igual, e o usuário achava que tinha salvo. Corrigido em `cadastros/page.tsx` (cliente) e `usuarios/page.tsx` (bloquear/desbloquear) com `.select('id')` e checagem de linhas afetadas.

### R7 - A etapa nova era invisível para contagem, filtro e mapa

Sobravam **15 arrays de status literais** sem `em_transito_retorno`, em 9 arquivos. A escolta sumia do mapa ao vivo e da lista durante a etapa nova, e o check-in periódico ficava escondido justamente na perna de estrada. Todos corrigidos, nenhum restante.

### Ainda pendente da revisão

| Item | Motivo |
|---|---|
| Bucket público para leitura | Fechar quebra o Telegram; exige `multipart` e URL assinada |
| `handleParada` sem exigir foto e com GPS 0,0 | Não corrigido |
| `fotos_select` sem cobrir checklist, presença e ocorrência | Não corrigido |
| Histórico gravado em dobro | Não corrigido |
| Rotas de API e `middleware.ts` | Não corrigidos |
| `utils/constants.ts` com definição antiga de status | Não removida |

### Verificação

`tsc` exit 0, `next build` compilado, rotas em 200. Dados iguais ao início: 3 usuários, 11 vigilantes, 16 escoltas, 120 fotos, 63 pontos, 44 efetivo.

---

## 2026-08-19 - Fechamento dos pendentes

### Rotas de API: de abertas para autenticadas

`lib/api-auth.ts` novo, com guarda de sessão, limite por usuário e escape de HTML.

| Chamada | Antes | Depois |
|---|---|---|
| `POST /api/ai/melhorar-texto` | **200** | **401** |
| `POST /api/telegram` | **200** | **401** |
| `GET /api/telegram?action=me` | **200** | **401** |
| `GET /api/telegram?action=updates` | **200** | **401** |

Além da sessão:

- **`chat_id` deixa de vir do cliente.** Era possível usar o bot para mandar mensagem a qualquer destino. Agora é resolvido no servidor a partir da escolta; um `chat_id` explícito só é aceito de administrador ou gestor.
- `GET` restrito a administrador e gestor. O `?action=updates` despejava as conversas recentes do bot.
- **HTML escapado** em 7 pontos de interpolação. Dado do usuário ia direto para `parse_mode: HTML`: um `<` quebrava a mensagem e uma tag `<a href>` virava link de phishing no canal de operações.
- Limite de 20 requisições por minuto na IA e 30 no Telegram, por usuário.
- O corpo de erro da OpenAI deixa de ser repassado ao cliente: vazava organização, projeto e detalhe de cota.

### `middleware.ts`: de inerte para ativo

Tinha `matcher: []` e nunca rodava. O comentário justificava com `@supabase/ssr@0.0.10`, mas o projeto está em `^0.12.0`, que persiste sessão em cookie. A justificativa estava obsoleta havia meses.

Agora renova a sessão a cada navegação e barra quem não está autenticado antes de a página existir:

```
/dashboard            307 -> /auth/login?de=%2Fdashboard
/dashboard/campo      307
/dashboard/usuarios   307
/auth/login           200
```

Usa `getUser()`, que revalida o token no servidor, e não `getSession()`, que apenas lê o cookie e aceitaria um token forjado.

### `handleParada`

Passa a exigir foto, como todo ponto do fluxo, e a **bloquear quando não há GPS**. Antes gravava `latitude 0, longitude 0` quando o sinal falhava, o que põe o ponto no golfo da Guiné. Ponto de controle sem coordenada real não serve como prova.

### `fotos_select` completa

A política só reconhecia a foto por `criado_por` ou por `pontos_controle.foto_id`. Ficavam de fora checklist, presença e ocorrência: um operador não via a foto de checklist registrada pelo colega da mesma escolta. Agora cobre os quatro caminhos.

### Histórico em dobro, resolvido

| Métrica | Antes | Depois |
|---|---|---|
| Total de linhas | 111 | **71** |
| `agendada -> em_pre_inicio` | 19 linhas / 13 escoltas | **13 / 13** |
| `em_andamento -> na_origem` | 17 / 11 | **11 / 11** |
| `retornando -> na_base` | 11 / 6 | **6 / 6** |

Uma linha por escolta por transição, como deve ser. A consolidação preservou a linha com `status_anterior` correto e trouxe autor, observação e GPS da outra.

A trigger `tr_registrar_historico_status` foi removida: o app continua gravando, e só ele tem observação, autor e GPS. **Contrapartida:** escrita feita fora do app não deixa rastro. O controle é a view `vw_historico_divergente`, que aponta escolta cujo status não bate com a última linha do histórico. Hoje retorna vazia.

Um detalhe do processo: a primeira tentativa de deduplicação não funcionou. Meu `UPDATE` preencheu `alterado_por` e, com isso, o `DELETE` seguinte não encontrou mais os pares, porque o critério era justamente `alterado_por IS NULL`. Refeito na ordem certa.

### `utils/constants.ts`

Removidas `STATUS_ESCOLTA`, `TIPOS_PONTO`, `LABELS_STATUS`, `LABELS_PONTO` e `TRANSICOES_VALIDAS_STATUS`. Eram a quinta definição divergente de status, sem a etapa nova. Nenhum arquivo importava desse módulo.

### Verificação final

| Item | Resultado |
|---|---|
| Tabelas sem RLS | nenhuma |
| `SECURITY DEFINER` executável por `anon` | nenhuma |
| Quem apaga foto no storage | só gestão |
| Contas sem `auth.identities` | nenhuma |
| Escoltas com histórico divergente | nenhuma |
| Fluxo das 9 etapas | passa |
| Conclusão sem ponto de trânsito | bloqueada |
| `tsc`, `build` | limpos |
| APIs sem sessão | 401 |
| Dashboard sem sessão | 307 |

### O que continua pendente

| Item | Motivo |
|---|---|
| Bucket `fotos` público para leitura | Fechar exige trocar `getPublicUrl` por URL assinada em 9 pontos e enviar bytes ao Telegram em `multipart` |
| Gráficos nos indicadores | Só as correções de honestidade foram feitas |
| Varredura página a página | Duas paletas, ~1840 hexes inline, acessibilidade |
| `viaturas[0]` em 19 pontos | 2 escoltas têm 2 viaturas; a segunda não recebe ponto |
| Fila offline | Não existe |
| 4 rotas órfãs | 1364 linhas não removidas |

---

## 2026-08-19 - Commit e verificação final

Commit `5a6c198` na branch `fase0-seguranca`: 49 arquivos, 4058 inserções.

O arquivo `types/supabase.ts.antigo`, backup meu da geração de tipos, foi retirado do commit e apagado. Nenhum arquivo `.env` entrou.

### Correção da view de reconciliação

`vw_historico_divergente` acusava 3 escoltas como divergentes. Era falso positivo meu: são escoltas em `agendada` que nunca mudaram de status, e por isso nunca geraram histórico. A view passou a exigir que a escolta tenha saído do estado inicial. Agora retorna vazia.

### Verificação final

| Verificação | Resultado |
|---|---|
| Tabelas sem RLS | nenhuma |
| `SECURITY DEFINER` executável por `anon` | nenhuma |
| Política com `true` em tabela sensível | nenhuma |
| Conta sem `auth.identities` | nenhuma |
| Histórico divergente | nenhum |
| Histórico total | 71 linhas (eram 111, com 40 duplicatas) |
| Dados | 16 escoltas, 120 fotos, 63 pontos, 3 usuários |
| `tsc --noEmit` | exit 0 |
| `next build` | compilado |
| Rotas do dashboard sem sessão | 307 |
| Rotas públicas | 200 |
| APIs sem sessão | 401 |
| Árvore de trabalho | limpa |

### Push

**Não realizado.** O comando foi bloqueado pelo classificador de permissões do ambiente. O commit está local, íntegro e verificado. O push precisa ser executado por Pecanha:

```bash
cd "C:/Users/Laudenir/Documents/00 - Projetos Vibe/escolta-armada/escolta-armada"
git push -u origin fase0-seguranca
```
