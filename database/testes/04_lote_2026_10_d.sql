-- Lote 2026-10, onda D (M2): locais salvos, permissões e conferência.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa). Esperado: só PASSOU e BLOQUEADO CORRETAMENTE.
\set QUIET on
\pset tuples_only on

BEGIN;
SELECT qa.como('qa_um');
DO $$
DECLARE n int;
BEGIN
  BEGIN
    INSERT INTO public.locais_salvos (nome, endereco, latitude, longitude) VALUES ('QA operador', 'Rua X', -22.9, -43.3);
    RAISE NOTICE 'FALHOU: operador cadastrou local';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador nao cadastra local';
  END;
  SELECT count(*) INTO n FROM public.locais_salvos WHERE situacao <> 'ativo';
  IF n = 0 THEN RAISE NOTICE 'PASSOU: operador so ve locais ativos';
  ELSE RAISE NOTICE 'FALHOU: operador ve % locais nao ativos', n; END IF;
END $$;
ROLLBACK;

BEGIN;
SELECT qa.como('qa_supervisor');
DO $$
DECLARE v_id uuid; v_sit text;
BEGIN
  INSERT INTO public.locais_salvos (nome, endereco, latitude, longitude, situacao)
  VALUES ('QA supervisor', 'Rua Y', -22.9, -43.3, 'ativo') RETURNING id, situacao INTO v_id, v_sit;
  IF v_sit = 'aguardando_conferencia' THEN RAISE NOTICE 'PASSOU: local novo nasce aguardando conferencia mesmo pedindo ativo';
  ELSE RAISE NOTICE 'FALHOU: local novo nasceu %', v_sit; END IF;
  BEGIN
    UPDATE public.locais_salvos SET situacao = 'ativo' WHERE id = v_id;
    RAISE NOTICE 'FALHOU: supervisor ativou local';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: supervisor nao ativa local';
  END;
  PERFORM set_config('t.local', v_id::text, true);
END $$;
RESET ROLE;
SELECT qa.como('qa_gestor');
DO $$
DECLARE r record;
BEGIN
  UPDATE public.locais_salvos SET situacao = 'ativo' WHERE id = current_setting('t.local')::uuid;
  SELECT situacao, conferido_por, conferido_em INTO r FROM public.locais_salvos WHERE id = current_setting('t.local')::uuid;
  IF r.situacao = 'ativo' AND r.conferido_por = public.get_meu_usuario_id() AND r.conferido_em IS NOT NULL
  THEN RAISE NOTICE 'PASSOU: gestor ativa e fica registrado quem conferiu';
  ELSE RAISE NOTICE 'FALHOU: ativacao %', r.situacao; END IF;
  UPDATE public.locais_salvos SET latitude = -22.95 WHERE id = current_setting('t.local')::uuid;
  SELECT situacao INTO r FROM public.locais_salvos WHERE id = current_setting('t.local')::uuid;
  IF r.situacao = 'aguardando_conferencia' THEN RAISE NOTICE 'PASSOU: mudar a coordenada de local ativo exige nova conferencia';
  ELSE RAISE NOTICE 'FALHOU: local continuou %', r.situacao; END IF;
  BEGIN
    UPDATE public.locais_salvos SET situacao = 'ativo', latitude = NULL WHERE id = current_setting('t.local')::uuid;
    RAISE NOTICE 'FALHOU: ativou local sem coordenada';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: local ativo sem coordenada';
  END;
END $$;
ROLLBACK;
