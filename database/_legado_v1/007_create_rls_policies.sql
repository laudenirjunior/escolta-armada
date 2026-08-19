-- Escolta Armada: Políticas de RLS (Row Level Security)
-- Controle de acesso baseado em linha - Supabase Auth

-- Habilitar RLS em todas as tabelas operacionais
ALTER TABLE usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE vigilantes ENABLE ROW LEVEL SECURITY;
ALTER TABLE clientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE veiculos ENABLE ROW LEVEL SECURITY;
ALTER TABLE armamentos ENABLE ROW LEVEL SECURITY;
ALTER TABLE escoltas ENABLE ROW LEVEL SECURITY;
ALTER TABLE escolta_veiculos ENABLE ROW LEVEL SECURITY;
ALTER TABLE escolta_efetivo ENABLE ROW LEVEL SECURITY;
ALTER TABLE escolta_armamentos ENABLE ROW LEVEL SECURITY;
ALTER TABLE pontos_controle ENABLE ROW LEVEL SECURITY;
ALTER TABLE rastreamento ENABLE ROW LEVEL SECURITY;
ALTER TABLE presencas ENABLE ROW LEVEL SECURITY;
ALTER TABLE fotos ENABLE ROW LEVEL SECURITY;
ALTER TABLE fotos_storage ENABLE ROW LEVEL SECURITY;
ALTER TABLE checklist_modelos ENABLE ROW LEVEL SECURITY;
ALTER TABLE checklist_modelos_itens ENABLE ROW LEVEL SECURITY;
ALTER TABLE checklists ENABLE ROW LEVEL SECURITY;
ALTER TABLE checklist_respostas ENABLE ROW LEVEL SECURITY;
ALTER TABLE atualizacoes_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE ocorrencias ENABLE ROW LEVEL SECURITY;
ALTER TABLE emergencias ENABLE ROW LEVEL SECURITY;
ALTER TABLE logs_auditoria ENABLE ROW LEVEL SECURITY;
ALTER TABLE escolta_status_historico ENABLE ROW LEVEL SECURITY;
ALTER TABLE notificacoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE sincronizacao ENABLE ROW LEVEL SECURITY;
ALTER TABLE configuracoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessoes_usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE tentativas_login ENABLE ROW LEVEL SECURITY;

-- Função auxiliar: obter usuário atual
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID
LANGUAGE SQL STABLE AS $$
  SELECT auth.uid()
$$;

-- Função auxiliar: obter cliente do usuário
CREATE OR REPLACE FUNCTION obter_cliente_usuario()
RETURNS UUID
LANGUAGE SQL STABLE AS $$
  SELECT cliente_id FROM usuarios WHERE auth_id = auth.uid()
$$;

-- Função auxiliar: obter perfil do usuário
CREATE OR REPLACE FUNCTION obter_perfil_usuario()
RETURNS SMALLINT
LANGUAGE SQL STABLE AS $$
  SELECT perfil_id FROM usuarios WHERE auth_id = auth.uid()
$$;

-- Função auxiliar: é admin?
CREATE OR REPLACE FUNCTION eh_admin()
RETURNS BOOLEAN
LANGUAGE SQL STABLE AS $$
  SELECT (obter_perfil_usuario() = 5)
$$;

-- Função auxiliar: é gestor?
CREATE OR REPLACE FUNCTION eh_gestor()
RETURNS BOOLEAN
LANGUAGE SQL STABLE AS $$
  SELECT (obter_perfil_usuario() IN (4, 5))
$$;

-- Função auxiliar: é supervisor?
CREATE OR REPLACE FUNCTION eh_supervisor()
RETURNS BOOLEAN
LANGUAGE SQL STABLE AS $$
  SELECT (obter_perfil_usuario() IN (3, 4, 5))
$$;

-- ============================================================================
-- POLÍTICAS DE ACESSO
-- ============================================================================

-- USUARIOS
-- Usuários podem ler seus próprios dados
CREATE POLICY "Usuários podem ler dados próprios" ON usuarios
  FOR SELECT USING (auth_id = auth.uid() OR eh_admin());

-- Gestores/Admins podem ler todos os usuários do seu cliente
CREATE POLICY "Gestores podem ler usuários do seu cliente" ON usuarios
  FOR SELECT USING (
    eh_gestor() AND cliente_id = obter_cliente_usuario()
  );

-- Usuários podem atualizar seus próprios dados
CREATE POLICY "Usuários podem atualizar dados próprios" ON usuarios
  FOR UPDATE USING (auth_id = auth.uid())
  WITH CHECK (auth_id = auth.uid());

-- Gestores/Admins podem atualizar usuários
CREATE POLICY "Gestores podem atualizar usuários do seu cliente" ON usuarios
  FOR UPDATE USING (
    eh_gestor() AND cliente_id = obter_cliente_usuario()
  );

-- Apenas admins podem inserir usuários
CREATE POLICY "Apenas admins podem criar usuários" ON usuarios
  FOR INSERT WITH CHECK (eh_admin());

-- VIGILANTES
-- Operadores podem ler vigilantes do seu cliente
CREATE POLICY "Usuarios podem ler vigilantes do seu cliente" ON vigilantes
  FOR SELECT USING (
    obter_cliente_usuario() IN (
      SELECT cliente_id FROM veiculos WHERE id IN (
        SELECT veiculo_id FROM escolta_veiculos WHERE escolta_id IN (
          SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
        )
      )
    ) OR eh_gestor()
  );

-- Gestores/Admins podem gerenciar vigilantes
CREATE POLICY "Gestores podem gerenciar vigilantes" ON vigilantes
  FOR ALL USING (eh_gestor())
  WITH CHECK (eh_gestor());

-- CLIENTES
-- Usuários podem ler seu próprio cliente
CREATE POLICY "Usuarios podem ler seu cliente" ON clientes
  FOR SELECT USING (
    id = obter_cliente_usuario() OR eh_admin()
  );

-- Gestores/Admins podem gerenciar seus clientes
CREATE POLICY "Gestores podem gerenciar seus clientes" ON clientes
  FOR ALL USING (
    id = obter_cliente_usuario() OR eh_admin()
  )
  WITH CHECK (id = obter_cliente_usuario() OR eh_admin());

-- VEÍCULOS
-- Usuários podem ler veículos de sua escolta
CREATE POLICY "Usuarios podem ler veiculos de sua escolta" ON veiculos
  FOR SELECT USING (
    cliente_id = obter_cliente_usuario() OR
    id IN (SELECT veiculo_id FROM escolta_veiculos WHERE escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    ))
  );

-- Gestores podem gerenciar veículos
CREATE POLICY "Gestores podem gerenciar veiculos" ON veiculos
  FOR ALL USING (cliente_id = obter_cliente_usuario() AND eh_gestor())
  WITH CHECK (cliente_id = obter_cliente_usuario() AND eh_gestor());

-- ARMAMENTOS
-- Usuários podem ler armamentos de sua escolta
CREATE POLICY "Usuarios podem ler armamentos de sua escolta" ON armamentos
  FOR SELECT USING (
    cliente_id = obter_cliente_usuario() OR
    id IN (SELECT armamento_id FROM escolta_armamentos WHERE escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    ))
  );

-- Gestores podem gerenciar armamentos
CREATE POLICY "Gestores podem gerenciar armamentos" ON armamentos
  FOR ALL USING (cliente_id = obter_cliente_usuario() AND eh_gestor())
  WITH CHECK (cliente_id = obter_cliente_usuario() AND eh_gestor());

-- ESCOLTAS
-- Usuários podem ler escoltas de seu cliente
CREATE POLICY "Usuarios podem ler escoltas de seu cliente" ON escoltas
  FOR SELECT USING (
    cliente_id = obter_cliente_usuario() OR
    responsavel_id = (SELECT id FROM usuarios WHERE auth_id = auth.uid())
  );

-- Usuários podem atualizar escoltas (mas não mudar cliente)
CREATE POLICY "Usuarios podem atualizar escoltas" ON escoltas
  FOR UPDATE USING (
    cliente_id = obter_cliente_usuario()
  )
  WITH CHECK (cliente_id = obter_cliente_usuario());

-- Gestores/Supervisores podem inserir escoltas
CREATE POLICY "Gestores podem criar escoltas" ON escoltas
  FOR INSERT WITH CHECK (
    cliente_id = obter_cliente_usuario() AND eh_gestor()
  );

-- ESCOLTA_VEICULOS
CREATE POLICY "Usuarios podem ler veiculos de escolta" ON escolta_veiculos
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Gestores podem gerenciar veiculos de escolta" ON escolta_veiculos
  FOR ALL USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    ) AND eh_gestor()
  );

-- ESCOLTA_EFETIVO
CREATE POLICY "Usuarios podem ler efetivo de escolta" ON escolta_efetivo
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Gestores podem gerenciar efetivo de escolta" ON escolta_efetivo
  FOR ALL USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    ) AND eh_gestor()
  );

-- ESCOLTA_ARMAMENTOS
CREATE POLICY "Usuarios podem ler armamentos de escolta" ON escolta_armamentos
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Gestores podem gerenciar armamentos de escolta" ON escolta_armamentos
  FOR ALL USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    ) AND eh_gestor()
  );

-- PONTOS_CONTROLE
CREATE POLICY "Usuarios podem ler pontos de controle" ON pontos_controle
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Usuarios podem inserir pontos de controle" ON pontos_controle
  FOR INSERT WITH CHECK (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

-- RASTREAMENTO
CREATE POLICY "Usuarios podem ler rastreamento" ON rastreamento
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Usuarios podem inserir rastreamento" ON rastreamento
  FOR INSERT WITH CHECK (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

-- PRESENCAS
CREATE POLICY "Usuarios podem ler presencas" ON presencas
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Usuarios podem registrar presenca" ON presencas
  FOR INSERT WITH CHECK (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

-- FOTOS
CREATE POLICY "Usuarios podem ler fotos" ON fotos
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Usuarios podem fazer upload de foto" ON fotos
  FOR INSERT WITH CHECK (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

-- FOTOS_STORAGE
CREATE POLICY "Usuarios podem ler fotos storage" ON fotos_storage
  FOR SELECT USING (
    foto_id IN (
      SELECT id FROM fotos WHERE escolta_id IN (
        SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
      )
    )
  );

-- CHECKLISTS
CREATE POLICY "Usuarios podem ler checklists" ON checklists
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Usuarios podem executar checklist" ON checklists
  FOR INSERT WITH CHECK (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Usuarios podem atualizar checklist" ON checklists
  FOR UPDATE USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

-- CHECKLIST_RESPOSTAS
CREATE POLICY "Usuarios podem ler respostas" ON checklist_respostas
  FOR SELECT USING (
    checklist_id IN (
      SELECT id FROM checklists WHERE escolta_id IN (
        SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
      )
    )
  );

CREATE POLICY "Usuarios podem responder checklist" ON checklist_respostas
  FOR INSERT WITH CHECK (
    checklist_id IN (
      SELECT id FROM checklists WHERE escolta_id IN (
        SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
      )
    )
  );

-- ATUALIZACOES_STATUS
CREATE POLICY "Usuarios podem ler atualizacoes" ON atualizacoes_status
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Usuarios podem registrar atualizacoes" ON atualizacoes_status
  FOR INSERT WITH CHECK (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

-- OCORRÊNCIAS
CREATE POLICY "Usuarios podem ler ocorrencias" ON ocorrencias
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Usuarios podem reportar ocorrencia" ON ocorrencias
  FOR INSERT WITH CHECK (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

-- EMERGÊNCIAS
CREATE POLICY "Usuarios podem ler emergencias" ON emergencias
  FOR SELECT USING (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

CREATE POLICY "Usuarios podem acionar emergencia" ON emergencias
  FOR INSERT WITH CHECK (
    escolta_id IN (
      SELECT id FROM escoltas WHERE cliente_id = obter_cliente_usuario()
    )
  );

-- LOGS_AUDITORIA
-- Apenas o usuário em questão ou admins podem ler
CREATE POLICY "Usuarios podem ler seus logs" ON logs_auditoria
  FOR SELECT USING (
    usuario_id = (SELECT id FROM usuarios WHERE auth_id = auth.uid()) OR eh_admin()
  );

-- NOTIFICAÇÕES
-- Apenas o destinatário ou admin pode ler
CREATE POLICY "Usuarios podem ler suas notificacoes" ON notificacoes
  FOR SELECT USING (
    usuario_id = (SELECT id FROM usuarios WHERE auth_id = auth.uid()) OR eh_admin()
  );

-- SINCRONIZAÇÃO
-- Apenas o usuário pode ler/gerenciar
CREATE POLICY "Usuarios podem ler sua sincronizacao" ON sincronizacao
  FOR SELECT USING (
    usuario_id = (SELECT id FROM usuarios WHERE auth_id = auth.uid()) OR eh_admin()
  );

-- CONFIGURAÇÕES
-- Públicas podem ser lidas por todos
CREATE POLICY "Todos podem ler configuracoes publicas" ON configuracoes
  FOR SELECT USING (publica = TRUE);

-- Privadas apenas pelo admin
CREATE POLICY "Admin pode ler todas as configuracoes" ON configuracoes
  FOR SELECT USING (eh_admin());

-- SESSÕES DE USUÁRIO
-- Apenas o próprio usuário pode ler
CREATE POLICY "Usuarios podem ler suas sessoes" ON sessoes_usuarios
  FOR SELECT USING (
    usuario_id = (SELECT id FROM usuarios WHERE auth_id = auth.uid()) OR eh_admin()
  );

-- ============================================================================
-- TRIGGERS PARA AUDITORIA
-- ============================================================================

-- Função para registrar mudanças em logs_auditoria
CREATE OR REPLACE FUNCTION auditoria_trigger()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO logs_auditoria (
    usuario_id, tabela_afetada, id_registro, operacao,
    dados_anterior, dados_novo, campos_alterados
  ) VALUES (
    (SELECT id FROM usuarios WHERE auth_id = auth.uid()),
    TG_TABLE_NAME,
    CASE
      WHEN TG_OP = 'DELETE' THEN OLD.id
      ELSE NEW.id
    END,
    TG_OP,
    CASE WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD) ELSE NULL END,
    CASE WHEN TG_OP != 'DELETE' THEN row_to_json(NEW) ELSE NULL END,
    CASE WHEN TG_OP = 'UPDATE' THEN
      ARRAY(
        SELECT key FROM jsonb_each(row_to_json(NEW)::jsonb)
        WHERE row_to_json(NEW)::jsonb -> key IS DISTINCT FROM row_to_json(OLD)::jsonb -> key
      )
    ELSE NULL END
  );
  
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$ LANGUAGE plpgsql;

-- Criar triggers de auditoria para tabelas críticas
CREATE TRIGGER audit_usuarios AFTER INSERT OR UPDATE OR DELETE ON usuarios
  FOR EACH ROW EXECUTE FUNCTION auditoria_trigger();

CREATE TRIGGER audit_escoltas AFTER INSERT OR UPDATE OR DELETE ON escoltas
  FOR EACH ROW EXECUTE FUNCTION auditoria_trigger();

CREATE TRIGGER audit_escolta_efetivo AFTER INSERT OR UPDATE OR DELETE ON escolta_efetivo
  FOR EACH ROW EXECUTE FUNCTION auditoria_trigger();

CREATE TRIGGER audit_ocorrencias AFTER INSERT OR UPDATE OR DELETE ON ocorrencias
  FOR EACH ROW EXECUTE FUNCTION auditoria_trigger();

CREATE TRIGGER audit_emergencias AFTER INSERT OR UPDATE OR DELETE ON emergencias
  FOR EACH ROW EXECUTE FUNCTION auditoria_trigger();
