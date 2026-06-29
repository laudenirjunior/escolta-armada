-- Escolta Armada: Tabelas de Checklists e Contexto
-- Modelos reutilizáveis, execução, histórico de status

-- 1. Modelos de Checklist (reutilizáveis)
CREATE TABLE IF NOT EXISTS checklist_modelos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID REFERENCES clientes(id),
  
  -- Dados
  codigo VARCHAR(50) UNIQUE NOT NULL,
  nome VARCHAR(255) NOT NULL,
  descricao TEXT,
  tipo_id SMALLINT NOT NULL REFERENCES dom_tipos_checklist(id),
  
  -- Versão (para histórico)
  versao INT DEFAULT 1,
  
  -- Status
  ativo BOOLEAN DEFAULT TRUE,
  obrigatorio BOOLEAN DEFAULT FALSE,
  
  -- Ordem
  ordem INT DEFAULT 0,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  deleted_at TIMESTAMP WITH TIME ZONE
);

-- 2. Itens do Modelo de Checklist
CREATE TABLE IF NOT EXISTS checklist_modelos_itens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  modelo_id UUID NOT NULL REFERENCES checklist_modelos(id) ON DELETE CASCADE,
  
  -- Dados
  ordem INT NOT NULL,
  texto VARCHAR(255) NOT NULL,
  tipo_resposta VARCHAR(20), -- boolean, texto, numerico, selecao
  valores_opcoes JSONB, -- Para tipo selecao
  
  -- Validação
  obrigatorio BOOLEAN DEFAULT TRUE,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. Execução de Checklist
CREATE TABLE IF NOT EXISTS checklists (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  modelo_id UUID NOT NULL REFERENCES checklist_modelos(id),
  modelo_versao INT NOT NULL DEFAULT 1, -- Guardar versão para histórico
  
  -- Execução
  iniciado_em TIMESTAMP WITH TIME ZONE,
  concluido_em TIMESTAMP WITH TIME ZONE,
  
  -- Responsável
  executado_por UUID NOT NULL REFERENCES usuarios(id),
  validado_por UUID REFERENCES usuarios(id),
  
  -- Status
  completo BOOLEAN DEFAULT FALSE,
  validado BOOLEAN DEFAULT FALSE,
  
  -- Observações
  observacoes TEXT,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. Respostas do Checklist (item a item)
CREATE TABLE IF NOT EXISTS checklist_respostas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_id UUID NOT NULL REFERENCES checklists(id) ON DELETE CASCADE,
  item_id UUID NOT NULL REFERENCES checklist_modelos_itens(id),
  
  -- Resposta
  resposta_booleana BOOLEAN,
  resposta_texto TEXT,
  resposta_numerica NUMERIC(15, 2),
  resposta_opcao VARCHAR(255),
  
  -- Hora
  respondido_em TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  -- Observação
  observacao TEXT,
  
  -- Foto (opcional)
  foto_id UUID REFERENCES fotos(id),
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. Atualizações de Status (timeline de eventos)
CREATE TABLE IF NOT EXISTS atualizacoes_status (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  
  -- Status Anterior e Novo
  status_anterior_id SMALLINT REFERENCES dom_status_escolta(id),
  status_novo_id SMALLINT NOT NULL REFERENCES dom_status_escolta(id),
  
  -- Motivo
  motivo VARCHAR(255),
  observacoes TEXT,
  
  -- Quem fez
  atualizado_por UUID NOT NULL REFERENCES usuarios(id),
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 6. Ocorrências (eventos anormais)
CREATE TABLE IF NOT EXISTS ocorrencias (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  
  -- Tipo de Ocorrência
  tipo_ocorrencia_id SMALLINT NOT NULL REFERENCES dom_tipos_ocorrencia(id),
  
  -- Descrição
  descricao TEXT NOT NULL,
  observacoes TEXT,
  
  -- Hora
  hora_ocorrencia TIMESTAMP WITH TIME ZONE NOT NULL,
  hora_reporte TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  -- Local (se diferente da rota)
  latitude NUMERIC(10, 8),
  longitude NUMERIC(11, 8),
  endereco_textual VARCHAR(255),
  
  -- Foto de Evidência
  foto_id UUID REFERENCES fotos(id),
  
  -- Quem reportou
  reportado_por UUID NOT NULL REFERENCES usuarios(id),
  
  -- Aprovação
  aprovado_supervisor BOOLEAN DEFAULT FALSE,
  aprovado_supervisor_por UUID REFERENCES usuarios(id),
  aprovado_supervisor_em TIMESTAMP WITH TIME ZONE,
  
  -- Ações Tomadas
  acoes_tomadas TEXT,
  resolvida BOOLEAN DEFAULT FALSE,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 7. Emergências (acionamentos críticos)
CREATE TABLE IF NOT EXISTS emergencias (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  
  -- Tipo
  tipo_emergencia VARCHAR(50), -- 'assalto', 'acidente', 'perseguicao', etc
  
  -- Descrição e Evidências
  descricao TEXT NOT NULL,
  observacoes TEXT,
  foto_id UUID REFERENCES fotos(id),
  
  -- Hora e Local
  hora_acionamento TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  hora_resposta TIMESTAMP WITH TIME ZONE,
  hora_resolucao TIMESTAMP WITH TIME ZONE,
  
  latitude NUMERIC(10, 8),
  longitude NUMERIC(11, 8),
  
  -- Contatos Notificados
  policia_notificada BOOLEAN DEFAULT FALSE,
  bombeiros_notificado BOOLEAN DEFAULT FALSE,
  cliente_notificado BOOLEAN DEFAULT FALSE,
  
  -- Status
  resolvida BOOLEAN DEFAULT FALSE,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Criar índices
CREATE INDEX IF NOT EXISTS idx_checklist_modelos_cliente_id ON checklist_modelos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_checklist_modelos_codigo ON checklist_modelos(codigo);
CREATE INDEX IF NOT EXISTS idx_checklist_modelos_tipo_id ON checklist_modelos(tipo_id);

CREATE INDEX IF NOT EXISTS idx_checklist_modelos_itens_modelo_id ON checklist_modelos_itens(modelo_id);

CREATE INDEX IF NOT EXISTS idx_checklists_escolta_id ON checklists(escolta_id);
CREATE INDEX IF NOT EXISTS idx_checklists_modelo_id ON checklists(modelo_id);
CREATE INDEX IF NOT EXISTS idx_checklists_completo ON checklists(completo);
CREATE INDEX IF NOT EXISTS idx_checklists_validado ON checklists(validado);

CREATE INDEX IF NOT EXISTS idx_checklist_respostas_checklist_id ON checklist_respostas(checklist_id);
CREATE INDEX IF NOT EXISTS idx_checklist_respostas_item_id ON checklist_respostas(item_id);

CREATE INDEX IF NOT EXISTS idx_atualizacoes_status_escolta_id ON atualizacoes_status(escolta_id);
CREATE INDEX IF NOT EXISTS idx_atualizacoes_status_status_novo_id ON atualizacoes_status(status_novo_id);
CREATE INDEX IF NOT EXISTS idx_atualizacoes_status_created_at ON atualizacoes_status(created_at);

CREATE INDEX IF NOT EXISTS idx_ocorrencias_escolta_id ON ocorrencias(escolta_id);
CREATE INDEX IF NOT EXISTS idx_ocorrencias_tipo_ocorrencia_id ON ocorrencias(tipo_ocorrencia_id);
CREATE INDEX IF NOT EXISTS idx_ocorrencias_hora_ocorrencia ON ocorrencias(hora_ocorrencia);
CREATE INDEX IF NOT EXISTS idx_ocorrencias_resolvida ON ocorrencias(resolvida);

CREATE INDEX IF NOT EXISTS idx_emergencias_escolta_id ON emergencias(escolta_id);
CREATE INDEX IF NOT EXISTS idx_emergencias_hora_acionamento ON emergencias(hora_acionamento);
CREATE INDEX IF NOT EXISTS idx_emergencias_resolvida ON emergencias(resolvida);

-- Triggers
CREATE TRIGGER update_checklist_modelos_timestamp BEFORE UPDATE ON checklist_modelos
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_checklist_modelos_itens_timestamp BEFORE UPDATE ON checklist_modelos_itens
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_checklists_timestamp BEFORE UPDATE ON checklists
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_checklist_respostas_timestamp BEFORE UPDATE ON checklist_respostas
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_atualizacoes_status_timestamp BEFORE UPDATE ON atualizacoes_status
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_ocorrencias_timestamp BEFORE UPDATE ON ocorrencias
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_emergencias_timestamp BEFORE UPDATE ON emergencias
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
