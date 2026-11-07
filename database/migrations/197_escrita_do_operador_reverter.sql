-- 197_escrita_do_operador_reverter.sql
-- Reverte a 197: corpos de produção de 08/10/2026 (migration 195) e policies originais.
-- Não mexe em ACL de função (a 196 cuida disso).

CREATE OR REPLACE FUNCTION public.impedir_edicao_por_operador() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text;
BEGIN
  -- Sem sessao de usuario final: SQL direto, migration ou service role. Passa, como nas
  -- demais funcoes deste banco, por ser a via de reparo.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil = ANY (ARRAY['administrador','gestor','supervisor','central']) THEN
    RETURN NEW;
  END IF;

  -- Daqui para baixo e operador ou vigilante. Ele so pode mover a escolta pelo fluxo:
  -- status, e os carimbos que o proprio avanco preenche.
  IF NEW.cliente_id          IS DISTINCT FROM OLD.cliente_id
     OR NEW.data_hora_prevista IS DISTINCT FROM OLD.data_hora_prevista
     OR NEW.origem_endereco  IS DISTINCT FROM OLD.origem_endereco
     OR NEW.origem_lat       IS DISTINCT FROM OLD.origem_lat
     OR NEW.origem_lng       IS DISTINCT FROM OLD.origem_lng
     OR NEW.destino_endereco IS DISTINCT FROM OLD.destino_endereco
     OR NEW.destino_lat      IS DISTINCT FROM OLD.destino_lat
     OR NEW.destino_lng      IS DISTINCT FROM OLD.destino_lng
  THEN
    RAISE EXCEPTION 'Operador nao edita dados da escolta. Fale com o supervisor para alterar cliente, data ou local.';
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.impedir_autopromocao() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil      text;
  v_eu          uuid;
  v_cod_novo    text;
  v_cod_antigo  text;
BEGIN
  v_eu := auth.uid();

  -- Sem sessao de usuario final: SQL direto, migration ou service role.
  -- Passa de proposito, e o unico caminho de reparo do banco. O controle
  -- desse caminho e a reconciliacao detectiva, nao esta trigger.
  IF v_eu IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT public.get_meu_perfil() INTO v_perfil;

  -- O vinculo com auth.users nunca muda pela API: trocar auth_user_id
  -- e sequestro de conta, nao edicao de cadastro.
  IF NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
    RAISE EXCEPTION 'O vinculo de autenticacao nao pode ser alterado pela aplicacao.';
  END IF;

  -- 1. Ninguem mexe no proprio perfil nem no proprio status, nem administrador.
  --    Confere OLD e NEW para o caso de a linha ser reapontada na mesma instrucao.
  IF OLD.auth_user_id = v_eu OR NEW.auth_user_id = v_eu THEN
    IF NEW.perfil_id IS DISTINCT FROM OLD.perfil_id THEN
      RAISE EXCEPTION 'Voce nao pode alterar o proprio perfil de acesso.';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'Voce nao pode alterar o proprio status.';
    END IF;
    RETURN NEW;
  END IF;

  -- 2. Mexer no perfil de terceiro exige perfil de gestao.
  IF NEW.perfil_id IS DISTINCT FROM OLD.perfil_id THEN
    IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor') THEN
      RAISE EXCEPTION 'Permissao negada para alterar perfil de acesso.';
    END IF;

    SELECT codigo INTO v_cod_novo   FROM public.dom_perfis WHERE id = NEW.perfil_id;
    SELECT codigo INTO v_cod_antigo FROM public.dom_perfis WHERE id = OLD.perfil_id;

    -- 3. Conceder ou retirar 'administrador' e privativo de administrador.
    --    Sem isto, o gestor promove um comparsa em vez de a si mesmo.
    IF v_perfil <> 'administrador'
       AND 'administrador' IN (coalesce(v_cod_novo, ''), coalesce(v_cod_antigo, '')) THEN
      RAISE EXCEPTION 'Somente um administrador concede ou remove o perfil administrador.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.redefinir_senha_usuario(p_usuario_id uuid, p_nova_senha text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions', 'pg_temp'
    AS $$
DECLARE
  v_caller_perfil TEXT;
  v_alvo_perfil   TEXT;
BEGIN
  -- Perfil de quem chama
  SELECT p.codigo INTO v_caller_perfil
  FROM public.usuarios u
  INNER JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.auth_user_id = auth.uid()
    AND u.status = 'ativo';

  IF v_caller_perfil IS NULL OR v_caller_perfil NOT IN ('administrador', 'gestor') THEN
    RAISE EXCEPTION 'Permissão negada. Apenas administradores e gestores podem redefinir senhas.';
  END IF;

  -- Perfil do alvo. p_usuario_id e o auth_user_id do alvo.
  SELECT p.codigo INTO v_alvo_perfil
  FROM public.usuarios u
  INNER JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.auth_user_id = p_usuario_id;

  IF v_alvo_perfil IS NULL THEN
    RAISE EXCEPTION 'Usuário alvo não encontrado.';
  END IF;

  -- Somente administrador redefine a senha de um administrador.
  IF v_alvo_perfil = 'administrador' AND v_caller_perfil <> 'administrador' THEN
    RAISE EXCEPTION 'Permissão negada. Apenas um administrador pode redefinir a senha de outro administrador.';
  END IF;

  IF length(p_nova_senha) < 6 THEN
    RAISE EXCEPTION 'A senha deve ter pelo menos 6 caracteres.';
  END IF;

  UPDATE auth.users
  SET encrypted_password = crypt(p_nova_senha, gen_salt('bf')),
      updated_at = now()
  WHERE id = p_usuario_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuário não encontrado na autenticação.';
  END IF;

  UPDATE public.usuarios
  SET troca_senha_obrigatoria = true,
      atualizado_em = now()
  WHERE auth_user_id = p_usuario_id;
END;
$$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['emergencias','presencas','rastreamento','atualizacoes_status',
                           'checklists','checklist_respostas','escolta_veiculos']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_delete_so_gestao', t);
  END LOOP;
END $$;
DROP POLICY IF EXISTS notificacoes_insert_so_gestao ON public.notificacoes;
DROP POLICY IF EXISTS notificacoes_update_restrita ON public.notificacoes;
DROP POLICY IF EXISTS logs_auditoria_insert ON public.logs_auditoria;
CREATE POLICY logs_auditoria_insert ON public.logs_auditoria FOR INSERT TO authenticated WITH CHECK (true);
