-- Escolta Armada: Tabelas de Auditoria e Sistema
-- Log de ações, histórico de status, notificações

-- 1. Log de Auditoria (quem fez o quê quando)
CREATE TABLE IF NOT EXISTS logs_auditoria (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID REFERENCES usuarios(id),
  cliente_id UUID REFERENCES clientes(id),
  
  -- Ação
  tabela_afetada VARCHAR(100) NOT NULL,
  id_registro UUID,
  operacao VARCHAR(20) NOT NULL, -- INSERT, UPDATE, DELETE, SELECT
  
  -- Dados
  dados_anterior JSONB,
  dados_novo JSONB,
  campos_alterados TEXT[], -- Array de nomes dos campos
  
  -- Contexto
  ip_address VARCHAR(45),
  user_agent TEXT,
  sessao_id VARCHAR(100),
  
  -- Observação
  observacao TEXT,
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Histórico de Status (trilha de status da escolta)
CREATE TABLE IF NOT EXISTS escolta_status_historico (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  
  -- Status
  status_id SMALLINT NOT NULL REFERENCES dom_status_escolta(id),
  
  -- Hora e Quem
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  atualizado_por UUID NOT NULL REFERENCES usuarios(id),
  
  -- Motivo
  motivo VARCHAR(255),
  observacoes TEXT,
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. Notificações (rastreamento de envios)
CREATE TABLE IF NOT EXISTS notificacoes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  
  -- Destinatário
  usuario_id UUID REFERENCES usuarios(id),
  
  -- Tipo
  tipo_notificacao VARCHAR(50), -- 'telegram', 'email', 'sms', 'push'
  titulo VARCHAR(255),
  mensagem TEXT NOT NULL,
  
  -- Dados da Notificação
  tipo_evento VARCHAR(50), -- 'status_alterado', 'escolta_iniciada', etc
  dados_evento JSONB,
  
  -- Status de Envio
  enviada BOOLEAN DEFAULT FALSE,
  enviada_em TIMESTAMP WITH TIME ZONE,
  
  -- Destinatário
  canal_envio VARCHAR(100), -- Telegram ID, Email, Phone
  
  -- Resposta
  confirmada BOOLEAN DEFAULT FALSE,
  confirmada_em TIMESTAMP WITH TIME ZONE,
  
  -- Tentativas
  tentativas_envio INT DEFAULT 0,
  proxima_tentativa TIMESTAMP WITH TIME ZONE,
  ultimo_erro TEXT,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. Sincronização (rastreamento de dados offline)
CREATE TABLE IF NOT EXISTS sincronizacao (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES usuarios(id),
  
  -- Tipo de Dados
  tabela_sincronizada VARCHAR(100),
  registro_id UUID,
  
  -- Status
  status VARCHAR(50), -- pending, syncing, synced, failed
  tipo_operacao VARCHAR(20), -- INSERT, UPDATE, DELETE
  
  -- Dados (para casos de conflito)
  dados_local JSONB,
  dados_servidor JSONB,
  
  -- Resolução de Conflito
  conflito_detectado BOOLEAN DEFAULT FALSE,
  conflito_resolvido BOOLEAN DEFAULT FALSE,
  estrategia_resolucao VARCHAR(50), -- 'servidor_vence', 'cliente_vence', 'merge'
  
  -- Tentativas
  tentativas INT DEFAULT 0,
  proxima_tentativa TIMESTAMP WITH TIME ZONE,
  ultimo_erro TEXT,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. Configurações do Sistema
CREATE TABLE IF NOT EXISTS configuracoes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID REFERENCES clientes(id), -- NULL = global
  
  -- Chave-Valor
  chave VARCHAR(100) NOT NULL,
  valor TEXT NOT NULL,
  tipo_valor VARCHAR(50), -- string, number, boolean, json
  descricao TEXT,
  
  -- Permissões
  publica BOOLEAN DEFAULT FALSE,
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  UNIQUE(cliente_id, chave)
);

-- 6. Sessões de Usuário (para controle de acesso)
CREATE TABLE IF NOT EXISTS sessoes_usuarios (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  
  -- Identificação
  token_sessao VARCHAR(500),
  token_refresh VARCHAR(500),
  
  -- Contexto
  ip_address VARCHAR(45),
  user_agent TEXT,
  dispositivo_fingerprint VARCHAR(255),
  
  -- Status
  ativa BOOLEAN DEFAULT TRUE,
  
  -- Datas
  iniciada_em TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  ultima_atividade TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  expira_em TIMESTAMP WITH TIME ZONE,
  encerrada_em TIMESTAMP WITH TIME ZONE,
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 7. Tentativas de Login (para detecção de ataques)
CREATE TABLE IF NOT EXISTS tentativas_login (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Identificação
  email VARCHAR(255),
  ip_address VARCHAR(45),
  
  -- Status
  sucesso BOOLEAN DEFAULT FALSE,
  motivo_falha VARCHAR(100),
  
  -- Tentativa
  realizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Criar índices
CREATE INDEX IF NOT EXISTS idx_logs_auditoria_usuario_id ON logs_auditoria(usuario_id);
CREATE INDEX IF NOT EXISTS idx_logs_auditoria_tabela_afetada ON logs_auditoria(tabela_afetada);
CREATE INDEX IF NOT EXISTS idx_logs_auditoria_id_registro ON logs_auditoria(id_registro);
CREATE INDEX IF NOT EXISTS idx_logs_auditoria_created_at ON logs_auditoria(created_at);

CREATE INDEX IF NOT EXISTS idx_escolta_status_historico_escolta_id ON escolta_status_historico(escolta_id);
CREATE INDEX IF NOT EXISTS idx_escolta_status_historico_status_id ON escolta_status_historico(status_id);
CREATE INDEX IF NOT EXISTS idx_escolta_status_historico_atualizado_em ON escolta_status_historico(atualizado_em);

CREATE INDEX IF NOT EXISTS idx_notificacoes_escolta_id ON notificacoes(escolta_id);
CREATE INDEX IF NOT EXISTS idx_notificacoes_usuario_id ON notificacoes(usuario_id);
CREATE INDEX IF NOT EXISTS idx_notificacoes_tipo_notificacao ON notificacoes(tipo_notificacao);
CREATE INDEX IF NOT EXISTS idx_notificacoes_enviada ON notificacoes(enviada);
CREATE INDEX IF NOT EXISTS idx_notificacoes_created_at ON notificacoes(created_at);

CREATE INDEX IF NOT EXISTS idx_sincronizacao_usuario_id ON sincronizacao(usuario_id);
CREATE INDEX IF NOT EXISTS idx_sincronizacao_status ON sincronizacao(status);
CREATE INDEX IF NOT EXISTS idx_sincronizacao_tabela_sincronizada ON sincronizacao(tabela_sincronizada);
CREATE INDEX IF NOT EXISTS idx_sincronizacao_conflito_detectado ON sincronizacao(conflito_detectado);

CREATE INDEX IF NOT EXISTS idx_configuracoes_cliente_id ON configuracoes(cliente_id);
CREATE INDEX IF NOT EXISTS idx_configuracoes_chave ON configuracoes(chave);

CREATE INDEX IF NOT EXISTS idx_sessoes_usuarios_usuario_id ON sessoes_usuarios(usuario_id);
CREATE INDEX IF NOT EXISTS idx_sessoes_usuarios_token_sessao ON sessoes_usuarios(token_sessao);
CREATE INDEX IF NOT EXISTS idx_sessoes_usuarios_ativa ON sessoes_usuarios(ativa);

CREATE INDEX IF NOT EXISTS idx_tentativas_login_email ON tentativas_login(email);
CREATE INDEX IF NOT EXISTS idx_tentativas_login_ip_address ON tentativas_login(ip_address);
CREATE INDEX IF NOT EXISTS idx_tentativas_login_realizado_em ON tentativas_login(realizado_em);

-- Triggers
CREATE TRIGGER update_notificacoes_timestamp BEFORE UPDATE ON notificacoes
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_sincronizacao_timestamp BEFORE UPDATE ON sincronizacao
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_configuracoes_timestamp BEFORE UPDATE ON configuracoes
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();

-- Função para limpeza de dados antigos (pode ser chamada periodicamente)
CREATE OR REPLACE FUNCTION limpar_dados_antigos()
RETURNS void AS $$
BEGIN
  -- Deletar logs antigos (mais de 90 dias)
  DELETE FROM logs_auditoria WHERE created_at < NOW() - INTERVAL '90 days';
  
  -- Deletar tentativas de login falhadas (mais de 7 dias)
  DELETE FROM tentativas_login WHERE realizado_em < NOW() - INTERVAL '7 days' AND sucesso = FALSE;
  
  -- Deletar sessões expiradas
  DELETE FROM sessoes_usuarios WHERE encerrada_em IS NOT NULL AND created_at < NOW() - INTERVAL '30 days';
  
  -- Deletar sincronizações completadas (mais de 30 dias)
  DELETE FROM sincronizacao WHERE status = 'synced' AND updated_at < NOW() - INTERVAL '30 days';
END;
$$ LANGUAGE plpgsql;

-- Inserir configurações padrão do sistema
INSERT INTO configuracoes (chave, valor, tipo_valor, descricao, publica) VALUES
  ('intervalo_rastreamento_ms', '60000', 'number', 'Intervalo entre coletas de GPS (ms)', TRUE),
  ('timeout_sincronizacao_ms', '30000', 'number', 'Timeout para sincronização de dados (ms)', FALSE),
  ('limite_tamanho_foto_mb', '5', 'number', 'Tamanho máximo de foto em MB', FALSE),
  ('ativo', 'true', 'boolean', 'Sistema ativo para operações', FALSE),
  ('manutencao', 'false', 'boolean', 'Sistema em manutenção', FALSE)
ON CONFLICT DO NOTHING;
