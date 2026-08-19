# Runbook

## Ambiente

```bash
cd "C:/Users/Laudenir/Documents/00 - Projetos Vibe/escolta-armada/escolta-armada"
npm install
npm run dev          # http://localhost:3000
```

### Variáveis (`.env.local`)

| Variável | Obrigatória | Observação |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | sim | |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | sim | Vai para o navegador. Só é segura porque a RLS está ligada |
| `NEXT_PUBLIC_APP_URL` | sim | |
| `TELEGRAM_BOT_TOKEN` | sim | **Secreta.** Nunca com prefixo `NEXT_PUBLIC_` |
| `TELEGRAM_CHAT_ID` | sim | |
| `NEXT_PUBLIC_MAPBOX_TOKEN` | sim | Sem ela o mapa falha em silêncio |
| `OPENAI_API_KEY` | sim | **Secreta.** Server-side apenas |
| `SUPABASE_SERVICE_ROLE_KEY` | não | Ainda não usada. Necessária se migrar o cadastro para o admin API |

## Verificação antes de entregar

```bash
npx tsc --noEmit     # deve sair 0
npx next build       # deve compilar
npm run lint
```

O `next build` **nunca passou** até agosto de 2026. A causa era `useSearchParams` sem limite de Suspense. Se voltar a falhar na pré-renderização, é provavelmente o mesmo padrão em outra página.

## Migrations

Aplicadas via MCP do Supabase, registradas em `supabase_migrations.schema_migrations`. A partir do número 100.

**Não execute nada de `database/_legado_v1/`.** São de um schema que nunca existiu, e o `007` redefine `auth.uid()` recursivamente, o que quebraria toda a autenticação.

## Cadastro de usuário

Feito em `/dashboard/usuarios` por administrador ou gestor. Quatro campos: nome, CPF, telefone e perfil.

O sistema gera:
- **Login**: `primeiro_ultimo`, sem acento, com sufixo numérico se houver colisão
- **Senha**: `123456`, com troca obrigatória no primeiro acesso

O usuário entra digitando **o login**, não um e-mail. A tela completa o domínio interno sozinha.

## Recuperação de senha

**Não existe recuperação automática.** As contas usam e-mail interno `@operador.local`, que não tem caixa postal.

Para redefinir: administrador ou gestor vai em `/dashboard/usuarios`, encontra o usuário e usa a ação de redefinir senha. Um gestor **não** consegue redefinir a senha de um administrador.

Se todos os administradores ficarem indisponíveis, a redefinição só sai por SQL no painel do Supabase.

## Diagnóstico rápido

```sql
-- Conta que não consegue entrar? Confira estes dois:
select email,
       (select count(*) from auth.identities i where i.user_id=u.id) as identities,
       email_change is null as coluna_nula
from auth.users u;
```

Zero identities ou coluna nula significam conta criada pelo caminho errado. O login devolve HTTP 500 antes mesmo de conferir a senha.

```sql
-- Alguma tabela sem RLS?
select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' and not c.relrowsecurity;
```

Deve voltar vazio.


## Reconciliação do histórico

A trigger que gravava histórico foi removida: quem grava é o aplicativo, porque só ele tem observação, autor e GPS. A contrapartida é que escrita feita fora do app (SQL direto, service role) não deixa rastro.

O controle é esta consulta, que deve voltar vazia:

```sql
select * from vw_historico_divergente;
```

Se voltar linhas, alguém alterou o status por fora do sistema.

## Rotas de API

As duas rotas exigem sessão válida. Sem sessão devolvem 401.

| Rota | Quem pode | Limite |
|---|---|---|
| `POST /api/ai/melhorar-texto` | Qualquer usuário ativo | 20 por minuto |
| `POST /api/telegram` | Qualquer usuário ativo | 30 por minuto |
| `GET /api/telegram` | Apenas administrador e gestor | - |

O `chat_id` do Telegram é resolvido no servidor a partir da escolta. Um `chat_id` explícito só é aceito de administrador ou gestor.

**Pré-requisito:** o cliente precisa ter `telegram_chat_id` preenchido. Sem isso a mensagem cai no chat central definido em `TELEGRAM_CHAT_ID`. Hoje **nenhum dos 5 clientes tem o campo preenchido**, e a única tela que editava esse campo é uma das rotas órfãs ainda não removidas.

## Proteção de rota

O `middleware.ts` renova a sessão a cada navegação e barra quem não está autenticado. Rota do dashboard sem sessão devolve 307 para `/auth/login`.

A checagem de **perfil** continua no cliente, porque depende de uma consulta a `usuarios`. Quem garante a autorização de fato é a RLS no banco, não a tela.

## Backups e limpeza de base

Em 2026-08-19 a base operacional foi zerada para os testes do fluxo de 9 etapas. O estado anterior está no schema `backup_20260819`, com 15 tabelas mais os metadados do Storage.

Consultar o backup sem restaurar:

```sql
select table_name, (xpath('/row/c/text()',
  query_to_xml('select count(*) c from backup_20260819.'||table_name, false, true, '')))[1]::text::int linhas
from information_schema.tables where table_schema = 'backup_20260819' order by 1;
```

O procedimento completo de restauração, com a ordem correta das tabelas, está no `LOG-ALTERACOES.md`, na entrada de 2026-08-19.

**A restauração não devolve as fotos.** Os 117 arquivos do bucket foram apagados definitivamente e o backup guarda só os metadados. Restaurar traz de volta datas, GPS, observações e checklists, e deixa toda galeria com imagem quebrada.

**Antes de qualquer limpeza futura, nesta ordem:**

1. Criar o schema de backup e **conferir a contagem de cada tabela contra a origem**, antes de apagar qualquer coisa.
2. Confirmar com Pecanha o que fica e o que sai. A fronteira não é óbvia: sem cliente, viatura e modelo de checklist não dá para criar a primeira escolta.
3. Declarar explicitamente que os arquivos do Storage não têm cópia.
4. Apagar das folhas para a raiz, numa transação. `fotos` é a última, porque pontos, checklists, ocorrências e presenças a referenciam.
5. Apagar o Storage por listagem recursiva da própria API, nunca por lista transcrita à mão.
6. Provar que funciona vazio: criar uma escolta pela API e apagá-la em seguida.

## Sequência do código da escolta

`gerar_codigo_escolta` deriva de `MAX()` sobre as escoltas do ano corrente, não de uma sequence. Com a tabela vazia, a próxima escolta do ano vira `ESC-AAAA-0001`. Não há risco de colisão enquanto não se restaurar backup por cima de escoltas novas: aí sim dois registros podem disputar o mesmo código, e a conferência é obrigatória antes de restaurar.

## Riscos conhecidos

| Risco | Situação |
|---|---|
| Sem fila offline | Foto perdida se a rede cair no upload. A tela de campo engole o erro e avança o status |
| Sem branch de teste no Supabase | Plano Free. Toda migration vai direto para produção |
| RPC acoplada ao GoTrue | `criar_usuario_por_login` escreve em tabelas internas do Supabase |
| Bucket `fotos` público para leitura | Foto operacional com GPS acessível por URL. Fechar exige URL assinada e envio em multipart ao Telegram |
