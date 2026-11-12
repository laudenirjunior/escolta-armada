-- Concorrência (2026-11-12), migration 223: última alteração da escolta para a mensagem de
-- conflito. RODA NA HOMOLOGAÇÃO (usuários QA e schema qa), com a 221, a 222 e a 223 aplicadas.
-- Esperado: só PASSOU e BLOQUEADO CORRETAMENTE. Cada bloco roda numa transação desfeita.
-- Não coberto aqui: operador fora do efetivo (recorte igual ao de escoltas_select; conferir à
-- mão com um segundo operador, esperado NULL).
\set QUIET on
\pset tuples_only on

-- Volta a ser postgres SEM usuário final (RESET ROLE não limpa as claims do JWT).
CREATE FUNCTION pg_temp.pg() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $$;

-- ── 1. Estrutura e privilégios ────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT has_function_privilege('anon', 'public.ultima_alteracao_escolta(uuid)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.ultima_alteracao_escolta(uuid)', 'EXECUTE') THEN
    RAISE NOTICE 'PASSOU: ultima_alteracao_escolta só para authenticated (anon sem EXECUTE)';
  ELSE RAISE NOTICE 'FALHOU: privilégios da ultima_alteracao_escolta'; END IF;
  IF (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc
       WHERE oid = 'public.ultima_alteracao_escolta(uuid)'::regprocedure) THEN
    RAISE NOTICE 'PASSOU: SECURITY DEFINER com search_path fixo';
  ELSE RAISE NOTICE 'FALHOU: função sem SECURITY DEFINER ou sem search_path'; END IF;
  IF NOT has_function_privilege('authenticated', 'lote_interno.texto_acao_escolta(text, jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'lote_interno.texto_mudanca_status(text, text, text, boolean)', 'EXECUTE') THEN
    RAISE NOTICE 'PASSOU: funções internas sem EXECUTE para authenticated';
  ELSE RAISE NOTICE 'FALHOU: função interna da 223 exposta'; END IF;
END $$;

-- ── 2. Avanço pelo campo: quem, o quê e quando, para a gestão e para o próprio autor ──
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 hour', 'agendada', 'qa_um', 1)::text, true);
SELECT qa.como('qa_um');
SELECT public.registrar_etapa_escolta(p_escolta_id => current_setting('t.esc')::uuid,
                                      p_status_atual => 'agendada', p_status_novo => 'em_pre_inicio');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; r jsonb; m text;
BEGIN
  r := public.ultima_alteracao_escolta(e);
  IF (r ->> 'eu')::boolean AND (r ->> 'fonte') = 'historico' THEN
    RAISE NOTICE 'PASSOU: o próprio autor vê eu = true';
  ELSE RAISE NOTICE 'FALHOU: autor: %', r; END IF;
  -- A segunda tentativa da mesma transição continua recusada com o texto de sempre.
  BEGIN
    PERFORM public.registrar_etapa_escolta(p_escolta_id => e, p_status_atual => 'agendada', p_status_novo => 'em_pre_inicio');
    RAISE NOTICE 'FALHOU: a transição repetida passou';
  EXCEPTION WHEN others THEN m := SQLERRM;
  END;
  IF m = 'ERRO_SEM_TRANSICAO' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: transição repetida, mensagem do banco inalterada (ERRO_SEM_TRANSICAO)';
  ELSIF m IS NOT NULL THEN RAISE NOTICE 'FALHOU: mensagem mudou: %', m; END IF;
END $$;
SELECT pg_temp.pg();
SELECT qa.como('qa_gestor');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; r jsonb;
BEGIN
  r := public.ultima_alteracao_escolta(e);
  IF (r ->> 'quem_id')::uuid = qa.usuario('qa_um') AND NOT (r ->> 'eu')::boolean
     AND (r ->> 'o_que') = 'etapa avançada para Pré-Início' AND (r ->> 'quando')::timestamptz > now() - interval '1 minute'
     AND (r ->> 'quem_nome') IS NOT NULL AND (r ->> 'perfil') IS NOT NULL AND (r ->> 'status') = 'em_pre_inicio' THEN
    RAISE NOTICE 'PASSOU: gestor vê quem (%, %), o quê e quando', r ->> 'quem_nome', r ->> 'perfil';
  ELSE RAISE NOTICE 'FALHOU: gestor: %', r; END IF;
END $$;
SELECT pg_temp.pg();
SELECT qa.como('qa_central');
DO $$
BEGIN
  IF public.ultima_alteracao_escolta(current_setting('t.esc')::uuid) ->> 'o_que' IS NOT NULL THEN
    RAISE NOTICE 'PASSOU: central lê a última alteração';
  ELSE RAISE NOTICE 'FALHOU: central sem leitura'; END IF;
END $$;
SELECT pg_temp.pg();
ROLLBACK;

-- ── 3. Ação da gestão: a auditoria vence o histórico da mesma transação ────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 hour', 'agendada', 'qa_um', 1)::text, true);
SELECT qa.como('qa_um');
SELECT public.registrar_etapa_escolta(p_escolta_id => current_setting('t.esc')::uuid,
                                      p_status_atual => 'agendada', p_status_novo => 'em_pre_inicio');
SELECT pg_temp.pg();
SELECT qa.como('qa_gestor');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; p jsonb; r jsonb; v_antes int;
BEGIN
  v_antes := (SELECT versao_gestao FROM public.escoltas WHERE id = e);
  p := public.voltar_etapa_escolta(e, NULL, true);
  PERFORM public.voltar_etapa_escolta(e, 'Teste de concorrência da 223', false, p -> 'resumo');
  r := public.ultima_alteracao_escolta(e);
  IF (r ->> 'fonte') = 'auditoria' AND (r ->> 'eu')::boolean AND (r ->> 'perfil_codigo') = 'gestor'
     AND ((r ->> 'o_que') LIKE 'etapa voltada para%' OR (r ->> 'o_que') = 'escolta zerada para Agendada')
     AND (r ->> 'versao_gestao')::int = v_antes + 1 THEN
    RAISE NOTICE 'PASSOU: voltar etapa aparece pela auditoria (%), versão %', r ->> 'o_que', r ->> 'versao_gestao';
  ELSE RAISE NOTICE 'FALHOU: depois de voltar etapa: %', r; END IF;
END $$;
SELECT pg_temp.pg();
ROLLBACK;

-- ── 4. Fora do alcance: sem perfil e escolta inexistente ──────────────────────────
BEGIN;
DO $$
BEGIN
  BEGIN
    PERFORM public.ultima_alteracao_escolta(gen_random_uuid());
    RAISE NOTICE 'FALHOU: sem usuário final leu a função';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: sem perfil ativo, Permissão negada';
  END;
END $$;
SELECT qa.como('qa_supervisor');
DO $$
BEGIN
  IF public.ultima_alteracao_escolta(gen_random_uuid()) IS NULL THEN
    RAISE NOTICE 'PASSOU: escolta inexistente devolve NULL (sem erro)';
  ELSE RAISE NOTICE 'FALHOU: escolta inexistente devolveu algo'; END IF;
END $$;
SELECT pg_temp.pg();
ROLLBACK;
