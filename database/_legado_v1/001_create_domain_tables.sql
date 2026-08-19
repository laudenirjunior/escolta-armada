-- Escolta Armada: Tabelas de Domínio (Extensibilidade)
-- Estas tabelas contêm listas de valores que podem ser consultadas e estendidas sem migrations

-- 1. Perfis de Acesso (5 tipos)
CREATE TABLE IF NOT EXISTS dom_perfis (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(20) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_perfis (id, codigo, nome, descricao) VALUES
  (1, 'operador', 'Operador', 'Campo - recebe instruções, faz check-ins e relatórios'),
  (2, 'central', 'Operador Central', 'Acompanha operações em tempo real, escalações'),
  (3, 'supervisor', 'Supervisor', 'Monitora indicadores, aprova relatórios'),
  (4, 'gestor', 'Gestor', 'Administra cliente, escalação, financeiro'),
  (5, 'admin', 'Administrador', 'Sistema completo, auditoria, integrações')
ON CONFLICT DO NOTHING;

-- 2. Funções de Vigilante (motorista, segurança, chefe, etc)
CREATE TABLE IF NOT EXISTS dom_funcoes (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(30) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_funcoes (id, codigo, nome, descricao) VALUES
  (1, 'motorista', 'Motorista', 'Conduz veículo'),
  (2, 'seguranca_frente', 'Segurança (Frente)', 'Armado na frente'),
  (3, 'seguranca_retaguarda', 'Segurança (Retaguarda)', 'Armado na retaguarda'),
  (4, 'chefe_escolta', 'Chefe de Escolta', 'Responsável pela operação'),
  (5, 'radio_operador', 'Rádio Operador', 'Comunicação'),
  (6, 'supervisor_campo', 'Supervisor de Campo', 'Acompanha presencialmente')
ON CONFLICT DO NOTHING;

-- 3. Tipos de Veículo
CREATE TABLE IF NOT EXISTS dom_tipos_veiculo (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(30) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  capacidade_pessoas INT DEFAULT 0,
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_tipos_veiculo (id, codigo, nome, capacidade_pessoas) VALUES
  (1, 'blindado_leve', 'Blindado Leve', 4),
  (2, 'blindado_medio', 'Blindado Médio', 6),
  (3, 'blindado_pesado', 'Blindado Pesado', 8),
  (4, 'comum_aberto', 'Comum Aberto', 5),
  (5, 'moto', 'Motocicleta', 2)
ON CONFLICT DO NOTHING;

-- 4. Calibres de Armamento
CREATE TABLE IF NOT EXISTS dom_calibres (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(20) UNIQUE NOT NULL,
  nome VARCHAR(50) NOT NULL,
  descricao TEXT,
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_calibres (id, codigo, nome) VALUES
  (1, '9mm', '9mm'),
  (2, '40', '.40 S&W'),
  (3, '45', '.45 ACP'),
  (4, 'm16', 'M16 (.223)'),
  (5, 'ak47', 'AK-47 (7.62x39)'),
  (6, 'taurus_24', 'Taurus .24')
ON CONFLICT DO NOTHING;

-- 5. Tipos de Ponto de Controle (4 pontos)
CREATE TABLE IF NOT EXISTS dom_tipos_ponto (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(30) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_tipos_ponto (id, codigo, nome, descricao) VALUES
  (1, 'saida', 'Saída', 'Ponto de saída do cliente'),
  (2, 'ponto_intermediario', 'Ponto Intermediário', 'Local de espera ou transferência'),
  (3, 'chegada', 'Chegada', 'Destino final'),
  (4, 'retorno', 'Retorno', 'Volta ao ponto de origem')
ON CONFLICT DO NOTHING;

-- 6. Tipos de Ocorrência (eventos anormais)
CREATE TABLE IF NOT EXISTS dom_tipos_ocorrencia (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(30) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  eh_critica BOOLEAN DEFAULT FALSE,
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_tipos_ocorrencia (id, codigo, nome, eh_critica) VALUES
  (1, 'atraso', 'Atraso na Rota', FALSE),
  (2, 'desvio', 'Desvio de Rota', FALSE),
  (3, 'troca_veiculo', 'Troca de Veículo', FALSE),
  (4, 'pessoal_indisponivel', 'Pessoal Indisponível', TRUE),
  (5, 'acidente_leve', 'Acidente Leve', TRUE),
  (6, 'acidente_grave', 'Acidente Grave', TRUE),
  (7, 'perseguicao', 'Perseguição', TRUE),
  (8, 'disparos', 'Disparo de Armas', TRUE),
  (9, 'assalto', 'Assalto', TRUE),
  (10, 'problema_mecanico', 'Problema Mecânico', TRUE)
ON CONFLICT DO NOTHING;

-- 7. Tipos de Evento (para timeline)
CREATE TABLE IF NOT EXISTS dom_tipos_evento (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(30) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  icone VARCHAR(50),
  cor VARCHAR(20),
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_tipos_evento (id, codigo, nome, icone, cor) VALUES
  (1, 'escolta_iniciada', 'Escolta Iniciada', 'Play', 'green'),
  (2, 'presenca_registrada', 'Presença Registrada', 'User', 'blue'),
  (3, 'ponto_alcancado', 'Ponto Alcançado', 'MapPin', 'blue'),
  (4, 'checklist_concluido', 'Checklist Concluído', 'CheckCircle', 'green'),
  (5, 'foto_registrada', 'Foto Registrada', 'Camera', 'purple'),
  (6, 'atualizacao_status', 'Atualização de Status', 'Clock', 'orange'),
  (7, 'ocorrencia_reportada', 'Ocorrência Reportada', 'AlertCircle', 'red'),
  (8, 'emergencia_acionada', 'Emergência Acionada', 'AlertTriangle', 'red'),
  (9, 'escolta_finalizada', 'Escolta Finalizada', 'CheckCircle', 'green'),
  (10, 'desvio_rota', 'Desvio de Rota', 'AlertCircle', 'orange')
ON CONFLICT DO NOTHING;

-- 8. Tipos de Foto (contexto/evidência)
CREATE TABLE IF NOT EXISTS dom_tipos_foto (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(30) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  obrigatoria BOOLEAN DEFAULT FALSE,
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_tipos_foto (id, codigo, nome, obrigatoria) VALUES
  (1, 'veiculo_frontal', 'Veículo - Frontal', TRUE),
  (2, 'veiculo_traseiro', 'Veículo - Traseiro', TRUE),
  (3, 'veiculo_lateral_esq', 'Veículo - Lateral Esquerdo', TRUE),
  (4, 'veiculo_lateral_dir', 'Veículo - Lateral Direito', TRUE),
  (5, 'interior_veiculo', 'Interior do Veículo', FALSE),
  (6, 'cliente_pickup', 'Cliente - Pickup', TRUE),
  (7, 'cliente_entrega', 'Cliente - Entrega', TRUE),
  (8, 'local_saida', 'Local de Saída', FALSE),
  (9, 'local_chegada', 'Local de Chegada', FALSE),
  (10, 'ocorrencia', 'Ocorrência/Evidência', FALSE)
ON CONFLICT DO NOTHING;

-- 9. Tipos de Checklist
CREATE TABLE IF NOT EXISTS dom_tipos_checklist (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(30) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  obrigatorio BOOLEAN DEFAULT FALSE,
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_tipos_checklist (id, codigo, nome, obrigatorio) VALUES
  (1, 'checklist_veiculo', 'Checklist de Veículo', TRUE),
  (2, 'checklist_armamento', 'Checklist de Armamento', TRUE),
  (3, 'checklist_seguranca', 'Checklist de Segurança', TRUE),
  (4, 'checklist_saida', 'Checklist de Saída', TRUE),
  (5, 'checklist_retorno', 'Checklist de Retorno', TRUE)
ON CONFLICT DO NOTHING;

-- 10. Status de Usuário (não pode estar em 2 status ao mesmo tempo)
CREATE TABLE IF NOT EXISTS dom_status_usuario (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(30) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_status_usuario (id, codigo, nome) VALUES
  (1, 'ativo', 'Ativo'),
  (2, 'inativo', 'Inativo'),
  (3, 'bloqueado', 'Bloqueado'),
  (4, 'suspenso', 'Suspenso')
ON CONFLICT DO NOTHING;

-- 11. Status de Escolta (máquina de estados)
CREATE TABLE IF NOT EXISTS dom_status_escolta (
  id SMALLINT PRIMARY KEY,
  codigo VARCHAR(30) UNIQUE NOT NULL,
  nome VARCHAR(100) NOT NULL,
  descricao TEXT,
  cor VARCHAR(20) DEFAULT 'gray',
  ativo BOOLEAN DEFAULT TRUE,
  ordem INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO dom_status_escolta (id, codigo, nome, cor) VALUES
  (1, 'planejada', 'Planejada', 'yellow'),
  (2, 'confirmada', 'Confirmada', 'blue'),
  (3, 'em_preparacao', 'Em Preparação', 'purple'),
  (4, 'em_transito', 'Em Trânsito', 'orange'),
  (5, 'em_local', 'No Local', 'cyan'),
  (6, 'em_retorno', 'Em Retorno', 'orange'),
  (7, 'finalizada', 'Finalizada', 'green'),
  (8, 'cancelada', 'Cancelada', 'red'),
  (9, 'incidente', 'Incidente', 'red'),
  (10, 'suspenso', 'Suspenso', 'orange')
ON CONFLICT DO NOTHING;

-- Criar índices nas tabelas de domínio
CREATE INDEX IF NOT EXISTS idx_dom_perfis_codigo ON dom_perfis(codigo);
CREATE INDEX IF NOT EXISTS idx_dom_perfis_ativo ON dom_perfis(ativo);
CREATE INDEX IF NOT EXISTS idx_dom_funcoes_codigo ON dom_funcoes(codigo);
CREATE INDEX IF NOT EXISTS idx_dom_funcoes_ativo ON dom_funcoes(ativo);
CREATE INDEX IF NOT EXISTS idx_dom_tipos_veiculo_codigo ON dom_tipos_veiculo(codigo);
CREATE INDEX IF NOT EXISTS idx_dom_tipos_ponto_codigo ON dom_tipos_ponto(codigo);
CREATE INDEX IF NOT EXISTS idx_dom_tipos_ocorrencia_codigo ON dom_tipos_ocorrencia(codigo);
CREATE INDEX IF NOT EXISTS idx_dom_tipos_evento_codigo ON dom_tipos_evento(codigo);
CREATE INDEX IF NOT EXISTS idx_dom_tipos_foto_codigo ON dom_tipos_foto(codigo);
CREATE INDEX IF NOT EXISTS idx_dom_tipos_checklist_codigo ON dom_tipos_checklist(codigo);
CREATE INDEX IF NOT EXISTS idx_dom_status_usuario_codigo ON dom_status_usuario(codigo);
CREATE INDEX IF NOT EXISTS idx_dom_status_escolta_codigo ON dom_status_escolta(codigo);

-- Alterar políticas de acesso (públicas, só leitura)
ALTER TABLE dom_perfis ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_funcoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_tipos_veiculo ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_calibres ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_tipos_ponto ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_tipos_ocorrencia ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_tipos_evento ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_tipos_foto ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_tipos_checklist ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_status_usuario ENABLE ROW LEVEL SECURITY;
ALTER TABLE dom_status_escolta ENABLE ROW LEVEL SECURITY;

-- Políticas de leitura (públicas - todos podem ler)
CREATE POLICY "Todos podem ler dom_perfis" ON dom_perfis FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_funcoes" ON dom_funcoes FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_tipos_veiculo" ON dom_tipos_veiculo FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_calibres" ON dom_calibres FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_tipos_ponto" ON dom_tipos_ponto FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_tipos_ocorrencia" ON dom_tipos_ocorrencia FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_tipos_evento" ON dom_tipos_evento FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_tipos_foto" ON dom_tipos_foto FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_tipos_checklist" ON dom_tipos_checklist FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_status_usuario" ON dom_status_usuario FOR SELECT USING (ativo = TRUE);
CREATE POLICY "Todos podem ler dom_status_escolta" ON dom_status_escolta FOR SELECT USING (ativo = TRUE);
