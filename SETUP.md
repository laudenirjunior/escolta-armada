# Checklist de Configuração - Escolta Armada

## ✅ O que foi criado

### Estrutura Base
- [x] Pasta raiz do Next.js 15 com App Router
- [x] TypeScript configurado
- [x] Tailwind CSS v4 com design system integrado
- [x] ESLint pronto
- [x] Fonts Google (DM Sans, JetBrains Mono)

### Configuração Inicial
- [x] `tsconfig.json` com paths aliases (`@/`)
- [x] `tailwind.config.ts` com variáveis de cores do design system
- [x] `globals.css` com estilos base e componentes Tailwind
- [x] `next.config.ts` pronto para produção
- [x] `.env.local.example` com variáveis necessárias

### Biblioteca Supabase
- [x] Cliente Supabase para browser (`lib/supabase/client.ts`)
- [x] Cliente Supabase para server (`lib/supabase/server.ts`)
- [x] Type definitions Supabase (`types/supabase.ts`)

### Types e Modelos
- [x] Tipos completos do domínio (`types/index.ts`)
- [x] Enums para status, perfis, tipos
- [x] Interfaces para todas as tabelas principais

### Componentes UI (Design System)
- [x] Button com variantes e tamanhos
- [x] Card, CardHeader, CardTitle, CardContent, CardFooter
- [x] Badge com variantes de status
- [x] Input com validação de erro
- [x] Label
- [x] Dialog/Modal

### Componentes de Layout
- [x] Sidebar responsivo com toggle mobile
- [x] TopBar com info de usuário e ações
- [x] Layout helpers (RootLayout, MainLayout, PageLayout)

### Hooks Customizados
- [x] `useAuth` para autenticação
- [x] `useEscolta` para gerenciar escoltas
- [x] `useSincronizacao` para offline/sync

### Utilities e Helpers
- [x] Formatadores (data, moeda, CPF, placa, coordenadas, distância)
- [x] Validadores (email, CPF, senha, placa, coordenadas)
- [x] Constantes (perfis, status, transições válidas)

### Páginas Iniciais
- [x] Página raiz `/` com redirecionamento
- [x] Página de login `/auth/login`
- [x] Layout raiz com fontes Google

## 🚀 Próximos Passos

### 1. Configurar Supabase (CRÍTICO)
- [ ] Copiar `.env.local.example` para `.env.local`
- [ ] Adicionar credenciais do Supabase
  - URL do projeto
  - Chave anôn (pública)
  - Chave service role (privada)

### 2. Criar Banco de Dados (CRÍTICO)
No Supabase Console, executar migrações SQL:
- [ ] Tabelas de domínio (`dom_perfis`, `dom_funcoes`, `dom_tipos_veiculo`, etc)
- [ ] Tabelas de usuários (`usuarios`, `vigilantes`)
- [ ] Tabelas de operação (`escoltas`, `escolta_veiculos`, `escolta_efetivo`)
- [ ] Tabelas de geolocalização (`pontos_controle`, `rastreamento`, `fotos`)
- [ ] Tabelas de checklists
- [ ] Tabelas de auditoria e timeline
- [ ] Índices e políticas de acesso (RLS)

### 3. Implementar Autenticação
- [ ] Integrar login com Supabase Auth no `useAuth.ts`
- [ ] Implementar logout
- [ ] Implementar troca de senha obrigatória
- [ ] Criar middleware de autenticação

### 4. Criar Páginas por Perfil
**Operador (Mobile/Campo)**
- [ ] Dashboard do operador
- [ ] Tela da escolta atual
- [ ] Registro de presença
- [ ] Checklist de viatura (com 5 fotos)
- [ ] Check-in de ponto de controle
- [ ] Lançamento de atualização
- [ ] Registro de ocorrência

**Central/Supervisor (Desktop)**
- [ ] Painel com operações em andamento
- [ ] Mapa com veículos
- [ ] Timeline de eventos
- [ ] Indicadores
- [ ] Relatórios

**Gestor/Admin (Desktop)**
- [ ] Tudo acima
- [ ] Cadastros (cliente, vigilante, veículo, armamento)
- [ ] Escalação de efetivo
- [ ] Gestão de usuários (Admin)
- [ ] Auditoria (Admin)

### 5. Funcionalidades Core
- [ ] Sincronização offline/online
- [ ] Câmera e foto com carimbo
- [ ] Geolocalização e GPS
- [ ] Rastreamento por intervalo
- [ ] Notificações (Telegram)
- [ ] Geração de PDF

### 6. Testes e Deploy
- [ ] Testar autenticação completa
- [ ] Testar offline/sync
- [ ] Testar notificações Telegram
- [ ] Build e otimização
- [ ] Deploy em staging
- [ ] Deploy em produção

## 📝 Arquivos para Criar Depois

```
database/
  ├── migrations/
  │   ├── 001_create_domain_tables.sql
  │   ├── 002_create_users.sql
  │   ├── 003_create_escoltas.sql
  │   ├── 004_create_geolocalization.sql
  │   ├── 005_create_checklists.sql
  │   ├── 006_create_audit.sql
  │   └── 007_create_rls_policies.sql
  └── seeds/
      └── initial_data.sql

pages/
  ├── dashboard/
  ├── operador/
  ├── central/
  ├── supervisor/
  ├── gestor/
  ├── admin/
  └── settings/

api/
  ├── auth/
  ├── escoltas/
  ├── fotos/
  ├── notificacoes/
  ├── indicadores/
  └── auditoria/

services/
  ├── supabase.ts
  ├── telegram.ts
  ├── llm.ts
  ├── storage.ts
  ├── offline.ts
  └── sync.ts

store/
  ├── auth.ts
  ├── escoltas.ts
  ├── ui.ts
  └── sync.ts
```

## 🔍 Como Verificar se Tudo Está Pronto

```bash
# 1. Instalar dependências
npm install

# 2. Verificar TypeScript
npm run type-check

# 3. Verificar compilação
npm run build

# 4. Iniciar desenvolvimento
npm run dev

# 5. Verificar em http://localhost:3000
# Deve redirecionar para /auth/login
```

## ⚠️ Observações Importantes

1. **Supabase é crítico**: Sem configurar as variáveis de ambiente e criar o banco de dados, a aplicação não funcionará
2. **Banco de dados versionado**: Sempre usar migrações SQL, nunca alterar manualmente
3. **RLS é essencial**: As políticas de acesso (Row Level Security) são a base da segurança
4. **Design System já está pronto**: Todos os componentes seguem o design visual do projeto
5. **Offline-first mindset**: Sempre pensar em sincronização ao adicionar features

## 📞 Suporte

Se tiver dúvidas, verifique:
- Planejamento técnico completo (anexado)
- Design system (anexado)
- Documentação Next.js: https://nextjs.org
- Documentação Supabase: https://supabase.io/docs

---

**Status**: ✅ Estrutura base criada e pronta para desenvolvimento
**Data**: Junho 2026
**Próximo**: Configurar Supabase e criar banco de dados
