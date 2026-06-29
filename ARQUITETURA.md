# Arquitetura Técnica - Escolta Armada

## 1. Visão Geral

A plataforma é construída em 3 camadas:
1. **Frontend**: PWA responsiva (web + celular)
2. **Backend**: Supabase (PostgreSQL + Auth + Storage + Real-time)
3. **Integrações**: Telegram, LLM, PDF

```
┌─────────────────────────────────────────────────────┐
│                  USUÁRIOS                           │
│  Operador (mobile)  Central  Supervisor  Gestor    │
└────────────┬────────────────────────────┬───────────┘
             │                            │
       ┌─────▼────────────────────────────▼─────┐
       │     FRONTEND - Next.js PWA              │
       │  Components, Pages, Hooks, Utils        │
       │     Suporte offline + sync              │
       └─────┬────────────────────────────┬─────┘
             │                            │
       ┌─────▼────────────────────────────▼─────┐
       │       BACKEND - SUPABASE                │
       │  ├─ PostgreSQL (Base de Dados)         │
       │  ├─ Auth (Autenticação)                │
       │  ├─ Storage (Fotos)                    │
       │  ├─ Real-time (WebSocket)              │
       │  └─ Edge Functions (Telegram, LLM)     │
       └─────┬────────────────────────────┬─────┘
             │                            │
       ┌─────▼────────┐         ┌────────▼──────┐
       │  TELEGRAM    │         │   OPENAI LLM  │
       │  NOTIFICAÇÕES│         │  MELHORIA TXT │
       └──────────────┘         └───────────────┘
```

## 2. Fluxos Principais

### 2.1 Autenticação
```
[Login Form] → [Supabase Auth] → [JWT Token] → [Local Storage]
                                              ↓
                                          [useAuth Hook]
                                              ↓
                                        [Context/State]
```

### 2.2 Escolta - Ciclo Completo
```
[Criar Escolta]
      ↓
[Agendar]
      ↓
[Pré-Início (Checklists)]
      ↓
[Iniciar (Saída da Base)] → [Rastreamento contínuo]
      ↓                              ↓
[Check-in Origem]              [Fotos, eventos]
      ↓                              ↓
[Check-in Destino]              [Timeline]
      ↓                              ↓
[Retorno] ─────────────────────────→ [Sincronizar]
      ↓
[Na Base]
      ↓
[Finalizar] → [PDF] → [Telegram]
```

### 2.3 Offline → Online
```
[Registrar localmente]
      ↓
[IndexedDB]
      ↓
[Internet volta]
      ↓
[Sincronizar com Supabase]
      ↓
[Idempotência: UUID único]
      ↓
[Atualizar estado local]
      ↓
[Timeline reflete mudanças]
```

## 3. Estrutura de Dados

### 3.1 Tabelas de Domínio (Extensibilidade)
```
dom_perfis              → 5 tipos de acesso
dom_funcoes             → Funções de vigilante
dom_tipos_veiculo       → Tipos de veículo
dom_calibres            → Calibres de armamento
dom_tipos_ponto         → 4 pontos de controle
dom_tipos_ocorrencia    → Tipos de evento excepcional
dom_tipos_evento        → Eventos de timeline
dom_tipos_foto          → Tipos de foto/contexto
```

### 3.2 Tabelas Operacionais
```
usuarios                → Quem acessa
vigilantes              → Quem trabalha
clientes                → Para quem trabalha

escoltas                → A operação central
escolta_veiculos        → Veículos dessa escolta
escolta_efetivo         → Quem vai em cada veículo
escolta_armamentos      → Armas que saem
```

### 3.3 Tabelas de Campo
```
fotos                   → Repositório central de imagens
pontos_controle         → Check-ins georreferenciados
rastreamento            → Posições periódicas
presencas               → Check-in de presença
```

### 3.4 Tabelas de Contexto
```
checklists              → Execução de checklists
checklist_respostas     → Resposta item a item
atualizacoes_status     → Timeline de eventos
ocorrencias             → Eventos excepcionais
emergencias             → Acionamentos críticos
```

### 3.5 Tabelas de Sistema
```
notificacoes            → Rastreamento de envios
logs_auditoria          → Quem fez o quê quando
escolta_status_historico → Trilha de status
```

## 4. Segurança

### 4.1 Autenticação
- Supabase Auth com JWT
- Email + Senha (primeira versão)
- MFA futuro

### 4.2 Autorização (RLS)
- Políticas por linha no PostgreSQL
- Usuário só vê dados do seu cliente
- Valores financeiros só para Gestor/Admin
- Ações restritas por perfil

### 4.3 Camadas de Validação
```
[Frontend]
   ↓ (validações UX)
[Network]
   ↓
[API/Edge Function]
   ↓ (validações regras)
[PostgreSQL]
   ↓ (constraints, triggers)
   ✓ Armazenado
```

## 5. Geolocalização e Fotos

### 5.1 Captura de Foto
```
[Câmera] → [Ler GPS/Hora] → [Carimbo na imagem] → [Upload]
                                    ↓
                            [Visível no PNG]
                                    ↓
                            [Prova offline-first]
```

### 5.2 Replicação de Foto
```
[Storage Supabase]
       ↓
  ┌────┴────┬───────────┬──────────┐
  ↓         ↓           ↓          ↓
Timeline  Telegram    PDF      Relatórios
```

## 6. Offline & Sync

### 6.1 Persistência Local
- IndexedDB para estruturado
- Cache API para assets
- Service Workers para PWA

### 6.2 Idempotência
- UUIDs gerados no cliente
- Mesmo ID = não duplica no servidor
- Resend seguro (reconhece mesmo item)

### 6.3 Estratégia de Conflito
- Dados de inserção nunca conflitam
- Edição: última versão ganha
- Trilha de auditoria registra tudo

## 7. Performance

### 7.1 Frontend
- Code splitting automático (Next.js)
- Image optimization
- CSS minificado (Tailwind)
- Cache de assets

### 7.2 Backend
- Índices nas colunas de busca
- Vistas pré-calculadas para indicadores
- Particionamento de dados por cliente
- Connection pooling do Supabase

### 7.3 Rede
- Compressão gzip
- CDN do Supabase
- Service Workers para offline
- Progressive Loading

## 8. Escalabilidade

### 8.1 Tabelas de Domínio
- Novos tipos sem migration
- Apenas INSERT + aplicação consulta
- Suporta 100+ tipos sem impacto

### 8.2 Modelo Versionado (Checklists)
- Versão do modelo guardada
- Histórico intacto
- Alterações futuras seguras

### 8.3 JSONB Flexível
- Campo `metadados` em tabelas chave
- Dados não previstos guardados
- Formaliza depois se vira coluna

## 9. Notificações

### 9.1 Evento na Timeline
```
[Atualização de status]
        ↓
[Tabela atualizacoes_status]
        ↓
[Trigger: é notificável?]
        ↓ SIM
[Inserir em notificacoes]
        ↓
[Edge Function: disparar Telegram]
```

### 9.2 Telegram
- Bot com token
- Mensagem formatada com foto
- Reenvio em caso de falha
- Grupo por cliente ou central

## 10. Relatórios & PDF

### 10.1 Indicadores
- Tempo, quilometragem, quantidade
- Taxa de checklist, ocorrências
- Filtros por período, cliente, veículo
- Só exibir valores para Gestor/Admin

### 10.2 PDF de Fechamento
```
[Finalizar Escolta]
       ↓
[Edge Function: gerar PDF]
       ↓
[Conteúdo:]
├─ Check-in presença
├─ Checklists + fotos
├─ Pontos controle
├─ Quilometragem
├─ Efetivo
├─ Ocorrências
├─ Observação final
└─ Código escolta
```

## 11. Implementação em Fases

### Fase 1 (Agora)
- ✅ Estrutura Next.js
- ✅ Componentes UI/Layout
- ✅ Types e interfaces
- ⏳ BD + RLS + Índices
- ⏳ Autenticação
- ⏳ Telas de campo

### Fase 2 (Próximas semanas)
- Funcionalidades core
- Offline/Sync
- Telegram
- LLM
- PDF

### Fase 3 (Evolução)
- Rastreamento ao vivo
- WhatsApp
- Módulo de pagamento
- BI avançado

## 12. Tecnologias Chave

| Camada | Tecnologia | Função |
|--------|------------|--------|
| **Frontend** | Next.js 15 | Framework React |
| | TypeScript | Tipagem |
| | Tailwind CSS v4 | Estilo |
| | SWR/TanStack Query | Dados remotos |
| **Backend** | PostgreSQL | Banco relacional |
| | PostGIS | Dados geográficos |
| | Supabase | Plataforma |
| | Edge Functions | Serverless |
| **Offline** | IndexedDB | Persistência |
| | Service Workers | Cache |
| **Integração** | Telegram Bot API | Notificações |
| | OpenAI API | LLM |

---

**Status**: Arquitetura definida, implementação iniciada
**Próximo**: Criar banco de dados no Supabase
