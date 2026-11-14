-- Numeração e criação atômica de escolta (2026-11-13), migration 224.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa), com a 221 e a 224 aplicadas.
-- Esperado: só PASSOU e BLOQUEADO CORRETAMENTE. Cada bloco roda numa transação desfeita.
-- A concorrência entre duas sessões (duas criações ao mesmo tempo e colisão com código gravado
-- por outra transação) está em database/testes/07_numeracao_escolta_concorrencia.mjs.
\set QUIET on
\pset tuples_only on

CREATE FUNCTION pg_temp.pg() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $$;

-- Campos mínimos de uma escolta nova (cliente QA qualquer, coordenadas no Rio).
CREATE FUNCTION pg_temp.campos() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('cliente_id', (SELECT id FROM public.clientes ORDER BY criado_em LIMIT 1),
    'data_hora_prevista', now() + interval '1 day',
    'origem_endereco', 'Origem teste 224', 'origem_lat', -22.90, 'origem_lng', -43.20,
    'destino_endereco', 'Destino teste 224', 'destino_lat', -22.95, 'destino_lng', -43.25)
$$;
-- N viaturas (veículos distintos), a primeira com o vigilante de qa_um como comandante.
CREATE FUNCTION pg_temp.viaturas(n int, com_vigilante boolean DEFAULT true) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('veiculo_id', v.id,
           'membros', CASE WHEN v.ord = 1 AND com_vigilante
                           THEN jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'comandante'))
                           ELSE '[]'::jsonb END) ORDER BY v.ord)
    FROM (SELECT id, row_number() OVER (ORDER BY placa) ord FROM public.veiculos LIMIT n) v
$$;

-- ── 1. Estrutura e privilégios ────────────────────────────────────────────────────
DO $$
BEGIN
  IF (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc WHERE oid = 'public.gerar_codigo_escolta()'::regprocedure)
  THEN RAISE NOTICE 'PASSOU: gerar_codigo_escolta é SECURITY DEFINER com search_path fixo';
  ELSE RAISE NOTICE 'FALHOU: gerar_codigo_escolta sem SECURITY DEFINER'; END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.criar_escolta(jsonb, jsonb)'::regprocedure)
  THEN RAISE NOTICE 'PASSOU: criar_escolta é SECURITY INVOKER (vale a RLS de quem cria)';
  ELSE RAISE NOTICE 'FALHOU: criar_escolta como SECURITY DEFINER'; END IF;
  IF NOT has_function_privilege('anon', 'public.criar_escolta(jsonb, jsonb)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.criar_escolta(jsonb, jsonb)', 'EXECUTE')
  THEN RAISE NOTICE 'PASSOU: criar_escolta só para authenticated';
  ELSE RAISE NOTICE 'FALHOU: privilégios da criar_escolta'; END IF;
  IF NOT has_table_privilege('authenticated', 'lote_interno.escolta_codigo_contador', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'lote_interno.escolta_codigo_contador', 'UPDATE')
     AND NOT has_table_privilege('anon', 'lote_interno.escolta_codigo_contador', 'SELECT')
  THEN RAISE NOTICE 'PASSOU: contador fechado para anon e authenticated';
  ELSE RAISE NOTICE 'FALHOU: contador exposto'; END IF;
  IF (SELECT ultimo FROM lote_interno.escolta_codigo_contador WHERE ano = extract(year FROM now())::int)
     >= coalesce((SELECT max(substring(codigo_escolta FROM '^ESC-\d{4}-(\d+)')::int) FROM public.escoltas
                   WHERE codigo_escolta LIKE 'ESC-' || to_char(now(), 'YYYY') || '-%'), 0)
  THEN RAISE NOTICE 'PASSOU: contador do ano >= maior código gravado';
  ELSE RAISE NOTICE 'FALHOU: contador abaixo do maior código gravado'; END IF;
END $$;

-- ── 2. A causa: maior código excluído (invisível) não volta a ser usado ─────────────
BEGIN;
-- A escolta de maior número do ano fica excluída (como ESC-2026-0010 e 0011 em produção).
-- Garante uma ESC do ano (o banco de homologação pode não ter nenhuma) e exclui a de maior número.
INSERT INTO public.escoltas (cliente_id, data_hora_prevista, origem_endereco, origem_lat, origem_lng,
                             destino_endereco, destino_lat, destino_lng, status, data_solicitacao,
                             checklist_pendente_no_inicio, criada_por)
VALUES ((pg_temp.campos() ->> 'cliente_id')::uuid, now() + interval '1 day', 'O', -22.9, -43.2, 'D', -22.95, -43.25,
        'agendada', now(), true, qa.usuario('qa_gestor'));
SELECT set_config('t.max', coalesce(max(substring(codigo_escolta FROM '^ESC-\d{4}-(\d+)')::int), 0)::text, true)
  FROM public.escoltas WHERE codigo_escolta LIKE 'ESC-' || to_char(now(), 'YYYY') || '-%';
SELECT set_config('t.esc', id::text, true) FROM public.escoltas
 WHERE codigo_escolta = 'ESC-' || to_char(now(), 'YYYY') || '-' || lpad(current_setting('t.max'), 4, '0');
UPDATE public.escoltas SET arquivada_em = now(), excluida_em = now(), motivo_exclusao = 'teste 224'
 WHERE id = current_setting('t.esc')::uuid;
SELECT qa.como('qa_gestor');
DO $$
DECLARE r jsonb; v_cod text; v_num int;
BEGIN
  IF EXISTS (SELECT 1 FROM public.escoltas WHERE id = current_setting('t.esc')::uuid) THEN
    RAISE NOTICE 'FALHOU: a excluída deveria estar invisível para o gestor (221)';
  END IF;
  r := public.criar_escolta(pg_temp.campos(), pg_temp.viaturas(1));
  v_cod := r ->> 'codigo_escolta';
  v_num := substring(v_cod FROM '-(\d+)$')::int;
  IF v_cod LIKE 'ESC-' || to_char(now(), 'YYYY') || '-%' AND v_num > current_setting('t.max')::int THEN
    RAISE NOTICE 'PASSOU: gestor cria com a maior excluída invisível (% > código da excluída)', v_cod;
  ELSE RAISE NOTICE 'FALHOU: código % (maior antes: %)', v_cod, current_setting('t.max'); END IF;
  IF (SELECT count(*) FROM public.escolta_veiculos WHERE escolta_id = (r ->> 'id')::uuid) = 1
     AND (SELECT count(*) FROM public.escolta_efetivo WHERE escolta_id = (r ->> 'id')::uuid AND papel_na_escolta = 'comandante') = 1
     AND (SELECT status = 'agendada' AND checklist_pendente_no_inicio AND criada_por = public.get_meu_usuario_id()
            FROM public.escoltas WHERE id = (r ->> 'id')::uuid)
  THEN RAISE NOTICE 'PASSOU: escolta, viatura e comandante gravados; status agendada e autor = quem criou';
  ELSE RAISE NOTICE 'FALHOU: gravação incompleta'; END IF;
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: criação com a maior excluída: % %', SQLSTATE, SQLERRM;
END $$;
-- O INSERT direto (caminho antigo da tela) também deixa de colidir: a correção está na trigger.
DO $$
DECLARE v_cod text;
BEGIN
  INSERT INTO public.escoltas (cliente_id, data_hora_prevista, origem_endereco, origem_lat, origem_lng,
                               destino_endereco, destino_lat, destino_lng, status, data_solicitacao,
                               checklist_pendente_no_inicio, criada_por)
  VALUES ((pg_temp.campos() ->> 'cliente_id')::uuid, now() + interval '1 day', 'O', -22.9, -43.2, 'D', -22.95, -43.25,
          'agendada', now(), true, public.get_meu_usuario_id())
  RETURNING codigo_escolta INTO v_cod;
  RAISE NOTICE 'PASSOU: INSERT direto do gestor também sai com código novo (%)', v_cod;
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: INSERT direto: % %', SQLSTATE, SQLERRM;
END $$;
ROLLBACK;

-- ── 3. Supervisor com a maior ARQUIVADA (invisível para ele desde antes da 221) ──────
BEGIN;
INSERT INTO public.escoltas (cliente_id, data_hora_prevista, origem_endereco, origem_lat, origem_lng,
                             destino_endereco, destino_lat, destino_lng, status, data_solicitacao,
                             checklist_pendente_no_inicio, criada_por)
VALUES ((pg_temp.campos() ->> 'cliente_id')::uuid, now() + interval '1 day', 'O', -22.9, -43.2, 'D', -22.95, -43.25,
        'agendada', now(), true, qa.usuario('qa_gestor'));
UPDATE public.escoltas SET arquivada_em = now()
 WHERE codigo_escolta = (SELECT max(codigo_escolta) FROM public.escoltas WHERE codigo_escolta LIKE 'ESC-' || to_char(now(), 'YYYY') || '-%');
SELECT qa.como('qa_supervisor');
DO $$
DECLARE r jsonb;
BEGIN
  r := public.criar_escolta(pg_temp.campos(), pg_temp.viaturas(1));
  RAISE NOTICE 'PASSOU: supervisor cria com a maior arquivada invisível (%)', r ->> 'codigo_escolta';
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: supervisor com arquivada: % %', SQLSTATE, SQLERRM;
END $$;
ROLLBACK;

-- ── 4. Tudo ou nada ──────────────────────────────────────────────────────────────────
BEGIN;
SELECT qa.como('qa_gestor');
DO $$
DECLARE n0 int; n1 int; v jsonb; m text;
BEGIN
  SELECT count(*) INTO n0 FROM public.escoltas;
  -- Segunda viatura com veículo inexistente: a escolta e a primeira viatura já tinham sido
  -- inseridas quando a FK falha. Nada pode sobrar.
  v := pg_temp.viaturas(1) || jsonb_build_array(jsonb_build_object('veiculo_id', gen_random_uuid(), 'membros', '[]'::jsonb));
  BEGIN
    PERFORM public.criar_escolta(pg_temp.campos(), v);
    RAISE NOTICE 'FALHOU: viatura com veículo inexistente passou';
  EXCEPTION WHEN others THEN m := SQLSTATE;
  END;
  SELECT count(*) INTO n1 FROM public.escoltas;
  IF m IS NOT NULL AND n1 = n0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: falha na 2ª viatura não deixa escolta pela metade (%)', m;
  ELSIF m IS NOT NULL THEN RAISE NOTICE 'FALHOU: sobrou escolta pela metade (% -> %)', n0, n1; END IF;
END $$;
DO $$
DECLARE m text; v jsonb;
BEGIN
  -- Mesmo vigilante em duas viaturas.
  v := jsonb_build_array(
         jsonb_build_object('veiculo_id', (SELECT id FROM public.veiculos ORDER BY placa LIMIT 1),
           'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'comandante'))),
         jsonb_build_object('veiculo_id', (SELECT id FROM public.veiculos ORDER BY placa OFFSET 1 LIMIT 1),
           'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'comandante'))));
  BEGIN PERFORM public.criar_escolta(pg_temp.campos(), v); EXCEPTION WHEN others THEN m := SQLERRM; END;
  IF m LIKE '%escalado duas vezes%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: vigilante repetido (%)', m;
  ELSE RAISE NOTICE 'FALHOU: vigilante repetido: %', coalesce(m, 'passou'); END IF;
  m := NULL;
  BEGIN PERFORM public.criar_escolta(pg_temp.campos(), '[]'::jsonb); EXCEPTION WHEN others THEN m := SQLERRM; END;
  IF m LIKE '%ao menos uma viatura%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: sem viatura';
  ELSE RAISE NOTICE 'FALHOU: sem viatura: %', coalesce(m, 'passou'); END IF;
  m := NULL;
  BEGIN PERFORM public.criar_escolta(pg_temp.campos() - 'cliente_id', pg_temp.viaturas(1)); EXCEPTION WHEN others THEN m := SQLERRM; END;
  IF m LIKE '%cliente%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: sem cliente';
  ELSE RAISE NOTICE 'FALHOU: sem cliente: %', coalesce(m, 'passou'); END IF;
  m := NULL;
  BEGIN PERFORM public.criar_escolta(pg_temp.campos() || '{"origem_lat": 0}', pg_temp.viaturas(1)); EXCEPTION WHEN others THEN m := SQLERRM; END;
  IF m LIKE 'Origem sem coordenada%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: origem sem coordenada';
  ELSE RAISE NOTICE 'FALHOU: origem sem coordenada: %', coalesce(m, 'passou'); END IF;
  m := NULL;
  BEGIN PERFORM public.criar_escolta(pg_temp.campos() || '{"status": "finalizada"}', pg_temp.viaturas(1)); EXCEPTION WHEN others THEN m := SQLERRM; END;
  IF m LIKE 'Campo não aceito%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: campo fora da lista (status)';
  ELSE RAISE NOTICE 'FALHOU: campo fora da lista: %', coalesce(m, 'passou'); END IF;
  m := NULL;
  BEGIN
    PERFORM public.criar_escolta(pg_temp.campos(), jsonb_build_array(jsonb_build_object('veiculo_id', (SELECT id FROM public.veiculos LIMIT 1),
      'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'operador')))));
  EXCEPTION WHEN others THEN m := SQLERRM; END;
  IF m LIKE '%Comandante%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: viatura com gente e sem comandante';
  ELSE RAISE NOTICE 'FALHOU: sem comandante: %', coalesce(m, 'passou'); END IF;
END $$;
-- Sem equipe (vai para o mural) continua permitido.
DO $$
DECLARE r jsonb;
BEGIN
  r := public.criar_escolta(pg_temp.campos(), pg_temp.viaturas(2, false));
  IF NOT EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = (r ->> 'id')::uuid)
     AND (SELECT count(*) FROM public.escolta_veiculos WHERE escolta_id = (r ->> 'id')::uuid) = 2
  THEN RAISE NOTICE 'PASSOU: duas viaturas sem equipe (mural)';
  ELSE RAISE NOTICE 'FALHOU: escolta sem equipe'; END IF;
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: escolta sem equipe: % %', SQLSTATE, SQLERRM;
END $$;
ROLLBACK;

-- ── 5. Quem não cria escolta continua sem criar ─────────────────────────────────────
BEGIN;
SELECT qa.como('qa_um');
DO $$
DECLARE m text;
BEGIN
  BEGIN PERFORM public.criar_escolta(pg_temp.campos(), pg_temp.viaturas(1)); EXCEPTION WHEN others THEN m := SQLSTATE; END;
  IF m = '42501' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não cria escolta (42501)';
  ELSE RAISE NOTICE 'FALHOU: operador: %', coalesce(m, 'passou'); END IF;
END $$;
SELECT pg_temp.pg();
SELECT qa.como('qa_central');
DO $$
DECLARE m text;
BEGIN
  BEGIN PERFORM public.criar_escolta(pg_temp.campos(), pg_temp.viaturas(1)); EXCEPTION WHEN others THEN m := SQLSTATE; END;
  IF m = '42501' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: central não cria escolta (42501, igual à policy escoltas_insert)';
  ELSE RAISE NOTICE 'FALHOU: central: %', coalesce(m, 'passou'); END IF;
END $$;
ROLLBACK;

-- ── 6. Transação desfeita devolve o número (sem buraco) ─────────────────────────────
-- (qa.nova_escolta desliga as triggers e grava código QA; aqui o INSERT passa pela trigger.)
DO $$
DECLARE a int; b int;
BEGIN
  SELECT ultimo INTO a FROM lote_interno.escolta_codigo_contador WHERE ano = extract(year FROM now())::int;
  BEGIN
    INSERT INTO public.escoltas (cliente_id, data_hora_prevista, origem_endereco, origem_lat, origem_lng,
                                 destino_endereco, destino_lat, destino_lng, status, data_solicitacao,
                                 checklist_pendente_no_inicio, criada_por)
    VALUES ((pg_temp.campos() ->> 'cliente_id')::uuid, now() + interval '1 day', 'O', -22.9, -43.2, 'D', -22.95, -43.25,
            'agendada', now(), true, qa.usuario('qa_gestor'));
    RAISE EXCEPTION 'desfazer';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  SELECT ultimo INTO b FROM lote_interno.escolta_codigo_contador WHERE ano = extract(year FROM now())::int;
  IF a IS NOT DISTINCT FROM b THEN RAISE NOTICE 'PASSOU: criação desfeita não consome número';
  ELSE RAISE NOTICE 'FALHOU: contador andou com a criação desfeita (% -> %)', a, b; END IF;
END $$;
