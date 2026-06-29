-- Escolta Armada: Dados Iniciais para Teste
-- Execute APENAS DEPOIS de todas as 7 migrações

-- ============================================================================
-- 1. CLIENTES DE TESTE
-- ============================================================================
INSERT INTO clientes (
  id, nome_razao_social, documento, eh_pessoa_juridica,
  email, telefone_principal, categoria, ativo
) VALUES
  (gen_random_uuid(), 'Banco do Brasil S.A.', '00000000000191', TRUE,
   'contato@bb.com.br', '1133334444', 'Banco', TRUE),
  (gen_random_uuid(), 'Tribunal de Justiça', '34028316000152', TRUE,
   'ti@tj.br', '1155556666', 'Justiça', TRUE),
  (gen_random_uuid(), 'Carro Forte Express', '12345678000199', TRUE,
   'operacoes@carroforte.com.br', '1177778888', 'Empresarial', TRUE)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 2. VEÍCULOS DE TESTE
-- ============================================================================
INSERT INTO veiculos (
  id, cliente_id, placa, tipo_id, marca, modelo,
  ano_fabricacao, ano_modelo, cor, ativo
)
SELECT
  gen_random_uuid(),
  (SELECT id FROM clientes LIMIT 1),
  'ABC-1001'::VARCHAR(10),
  2::SMALLINT, -- Blindado Médio
  'Chevrolet',
  'S10',
  2022,
  2022,
  'Branco',
  TRUE
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 3. ARMAMENTOS DE TESTE
-- ============================================================================
INSERT INTO armamentos (
  id, cliente_id, numero_serie, tipo, marca,
  calibre_id, municao_tipo, municao_quantidade, ativo
)
SELECT
  gen_random_uuid(),
  (SELECT id FROM clientes LIMIT 1),
  'ARQ-2024-001-001',
  'Pistola',
  'Taurus',
  2::SMALLINT, -- .40 S&W
  '.40 S&W',
  100,
  TRUE
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 4. VIGILANTES DE TESTE
-- ============================================================================
INSERT INTO vigilantes (
  id, nome, cpf, rg, data_nascimento,
  sexo, telefone, registro_seguranca,
  ativo, status_id
) VALUES
  (gen_random_uuid(), 'João da Silva Santos', '12345678900', 'MG123456', '1990-05-15',
   'M', '11999999999', 'RSO-2024-001', TRUE, 1),
  (gen_random_uuid(), 'Maria Oliveira Costa', '98765432100', 'SP654321', '1992-03-20',
   'F', '11988888888', 'RSO-2024-002', TRUE, 1),
  (gen_random_uuid(), 'Carlos Mendes Ferreira', '55555555555', 'RJ333333', '1988-11-10',
   'M', '11977777777', 'RSO-2024-003', TRUE, 1)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 5. ESQUERÇA DE TESTE (ESCOLTA)
-- ============================================================================
INSERT INTO escoltas (
  id, cliente_id, codigo, numero, tipo,
  descricao_servico, data_prevista, hora_saida_prevista,
  hora_retorno_prevista, local_saida, local_saida_lat,
  local_saida_lng, local_destino, local_destino_lat,
  local_destino_lng, status_id
)
SELECT
  gen_random_uuid(),
  (SELECT id FROM clientes LIMIT 1),
  'ESC-' || TO_CHAR(NOW(), 'YYYYMM') || '-' || LPAD(CAST(FLOOR(RANDOM() * 10000) AS INT)::TEXT, 5, '0'),
  1,
  'transporte',
  'Transporte de valores Banco',
  CURRENT_DATE + 1,
  '09:00'::TIME,
  '17:00'::TIME,
  'Agência Paulista',
  -23.550520::NUMERIC(10, 8),
  -46.633309::NUMERIC(11, 8),
  'Agência Centro',
  -23.547020::NUMERIC(10, 8),
  -46.643309::NUMERIC(11, 8),
  1::SMALLINT -- Planejada
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 6. REGISTRAR VEÍCULOS NA ESCOLTA
-- ============================================================================
INSERT INTO escolta_veiculos (
  id, escolta_id, veiculo_id, ordem, posicao, quilometragem_saida, ativo
)
SELECT
  gen_random_uuid(),
  (SELECT id FROM escoltas LIMIT 1),
  (SELECT id FROM veiculos LIMIT 1),
  1,
  'Frente',
  0,
  TRUE
ON CONFLICT (escolta_id, veiculo_id) DO NOTHING;

-- ============================================================================
-- 7. REGISTRAR EFETIVO NA ESCOLTA
-- ============================================================================
INSERT INTO escolta_efetivo (
  id, escolta_id, escolta_veiculo_id,
  vigilante_id, funcao_id, confirmado,
  valor_diaria, pago
)
SELECT
  gen_random_uuid(),
  e.id,
  ev.id,
  (SELECT id FROM vigilantes LIMIT 1),
  1::SMALLINT, -- Motorista
  FALSE,
  1500.00,
  FALSE
FROM escoltas e
JOIN escolta_veiculos ev ON e.id = ev.escolta_id
LIMIT 1
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 8. REGISTRAR ARMAMENTOS NA ESCOLTA
-- ============================================================================
INSERT INTO escolta_armamentos (
  id, escolta_id, escolta_efetivo_id, armamento_id,
  municao_retirada, municao_devolvida
)
SELECT
  gen_random_uuid(),
  e.id,
  ee.id,
  (SELECT id FROM armamentos LIMIT 1),
  20,
  20
FROM escoltas e
JOIN escolta_efetivo ee ON e.id = ee.escolta_id
LIMIT 1
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 9. MODELOS DE CHECKLIST
-- ============================================================================
INSERT INTO checklist_modelos (
  id, cliente_id, codigo, nome, tipo_id,
  obrigatorio, ativo, ordem
)
VALUES
  (gen_random_uuid(), (SELECT id FROM clientes LIMIT 1), 
   'CHKL-VEICULO', 'Checklist de Veículo', 1::SMALLINT, TRUE, TRUE, 1),
  (gen_random_uuid(), (SELECT id FROM clientes LIMIT 1),
   'CHKL-ARMAMENTO', 'Checklist de Armamento', 2::SMALLINT, TRUE, TRUE, 2)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 10. ITENS DE CHECKLIST
-- ============================================================================
INSERT INTO checklist_modelos_itens (
  id, modelo_id, ordem, texto, tipo_resposta, obrigatorio
)
SELECT
  gen_random_uuid(),
  (SELECT id FROM checklist_modelos WHERE codigo = 'CHKL-VEICULO' LIMIT 1),
  1,
  'Pneus em bom estado?',
  'boolean',
  TRUE
ON CONFLICT DO NOTHING;

INSERT INTO checklist_modelos_itens (
  id, modelo_id, ordem, texto, tipo_resposta, obrigatorio
)
SELECT
  gen_random_uuid(),
  (SELECT id FROM checklist_modelos WHERE codigo = 'CHKL-VEICULO' LIMIT 1),
  2,
  'Combustível acima de 75%?',
  'boolean',
  TRUE
ON CONFLICT DO NOTHING;

INSERT INTO checklist_modelos_itens (
  id, modelo_id, ordem, texto, tipo_resposta, obrigatorio
)
SELECT
  gen_random_uuid(),
  (SELECT id FROM checklist_modelos WHERE codigo = 'CHKL-VEICULO' LIMIT 1),
  3,
  'Documentação completa?',
  'boolean',
  TRUE
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 11. PONTOS DE CONTROLE DE TESTE
-- ============================================================================
INSERT INTO pontos_controle (
  id, escolta_id, tipo_ponto_id,
  latitude, longitude, altitude,
  hora_chegada, endereco_textual, confirmado
)
SELECT
  gen_random_uuid(),
  (SELECT id FROM escoltas LIMIT 1),
  1::SMALLINT, -- Saída
  -23.550520::NUMERIC(10, 8),
  -46.633309::NUMERIC(11, 8),
  700::NUMERIC(10, 2),
  NOW(),
  'Agência Paulista, São Paulo',
  FALSE
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 12. ESTATÍSTICAS
-- ============================================================================
SELECT 
  'DADOS INICIAIS CARREGADOS' as status,
  (SELECT COUNT(*) FROM clientes) as total_clientes,
  (SELECT COUNT(*) FROM veiculos) as total_veiculos,
  (SELECT COUNT(*) FROM armamentos) as total_armamentos,
  (SELECT COUNT(*) FROM vigilantes) as total_vigilantes,
  (SELECT COUNT(*) FROM escoltas) as total_escoltas,
  (SELECT COUNT(*) FROM escolta_efetivo) as total_efetivo,
  (SELECT COUNT(*) FROM checklist_modelos) as total_modelos_checklist,
  (SELECT COUNT(*) FROM pontos_controle) as total_pontos_controle;
