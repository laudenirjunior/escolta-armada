-- Lote 2026-10, onda L (operação offline do operador): migration 219 (docs/14, 16.2 e 18.8).
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa), com os blocos 1 e 2 aplicados.
-- Esperado: só PASSOU e BLOQUEADO CORRETAMENTE. Cada bloco roda numa transação desfeita.
-- Cobre o L7 inteiro (idempotência, livro alheio, escrita direta, funções do lote_interno,
-- resultado imutável, conflito não apagável, payload fora da lista, limite de 5 avisos,
-- SEM_VINCULO, 10 emergências de quem perdeu o vínculo, escolta apagada) e os casos de
-- conflito do L4 e do L3 pelo banco (versão, sem acesso, arquivada, apagada, dois
-- aparelhos, dois check-ins seguidos aplicados, edição da observação sem conflito).
\set QUIET on
\pset tuples_only on

-- ── Auxiliares da sessão (pg_temp, somem no fim) ───────────────────────────────────
CREATE FUNCTION pg_temp.pg() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $$;
CREATE FUNCTION pg_temp.ev(p_esc uuid, p_n int) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_esc ORDER BY criado_em OFFSET p_n - 1 LIMIT 1 $$;
CREATE FUNCTION pg_temp.tp(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.dom_tipos_ponto WHERE codigo = p $$;
CREATE FUNCTION pg_temp.tipo_da_etapa(p text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE p WHEN 'em_andamento' THEN 'base_saida' WHEN 'na_origem' THEN 'origem' WHEN 'em_transito_destino' THEN 'transito_destino'
    WHEN 'no_destino' THEN 'destino' WHEN 'em_transito_retorno' THEN 'transito_retorno' WHEN 'retornando' THEN 'retorno'
    WHEN 'na_base' THEN 'base_retorno' END $$;
-- Avança como postgres (sem usuário final) até a etapa pedida, como a jornada da onda I.
CREATE FUNCTION pg_temp.jornada(p_esc uuid, p_ate text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  seq text[] := ARRAY['agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino', 'no_destino',
                      'em_transito_retorno', 'retornando', 'na_base', 'finalizada'];
  v_status text; v_prox text; v_tipo text; v_pontos jsonb; r record; v_resp uuid;
BEGIN
  v_resp := qa.usuario('qa_administrador');
  LOOP
    SELECT status INTO v_status FROM public.escoltas WHERE id = p_esc;
    EXIT WHEN v_status = p_ate OR v_status IS NULL;
    v_prox := seq[array_position(seq, v_status) + 1];
    IF v_prox = 'em_andamento' THEN
      FOR r IN SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_esc LOOP
        INSERT INTO public.checklists (escolta_veiculo_id, tipo, concluido, responsavel_id, data_inicio)
        VALUES (r.id, 'viatura', true, v_resp, clock_timestamp()), (r.id, 'material', true, v_resp, clock_timestamp());
      END LOOP;
    END IF;
    v_tipo := pg_temp.tipo_da_etapa(v_prox);
    v_pontos := CASE WHEN v_tipo IS NULL THEN '[]'::jsonb ELSE
      (SELECT jsonb_agg(jsonb_build_object('escolta_veiculo_id', ev.id, 'tipo_ponto_id', pg_temp.tp(v_tipo),
                                           'data_hora', clock_timestamp(), 'sem_sinal_gps', true, 'lancado_por', v_resp))
         FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_esc) END;
    PERFORM public.registrar_etapa_escolta(p_esc, v_pontos, v_status, v_prox, 'teste onda L', NULL, NULL,
      CASE WHEN v_prox = 'finalizada' THEN 'relatório de teste' END, NULL, pg_temp.tp(v_tipo));
  END LOOP;
END $$;
-- Coloca um login QA no efetivo da viatura n (como postgres).
CREATE FUNCTION pg_temp.no_efetivo(p_esc uuid, p_login text, p_n int) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_esc, pg_temp.ev(p_esc, p_n), qa.vigilante(p_login), 'operador', true, qa.usuario('qa_administrador')) $$;
-- Envelope de etapa com um ponto da etapa na viatura n.
CREATE FUNCTION pg_temp.env_etapa(p_esc uuid, p_n int, p_de text, p_para text, p_ponto uuid DEFAULT gen_random_uuid()) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('escolta_id', p_esc, 'escolta_veiculo_id', pg_temp.ev(p_esc, p_n),
    'etapa', jsonb_build_object('status_atual', p_de, 'status_novo', p_para,
      'tipo_ponto_todas', pg_temp.tp(pg_temp.tipo_da_etapa(p_para)),
      'pontos', jsonb_build_array(jsonb_build_object('id', p_ponto, 'escolta_veiculo_id', pg_temp.ev(p_esc, p_n),
        'tipo_ponto_id', pg_temp.tp(pg_temp.tipo_da_etapa(p_para)), 'data_hora', now() - interval '30 min',
        'latitude', -22.9, 'longitude', -43.3, 'criado_offline', true)))) $$;
-- Envelope de check-in (ponto de parada) na viatura n.
CREATE FUNCTION pg_temp.env_checkin(p_esc uuid, p_n int, p_status text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('escolta_id', p_esc, 'escolta_veiculo_id', pg_temp.ev(p_esc, p_n), 'status_esperado', p_status,
    'linhas', jsonb_build_object('pontos_controle', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(),
      'escolta_veiculo_id', pg_temp.ev(p_esc, p_n), 'tipo_ponto_id', pg_temp.tp('parada'), 'data_hora', now() - interval '20 min',
      'latitude', -22.9, 'longitude', -43.3, 'observacoes', '{"tipo":"reporte_periodico"}', 'criado_offline', true)))) $$;
-- Envelope de ocorrência.
CREATE FUNCTION pg_temp.env_ocorrencia(p_esc uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('escolta_id', p_esc, 'linhas', jsonb_build_object('ocorrencias', jsonb_build_array(jsonb_build_object(
    'id', gen_random_uuid(), 'escolta_id', p_esc, 'tipo_ocorrencia_id', (SELECT id FROM public.dom_tipos_ocorrencia ORDER BY 1 LIMIT 1),
    'descricao', 'ocorrência do teste da onda L', 'data_hora', now() - interval '25 min')))) $$;
-- Envelope de emergência.
CREATE FUNCTION pg_temp.env_emergencia(p_esc uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('escolta_id', p_esc, 'linhas', jsonb_build_object('emergencias', jsonb_build_array(jsonb_build_object(
    'id', gen_random_uuid(), 'escolta_id', p_esc, 'data_hora', now() - interval '15 min', 'sem_sinal_gps', true, 'status', 'aberta')))) $$;
CREATE FUNCTION pg_temp.versao(p_esc uuid) RETURNS int LANGUAGE sql AS $$ SELECT versao_gestao FROM public.escoltas WHERE id = p_esc $$;
-- Mudança da gestão simulada como postgres (sem usuário final as travas deixam passar).
-- (session_replication_role = replica pula a máquina de estados, como o qa.nova_escolta).
CREATE FUNCTION pg_temp.gestao_muda(p_esc uuid, p_sql text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_sql LIKE 'UPDATE public.escoltas%' THEN SET LOCAL session_replication_role = replica; END IF;
  EXECUTE p_sql USING p_esc;
  SET LOCAL session_replication_role = origin;
END $$;

-- ── 1. Estrutura e privilégios ───────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE n int; v_lista text;
BEGIN
  IF (SELECT bool_and(c.relrowsecurity) FROM pg_class c WHERE c.oid IN ('public.registros_campo'::regclass,
        'public.registros_campo_aparelhos'::regclass, 'public.escolta_efetivo_saidas'::regclass,
        'public.registros_campo_avisos_agrupados'::regclass))
     AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY['public.registros_campo', 'public.registros_campo_aparelhos',
                       'public.escolta_efetivo_saidas', 'public.registros_campo_avisos_agrupados']) t,
                       unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p, unnest(ARRAY['anon', 'authenticated']) r
                     WHERE has_table_privilege(r, t, p))
     AND NOT has_table_privilege('anon', 'public.registros_campo', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.escolta_efetivo_saidas', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.registros_campo_aparelhos', 'SELECT') THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: 4 tabelas da 219 com RLS e sem INSERT, UPDATE, DELETE nem TRUNCATE para anon e authenticated';
  ELSE RAISE NOTICE 'FALHOU: privilégio de escrita ou RLS nas tabelas da 219'; END IF;

  IF has_column_privilege('authenticated', 'public.registros_campo', 'motivo', 'SELECT')
     AND has_column_privilege('authenticated', 'public.registros_campo', 'payload', 'SELECT')
     AND NOT has_column_privilege('authenticated', 'public.registros_campo', 'motivo_detalhe', 'SELECT') THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: motivo_detalhe sem SELECT para authenticated (GRANT por coluna; motivo e payload liberados)';
  ELSE RAISE NOTICE 'FALHOU: GRANT por coluna do livro'; END IF;

  SELECT count(*) INTO n FROM information_schema.table_constraints tc JOIN information_schema.constraint_column_usage cu
      ON cu.constraint_name = tc.constraint_name AND cu.table_schema = tc.table_schema
   WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name IN ('registros_campo', 'escolta_efetivo_saidas') AND cu.table_name = 'escoltas';
  IF n = 0 THEN RAISE NOTICE 'PASSOU: escolta_id sem FK no livro e nas saídas (o caso escolta_apagada depende disso)';
  ELSE RAISE NOTICE 'FALHOU: % FKs para escoltas no livro ou nas saídas', n; END IF;

  -- has_function_privilege em TODO o lote_interno: só livro_registrar e livro_resultado para authenticated.
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_lista FROM pg_proc p
   WHERE p.pronamespace = 'lote_interno'::regnamespace AND has_function_privilege('authenticated', p.oid, 'EXECUTE');
  SELECT count(*) INTO n FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF v_lista = 'livro_registrar, livro_resultado' AND n = 0 THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: das % funções do lote_interno, só livro_registrar e livro_resultado executáveis por authenticated; nenhuma por anon',
      (SELECT count(*) FROM pg_proc WHERE pronamespace = 'lote_interno'::regnamespace);
  ELSE RAISE NOTICE 'FALHOU: executáveis por authenticated: %; por anon: %', v_lista, n; END IF;
  IF has_schema_privilege('authenticated', 'lote_interno', 'USAGE') AND NOT has_schema_privilege('anon', 'lote_interno', 'USAGE')
     AND NOT has_table_privilege('authenticated', 'lote_interno.malha_uf', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'lote_interno.locais_uso_falhas', 'SELECT') THEN
    RAISE NOTICE 'PASSOU: USAGE no lote_interno só para authenticated, sem acesso às tabelas internas';
  ELSE RAISE NOTICE 'FALHOU: USAGE ou tabelas do lote_interno'; END IF;
  SELECT count(*) INTO n FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace
     AND p.proname IN ('livro_registrar', 'livro_resultado', 'avisar_conflito', 'fechar_avisos_agrupados', 'registrar_saida_efetivo', 'marcar_escolta_apagada')
     AND p.prosecdef AND 'search_path=public, pg_temp' = ANY (p.proconfig);
  IF n = 6 THEN RAISE NOTICE 'PASSOU: 6 funções internas da 219 SECURITY DEFINER com search_path fixo (livro, avisos e triggers)';
  ELSE RAISE NOTICE 'FALHOU: % de 6 funções internas DEFINER', n; END IF;

  IF (SELECT NOT prosecdef FROM pg_proc WHERE oid = 'public.registrar_campo(uuid, text, jsonb, integer, timestamptz, jsonb)'::regprocedure)
     AND has_function_privilege('authenticated', 'public.registrar_campo(uuid, text, jsonb, integer, timestamptz, jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.registrar_campo(uuid, text, jsonb, integer, timestamptz, jsonb)', 'EXECUTE')
     AND (SELECT prosrc NOT LIKE '%EXECUTE %' AND prosrc LIKE '%FOR UPDATE%' AND prosrc LIKE '%jsonb_populate_record(NULL::public.fotos%'
           FROM pg_proc WHERE proname = 'registrar_campo') THEN
    RAISE NOTICE 'PASSOU: registrar_campo SECURITY INVOKER, só authenticated, sem SQL dinâmico, com FOR UPDATE e ramos por tabela';
  ELSE RAISE NOTICE 'FALHOU: registrar_campo com privilégio ou corpo errado'; END IF;
  SELECT count(*) INTO n FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('reservar_aviso_campo', 'informar_pendentes', 'config_offline', 'listar_conflitos', 'tratar_conflito')
     AND p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE');
  IF n = 5 THEN RAISE NOTICE 'PASSOU: 5 RPCs da 219 SECURITY DEFINER, só para authenticated';
  ELSE RAISE NOTICE 'FALHOU: % de 5 RPCs da 219', n; END IF;

  -- Cadeia da registrar_etapa_escolta (207, 214, 218 e 219).
  IF (SELECT prosrc LIKE '%pc.anulado_em IS NULL%' AND prosrc LIKE '%v_arquivada IS NOT NULL%'
             AND prosrc LIKE '%escolta.historico_rpc%' AND prosrc LIKE '%escolta.data_hora_acao%'
             AND prosrc LIKE '%coalesce(public.get_meu_usuario_id(), x.lancado_por)%'
        FROM pg_proc WHERE oid = 'public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid)'::regprocedure)
     AND (SELECT count(*) FROM pg_proc WHERE proname = 'registrar_etapa_escolta') = 1 THEN
    RAISE NOTICE 'PASSOU: registrar_etapa_escolta com a assinatura de sempre e todos os acréscimos (anulado, arquivada, historico_rpc, hora da ação)';
  ELSE RAISE NOTICE 'FALHOU: registrar_etapa_escolta sem um dos acréscimos ou com outra assinatura'; END IF;

  IF (SELECT command LIKE '%gerar_avisos_checkin%' AND command LIKE '%fechar_avisos_agrupados%' FROM cron.job WHERE jobname = 'lote2026_avisos_checkin') THEN
    RAISE NOTICE 'PASSOU: cron de minuto da 212 fecha também as janelas de emergência (18.8.2)';
  ELSE RAISE NOTICE 'FALHOU: cron sem fechar_avisos_agrupados'; END IF;
  IF (SELECT offline_ligado FROM public.configuracao_avisos WHERE id = 1) THEN
    RAISE NOTICE 'PASSOU: configuracao_avisos.offline_ligado existe e nasce ligada';
  ELSE RAISE NOTICE 'FALHOU: offline_ligado'; END IF;
END $$;
ROLLBACK;

-- ── 2. Idempotência, hora da ação, histórico e Telegram uma vez ──────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; c uuid := gen_random_uuid(); p uuid := gen_random_uuid();
        r1 jsonb; r2 jsonb; v int; n int; h record; c2 uuid := gen_random_uuid(); rr jsonb;
BEGIN
  v := pg_temp.versao(e);
  PERFORM qa.como('qa_um');
  r1 := public.registrar_campo(c, 'etapa', pg_temp.env_etapa(e, 1, 'em_andamento', 'na_origem', p), v, now() - interval '30 min',
                               '{"offline": true, "desvio_ms": 1200}'::jsonb);
  r2 := public.registrar_campo(c, 'etapa', pg_temp.env_etapa(e, 1, 'em_andamento', 'na_origem', gen_random_uuid()), v, now() - interval '30 min', NULL);
  PERFORM pg_temp.pg();
  SELECT count(*) INTO n FROM public.registros_campo WHERE client_id = c;
  IF r1 ->> 'resultado' = 'aplicado' AND NOT (r1 ->> 'duplicado')::boolean AND (r2 ->> 'duplicado')::boolean
     AND r2 ->> 'resultado' = 'aplicado' AND n = 1
     AND (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
           WHERE ev.escolta_id = e AND pc.tipo_ponto_id = pg_temp.tp('origem')) = 1 THEN
    RAISE NOTICE 'PASSOU: mesmo client_id duas vezes: uma linha no livro, um ponto, o reenvio devolve aplicado com duplicado = true';
  ELSE RAISE NOTICE 'FALHOU: idempotência: % / % / % linhas', r1, r2, n; END IF;
  SELECT * INTO h FROM public.escolta_status_historico WHERE escolta_id = e AND status_novo = 'na_origem';
  IF h.data_hora = now() - interval '30 min' AND h.via_rpc
     AND (SELECT data_hora_acao < recebido_em FROM public.registros_campo WHERE client_id = c)
     AND (SELECT criado_offline AND id = p FROM public.pontos_controle WHERE id = p)
     AND r1 ->> 'texto_offline' LIKE 'Registrado às __:__ sem conexão, enviado às __:__ (Brasília)' THEN
    RAISE NOTICE 'PASSOU: histórico com a hora da ação (via_rpc), hora da ação menor que recebido_em, ponto com o id do aparelho e criado_offline, texto "%"', r1 ->> 'texto_offline';
  ELSE RAISE NOTICE 'FALHOU: hora da ação: histórico %, texto %', h.data_hora, r1 ->> 'texto_offline'; END IF;
  -- A variável da hora não vaza para a chamada seguinte na mesma transação.
  PERFORM qa.como('qa_um');
  PERFORM public.registrar_etapa_escolta(e, '[]'::jsonb, 'na_origem', 'em_transito_destino', 'direto', NULL, NULL, NULL, NULL, NULL);
  PERFORM pg_temp.pg();
  IF (SELECT data_hora FROM public.escolta_status_historico WHERE escolta_id = e AND status_novo = 'em_transito_destino') = now() THEN
    RAISE NOTICE 'PASSOU: registrar_etapa_escolta pela assinatura antiga continua com now() (a hora da ação não vaza)';
  ELSE RAISE NOTICE 'FALHOU: hora da ação vazou para a chamada direta'; END IF;
  -- Telegram do registro aplicado: reserva campo:<client_id> uma vez só.
  PERFORM qa.como('qa_um');
  IF public.reservar_aviso_campo(c) AND NOT public.reservar_aviso_campo(c) AND NOT public.reservar_aviso_campo(gen_random_uuid()) THEN
    PERFORM pg_temp.pg();
    RAISE NOTICE 'PASSOU: reservar_aviso_campo devolve true uma única vez (chave campo:<client_id>) e false para registro alheio ou inexistente';
  ELSE PERFORM pg_temp.pg(); RAISE NOTICE 'FALHOU: reserva do Telegram'; END IF;
  -- Registro aplicado na hora (online) não tem o texto das duas horas.
  PERFORM qa.como('qa_um');
  rr := public.registrar_campo(c2, 'linhas', pg_temp.env_ocorrencia(e), pg_temp.versao(e), now(), NULL);
  PERFORM pg_temp.pg();
  IF rr ->> 'resultado' = 'aplicado' AND rr ->> 'texto_offline' IS NULL
     AND (SELECT count(*) FROM public.ocorrencias WHERE escolta_id = e) = 1 THEN
    RAISE NOTICE 'PASSOU: ocorrência pelo envelope aplicada; registro feito na hora sai sem o texto das duas horas';
  ELSE RAISE NOTICE 'FALHOU: ocorrência online: %', rr; END IF;
END $$;
ROLLBACK;

-- ── 3. Dois aparelhos (L3) e dois check-ins seguidos ──────────────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 2)::text, true);
SELECT pg_temp.no_efetivo(current_setting('t.esc')::uuid, 'qa_dois', 2);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; v int; a jsonb; b jsonb; cdup uuid := gen_random_uuid(); d jsonb; ck1 jsonb; ck2 jsonb; pr1 jsonb; pr2 jsonb; n int;
BEGIN
  v := pg_temp.versao(e);
  -- qa_um na viatura 1; qa_dois tenta a mesma etapa na mesma viatura 1; depois na viatura 2.
  PERFORM qa.como('qa_um');
  a := public.registrar_campo(gen_random_uuid(), 'etapa', pg_temp.env_etapa(e, 1, 'em_andamento', 'na_origem'), v, now() - interval '30 min', NULL);
  PERFORM pg_temp.pg(); PERFORM qa.como('qa_dois');
  d := public.registrar_campo(cdup, 'etapa', pg_temp.env_etapa(e, 1, 'em_andamento', 'na_origem'), v, now() - interval '29 min', NULL);
  b := public.registrar_campo(gen_random_uuid(), 'etapa', pg_temp.env_etapa(e, 2, 'em_andamento', 'na_origem'), v, now() - interval '28 min', NULL);
  PERFORM pg_temp.pg();
  SELECT count(*) INTO n FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
   WHERE ev.escolta_id = e AND pc.tipo_ponto_id = pg_temp.tp('origem');
  IF a ->> 'resultado' = 'aplicado' AND (a #>> '{resposta,avancou}')::boolean = false
     AND d ->> 'resultado' = 'conflito' AND d ->> 'motivo' = 'ponto_repetido'
     AND b ->> 'resultado' = 'aplicado' AND (b #>> '{resposta,avancou}')::boolean
     AND n = 2 AND (SELECT status FROM public.escoltas WHERE id = e) = 'na_origem'
     AND (SELECT count(*) FROM public.escolta_status_historico WHERE escolta_id = e AND status_novo = 'na_origem') = 1
     AND (SELECT payload ? 'etapa' FROM public.registros_campo WHERE client_id = cdup) THEN
    RAISE NOTICE 'PASSOU: dois aparelhos: uma transição, um ponto por viatura, o excedente na mesma viatura em conflito (ponto_repetido) com o payload inteiro';
  ELSE RAISE NOTICE 'FALHOU: dois aparelhos: % / % / % / % pontos', a, d, b, n; END IF;
  -- Dois check-ins e duas paradas seguidos (mesma viatura, mesmo status): todos aplicados.
  PERFORM qa.como('qa_um');
  ck1 := public.registrar_campo(gen_random_uuid(), 'linhas', pg_temp.env_checkin(e, 1, 'na_origem'), v, now() - interval '20 min', NULL);
  ck2 := public.registrar_campo(gen_random_uuid(), 'linhas', pg_temp.env_checkin(e, 1, 'na_origem'), v, now() - interval '19 min', NULL);
  pr1 := public.registrar_campo(gen_random_uuid(), 'linhas', pg_temp.env_checkin(e, 1, 'na_origem'), v, now() - interval '18 min', NULL);
  pr2 := public.registrar_campo(gen_random_uuid(), 'linhas', pg_temp.env_checkin(e, 1, 'na_origem'), v, now() - interval '17 min', NULL);
  PERFORM pg_temp.pg();
  IF ck1 ->> 'resultado' = 'aplicado' AND ck2 ->> 'resultado' = 'aplicado' AND pr1 ->> 'resultado' = 'aplicado' AND pr2 ->> 'resultado' = 'aplicado'
     AND (SELECT count(*) FROM public.pontos_controle WHERE escolta_veiculo_id = pg_temp.ev(e, 1) AND tipo_ponto_id = pg_temp.tp('parada')) = 4 THEN
    RAISE NOTICE 'PASSOU: dois check-ins e duas paradas seguidos na mesma viatura: os 4 aplicados (paradas e check-ins nunca entram na regra do ponto repetido)';
  ELSE RAISE NOTICE 'FALHOU: check-ins seguidos: % % % %', ck1 ->> 'motivo', ck2 ->> 'motivo', pr1 ->> 'motivo', pr2 ->> 'motivo'; END IF;
  -- Etapa que chega depois de outra (status não bate): conflito status.
  PERFORM qa.como('qa_dois');
  d := public.registrar_campo(gen_random_uuid(), 'etapa', pg_temp.env_etapa(e, 2, 'em_andamento', 'na_origem'), v, now() - interval '27 min', NULL);
  PERFORM pg_temp.pg();
  IF d ->> 'resultado' = 'conflito' AND d ->> 'motivo' = 'status' THEN
    RAISE NOTICE 'PASSOU: etapa com status esperado diferente do servidor vira conflito (status), nada gravado';
  ELSE RAISE NOTICE 'FALHOU: status: %', d; END IF;
END $$;
ROLLBACK;

-- ── 4. Mudança da gestão durante o offline (L4) ─────────────────────────────────────
-- 4a. Versão: zerar, arquivar, concluir, voltar e avançar de novo até o status esperado.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; v int; r jsonb; c uuid := gen_random_uuid(); n0 int; n1 int; t0 int; t1 int;
BEGIN
  v := pg_temp.versao(e);
  -- Gestão volta uma etapa e avança de novo (versão + 1; o status volta ao esperado).
  PERFORM pg_temp.gestao_muda(e, 'UPDATE public.escoltas SET versao_gestao = versao_gestao + 1 WHERE id = $1');
  SELECT count(*) INTO n0 FROM public.notificacoes WHERE evento_chave = 'conflito:' || c;
  SELECT count(*) INTO t0 FROM public.avisos_telegram WHERE evento_chave = 'conflito:' || c;
  PERFORM qa.como('qa_um');
  r := public.registrar_campo(c, 'etapa', pg_temp.env_etapa(e, 1, 'em_andamento', 'na_origem'), v, now() - interval '30 min', NULL);
  PERFORM pg_temp.pg();
  SELECT count(*) INTO n1 FROM public.notificacoes n JOIN public.usuarios u ON u.id = n.usuario_dest_id JOIN public.dom_perfis p ON p.id = u.perfil_id
   WHERE n.evento_chave = 'conflito:' || c AND p.codigo IN ('administrador', 'gestor', 'supervisor');
  SELECT count(*) INTO t1 FROM public.avisos_telegram WHERE evento_chave = 'conflito:' || c;
  IF r ->> 'resultado' = 'conflito' AND r ->> 'motivo' = 'versao' AND (SELECT status FROM public.escoltas WHERE id = e) = 'em_andamento'
     AND (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
           WHERE ev.escolta_id = e AND pc.tipo_ponto_id = pg_temp.tp('origem')) = 0
     AND n0 = 0 AND n1 >= 3 AND t1 = (CASE WHEN public.avisos_pelo_banco_ativos() THEN 1 ELSE 0 END)
     AND NOT EXISTS (SELECT 1 FROM public.notificacoes n JOIN public.usuarios u ON u.id = n.usuario_dest_id JOIN public.dom_perfis p ON p.id = u.perfil_id
                      WHERE n.evento_chave = 'conflito:' || c AND p.codigo IN ('operador', 'central')) THEN
    RAISE NOTICE 'PASSOU: versão da gestão mudou (voltou e avançou de novo até o status esperado): conflito por versão, nada aplicado, aviso conflito_offline na Central de % pessoas da supervisão e % na fila do Telegram', n1, t1;
  ELSE RAISE NOTICE 'FALHOU: versão: % (Central %, Telegram %)', r, n1, t1; END IF;
  -- Supervisor vê na tela de conflitos.
  PERFORM qa.como('qa_supervisor');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.listar_conflitos(true, 100, NULL)) x
              WHERE x ->> 'client_id' = c::text AND x ->> 'motivo' = 'versao' AND x -> 'payload' ? 'etapa') THEN
    PERFORM pg_temp.pg(); RAISE NOTICE 'PASSOU: supervisor vê o conflito por versão em listar_conflitos, com o payload inteiro';
  ELSE PERFORM pg_temp.pg(); RAISE NOTICE 'FALHOU: conflito fora da lista do supervisor'; END IF;
END $$;
ROLLBACK;

-- 4b. Zerar, concluir e arquivar pelas RPCs da gestão (versão e status), um a um.
BEGIN;
DO $$
DECLARE e uuid; v int; r jsonb; acao text; prev jsonb; ok int := 0;
BEGIN
  FOREACH acao IN ARRAY ARRAY['zerar', 'concluir', 'voltar'] LOOP
    e := qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1);
    PERFORM pg_temp.jornada(e, 'na_origem');
    v := pg_temp.versao(e);
    PERFORM qa.como('qa_gestor');
    IF acao = 'zerar' THEN
      prev := public.zerar_escolta(e, 'motivo do teste da onda L', true);
      PERFORM public.zerar_escolta(e, 'motivo do teste da onda L', false, prev -> 'resumo');
    ELSIF acao = 'voltar' THEN
      prev := public.voltar_etapa_escolta(e, 'motivo do teste da onda L', true);
      PERFORM public.voltar_etapa_escolta(e, 'motivo do teste da onda L', false, prev -> 'resumo');
    ELSE
      PERFORM public.concluir_escolta_antecipada(e, 'motivo do teste da onda L');
    END IF;
    PERFORM pg_temp.pg();
    IF acao = 'voltar' THEN PERFORM pg_temp.jornada(e, 'na_origem'); END IF;   -- avança de novo até o esperado
    PERFORM qa.como('qa_um');
    r := public.registrar_campo(gen_random_uuid(), 'linhas', pg_temp.env_checkin(e, 1, 'na_origem'), v, now() - interval '10 min', NULL);
    PERFORM pg_temp.pg();
    IF r ->> 'resultado' = 'conflito' AND r ->> 'motivo' = 'versao' THEN ok := ok + 1;
    ELSE RAISE NOTICE 'FALHOU: % da gestão durante o offline: %', acao, r; END IF;
  END LOOP;
  IF ok = 3 THEN RAISE NOTICE 'PASSOU: zerar, concluir e voltar uma etapa (e avançar de novo) pela gestão durante o offline: check-in em conflito por versão nos 3';
  END IF;
END $$;
ROLLBACK;

-- 4c. Gestor só edita a observação: tudo aplicado.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; v int; r1 jsonb; r2 jsonb;
BEGIN
  v := pg_temp.versao(e);
  PERFORM qa.como('qa_gestor');
  PERFORM public.editar_escolta(e, jsonb_build_object('observacao_financeira', 'observação editada durante o offline'), NULL, 'motivo do teste da onda L');
  PERFORM pg_temp.pg();
  PERFORM qa.como('qa_um');
  r1 := public.registrar_campo(gen_random_uuid(), 'etapa', pg_temp.env_etapa(e, 1, 'em_andamento', 'na_origem'), v, now() - interval '30 min', NULL);
  r2 := public.registrar_campo(gen_random_uuid(), 'linhas', pg_temp.env_checkin(e, 1, 'na_origem'), v, now() - interval '20 min', NULL);
  PERFORM pg_temp.pg();
  IF pg_temp.versao(e) = v AND r1 ->> 'resultado' = 'aplicado' AND r2 ->> 'resultado' = 'aplicado'
     AND (SELECT observacao_financeira FROM public.escoltas WHERE id = e) = 'observação editada durante o offline' THEN
    RAISE NOTICE 'PASSOU: gestor só editou a observação durante o offline: versão igual, etapa e check-in aplicados, nada em conflito';
  ELSE RAISE NOTICE 'FALHOU: edição da observação: versão %->%, % / %', v, pg_temp.versao(e), r1 ->> 'motivo', r2 ->> 'motivo'; END IF;
END $$;
ROLLBACK;

-- 4d. Operador retirado do efetivo (edição), substituído (mural) e escolta arquivada: sem_acesso.
BEGIN;
DO $$
DECLARE e1 uuid; e2 uuid; e3 uuid; v1 int; v2 int; v3 int; r1 jsonb; r2 jsonb; r3 jsonb; c1 uuid := gen_random_uuid(); c3 uuid := gen_random_uuid();
        m text; vis text; det text; n int; cod3 text;
BEGIN
  e1 := qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1); PERFORM pg_temp.jornada(e1, 'em_andamento'); v1 := pg_temp.versao(e1);
  e2 := qa.nova_escolta(now() + interval '20 min', 'agendada', 'qa_um', 1); v2 := pg_temp.versao(e2);
  e3 := qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1); PERFORM pg_temp.jornada(e3, 'em_andamento'); v3 := pg_temp.versao(e3);
  -- Retirado pela edição (DELETE do efetivo), substituído pelo mural (UPDATE do vigilante), arquivada.
  PERFORM pg_temp.gestao_muda(e1, 'DELETE FROM public.escolta_efetivo WHERE escolta_id = $1');
  PERFORM pg_temp.gestao_muda(e2, format('UPDATE public.escolta_efetivo SET vigilante_id = %L WHERE escolta_id = $1', qa.vigilante('qa_tres')));
  PERFORM pg_temp.gestao_muda(e3, 'UPDATE public.escoltas SET status = ''finalizada'' WHERE id = $1');
  PERFORM pg_temp.gestao_muda(e3, 'UPDATE public.escoltas SET arquivada_em = now(), versao_gestao = versao_gestao + 1 WHERE id = $1');
  PERFORM qa.como('qa_um');
  r1 := public.registrar_campo(c1, 'linhas', pg_temp.env_checkin(e1, 1, 'em_andamento'), v1, now() - interval '10 min', NULL);
  r2 := public.registrar_campo(gen_random_uuid(), 'presenca_base', jsonb_build_object('escolta_id', e2, 'presenca', jsonb_build_object('latitude', -22.9, 'longitude', -43.3)), v2, now() - interval '5 min', NULL);
  r3 := public.registrar_campo(c3, 'linhas', pg_temp.env_ocorrencia(e3), v3 - 1, now() - interval '10 min', NULL);
  SELECT motivo INTO vis FROM public.registros_campo WHERE client_id = c1;
  BEGIN
    SELECT motivo_detalhe INTO det FROM public.registros_campo WHERE client_id = c1;
    m := 'leu';
  EXCEPTION WHEN insufficient_privilege THEN m := 'negado';
  END;
  PERFORM pg_temp.pg();
  IF r1 ->> 'resultado' = 'conflito' AND r1 ->> 'motivo' = 'sem_acesso' AND r2 ->> 'motivo' = 'sem_acesso' AND r3 ->> 'motivo' = 'sem_acesso'
     AND (SELECT string_agg(motivo_detalhe, ',' ORDER BY recebido_em, motivo_detalhe) FROM public.registros_campo WHERE client_id IN (c1, c3)) IN ('arquivada,retirado', 'retirado,arquivada')
     AND (SELECT motivo FROM public.escolta_efetivo_saidas WHERE escolta_id = e2) = 'substituido'
     AND (SELECT count(*) FROM public.pontos_controle WHERE escolta_veiculo_id = pg_temp.ev(e1, 1) AND tipo_ponto_id = pg_temp.tp('parada')) = 0
     AND (SELECT count(*) FROM public.ocorrencias WHERE escolta_id = e3) = 0
     AND vis = 'sem_acesso' AND m = 'negado' THEN
    RAISE NOTICE 'PASSOU: retirado pela edição, substituído pelo mural e escolta arquivada: os 3 em conflito sem_acesso, nada aplicado; o operador lê "sem_acesso" e não lê motivo_detalhe';
  ELSE RAISE NOTICE 'FALHOU: sem acesso: % / % / %, visível %, detalhe %', r1, r2, r3, vis, m; END IF;
  -- Reenvio do mesmo registro: devolve o gravado (o aparelho para de reenviar).
  PERFORM qa.como('qa_um');
  r1 := public.registrar_campo(c1, 'linhas', pg_temp.env_checkin(e1, 1, 'em_andamento'), v1, now() - interval '10 min', NULL);
  PERFORM pg_temp.pg();
  IF (r1 ->> 'duplicado')::boolean AND r1 ->> 'resultado' = 'conflito' AND r1 ->> 'motivo' = 'sem_acesso'
     AND (SELECT count(*) FROM public.registros_campo WHERE client_id = c1) = 1 THEN
    RAISE NOTICE 'PASSOU: reenvio do registro sem acesso devolve o conflito gravado (duplicado), sem nova linha';
  ELSE RAISE NOTICE 'FALHOU: reenvio sem acesso: %', r1; END IF;
  -- Supervisor: código da escolta arquivada (que ele não enxerga pela RLS) e o detalhe.
  SELECT codigo_escolta INTO cod3 FROM public.escoltas WHERE id = e3;
  PERFORM qa.como('qa_supervisor');
  SELECT count(*) INTO n FROM jsonb_array_elements(public.listar_conflitos(true, 100, NULL)) x
   WHERE (x ->> 'client_id' = c3::text AND x ->> 'escolta_codigo' = cod3
          AND x ->> 'motivo_detalhe' = 'arquivada' AND (x ->> 'escolta_arquivada')::boolean)
      OR (x ->> 'client_id' = c1::text AND x ->> 'motivo_detalhe' = 'retirado');
  SELECT jsonb_agg(x - 'payload')::text INTO det FROM jsonb_array_elements(public.listar_conflitos(true, 100, NULL)) x WHERE x ->> 'client_id' IN (c1::text, c3::text);
  PERFORM pg_temp.pg();
  IF n = 2 THEN RAISE NOTICE 'PASSOU: supervisor vê os conflitos sem acesso com o detalhe (retirado, arquivada) e o código da escolta arquivada';
  ELSE RAISE NOTICE 'FALHOU: listar_conflitos com % de 2 (%)', n, det; END IF;
END $$;
ROLLBACK;

-- 4e. Escolta apagada pela gestão: conflito escolta_apagada para quem estava no efetivo.
BEGIN;
DO $$
DECLARE e uuid; cod text; r jsonb; c uuid := gen_random_uuid(); n int; t int;
BEGIN
  e := qa.nova_escolta(now() + interval '2 days', 'rascunho', 'qa_um', 1);
  SELECT codigo_escolta INTO cod FROM public.escoltas WHERE id = e;
  -- Administrador apaga o rascunho sem registro de campo (única exclusão que a 214 permite).
  PERFORM qa.como('qa_administrador');
  DELETE FROM public.escoltas WHERE id = e;
  PERFORM pg_temp.pg();
  IF (SELECT count(*) FROM public.escoltas WHERE id = e) = 0
     AND (SELECT motivo || '|' || escolta_codigo FROM public.escolta_efetivo_saidas WHERE escolta_id = e) = 'escolta_apagada|' || cod THEN
    RAISE NOTICE 'PASSOU: escolta apagada em cascata grava a saída do efetivo (escolta_apagada) com o código, pela trigger';
  ELSE RAISE NOTICE 'FALHOU: saída da escolta apagada: %', (SELECT motivo || '|' || coalesce(escolta_codigo, '-') FROM public.escolta_efetivo_saidas WHERE escolta_id = e); END IF;
  SELECT count(*) INTO t FROM public.avisos_telegram WHERE evento_chave = 'conflito:' || c;
  PERFORM qa.como('qa_um');
  r := public.registrar_campo(c, 'linhas', pg_temp.env_ocorrencia(e), 0, now() - interval '10 min', NULL);
  PERFORM pg_temp.pg();
  SELECT count(*) INTO n FROM public.notificacoes WHERE evento_chave = 'conflito:' || c;
  IF r ->> 'resultado' = 'conflito' AND r ->> 'motivo' = 'sem_acesso'
     AND (SELECT motivo_detalhe || '|' || escolta_codigo FROM public.registros_campo WHERE client_id = c) = 'escolta_apagada|' || cod
     AND n = 0 AND (SELECT count(*) FROM public.avisos_telegram WHERE evento_chave = 'conflito:' || c AND escolta_id IS NULL)
                   = (CASE WHEN public.avisos_pelo_banco_ativos() THEN 1 ELSE 0 END) THEN
    RAISE NOTICE 'PASSOU: registro de escolta apagada: conflito escolta_apagada com o código guardado; aviso só pela fila do Telegram (escolta nula) e pela tela, nenhum na Central (notificacoes exige escolta)';
  ELSE RAISE NOTICE 'FALHOU: escolta apagada: % (Central %)', r, n; END IF;
  PERFORM qa.como('qa_gestor');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.listar_conflitos(true, 100, NULL)) x
              WHERE x ->> 'client_id' = c::text AND x ->> 'escolta_codigo' = cod AND NOT (x ->> 'escolta_existe')::boolean) THEN
    PERFORM pg_temp.pg(); RAISE NOTICE 'PASSOU: gestor vê o conflito da escolta apagada com o código, em listar_conflitos';
  ELSE PERFORM pg_temp.pg(); RAISE NOTICE 'FALHOU: escolta apagada fora da lista'; END IF;
END $$;
ROLLBACK;

-- ── 5. Emergência ────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE e uuid; e2 uuid; v int; r jsonb; i int; c uuid; n int; t int; g record; fechou int;
BEGIN
  -- Nunca vira conflito por status nem por versão (escolta finalizada e versão mudada).
  e := qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1);
  PERFORM pg_temp.jornada(e, 'em_andamento'); v := pg_temp.versao(e);
  PERFORM pg_temp.gestao_muda(e, 'UPDATE public.escoltas SET status = ''finalizada'', versao_gestao = versao_gestao + 1 WHERE id = $1');
  PERFORM qa.como('qa_um');
  r := public.registrar_campo(gen_random_uuid(), 'emergencia', pg_temp.env_emergencia(e), v, now() - interval '15 min', NULL);
  PERFORM pg_temp.pg();
  IF r ->> 'resultado' = 'aplicado' AND (SELECT count(*) FROM public.emergencias WHERE escolta_id = e) = 1 THEN
    RAISE NOTICE 'PASSOU: emergência nunca vira conflito por status nem por versão (escolta finalizada e versão mudada): gravada em emergencias';
  ELSE RAISE NOTICE 'FALHOU: emergência por status: %', r; END IF;
  -- Emergência pelo tipo errado é recusada (a regra não serve de atalho).
  PERFORM qa.como('qa_um');
  BEGIN
    PERFORM public.registrar_campo(gen_random_uuid(), 'linhas', pg_temp.env_emergencia(e), v, now(), NULL);
    PERFORM pg_temp.pg(); RAISE NOTICE 'FALHOU: emergência pelo tipo linhas aceita';
  EXCEPTION WHEN invalid_parameter_value THEN PERFORM pg_temp.pg();
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: emergência só pelo tipo emergencia (PAYLOAD_INVALIDO no tipo linhas)';
  END;
  -- 10 emergências seguidas de quem perdeu o vínculo: 1 aviso imediato e 1 agrupado.
  e2 := qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1);
  PERFORM pg_temp.jornada(e2, 'em_andamento');
  PERFORM pg_temp.gestao_muda(e2, 'DELETE FROM public.escolta_efetivo WHERE escolta_id = $1');
  PERFORM qa.como('qa_um');
  FOR i IN 1..10 LOOP
    r := public.registrar_campo(gen_random_uuid(), 'emergencia', pg_temp.env_emergencia(e2), NULL, now() - interval '15 min', NULL);
  END LOOP;
  PERFORM pg_temp.pg();
  SELECT count(*) INTO n FROM public.registros_campo WHERE escolta_id = e2 AND tipo = 'emergencia' AND resultado = 'conflito' AND motivo = 'sem_acesso';
  SELECT count(DISTINCT evento_chave) INTO t FROM public.notificacoes WHERE escolta_id = e2 AND evento_chave LIKE 'conflito:%';
  SELECT * INTO g FROM public.registros_campo_avisos_agrupados WHERE escolta_id = e2 AND fechado_em IS NULL;
  fechou := lote_interno.fechar_avisos_agrupados(now() + interval '11 min');
  IF n = 10 AND t = 1 AND g.pendentes = 9 AND fechou = 1
     AND (SELECT count(DISTINCT evento_chave) FROM public.notificacoes WHERE escolta_id = e2 AND evento_chave LIKE 'emergencia_agrupada:%') = 1
     AND (SELECT count(*) FROM public.registros_campo WHERE escolta_id = e2 AND aviso = 'enviado') = 1
     AND (SELECT count(*) FROM public.registros_campo WHERE escolta_id = e2 AND aviso = 'agrupado') = 9
     AND (SELECT count(*) FROM public.emergencias WHERE escolta_id = e2) = 0
     AND lote_interno.fechar_avisos_agrupados(now() + interval '30 min') = 0 THEN
    RAISE NOTICE 'PASSOU: 10 emergências seguidas de quem perdeu o vínculo: 10 conflitos sem_acesso, 1 aviso imediato e 1 agrupado (9 somados) fechado pelo cron, sem repetir';
  ELSE RAISE NOTICE 'FALHOU: emergências agrupadas: % conflitos, % imediatos, % pendentes, fechou %', n, t, g.pendentes, fechou; END IF;
END $$;
ROLLBACK;

-- ── 6. SEM_VINCULO e payload fora da lista (nada gravado, nada avisado) ───────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; n0 int; a0 int; t0 int; ok int := 0; p jsonb; s text;
BEGIN
  SELECT count(*) INTO n0 FROM public.registros_campo;
  SELECT count(*) INTO a0 FROM public.notificacoes;
  SELECT count(*) INTO t0 FROM public.avisos_telegram;
  PERFORM qa.como('qa_tres');
  FOREACH p IN ARRAY ARRAY[pg_temp.env_checkin(e, 1, 'em_andamento'), pg_temp.env_emergencia(e),
                           jsonb_build_object('escolta_id', gen_random_uuid(), 'linhas', jsonb_build_object('ocorrencias', '[]'::jsonb))] LOOP
    BEGIN
      PERFORM public.registrar_campo(gen_random_uuid(), CASE WHEN p #> '{linhas,emergencias}' IS NOT NULL THEN 'emergencia' ELSE 'linhas' END,
                                     p, 0, now(), NULL);
      RAISE NOTICE 'FALHOU: sem vínculo aceito: %', p;
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS s = MESSAGE_TEXT;
      IF s = 'SEM_VINCULO' THEN ok := ok + 1; ELSE RAISE NOTICE 'FALHOU: mensagem %', s; END IF;
    END;
  END LOOP;
  PERFORM pg_temp.pg();
  IF ok = 3 AND (SELECT count(*) FROM public.registros_campo) = n0 AND (SELECT count(*) FROM public.notificacoes) = a0
     AND (SELECT count(*) FROM public.avisos_telegram) = t0 THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: quem nunca teve vínculo (check-in, emergência e escolta_id inexistente) recebe SEM_VINCULO; nada gravado nem avisado';
  ELSE RAISE NOTICE 'FALHOU: SEM_VINCULO % de 3', ok; END IF;
  -- Payload com tabela ou coluna fora da lista.
  ok := 0;
  PERFORM qa.como('qa_um');
  FOREACH p IN ARRAY ARRAY[
      jsonb_build_object('escolta_id', e, 'linhas', jsonb_build_object('usuarios', jsonb_build_array(jsonb_build_object('id', gen_random_uuid())))),
      jsonb_build_object('escolta_id', e, 'linhas', jsonb_build_object('pontos_controle', jsonb_build_array(
        (pg_temp.env_checkin(e, 1, 'em_andamento') #> '{linhas,pontos_controle,0}') || jsonb_build_object('anulado_em', now())))),
      jsonb_build_object('escolta_id', e, 'linhas', jsonb_build_object('km', jsonb_build_array(jsonb_build_object(
        'escolta_veiculo_id', pg_temp.ev(e, 1), 'abastecimento_valor', 1)))),
      jsonb_build_object('escolta_id', e, 'outra_coisa', 1),
      jsonb_build_object('escolta_id', e, 'linhas', jsonb_build_object('ocorrencias', jsonb_build_array(
        (pg_temp.env_ocorrencia(e) #> '{linhas,ocorrencias,0}') || jsonb_build_object('escolta_id', gen_random_uuid())))),
      jsonb_build_object('escolta_id', e, 'linhas', jsonb_build_object('fotos', jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid(), 'caminho_arquivo', 'campo/' || gen_random_uuid() || '/x.jpg', 'tipo_foto_id', gen_random_uuid())))),
      jsonb_build_object('escolta_id', e, 'linhas', jsonb_build_object('ocorrencias', jsonb_build_array(
        (pg_temp.env_ocorrencia(e) #> '{linhas,ocorrencias,0}') - 'id')))] LOOP
    BEGIN
      PERFORM public.registrar_campo(gen_random_uuid(), 'linhas', p, 0, now(), NULL);
      RAISE NOTICE 'FALHOU: payload aceito: %', p;
    EXCEPTION WHEN invalid_parameter_value THEN ok := ok + 1;
    END;
  END LOOP;
  PERFORM pg_temp.pg();
  IF ok = 7 AND (SELECT count(*) FROM public.registros_campo) = n0 THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: payload com tabela (usuarios) ou coluna fora da lista (anulado_em, combustível), chave desconhecida, linha de outra escolta, foto de outra escolta ou linha sem id: PAYLOAD_INVALIDO, nada no livro';
  ELSE RAISE NOTICE 'FALHOU: payload fora da lista recusado em % de 7', ok; END IF;
END $$;
ROLLBACK;

-- ── 7. Operador abusando: livro alheio, escrita direta, funções do lote_interno ───────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 2)::text, true);
SELECT pg_temp.no_efetivo(current_setting('t.esc')::uuid, 'qa_dois', 2);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; c_um uuid := gen_random_uuid(); c_dois uuid := gen_random_uuid();
        c_conf uuid := gen_random_uuid(); n int; ok int := 0; f text; v int;
BEGIN
  v := pg_temp.versao(e);
  PERFORM qa.como('qa_um');
  PERFORM public.registrar_campo(c_um, 'linhas', pg_temp.env_checkin(e, 1, 'em_andamento'), v, now() - interval '5 min', NULL);
  PERFORM public.registrar_campo(c_conf, 'linhas', pg_temp.env_checkin(e, 1, 'na_base'), v, now() - interval '5 min', NULL);
  PERFORM pg_temp.pg(); PERFORM qa.como('qa_dois');
  PERFORM public.registrar_campo(c_dois, 'linhas', pg_temp.env_checkin(e, 2, 'em_andamento'), v, now() - interval '5 min', NULL);
  -- Livro alheio invisível.
  SELECT count(*) INTO n FROM public.registros_campo WHERE client_id IN (c_um, c_conf);
  PERFORM pg_temp.pg();
  IF n = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não lê o livro de outro operador (RLS)';
  ELSE RAISE NOTICE 'FALHOU: qa_dois leu % linhas do qa_um', n; END IF;
  PERFORM qa.como('qa_central');
  SELECT count(*) INTO n FROM public.registros_campo WHERE client_id IN (c_um, c_dois, c_conf);
  PERFORM pg_temp.pg();
  IF n = 3 THEN RAISE NOTICE 'PASSOU: central (G4) lê o livro de todos, sem o detalhe do motivo';
  ELSE RAISE NOTICE 'FALHOU: central leu % de 3', n; END IF;

  -- Escrita direta no livro e chamadas às funções do lote_interno em nome de outro.
  PERFORM qa.como('qa_dois');
  FOREACH f IN ARRAY ARRAY[
      format('INSERT INTO public.registros_campo (client_id, usuario_id, auth_user_id, escolta_id, tipo, payload, data_hora_acao, resultado) VALUES (%L, %L, auth.uid(), %L, ''linhas'', ''{}'', now(), ''aplicado'')', gen_random_uuid(), qa.usuario('qa_dois'), e),
      format('UPDATE public.registros_campo SET resultado = ''aplicado'' WHERE client_id = %L', c_dois),
      format('DELETE FROM public.registros_campo WHERE client_id = %L', c_dois),
      format('SELECT lote_interno.livro_resultado(%L, ''aplicado'', NULL, NULL, NULL, NULL, NULL)', c_um),
      format('SELECT lote_interno.livro_resultado(%L, ''conflito'', ''x'', NULL, NULL, NULL, NULL)', c_dois),
      format('SELECT lote_interno.livro_registrar(%L, ''linhas'', %L, NULL, ''{}'', 0, now(), NULL)', c_um, e),
      'SELECT lote_interno.notificar(''x'', NULL, ''conflito_offline'', NULL, ''x'', ''x'', NULL)',
      'SELECT lote_interno.avisar_conflito(gen_random_uuid())',
      'SELECT lote_interno.fechar_avisos_agrupados(now())',
      format('SELECT public.tratar_conflito(%L, ''tratado pelo próprio operador'')', c_conf),
      'SELECT public.listar_conflitos(false, 10, NULL)',
      'INSERT INTO public.escolta_efetivo_saidas (escolta_id, motivo) VALUES (gen_random_uuid(), ''retirado'')',
      'SELECT count(*) FROM public.escolta_efetivo_saidas'] LOOP
    BEGIN
      EXECUTE f;
      RAISE NOTICE 'FALHOU: qa_dois executou %', f;
    EXCEPTION WHEN insufficient_privilege THEN ok := ok + 1;
    END;
  END LOOP;
  PERFORM pg_temp.pg();
  IF ok = 13 AND (SELECT resultado FROM public.registros_campo WHERE client_id = c_dois) = 'aplicado'
     AND (SELECT resultado FROM public.registros_campo WHERE client_id = c_um) = 'aplicado' THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não grava no livro direto (INSERT, UPDATE, DELETE), não muda o resultado (o dele, já gravado, nem o de outro), não usa o livro com client_id de outro, não chama as funções internas sem EXECUTE, não trata nem lista conflitos, não lê nem grava as saídas do efetivo (13)';
  ELSE RAISE NOTICE 'FALHOU: abuso bloqueado em % de 13', ok; END IF;

  -- Conflito não é apagável, nem pela supervisão.
  ok := 0;
  FOREACH f IN ARRAY ARRAY['qa_um', 'qa_supervisor', 'qa_gestor', 'qa_administrador'] LOOP
    PERFORM qa.como(f);
    BEGIN
      DELETE FROM public.registros_campo WHERE client_id = c_conf;
    EXCEPTION WHEN insufficient_privilege THEN ok := ok + 1;
    END;
    PERFORM pg_temp.pg();
  END LOOP;
  IF ok = 4 AND (SELECT resultado FROM public.registros_campo WHERE client_id = c_conf) = 'conflito' THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: conflito não é apagável (operador, supervisor, gestor e administrador)';
  ELSE RAISE NOTICE 'FALHOU: conflito apagável (% de 4 bloqueados)', ok; END IF;

  -- Tratar conflito: supervisor com justificativa; uma vez só.
  PERFORM qa.como('qa_supervisor');
  BEGIN PERFORM public.tratar_conflito(c_conf, 'curto'); RAISE NOTICE 'FALHOU: justificativa curta aceita';
  EXCEPTION WHEN raise_exception THEN NULL; END;
  PERFORM public.tratar_conflito(c_conf, 'conferido com a equipe pelo rádio');
  BEGIN PERFORM public.tratar_conflito(c_conf, 'conferido com a equipe de novo'); RAISE NOTICE 'FALHOU: tratado duas vezes';
  EXCEPTION WHEN raise_exception THEN NULL; END;
  BEGIN PERFORM public.tratar_conflito(c_um, 'registro aplicado, não é conflito'); RAISE NOTICE 'FALHOU: tratou registro aplicado';
  EXCEPTION WHEN raise_exception THEN NULL; END;
  PERFORM pg_temp.pg();
  IF (SELECT tratado_por = qa.usuario('qa_supervisor') AND tratamento = 'conferido com a equipe pelo rádio' AND resultado = 'conflito'
        FROM public.registros_campo WHERE client_id = c_conf)
     AND EXISTS (SELECT 1 FROM public.logs_auditoria WHERE acao = 'TRATAR_CONFLITO_OFFLINE' AND registro_id = c_conf) THEN
    RAISE NOTICE 'PASSOU: supervisor marca o conflito como tratado com justificativa (mínimo de 10 caracteres), uma vez só, com auditoria; o registro continua no livro';
  ELSE RAISE NOTICE 'FALHOU: tratar conflito'; END IF;
END $$;
ROLLBACK;

-- ── 8. Limite de avisos: 20 conflitos forjados em 1 minuto geram no máximo 5 ─────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; i int; n int; t int; lim int;
BEGIN
  PERFORM qa.como('qa_um');
  FOR i IN 1..20 LOOP
    PERFORM public.registrar_campo(gen_random_uuid(), 'linhas', pg_temp.env_checkin(e, 1, 'retornando'), pg_temp.versao(e), now(), NULL);
  END LOOP;
  PERFORM pg_temp.pg();
  SELECT count(DISTINCT evento_chave) INTO n FROM public.notificacoes WHERE escolta_id = e AND evento_chave LIKE 'conflito:%';
  SELECT count(*) INTO t FROM public.avisos_telegram WHERE escolta_id = e AND evento_chave LIKE 'conflito:%';
  SELECT count(*) INTO lim FROM public.registros_campo WHERE escolta_id = e AND aviso = 'limitado';
  IF (SELECT count(*) FROM public.registros_campo WHERE escolta_id = e AND resultado = 'conflito') = 20 AND n = 5 AND lim = 15
     AND t <= 5 THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: 20 conflitos forjados em 1 minuto: 20 no livro, só 5 avisos na Central (% no Telegram), 15 marcados como limitados', t;
  ELSE RAISE NOTICE 'FALHOU: limite de avisos: % avisos, % limitados', n, lim; END IF;
END $$;
ROLLBACK;

-- ── 9. Demais tipos do envelope: wizard (checklists, respostas, fotos, KM), presença, G4 ─
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '10 min', 'agendada', 'qa_um', 2)::text, true);
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; v int; r jsonb; ck uuid := gen_random_uuid(); ck2 uuid := gen_random_uuid();
        f1 uuid := gen_random_uuid(); f2 uuid := gen_random_uuid(); tf uuid; p jsonb; c_f uuid := gen_random_uuid();
BEGIN
  v := pg_temp.versao(e);
  SELECT id INTO tf FROM public.dom_tipos_foto ORDER BY 1 LIMIT 1;
  -- Presença na base pela RPC da 204 (janela do mural aberta: prevista daqui a 10 min).
  PERFORM qa.como('qa_um');
  r := public.registrar_campo(gen_random_uuid(), 'presenca_base', jsonb_build_object('escolta_id', e, 'status_esperado', 'agendada',
         'presenca', jsonb_build_object('latitude', -22.9, 'longitude', -43.3, 'precisao', 12)), v, now() - interval '3 min', NULL);
  PERFORM pg_temp.pg();
  IF r ->> 'resultado' = 'aplicado' AND (SELECT count(*) FROM public.mural_presencas WHERE escolta_id = e AND anulado_em IS NULL) = 1 THEN
    RAISE NOTICE 'PASSOU: presença na base pelo envelope (confirmar_presenca_base da 204) aplicada';
  ELSE RAISE NOTICE 'FALHOU: presença: %', r; END IF;
  -- Pré-início pela etapa, depois o wizard: checklists, respostas, fotos, KM e a partida numa só.
  PERFORM qa.como('qa_um');
  r := public.registrar_campo(gen_random_uuid(), 'etapa', jsonb_build_object('escolta_id', e,
         'etapa', jsonb_build_object('status_atual', 'agendada', 'status_novo', 'em_pre_inicio')), v, now() - interval '2 min', NULL);
  p := jsonb_build_object('escolta_id', e, 'escolta_veiculo_id', pg_temp.ev(e, 1),
    'linhas', jsonb_build_object(
      'fotos', jsonb_build_array(
        jsonb_build_object('id', f1, 'caminho_arquivo', 'campo/' || e || '/' || f1 || '.jpg', 'tipo_foto_id', tf, 'data_hora_captura', now() - interval '90 s', 'carimbo_aplicado', true),
        jsonb_build_object('id', f2, 'caminho_arquivo', 'checklists/' || e || '/' || f2 || '.jpg', 'tipo_foto_id', tf, 'data_hora_captura', now() - interval '80 s', 'carimbo_aplicado', true)),
      'checklists', jsonb_build_array(
        jsonb_build_object('id', ck, 'escolta_veiculo_id', pg_temp.ev(e, 1), 'tipo', 'material', 'concluido', true, 'data_conclusao', now() - interval '70 s'),
        jsonb_build_object('id', ck2, 'escolta_veiculo_id', pg_temp.ev(e, 1), 'tipo', 'viatura', 'concluido', true, 'data_conclusao', now() - interval '70 s')),
      'checklist_respostas', jsonb_build_array(
        jsonb_build_object('id', gen_random_uuid(), 'checklist_id', ck, 'descricao_item', 'Rádio', 'conforme', true, 'foto_id', f1),
        jsonb_build_object('id', gen_random_uuid(), 'checklist_id', ck2, 'descricao_item', 'Pneus', 'conforme', true, 'foto_id', f2)),
      'km', jsonb_build_array(jsonb_build_object('escolta_veiculo_id', pg_temp.ev(e, 1), 'quilometragem_saida', 12345),
                              jsonb_build_object('escolta_veiculo_id', pg_temp.ev(e, 2), 'quilometragem_saida', 22222))),
    'etapa', jsonb_build_object('status_atual', 'em_pre_inicio', 'status_novo', 'em_andamento', 'tipo_ponto_todas', pg_temp.tp('base_saida'),
      'pontos', (SELECT jsonb_agg(jsonb_build_object('id', gen_random_uuid(), 'escolta_veiculo_id', ev.id, 'tipo_ponto_id', pg_temp.tp('base_saida'),
                   'data_hora', now() - interval '60 s', 'sem_sinal_gps', true, 'criado_offline', true)) FROM public.escolta_veiculos ev WHERE ev.escolta_id = e)));
  r := public.registrar_campo(c_f, 'etapa', p, v, now() - interval '60 s', NULL);
  PERFORM pg_temp.pg();
  IF r ->> 'resultado' = 'aplicado' AND (SELECT status FROM public.escoltas WHERE id = e) = 'em_andamento'
     AND (SELECT count(*) FROM public.fotos WHERE id IN (f1, f2) AND carimbo_aplicado AND criado_por = qa.usuario('qa_um')) = 2
     AND (SELECT count(*) FROM public.checklist_respostas WHERE checklist_id IN (ck, ck2)) = 2
     AND (SELECT string_agg(quilometragem_saida::int::text, ',' ORDER BY criado_em) FROM public.escolta_veiculos WHERE escolta_id = e) = '12345,22222'
     AND (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
           WHERE ev.escolta_id = e AND pc.criado_offline) = 2 THEN
    RAISE NOTICE 'PASSOU: wizard pelo envelope: 2 fotos com o carimbo e o autor, 2 checklists e respostas, KM das 2 viaturas (só as colunas de KM) e a partida com os pontos de base, numa transação';
  ELSE RAISE NOTICE 'FALHOU: wizard: % (status %, fotos %, respostas %, km %, offline %)', r, (SELECT status FROM public.escoltas WHERE id = e),
    (SELECT count(*) FROM public.fotos WHERE id IN (f1, f2) AND carimbo_aplicado AND criado_por = qa.usuario('qa_um')),
    (SELECT count(*) FROM public.checklist_respostas WHERE checklist_id IN (ck, ck2)),
    (SELECT string_agg(quilometragem_saida::text, ',' ORDER BY criado_em) FROM public.escolta_veiculos WHERE escolta_id = e),
    (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id WHERE ev.escolta_id = e AND pc.criado_offline); END IF;
  -- Supervisor (G4, fora do efetivo) registra pela fila.
  PERFORM qa.como('qa_supervisor');
  r := public.registrar_campo(gen_random_uuid(), 'linhas', pg_temp.env_checkin(e, 2, 'em_andamento'), v, now(), NULL);
  PERFORM pg_temp.pg();
  IF r ->> 'resultado' = 'aplicado' THEN RAISE NOTICE 'PASSOU: supervisor (G4, fora do efetivo) registra pelo envelope, com a RLS dele';
  ELSE RAISE NOTICE 'FALHOU: G4: %', r; END IF;
  -- Configuração e contagem do aparelho.
  PERFORM qa.como('qa_um');
  PERFORM public.informar_pendentes('aparelho-teste-l', 3);
  PERFORM public.informar_pendentes('aparelho-teste-l', 0);
  r := public.config_offline();
  PERFORM pg_temp.pg();
  IF (SELECT pendentes FROM public.registros_campo_aparelhos WHERE aparelho_id = 'aparelho-teste-l' AND auth_user_id = (SELECT id FROM auth.users WHERE email = 'qa_um@operador.local')) = 0
     AND (r ->> 'offline_ligado')::boolean AND r ? 'telefone_central' THEN
    RAISE NOTICE 'PASSOU: informar_pendentes grava a contagem do aparelho (3, depois 0) e config_offline devolve a chave e o telefone da central';
  ELSE RAISE NOTICE 'FALHOU: aparelho ou configuração: %', r; END IF;
END $$;
ROLLBACK;

-- ── 10. Recusa da RLS ou trigger vira conflito (recusado), nunca erro perdido ───────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; r jsonb; p jsonb;
BEGIN
  -- Ponto em nome de outro usuário (RESTRICTIVE pontos_insert_autor): recusado pela RLS.
  p := pg_temp.env_checkin(e, 1, 'em_andamento');
  p := jsonb_set(p, '{linhas,pontos_controle,0,lancado_por}', to_jsonb(qa.usuario('qa_dois')));
  PERFORM qa.como('qa_um');
  r := public.registrar_campo(gen_random_uuid(), 'linhas', p, pg_temp.versao(e), now(), NULL);
  PERFORM pg_temp.pg();
  IF r ->> 'resultado' = 'conflito' AND r ->> 'motivo' = 'recusado'
     AND (SELECT count(*) FROM public.pontos_controle WHERE escolta_veiculo_id = pg_temp.ev(e, 1) AND tipo_ponto_id = pg_temp.tp('parada')) = 0 THEN
    RAISE NOTICE 'PASSOU: linha recusada pela RLS (ponto em nome de outro) vira conflito recusado no livro, com o payload; nada gravado';
  ELSE RAISE NOTICE 'FALHOU: recusa da RLS: %', r; END IF;
END $$;
ROLLBACK;
