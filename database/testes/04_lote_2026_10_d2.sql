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

-- 1. Estrutura: colunas, CHECK, triggers, funções internas sem GRANT, lock_timeout, registro
-- de falhas sem acesso de authenticated e resumo das falhas só para a gestão.
BEGIN;
DO $$
DECLARE n int; t text;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'locais_salvos' AND column_name IN ('vezes_usado', 'uf');
  IF n = 2 THEN RAISE NOTICE 'PASSOU: locais_salvos tem vezes_usado e uf';
  ELSE RAISE NOTICE 'FALHOU: % de 2 colunas novas', n; END IF;
  SELECT pg_get_triggerdef(oid) INTO t FROM pg_trigger WHERE tgname = 'tr_contar_uso_local' AND tgrelid = 'public.escoltas'::regclass;
  IF t LIKE '%AFTER INSERT OR DELETE OR UPDATE OF origem_endereco, destino_endereco, origem_lat, origem_lng, destino_lat, destino_lng, status ON public.escoltas FOR EACH ROW%' THEN
    RAISE NOTICE 'PASSOU: trigger de uso das escoltas em INSERT, DELETE e UPDATE das colunas de endereço e do status';
  ELSE RAISE NOTICE 'FALHOU: trigger de uso %', coalesce(t, 'ausente'); END IF;
  SELECT pg_get_triggerdef(oid) INTO t FROM pg_trigger WHERE tgname = 'tr_recontar_uso_locais' AND tgrelid = 'public.locais_salvos'::regclass;
  IF t LIKE '%AFTER INSERT OR DELETE OR UPDATE OF nome, endereco, complemento, latitude, longitude, situacao ON public.locais_salvos FOR EACH STATEMENT%' THEN
    RAISE NOTICE 'PASSOU: trigger por comando em locais_salvos (nome, texto, pino e situação; vezes_usado não a dispara)';
  ELSE RAISE NOTICE 'FALHOU: trigger de recontagem %', coalesce(t, 'ausente'); END IF;
  SELECT count(*) INTO n FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace
     AND p.proname IN ('contar_uso_local', 'recontar_uso_locais', 'local_do_endereco', 'contar_escoltas_do_local', 'carregar_uso_locais')
     AND p.prosecdef AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE');
  IF n = 5 THEN RAISE NOTICE 'PASSOU: as 5 funções internas da 215 são SECURITY DEFINER sem EXECUTE para anon e authenticated';
  ELSE RAISE NOTICE 'FALHOU: % de 5 funções internas corretas', n; END IF;
  SELECT count(*) INTO n FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace
     AND p.proname IN ('contar_uso_local', 'recontar_uso_locais') AND 'lock_timeout=500ms' = ANY (p.proconfig);
  IF n = 2 THEN RAISE NOTICE 'PASSOU: as duas funções de trigger rodam com lock_timeout de 500 ms';
  ELSE RAISE NOTICE 'FALHOU: % de 2 funções de trigger com lock_timeout', n; END IF;
  IF NOT has_table_privilege('authenticated', 'lote_interno.locais_uso_falhas', 'SELECT')
     AND NOT has_table_privilege('anon', 'lote_interno.locais_uso_falhas', 'SELECT')
     AND NOT has_schema_privilege('authenticated', 'lote_interno', 'USAGE')
  THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: authenticated e anon não leem lote_interno.locais_uso_falhas';
  ELSE RAISE NOTICE 'FALHOU: registro de falhas legível pela API'; END IF;
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
BEGIN;
INSERT INTO lote_interno.locais_uso_falhas (origem, erro, codigo) VALUES ('escoltas', 'falha QA', 'XX000');
SELECT qa.como('qa_gestor');
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM public.locais_uso_falhas_resumo();
  IF r.total >= 1 AND r.ultima ~ '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}$' THEN
    RAISE NOTICE 'PASSOU: gestor lê o resumo das falhas da contagem (total %, última em DD/MM/AAAA HH:MM de Brasília)', r.total;
  ELSE RAISE NOTICE 'FALHOU: resumo das falhas % %', r.total, r.ultima; END IF;
END $$;
SELECT pg_temp.pg();
SELECT qa.como('qa_supervisor');
DO $$
BEGIN
  PERFORM * FROM public.locais_uso_falhas_resumo();
  RAISE NOTICE 'FALHOU: supervisor leu o resumo das falhas';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: supervisor não lê o resumo das falhas (%)', SQLERRM;
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

-- 4. Edição: só a mudança de local recalcula (IS DISTINCT FROM); mesmo endereço, complemento
-- do mesmo local e outras colunas não mudam o uso; a editar_escolta (onda I) recalcula o lado mudado.
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
  -- A mesma UF junto com outra coluna (fonte_coordenada): a linha muda, então passa pela
  -- comparação de UF da locais_salvos_regras (não pelo atalho do UPDATE só de vezes_usado).
  UPDATE public.locais_salvos SET uf = 'TO', fonte_coordenada = 'Revisada pelo supervisor' WHERE nome = 'QA D2 Base';
  SELECT situacao, fonte_coordenada, (atualizado_por = public.get_meu_usuario_id()) AS por_mim INTO r FROM public.locais_salvos WHERE nome = 'QA D2 Base';
  IF r.situacao = 'ativo' AND r.fonte_coordenada = 'Revisada pelo supervisor' AND r.por_mim THEN
    RAISE NOTICE 'PASSOU: regravar a mesma UF (com outra coluna mudada, pelo caminho completo da regra) mantém o local ativo';
  ELSE RAISE NOTICE 'FALHOU: regravar a mesma UF: % % %', r.situacao, r.fonte_coordenada, r.por_mim; END IF;
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

-- 8. Carga conferida contra uma contagem calculada à parte (os números estão escritos aqui,
-- pela regra lida no docs/03, sem usar as funções da 215): locais e escoltas QA gravados sem
-- trigger, como os que existiam antes da 215. A carga não muda nenhuma escolta.
--   e1: Base (texto) e Doca (texto com complemento que a Doca não tem)       -> Base 1, Doca 1
--   e2: "..., Doca 9" (texto completo da Base Doca 9) e coordenada a 55 m da Base e da
--       Base Doca 9 (mesmo pino): empate pela coordenada vai ao local sem complemento -> Base Doca 9 1, Base 1
--   e3: cancelada, Base e Doca                                                  -> nada
--   e4: "..., Portão 5" (complemento que nenhum local tem) e o inativo Velho    -> Base 1, nada
--   Esperado: Base 3, Base Doca 9 1, Doca 1, Velho 0 (estava 7 e é zerado).
BEGIN;
SET LOCAL session_replication_role = replica;
SELECT pg_temp.locais_qa();
INSERT INTO public.locais_salvos (nome, endereco, complemento, latitude, longitude, situacao, uf)
VALUES ('QA D2 Base Doca 9', 'Rua QA D2, 100, Centro, Palmas', 'Doca 9', -10.1840000, -48.3336000, 'ativo', 'TO');
UPDATE public.locais_salvos SET vezes_usado = 7 WHERE nome = 'QA D2 Velho';
SELECT qa.como('qa_gestor');
SELECT pg_temp.nova('Rua QA D2, 100, Centro, Palmas', -10.1840000, -48.3336000, 'Avenida QA D2, 900, Distrito, Palmas, Doca 7', -10.9, -48.9);
SELECT pg_temp.nova('Rua QA D2, 100, Centro, Palmas, Doca 9', -10.1840000, -48.3336000, 'Rua Vizinha, 7, Palmas', -10.1835000, -48.3336000);
SELECT set_config('t.e3', pg_temp.nova('Rua QA D2, 100, Centro, Palmas', -10.1840000, -48.3336000, 'Avenida QA D2, 900, Distrito, Palmas', -10.9, -48.9)::text, true);
SELECT pg_temp.nova('Rua QA D2, 100, Centro, Palmas, Portão 5', 0, 0, 'Travessa QA D2, 5, Palmas', -10.25, -48.30);
SELECT pg_temp.pg();
UPDATE public.escoltas SET status = 'cancelada' WHERE id = current_setting('t.e3')::uuid;
SET LOCAL session_replication_role = origin;
SELECT set_config('t.md5', coalesce((SELECT md5(string_agg(e::text, '|' ORDER BY e.id)) FROM public.escoltas e), '-'), true);
SELECT set_config('t.ref', coalesce((SELECT md5(string_agg(e::text, '|' ORDER BY e.id)) FROM public.escoltas e WHERE codigo_escolta IN ('ESC-2026-0001', 'ESC-2026-0007')), '-'), true);
SELECT lote_interno.carregar_uso_locais();
DO $$
DECLARE r text;
BEGIN
  IF coalesce((SELECT md5(string_agg(e::text, '|' ORDER BY e.id)) FROM public.escoltas e), '-') = current_setting('t.md5')
     AND coalesce((SELECT md5(string_agg(e::text, '|' ORDER BY e.id)) FROM public.escoltas e WHERE codigo_escolta IN ('ESC-2026-0001', 'ESC-2026-0007')), '-') = current_setting('t.ref')
  THEN RAISE NOTICE 'PASSOU: a carga do uso não muda nenhuma escolta (ESC-2026-0001 e 0007 iguais; % delas neste banco)', (SELECT count(*) FROM public.escoltas WHERE codigo_escolta IN ('ESC-2026-0001', 'ESC-2026-0007'));
  ELSE RAISE NOTICE 'FALHOU: a carga mudou escoltas'; END IF;
  SELECT string_agg(nome || '=' || vezes_usado, ', ' ORDER BY nome) INTO r FROM public.locais_salvos WHERE nome LIKE 'QA D2 %';
  IF r = 'QA D2 Base=3, QA D2 Base Doca 9=1, QA D2 Doca=1, QA D2 Velho=0' THEN
    RAISE NOTICE 'PASSOU: carga igual à contagem calculada à parte (%)', r;
  ELSE RAISE NOTICE 'FALHOU: carga % (esperado QA D2 Base=3, QA D2 Base Doca 9=1, QA D2 Doca=1, QA D2 Velho=0)', r; END IF;
END $$;
ROLLBACK;
-- O mesmo cenário gravado com as triggers ligadas (como a Nova grava) chega aos mesmos números.
BEGIN;
SELECT pg_temp.locais_qa();
INSERT INTO public.locais_salvos (nome, endereco, complemento, latitude, longitude, situacao, uf)
VALUES ('QA D2 Base Doca 9', 'Rua QA D2, 100, Centro, Palmas', 'Doca 9', -10.1840000, -48.3336000, 'ativo', 'TO');
SELECT qa.como('qa_gestor');
SELECT pg_temp.nova('Rua QA D2, 100, Centro, Palmas', -10.1840000, -48.3336000, 'Avenida QA D2, 900, Distrito, Palmas, Doca 7', -10.9, -48.9);
SELECT pg_temp.nova('Rua QA D2, 100, Centro, Palmas, Doca 9', -10.1840000, -48.3336000, 'Rua Vizinha, 7, Palmas', -10.1835000, -48.3336000);
SELECT set_config('t.e3', pg_temp.nova('Rua QA D2, 100, Centro, Palmas', -10.1840000, -48.3336000, 'Avenida QA D2, 900, Distrito, Palmas', -10.9, -48.9)::text, true);
SELECT pg_temp.nova('Rua QA D2, 100, Centro, Palmas, Portão 5', 0, 0, 'Travessa QA D2, 5, Palmas', -10.25, -48.30);
SELECT pg_temp.pg();
UPDATE public.escoltas SET status = 'cancelada' WHERE id = current_setting('t.e3')::uuid;
DO $$
DECLARE r text;
BEGIN
  SELECT string_agg(nome || '=' || vezes_usado, ', ' ORDER BY nome) INTO r FROM public.locais_salvos WHERE nome LIKE 'QA D2 %';
  IF r = 'QA D2 Base=3, QA D2 Base Doca 9=1, QA D2 Doca=1, QA D2 Velho=0' THEN
    RAISE NOTICE 'PASSOU: as triggers chegam aos mesmos números da carga e da contagem à parte (%)', r;
  ELSE RAISE NOTICE 'FALHOU: triggers % (esperado QA D2 Base=3, QA D2 Base Doca 9=1, QA D2 Doca=1, QA D2 Velho=0)', r; END IF;
END $$;
ROLLBACK;

-- 9. A trigger nunca recusa a escolta. Caminho de erro forçado: um CHECK provisório (NOT
-- VALID, desfeito no ROLLBACK) faz o UPDATE do uso falhar; a escolta é gravada, a falha vai
-- para lote_interno.locais_uso_falhas (o mesmo bloco de exceção emite o WARNING) e o uso não
-- muda. O mesmo vale para a recontagem por comando em locais_salvos. Coordenada zerada e
-- texto sem local também gravam. (A criação de escolta pela central é pendência anterior ao
-- lote, registrada em portoes.md para decisão do Peçanha; não é testada aqui.)
BEGIN;
SELECT pg_temp.locais_qa();
ALTER TABLE public.locais_salvos ADD CONSTRAINT qa_forca_erro_uso CHECK (vezes_usado < 1) NOT VALID;
SELECT set_config('t.falhas', (SELECT count(*)::text FROM lote_interno.locais_uso_falhas), true);
SELECT qa.como('qa_supervisor');
DO $$
DECLARE v uuid;
BEGIN
  v := pg_temp.nova('Rua QA D2, 100, Centro, Palmas', -10.1840000, -48.3336000, 'Lugar sem local salvo, Palmas', -11.5, -49.5);
  PERFORM set_config('t.e', v::text, true);
  IF v IS NOT NULL THEN RAISE NOTICE 'PASSOU: escolta gravada mesmo com erro dentro da trigger de uso';
  ELSE RAISE NOTICE 'FALHOU: escolta não gravada'; END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'FALHOU: trigger de uso recusou a escolta: %', SQLERRM;
END $$;
SELECT pg_temp.pg();
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM lote_interno.locais_uso_falhas ORDER BY id DESC LIMIT 1;
  IF (SELECT count(*) FROM lote_interno.locais_uso_falhas) = current_setting('t.falhas')::int + 1
     AND r.origem = 'escoltas' AND r.escolta_id = current_setting('t.e')::uuid AND r.codigo = '23514'
     AND pg_temp.uso('QA D2 Base') = 0 AND EXISTS (SELECT 1 FROM public.escoltas WHERE id = current_setting('t.e')::uuid) THEN
    RAISE NOTICE 'PASSOU: a falha da trigger foi registrada (escolta, código %) e o uso não mudou', r.codigo;
  ELSE RAISE NOTICE 'FALHOU: falha não registrada como esperado (% % % uso %)', r.origem, r.escolta_id, r.codigo, pg_temp.uso('QA D2 Base'); END IF;
END $$;
DO $$
DECLARE n int;
BEGIN
  UPDATE public.locais_salvos SET nome = 'QA D2 Base renomeada' WHERE nome = 'QA D2 Base';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 1 AND (SELECT origem FROM lote_interno.locais_uso_falhas ORDER BY id DESC LIMIT 1) = 'locais_salvos'
     AND (SELECT count(*) FROM lote_interno.locais_uso_falhas) = current_setting('t.falhas')::int + 2 THEN
    RAISE NOTICE 'PASSOU: a recontagem por comando falhou sem recusar a edição do local, e a falha foi registrada';
  ELSE RAISE NOTICE 'FALHOU: recontagem por comando (% linha)', n; END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'FALHOU: a recontagem recusou a edição do local: %', SQLERRM;
END $$;
ROLLBACK;
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

-- 10. O uso é o número real: ida e volta da origem numa edição não infla, cancelar desconta
-- (a máquina de estados não deixa voltar de cancelada) e apagar a escolta desconta.
BEGIN;
SELECT pg_temp.locais_qa();
SELECT qa.como('qa_gestor');
SELECT set_config('t.e', pg_temp.nova('Rua QA D2, 100, Centro, Palmas', -10.1840000, -48.3336000, 'Lugar sem local salvo, Palmas', -11.5, -49.5)::text, true);
SELECT pg_temp.pg();
CREATE FUNCTION pg_temp.par() RETURNS text LANGUAGE sql AS $$ SELECT pg_temp.uso('QA D2 Base') || '/' || pg_temp.uso('QA D2 Doca') $$;
SELECT set_config('t.passos', pg_temp.par(), true);
UPDATE public.escoltas SET origem_endereco = 'Avenida QA D2, 900, Distrito, Palmas', origem_lat = -10.9, origem_lng = -48.9 WHERE id = current_setting('t.e')::uuid;
SELECT set_config('t.passos', current_setting('t.passos') || ' ' || pg_temp.par(), true);
UPDATE public.escoltas SET origem_endereco = 'Rua QA D2, 100, Centro, Palmas', origem_lat = -10.184, origem_lng = -48.3336 WHERE id = current_setting('t.e')::uuid;
SELECT set_config('t.passos', current_setting('t.passos') || ' ' || pg_temp.par(), true);
UPDATE public.escoltas SET status = 'cancelada' WHERE id = current_setting('t.e')::uuid;
SELECT set_config('t.passos', current_setting('t.passos') || ' ' || pg_temp.par(), true);
SELECT qa.como('qa_gestor');
SELECT set_config('t.e2', pg_temp.nova('Lugar sem local salvo, Palmas', -11.5, -49.5, 'Avenida QA D2, 900, Distrito, Palmas', -10.9, -48.9)::text, true);
SELECT pg_temp.pg();
SELECT set_config('t.passos', current_setting('t.passos') || ' ' || pg_temp.par(), true);
DELETE FROM public.escoltas WHERE id = current_setting('t.e2')::uuid;
SELECT set_config('t.passos', current_setting('t.passos') || ' ' || pg_temp.par(), true);
DO $$
BEGIN
  IF current_setting('t.passos') = '1/0 0/1 1/0 0/0 0/1 0/0' THEN
    RAISE NOTICE 'PASSOU: Base/Doca ao criar, trocar a origem, voltar (não infla), cancelar (desconta), criar outra e apagá-la: %', current_setting('t.passos');
  ELSE RAISE NOTICE 'FALHOU: sequência % (esperado 1/0 0/1 1/0 0/0 0/1 0/0)', current_setting('t.passos'); END IF;
END $$;
ROLLBACK;

-- 11. JAMEF e "JAMEF Doca 9" no mesmo endereço e pino: o texto com o complemento conta para a
-- doca, o endereço sem complemento e um complemento que nenhum local tem contam para a JAMEF.
-- Escolta da doca gravada antes de o local da doca existir passa para ele quando ele nasce.
BEGIN;
UPDATE public.locais_salvos SET situacao = 'ativo' WHERE nome = 'JAMEF';
SELECT lote_interno.carregar_uso_locais();
SELECT set_config('t.j0', pg_temp.uso('JAMEF')::text, true);
SELECT qa.como('qa_gestor');
SELECT pg_temp.nova('Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti, Doca 9', -22.799521, -43.347756, 'Lugar sem local salvo, Palmas', -11.5, -49.5);
SELECT pg_temp.pg();
SELECT set_config('t.j1', pg_temp.uso('JAMEF')::text, true);
INSERT INTO public.locais_salvos (nome, endereco, complemento, latitude, longitude, situacao, uf)
VALUES ('JAMEF Doca 9', 'Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti', 'Doca 9', -22.799521, -43.347756, 'ativo', 'RJ');
DO $$
DECLARE j0 int := current_setting('t.j0')::int;
BEGIN
  IF current_setting('t.j1')::int = j0 + 1 AND pg_temp.uso('JAMEF') = j0 AND pg_temp.uso('JAMEF Doca 9') = 1 THEN
    RAISE NOTICE 'PASSOU: a escolta "..., Doca 9" contava para a JAMEF e passou para "JAMEF Doca 9" quando o local nasceu';
  ELSE RAISE NOTICE 'FALHOU: JAMEF % -> % -> %, doca %', j0, current_setting('t.j1'), pg_temp.uso('JAMEF'), pg_temp.uso('JAMEF Doca 9'); END IF;
  IF lote_interno.local_do_endereco('Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti, Doca 9', -22.799521, -43.347756) = (SELECT id FROM public.locais_salvos WHERE nome = 'JAMEF Doca 9')
     AND lote_interno.local_do_endereco('Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti', -22.799521, -43.347756) = (SELECT id FROM public.locais_salvos WHERE nome = 'JAMEF')
     AND lote_interno.local_do_endereco('Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti, Portão 5', -22.799521, -43.347756) = (SELECT id FROM public.locais_salvos WHERE nome = 'JAMEF')
     AND lote_interno.local_do_endereco('Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti, Doca 9', 0, 0) = (SELECT id FROM public.locais_salvos WHERE nome = 'JAMEF Doca 9')
  THEN RAISE NOTICE 'PASSOU: local_do_endereco: com Doca 9 vai à doca (com e sem coordenada); sem complemento e com Portão 5, à JAMEF';
  ELSE RAISE NOTICE 'FALHOU: local_do_endereco não separou JAMEF e JAMEF Doca 9'; END IF;
END $$;
SELECT qa.como('qa_gestor');
SELECT pg_temp.nova('Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti', -22.799521, -43.347756, 'Lugar sem local salvo, Palmas', -11.5, -49.5);
SELECT pg_temp.nova('Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti, Portão 5', -22.799521, -43.347756, 'Lugar sem local salvo, Palmas', -11.5, -49.5);
SELECT pg_temp.nova('Lugar sem local salvo, Palmas', -11.5, -49.5, 'Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti, Doca 9', -22.799521, -43.347756);
SELECT pg_temp.pg();
DO $$
DECLARE j0 int := current_setting('t.j0')::int;
BEGIN
  IF pg_temp.uso('JAMEF') = j0 + 2 AND pg_temp.uso('JAMEF Doca 9') = 2 THEN
    RAISE NOTICE 'PASSOU: escoltas novas: sem complemento e Portão 5 contam para a JAMEF (+2), Doca 9 no destino conta para a doca (2)';
  ELSE RAISE NOTICE 'FALHOU: JAMEF % (esperado %), doca % (esperado 2)', pg_temp.uso('JAMEF'), j0 + 2, pg_temp.uso('JAMEF Doca 9'); END IF;
END $$;
ROLLBACK;
