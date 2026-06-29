# Migrações do Banco de Dados - Escolta Armada

## 📋 Overview

Este diretório contém as migrações SQL para o banco de dados PostgreSQL do Supabase. As migrações devem ser executadas **na ordem numérica**.

### Arquivos de Migração

| # | Nome | Descrição | Tabelas |
|---|------|-----------|---------|
| 001 | `create_domain_tables.sql` | Tabelas de domínio (enums de negócio) | 11 tabelas + políticas RLS |
| 002 | `create_users.sql` | Usuários, vigilantes, clientes, veículos, armamentos | 5 tabelas + triggers |
| 003 | `create_escoltas.sql` | Operações de escolta | 4 tabelas + índices |
| 004 | `create_geolocalization.sql` | Geolocalização e fotos | 5 tabelas + geo-índices |
| 005 | `create_checklists.sql` | Checklists e timeline | 7 tabelas + triggers |
| 006 | `create_audit.sql` | Auditoria e sistema | 7 tabelas + triggers |
| 007 | `create_rls_policies.sql` | Políticas RLS (controle de acesso) | Funções + 28 políticas |

**Total: ~80 tabelas + triggers + índices + RLS**

## 🚀 Como Executar

### Opção 1: Supabase Dashboard (Recomendado)

1. Abra o [Supabase Console](https://supabase.com/dashboard)
2. Acesse seu projeto → **SQL Editor**
3. Clique em **"New Query"**
4. **Cole o conteúdo do arquivo `001_create_domain_tables.sql`**
5. Clique em **"Run"** (ou Ctrl+Enter)
6. Repita para os arquivos 002-007 **na ordem**

### Opção 2: Supabase CLI

```bash
# Instalar Supabase CLI (se não tiver)
npm install -g supabase

# Fazer login
supabase login

# Link projeto
supabase link --project-ref seu-project-id

# Executar migração
supabase db push --local

# Ou copiar/colar manualmente:
cat database/migrations/001_create_domain_tables.sql | supabase db execute
```

### Opção 3: psql (Conexão Direta)

```bash
# Obter connection string no Supabase Console → Settings → Database

# Executar migração
psql "postgresql://user:password@host:5432/postgres" < database/migrations/001_create_domain_tables.sql
```

## ⚠️ Ordem Importante

**EXECUTE NA ORDEM:**
1. ✅ `001_create_domain_tables.sql`
2. ✅ `002_create_users.sql`
3. ✅ `003_create_escoltas.sql`
4. ✅ `004_create_geolocalization.sql`
5. ✅ `005_create_checklists.sql`
6. ✅ `006_create_audit.sql`
7. ✅ `007_create_rls_policies.sql`

## ✅ Verificação Pós-Migração

```sql
-- Listar todas as tabelas criadas
SELECT table_name FROM information_schema.tables 
WHERE table_schema = 'public'
ORDER BY table_name;

-- Contar tabelas
SELECT COUNT(*) as total_tabelas FROM information_schema.tables 
WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

-- Listar políticas RLS
SELECT schemaname, tablename, policyname 
FROM pg_policies 
ORDER BY tablename;

-- Listar triggers
SELECT trigger_name, event_manipulation, event_object_table 
FROM information_schema.triggers 
WHERE trigger_schema = 'public'
ORDER BY event_object_table;
```

## 🔍 Solução de Problemas

### Erro: "table already exists"
→ Tabela já foi criada. Prossiga para a próxima migração.

### Erro: "foreign key constraint fails"
→ Migração anterior não foi completada. Verifique se executou na ordem correta.

### Erro: "permission denied"
→ Usuário Supabase não tem permissão. Use o **anon key** ou **service role key** com permissões suficientes.

### Erro: "extension earthdistance not available"
→ Normal no Supabase. A extensão foi criada, RLS pode precisar ajuste para geoindexes.

## 📊 Estrutura de Dados

### Tabelas de Domínio (001)
- `dom_perfis` - 5 níveis de acesso
- `dom_funcoes` - Papéis de vigilante
- `dom_tipos_veiculo` - Tipos de veículo
- `dom_status_escolta` - 10 estados possíveis
- `dom_tipos_ocorrencia` - Tipos de evento
- E mais...

### Usuários e Cadastro (002)
- `usuarios` - Usuários do sistema (auth)
- `vigilantes` - Profissionais de segurança
- `clientes` - Empresas/Pessoas que contratam
- `veiculos` - Veículos blindados
- `armamentos` - Armas e equipamentos

### Operações (003)
- `escoltas` - Operação central
- `escolta_veiculos` - Veículos por escolta
- `escolta_efetivo` - Pessoas por veículo
- `escolta_armamentos` - Armas por pessoa

### Localização (004)
- `pontos_controle` - Check-ins georreferenciados
- `rastreamento` - GPS periódico
- `presencas` - Presença do pessoal
- `fotos` - Imagens com carimbo
- `fotos_storage` - Referência ao Supabase Storage

### Checklists (005)
- `checklist_modelos` - Modelos reutilizáveis
- `checklists` - Execução
- `checklist_respostas` - Respostas item a item
- `atualizacoes_status` - Timeline
- `ocorrencias` - Eventos anormais
- `emergencias` - Acionamentos críticos

### Sistema (006)
- `logs_auditoria` - Auditoria completa
- `notificacoes` - Telegram, email, etc
- `sincronizacao` - Offline/sync
- `configuracoes` - Parâmetros do sistema
- `sessoes_usuarios` - Controle de acesso
- `tentativas_login` - Detecção de ataques

## 🔐 RLS (Row Level Security)

Todos os dados são protegidos por políticas RLS:

- **Operador**: Vê apenas sua escolta
- **Central/Supervisor**: Vê escoltas de seu cliente
- **Gestor**: Vê e gerencia dados do cliente
- **Admin**: Acesso irrestrito

## 📝 Dados Iniciais

Algumas tabelas de domínio já vêm com dados:
- Perfis (5 tipos)
- Funções (6 tipos)
- Status de Escolta (10 estados)
- Tipos de Foto (10 tipos)

## 🔄 Backup e Restore

```bash
# Backup do banco (no Supabase Dashboard → Backups)
pg_dump "postgresql://..." > backup.sql

# Restore
psql "postgresql://..." < backup.sql
```

## ❓ Dúvidas?

Se encontrar problemas:
1. Verifique a ordem das migrações
2. Copie a mensagem de erro exata
3. Procure no [Supabase Docs](https://supabase.com/docs)
4. Abra uma issue no repositório
