-- 196_identidade_e_higiene.sql
-- Lote 2026-10, onda A (segurança). Idempotente. Aplicar ANTES do deploy da onda A.
--
-- Por quê:
-- 1. Bloquear usuário não cortava o acesso (docs/13, H1). get_meu_perfil já exigia
--    status = 'ativo', mas perfil_usuario_atual (usada por cadastrar_operador e
--    criar_usuario_por_login) e sou_do_efetivo (usada por quase toda a RLS de campo)
--    não. Um operador bloqueado continuava lendo e gravando nas escoltas dele, e um
--    gestor bloqueado continuava criando contas.
-- 2. Quatro funções SECURITY DEFINER sem pg_temp no search_path (B2), contra a regra
--    de database/migrations/README.md.
-- 3. Funções de trigger com EXECUTE para PUBLIC e uma com GRANT a anon (B1). Trigger
--    dispara sem depender de EXECUTE de quem faz o UPDATE; o grant só abre superfície.
-- 4. vw_operador_sem_vinculo legível por anon e authenticated (B3); a outra view de
--    conferência (vw_historico_divergente) já é só service_role.

CREATE OR REPLACE FUNCTION public.perfil_usuario_atual() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT p.codigo
  FROM public.usuarios u
  JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.auth_user_id = auth.uid()
    AND u.status = 'ativo'
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
      AND u.status = 'ativo'
  );
$$;
-- sou_do_efetivo_veiculo delega a sou_do_efetivo e herda a regra sem alteração.

ALTER FUNCTION public.cadastrar_operador(text, text, text, text, text, uuid, text, text, numeric, text)
  SET search_path TO 'public', 'auth', 'extensions', 'pg_temp';
ALTER FUNCTION public.criar_usuario_completo(text, text, text, uuid, text, text)
  SET search_path TO 'public', 'auth', 'extensions', 'pg_temp';
ALTER FUNCTION public.excluir_auth_usuario(uuid)
  SET search_path TO 'public', 'pg_temp';

-- Funções de trigger: ninguém precisa chamá-las diretamente.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS f
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prorettype = 'trigger'::regtype
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.f);
  END LOOP;
END $$;

REVOKE ALL ON public.vw_operador_sem_vinculo FROM anon, authenticated;

-- Conferência (esperado: 0 linhas em cada):
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE nspname='public' AND prosecdef AND has_function_privilege('anon', p.oid, 'EXECUTE');
-- SELECT proname FROM pg_proc WHERE proname IN ('perfil_usuario_atual','sou_do_efetivo')
--  AND pg_get_functiondef(oid) NOT LIKE '%status = ''ativo''%';
