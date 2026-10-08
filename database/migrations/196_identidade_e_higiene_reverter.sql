-- 196_identidade_e_higiene_reverter.sql
-- Reverte a 196 para o estado de produção de 08/10/2026 (corpos da 195 e ACLs do dump).

CREATE OR REPLACE FUNCTION public.perfil_usuario_atual() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT p.codigo
  FROM public.usuarios u
  JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.auth_user_id = auth.uid()
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.sou_do_efetivo(p_escolta_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.escolta_efetivo ee
    JOIN public.vigilantes v ON v.id = ee.vigilante_id
    JOIN public.usuarios u   ON u.id = v.usuario_id
    WHERE ee.escolta_id = p_escolta_id
      AND u.auth_user_id = auth.uid()
  );
$$;

ALTER FUNCTION public.cadastrar_operador(text, text, text, text, text, uuid, text, text, numeric, text)
  SET search_path TO 'public', 'auth', 'extensions';
ALTER FUNCTION public.criar_usuario_completo(text, text, text, uuid, text, text)
  SET search_path TO 'public', 'auth', 'extensions';
ALTER FUNCTION public.excluir_auth_usuario(uuid)
  SET search_path TO 'public';

-- ACLs das funções de trigger e da view, como estavam no dump de produção.
REVOKE ALL ON FUNCTION public.exigir_ponto_transito_retorno() FROM PUBLIC;
GRANT ALL ON FUNCTION public.exigir_ponto_transito_retorno() TO service_role;
REVOKE ALL ON FUNCTION public.garantir_vinculo_operador() FROM PUBLIC;
GRANT ALL ON FUNCTION public.garantir_vinculo_operador() TO authenticated;
GRANT ALL ON FUNCTION public.garantir_vinculo_operador() TO service_role;
GRANT ALL ON FUNCTION public.gerar_codigo_escolta() TO anon;
GRANT ALL ON FUNCTION public.gerar_codigo_escolta() TO authenticated;
GRANT ALL ON FUNCTION public.gerar_codigo_escolta() TO service_role;
REVOKE ALL ON FUNCTION public.impedir_autopromocao() FROM PUBLIC;
GRANT ALL ON FUNCTION public.impedir_autopromocao() TO service_role;
REVOKE ALL ON FUNCTION public.impedir_criacao_perfil_superior() FROM PUBLIC;
GRANT ALL ON FUNCTION public.impedir_criacao_perfil_superior() TO service_role;
GRANT ALL ON FUNCTION public.impedir_edicao_por_operador() TO anon;
GRANT ALL ON FUNCTION public.impedir_edicao_por_operador() TO authenticated;
GRANT ALL ON FUNCTION public.impedir_edicao_por_operador() TO service_role;
REVOKE ALL ON FUNCTION public.registrar_historico_status_escolta() FROM PUBLIC;
GRANT ALL ON FUNCTION public.registrar_historico_status_escolta() TO service_role;
GRANT ALL ON FUNCTION public.sync_auth_user_on_usuarios() TO anon;
GRANT ALL ON FUNCTION public.sync_auth_user_on_usuarios() TO authenticated;
GRANT ALL ON FUNCTION public.sync_auth_user_on_usuarios() TO service_role;
GRANT ALL ON FUNCTION public.update_atualizado_em() TO anon;
GRANT ALL ON FUNCTION public.update_atualizado_em() TO authenticated;
GRANT ALL ON FUNCTION public.update_atualizado_em() TO service_role;
GRANT ALL ON FUNCTION public.validar_transicao_status_escolta() TO anon;
GRANT ALL ON FUNCTION public.validar_transicao_status_escolta() TO authenticated;
GRANT ALL ON FUNCTION public.validar_transicao_status_escolta() TO service_role;
GRANT ALL ON FUNCTION public.verificar_checklist_pendente() TO anon;
GRANT ALL ON FUNCTION public.verificar_checklist_pendente() TO authenticated;
GRANT ALL ON FUNCTION public.verificar_checklist_pendente() TO service_role;
REVOKE ALL ON FUNCTION public.vincular_vigilante_a_usuario() FROM PUBLIC;
GRANT ALL ON FUNCTION public.vincular_vigilante_a_usuario() TO authenticated;
GRANT ALL ON FUNCTION public.vincular_vigilante_a_usuario() TO service_role;
GRANT EXECUTE ON FUNCTION public.gerar_codigo_escolta() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_auth_user_on_usuarios() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_atualizado_em() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.validar_transicao_status_escolta() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.verificar_checklist_pendente() TO PUBLIC;
GRANT ALL ON TABLE public.vw_operador_sem_vinculo TO anon;
GRANT ALL ON TABLE public.vw_operador_sem_vinculo TO authenticated;
GRANT ALL ON TABLE public.vw_operador_sem_vinculo TO service_role;
GRANT EXECUTE ON FUNCTION public.impedir_edicao_por_operador() TO PUBLIC;
