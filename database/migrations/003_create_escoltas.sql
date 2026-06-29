-- Escolta Armada: Tabelas Operacionais
-- Escoltas, veículos, efetivo, armamentos

-- 1. Escoltas (operação central)
CREATE TABLE IF NOT EXISTS escoltas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES clientes(id),
  
  -- Identificação
  codigo VARCHAR(50) UNIQUE NOT NULL, -- ESC-xxxxx-xxxxx
  numero INT,
  
  -- Tipo de Operação
  tipo VARCHAR(50) DEFAULT 'transporte', -- transporte, acompanhamento, etc
  descricao_servico TEXT,
  
  -- Datas e Horas
  data_prevista DATE NOT NULL,
  hora_saida_prevista TIME,
  hora_retorno_prevista TIME,
  
  data_execucao DATE,
  hora_saida_real TIMESTAMP WITH TIME ZONE,
  hora_chegada_ponto TIMESTAMP WITH TIME ZONE,
  hora_retorno_real TIMESTAMP WITH TIME ZONE,
  
  -- Locais
  local_saida VARCHAR(255),
  local_saida_lat NUMERIC(10, 8),
  local_saida_lng NUMERIC(11, 8),
  
  local_destino VARCHAR(255),
  local_destino_lat NUMERIC(10, 8),
  local_destino_lng NUMERIC(11, 8),
  
  observacoes_rota TEXT,
  
  -- Status (máquina de estados)
  status_id SMALLINT NOT NULL DEFAULT 1 REFERENCES dom_status_escolta(id),
  
  -- Pessoal
  responsavel_id UUID REFERENCES usuarios(id),
  chefe_escolta_id UUID REFERENCES vigilantes(id),
  
  -- Dados Financeiros
  valor_previsto NUMERIC(12, 2),
  valor_realizado NUMERIC(12, 2),
  desconto NUMERIC(12, 2) DEFAULT 0,
  observacoes_faturamento TEXT,
  
  -- Aprovação
  aprovado_supervisor_em TIMESTAMP WITH TIME ZONE,
  aprovado_supervisor_por UUID REFERENCES usuarios(id),
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  deleted_at TIMESTAMP WITH TIME ZONE
);

-- 2. Veículos em Escolta (1:N)
CREATE TABLE IF NOT EXISTS escolta_veiculos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  veiculo_id UUID NOT NULL REFERENCES veiculos(id),
  
  -- Ordem e Posição
  ordem INT DEFAULT 1,
  posicao VARCHAR(50), -- Frente, Meio, Retaguarda
  
  -- Quilometragem
  quilometragem_saida INT,
  quilometragem_retorno INT,
  
  -- Status
  ativo BOOLEAN DEFAULT TRUE,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  UNIQUE(escolta_id, veiculo_id)
);

-- 3. Efetivo em Escolta (vigilantes por veículo)
CREATE TABLE IF NOT EXISTS escolta_efetivo (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  escolta_veiculo_id UUID NOT NULL REFERENCES escolta_veiculos(id) ON DELETE CASCADE,
  vigilante_id UUID NOT NULL REFERENCES vigilantes(id),
  
  -- Função do Vigilante
  funcao_id SMALLINT NOT NULL REFERENCES dom_funcoes(id),
  
  -- Status
  confirmado BOOLEAN DEFAULT FALSE,
  confirmado_em TIMESTAMP WITH TIME ZONE,
  presenca_confirmada BOOLEAN DEFAULT FALSE,
  presenca_confirmada_em TIMESTAMP WITH TIME ZONE,
  
  -- Pagamento
  valor_diaria NUMERIC(12, 2),
  pago BOOLEAN DEFAULT FALSE,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  UNIQUE(escolta_id, vigilante_id)
);

-- 4. Armamentos em Escolta
CREATE TABLE IF NOT EXISTS escolta_armamentos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  escolta_efetivo_id UUID NOT NULL REFERENCES escolta_efetivo(id) ON DELETE CASCADE,
  armamento_id UUID NOT NULL REFERENCES armamentos(id),
  
  -- Saída/Retorno
  retirado_em TIMESTAMP WITH TIME ZONE,
  retirado_por UUID REFERENCES usuarios(id),
  devolvido_em TIMESTAMP WITH TIME ZONE,
  devolvido_por UUID REFERENCES usuarios(id),
  
  -- Munição
  municao_retirada INT DEFAULT 0,
  municao_devolvida INT DEFAULT 0,
  municao_disparada INT DEFAULT 0,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  UNIQUE(escolta_id, armamento_id)
);

-- Criar índices
CREATE INDEX IF NOT EXISTS idx_escoltas_cliente_id ON escoltas(cliente_id);
CREATE INDEX IF NOT EXISTS idx_escoltas_codigo ON escoltas(codigo);
CREATE INDEX IF NOT EXISTS idx_escoltas_status_id ON escoltas(status_id);
CREATE INDEX IF NOT EXISTS idx_escoltas_data_prevista ON escoltas(data_prevista);
CREATE INDEX IF NOT EXISTS idx_escoltas_data_execucao ON escoltas(data_execucao);
CREATE INDEX IF NOT EXISTS idx_escoltas_chefe_escolta_id ON escoltas(chefe_escolta_id);

CREATE INDEX IF NOT EXISTS idx_escolta_veiculos_escolta_id ON escolta_veiculos(escolta_id);
CREATE INDEX IF NOT EXISTS idx_escolta_veiculos_veiculo_id ON escolta_veiculos(veiculo_id);

CREATE INDEX IF NOT EXISTS idx_escolta_efetivo_escolta_id ON escolta_efetivo(escolta_id);
CREATE INDEX IF NOT EXISTS idx_escolta_efetivo_vigilante_id ON escolta_efetivo(vigilante_id);
CREATE INDEX IF NOT EXISTS idx_escolta_efetivo_confirmado ON escolta_efetivo(confirmado);

CREATE INDEX IF NOT EXISTS idx_escolta_armamentos_escolta_id ON escolta_armamentos(escolta_id);
CREATE INDEX IF NOT EXISTS idx_escolta_armamentos_armamento_id ON escolta_armamentos(armamento_id);

-- Triggers para updated_at
CREATE TRIGGER update_escoltas_timestamp BEFORE UPDATE ON escoltas
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_escolta_veiculos_timestamp BEFORE UPDATE ON escolta_veiculos
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_escolta_efetivo_timestamp BEFORE UPDATE ON escolta_efetivo
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_escolta_armamentos_timestamp BEFORE UPDATE ON escolta_armamentos
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
