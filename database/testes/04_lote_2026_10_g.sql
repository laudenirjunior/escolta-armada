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

-- ── RPCs da 204 com os índices da 210 aplicados (revisão adversarial G, achados 1 e 3) ──

-- Assumir escolta vazia com a placa da outra viatura da escolta: recusado com mensagem.
BEGIN;
SELECT set_config('t.e', qa.nova_escolta(now() + interval '2 days', 'agendada', NULL, 2)::text, true);
SELECT qa.como('qa_dois');
DO $$
BEGIN
  PERFORM public.assumir_escolta(current_setting('t.e')::uuid, '{}', '00000000-0000-4000-a000-0000000000f2', NULL);
  RAISE NOTICE 'FALHOU: assumir com a placa da outra viatura foi aceito';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE 'Esta viatura já está em outra viatura desta escolta%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: assumir escolta vazia com placa já usada (%)', SQLERRM;
  ELSE RAISE NOTICE 'FALHOU: mensagem inesperada %', SQLERRM; END IF;
WHEN others THEN RAISE NOTICE 'FALHOU: erro cru %', SQLERRM;
END $$;
ROLLBACK;

-- Pedido (escolta com equipe, dentro da janela) com a placa da outra viatura: recusado.
BEGIN;
SELECT set_config('t.e', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um', 2)::text, true);
SELECT qa.como('qa_dois');
DO $$
BEGIN
  PERFORM public.assumir_escolta(current_setting('t.e')::uuid, '{}', '00000000-0000-4000-a000-0000000000f2', 'a equipe escalada nao apareceu na base');
  RAISE NOTICE 'FALHOU: pedido com a placa da outra viatura foi aceito';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE 'Esta viatura já está em outra viatura desta escolta%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: pedido com placa já usada na escolta';
  ELSE RAISE NOTICE 'FALHOU: mensagem inesperada %', SQLERRM; END IF;
WHEN others THEN RAISE NOTICE 'FALHOU: erro cru %', SQLERRM;
END $$;
ROLLBACK;

-- Assumir escolta vazia com acompanhante repetido e o próprio operador na lista: aceito, sem linha duplicada.
BEGIN;
SELECT set_config('t.e', qa.nova_escolta(now() + interval '2 days', 'agendada', NULL, 1)::text, true);
SELECT qa.como('qa_dois');
DO $$
DECLARE n int; a uuid := qa.vigilante('qa_tres');
BEGIN
  PERFORM public.assumir_escolta(current_setting('t.e')::uuid, ARRAY[a, a, qa.vigilante('qa_dois')], NULL, NULL);
  SELECT count(*) INTO n FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.e')::uuid;
  IF n = 2 THEN RAISE NOTICE 'PASSOU: assumir com acompanhante repetido e o próprio na lista grava 2 linhas';
  ELSE RAISE NOTICE 'FALHOU: efetivo com % linhas', n; END IF;
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: erro %', SQLERRM;
END $$;
ROLLBACK;

-- Incluir vigilante que já está na escolta: mensagem em português.
BEGIN;
SELECT set_config('t.e', qa.nova_escolta(now() + interval '2 days', 'agendada', 'qa_um', 1)::text, true);
INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta)
SELECT current_setting('t.e')::uuid, id, qa.vigilante('qa_dois'), 'operador' FROM public.escolta_veiculos WHERE escolta_id = current_setting('t.e')::uuid;
SELECT qa.como('qa_um');
DO $$
BEGIN
  PERFORM public.incluir_vigilante_na_minha_escolta(current_setting('t.e')::uuid, qa.vigilante('qa_dois'));
  RAISE NOTICE 'FALHOU: vigilante já presente incluído de novo';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM = 'Este vigilante ja esta na escolta.' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: incluir vigilante já presente';
  ELSE RAISE NOTICE 'FALHOU: mensagem inesperada %', SQLERRM; END IF;
WHEN others THEN RAISE NOTICE 'FALHOU: erro cru %', SQLERRM;
END $$;
ROLLBACK;

-- Liberação por tempo: pedido com placa que passou a estar na outra viatura (a gestão
-- incluiu a viatura depois do pedido) não trava o pedido válido seguinte.
BEGIN;
SELECT set_config('t.e1', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um', 1)::text, true);
SELECT set_config('t.e2', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um', 1)::text, true);
SELECT qa.como('qa_dois');
SELECT set_config('t.p1', (public.assumir_escolta(current_setting('t.e1')::uuid, '{}', '00000000-0000-4000-a000-0000000000f2', 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
RESET ROLE;
SELECT qa.como('qa_tres');
SELECT set_config('t.p2', (public.assumir_escolta(current_setting('t.e2')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
RESET ROLE;
INSERT INTO public.escolta_veiculos (escolta_id, veiculo_id, quilometragem_saida, criado_em)
VALUES (current_setting('t.e1')::uuid, '00000000-0000-4000-a000-0000000000f2', 1000, now() + interval '1 second');
UPDATE public.mural_pedidos SET expira_em = now() - interval '1 minute',
       criado_em = CASE WHEN id = current_setting('t.p1')::uuid THEN now() - interval '20 minutes' ELSE now() - interval '10 minutes' END
 WHERE id IN (current_setting('t.p1')::uuid, current_setting('t.p2')::uuid);
DO $$
DECLARE s1 text; o1 text; s2 text; c1 uuid; c2 uuid; a int;
BEGIN
  PERFORM public.processar_pedidos_vencidos();
  SELECT status, observacao_decisao INTO s1, o1 FROM public.mural_pedidos WHERE id = current_setting('t.p1')::uuid;
  SELECT status INTO s2 FROM public.mural_pedidos WHERE id = current_setting('t.p2')::uuid;
  SELECT vigilante_id INTO c1 FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.e1')::uuid AND papel_na_escolta = 'comandante';
  SELECT vigilante_id INTO c2 FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.e2')::uuid AND papel_na_escolta = 'comandante';
  SELECT count(*) INTO a FROM public.logs_auditoria WHERE acao = 'pedido_substituicao_invalidado' AND dados_depois ->> 'pedido_id' = current_setting('t.p1');
  IF s1 = 'invalidado' AND o1 LIKE '%já está em outra viatura%' AND c1 = qa.vigilante('qa_um') AND a = 1 THEN
    RAISE NOTICE 'PASSOU: pedido com placa repetida invalidado com o motivo e auditoria, equipe mantida';
  ELSE RAISE NOTICE 'FALHOU: pedido 1 status=% obs=% auditoria=%', s1, o1, a; END IF;
  IF s2 = 'liberado_por_tempo' AND c2 = qa.vigilante('qa_tres') THEN RAISE NOTICE 'PASSOU: o pedido válido seguinte foi liberado por tempo e executado';
  ELSE RAISE NOTICE 'FALHOU: pedido 2 status=%', s2; END IF;
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: processar_pedidos_vencidos lançou %', SQLERRM;
END $$;
ROLLBACK;

-- Liberação por tempo: erro inesperado num pedido (falha simulada por trigger nesta
-- transação) vira 'invalidado' com auditoria, e o pedido seguinte é executado.
BEGIN;
SELECT set_config('t.e1', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um', 1)::text, true);
SELECT set_config('t.e2', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um', 1)::text, true);
SELECT qa.como('qa_dois');
SELECT set_config('t.p1', (public.assumir_escolta(current_setting('t.e1')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
RESET ROLE;
SELECT qa.como('qa_tres');
SELECT set_config('t.p2', (public.assumir_escolta(current_setting('t.e2')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
RESET ROLE;
CREATE FUNCTION qa.falha_simulada() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF NEW.escolta_id = current_setting('t.e1')::uuid THEN RAISE EXCEPTION 'falha simulada do teste'; END IF;
  RETURN NEW;
END $f$;
CREATE TRIGGER qa_falha_simulada BEFORE INSERT ON public.escolta_efetivo FOR EACH ROW EXECUTE FUNCTION qa.falha_simulada();
UPDATE public.mural_pedidos SET expira_em = now() - interval '1 minute',
       criado_em = CASE WHEN id = current_setting('t.p1')::uuid THEN now() - interval '20 minutes' ELSE now() - interval '10 minutes' END
 WHERE id IN (current_setting('t.p1')::uuid, current_setting('t.p2')::uuid);
DO $$
DECLARE s1 text; s2 text; c1 uuid; c2 uuid; a int;
BEGIN
  PERFORM public.processar_pedidos_vencidos();
  SELECT status INTO s1 FROM public.mural_pedidos WHERE id = current_setting('t.p1')::uuid;
  SELECT status INTO s2 FROM public.mural_pedidos WHERE id = current_setting('t.p2')::uuid;
  SELECT vigilante_id INTO c1 FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.e1')::uuid AND papel_na_escolta = 'comandante';
  SELECT vigilante_id INTO c2 FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.e2')::uuid AND papel_na_escolta = 'comandante';
  SELECT count(*) INTO a FROM public.logs_auditoria WHERE acao = 'pedido_substituicao_erro_liberacao' AND dados_depois ->> 'pedido_id' = current_setting('t.p1');
  IF s1 = 'invalidado' AND c1 = qa.vigilante('qa_um') AND a = 1 THEN RAISE NOTICE 'PASSOU: erro inesperado num pedido vira invalidado com auditoria, equipe intacta';
  ELSE RAISE NOTICE 'FALHOU: pedido 1 status=% auditoria=%', s1, a; END IF;
  IF s2 = 'liberado_por_tempo' AND c2 = qa.vigilante('qa_tres') THEN RAISE NOTICE 'PASSOU: o pedido seguinte foi executado apesar do erro no anterior';
  ELSE RAISE NOTICE 'FALHOU: pedido 2 status=%', s2; END IF;
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: processar_pedidos_vencidos lançou %', SQLERRM;
END $$;
ROLLBACK;

-- Aprovação do mesmo caso (placa que passou a estar na outra viatura): sem erro cru, pedido invalidado.
BEGIN;
SELECT set_config('t.e1', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um', 1)::text, true);
SELECT qa.como('qa_dois');
SELECT set_config('t.p1', (public.assumir_escolta(current_setting('t.e1')::uuid, '{}', '00000000-0000-4000-a000-0000000000f2', 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
RESET ROLE;
INSERT INTO public.escolta_veiculos (escolta_id, veiculo_id, quilometragem_saida, criado_em)
VALUES (current_setting('t.e1')::uuid, '00000000-0000-4000-a000-0000000000f2', 1000, now() + interval '1 second');
SELECT qa.como('qa_supervisor');
DO $$
DECLARE r jsonb;
BEGIN
  r := public.aprovar_pedido_mural(current_setting('t.p1')::uuid, NULL);
  IF (r ->> 'executado')::boolean = false THEN RAISE NOTICE 'PASSOU: aprovação com placa repetida não executa e não devolve erro técnico';
  ELSE RAISE NOTICE 'FALHOU: aprovação devolveu %', r; END IF;
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: aprovação lançou %', SQLERRM;
END $$;
RESET ROLE;
DO $$
DECLARE s text; o text; n int;
BEGIN
  SELECT status, observacao_decisao INTO s, o FROM public.mural_pedidos WHERE id = current_setting('t.p1')::uuid;
  SELECT count(*) INTO n FROM public.escolta_veiculos WHERE escolta_id = current_setting('t.e1')::uuid AND veiculo_id = '00000000-0000-4000-a000-0000000000f2';
  IF s = 'invalidado' AND o LIKE '%já está em outra viatura%' AND n = 1 THEN RAISE NOTICE 'PASSOU: pedido aprovado com placa repetida fica invalidado com o motivo';
  ELSE RAISE NOTICE 'FALHOU: status=% obs=% placas=%', s, o, n; END IF;
END $$;
ROLLBACK;
