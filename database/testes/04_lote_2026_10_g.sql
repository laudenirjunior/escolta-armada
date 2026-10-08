-- Lote 2026-10, onda G (escolta com dois vigilantes): índices únicos da migration 210.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa). Esperado: só PASSOU e BLOQUEADO CORRETAMENTE.
\set QUIET on
\pset tuples_only on
BEGIN;
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_indexes WHERE schemaname = 'public'
   AND indexname IN ('escolta_efetivo_escolta_vigilante_uk', 'escolta_veiculos_escolta_veiculo_uk')
   AND indexdef LIKE 'CREATE UNIQUE INDEX%';
  IF n = 2 THEN RAISE NOTICE 'PASSOU: os dois índices únicos da 210 existem';
  ELSE RAISE NOTICE 'FALHOU: % de 2 índices únicos da 210', n; END IF;
END $$;
-- Duas escoltas agendadas, duas viaturas cada, qa_um comandante na primeira viatura da E1.
SELECT set_config('t.e1', qa.nova_escolta(now() + interval '2 days', 'agendada', 'qa_um', 2)::text, true);
SELECT set_config('t.e2', qa.nova_escolta(now() + interval '2 days', 'agendada', 'qa_tres', 2)::text, true);
SELECT qa.como('qa_gestor');
DO $$
DECLARE e1 uuid := current_setting('t.e1')::uuid; e2 uuid := current_setting('t.e2')::uuid;
        ev1 uuid; ev2 uuid; n int;
BEGIN
  SELECT id INTO ev1 FROM public.escolta_veiculos WHERE escolta_id = e1 ORDER BY criado_em LIMIT 1;
  SELECT id INTO ev2 FROM public.escolta_veiculos WHERE escolta_id = e1 ORDER BY criado_em DESC LIMIT 1;
  -- Dois vigilantes diferentes na mesma viatura, e um terceiro na outra viatura: aceito.
  INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta)
  VALUES (e1, ev1, qa.vigilante('qa_dois'), 'operador'), (e1, ev2, qa.vigilante('qa_tres'), 'comandante');
  SELECT count(*) INTO n FROM public.escolta_efetivo WHERE escolta_id = e1;
  IF n = 3 THEN RAISE NOTICE 'PASSOU: gestor escala três vigilantes diferentes em duas viaturas';
  ELSE RAISE NOTICE 'FALHOU: efetivo da E1 com % linhas', n; END IF;
  -- O mesmo vigilante em outra escolta: aceito (a unicidade é por escolta).
  INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta)
  SELECT e2, id, qa.vigilante('qa_dois'), 'operador' FROM public.escolta_veiculos WHERE escolta_id = e2 ORDER BY criado_em LIMIT 1;
  RAISE NOTICE 'PASSOU: o mesmo vigilante entra em outra escolta';
  -- O mesmo vigilante duas vezes na mesma viatura.
  BEGIN
    INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta)
    VALUES (e1, ev1, qa.vigilante('qa_um'), 'operador');
    RAISE NOTICE 'FALHOU: vigilante repetido na mesma viatura aceito';
  EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: vigilante repetido na mesma viatura';
  END;
  -- O mesmo vigilante em outra viatura da mesma escolta.
  BEGIN
    INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta)
    VALUES (e1, ev2, qa.vigilante('qa_um'), 'operador');
    RAISE NOTICE 'FALHOU: vigilante repetido em outra viatura da mesma escolta aceito';
  EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: vigilante repetido em outra viatura da mesma escolta';
  END;
  -- Trocar a linha de um vigilante para outro já escalado (UPDATE) também esbarra no índice.
  BEGIN
    UPDATE public.escolta_efetivo SET vigilante_id = qa.vigilante('qa_um')
     WHERE escolta_id = e1 AND vigilante_id = qa.vigilante('qa_dois');
    RAISE NOTICE 'FALHOU: UPDATE para vigilante já escalado aceito';
  EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: UPDATE para vigilante já escalado na escolta';
  END;
  -- A mesma placa duas vezes na escolta.
  BEGIN
    INSERT INTO public.escolta_veiculos (escolta_id, veiculo_id, quilometragem_saida)
    VALUES (e1, '00000000-0000-4000-a000-0000000000f1', 1000);
    RAISE NOTICE 'FALHOU: mesma viatura duas vezes na escolta aceita';
  EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: mesma viatura duas vezes na escolta';
  END;
  -- Outra viatura, ainda não usada na E2: aceita.
  INSERT INTO public.escolta_veiculos (escolta_id, veiculo_id, quilometragem_saida)
  VALUES (e2, '00000000-0000-4000-a000-0000000000f3', 1000);
  RAISE NOTICE 'PASSOU: viatura nova na E2 aceita';
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: erro inesperado: %', SQLERRM;
END $$;
RESET ROLE;
ROLLBACK;
