-- Lote 2026-10, onda I (poder total de gestor e administrador): migrations 213, 214 e 218.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa), com os blocos 1 e 2 aplicados.
-- Esperado: só PASSOU e BLOQUEADO CORRETAMENTE. Cada bloco roda numa transação desfeita.
\set QUIET on
\pset tuples_only on

-- ── Auxiliares da sessão (pg_temp, somem no fim) ───────────────────────────────────
-- Volta a ser postgres SEM usuário final (RESET ROLE não limpa as claims do JWT).
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
-- Ponto de controle na viatura n, como a identidade atual.
CREATE FUNCTION pg_temp.ponto(p_esc uuid, p_n int, p_tipo text, p_quando timestamptz DEFAULT clock_timestamp()) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, sem_sinal_gps, lancado_por)
  VALUES (pg_temp.ev(p_esc, p_n), pg_temp.tp(p_tipo), p_quando, true, coalesce(public.get_meu_usuario_id(), qa.usuario('qa_administrador')))
  RETURNING id INTO v;
  RETURN v;
END $$;
-- Avança pela tela (registrar_etapa_escolta, 207/214/218) até a etapa pedida, com os
-- checklists do pré-início, KM, o checklist de entrega e um ponto por viatura em cada etapa.
CREATE FUNCTION pg_temp.jornada(p_esc uuid, p_ate text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  seq text[] := ARRAY['agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino', 'no_destino',
                      'em_transito_retorno', 'retornando', 'na_base', 'finalizada'];
  v_status text; v_prox text; v_tipo text; v_pontos jsonb; r record; v_resp uuid;
BEGIN
  v_resp := coalesce(public.get_meu_usuario_id(), qa.usuario('qa_administrador'));
  LOOP
    SELECT status INTO v_status FROM public.escoltas WHERE id = p_esc;
    EXIT WHEN v_status = p_ate OR v_status IS NULL;
    v_prox := seq[array_position(seq, v_status) + 1];
    IF v_prox = 'em_andamento' THEN
      FOR r IN SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_esc LOOP
        INSERT INTO public.checklists (escolta_veiculo_id, tipo, concluido, responsavel_id, data_inicio)
        VALUES (r.id, 'viatura', true, v_resp, clock_timestamp()), (r.id, 'material', true, v_resp, clock_timestamp());
        UPDATE public.escolta_veiculos SET quilometragem_saida = 1000 WHERE id = r.id;
      END LOOP;
    ELSIF v_prox = 'na_base' THEN
      UPDATE public.escolta_veiculos SET quilometragem_retorno = 1100 WHERE escolta_id = p_esc;
    ELSIF v_prox = 'finalizada' THEN
      FOR r IN SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_esc LOOP
        INSERT INTO public.checklists (escolta_veiculo_id, tipo, concluido, responsavel_id, data_inicio)
        VALUES (r.id, 'viatura', true, v_resp, clock_timestamp());          -- entrega
      END LOOP;
    END IF;
    v_tipo := pg_temp.tipo_da_etapa(v_prox);
    v_pontos := CASE WHEN v_tipo IS NULL THEN '[]'::jsonb ELSE
      (SELECT jsonb_agg(jsonb_build_object('escolta_veiculo_id', ev.id, 'tipo_ponto_id', pg_temp.tp(v_tipo),
                                           'data_hora', clock_timestamp(), 'sem_sinal_gps', true, 'lancado_por', v_resp))
         FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_esc) END;
    PERFORM public.registrar_etapa_escolta(p_esc, v_pontos, v_status, v_prox, 'teste onda I', NULL, NULL,
      CASE WHEN v_prox = 'finalizada' THEN 'relatório de teste' END, NULL, pg_temp.tp(v_tipo));
  END LOOP;
END $$;
-- Linhas das 9 tabelas de campo da escolta (todas, ou só as válidas).
CREATE FUNCTION pg_temp.contar(p_esc uuid, p_validos boolean) RETURNS int LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
           WHERE ev.escolta_id = p_esc AND (NOT p_validos OR pc.anulado_em IS NULL))
       + (SELECT count(*) FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id
           WHERE ev.escolta_id = p_esc AND (NOT p_validos OR c.anulado_em IS NULL))
       + (SELECT count(*) FROM public.ocorrencias WHERE escolta_id = p_esc AND (NOT p_validos OR anulado_em IS NULL))
       + (SELECT count(*) FROM public.emergencias WHERE escolta_id = p_esc AND (NOT p_validos OR anulado_em IS NULL))
       + (SELECT count(*) FROM public.presencas WHERE escolta_id = p_esc AND (NOT p_validos OR anulado_em IS NULL))
       + (SELECT count(*) FROM public.mural_presencas WHERE escolta_id = p_esc AND (NOT p_validos OR anulado_em IS NULL))
       + (SELECT count(*) FROM public.escolta_status_historico WHERE escolta_id = p_esc AND (NOT p_validos OR anulado_em IS NULL))
       + (SELECT count(*) FROM public.rastreamento r JOIN public.escolta_veiculos ev ON ev.id = r.escolta_veiculo_id
           WHERE ev.escolta_id = p_esc AND (NOT p_validos OR r.anulado_em IS NULL))
       + (SELECT count(*) FROM public.atualizacoes_status WHERE escolta_id = p_esc AND (NOT p_validos OR anulado_em IS NULL))::int
$$;

-- ── Estrutura, privilégios e funções reescritas em cadeia (18.4) ─────────────────────
BEGIN;
DO $$
DECLARE n int; v_lista text;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns WHERE table_schema = 'public'
     AND column_name IN ('anulado_em', 'anulado_por', 'motivo_anulacao', 'anulacao_id', 'status_escolta_no_registro')
     AND table_name IN ('pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                        'atualizacoes_status', 'rastreamento', 'escolta_status_historico');
  IF n = 45 THEN RAISE NOTICE 'PASSOU: anulação e carimbo de etapa nas 9 tabelas de campo (45 colunas)';
  ELSE RAISE NOTICE 'FALHOU: % de 45 colunas de anulação e carimbo', n; END IF;

  SELECT count(*) INTO n FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'escoltas'
     AND column_name IN ('arquivada_em', 'arquivada_por', 'motivo_arquivamento', 'reiniciada_em', 'versao_gestao');
  IF n = 5 AND (SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_carimbar_etapa_%') = 9
     AND (SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_travar_colunas_gestao_%') = 10
     AND (SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_impedir_edicao_escolta_iniciada') = 3 THEN
    RAISE NOTICE 'PASSOU: colunas da gestão em escoltas; triggers de carimbo (9), de trava (10) e de edição iniciada (3)';
  ELSE RAISE NOTICE 'FALHOU: estrutura da 213 e 214 incompleta (% colunas)', n; END IF;

  -- 18.8, item 7: chave estrangeira SEM ação (NO ACTION) para usuarios.
  SELECT count(*) INTO n FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
   WHERE c.contype = 'f' AND c.confrelid = 'public.usuarios'::regclass AND c.confdeltype = 'a'
     AND a.attname IN ('anulado_por', 'arquivada_por', 'concluida_por', 'feito_por');
  IF n = 13 THEN RAISE NOTICE 'PASSOU: anulado_por, arquivada_por, concluida_por e feito_por com FK sem ação para usuarios (13)';
  ELSE RAISE NOTICE 'FALHOU: % FKs sem ação para usuarios (esperado 13)', n; END IF;

  SELECT string_agg(p.proname, ', ') INTO v_lista FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace
     AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  SELECT count(*) INTO n FROM pg_proc WHERE pronamespace = 'lote_interno'::regnamespace;
  IF v_lista IS NULL AND n >= 24 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: nenhuma das % funções do lote_interno executável por anon ou authenticated', n;
  ELSE RAISE NOTICE 'FALHOU: funções do lote_interno executáveis: %', v_lista; END IF;

  SELECT count(*) INTO n FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('editar_escolta', 'pendencias_da_escolta', 'concluir_escolta_antecipada', 'voltar_etapa_escolta',
                       'zerar_escolta', 'arquivar_escolta', 'recuperar_escolta')
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
     AND p.prosecdef;
  IF n = 7 THEN RAISE NOTICE 'PASSOU: as 7 RPCs da gestão existem, SECURITY DEFINER, só para authenticated';
  ELSE RAISE NOTICE 'FALHOU: % de 7 RPCs com o privilégio certo', n; END IF;

  -- Cadeia: registrar_etapa_escolta 207, 214 e 218.
  IF (SELECT prosrc LIKE '%pc.anulado_em IS NULL%' AND prosrc LIKE '%v_arquivada IS NOT NULL%'
             AND prosrc LIKE '%escolta.historico_rpc%' AND prosrc LIKE '%coalesce(public.get_meu_usuario_id(), x.lancado_por)%'
        FROM pg_proc WHERE oid = 'public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid)'::regprocedure) THEN
    RAISE NOTICE 'PASSOU: registrar_etapa_escolta final com filtro de anulado, recusa de arquivada, historico_rpc e autor da sessão';
  ELSE RAISE NOTICE 'FALHOU: registrar_etapa_escolta sem um dos acréscimos de 214 e 218'; END IF;
  -- Cadeia: funções do mural 204, 217 e 218.
  SELECT string_agg(f, ', ') INTO v_lista FROM unnest(ARRAY[
      'public.assumir_escolta(uuid, uuid[], uuid, text)', 'public.puxar_escolta(uuid)', 'public.devolver_escolta(uuid)',
      'public.incluir_vigilante_na_minha_escolta(uuid, uuid)', 'public.confirmar_presenca_base(uuid, numeric, numeric, numeric)',
      'public.listar_pedidos_mural(timestamptz)', 'public.mural_info(uuid[])', 'public._conflito_comandante(uuid, uuid)',
      'public._executar_substituicao(uuid, text)', 'public.enviar_avisos_telegram()']) f
   WHERE NOT (SELECT prosrc LIKE '%arquivada_em%' FROM pg_proc WHERE oid = f::regprocedure);
  IF v_lista IS NULL AND (SELECT prosrc LIKE '%lote_interno.notificar%' FROM pg_proc WHERE oid = 'public._avisar_app(uuid, text, uuid[], text, text, uuid)'::regprocedure)
     AND (SELECT prosrc LIKE '%anulado_em IS NULL%' FROM pg_proc WHERE oid = 'public._presenca_da_equipe(uuid)'::regprocedure) THEN
    RAISE NOTICE 'PASSOU: funções do mural e envio do Telegram com o filtro de arquivada, sem perder o lote_interno.notificar da 217';
  ELSE RAISE NOTICE 'FALHOU: sem filtro de arquivada em: %', v_lista; END IF;
  -- Cadeia: alertas 208, 212 e 214.
  IF (SELECT prosrc LIKE '%arquivada_em IS NULL%' AND prosrc LIKE '%anulado_em IS NULL%' AND prosrc LIKE '%checkin_telegram_pelo_cron%'
        FROM pg_proc WHERE oid = 'lote_interno.gerar_avisos_checkin(timestamptz)'::regprocedure)
     AND (SELECT prosrc LIKE '%arquivada%' AND prosrc LIKE '%anulado_em IS NULL%' AND prosrc LIKE '%avisos_reservados%'
        FROM pg_proc WHERE oid = 'lote_interno.enfileirar_alerta_checkin(uuid)'::regprocedure)
     AND (SELECT prosrc LIKE '%arquivada_em IS NULL%' AND prosrc LIKE '%anulado_em IS NULL%' FROM pg_proc WHERE oid = 'public.reservar_alertas_checkin()'::regprocedure)
     AND (SELECT prosrc LIKE '%anulado_em IS NULL%' FROM pg_proc WHERE oid = 'public.reservar_aviso_presenca(uuid)'::regprocedure)
     AND (SELECT prosrc LIKE '%anulado_em IS NULL%' FROM pg_proc WHERE oid = 'public.exigir_ponto_transito_retorno()'::regprocedure)
     AND (SELECT prosrc LIKE '%anulado_em IS NULL%' FROM pg_proc WHERE oid = 'public.verificar_checklist_pendente()'::regprocedure) THEN
    RAISE NOTICE 'PASSOU: alertas (208, 212, 214) e triggers de status com os filtros de arquivada e de anulado';
  ELSE RAISE NOTICE 'FALHOU: alerta ou trigger de status sem o filtro da onda I'; END IF;

  -- Ordem real das BEFORE UPDATE em escoltas (alfabética).
  SELECT string_agg(tgname, ',' ORDER BY tgname) INTO v_lista FROM pg_trigger
   WHERE tgrelid = 'public.escoltas'::regclass AND NOT tgisinternal AND (tgtype & 2) = 2 AND (tgtype & 16) = 16;
  IF position('tr_impedir_edicao_escolta_iniciada' IN v_lista) < position('tr_impedir_edicao_por_operador' IN v_lista)
     AND position('tr_impedir_edicao_por_operador' IN v_lista) < position('tr_verificar_checklist_pendente' IN v_lista) THEN
    RAISE NOTICE 'PASSOU: ordem real das BEFORE UPDATE em escoltas: edição iniciada, depois a do operador, depois o checklist (%)', v_lista;
  ELSE RAISE NOTICE 'FALHOU: ordem das triggers: %', v_lista; END IF;
END $$;
ROLLBACK;

-- ── Carimbo, via_rpc e autor do ponto ──────────────────────────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 2)::text, true);
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; r record; n int;
BEGIN
  -- Gestor FORA da equipe percorre até no_destino pela RPC da tela (critério 1).
  PERFORM qa.como('qa_gestor');
  PERFORM pg_temp.jornada(e, 'no_destino');
  -- Check-in (parada) e ocorrência pelo gestor, direto como a tela, com lancado_por nulo.
  INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, sem_sinal_gps, lancado_por, observacoes)
  VALUES (pg_temp.ev(e, 2), pg_temp.tp('parada'), clock_timestamp(), true, NULL, '{"tipo":"reporte_periodico"}');
  INSERT INTO public.ocorrencias (escolta_id, tipo_ocorrencia_id, descricao, data_hora, registrado_por, status_escolta_no_registro)
  VALUES (e, (SELECT id FROM public.dom_tipos_ocorrencia LIMIT 1), 'ocorrência do teste', clock_timestamp(), qa.usuario('qa_gestor'), 'finalizada');
  PERFORM pg_temp.pg();
  SELECT count(*) INTO n FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
   WHERE ev.escolta_id = e AND pc.lancado_por <> qa.usuario('qa_gestor');
  IF n = 0 AND (SELECT status FROM public.escoltas WHERE id = e) = 'no_destino'
     AND (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id WHERE ev.escolta_id = e) = 9
     AND (SELECT count(*) FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id WHERE ev.escolta_id = e) = 4 THEN
    RAISE NOTICE 'PASSOU: gestor fora da equipe registra pontos, check-in, checklists e etapas; lancado_por = gestor em todos (nulo preenchido no servidor)';
  ELSE RAISE NOTICE 'FALHOU: gestor fora da equipe: % pontos com outro autor, status %', n, (SELECT status FROM public.escoltas WHERE id = e); END IF;
  SELECT status_escolta_no_registro AS c INTO r FROM public.ocorrencias WHERE escolta_id = e;
  IF r.c = 'no_destino' AND (SELECT status_escolta_no_registro FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
                              WHERE ev.escolta_id = e AND pc.tipo_ponto_id = pg_temp.tp('destino') LIMIT 1) = 'em_transito_destino' THEN
    RAISE NOTICE 'PASSOU: carimbo de etapa pelo servidor (ocorrência mandada com "finalizada" saiu no_destino; ponto do destino carimbado em_transito_destino)';
  ELSE RAISE NOTICE 'FALHOU: carimbo %', r.c; END IF;
  SELECT count(*) FILTER (WHERE via_rpc) AS sim, count(*) AS todos INTO r FROM public.escolta_status_historico WHERE escolta_id = e;
  IF r.sim = r.todos AND r.todos = 5 THEN RAISE NOTICE 'PASSOU: histórico gravado por registrar_etapa_escolta sai com via_rpc = true (% linhas)', r.todos;
  ELSE RAISE NOTICE 'FALHOU: via_rpc % de %', r.sim, r.todos; END IF;
  -- Linha gravada direto pelo cliente, mesmo pedindo via_rpc = true, fica false.
  PERFORM qa.como('qa_um');
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora, via_rpc)
  VALUES (e, 'agendada', 'no_destino', qa.usuario('qa_um'), now() - interval '2 days', true);
  PERFORM pg_temp.pg();
  IF (SELECT via_rpc FROM public.escolta_status_historico WHERE escolta_id = e AND data_hora < now() - interval '1 day') = false THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: histórico gravado direto pelo cliente fica via_rpc = false, mesmo mandando true';
  ELSE RAISE NOTICE 'FALHOU: cliente gravou via_rpc = true'; END IF;
END $$;
-- Ponto em nome de outro (RESTRICTIVE pontos_insert_autor).
SELECT qa.como('qa_gestor');
DO $$
BEGIN
  INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, sem_sinal_gps, lancado_por)
  VALUES (pg_temp.ev(current_setting('t.esc')::uuid, 1), pg_temp.tp('parada'), now(), true, qa.usuario('qa_um'));
  RAISE NOTICE 'FALHOU: gestor gravou ponto em nome do operador';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: ponto em nome de outro usuário (pontos_insert_autor)';
END $$;
SELECT pg_temp.pg();
ROLLBACK;

-- ── Operador, supervisor e central sem os poderes da gestão, inclusive pela API ──────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_transito_destino');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; u text; f text; n int; v_ok int := 0; v_tot int := 0;
BEGIN
  FOREACH u IN ARRAY ARRAY['qa_um', 'qa_supervisor', 'qa_central'] LOOP
    PERFORM qa.como(u);
    FOREACH f IN ARRAY ARRAY[
        format('SELECT public.voltar_etapa_escolta(%L, %L, false)', e, 'motivo do teste da onda I'),
        format('SELECT public.voltar_etapa_escolta(%L, NULL, true)', e),
        format('SELECT public.zerar_escolta(%L, %L, false)', e, 'motivo do teste da onda I'),
        format('SELECT public.concluir_escolta_antecipada(%L, %L)', e, 'motivo do teste da onda I'),
        format('SELECT public.pendencias_da_escolta(%L)', e),
        format('SELECT public.arquivar_escolta(%L, %L)', e, 'motivo do teste da onda I'),
        format('SELECT public.recuperar_escolta(%L, %L)', e, 'motivo do teste da onda I'),
        format('SELECT public.editar_escolta(%L, %L::jsonb, NULL, %L)', e, '{"origem_endereco": "mudado pelo teste"}', 'motivo do teste da onda I')] LOOP
      v_tot := v_tot + 1;
      BEGIN
        EXECUTE f;
        RAISE NOTICE 'FALHOU: % executou %', u, f;
      EXCEPTION WHEN insufficient_privilege OR raise_exception THEN v_ok := v_ok + 1;
      END;
    END LOOP;
    PERFORM pg_temp.pg();
  END LOOP;
  IF v_ok = v_tot THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador, supervisor e central recusados nas 7 RPCs da gestão e na edição de escolta iniciada (% chamadas)', v_tot;
  ELSE RAISE NOTICE 'FALHOU: % de % chamadas recusadas', v_ok, v_tot; END IF;

  -- UPDATE direto: status para trás, colunas da gestão, edição de iniciada.
  v_ok := 0; v_tot := 0;
  FOREACH u IN ARRAY ARRAY['qa_um', 'qa_supervisor', 'qa_central', 'qa_gestor'] LOOP
    PERFORM qa.como(u);
    FOREACH f IN ARRAY ARRAY[
        format('UPDATE public.escoltas SET status = %L WHERE id = %L', 'na_origem', e),
        format('UPDATE public.escoltas SET versao_gestao = 9 WHERE id = %L', e),
        format('UPDATE public.escoltas SET arquivada_em = now() WHERE id = %L', e),
        format('UPDATE public.pontos_controle SET anulado_em = now() WHERE escolta_veiculo_id = %L', pg_temp.ev(e, 1)),
        format('UPDATE public.escolta_status_historico SET via_rpc = true WHERE escolta_id = %L', e)] LOOP
      v_tot := v_tot + 1;
      BEGIN
        EXECUTE f;
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n = 0 THEN v_ok := v_ok + 1;   -- sem policy de UPDATE: nenhuma linha muda
        ELSE RAISE NOTICE 'FALHOU: % mudou % linhas com %', u, n, f; END IF;
      EXCEPTION WHEN insufficient_privilege OR raise_exception THEN v_ok := v_ok + 1;
      END;
    END LOOP;
    PERFORM pg_temp.pg();
  END LOOP;
  IF v_ok = v_tot THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: UPDATE direto de status para trás, versao_gestao, arquivada_*, anulado_* e via_rpc recusado para operador, supervisor, central e gestor (% casos)', v_tot;
  ELSE RAISE NOTICE 'FALHOU: % de % UPDATEs diretos recusados', v_ok, v_tot; END IF;

  v_ok := 0;
  FOREACH u IN ARRAY ARRAY['qa_supervisor', 'qa_central'] LOOP
    PERFORM qa.como(u);
    BEGIN
      UPDATE public.escoltas SET destino_endereco = 'outro destino' WHERE id = e;
      RAISE NOTICE 'FALHOU: % editou escolta iniciada direto', u;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1;
    END;
    BEGIN
      DELETE FROM public.escolta_veiculos WHERE escolta_id = e;
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n = 0 THEN v_ok := v_ok + 1; ELSE RAISE NOTICE 'FALHOU: % tirou viatura de escolta iniciada', u; END IF;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1;
    END;
    -- KM e periodicidade continuam com eles (S10).
    UPDATE public.escolta_veiculos SET quilometragem_saida = 1001 WHERE escolta_id = e;
    UPDATE public.escoltas SET periodicidade_checkin_min = 30 WHERE id = e;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 1 THEN v_ok := v_ok + 1; END IF;
    PERFORM pg_temp.pg();
  END LOOP;
  IF v_ok = 6 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: supervisor e central não editam escolta iniciada nem as viaturas (S10); KM e periodicidade continuam livres';
  ELSE RAISE NOTICE 'FALHOU: S10 com % de 6', v_ok; END IF;
END $$;
ROLLBACK;

-- ── Dupla guarda da máquina de estados e da trava das colunas ───────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'no_destino', 'qa_um', 1)::text, true);
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid;
BEGIN
  PERFORM qa.como('qa_gestor');
  BEGIN
    UPDATE public.escoltas SET status = 'em_transito_destino' WHERE id = e;
    RAISE NOTICE 'FALHOU: gestor voltou o status direto, sem a variável';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: gestor sem a variável de transação não volta o status direto';
  END;
  PERFORM pg_temp.pg();
  PERFORM qa.como('qa_um');
  PERFORM set_config('escolta.transicao_especial', 'reset', true);
  PERFORM set_config('escolta.transicao_destino', 'em_transito_destino', true);
  PERFORM set_config('escolta.rpc_gestao', 'on', true);
  BEGIN
    UPDATE public.escoltas SET status = 'em_transito_destino' WHERE id = e;
    RAISE NOTICE 'FALHOU: operador com a variável ligada voltou o status';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador com a variável ligada não volta o status (perfil)';
  END;
  BEGIN
    UPDATE public.pontos_controle SET anulado_em = now() WHERE escolta_veiculo_id = pg_temp.ev(e, 1);
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador com escolta.rpc_gestao ligada não anula (sem linha visível para UPDATE)';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador com escolta.rpc_gestao ligada não anula (trava das colunas)';
  END;
  BEGIN
    INSERT INTO public.ocorrencias (escolta_id, tipo_ocorrencia_id, descricao, data_hora, registrado_por, anulado_em)
    VALUES (e, (SELECT id FROM public.dom_tipos_ocorrencia LIMIT 1), 'x', now(), qa.usuario('qa_um'), now());
    RAISE NOTICE 'FALHOU: operador gravou ocorrência já anulada';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: INSERT com anulado_em preenchido recusado (só nulo e 0 passam)';
  END;
  PERFORM pg_temp.pg();
  PERFORM qa.como('qa_gestor');
  PERFORM set_config('escolta.transicao_especial', 'reset', true);
  PERFORM set_config('escolta.transicao_destino', 'na_origem', true);
  BEGIN
    UPDATE public.escoltas SET status = 'em_transito_destino' WHERE id = e;
    RAISE NOTICE 'FALHOU: reset para destino diferente do calculado aceito';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: com a variável, a trigger só aceita o destino calculado pela RPC';
  END;
  PERFORM pg_temp.pg();
END $$;
ROLLBACK;

-- ── Coluna gerada e UF (simuladas) não travam o avanço de status ───────────────────
BEGIN;
ALTER TABLE public.escoltas ADD COLUMN teste_i_uf text;
ALTER TABLE public.escoltas ADD COLUMN teste_i_gerada boolean GENERATED ALWAYS AS (teste_i_uf <> 'RJ') STORED;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'em_andamento', 'qa_um', 1)::text, true);
UPDATE public.escoltas SET teste_i_uf = 'SP' WHERE id = current_setting('t.esc')::uuid;
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; u text; s text; v_ok int := 0;
BEGIN
  FOREACH u IN ARRAY ARRAY['qa_um', 'qa_supervisor', 'qa_central'] LOOP
    SELECT CASE status WHEN 'em_andamento' THEN 'na_origem' WHEN 'na_origem' THEN 'em_transito_destino' ELSE 'no_destino' END INTO s
      FROM public.escoltas WHERE id = e;
    PERFORM qa.como(u);
    UPDATE public.escoltas SET status = s WHERE id = e;
    PERFORM pg_temp.pg();
    IF (SELECT status FROM public.escoltas WHERE id = e) = s THEN v_ok := v_ok + 1; END IF;
  END LOOP;
  IF v_ok = 3 AND (SELECT teste_i_gerada FROM public.escoltas WHERE id = e) THEN
    RAISE NOTICE 'PASSOU: escolta iniciada com UF e coluna gerada calculada: operador, supervisor e central avançam o status';
  ELSE RAISE NOTICE 'FALHOU: avanço com coluna gerada % de 3', v_ok; END IF;
END $$;
ROLLBACK;

-- ── Edição de escolta em andamento pela gestão (por diferença) ──────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_transito_destino');
UPDATE public.escolta_veiculos SET abastecimento_litros = 40, abastecimento_valor = 250 WHERE escolta_id = current_setting('t.esc')::uuid;
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; ev1 uuid := pg_temp.ev(current_setting('t.esc')::uuid, 1); ev2 uuid; n0 int; n1 int; r jsonb; v_aud record; v_ver int;
BEGIN
  n0 := pg_temp.contar(e, false);
  SELECT versao_gestao INTO v_ver FROM public.escoltas WHERE id = e;
  PERFORM qa.como('qa_gestor');
  r := public.editar_escolta(e,
         jsonb_build_object('data_hora_prevista', now() + interval '1 hour', 'destino_endereco', 'Novo destino do teste',
                            'metadados', jsonb_build_object('observacoes', 'observação mudada em andamento')),
         jsonb_build_array(
           jsonb_build_object('escolta_veiculo_id', ev1, 'veiculo_id', '00000000-0000-4000-a000-0000000000f1',
                              'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'comandante'))),
           jsonb_build_object('veiculo_id', '00000000-0000-4000-a000-0000000000f2',
                              'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_dois'), 'papel_na_escolta', 'comandante')))),
         'Cliente pediu mudança do destino durante a escolta');
  PERFORM pg_temp.pg();
  n1 := pg_temp.contar(e, false);
  IF n1 = n0 AND (SELECT count(*) FROM public.escolta_veiculos WHERE escolta_id = e) = 2
     AND (SELECT destino_endereco FROM public.escoltas WHERE id = e) = 'Novo destino do teste'
     AND (SELECT metadados ->> 'observacoes' FROM public.escoltas WHERE id = e) = 'observação mudada em andamento'
     AND (SELECT abastecimento_litros FROM public.escolta_veiculos WHERE id = ev1) = 40
     AND (SELECT count(*) FROM public.pontos_controle WHERE escolta_veiculo_id = ev1) = 3
     AND (SELECT status FROM public.escoltas WHERE id = e) = 'em_transito_destino'
     AND (SELECT versao_gestao FROM public.escoltas WHERE id = e) = v_ver THEN
    RAISE NOTICE 'PASSOU: gestor edita escolta em andamento (data, destino, observação e viatura nova) sem perder registro (% linhas antes e depois), combustível preservado, versao_gestao igual', n1;
  ELSE RAISE NOTICE 'FALHOU: edição em andamento: linhas % para %, viaturas %', n0, n1, (SELECT count(*) FROM public.escolta_veiculos WHERE escolta_id = e); END IF;
  SELECT dados_antes, dados_depois INTO v_aud FROM public.logs_auditoria WHERE registro_id = e AND acao = 'EDITAR_ESCOLTA' ORDER BY data_hora DESC LIMIT 1;
  IF v_aud.dados_antes ->> 'destino_endereco' = 'QA Destino, São João de Meriti' AND v_aud.dados_depois ->> 'destino_endereco' = 'Novo destino do teste'
     AND v_aud.dados_depois ->> 'motivo' LIKE 'Cliente pediu%' AND jsonb_array_length(v_aud.dados_depois -> 'viaturas') = 2 THEN
    RAISE NOTICE 'PASSOU: auditoria EDITAR_ESCOLTA com antes e depois (destino, viaturas e motivo)';
  ELSE RAISE NOTICE 'FALHOU: auditoria da edição %', v_aud; END IF;
  IF EXISTS (SELECT 1 FROM public.notificacoes n JOIN public.dom_tipos_evento t ON t.id = n.tipo_evento_id
              WHERE n.escolta_id = e AND t.codigo = 'edicao_escolta' AND n.usuario_dest_id = qa.usuario('qa_supervisor'))
     AND NOT EXISTS (SELECT 1 FROM public.notificacoes WHERE escolta_id = e AND usuario_dest_id = qa.usuario('qa_gestor')) THEN
    RAISE NOTICE 'PASSOU: edição de escolta iniciada avisa a supervisão na central (quem editou não recebe)';
  ELSE RAISE NOTICE 'FALHOU: aviso da edição'; END IF;

  -- S9: remover viatura com registro e trocar a placa dela, recusados.
  SELECT id INTO ev2 FROM public.escolta_veiculos WHERE escolta_id = e AND id <> ev1;
  PERFORM qa.como('qa_gestor');
  BEGIN
    PERFORM public.editar_escolta(e, '{}'::jsonb, jsonb_build_array(jsonb_build_object('veiculo_id', '00000000-0000-4000-a000-0000000000f2',
      'escolta_veiculo_id', ev2, 'membros', '[]'::jsonb)), 'remover a primeira viatura do teste');
    RAISE NOTICE 'FALHOU: viatura com registro removida';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: remover viatura com registro de campo (S9): %', SQLERRM;
  END;
  BEGIN
    PERFORM public.editar_escolta(e, '{}'::jsonb, jsonb_build_array(
      jsonb_build_object('escolta_veiculo_id', ev1, 'veiculo_id', '00000000-0000-4000-a000-0000000000f3', 'membros', '[]'::jsonb),
      jsonb_build_object('escolta_veiculo_id', ev2, 'veiculo_id', '00000000-0000-4000-a000-0000000000f2', 'membros', '[]'::jsonb)),
      'trocar a placa da viatura com registro');
    RAISE NOTICE 'FALHOU: placa de viatura com registro trocada';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: trocar a placa de viatura com registro (S9)';
  END;
  BEGIN
    PERFORM public.editar_escolta(e, '{}'::jsonb, jsonb_build_array(
      jsonb_build_object('escolta_veiculo_id', ev1, 'veiculo_id', '00000000-0000-4000-a000-0000000000f1', 'membros', '[]'::jsonb),
      jsonb_build_object('escolta_veiculo_id', ev2, 'veiculo_id', '00000000-0000-4000-a000-0000000000f1', 'membros', '[]'::jsonb)),
      'placa repetida no teste da onda I');
    RAISE NOTICE 'FALHOU: placa repetida aceita';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: mesma placa em duas viaturas (G)';
  END;
  BEGIN
    PERFORM public.editar_escolta(e, '{}'::jsonb, jsonb_build_array(
      jsonb_build_object('escolta_veiculo_id', ev1, 'veiculo_id', '00000000-0000-4000-a000-0000000000f1',
        'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'comandante'))),
      jsonb_build_object('escolta_veiculo_id', ev2, 'veiculo_id', '00000000-0000-4000-a000-0000000000f2',
        'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'operador')))),
      'vigilante repetido no teste da onda I');
    RAISE NOTICE 'FALHOU: vigilante repetido aceito';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: mesmo vigilante em duas viaturas (G)';
  END;
  -- A viatura nova (sem registro) pode sair.
  PERFORM public.editar_escolta(e, '{}'::jsonb, jsonb_build_array(jsonb_build_object('escolta_veiculo_id', ev1,
    'veiculo_id', '00000000-0000-4000-a000-0000000000f1',
    'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'comandante')))),
    'tirar a viatura nova sem registro');
  PERFORM pg_temp.pg();
  IF (SELECT count(*) FROM public.escolta_veiculos WHERE escolta_id = e) = 1
     AND NOT EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = e AND vigilante_id = qa.vigilante('qa_dois')) THEN
    RAISE NOTICE 'PASSOU: viatura sem registro sai da escolta iniciada, com a equipe dela';
  ELSE RAISE NOTICE 'FALHOU: viatura sem registro não saiu'; END IF;
  -- Edição sem motivo em escolta iniciada.
  PERFORM qa.como('qa_gestor');
  BEGIN
    PERFORM public.editar_escolta(e, '{"origem_endereco": "x"}'::jsonb, NULL, 'curto');
    RAISE NOTICE 'FALHOU: edição de iniciada com motivo curto';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: edição de escolta iniciada exige motivo de 10 caracteres';
  END;
  PERFORM pg_temp.pg();
END $$;
ROLLBACK;

-- ── Edição em agendada: central edita os dados, não a equipe ────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 day', 'agendada', 'qa_um', 1)::text, true);
UPDATE public.escoltas SET valor_cobrado = 500 WHERE id = current_setting('t.esc')::uuid;
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; ev1 uuid := pg_temp.ev(current_setting('t.esc')::uuid, 1);
BEGIN
  PERFORM qa.como('qa_central');
  PERFORM public.editar_escolta(e, '{"origem_endereco": "Origem editada pela central", "valor_cobrado": 1}'::jsonb,
    jsonb_build_array(jsonb_build_object('escolta_veiculo_id', ev1, 'veiculo_id', '00000000-0000-4000-a000-0000000000f1',
      'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'comandante')))), NULL);
  BEGIN
    PERFORM public.editar_escolta(e, '{}'::jsonb,
      jsonb_build_array(jsonb_build_object('escolta_veiculo_id', ev1, 'veiculo_id', '00000000-0000-4000-a000-0000000000f1',
        'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_dois'), 'papel_na_escolta', 'comandante')))), NULL);
    RAISE NOTICE 'FALHOU: central trocou a equipe pela editar_escolta';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: central não altera a equipe pela editar_escolta';
  END;
  PERFORM pg_temp.pg();
  IF (SELECT origem_endereco FROM public.escoltas WHERE id = e) = 'Origem editada pela central'
     AND (SELECT valor_cobrado FROM public.escoltas WHERE id = e) = 500
     AND EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = e AND vigilante_id = qa.vigilante('qa_um')) THEN
    RAISE NOTICE 'PASSOU: central edita os dados da agendada pela RPC, sem gravar financeiro e sem mexer na equipe';
  ELSE RAISE NOTICE 'FALHOU: edição da central em agendada'; END IF;
  -- Supervisor troca a equipe da agendada (como hoje), sem apagar e recriar a viatura.
  PERFORM qa.como('qa_supervisor');
  PERFORM public.editar_escolta(e, '{}'::jsonb,
    jsonb_build_array(jsonb_build_object('escolta_veiculo_id', ev1, 'veiculo_id', '00000000-0000-4000-a000-0000000000f1',
      'membros', jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_dois'), 'papel_na_escolta', 'comandante')))), NULL);
  PERFORM pg_temp.pg();
  IF pg_temp.ev(e, 1) = ev1 AND EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = e AND vigilante_id = qa.vigilante('qa_dois'))
     AND NOT EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = e AND vigilante_id = qa.vigilante('qa_um')) THEN
    RAISE NOTICE 'PASSOU: supervisor troca a equipe da agendada pela RPC, mantendo a mesma viatura (escolta_veiculo_id)';
  ELSE RAISE NOTICE 'FALHOU: troca de equipe pelo supervisor'; END IF;
END $$;
ROLLBACK;

-- ── Edição em agendada: troca de placa é UPDATE na mesma linha (revisão I, médio 1) ──
-- Troca simples e troca entre duas viaturas (restrição única da 210 adiada na RPC):
-- escolta_veiculo_id, confirmado, valor pago, armamentos, combustível e ordem preservados.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 day', 'agendada', 'qa_um', 2)::text, true);
UPDATE public.escolta_veiculos SET abastecimento_litros = 30 WHERE id = pg_temp.ev(current_setting('t.esc')::uuid, 1);
UPDATE public.escolta_efetivo SET valor_pago_vigilante = 150 WHERE escolta_id = current_setting('t.esc')::uuid;
INSERT INTO public.escolta_armamentos (escolta_veiculo_id, tipo_id, calibre_id, quantidade)
SELECT pg_temp.ev(current_setting('t.esc')::uuid, n), (SELECT id FROM public.dom_tipos_armamento ORDER BY id LIMIT 1),
       (SELECT id FROM public.dom_calibres ORDER BY id LIMIT 1), n
  FROM generate_series(1, 2) n;
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; ev1 uuid := pg_temp.ev(current_setting('t.esc')::uuid, 1);
  ev2 uuid := pg_temp.ev(current_setting('t.esc')::uuid, 2); ef uuid;
  f1 uuid := '00000000-0000-4000-a000-0000000000f1'; f2 uuid := '00000000-0000-4000-a000-0000000000f2';
  f3 uuid := '00000000-0000-4000-a000-0000000000f3';
  cmd jsonb := jsonb_build_array(jsonb_build_object('vigilante_id', qa.vigilante('qa_um'), 'papel_na_escolta', 'comandante'));
BEGIN
  SELECT id INTO ef FROM public.escolta_efetivo WHERE escolta_id = e;
  -- 1. Troca simples (supervisor): a viatura 1 passa da placa f1 para a f3.
  PERFORM qa.como('qa_supervisor');
  PERFORM public.editar_escolta(e, '{}'::jsonb, jsonb_build_array(
    jsonb_build_object('escolta_veiculo_id', ev1, 'veiculo_id', f3, 'membros', cmd),
    jsonb_build_object('escolta_veiculo_id', ev2, 'veiculo_id', f2, 'membros', '[]'::jsonb)), NULL);
  PERFORM pg_temp.pg();
  IF (SELECT veiculo_id FROM public.escolta_veiculos WHERE id = ev1) = f3
     AND (SELECT count(*) FROM public.escolta_veiculos WHERE escolta_id = e) = 2
     AND pg_temp.ev(e, 1) = ev1
     AND (SELECT escolta_veiculo_id = ev1 AND confirmado AND valor_pago_vigilante = 150 FROM public.escolta_efetivo WHERE id = ef)
     AND (SELECT abastecimento_litros FROM public.escolta_veiculos WHERE id = ev1) = 30
     AND (SELECT quantidade FROM public.escolta_armamentos WHERE escolta_veiculo_id = ev1) = 1 THEN
    RAISE NOTICE 'PASSOU: troca simples de placa é UPDATE na mesma linha: mesmo escolta_veiculo_id e ordem, comandante confirmado com valor pago 150, armamento e combustível preservados';
  ELSE RAISE NOTICE 'FALHOU: troca simples de placa'; END IF;
  -- 2. Troca entre as duas viaturas (gestor): f3 e f2 trocam de lugar sem apagar linha.
  PERFORM qa.como('qa_gestor');
  PERFORM public.editar_escolta(e, '{}'::jsonb, jsonb_build_array(
    jsonb_build_object('escolta_veiculo_id', ev1, 'veiculo_id', f2, 'membros', cmd),
    jsonb_build_object('escolta_veiculo_id', ev2, 'veiculo_id', f3, 'membros', '[]'::jsonb)), NULL);
  PERFORM pg_temp.pg();
  IF (SELECT veiculo_id FROM public.escolta_veiculos WHERE id = ev1) = f2
     AND (SELECT veiculo_id FROM public.escolta_veiculos WHERE id = ev2) = f3
     AND pg_temp.ev(e, 1) = ev1 AND pg_temp.ev(e, 2) = ev2
     AND (SELECT escolta_veiculo_id = ev1 AND confirmado AND valor_pago_vigilante = 150 FROM public.escolta_efetivo WHERE id = ef)
     AND (SELECT abastecimento_litros FROM public.escolta_veiculos WHERE id = ev1) = 30
     AND (SELECT quantidade FROM public.escolta_armamentos WHERE escolta_veiculo_id = ev1) = 1
     AND (SELECT quantidade FROM public.escolta_armamentos WHERE escolta_veiculo_id = ev2) = 2 THEN
    RAISE NOTICE 'PASSOU: duas viaturas trocam de placa entre si (restrição da 210 adiada): ids, ordem, confirmado, valor pago, armamentos e combustível preservados';
  ELSE RAISE NOTICE 'FALHOU: troca de placas entre viaturas'; END IF;
  -- 3. Fora da RPC, a restrição continua valendo na hora: placa repetida é recusada.
  BEGIN
    UPDATE public.escolta_veiculos SET veiculo_id = f3 WHERE id = ev1;
    RAISE NOTICE 'FALHOU: placa repetida aceita fora da RPC';
  EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: fora da editar_escolta a placa repetida na escolta é recusada na hora (restrição INITIALLY IMMEDIATE)';
  END;
END $$;
ROLLBACK;

-- ── Arquivar e recuperar ───────────────────────────────────────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '20 min', 'agendada', NULL, 1)::text, true);
SELECT set_config('t.and', qa.nova_escolta(now(), 'em_andamento', 'qa_dois', 1)::text, true);
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; v_ver int; n int; r jsonb;
BEGIN
  PERFORM qa.como('qa_gestor');
  BEGIN
    PERFORM public.arquivar_escolta(current_setting('t.and')::uuid, 'arquivar escolta em andamento');
    RAISE NOTICE 'FALHOU: escolta em andamento arquivada';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: escolta em andamento não é arquivada (S7)';
  END;
  PERFORM public.arquivar_escolta(e, 'Escolta duplicada por engano no cadastro');
  -- Some para o próprio gestor (só o administrador vê).
  SELECT count(*) INTO n FROM public.escoltas WHERE id = e;
  PERFORM pg_temp.pg();
  IF n = 0 AND (SELECT arquivada_em IS NOT NULL AND versao_gestao = 1 FROM public.escoltas WHERE id = e) THEN
    RAISE NOTICE 'PASSOU: gestor arquiva a agendada; ela some para o gestor (RLS); versao_gestao 1';
  ELSE RAISE NOTICE 'FALHOU: arquivamento (visível ao gestor: %)', n; END IF;
  PERFORM qa.como('qa_um');
  SELECT count(*) INTO n FROM public.escoltas WHERE id = e;
  r := public.mural_info(ARRAY[e]);
  BEGIN
    PERFORM public.puxar_escolta(e);
    RAISE NOTICE 'FALHOU: operador puxou escolta arquivada';
  EXCEPTION WHEN raise_exception THEN
    IF n = 0 AND r = '{}'::jsonb THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: escolta arquivada some do operador (lista e mural_info) e puxar é recusado: %', SQLERRM;
    ELSE RAISE NOTICE 'FALHOU: operador ainda vê a arquivada (%, %)', n, r; END IF;
  END;
  PERFORM pg_temp.pg();
  PERFORM qa.como('qa_administrador');
  SELECT count(*) INTO n FROM public.escoltas WHERE id = e AND arquivada_em IS NOT NULL;
  BEGIN
    UPDATE public.escoltas SET status = 'em_pre_inicio' WHERE id = e;
    RAISE NOTICE 'FALHOU: status de escolta arquivada mudou';
  EXCEPTION WHEN raise_exception THEN
    IF n = 1 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: administrador vê a arquivada, mas o status dela não muda'; END IF;
  END;
  PERFORM pg_temp.pg();
  PERFORM qa.como('qa_gestor');
  BEGIN
    PERFORM public.recuperar_escolta(e, 'gestor tentando recuperar');
    RAISE NOTICE 'FALHOU: gestor recuperou';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: só o administrador recupera';
  END;
  PERFORM pg_temp.pg();
  PERFORM qa.como('qa_administrador');
  PERFORM public.recuperar_escolta(e, 'Arquivada por engano, volta para a operação');
  PERFORM pg_temp.pg();
  IF (SELECT arquivada_em IS NULL AND status = 'agendada' AND versao_gestao = 2 FROM public.escoltas WHERE id = e)
     AND (SELECT count(*) FROM public.logs_auditoria WHERE registro_id = e AND acao IN ('ARQUIVAR_ESCOLTA', 'RECUPERAR_ESCOLTA')) = 2
     AND (SELECT count(*) FROM public.notificacoes n JOIN public.dom_tipos_evento t ON t.id = n.tipo_evento_id
           WHERE n.escolta_id = e AND t.codigo IN ('arquivamento_escolta', 'recuperacao_escolta')) >= 2
     AND NOT EXISTS (SELECT 1 FROM public.escolta_status_historico WHERE escolta_id = e AND status_anterior = status_novo) THEN
    RAISE NOTICE 'PASSOU: administrador recupera; volta agendada, versao_gestao 2, auditoria e avisos das duas ações; nenhuma linha de histórico de X para X (a âncora não se desloca)';
  ELSE RAISE NOTICE 'FALHOU: recuperação'; END IF;
  IF NOT public.avisos_pelo_banco_ativos()
     OR (SELECT count(*) FROM public.avisos_telegram WHERE escolta_id = e AND evento_chave LIKE 'gestao:%' AND destino = 'central') = 2 THEN
    RAISE NOTICE 'PASSOU: Telegram ao chat central para arquivar e recuperar (uma mensagem por ação, pela fila da 202)';
  ELSE RAISE NOTICE 'FALHOU: fila do Telegram das ações da gestão'; END IF;
END $$;
ROLLBACK;

-- Telegram pendente de escolta arquivada não sai; o do arquivamento sai.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 day', 'agendada', 'qa_um', 1)::text, true);
INSERT INTO public.avisos_telegram (evento_chave, destino, escolta_id, texto, criado_em)
VALUES ('teste_i:antigo', 'central', current_setting('t.esc')::uuid, 'aviso antigo', now() - interval '1 minute');
SELECT qa.como('qa_gestor');
SELECT public.arquivar_escolta(current_setting('t.esc')::uuid, 'teste do envio do Telegram');
SELECT pg_temp.pg();
DO $$
BEGIN
  IF NOT public.avisos_pelo_banco_ativos() THEN RAISE NOTICE 'PASSOU: envio pelo banco inativo (conferência do Telegram de arquivada não se aplica)'; RETURN; END IF;
  PERFORM public.enviar_avisos_telegram();
  IF (SELECT situacao FROM public.avisos_telegram WHERE evento_chave = 'teste_i:antigo') = 'erro'
     AND (SELECT situacao FROM public.avisos_telegram WHERE escolta_id = current_setting('t.esc')::uuid AND evento_chave LIKE 'gestao:arquivamento:%') = 'enviando' THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: aviso pendente de escolta arquivada não é enviado; o do arquivamento sai';
  ELSE RAISE NOTICE 'FALHOU: envio de aviso de escolta arquivada'; END IF;
END $$;
ROLLBACK;

-- ── Voltar uma etapa ───────────────────────────────────────────────────────────────
-- De no_destino para em_transito_destino: o ponto do destino fica anulado e não conta.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 2)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'no_destino');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; pv jsonb; r jsonb; n0 int; v_ver int; v_res jsonb;
BEGIN
  n0 := pg_temp.contar(e, false);
  SELECT versao_gestao INTO v_ver FROM public.escoltas WHERE id = e;
  PERFORM qa.como('qa_gestor');
  pv := public.voltar_etapa_escolta(e, NULL, true);
  PERFORM pg_temp.pg();
  IF pv ->> 'destino' = 'em_transito_destino' AND (pv ->> 'total')::int = 3
     AND (SELECT status FROM public.escoltas WHERE id = e) = 'no_destino' AND pg_temp.contar(e, true) = n0 THEN
    RAISE NOTICE 'PASSOU: prévia da volta (no_destino para em_transito_destino) lista % itens (2 pontos do destino e o histórico) sem mudar nada', pv ->> 'total';
  ELSE RAISE NOTICE 'FALHOU: prévia %', pv; END IF;
  PERFORM qa.como('qa_gestor');
  BEGIN
    PERFORM public.voltar_etapa_escolta(e, 'curto', false, public.voltar_etapa_escolta(e, NULL, true) -> 'resumo');
    RAISE NOTICE 'FALHOU: volta sem motivo';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: voltar etapa exige motivo de 10 caracteres';
  END;
  r := public.voltar_etapa_escolta(e, 'Foto do destino saiu errada, refazer', false, public.voltar_etapa_escolta(e, NULL, true) -> 'resumo');
  PERFORM pg_temp.pg();
  IF (SELECT status FROM public.escoltas WHERE id = e) = 'em_transito_destino'
     AND (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
           WHERE ev.escolta_id = e AND pc.tipo_ponto_id = pg_temp.tp('destino') AND pc.anulado_em IS NOT NULL
             AND pc.anulado_por = qa.usuario('qa_gestor') AND pc.motivo_anulacao LIKE 'Foto do destino%') = 2
     AND pg_temp.contar(e, false) = n0 + 1
     AND (SELECT versao_gestao FROM public.escoltas WHERE id = e) = v_ver + 1
     AND (SELECT count(*) FROM public.escolta_resets WHERE escolta_id = e AND tipo = 'voltar_etapa') = 1
     AND EXISTS (SELECT 1 FROM public.escolta_status_historico WHERE escolta_id = e AND status_anterior = 'no_destino'
                  AND status_novo = 'em_transito_destino' AND observacao LIKE 'Reset: %' AND via_rpc)
     AND EXISTS (SELECT 1 FROM public.logs_auditoria WHERE registro_id = e AND acao = 'VOLTAR_ETAPA') THEN
    RAISE NOTICE 'PASSOU: volta de no_destino para em_transito_destino: 2 pontos do destino anulados, nada apagado, linha Reset no histórico (via_rpc), escolta_resets, auditoria e versao_gestao + 1';
  ELSE RAISE NOTICE 'FALHOU: volta de etapa %', r; END IF;
  -- O Modo Guiado e a tela não avançam sozinhos: a contagem do comboio ignora o anulado.
  PERFORM qa.como('qa_um');
  v_res := public.registrar_etapa_escolta(e, '[]'::jsonb, 'em_transito_destino', 'no_destino', NULL, NULL, NULL, NULL, NULL, pg_temp.tp('destino'));
  PERFORM pg_temp.pg();
  IF (v_res ->> 'avancou')::boolean = false AND jsonb_array_length(v_res -> 'faltando') = 2 THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: depois da volta, registrar_etapa_escolta pede de novo a foto do destino nas 2 viaturas (não avança sozinho)';
  ELSE RAISE NOTICE 'FALHOU: avançou com ponto anulado %', v_res; END IF;
END $$;
ROLLBACK;

-- De em_andamento: checklists do pré-início, base_saida, KM e checklist_pendente; refazer não duplica.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
UPDATE public.escoltas SET checklist_pendente_no_inicio = false WHERE id = current_setting('t.esc')::uuid;
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; r jsonb; v_res record;
BEGIN
  PERFORM qa.como('qa_administrador');
  r := public.voltar_etapa_escolta(e, 'Checklist feito na viatura errada', false, public.voltar_etapa_escolta(e, NULL, true) -> 'resumo');
  PERFORM pg_temp.pg();
  SELECT (SELECT count(*) FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id WHERE ev.escolta_id = e AND c.anulado_em IS NOT NULL) AS ck,
         (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id WHERE ev.escolta_id = e AND pc.anulado_em IS NOT NULL) AS pt,
         (SELECT quilometragem_saida FROM public.escolta_veiculos WHERE escolta_id = e) AS km,
         (SELECT checklist_pendente_no_inicio FROM public.escoltas WHERE id = e) AS pend,
         (SELECT status FROM public.escoltas WHERE id = e) AS st,
         (SELECT valores_anteriores -> 'km' -> 0 ->> 'quilometragem_saida' FROM public.escolta_resets WHERE escolta_id = e) AS km_guardado
    INTO v_res;
  IF v_res.ck = 2 AND v_res.pt = 1 AND v_res.km IS NULL AND v_res.pend AND v_res.st = 'em_pre_inicio' AND v_res.km_guardado::numeric = 1000 THEN
    RAISE NOTICE 'PASSOU: volta de em_andamento anula os 2 checklists e o base_saida, guarda e limpa o KM de saída e devolve checklist_pendente_no_inicio';
  ELSE RAISE NOTICE 'FALHOU: volta de em_andamento %', v_res; END IF;
  -- Refaz o wizard: só os novos checklists ficam válidos.
  PERFORM qa.como('qa_gestor');
  PERFORM pg_temp.jornada(e, 'em_andamento');
  PERFORM pg_temp.pg();
  IF (SELECT count(*) FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id
       WHERE ev.escolta_id = e AND c.anulado_em IS NULL) = 2
     AND (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
           WHERE ev.escolta_id = e AND pc.anulado_em IS NULL AND pc.tipo_ponto_id = pg_temp.tp('base_saida')) = 1 THEN
    RAISE NOTICE 'PASSOU: refazer o pré-início não duplica checklist válido (2 válidos, 2 anulados) nem o ponto de saída';
  ELSE RAISE NOTICE 'FALHOU: refazer duplicou'; END IF;
END $$;
ROLLBACK;

-- De finalizada normal: o checklist de entrega cai, os do wizard ficam.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'finalizada');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; v_res record;
BEGIN
  PERFORM qa.como('qa_gestor');
  PERFORM public.voltar_etapa_escolta(e, 'Relatório final saiu incompleto', false, public.voltar_etapa_escolta(e, NULL, true) -> 'resumo');
  PERFORM pg_temp.pg();
  SELECT (SELECT count(*) FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id
           WHERE ev.escolta_id = e AND c.anulado_em IS NULL) AS validos,
         (SELECT count(*) FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id
           WHERE ev.escolta_id = e AND c.anulado_em IS NOT NULL AND c.status_escolta_no_registro = 'na_base') AS entrega,
         (SELECT status FROM public.escoltas WHERE id = e) AS st,
         (SELECT data_finalizacao IS NULL AND observacao_fechamento IS NULL FROM public.escoltas WHERE id = e) AS limpou
    INTO v_res;
  IF v_res.validos = 2 AND v_res.entrega = 1 AND v_res.st = 'na_base' AND v_res.limpou THEN
    RAISE NOTICE 'PASSOU: volta de finalizada para na_base anula só o checklist de entrega (carimbo na_base); os 2 do wizard ficam válidos; fechamento limpo e guardado';
  ELSE RAISE NOTICE 'FALHOU: volta de finalizada %', v_res; END IF;
END $$;
ROLLBACK;

-- Histórico forjado pelo operador não muda o destino nem a janela; agendada e cancelada recusadas.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '3 hours', 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'no_destino');
-- Ocorrência antiga, sem carimbo (anterior à 213), e linha forjada com data antiga.
INSERT INTO public.ocorrencias (escolta_id, tipo_ocorrencia_id, descricao, data_hora, registrado_por)
VALUES (current_setting('t.esc')::uuid, (SELECT id FROM public.dom_tipos_ocorrencia LIMIT 1), 'ocorrência antiga do teste', now() - interval '2 hours', qa.usuario('qa_um'));
UPDATE public.ocorrencias SET status_escolta_no_registro = NULL WHERE escolta_id = current_setting('t.esc')::uuid;
SELECT qa.como('qa_um');
INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora)
VALUES (current_setting('t.esc')::uuid, 'agendada', 'no_destino', qa.usuario('qa_um'), now() - interval '2 days 1 hour');
SELECT pg_temp.pg();
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; pv jsonb; s text; v_ok int := 0;
BEGIN
  PERFORM qa.como('qa_gestor');
  pv := public.voltar_etapa_escolta(e, NULL, true);
  PERFORM pg_temp.pg();
  IF pv ->> 'destino' = 'em_transito_destino'
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pv -> 'itens') x WHERE x ->> 'tabela' = 'ocorrencias') THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: linha de histórico forjada pelo operador (agendada, data antiga) não muda o destino nem a janela (ocorrência antiga fora)';
  ELSE RAISE NOTICE 'FALHOU: forjada mudou a volta %', pv; END IF;
  -- Agendada e cancelada: recusadas.
  FOREACH s IN ARRAY ARRAY['agendada', 'cancelada', 'rascunho'] LOOP
    PERFORM set_config('t.x', qa.nova_escolta(now() + interval '1 day', s, NULL, 1)::text, true);
    PERFORM qa.como('qa_gestor');
    BEGIN
      PERFORM public.voltar_etapa_escolta(current_setting('t.x')::uuid, 'voltar sem etapa anterior', false, public.voltar_etapa_escolta(current_setting('t.x')::uuid, NULL, true) -> 'resumo');
      RAISE NOTICE 'FALHOU: voltou de %', s;
    EXCEPTION WHEN raise_exception THEN v_ok := v_ok + 1;
    END;
    PERFORM pg_temp.pg();
  END LOOP;
  IF v_ok = 3 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: voltar etapa recusado em agendada, cancelada e rascunho'; END IF;
END $$;
ROLLBACK;

-- Registro antigo (sem carimbo) dentro da janela do ponto que produziu a etapa.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'no_destino');
INSERT INTO public.ocorrencias (escolta_id, tipo_ocorrencia_id, descricao, data_hora, registrado_por)
VALUES (current_setting('t.esc')::uuid, (SELECT id FROM public.dom_tipos_ocorrencia LIMIT 1), 'ocorrência antiga depois do destino', clock_timestamp() + interval '1 min', qa.usuario('qa_um')),
       (current_setting('t.esc')::uuid, (SELECT id FROM public.dom_tipos_ocorrencia LIMIT 1), 'ocorrência antiga antes do destino', now() - interval '1 hour', qa.usuario('qa_um'));
UPDATE public.ocorrencias SET status_escolta_no_registro = NULL WHERE escolta_id = current_setting('t.esc')::uuid;
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; pv jsonb;
BEGIN
  PERFORM qa.como('qa_gestor');
  pv := public.voltar_etapa_escolta(e, NULL, true);
  PERFORM pg_temp.pg();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(pv -> 'itens') x WHERE x ->> 'criterio' = 'janela' AND x ->> 'descricao' LIKE '%depois do destino')
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pv -> 'itens') x WHERE x ->> 'descricao' LIKE '%antes do destino')
     AND (pv -> 'avisos') ->> 0 LIKE 'Registros antigos (sem carimbo de etapa) contam a partir de %' THEN
    RAISE NOTICE 'PASSOU: registro antigo sem carimbo entra pela janela do ponto que produziu a etapa (o anterior fica); a prévia mostra o horário de corte';
  ELSE RAISE NOTICE 'FALHOU: janela dos antigos %', pv; END IF;
END $$;
ROLLBACK;

-- Fluxo 1 que pulou em_transito_destino: volta de no_destino para em_transito_destino e avança de novo.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'na_origem');
UPDATE public.escoltas SET fluxo_versao = 1 WHERE id = current_setting('t.esc')::uuid;
SELECT public.registrar_etapa_escolta(current_setting('t.esc')::uuid,
  jsonb_build_array(jsonb_build_object('escolta_veiculo_id', pg_temp.ev(current_setting('t.esc')::uuid, 1), 'tipo_ponto_id', pg_temp.tp('destino'), 'sem_sinal_gps', true, 'lancado_por', qa.usuario('qa_um'))),
  'na_origem', 'no_destino', 'salto legado do fluxo 1', NULL, NULL, NULL, NULL, pg_temp.tp('destino'));
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; r jsonb;
BEGIN
  PERFORM qa.como('qa_gestor');
  r := public.voltar_etapa_escolta(e, 'Pulou a etapa de trânsito no fluxo antigo', false, public.voltar_etapa_escolta(e, NULL, true) -> 'resumo');
  PERFORM pg_temp.pg();
  IF r ->> 'para' = 'em_transito_destino' THEN
    PERFORM qa.como('qa_um');
    PERFORM public.registrar_etapa_escolta(e, jsonb_build_array(jsonb_build_object('escolta_veiculo_id', pg_temp.ev(e, 1), 'tipo_ponto_id', pg_temp.tp('destino'), 'sem_sinal_gps', true)),
      'em_transito_destino', 'no_destino', 'refeito', NULL, NULL, NULL, NULL, pg_temp.tp('destino'));
    PERFORM pg_temp.pg();
  END IF;
  IF r ->> 'para' = 'em_transito_destino' AND (SELECT status FROM public.escoltas WHERE id = e) = 'no_destino' THEN
    RAISE NOTICE 'PASSOU: escolta do fluxo 1 que pulou em_transito_destino volta de no_destino para em_transito_destino (etapa linear) e avança de novo';
  ELSE RAISE NOTICE 'FALHOU: fluxo 1 %', r; END IF;
END $$;
ROLLBACK;

-- Emergência aberta impede voltar e zerar.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'na_origem');
INSERT INTO public.emergencias (escolta_id, escolta_veiculo_id, acionado_por, data_hora, sem_sinal_gps)
VALUES (current_setting('t.esc')::uuid, pg_temp.ev(current_setting('t.esc')::uuid, 1), qa.usuario('qa_um'), now(), true);
SELECT qa.como('qa_gestor');
DO $$
BEGIN
  PERFORM public.zerar_escolta(current_setting('t.esc')::uuid, 'zerar com emergência aberta', false, public.zerar_escolta(current_setting('t.esc')::uuid, NULL, true) -> 'resumo');
  RAISE NOTICE 'FALHOU: zerou com emergência aberta';
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: com emergência aberta, voltar e zerar são recusados (%)', SQLERRM;
END $$;
SELECT pg_temp.pg();
ROLLBACK;

-- Emergência aberta impede concluir e arquivar (revisão I, médio 3).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_transito_destino');
INSERT INTO public.emergencias (escolta_id, escolta_veiculo_id, acionado_por, data_hora, sem_sinal_gps)
VALUES (current_setting('t.esc')::uuid, pg_temp.ev(current_setting('t.esc')::uuid, 1), qa.usuario('qa_um'), now(), true);
SELECT set_config('t.ag', qa.nova_escolta(now() + interval '1 day', 'agendada', 'qa_dois', 1)::text, true);
INSERT INTO public.emergencias (escolta_id, escolta_veiculo_id, acionado_por, data_hora, sem_sinal_gps, status)
VALUES (current_setting('t.ag')::uuid, pg_temp.ev(current_setting('t.ag')::uuid, 1), qa.usuario('qa_dois'), now(), true, 'em_atendimento');
SELECT qa.como('qa_gestor');
DO $$
BEGIN
  BEGIN
    PERFORM public.concluir_escolta_antecipada(current_setting('t.esc')::uuid, 'concluir com emergência aberta');
    RAISE NOTICE 'FALHOU: concluiu com emergência aberta';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE '%encerre a emergência antes%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: com emergência aberta, concluir é recusado (%)', SQLERRM;
    ELSE RAISE NOTICE 'FALHOU: concluir recusado por outro motivo: %', SQLERRM; END IF;
  END;
  BEGIN
    PERFORM public.arquivar_escolta(current_setting('t.ag')::uuid, 'arquivar com emergência em atendimento');
    RAISE NOTICE 'FALHOU: arquivou com emergência aberta';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE '%encerre a emergência antes%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: com emergência em atendimento, arquivar é recusado (%)', SQLERRM;
    ELSE RAISE NOTICE 'FALHOU: arquivar recusado por outro motivo: %', SQLERRM; END IF;
  END;
END $$;
SELECT pg_temp.pg();
DO $$
BEGIN
  IF (SELECT status FROM public.escoltas WHERE id = current_setting('t.esc')::uuid) = 'em_transito_destino'
     AND (SELECT arquivada_em IS NULL FROM public.escoltas WHERE id = current_setting('t.ag')::uuid) THEN
    RAISE NOTICE 'PASSOU: depois das recusas, a escolta continua em trânsito e a agendada continua visível (emergência segue no Painel)';
  ELSE RAISE NOTICE 'FALHOU: recusa mudou a escolta'; END IF;
END $$;
ROLLBACK;

-- Confirmação com o resumo da prévia (revisão I, menor 10).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'no_destino');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; pv jsonb; pv2 jsonb; r jsonb;
BEGIN
  PERFORM qa.como('qa_gestor');
  pv := public.voltar_etapa_escolta(e, NULL, true);
  BEGIN
    PERFORM public.voltar_etapa_escolta(e, 'confirmação sem o resumo da prévia', false);
    RAISE NOTICE 'FALHOU: confirmou sem resumo';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: confirmação sem o resumo da prévia (%)', SQLERRM;
  END;
  -- O operador registra uma ocorrência entre a prévia e a confirmação.
  PERFORM pg_temp.pg();
  PERFORM qa.como('qa_um');
  INSERT INTO public.ocorrencias (escolta_id, tipo_ocorrencia_id, descricao, data_hora, registrado_por)
  VALUES (e, (SELECT id FROM public.dom_tipos_ocorrencia LIMIT 1), 'ocorrência entre a prévia e a confirmação', now(), qa.usuario('qa_um'));
  PERFORM pg_temp.pg();
  PERFORM qa.como('qa_gestor');
  BEGIN
    PERFORM public.voltar_etapa_escolta(e, 'confirmação com prévia antiga', false, pv -> 'resumo');
    RAISE NOTICE 'FALHOU: confirmou com prévia antiga';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'A escolta mudou desde a prévia%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: a escolta mudou desde a prévia (registro novo): %', SQLERRM;
    ELSE RAISE NOTICE 'FALHOU: recusa por outro motivo: %', SQLERRM; END IF;
  END;
  pv2 := public.voltar_etapa_escolta(e, NULL, true);
  r := public.voltar_etapa_escolta(e, 'Confirmação com a prévia nova e a ocorrência', false, pv2 -> 'resumo');
  PERFORM pg_temp.pg();
  IF (pv2 ->> 'total')::int = (pv ->> 'total')::int + 1 AND (r ->> 'anulados')::int = (pv2 ->> 'total')::int
     AND (pv -> 'resumo' ->> 'hash') <> (pv2 -> 'resumo' ->> 'hash')
     AND (SELECT status FROM public.escoltas WHERE id = e) = 'em_transito_destino' THEN
    RAISE NOTICE 'PASSOU: com a prévia nova (versão, status, total e hash dos ids), a confirmação anula exatamente o que a gestão viu (% itens)', r ->> 'anulados';
  ELSE RAISE NOTICE 'FALHOU: confirmação com prévia nova % %', pv2 -> 'resumo', r; END IF;
END $$;
ROLLBACK;

-- Volta de finalizada concluída em agendada recebe o tratamento do zerar (revisão I, menor
-- 6); devolver a escolta ao mural não apaga a presença anulada (menor 7).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '20 min', 'agendada', 'qa_um', 1)::text, true);
SELECT qa.como('qa_um');
SELECT public.confirmar_presenca_base(current_setting('t.esc')::uuid);
SELECT pg_temp.pg();
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; r jsonb; pv jsonb;
BEGIN
  PERFORM qa.como('qa_gestor');
  r := public.concluir_escolta_antecipada(e, 'Cliente desistiu, fechar a agendada');
  pv := public.voltar_etapa_escolta(e, NULL, true);
  r := public.voltar_etapa_escolta(e, 'Cliente voltou atrás, reabrir a escolta', false, pv -> 'resumo');
  PERFORM pg_temp.pg();
  IF pv ->> 'destino' = 'agendada' AND pv ->> 'tipo' = 'zerar'
     AND (SELECT status = 'agendada' AND reiniciada_em IS NOT NULL AND data_finalizacao IS NULL FROM public.escoltas WHERE id = e)
     AND (SELECT anulado_em IS NOT NULL FROM public.mural_presencas WHERE escolta_id = e)
     AND NOT EXISTS (SELECT 1 FROM public.escolta_conclusoes_antecipadas WHERE escolta_id = e AND anulado_em IS NULL) THEN
    RAISE NOTICE 'PASSOU: volta de finalizada concluída em agendada vai a agendada com o tratamento do zerar (presença do mural anulada, reiniciada_em, conclusão anulada)';
  ELSE RAISE NOTICE 'FALHOU: volta para agendada sem o tratamento do zerar % %', pv, r; END IF;
  PERFORM qa.como('qa_um');
  PERFORM public.devolver_escolta(e);
  PERFORM pg_temp.pg();
  IF (SELECT count(*) FROM public.mural_presencas WHERE escolta_id = e AND anulado_em IS NOT NULL) = 1
     AND NOT EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = e) THEN
    RAISE NOTICE 'PASSOU: comandante devolve a escolta ao mural e a presença anulada continua guardada (só as válidas saem)';
  ELSE RAISE NOTICE 'FALHOU: devolver apagou a presença anulada'; END IF;
END $$;
ROLLBACK;

-- Nada é apagado (revisão I, médio 2): linha anulada e viatura com registro de campo,
-- para supervisor, central, gestor e administrador, pela API (identidade de cada um).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 2)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'na_origem');
SELECT qa.como('qa_gestor');
SELECT public.zerar_escolta(current_setting('t.esc')::uuid, 'Zerar para o teste de apagar', false,
                            public.zerar_escolta(current_setting('t.esc')::uuid, NULL, true) -> 'resumo') IS NOT NULL;
SELECT pg_temp.pg();
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; n0 int; l text; v_ck uuid; v_pc uuid; v_hi uuid; v_ok int := 0; v_msgs text := '';
  v_ant int := 0; v_por text := '';
BEGIN
  n0 := pg_temp.contar(e, false);
  SELECT c.id INTO v_ck FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id
   WHERE ev.escolta_id = e AND c.anulado_em IS NOT NULL LIMIT 1;
  SELECT pc.id INTO v_pc FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
   WHERE ev.escolta_id = e AND pc.anulado_em IS NOT NULL LIMIT 1;
  SELECT id INTO v_hi FROM public.escolta_status_historico WHERE escolta_id = e AND anulado_em IS NOT NULL LIMIT 1;
  FOREACH l IN ARRAY ARRAY['qa_supervisor', 'qa_central', 'qa_gestor', 'qa_administrador'] LOOP
    PERFORM qa.como(l);
    BEGIN DELETE FROM public.checklists WHERE id = v_ck;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1; v_msgs := SQLERRM; END;
    BEGIN DELETE FROM public.pontos_controle WHERE id = v_pc;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1; END;
    BEGIN DELETE FROM public.escolta_status_historico WHERE id = v_hi;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1; END;
    BEGIN DELETE FROM public.mural_presencas WHERE escolta_id = e AND anulado_em IS NOT NULL;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1; END;
    -- A escolta voltou a agendada: sem esta trava, apagar a viatura levaria tudo em cascata.
    BEGIN DELETE FROM public.escolta_veiculos WHERE escolta_id = e;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1; END;
    PERFORM pg_temp.pg();
    v_por := v_por || ' ' || replace(l, 'qa_', '') || '=' || (v_ok - v_ant);
    v_ant := v_ok;
  END LOOP;
  IF pg_temp.contar(e, false) = n0 AND (SELECT count(*) FROM public.escolta_veiculos WHERE escolta_id = e) = 2
     AND EXISTS (SELECT 1 FROM public.checklists WHERE id = v_ck) AND EXISTS (SELECT 1 FROM public.pontos_controle WHERE id = v_pc) THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: supervisor, central, gestor e administrador não apagam checklist, ponto, histórico e presença anulados nem a viatura da escolta zerada (recusas pela trava:%; % linhas intactas): %', v_por, n0, v_msgs;
  ELSE RAISE NOTICE 'FALHOU: algo foi apagado (% recusas, % de % linhas)', v_ok, pg_temp.contar(e, false), n0; END IF;
END $$;
ROLLBACK;

-- Ponto gravado não muda de autor nem de horário (revisão I, menor 8).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT qa.como('qa_um');
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'na_origem');
SELECT pg_temp.pg();
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; v_pc uuid; l text; v_ok int := 0; v_msg text;
BEGIN
  SELECT pc.id INTO v_pc FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
   WHERE ev.escolta_id = e LIMIT 1;
  FOREACH l IN ARRAY ARRAY['qa_supervisor', 'qa_gestor'] LOOP
    PERFORM qa.como(l);
    BEGIN UPDATE public.pontos_controle SET lancado_por = qa.usuario('qa_dois') WHERE id = v_pc;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1; v_msg := SQLERRM; END;
    BEGIN UPDATE public.pontos_controle SET data_hora = data_hora - interval '5 days' WHERE id = v_pc;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1; END;
    PERFORM pg_temp.pg();
  END LOOP;
  IF v_ok = 4 AND (SELECT lancado_por = qa.usuario('qa_um') AND data_hora > now() - interval '1 hour' FROM public.pontos_controle WHERE id = v_pc) THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: supervisor e gestor não mudam lancado_por nem data_hora de ponto gravado (%)', v_msg;
  ELSE RAISE NOTICE 'FALHOU: ponto mudou de autor ou de horário (% recusas)', v_ok; END IF;
END $$;
ROLLBACK;

-- ── Concluir com pendências; voltar dela vai ao status em que estava ────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 2)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_transito_destino');
-- Comboio parcial: só a viatura 1 registrou o destino.
SELECT pg_temp.ponto(current_setting('t.esc')::uuid, 1, 'destino');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; pv jsonb; r jsonb; v_c record; n int;
BEGIN
  PERFORM qa.como('qa_gestor');
  pv := public.pendencias_da_escolta(e);
  r := public.concluir_escolta_antecipada(e, 'Carga entregue em outro local por ordem do cliente');
  PERFORM pg_temp.pg();
  SELECT * INTO v_c FROM public.escolta_conclusoes_antecipadas WHERE escolta_id = e AND anulado_em IS NULL;
  IF pv = v_c.pendencias AND v_c.status_no_momento = 'em_transito_destino' AND jsonb_array_length(v_c.pendencias) = 4
     AND (v_c.pendencias -> 0 ->> 'etapa') = 'no_destino'
     AND jsonb_array_length(v_c.pendencias -> 0 -> 'viaturas') = 1
     AND (SELECT status = 'finalizada' AND observacao_fechamento LIKE 'Carga entregue%' AND data_finalizacao IS NOT NULL
            FROM public.escoltas WHERE id = e)
     AND EXISTS (SELECT 1 FROM public.escolta_status_historico WHERE escolta_id = e AND status_novo = 'finalizada' AND via_rpc)
     AND EXISTS (SELECT 1 FROM public.logs_auditoria WHERE registro_id = e AND acao = 'CONCLUSAO_ANTECIPADA') THEN
    RAISE NOTICE 'PASSOU: conclusão em em_transito_destino com pendências calculadas no servidor (4 etapas; no_destino só a viatura 2), finalizada, histórico via_rpc e auditoria';
  ELSE RAISE NOTICE 'FALHOU: conclusão %', v_c; END IF;
  SELECT count(*) INTO n FROM public.vw_pendencias_conclusao WHERE escolta_id = e;
  IF n = (SELECT count(*) FROM jsonb_array_elements(v_c.pendencias) et, jsonb_array_elements(et -> 'viaturas') vt, jsonb_array_elements(vt -> 'faltando')) AND n >= 9 THEN
    RAISE NOTICE 'PASSOU: vw_pendencias_conclusao com uma linha por item (% itens)', n;
  ELSE RAISE NOTICE 'FALHOU: view com % linhas', n; END IF;
  -- Leitura: o efetivo lê a da própria escolta; a central também (quem vê a escolta vê a lista).
  PERFORM qa.como('qa_um');
  SELECT count(*) INTO n FROM public.escolta_conclusoes_antecipadas WHERE escolta_id = e;
  PERFORM pg_temp.pg();
  IF n = 1 THEN
    PERFORM qa.como('qa_central');
    SELECT count(*) INTO n FROM public.escolta_conclusoes_antecipadas WHERE escolta_id = e;
    SELECT n * 1000 + count(*) INTO n FROM public.vw_pendencias_conclusao WHERE escolta_id = e;
    PERFORM pg_temp.pg();
    IF n >= 1009 THEN RAISE NOTICE 'PASSOU: o efetivo lê a conclusão da própria escolta; a central lê a conclusão e a lista da view (adendo 4.3.6)';
    ELSE RAISE NOTICE 'FALHOU: leitura da central %', n; END IF;
  ELSE RAISE NOTICE 'FALHOU: efetivo não leu a conclusão'; END IF;
  -- Voltar: vai ao status em que ela estava e anula a linha de pendências.
  PERFORM qa.como('qa_gestor');
  r := public.voltar_etapa_escolta(e, 'Conclusão feita antes da hora', false, public.voltar_etapa_escolta(e, NULL, true) -> 'resumo');
  PERFORM pg_temp.pg();
  IF r ->> 'para' = 'em_transito_destino' AND (SELECT status FROM public.escoltas WHERE id = e) = 'em_transito_destino'
     AND NOT EXISTS (SELECT 1 FROM public.escolta_conclusoes_antecipadas WHERE escolta_id = e AND anulado_em IS NULL)
     AND (SELECT count(*) FROM public.vw_pendencias_conclusao WHERE escolta_id = e) = 0 THEN
    RAISE NOTICE 'PASSOU: volta de finalizada por conclusão antecipada vai ao status em que ela estava (em_transito_destino) e anula a lista de pendências';
  ELSE RAISE NOTICE 'FALHOU: volta da conclusão %', r; END IF;
END $$;
ROLLBACK;

-- Sem pendência, conclui sem a linha.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'na_base');
SELECT qa.como('qa_gestor');
DO $$
DECLARE r jsonb;
BEGIN
  r := public.concluir_escolta_antecipada(current_setting('t.esc')::uuid, 'Fechamento pela gestão sem pendências');
  IF (r ->> 'itens')::int = 0 AND r ->> 'conclusao_id' IS NULL THEN RAISE NOTICE 'PASSOU: sem pendência, conclui normalmente sem a linha de conclusão antecipada';
  ELSE RAISE NOTICE 'FALHOU: conclusão sem pendência %', r; END IF;
END $$;
SELECT pg_temp.pg();
ROLLBACK;

-- ── Zerar para agendada ────────────────────────────────────────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '20 min', 'agendada', 'qa_um', 2)::text, true);
SELECT qa.como('qa_um');
SELECT public.confirmar_presenca_base(current_setting('t.esc')::uuid);
SELECT pg_temp.pg();
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'no_destino');
INSERT INTO public.ocorrencias (escolta_id, tipo_ocorrencia_id, descricao, data_hora, registrado_por)
VALUES (current_setting('t.esc')::uuid, (SELECT id FROM public.dom_tipos_ocorrencia LIMIT 1), 'ocorrência no destino', now(), qa.usuario('qa_um'));
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; n0 int; ef0 text; vt0 text; r jsonb; v jsonb;
BEGIN
  n0 := pg_temp.contar(e, false);
  SELECT string_agg(vigilante_id::text, ',' ORDER BY vigilante_id) INTO ef0 FROM public.escolta_efetivo WHERE escolta_id = e;
  SELECT string_agg(id::text, ',' ORDER BY id) INTO vt0 FROM public.escolta_veiculos WHERE escolta_id = e;
  PERFORM qa.como('qa_gestor');
  r := public.zerar_escolta(e, 'Escolta reiniciada: cliente remarcou a saída', false, public.zerar_escolta(e, NULL, true) -> 'resumo');
  PERFORM pg_temp.pg();
  IF (SELECT status FROM public.escoltas WHERE id = e) = 'agendada'
     AND pg_temp.contar(e, false) = n0 + 1
     AND pg_temp.contar(e, true) = (SELECT count(*) FROM public.escolta_status_historico WHERE escolta_id = e AND anulado_em IS NULL)
     AND (SELECT count(*) FROM public.escolta_status_historico WHERE escolta_id = e AND anulado_em IS NULL AND status_novo NOT IN ('agendada', 'rascunho')) = 0
     AND (SELECT string_agg(vigilante_id::text, ',' ORDER BY vigilante_id) FROM public.escolta_efetivo WHERE escolta_id = e) = ef0
     AND (SELECT string_agg(id::text, ',' ORDER BY id) FROM public.escolta_veiculos WHERE escolta_id = e) = vt0
     AND (SELECT anulado_em IS NOT NULL FROM public.mural_presencas WHERE escolta_id = e)
     AND (SELECT reiniciada_em IS NOT NULL AND quilometragem_saida IS NULL FROM public.escoltas es JOIN public.escolta_veiculos ev ON ev.escolta_id = es.id WHERE es.id = e LIMIT 1)
     AND (SELECT tipo FROM public.escolta_resets WHERE escolta_id = e) = 'zerar' THEN
    RAISE NOTICE 'PASSOU: zerar volta a agendada; todos os registros de campo anulados e nada apagado (% linhas antes, mais a linha do reset); equipe e viaturas iguais; presença do mural anulada; reiniciada_em', n0;
  ELSE RAISE NOTICE 'FALHOU: zerar %', r; END IF;
  -- T2 de novo: a presença anulada não vale e o mesmo vigilante confirma outra vez.
  PERFORM qa.como('qa_um');
  v := public.mural_info(ARRAY[e]);
  PERFORM public.confirmar_presenca_base(e);
  PERFORM pg_temp.pg();
  IF (v -> e::text ->> 'presenca') IS NULL AND (v -> e::text ->> 'eu_confirmei')::boolean = false
     AND (SELECT count(*) FROM public.mural_presencas WHERE escolta_id = e AND anulado_em IS NULL) = 1 THEN
    RAISE NOTICE 'PASSOU: depois de zerar, o mural não conta a presença anulada e o vigilante confirma presença de novo';
  ELSE RAISE NOTICE 'FALHOU: presença depois de zerar %', v; END IF;
  -- O pré-início é feito de novo do começo, e a escolta refeita conta uma vez.
  PERFORM qa.como('qa_gestor');
  PERFORM pg_temp.jornada(e, 'finalizada');
  PERFORM pg_temp.pg();
  IF (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
       WHERE ev.escolta_id = e AND pc.anulado_em IS NULL AND pc.tipo_ponto_id = pg_temp.tp('destino')) = 2
     AND (SELECT count(*) FROM public.escolta_status_historico WHERE escolta_id = e AND anulado_em IS NULL AND status_novo = 'em_andamento') = 1
     AND (SELECT count(*) FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id
           WHERE ev.escolta_id = e AND c.anulado_em IS NULL AND c.tipo = 'material') = 2 THEN
    RAISE NOTICE 'PASSOU: escolta zerada e refeita conta uma vez nos válidos (2 pontos de destino, 1 entrada em andamento, 2 checklists de material)';
  ELSE RAISE NOTICE 'FALHOU: refeita conta em dobro'; END IF;
END $$;
ROLLBACK;

-- ── Cron do check-in ignora arquivada e ponto anulado ──────────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um', 1, 5)::text, true);
SELECT pg_temp.ponto(current_setting('t.esc')::uuid, 1, 'origem', now() - interval '30 min');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; n1 int; n2 int;
BEGIN
  PERFORM set_config('escolta.rpc_gestao', 'on', true);
  UPDATE public.pontos_controle SET anulado_em = now() WHERE escolta_veiculo_id = pg_temp.ev(e, 1);
  PERFORM lote_interno.gerar_avisos_checkin();
  SELECT count(*) INTO n1 FROM public.notificacoes WHERE escolta_id = e;
  -- Sem ponto válido, a referência é a data prevista (1 h atrás): avisa; arquivada: não avisa.
  DELETE FROM public.notificacoes WHERE escolta_id = e;
  UPDATE public.escoltas SET arquivada_em = now() WHERE id = e;
  PERFORM lote_interno.gerar_avisos_checkin();
  SELECT count(*) INTO n2 FROM public.notificacoes WHERE escolta_id = e;
  IF n1 > 0 AND n2 = 0 AND (lote_interno.enfileirar_alerta_checkin(e) ->> 'motivo') = 'arquivada' THEN
    RAISE NOTICE 'PASSOU: aviso de check-in ignora ponto anulado como referência e não sai para escolta arquivada (cron e Telegram)';
  ELSE RAISE NOTICE 'FALHOU: cron com anulado/arquivada: % e %', n1, n2; END IF;
END $$;
ROLLBACK;

-- ── 18.8, item 6: apagar escolta só o administrador, em rascunho e sem registro ──────
BEGIN;
SELECT set_config('t.ag', qa.nova_escolta(now() + interval '1 day', 'agendada', NULL, 1)::text, true);
SELECT set_config('t.ra', qa.nova_escolta(now() + interval '1 day', 'rascunho', NULL, 1)::text, true);
SELECT set_config('t.in', qa.nova_escolta(now(), 'em_andamento', 'qa_um', 1)::text, true);
DO $$
DECLARE n int; v_ok int := 0; u text; e text;
BEGIN
  FOREACH u IN ARRAY ARRAY['qa_gestor', 'qa_administrador'] LOOP
    PERFORM qa.como(u);
    FOREACH e IN ARRAY ARRAY[current_setting('t.ag'), current_setting('t.in')] LOOP
      DELETE FROM public.escoltas WHERE id = e::uuid;
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n = 0 THEN v_ok := v_ok + 1; END IF;
    END LOOP;
    PERFORM pg_temp.pg();
  END LOOP;
  PERFORM qa.como('qa_gestor');
  DELETE FROM public.escoltas WHERE id = current_setting('t.ra')::uuid;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN v_ok := v_ok + 1; END IF;
  PERFORM pg_temp.pg();
  PERFORM qa.como('qa_administrador');
  DELETE FROM public.escoltas WHERE id = current_setting('t.ra')::uuid;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.pg();
  IF v_ok = 5 AND n = 1 THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: gestor e administrador não apagam escolta agendada ou iniciada pela API, gestor não apaga rascunho; só o administrador apaga rascunho sem registro';
  ELSE RAISE NOTICE 'FALHOU: apagar escolta (% de 5 recusas, rascunho apagado %)', v_ok, n; END IF;
END $$;
ROLLBACK;

-- ── 18.8, item 7: excluir usuário que anulou algo é recusado ────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now(), 'agendada', 'qa_um', 1)::text, true);
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'na_origem');
SELECT qa.como('qa_gestor');
SELECT public.voltar_etapa_escolta(current_setting('t.esc')::uuid, 'teste da chave estrangeira', false, public.voltar_etapa_escolta(current_setting('t.esc')::uuid, NULL, true) -> 'resumo') IS NOT NULL;
SELECT pg_temp.pg();
DO $$
BEGIN
  DELETE FROM public.usuarios WHERE id = qa.usuario('qa_gestor');
  RAISE NOTICE 'FALHOU: usuário que anulou registro foi excluído';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: excluir o usuário que anulou registros é recusado pela chave estrangeira (sem ação)';
END $$;
ROLLBACK;

DROP FUNCTION pg_temp.contar(uuid, boolean);
DROP FUNCTION pg_temp.jornada(uuid, text);
DROP FUNCTION pg_temp.ponto(uuid, int, text, timestamptz);
DROP FUNCTION pg_temp.tipo_da_etapa(text);
DROP FUNCTION pg_temp.tp(text);
DROP FUNCTION pg_temp.ev(uuid, int);
DROP FUNCTION pg_temp.pg();
