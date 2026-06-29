-- Escolta Armada: Tabelas de Usuários e Pessoas
-- Autenticação, papéis, vigilantes, clientes

-- 1. Usuários (acesso ao sistema via Supabase Auth)
CREATE TABLE IF NOT EXISTS usuarios (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id UUID UNIQUE NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  -- Dados Pessoais
  nome VARCHAR(255) NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL,
  cpf VARCHAR(14) UNIQUE NOT NULL,
  telefone VARCHAR(20),
  
  -- Perfil e Acesso
  perfil_id SMALLINT NOT NULL REFERENCES dom_perfis(id),
  cliente_id UUID, -- Null se admin/gestor multi-cliente
  ativo BOOLEAN DEFAULT TRUE,
  status_id SMALLINT NOT NULL DEFAULT 1 REFERENCES dom_status_usuario(id),
  
  -- Segurança
  senha_temporaria BOOLEAN DEFAULT FALSE,
  senha_alterada_em TIMESTAMP WITH TIME ZONE,
  ultimo_login TIMESTAMP WITH TIME ZONE,
  tentativas_login_falhas INT DEFAULT 0,
  bloqueado_ate TIMESTAMP WITH TIME ZONE,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  deleted_at TIMESTAMP WITH TIME ZONE
);

-- 2. Vigilantes (pessoas que trabalham na segurança)
CREATE TABLE IF NOT EXISTS vigilantes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Dados Pessoais
  nome VARCHAR(255) NOT NULL,
  cpf VARCHAR(14) UNIQUE NOT NULL,
  rg VARCHAR(20),
  data_nascimento DATE,
  sexo CHAR(1), -- M, F
  telefone VARCHAR(20),
  
  -- Documentação
  cnh VARCHAR(20),
  cnh_validade DATE,
  ctps VARCHAR(20),
  pis VARCHAR(20),
  
  -- Certificações
  registro_seguranca VARCHAR(30), -- Número de registro
  validade_registro DATE,
  certificacao_adicional TEXT,
  
  -- Situação
  ativo BOOLEAN DEFAULT TRUE,
  status_id SMALLINT NOT NULL DEFAULT 1 REFERENCES dom_status_usuario(id),
  
  -- Dados Bancários
  banco VARCHAR(5),
  agencia VARCHAR(10),
  conta VARCHAR(20),
  tipo_conta VARCHAR(10), -- CC, CP
  titular VARCHAR(255),
  
  -- Endereço
  endereco VARCHAR(255),
  numero VARCHAR(10),
  complemento VARCHAR(100),
  bairro VARCHAR(100),
  cidade VARCHAR(100),
  estado CHAR(2),
  cep VARCHAR(10),
  
  -- Contato Emergência
  contato_emergencia_nome VARCHAR(255),
  contato_emergencia_telefone VARCHAR(20),
  contato_emergencia_relacao VARCHAR(50),
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  deleted_at TIMESTAMP WITH TIME ZONE
);

-- 3. Clientes (quem contrata o serviço)
CREATE TABLE IF NOT EXISTS clientes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Dados Básicos
  nome_razao_social VARCHAR(255) NOT NULL,
  documento VARCHAR(20) UNIQUE NOT NULL, -- CNPJ ou CPF
  
  -- Tipo
  eh_pessoa_juridica BOOLEAN DEFAULT TRUE,
  inscricao_estadual VARCHAR(30),
  
  -- Contato Principal
  email VARCHAR(255),
  telefone_principal VARCHAR(20),
  telefone_adicional VARCHAR(20),
  
  -- Endereço
  endereco_rua VARCHAR(255),
  endereco_numero VARCHAR(10),
  endereco_complemento VARCHAR(100),
  endereco_bairro VARCHAR(100),
  endereco_cidade VARCHAR(100),
  endereco_estado CHAR(2),
  endereco_cep VARCHAR(10),
  
  -- Dados Comerciais
  ativo BOOLEAN DEFAULT TRUE,
  limite_credito NUMERIC(15, 2) DEFAULT 0,
  categoria VARCHAR(50), -- Banco, Justiça, Empresarial, Particular
  observacoes TEXT,
  
  -- Integração
  codigo_externo VARCHAR(50),
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  deleted_at TIMESTAMP WITH TIME ZONE
);

-- 4. Veículos
CREATE TABLE IF NOT EXISTS veiculos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES clientes(id),
  
  -- Identificação
  placa VARCHAR(10) UNIQUE NOT NULL,
  renavam VARCHAR(20),
  chassis VARCHAR(30),
  
  -- Dados
  marca VARCHAR(100),
  modelo VARCHAR(100),
  ano_fabricacao INT,
  ano_modelo INT,
  cor VARCHAR(50),
  tipo_id SMALLINT REFERENCES dom_tipos_veiculo(id),
  
  -- Documentação
  data_emplacamento DATE,
  data_vencimento_placa DATE,
  data_vencimento_seguro DATE,
  numero_seguro VARCHAR(50),
  seguradora VARCHAR(100),
  
  -- Estado
  ativo BOOLEAN DEFAULT TRUE,
  quilometragem_atual INT DEFAULT 0,
  ultima_manutencao DATE,
  proxima_manutencao DATE,
  em_manutencao BOOLEAN DEFAULT FALSE,
  
  -- Capacidade
  capacidade_pessoas INT,
  capacidade_blindagem VARCHAR(100),
  
  -- Rastreamento
  rastreador_ativo BOOLEAN DEFAULT FALSE,
  numero_rastreador VARCHAR(50),
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  deleted_at TIMESTAMP WITH TIME ZONE
);

-- 5. Armamentos
CREATE TABLE IF NOT EXISTS armamentos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES clientes(id),
  
  -- Identificação
  numero_serie VARCHAR(50) UNIQUE NOT NULL,
  
  -- Dados
  tipo VARCHAR(100),
  marca VARCHAR(100),
  calibre_id SMALLINT REFERENCES dom_calibres(id),
  
  -- Documentação
  numero_empenho VARCHAR(50),
  data_empenho DATE,
  data_vencimento_empenho DATE,
  
  -- Estado
  ativo BOOLEAN DEFAULT TRUE,
  disponivel BOOLEAN DEFAULT TRUE,
  em_manutencao BOOLEAN DEFAULT FALSE,
  
  -- Munição
  municao_tipo VARCHAR(100),
  municao_quantidade INT DEFAULT 0,
  
  -- Metadados
  metadados JSONB DEFAULT '{}',
  
  -- Auditoria
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  deleted_at TIMESTAMP WITH TIME ZONE
);

-- Criar índices para performance
CREATE INDEX IF NOT EXISTS idx_usuarios_auth_id ON usuarios(auth_id);
CREATE INDEX IF NOT EXISTS idx_usuarios_perfil_id ON usuarios(perfil_id);
CREATE INDEX IF NOT EXISTS idx_usuarios_cliente_id ON usuarios(cliente_id);
CREATE INDEX IF NOT EXISTS idx_usuarios_ativo ON usuarios(ativo);
CREATE INDEX IF NOT EXISTS idx_usuarios_email ON usuarios(email);
CREATE INDEX IF NOT EXISTS idx_usuarios_cpf ON usuarios(cpf);

CREATE INDEX IF NOT EXISTS idx_vigilantes_cpf ON vigilantes(cpf);
CREATE INDEX IF NOT EXISTS idx_vigilantes_ativo ON vigilantes(ativo);
CREATE INDEX IF NOT EXISTS idx_vigilantes_status_id ON vigilantes(status_id);

CREATE INDEX IF NOT EXISTS idx_clientes_documento ON clientes(documento);
CREATE INDEX IF NOT EXISTS idx_clientes_ativo ON clientes(ativo);

CREATE INDEX IF NOT EXISTS idx_veiculos_cliente_id ON veiculos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_veiculos_placa ON veiculos(placa);
CREATE INDEX IF NOT EXISTS idx_veiculos_ativo ON veiculos(ativo);

CREATE INDEX IF NOT EXISTS idx_armamentos_cliente_id ON armamentos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_armamentos_numero_serie ON armamentos(numero_serie);
CREATE INDEX IF NOT EXISTS idx_armamentos_ativo ON armamentos(ativo);
CREATE INDEX IF NOT EXISTS idx_armamentos_disponivel ON armamentos(disponivel);

-- Criar funções de atualização (updated_at)
CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_usuarios_timestamp BEFORE UPDATE ON usuarios
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_vigilantes_timestamp BEFORE UPDATE ON vigilantes
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_clientes_timestamp BEFORE UPDATE ON clientes
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_veiculos_timestamp BEFORE UPDATE ON veiculos
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER update_armamentos_timestamp BEFORE UPDATE ON armamentos
  FOR EACH ROW EXECUTE FUNCTION update_timestamp();
