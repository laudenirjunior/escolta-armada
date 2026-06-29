# Escolta Armada - Plataforma de Controle Operacional

Aplicação web responsiva (PWA) para gerenciamento completo de escoltas armadas, com funcionamento offline, georreferenciamento, checklists e timeline de eventos.

## 📋 Características

- ✅ Autenticação e controle de acesso por perfil (5 perfis distintos)
- 📍 Georreferenciamento com 4 pontos de controle
- 📸 Fotos com carimbo de data, hora e localização
- ✓ Checklists de material e viatura por modelo versionado
- 📱 Funcionamento offline com sincronização idempotente
- 🔔 Notificações em tempo real pelo Telegram
- 📊 Indicadores, relatórios e PDF de fechamento
- 🗺️ Mapa interativo com rastreamento
- 💬 Melhoria de texto por LLM
- 🎨 Design system premium industrial corporativo

## 🛠️ Stack Tecnológica

- **Frontend**: Next.js 15, React 19, TypeScript, Tailwind CSS v4
- **Backend**: Supabase (PostgreSQL, Auth, Storage, Real-time)
- **Banco de Dados**: PostgreSQL com PostGIS para dados geográficos
- **Autenticação**: Supabase Auth
- **Armazenamento**: Supabase Storage para fotos
- **Notificações**: Telegram Bot API
- **LLM**: OpenAI API ou similar

## 📦 Instalação

### Pré-requisitos

- Node.js 18+ e npm/yarn
- Conta no Supabase (criada e projeto já existente)
- Credenciais do Supabase

### Configuração Inicial

1. **Clone ou configure o ambiente**

```bash
cd escolta-armada
npm install
```

2. **Configure as variáveis de ambiente**

Copie o arquivo de exemplo e adicione suas credenciais:

```bash
cp .env.local.example .env.local
```

Edite `.env.local`:

```env
# Supabase
NEXT_PUBLIC_SUPABASE_URL=https://seu-projeto.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=sua_chave_anon_aqui
SUPABASE_SERVICE_ROLE_KEY=sua_service_role_key_aqui

# App
NEXT_PUBLIC_APP_URL=http://localhost:3000

# Telegram (opcional)
TELEGRAM_BOT_TOKEN=seu_token_bot_aqui
TELEGRAM_CHAT_ID_CENTRAL=seu_chat_id_central_aqui

# LLM (opcional)
OPENAI_API_KEY=sua_api_key_openai_aqui
```

3. **Configure o banco de dados**

Acesse o Supabase Console e execute as migrações SQL fornecidas em `database/migrations/` para criar todas as tabelas, índices e políticas de acesso.

4. **Inicie o servidor de desenvolvimento**

```bash
npm run dev
```

A aplicação estará disponível em `http://localhost:3000`

## 🗂️ Estrutura do Projeto

```
escolta-armada/
├── app/                    # App Router do Next.js
│   ├── layout.tsx         # Layout raiz
│   ├── page.tsx           # Página inicial
│   └── auth/              # Rotas de autenticação
├── components/
│   ├── ui/                # Componentes base (Button, Card, Input, etc)
│   ├── layout/            # Componentes de layout (Sidebar, TopBar)
│   └── shared/            # Componentes compartilhados
├── lib/
│   ├── supabase/
│   │   ├── client.ts      # Cliente Supabase browser
│   │   └── server.ts      # Cliente Supabase server
│   └── ...                # Outras bibliotecas
├── types/
│   ├── index.ts           # Types principais da aplicação
│   └── supabase.ts        # Types gerados do Supabase
├── hooks/                 # Hooks customizados (useAuth, useEscolta, etc)
├── utils/
│   ├── formatters.ts      # Funções de formatação
│   ├── validators.ts      # Funções de validação
│   └── constants.ts       # Constantes globais
├── public/                # Arquivos estáticos
├── globals.css            # Estilos globais com design system
├── tailwind.config.ts     # Configuração Tailwind
├── next.config.ts         # Configuração Next.js
└── package.json           # Dependências e scripts
```

## 🔑 Perfis de Acesso

1. **Administrador**: Acesso total, auditoria, gestão de usuários
2. **Gestor**: Cadastra escoltas, vê valores, indicadores financeiros
3. **Supervisor**: Cadastra e acompanha escoltas, sem valores
4. **Central**: Monitora painel e mapa, recebe alertas
5. **Operador**: Atua em campo, lança dados, faz checklists

## 📱 Telas Principais

### Para Operador (Celular - Campo)
- Lista de escoltas do dia
- Registro de presença com foto
- Checklist de material e viatura
- Check-in de pontos de controle
- Lançamento de atualizações manuais
- Registro de ocorrências
- Botão de emergência
- Fechamento com observação

### Para Central/Supervisor/Gestor (Web)
- Painel de operações em andamento
- Mapa com posição de veículos
- Timeline de eventos
- Indicadores e relatórios
- Gestão de escoltas e efetivo

### Para Administrador (Web)
- Tudo acima
- Gestão de usuários
- Reatribuição de lançamentos
- Página de auditoria
- Gestão de tabelas de domínio

## 🔄 Fluxo de uma Escolta

```
Rascunho → Agendada → Pré-Início → Em Andamento
    ↓                              ↓
Cancelada                    Na Origem
                                ↓
                           No Destino
                                ↓
                           Retornando
                                ↓
                            Na Base
                                ↓
                           Finalizada
```

## 🌐 Geolocalização e Rastreamento

- **4 Pontos de Controle**: Base Saída, Origem, Destino, Base Retorno
- **Rastreamento por Intervalo**: Posição gravada a cada 1 minuto (configurável)
- **Fotos Carimbadas**: Cada foto recebe data, hora e coordenadas
- **Mapa Interativo**: Visualização de todos os veículos em operação

## 📸 Fotos com Carimbo

- Carimbo embutido na imagem
- Metadados estruturados no banco
- Replicação para timeline, Telegram e PDF
- Sem duplicação desnecessária

## 🔔 Notificações

### Eventos que geram notificação:
- Mudança de status da escolta
- Check-in de ponto de controle
- Conclusão de checklist
- Acionamento de emergência
- Registro de ocorrência

### Canais:
- **App**: Notificação in-app na timeline
- **Telegram**: Mensagem no grupo do cliente ou grupo central

## 📊 Indicadores Disponíveis

- Tempo total por escolta
- Quilometragem por escolta e acumulada
- Quantidade de veículos, vigilantes e solicitações
- Taxa de checklist concluído
- Número de ocorrências e emergências
- (Gestor/Admin) Custo, receita e margem

## 🏗️ Próximos Passos Recomendados

1. **Criar e configurar banco de dados** no Supabase
2. **Implementar autenticação** (login, logout, mudança de senha)
3. **Criar páginas de operador** (telas de campo)
4. **Integração com Telegram** para notificações
5. **Testes offline** e sincronização
6. **Deployment** em produção

## 📚 Documentação Técnica

- [Planejamento Técnico Completo](PLANEJAMENTO.md)
- [Design System](../design_system.md)
- [API Contracts](APIS.md) *(a criar)*
- [Migração de Banco de Dados](database/migrations/README.md) *(a criar)*

## 🚀 Desenvolvimento

```bash
# Desenvolvimento
npm run dev

# Build
npm run build

# Produção
npm start

# Type checking
npm run type-check

# Lint
npm run lint
```

## 🔐 Segurança

- Autenticação via Supabase Auth
- Controle de acesso por linha no banco (RLS)
- Separação lógica de clientes
- Trilha de auditoria completa
- Validações em 3 camadas (DB, Server, Client)

## 📝 Licença

Proprietário - Grupo Esquematiza

## 🤝 Suporte

Para questões técnicas ou bugs, abra uma issue no repositório interno.

---

**Versão**: 0.1.0
**Status**: Em desenvolvimento - Fase 1
**Data de Criação**: Junho 2026
