-- Escolta Armada: Tabelas de Geolocalização e Fotos
-- Rastreamento GPS, pontos de controle, fotos com carimbo

-- 1. Pontos de Controle (check-ins georreferenciados)
CREATE TABLE IF NOT EXISTS pontos_controle (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  tipo_ponto_id SMALLINT NOT NULL REFERENCES dom_tipos_ponto(id),
  
  -- Localização
  latitude NUMERIC(10, 8) NOT NULL,
  longitude NUMERIC(11, 8) NOT NULL,
  altitude NUMERIC(10, 2),
  
  -- Hora
  hora_chegada TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  hora_saida TIMESTAMP WITH TIME ZONE,
  tempo_parado_minutos INT DEFAULT 0,
  
  -- Pessoa
  registrado_por UUID REFERENCES usuarios(id),
  confirmado_por UUID REFERENCES usuarios(id),
  
  -- Status
  confirmado BOOLEAN DEFAULT FALSE,
  confirmado_em TIMESTAMP WITH TIME ZONE,
  
  -- Endereço (geocoding reverso)
  endereco_textual VARCHAR(255),
  
  -- Observações
  observacoes TEXT,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Rastreamento (posições periódicas)
CREATE TABLE IF NOT EXISTS rastreamento (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  escolta_veiculo_id UUID REFERENCES escolta_veiculos(id),
  
  -- Localização
  latitude NUMERIC(10, 8) NOT NULL,
  longitude NUMERIC(11, 8) NOT NULL,
  altitude NUMERIC(10, 2),
  
  -- Precisão
  precisao_metros INT,
  fonte VARCHAR(50), -- GPS, NETWORK, etc
  
  -- Movimento
  velocidade_kmh NUMERIC(5, 2),
  direcao_graus NUMERIC(5, 2),
  
  -- Hora
  timestamp_coleta TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  timestamp_envio TIMESTAMP WITH TIME ZONE,
  
  -- Ambiente
  temperatura_celsius NUMERIC(4, 1),
  bateria_percentual INT,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. Presença (check-in de presença)
CREATE TABLE IF NOT EXISTS presencas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  escolta_efetivo_id UUID NOT NULL REFERENCES escolta_efetivo(id) ON DELETE CASCADE,
  
  -- Localização
  latitude NUMERIC(10, 8),
  longitude NUMERIC(11, 8),
  
  -- Hora
  hora_checkin TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  -- Foto (opcional)
  foto_url VARCHAR(500),
  
  -- Status
  confirmado BOOLEAN DEFAULT FALSE,
  observacoes TEXT,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. Fotos (repositório central com carimbo)
CREATE TABLE IF NOT EXISTS fotos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id UUID NOT NULL REFERENCES escoltas(id) ON DELETE CASCADE,
  
  -- Tipo de Foto
  tipo_foto_id SMALLINT NOT NULL REFERENCES dom_tipos_foto(id),
  
  -- Arquivo
  nome_arquivo VARCHAR(255) NOT NULL,
  url_completa VARCHAR(500) NOT NULL,
  url_thumbnail VARCHAR(500),
  tamanho_bytes INT,
  mime_type VARCHAR(50),
  
  -- Carimbo (gerado pelo dispositivo)
  latitude NUMERIC(10, 8),
  longitude NUMERIC(11, 8),
  altitude NUMERIC(10, 2),
  
  hora_foto TIMESTAMP WITH TIME ZONE NOT NULL,
  hora_upload TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  -- Quem tirou
  fotografo_id UUID NOT NULL REFERENCES usuarios(id),
  escolta_efetivo_id UUID REFERENCES escolta_efetivo(id),
  
  -- Validação
  validada BOOLEAN DEFAULT FALSE,
  validada_por UUID REFERENCES usuarios(id),
  validada_em TIMESTAMP WITH TIME ZONE,
  motivo_rejeicao TEXT,
  
  -- Metadados
  metadados JSONB DEFAULT '{}', -- Ex: ISO, EV, foco automático, etc
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. Tabela de Storage (referência ao Supabase Storage)
CREATE TABLE IF NOT EXISTS fotos_storage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  foto_id UUID UNIQUE NOT NULL REFERENCES fotos(id) ON DELETE CASCADE,
  
  -- Referência ao Storage
  bucket VARCHAR(100) DEFAULT 'escoltas',
  storage_path VARCHAR(500) NOT NULL,
  
  -- Metadados do arquivo
  tamanho_kb INT,
  duracao_segundos INT, -- Se for vídeo
  hash_arquivo VARCHAR(64),
  
  -- Processamento
  processada BOOLEAN DEFAULT FALSE,
  comprimida BOOLEAN DEFAULT FALSE,
  thumbnail_criada BOOLEAN DEFAULT FALSE,
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Criar índices
CREATE INDEX IF NOT EXISTS idx_pontos_controle_escolta_id ON pontos_controle(escolta_id);
CREATE INDEX IF NOT EXISTS idx_pontos_controle_tipo_ponto_id ON pontos_controle(tipo_ponto_id);
CREATE INDEX IF NOT EXISTS idx_pontos_controle_hora_chegada ON pontos_controle(hora_chegada);
CREATE INDEX IF NOT EXISTS idx_pontos_controle_geoindex ON pontos_controle USING GIST (
  ll_to_earth(latitude, longitude)
);

CREATE INDEX IF NOT EXISTS idx_rastreamento_escolta_id ON rastreamento(escolta_id);
CREATE INDEX IF NOT EXISTS idx_rastreamento_escolta_veiculo_id ON rastreamento(escolta_veiculo_id);
CREATE INDEX IF NOT EXISTS idx_rastreamento_timestamp_coleta ON rastreamento(timestamp_coleta);
CREATE INDEX IF NOT EXISTS idx_rastreamento_geoindex ON rastreamento USING GIST (
  ll_to_earth(latitude, longitude)
);

CREATE INDEX IF NOT EXISTS idx_presencas_escolta_id ON presencas(escolta_id);
CREATE INDEX IF NOT EXISTS idx_presencas_escolta_efetivo_id ON presencas(escolta_efetivo_id);
CREATE INDEX IF NOT EXISTS idx_presencas_hora_checkin ON presencas(hora_checkin);

CREATE INDEX IF NOT EXISTS idx_fotos_escolta_id ON fotos(escolta_id);
CREATE INDEX IF NOT EXISTS idx_fotos_tipo_foto_id ON fotos(tipo_foto_id);
CREATE INDEX IF NOT EXISTS idx_fotos_fotografo_id ON fotos(fotografo_id);
CREATE INDEX IF NOT EXISTS idx_fotos_validada ON fotos(validada);
CREATE INDEX IF NOT EXISTS idx_fotos_hora_foto ON fotos(hora_foto);

CREATE INDEX IF NOT EXISTS idx_fotos_storage_foto_id ON fotos_storage(foto_id);
CREATE INDEX IF NOT EXISTS idx_fotos_storage_bucket ON fotos_storage(bucket);

-- Triggers
CREATE TRIGGER update_pontos_controle_timestamp BEFORE UPDATE ON pontos_controle
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_presencas_timestamp BEFORE UPDATE ON presencas
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_fotos_timestamp BEFORE UPDATE ON fotos
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_fotos_storage_timestamp BEFORE UPDATE ON fotos_storage
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();

-- Habilitar extensão de geolocalização (se não estiver)
CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;
