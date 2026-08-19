# Estrutura do Projeto - Escolta Armada

```
escolta-armada/
│
├── 📁 app/                           # Next.js App Router
│   ├── layout.tsx                    # Layout raiz com fontes Google
│   ├── page.tsx                      # Página inicial (redirect login)
│   ├── 📁 auth/
│   │   └── login/
│   │       └── page.tsx              # Página de login
│   ├── 📁 dashboard/                 # [TODO] Painel principal
│   ├── 📁 operador/                  # [TODO] Telas do operador
│   ├── 📁 central/                   # [TODO] Painel central
│   ├── 📁 admin/                     # [TODO] Painel admin
│   └── 📁 api/                       # [TODO] Route handlers
│
├── 📁 components/
│   ├── 📁 ui/                        # Componentes base (design system)
│   │   ├── button.tsx                # Button com 6 variantes
│   │   ├── card.tsx                  # Card, CardHeader, CardTitle, CardContent, CardFooter
│   │   ├── badge.tsx                 # Badge com 6 variantes de status
│   │   ├── input.tsx                 # Input com validação de erro
│   │   ├── label.tsx                 # Label com estilo correto
│   │   ├── dialog.tsx                # Dialog/Modal
│   │   ├── 📁 table/                 # [TODO] Table componentes
│   │   ├── 📁 tabs/                  # [TODO] Tabs
│   │   ├── 📁 textarea/              # [TODO] Textarea
│   │   ├── 📁 select/                # [TODO] Select/Dropdown
│   │   └── 📁 avatar/                # [TODO] Avatar
│   │
│   ├── 📁 layout/
│   │   ├── index.tsx                 # RootLayout, MainLayout, PageLayout
│   │   ├── sidebar.tsx               # Sidebar responsivo
│   │   ├── topbar.tsx                # TopBar com info de usuário
│   │   └── 📁 components/            # [TODO] Sub-componentes de layout
│   │
│   └── 📁 shared/                    # Componentes compartilhados
│       ├── 📁 escolta/               # [TODO] Componentes de escolta
│       ├── 📁 timeline/              # [TODO] Timeline de eventos
│       ├── 📁 mapa/                  # [TODO] Mapa interativo
│       └── 📁 indicadores/           # [TODO] Cards de KPI
│
├── 📁 lib/
│   ├── 📁 supabase/
│   │   ├── client.ts                 # Cliente Supabase (browser)
│   │   ├── server.ts                 # Cliente Supabase (server)
│   │   ├── 📁 queries/               # [TODO] Queries reutilizáveis
│   │   └── 📁 mutations/              # [TODO] Mutations reutilizáveis
│   └── 📁 utils/                     # [TODO] Outras bibliotecas
│
├── 📁 types/
│   ├── index.ts                      # Types principais (Escolta, Usuario, etc)
│   └── supabase.ts                   # Database types (gerados)
│
├── 📁 hooks/
│   ├── useAuth.ts                    # Autenticação
│   ├── useEscolta.ts                 # Gerenciar escolta
│   ├── 📁 [TODO]/
│   │   ├── useSincronizacao.ts
│   │   ├── useGeolocation.ts
│   │   ├── useCamera.ts
│   │   └── (useOffline.ts nunca existiu, ver README)
│
├── 📁 utils/
│   ├── formatters.ts                 # Data, moeda, CPF, placa, etc
│   ├── validators.ts                 # Email, CPF, senha, etc
│   ├── constants.ts                  # Perfis, status, transições
│   └── 📁 [TODO]/
│       ├── geolocation.ts
│       ├── storage.ts
│       └── sync.ts
│
├── 📁 services/                      # [TODO] Serviços de negócio
│   ├── escolta.ts
│   ├── fotos.ts
│   ├── telegram.ts
│   ├── llm.ts
│   └── pdf.ts
│
├── 📁 store/                         # [TODO] State management (Zustand)
│   ├── auth.ts
│   ├── escoltas.ts
│   └── ui.ts
│
├── 📁 public/
│   ├── favicon.ico
│   ├── logo.png
│   └── icons/
│
├── 📁 database/                      # [TODO] Migrações e sementes
│   ├── 📁 migrations/
│   │   ├── 001_create_domain_tables.sql
│   │   ├── 002_create_users.sql
│   │   ├── 003_create_escoltas.sql
│   │   ├── 004_create_geolocalization.sql
│   │   ├── 005_create_checklists.sql
│   │   ├── 006_create_audit.sql
│   │   └── 007_create_rls_policies.sql
│   └── 📁 seeds/
│       └── initial_data.sql
│
├── 📁 supabase/                      # [TODO] Edge Functions
│   └── 📁 functions/
│       ├── 📁 notify-telegram/
│       ├── 📁 generate-pdf/
│       └── 📁 improve-text/
│
├── 🔧 Configuração
│   ├── next.config.ts                # Next.js config
│   ├── tailwind.config.ts            # Tailwind com design tokens
│   ├── tsconfig.json                 # TypeScript config
│   ├── postcss.config.mjs            # PostCSS config
│   ├── next-env.d.ts                 # Types Next.js
│   ├── package.json                  # Dependências e scripts
│   ├── .env.local.example            # Template de env vars
│   └── .gitignore                    # Arquivos ignorados
│
├── 📖 Documentação
│   ├── README.md                     # Overview do projeto
│   ├── SETUP.md                      # Setup e instalação
│   ├── ARQUITETURA.md                # Arquitetura técnica detalhada
│   ├── EXEMPLOS.md                   # Exemplos de integração
│   └── PLANEJAMENTO.md               # [Referência externa]
│
└── 🎨 Estilos
    └── globals.css                   # Estilos globais + design system
```

## 📊 Quantidade de Arquivos por Categoria

| Categoria | Criados | TODO | Total |
|-----------|---------|------|-------|
| **Configuração** | 8 | 0 | 8 |
| **Tipos** | 2 | 0 | 2 |
| **Lib Supabase** | 2 | 2 | 4 |
| **Components UI** | 6 | 9 | 15 |
| **Components Layout** | 3 | 1 | 4 |
| **Components Shared** | 0 | 6 | 6 |
| **Hooks** | 2 | 4 | 6 |
| **Utils** | 3 | 2 | 5 |
| **Services** | 0 | 5 | 5 |
| **Store/State** | 0 | 3 | 3 |
| **Páginas** | 2 | 6+ | 8+ |
| **Database** | 0 | 7 | 7 |
| **Edge Functions** | 0 | 3 | 3 |
| **Documentação** | 4 | 0 | 4 |
| **TOTAL** | **33** | **48** | **81+** |

## ✅ O que Está Pronto

### Core Estrutural
- ✅ Next.js 15 com App Router
- ✅ TypeScript com paths aliases
- ✅ Tailwind CSS v4 com design tokens
- ✅ Fontes Google (DM Sans, JetBrains Mono)
- ✅ ESLint e formatação

### Componentes
- ✅ 6 componentes UI base (Button, Card, Badge, Input, Label, Dialog)
- ✅ Sidebar e TopBar responsivos
- ✅ Layout helpers

### Tipos e Interfaces
- ✅ 20+ types principais
- ✅ Enums para status, perfis, etc
- ✅ Database types template

### Lógica
- ✅ 2 hooks customizados
- ✅ 3 utilities (formatters, validators, constants)
- ✅ Clients Supabase (browser + server)

### Documentação
- ✅ README com instruções
- ✅ SETUP com checklist
- ✅ ARQUITETURA técnica detalhada
- ✅ EXEMPLOS de integração

## 🚀 Próximos Passos Críticos

### 1️⃣ **Configurar Supabase (HOJE)**
```bash
# 1. Copiar .env
cp .env.local.example .env.local

# 2. Adicionar credenciais
NEXT_PUBLIC_SUPABASE_URL=https://seu-projeto.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=xxx
SUPABASE_SERVICE_ROLE_KEY=xxx
```

### 2️⃣ **Criar Banco de Dados (PRÓXIMO)**
No Supabase Console, executar `database/migrations/*.sql`:
- Tabelas de domínio
- Tabelas operacionais
- Índices
- RLS policies

### 3️⃣ **Implementar Autenticação**
```typescript
// Integrar em lib/supabase/auth.ts
// Implementar em hooks/useAuth.ts
```

### 4️⃣ **Desenvolver Telas por Perfil**
- Operador (mobile/campo)
- Central
- Supervisor
- Gestor
- Admin

### 5️⃣ **Testar e Deploy**

## 🛠️ Como Rodar

```bash
# Instalar
npm install

# Desenvolvimento
npm run dev
# → http://localhost:3000

# Type check
npm run type-check

# Build
npm run build

# Produção
npm start
```

## 📱 Telas Prioritárias

| Ordem | Tela | Perfil | Status |
|-------|------|--------|--------|
| 1 | Login | Todos | ⏳ Integrar Auth |
| 2 | Dashboard | Operador | ⏳ Criar |
| 3 | Escolta Atual | Operador | ⏳ Criar |
| 4 | Painel Central | Central | ⏳ Criar |
| 5 | Mapa | Central | ⏳ Criar |
| 6 | Cadastros | Supervisor | ⏳ Criar |
| 7 | Indicadores | Gestor | ⏳ Criar |
| 8 | Admin | Admin | ⏳ Criar |

## 🎯 Stack Confirmado

- ✅ **Frontend**: Next.js 15 + React 19 + TypeScript
- ✅ **Estilo**: Tailwind CSS v4 + Design System
- ✅ **Backend**: Supabase (PostgreSQL + Auth + Storage)
- ⏳ **Offline**: não implementado. Há um service worker sem cache, só para tornar o app instalável
- ⏳ **Notificações**: Telegram Bot API
- ⏳ **LLM**: OpenAI API
- ⏳ **PDF**: Puppeteer ou similar

---

**Data de Criação**: Junho 2026
**Status**: ✅ Fase 1 (Estrutura) - Concluída
**Próxima Fase**: 🚀 Fase 2 (Banco de Dados + Auth)
**Versão**: 0.1.0
