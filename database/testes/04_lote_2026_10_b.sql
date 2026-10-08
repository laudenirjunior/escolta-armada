-- Lote 2026-10, onda B (M4): check-in desligado e dispensa de aviso por usuário.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa). Esperado: só PASSOU e BLOQUEADO CORRETAMENTE.
\set QUIET on
\pset tuples_only on

-- Depois da 201, nenhuma escolta aberta tem periodicidade.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.escoltas WHERE status NOT IN ('finalizada','cancelada') AND periodicidade_checkin_min IS NOT NULL;
  IF n = 0 THEN RAISE NOTICE 'PASSOU: nenhuma escolta aberta com periodicidade';
  ELSE RAISE NOTICE 'FALHOU: % escoltas abertas com periodicidade', n; END IF;
END $$;

-- Cada usuário só grava e lê a própria dispensa.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um', 1, 10)::text, true);
INSERT INTO public.alertas_dispensados (usuario_id, escolta_id, tipo, assinatura)
SELECT id, current_setting('t.esc')::uuid, 'checkin', 'x' FROM public.usuarios WHERE metadados->>'login' = 'qa_supervisor';
SELECT qa.como('qa_um');
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.alertas_dispensados;
  IF n = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador nao le dispensa de outro usuario';
  ELSE RAISE NOTICE 'FALHOU: operador leu % dispensas de outro usuario', n; END IF;
  BEGIN
    INSERT INTO public.alertas_dispensados (usuario_id, escolta_id, tipo, assinatura)
    SELECT id, current_setting('t.esc')::uuid, 'checkin', 'y' FROM public.usuarios WHERE metadados->>'login' = 'qa_dois';
    RAISE NOTICE 'FALHOU: operador gravou dispensa em nome de outro usuario';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: dispensa em nome de outro usuario';
  END;
  INSERT INTO public.alertas_dispensados (usuario_id, escolta_id, tipo, assinatura)
  VALUES (public.get_meu_usuario_id(), current_setting('t.esc')::uuid, 'checkin', 'z');
  RAISE NOTICE 'PASSOU: operador grava a propria dispensa';
END $$;
ROLLBACK;
