-- Lote 2026-10, onda D2 (acréscimos da onda D): migration 215 (uso e UF dos locais salvos).
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa), com a 215 aplicada.
-- Esperado: só PASSOU e BLOQUEADO CORRETAMENTE. Cada bloco roda numa transação desfeita.
\set QUIET on
\pset tuples_only on

-- Volta a ser postgres SEM usuário final (RESET ROLE não limpa as claims do JWT).
CREATE FUNCTION pg_temp.pg() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $$;
-- Uso de um local pelo nome (como postgres).
CREATE FUNCTION pg_temp.uso(p text) RETURNS int LANGUAGE sql AS $$ SELECT vezes_usado FROM public.locais_salvos WHERE nome = p $$;
-- Locais QA isolados (longe dos locais reais): Base com texto e pino, Doca só com texto, Velho inativo.
CREATE FUNCTION pg_temp.locais_qa() RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.locais_salvos (nome, endereco, latitude, longitude, situacao, uf) VALUES
    ('QA D2 Base', 'Rua QA D2, 100, Centro, Palmas', -10.1840000, -48.3336000, 'ativo', 'TO'),
    ('QA D2 Doca', 'Avenida QA D2, 900, Distrito, Palmas', NULL, NULL, 'aguardando_conferencia', 'TO'),
    ('QA D2 Velho', 'Travessa QA D2, 5, Palmas', -10.2500000, -48.3000000, 'inativo', 'TO');
$$;
-- Escolta como a Nova grava (INSERT direto pelo perfil da sessão).
CREATE FUNCTION pg_temp.nova(p_origem text, p_olat numeric, p_olng numeric, p_destino text, p_dlat numeric, p_dlng numeric)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO public.escoltas (cliente_id, data_hora_prevista, origem_endereco, origem_lat, origem_lng,
    destino_endereco, destino_lat, destino_lng, data_solicitacao, status, checklist_pendente_no_inicio, criada_por)
  VALUES ('00000000-0000-4000-a000-0000000000c1', now() + interval '3 days', p_origem, p_olat, p_olng,
    p_destino, p_dlat, p_dlng, now(), 'agendada', true, public.get_meu_usuario_id())
  RETURNING id INTO v;
  RETURN v;
END $$;

-- 1. Estrutura: colunas, CHECK, trigger e funções internas sem GRANT.
BEGIN;
DO $$
DECLARE n int; t text;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'locais_salvos' AND column_name IN ('vezes_usado', 'uf');
  IF n = 2 THEN RAISE NOTICE 'PASSOU: locais_salvos tem vezes_usado e uf';
  ELSE RAISE NOTICE 'FALHOU: % de 2 colunas novas', n; END IF;
  SELECT pg_get_triggerdef(oid) INTO t FROM pg_trigger WHERE tgname = 'tr_contar_uso_local' AND tgrelid = 'public.escoltas'::regclass;
  IF t LIKE '%AFTER INSERT OR UPDATE OF origem_endereco, destino_endereco, origem_lat, origem_lng, destino_lat, destino_lng%' THEN
    RAISE NOTICE 'PASSOU: trigger de uso só em INSERT e em UPDATE das colunas de endereço';
  ELSE RAISE NOTICE 'FALHOU: trigger de uso %', coalesce(t, 'ausente'); END IF;
  SELECT count(*) INTO n FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace
     AND p.proname IN ('contar_uso_local', 'local_do_endereco', 'carregar_uso_locais')
     AND p.prosecdef AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE');
  IF n = 3 THEN RAISE NOTICE 'PASSOU: as 3 funções da 215 são SECURITY DEFINER sem EXECUTE para anon e authenticated';
  ELSE RAISE NOTICE 'FALHOU: % de 3 funções internas corretas', n; END IF;
  IF NOT has_column_privilege('authenticated', 'public.locais_salvos', 'vezes_usado', 'UPDATE')
     AND NOT has_column_privilege('authenticated', 'public.locais_salvos', 'vezes_usado', 'INSERT')
     AND has_column_privilege('authenticated', 'public.locais_salvos', 'uf', 'UPDATE')
  THEN RAISE NOTICE 'PASSOU: authenticated não grava vezes_usado (INSERT e UPDATE por coluna) e grava uf';
  ELSE RAISE NOTICE 'FALHOU: privilégios por coluna de locais_salvos'; END IF;
  SELECT count(*) INTO n FROM public.locais_salvos
   WHERE nome IN ('JAMEF', 'Sede', 'Engenhão', 'Aeroporto do Galeão', 'Aeroporto Santos Dumont') AND uf = 'RJ';
  IF n = 5 THEN RAISE NOTICE 'PASSOU: os 5 locais da carga têm UF RJ';
  ELSE RAISE NOTICE 'FALHOU: % de 5 locais da carga com UF RJ', n; END IF;
  BEGIN
    UPDATE public.locais_salvos SET uf = 'rj' WHERE nome = 'JAMEF';
    RAISE NOTICE 'FALHOU: UF minúscula aceita';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: UF fora do formato de duas letras maiúsculas';
  END;
END $$;
ROLLBACK;

-- 2. Criação conta origem e destino; complemento no texto conta; inativo não conta.
BEGIN;
SELECT pg_temp.locais_qa();
SELECT qa.como('qa_gestor');
SELECT set_config('t.e', pg_temp.nova('Rua QA D2, 100, Centro, Palmas, Portão 2', -10.1840000, -48.3336000,
                                      'Avenida QA D2, 900, Distrito, Palmas, Doca 7', -10.9, -48.9)::text, true);
SELECT set_config('t.f', pg_temp.nova('Travessa QA D2, 5, Palmas', -10.25, -48.30, 'Lugar sem local salvo, Palmas', -11.5, -49.5)::text, true);
SELECT pg_temp.pg();
DO $$
BEGIN
  IF pg_temp.uso('QA D2 Base') = 1 AND pg_temp.uso('QA D2 Doca') = 1 THEN
    RAISE NOTICE 'PASSOU: escolta nova soma 1 na origem e 1 no destino (endereço com complemento no texto, como a Nova grava)';
  ELSE RAISE NOTICE 'FALHOU: uso Base % Doca %', pg_temp.uso('QA D2 Base'), pg_temp.uso('QA D2 Doca'); END IF;
  IF pg_temp.uso('QA D2 Velho') = 0 THEN RAISE NOTICE 'PASSOU: local inativo não conta';
  ELSE RAISE NOTICE 'FALHOU: inativo contou %', pg_temp.uso('QA D2 Velho'); END IF;
END $$;
ROLLBACK;

-- 3. Coordenada a até 100 m conta; a 300 m não; texto vence a coordenada.
BEGIN;
SELECT pg_temp.locais_qa();
SELECT qa.como('qa_gestor');
-- ~55 m ao norte do pino da Base, texto diferente: conta pela coordenada.
SELECT pg_temp.nova('Rua Vizinha, 7, Palmas', -10.1835000, -48.3336000, 'Lugar sem local salvo, Palmas', -11.5, -49.5);
-- ~330 m: não conta.
SELECT pg_temp.nova('Rua Longe, 8, Palmas', -10.1810000, -48.3336000, 'Lugar sem local salvo, Palmas', -11.5, -49.5);
-- Texto da Doca com coordenada colada na Base: conta a Doca (texto primeiro).
SELECT pg_temp.nova('Avenida QA D2, 900, Distrito, Palmas', -10.1840000, -48.3336000, 'Lugar sem local salvo, Palmas', -11.5, -49.5);
SELECT pg_temp.pg();
DO $$
BEGIN
  IF pg_temp.uso('QA D2 Base') = 1 AND pg_temp.uso('QA D2 Doca') = 1 THEN
    RAISE NOTICE 'PASSOU: coordenada a 55 m conta, a 330 m não, e o texto do local vence a coordenada de outro';
  ELSE RAISE NOTICE 'FALHOU: uso Base % Doca %', pg_temp.uso('QA D2 Base'), pg_temp.uso('QA D2 Doca'); END IF;
END $$;
ROLLBACK;

-- 4. Edição: só a mudança de local conta (IS DISTINCT FROM); mesmo endereço, complemento e
-- outras colunas não contam; a edição pela editar_escolta (onda I) conta o lado mudado.
BEGIN;
SELECT pg_temp.locais_qa();
SELECT qa.como('qa_gestor');
SELECT set_config('t.e', pg_temp.nova('Lugar sem local salvo, Palmas', -11.5, -49.5, 'Rua QA D2, 100, Centro, Palmas', -10.1840000, -48.3336000)::text, true);
DO $$
DECLARE e uuid := current_setting('t.e')::uuid;
BEGIN
  UPDATE public.escoltas SET origem_endereco = origem_endereco, destino_endereco = destino_endereco,
         destino_lat = destino_lat, destino_lng = destino_lng WHERE id = e;
  UPDATE public.escoltas SET data_hora_prevista = data_hora_prevista + interval '1 hour', valor_cobrado = 500 WHERE id = e;
  UPDATE public.escoltas SET destino_endereco = 'Rua QA D2, 100, Centro, Palmas, Portão 3' WHERE id = e;
END $$;
SELECT pg_temp.pg();
DO $$
BEGIN
  IF pg_temp.uso('QA D2 Base') = 1 THEN
    RAISE NOTICE 'PASSOU: regravar o mesmo endereço, mudar data e valor e trocar só o complemento do mesmo local não contam';
  ELSE RAISE NOTICE 'FALHOU: uso da Base % (esperado 1)', pg_temp.uso('QA D2 Base'); END IF;
END $$;
SELECT qa.como('qa_gestor');
SELECT public.editar_escolta(current_setting('t.e')::uuid,
  '{"origem_endereco": "Avenida QA D2, 900, Distrito, Palmas", "origem_lat": -10.9, "origem_lng": -48.9,
    "destino_endereco": "Rua QA D2, 100, Centro, Palmas, Portão 3", "destino_lat": -10.184, "destino_lng": -48.3336}'::jsonb, NULL, NULL) IS NOT NULL;
SELECT pg_temp.pg();
DO $$
BEGIN
  IF pg_temp.uso('QA D2 Doca') = 1 AND pg_temp.uso('QA D2 Base') = 1 THEN
    RAISE NOTICE 'PASSOU: edição pela editar_escolta conta só a origem que mudou de local (destino reenviado igual não conta)';
  ELSE RAISE NOTICE 'FALHOU: uso Doca % Base %', pg_temp.uso('QA D2 Doca'), pg_temp.uso('QA D2 Base'); END IF;
END $$;
ROLLBACK;

-- 5. Avançar o status não conta (operador do efetivo, como a master grava) e não muda o local.
BEGIN;
SELECT set_config('t.e', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um', 1)::text, true);
UPDATE public.escoltas SET origem_endereco = 'Sede QA', origem_lat = -22.918625, origem_lng = -43.36267 WHERE id = current_setting('t.e')::uuid;
SELECT set_config('t.antes', (SELECT string_agg(nome || '=' || vezes_usado || '/' || atualizado_em, ',' ORDER BY nome) FROM public.locais_salvos), true);
SELECT qa.como('qa_um');
DO $$
DECLARE n int;
BEGIN
  UPDATE public.escoltas SET status = 'na_origem' WHERE id = current_setting('t.e')::uuid;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 1 THEN RAISE NOTICE 'PASSOU: operador do efetivo avança o status (em_andamento para na_origem)';
  ELSE RAISE NOTICE 'FALHOU: avanço de status sem linha'; END IF;
END $$;
SELECT pg_temp.pg();
UPDATE public.escolta_veiculos SET quilometragem_saida = 1234 WHERE escolta_id = current_setting('t.e')::uuid;
DO $$
BEGIN
  IF (SELECT string_agg(nome || '=' || vezes_usado || '/' || atualizado_em, ',' ORDER BY nome) FROM public.locais_salvos) = current_setting('t.antes') THEN
    RAISE NOTICE 'PASSOU: avançar o status e mudar o KM não mudam vezes_usado nem nenhum local';
  ELSE RAISE NOTICE 'FALHOU: locais mudaram com status ou KM'; END IF;
END $$;
ROLLBACK;

-- 6. Operador não altera vezes_usado nem uf; supervisor e gestor não alteram vezes_usado.
BEGIN;
SELECT pg_temp.locais_qa();
SELECT qa.como('qa_um');
DO $$
DECLARE n int;
BEGIN
  BEGIN
    UPDATE public.locais_salvos SET vezes_usado = 999 WHERE nome = 'QA D2 Base';
    RAISE NOTICE 'FALHOU: operador alterou vezes_usado';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não altera vezes_usado';
  END;
  UPDATE public.locais_salvos SET uf = 'SP' WHERE nome = 'QA D2 Base';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não altera uf (nenhuma linha)';
  ELSE RAISE NOTICE 'FALHOU: operador alterou uf de % local', n; END IF;
  BEGIN
    INSERT INTO public.locais_salvos (nome, endereco, uf) VALUES ('QA D2 operador', 'Rua do operador', 'RJ');
    RAISE NOTICE 'FALHOU: operador cadastrou local com uf';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não cadastra local (nem com uf)';
  END;
END $$;
SELECT pg_temp.pg();
SELECT qa.como('qa_supervisor');
DO $$
BEGIN
  BEGIN
    UPDATE public.locais_salvos SET vezes_usado = 50 WHERE nome = 'QA D2 Base';
    RAISE NOTICE 'FALHOU: supervisor alterou vezes_usado';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: supervisor não altera vezes_usado';
  END;
  BEGIN
    INSERT INTO public.locais_salvos (nome, endereco, vezes_usado) VALUES ('QA D2 supervisor', 'Rua do supervisor', 40);
    RAISE NOTICE 'FALHOU: supervisor cadastrou local já com uso';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: supervisor não cadastra local já com vezes_usado';
  END;
END $$;
SELECT pg_temp.pg();
SELECT qa.como('qa_gestor');
DO $$
BEGIN
  BEGIN
    UPDATE public.locais_salvos SET vezes_usado = 0 WHERE nome = 'JAMEF';
    RAISE NOTICE 'FALHOU: gestor zerou vezes_usado pela API';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: gestor também não altera vezes_usado pela API';
  END;
END $$;
SELECT pg_temp.pg();
DO $$
BEGIN
  IF pg_temp.uso('QA D2 Base') = 0 AND (SELECT uf FROM public.locais_salvos WHERE nome = 'QA D2 Base') = 'TO' THEN
    RAISE NOTICE 'PASSOU: vezes_usado e uf do local continuam como estavam';
  ELSE RAISE NOTICE 'FALHOU: local QA mudou'; END IF;
END $$;
ROLLBACK;

-- 7. Supervisor cadastra com UF ("Salvar este endereço"): nasce aguardando, uso 0; UF do
-- local ativo mudada devolve para conferência; o uso contado pela escolta de outro usuário
-- não grava esse usuário em atualizado_por do local.
BEGIN;
SELECT pg_temp.locais_qa();
SELECT qa.como('qa_supervisor');
DO $$
DECLARE r record;
BEGIN
  INSERT INTO public.locais_salvos (nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, uf)
  VALUES ('QA D2 do campo', 'Rua do Campo, 10, Niterói', 'Portão 1', -22.89, -43.10, 'ativo', 'Formulário de escolta', 'RJ')
  RETURNING situacao, vezes_usado, uf INTO r;
  IF r.situacao = 'aguardando_conferencia' AND r.vezes_usado = 0 AND r.uf = 'RJ' THEN
    RAISE NOTICE 'PASSOU: supervisor salva o endereço do campo com UF, aguardando conferência e uso 0';
  ELSE RAISE NOTICE 'FALHOU: local do campo % % %', r.situacao, r.vezes_usado, r.uf; END IF;
  UPDATE public.locais_salvos SET uf = 'TO' WHERE nome = 'QA D2 Base';
  SELECT situacao INTO r FROM public.locais_salvos WHERE nome = 'QA D2 Base';
  IF r.situacao = 'ativo' THEN RAISE NOTICE 'PASSOU: regravar a mesma UF de local ativo mantém o local ativo';
  ELSE RAISE NOTICE 'FALHOU: regravar a mesma UF mudou o local para %', r.situacao; END IF;
END $$;
ROLLBACK;
BEGIN;
SELECT pg_temp.locais_qa();
SELECT qa.como('qa_supervisor');
DO $$
DECLARE v text;
BEGIN
  UPDATE public.locais_salvos SET uf = 'GO' WHERE nome = 'QA D2 Base';
  SELECT situacao INTO v FROM public.locais_salvos WHERE nome = 'QA D2 Base';
  IF v = 'aguardando_conferencia' THEN RAISE NOTICE 'PASSOU: mudar a UF de local ativo devolve para conferência';
  ELSE RAISE NOTICE 'FALHOU: local continuou %', v; END IF;
END $$;
ROLLBACK;
BEGIN;
SELECT pg_temp.locais_qa();
SELECT set_config('t.antes', (SELECT coalesce(atualizado_por::text, '-') || '|' || atualizado_em FROM public.locais_salvos WHERE nome = 'QA D2 Base'), true);
SELECT qa.como('qa_supervisor');
SELECT pg_temp.nova('Rua QA D2, 100, Centro, Palmas', -10.184, -48.3336, 'Lugar sem local salvo, Palmas', -11.5, -49.5);
SELECT pg_temp.pg();
DO $$
BEGIN
  IF pg_temp.uso('QA D2 Base') = 1
     AND (SELECT coalesce(atualizado_por::text, '-') || '|' || atualizado_em FROM public.locais_salvos WHERE nome = 'QA D2 Base') = current_setting('t.antes') THEN
    RAISE NOTICE 'PASSOU: escolta criada pelo supervisor conta o uso sem gravar o supervisor em atualizado_por do local';
  ELSE RAISE NOTICE 'FALHOU: uso % ou atualizado_por mudou', pg_temp.uso('QA D2 Base'); END IF;
END $$;
ROLLBACK;

-- 8. A carga só lê escoltas: nenhuma linha de escoltas muda (ESC-2026-0001 e 0007 incluídas)
-- e o resultado bate com a contagem pela mesma regra.
BEGIN;
SELECT set_config('t.md5', (SELECT md5(string_agg(e::text, '|' ORDER BY e.id)) FROM public.escoltas e), true);
SELECT set_config('t.ref', (SELECT md5(string_agg(e::text, '|' ORDER BY e.id)) FROM public.escoltas e WHERE codigo_escolta IN ('ESC-2026-0001', 'ESC-2026-0007')), true);
UPDATE public.locais_salvos SET vezes_usado = 0;
SELECT lote_interno.carregar_uso_locais();
DO $$
DECLARE n int; esperado int;
BEGIN
  IF (SELECT md5(string_agg(e::text, '|' ORDER BY e.id)) FROM public.escoltas e) = current_setting('t.md5')
     AND (SELECT md5(string_agg(e::text, '|' ORDER BY e.id)) FROM public.escoltas e WHERE codigo_escolta IN ('ESC-2026-0001', 'ESC-2026-0007')) IS NOT DISTINCT FROM current_setting('t.ref')
  THEN RAISE NOTICE 'PASSOU: a carga do uso não muda nenhuma escolta (ESC-2026-0001 e 0007 iguais)';
  ELSE RAISE NOTICE 'FALHOU: a carga mudou escoltas'; END IF;
  SELECT count(*) INTO esperado FROM public.escoltas e, LATERAL (VALUES (lote_interno.local_do_endereco(e.origem_endereco, e.origem_lat, e.origem_lng)),
                                                                        (lote_interno.local_do_endereco(e.destino_endereco, e.destino_lat, e.destino_lng))) v(l)
   WHERE v.l IS NOT NULL;
  SELECT sum(vezes_usado) INTO n FROM public.locais_salvos;
  IF n = esperado AND n > 0 THEN RAISE NOTICE 'PASSOU: carga soma % usos, igual à contagem das escoltas pela mesma regra', n;
  ELSE RAISE NOTICE 'FALHOU: carga % esperado %', n, esperado; END IF;
END $$;
ROLLBACK;

-- 9. A trigger nunca recusa a escolta: coordenada zerada (sem coordenada) e texto sem local. (A central não grava
-- escolta no banco: a policy escoltas_insert, anterior ao lote, é só gestão e supervisor.)
BEGIN;
SELECT qa.como('qa_supervisor');
DO $$
DECLARE v uuid;
BEGIN
  v := pg_temp.nova('Endereço sem coordenada', 0, 0, 'Outro sem coordenada', 0, 0);
  IF v IS NOT NULL THEN RAISE NOTICE 'PASSOU: escolta com coordenada zerada e texto sem local gravada com a trigger de uso ligada';
  ELSE RAISE NOTICE 'FALHOU: escolta não gravada'; END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'FALHOU: trigger de uso recusou a escolta: %', SQLERRM;
END $$;
ROLLBACK;
