-- Lançamento retroativo (2026-11-12), migration 222.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa), com a 221 e a 222 aplicadas.
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
-- Etapas da sequência depois de p_desde até finalizada, a partir de p_inicio, uma a cada p_passo,
-- com o fuso de Brasília escrito no texto (como a tela manda).
CREATE FUNCTION pg_temp.etapas(p_desde text, p_inicio timestamptz, p_passo interval DEFAULT interval '30 minutes') RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('status', s,
           'data_hora', to_char((p_inicio + p_passo * (o - 1)) AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS') || '-03:00')
         ORDER BY o)
  FROM unnest((lote_interno.sequencia_status())[array_position(lote_interno.sequencia_status(), p_desde) + 1:]) WITH ORDINALITY AS x(s, o)
$$;
-- Chama a RPC e devolve a mensagem do erro (NULL quando passou).
CREATE FUNCTION pg_temp.erro(p_esc uuid, p_etapas jsonb, p_motivo text, p_previa boolean DEFAULT true, p_resumo jsonb DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.lancar_escolta_retroativa(p_esc, p_etapas, p_motivo, p_previa, p_resumo);
  RETURN NULL;
EXCEPTION WHEN others THEN RETURN SQLERRM;
END $$;

-- ── 1. Estrutura e privilégios ────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT has_function_privilege('anon', 'public.lancar_escolta_retroativa(uuid, jsonb, text, boolean, jsonb)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.lancar_escolta_retroativa(uuid, jsonb, text, boolean, jsonb)', 'EXECUTE') THEN
    RAISE NOTICE 'PASSOU: lancar_escolta_retroativa só para authenticated (anon sem EXECUTE)';
  ELSE RAISE NOTICE 'FALHOU: privilégios da lancar_escolta_retroativa'; END IF;
  IF (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc
       WHERE oid = 'public.lancar_escolta_retroativa(uuid, jsonb, text, boolean, jsonb)'::regprocedure) THEN
    RAISE NOTICE 'PASSOU: SECURITY DEFINER com search_path fixo';
  ELSE RAISE NOTICE 'FALHOU: RPC sem SECURITY DEFINER ou sem search_path'; END IF;
  IF NOT has_function_privilege('authenticated', 'lote_interno.ultimo_registro_campo(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'lote_interno.travar_colunas_retroativo()', 'EXECUTE') THEN
    RAISE NOTICE 'PASSOU: funções internas sem EXECUTE para authenticated';
  ELSE RAISE NOTICE 'FALHOU: função interna da 222 exposta'; END IF;
END $$;

-- ── 2. Trava de perfil: operador, supervisor e central recusados ──────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 day', 'agendada', 'qa_um', 1)::text, true);
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; u text; v_ok int := 0; v_tot int := 0; v_et jsonb;
BEGIN
  v_et := pg_temp.etapas('agendada', now() - interval '1 day');
  FOREACH u IN ARRAY ARRAY['qa_um', 'qa_supervisor', 'qa_central'] LOOP
    PERFORM qa.como(u);
    v_tot := v_tot + 2;
    BEGIN
      PERFORM public.lancar_escolta_retroativa(e, v_et, 'motivo do teste retroativo', true);
      RAISE NOTICE 'FALHOU: % fez a prévia', u;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1;
    END;
    BEGIN
      PERFORM public.lancar_escolta_retroativa(e, v_et, 'motivo do teste retroativo', false, '{}'::jsonb);
      RAISE NOTICE 'FALHOU: % confirmou', u;
    EXCEPTION WHEN insufficient_privilege THEN v_ok := v_ok + 1;
    END;
    PERFORM pg_temp.pg();
  END LOOP;
  IF v_ok = v_tot THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador, supervisor e central recusados (% chamadas)', v_tot;
  ELSE RAISE NOTICE 'FALHOU: % de % chamadas recusadas', v_ok, v_tot; END IF;
  IF (SELECT status FROM public.escoltas WHERE id = e) = 'agendada' THEN
    RAISE NOTICE 'PASSOU: escolta intacta depois das recusas';
  ELSE RAISE NOTICE 'FALHOU: escolta mudou'; END IF;
END $$;
-- Colunas do retroativo travadas fora da RPC, até para o gestor.
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['qa_supervisor', 'qa_gestor'] LOOP
    PERFORM qa.como(u);
    BEGIN
      UPDATE public.escoltas SET lancamento_retroativo = true WHERE id = e;
      IF FOUND THEN RAISE NOTICE 'FALHOU: % marcou a escolta como retroativa por UPDATE direto', u;
      ELSE RAISE NOTICE 'BLOQUEADO CORRETAMENTE: % não alcança a escolta por UPDATE direto', u; END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'BLOQUEADO CORRETAMENTE: % não marca lancamento_retroativo por UPDATE direto', u;
    END;
    PERFORM pg_temp.pg();
  END LOOP;
END $$;
ROLLBACK;

-- ── 3. Validações (gestor) ────────────────────────────────────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 day', 'agendada', 'qa_um', 1)::text, true);
SELECT qa.como('qa_gestor');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; v_et jsonb := pg_temp.etapas('agendada', now() - interval '1 day'); m text;
BEGIN
  m := pg_temp.erro(e, v_et, 'curto');
  IF m LIKE '%10 caracteres%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: motivo curto (%)', m;
  ELSE RAISE NOTICE 'FALHOU: motivo curto aceito (%)', m; END IF;

  m := pg_temp.erro(e, v_et - 0, 'motivo do teste retroativo');                       -- sem o pré-início
  IF m LIKE 'Etapa pulada%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: etapa pulada (%)', m;
  ELSE RAISE NOTICE 'FALHOU: etapa pulada aceita (%)', m; END IF;

  m := pg_temp.erro(e, jsonb_build_array(jsonb_build_object('status', 'agendada', 'data_hora', now() - interval '2 days')) || v_et,
                    'motivo do teste retroativo');
  IF m LIKE 'Etapa repetida%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: etapa repetida (%)', m;
  ELSE RAISE NOTICE 'FALHOU: etapa repetida aceita (%)', m; END IF;

  m := pg_temp.erro(e, v_et - (jsonb_array_length(v_et) - 1), 'motivo do teste retroativo'); -- para em Na Base
  IF m LIKE '%precisa ir até Finalizada%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: lançamento que não termina em Finalizada (%)', m;
  ELSE RAISE NOTICE 'FALHOU: lançamento parcial aceito (%)', m; END IF;

  m := pg_temp.erro(e, jsonb_set(v_et, '{2,data_hora}', v_et -> 0 -> 'data_hora'), 'motivo do teste retroativo');
  IF m LIKE 'Horários fora de ordem%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: horário fora de ordem (%)', m;
  ELSE RAISE NOTICE 'FALHOU: horário fora de ordem aceito (%)', m; END IF;

  m := pg_temp.erro(e, pg_temp.etapas('agendada', now() - interval '1 hour'), 'motivo do teste retroativo');
  IF m LIKE 'Horário no futuro%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: horário no futuro (%)', m;
  ELSE RAISE NOTICE 'FALHOU: horário no futuro aceito (%)', m; END IF;

  m := pg_temp.erro(e, pg_temp.etapas('agendada', now() - interval '31 days'), 'motivo do teste retroativo');
  IF m LIKE '%até 30 dias%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: mais de 30 dias (%)', m;
  ELSE RAISE NOTICE 'FALHOU: lançamento de 31 dias aceito (%)', m; END IF;

  m := pg_temp.erro(e, jsonb_set(v_et, '{0,data_hora}', '"2026-11-10T08:00:00"'), 'motivo do teste retroativo');
  IF m LIKE '%sem fuso%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: horário sem fuso (%)', m;
  ELSE RAISE NOTICE 'FALHOU: horário sem fuso aceito (%)', m; END IF;

  m := pg_temp.erro(e, jsonb_set(v_et, '{0,foto_ids}', '["00000000-0000-4000-8000-000000000001"]'), 'motivo do teste retroativo');
  IF m LIKE '%foto não se aplica%' OR m LIKE 'Foto que não serve%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: foto inexistente ou em etapa sem ponto (%)', m;
  ELSE RAISE NOTICE 'FALHOU: foto inválida aceita (%)', m; END IF;

  m := pg_temp.erro(e, v_et, 'motivo do teste retroativo', false, NULL);
  IF m LIKE 'Confira antes%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: confirmação sem o resumo da prévia';
  ELSE RAISE NOTICE 'FALHOU: confirmação sem resumo (%)', m; END IF;

  m := pg_temp.erro(e, v_et, 'motivo do teste retroativo', false,
                    jsonb_set(public.lancar_escolta_retroativa(e, v_et, 'motivo do teste retroativo', true) -> 'resumo', '{versao_gestao}', '999'));
  IF m LIKE '%mudaram desde a conferência%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: resumo divergente da prévia';
  ELSE RAISE NOTICE 'FALHOU: resumo divergente aceito (%)', m; END IF;

  -- Etapas mudadas entre a prévia e a confirmação (mesmo resumo, outro horário).
  m := pg_temp.erro(e, jsonb_set(v_et, '{0,data_hora}', to_jsonb(now() - interval '25 hours')), 'motivo do teste retroativo', false,
                    public.lancar_escolta_retroativa(e, v_et, 'motivo do teste retroativo', true) -> 'resumo');
  IF m LIKE '%mudaram desde a conferência%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: etapas trocadas depois da prévia';
  ELSE RAISE NOTICE 'FALHOU: etapas trocadas aceitas (%)', m; END IF;
END $$;
SELECT pg_temp.pg();
-- Status de partida: rascunho, finalizada e cancelada recusadas.
DO $$
DECLARE s text; e uuid; m text;
BEGIN
  FOREACH s IN ARRAY ARRAY['rascunho', 'finalizada', 'cancelada'] LOOP
    e := qa.nova_escolta(now() - interval '1 day', s, 'qa_um', 1);
    PERFORM qa.como('qa_gestor');
    m := pg_temp.erro(e, pg_temp.etapas('agendada', now() - interval '1 day'), 'motivo do teste retroativo');
    PERFORM pg_temp.pg();
    IF m LIKE '%vale para escolta de Agendada até Na Base%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: partida em % recusada', s;
    ELSE RAISE NOTICE 'FALHOU: partida em % (%)', s, m; END IF;
  END LOOP;
END $$;
ROLLBACK;

-- ── 4. Lançamento completo (gestor, de Agendada a Finalizada, comboio de 2 viaturas) ──
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '2 days', 'agendada', 'qa_um', 2)::text, true);
SELECT set_config('t.ini', (date_trunc('minute', now()) - interval '2 days')::text, true);
SELECT qa.como('qa_gestor');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; ini timestamptz := current_setting('t.ini')::timestamptz;
        v_et jsonb; p jsonb; r jsonb;
BEGIN
  v_et := pg_temp.etapas('agendada', ini, interval '1 hour');
  p := public.lancar_escolta_retroativa(e, v_et, 'Operador ficou sem bateria, lançado pela gestão', true);
  IF (p ->> 'previa')::boolean AND (p ->> 'total_etapas')::int = 9 AND (p ->> 'etapas_sem_foto')::int = 7
     AND (p ->> 'data_finalizacao')::timestamptz = ini + interval '8 hours' THEN
    RAISE NOTICE 'PASSOU: prévia com 9 etapas, 7 sem foto marcadas e término na última etapa';
  ELSE RAISE NOTICE 'FALHOU: prévia inesperada: %', p; END IF;
  IF (SELECT status FROM public.escoltas WHERE id = e) = 'agendada' THEN RAISE NOTICE 'PASSOU: a prévia não grava nada';
  ELSE RAISE NOTICE 'FALHOU: a prévia gravou'; END IF;
  r := public.lancar_escolta_retroativa(e, v_et, 'Operador ficou sem bateria, lançado pela gestão', false, p -> 'resumo');
  IF (r ->> 'ok')::boolean AND (r ->> 'pontos')::int = 14 THEN RAISE NOTICE 'PASSOU: confirmação gravou 14 pontos (7 etapas x 2 viaturas)';
  ELSE RAISE NOTICE 'FALHOU: confirmação: %', r; END IF;
END $$;
SELECT pg_temp.pg();
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; ini timestamptz := current_setting('t.ini')::timestamptz; x record; n int;
BEGIN
  SELECT * INTO x FROM public.escoltas WHERE id = e;
  IF x.status = 'finalizada' AND x.data_finalizacao = ini + interval '8 hours' THEN
    RAISE NOTICE 'PASSOU: finalizada com data_finalizacao = horário da última etapa (não now())';
  ELSE RAISE NOTICE 'FALHOU: status % e data_finalizacao %', x.status, x.data_finalizacao; END IF;
  IF x.lancamento_retroativo AND x.retroativo_por = qa.usuario('qa_gestor') AND x.retroativo_em IS NOT NULL
     AND x.retroativo_motivo = 'Operador ficou sem bateria, lançado pela gestão' AND x.versao_gestao >= 1 THEN
    RAISE NOTICE 'PASSOU: flag, autor, horário e motivo do retroativo na escolta';
  ELSE RAISE NOTICE 'FALHOU: marcas da escolta: % % %', x.lancamento_retroativo, x.retroativo_por, x.retroativo_motivo; END IF;

  SELECT count(*) INTO n FROM public.escolta_status_historico h
   WHERE h.escolta_id = e AND h.retroativo AND h.via_rpc AND h.registrado_em > h.data_hora
     AND h.motivo_retroativo IS NOT NULL AND h.data_hora BETWEEN ini AND ini + interval '8 hours';
  IF n = 9 THEN RAISE NOTICE 'PASSOU: 9 linhas de histórico retroativas, horário operacional informado e registrado_em do servidor';
  ELSE RAISE NOTICE 'FALHOU: % linhas de histórico retroativas', n; END IF;
  IF (SELECT array_agg(status_novo ORDER BY data_hora) FROM public.escolta_status_historico WHERE escolta_id = e AND retroativo)
     = (lote_interno.sequencia_status())[3:] THEN
    RAISE NOTICE 'PASSOU: histórico na ordem da sequência, sem pular nem repetir';
  ELSE RAISE NOTICE 'FALHOU: ordem do histórico'; END IF;

  SELECT count(*) INTO n FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
   WHERE ev.escolta_id = e AND pc.retroativo AND pc.latitude IS NULL AND pc.longitude IS NULL
     AND (pc.observacoes::jsonb ->> 'sem_foto')::boolean AND pc.lancado_por = qa.usuario('qa_gestor');
  IF n = 14 THEN RAISE NOTICE 'PASSOU: pontos retroativos sem GPS, marcados sem foto, em nome do gestor';
  ELSE RAISE NOTICE 'FALHOU: % pontos retroativos sem GPS', n; END IF;

  SELECT count(*) INTO n FROM public.avisos_telegram WHERE escolta_id = e;
  IF n = CASE WHEN public.avisos_pelo_banco_ativos() THEN 1 ELSE 0 END
     AND NOT EXISTS (SELECT 1 FROM public.avisos_telegram WHERE escolta_id = e AND evento_chave NOT LIKE 'gestao:retroativo:%') THEN
    RAISE NOTICE 'PASSOU: Telegram com um só resumo (% na fila; 0 quando o envio pelo banco está desligado)', n;
  ELSE RAISE NOTICE 'FALHOU: % avisos de Telegram para a escolta', n; END IF;
  IF public.avisos_pelo_banco_ativos() AND NOT EXISTS (SELECT 1 FROM public.avisos_telegram WHERE escolta_id = e
       AND texto LIKE '%Lançamento retroativo%' AND texto LIKE '%Motivo: Operador ficou sem bateria%'
       AND texto LIKE '%' || public._hora_br(ini) || '%') THEN
    RAISE NOTICE 'FALHOU: texto do resumo sem título, horário de Brasília ou motivo';
  ELSE RAISE NOTICE 'PASSOU: resumo com título, horários de Brasília e motivo (ou envio pelo banco desligado)'; END IF;

  SELECT count(DISTINCT evento_chave) INTO n FROM public.notificacoes WHERE escolta_id = e;
  IF n <= 1 AND NOT EXISTS (SELECT 1 FROM public.notificacoes WHERE escolta_id = e AND evento_chave NOT LIKE 'retroativo:%') THEN
    RAISE NOTICE 'PASSOU: central de avisos com um só evento (retroativo:...)';
  ELSE RAISE NOTICE 'FALHOU: % eventos na central de avisos', n; END IF;

  IF (SELECT count(*) FROM public.logs_auditoria WHERE registro_id = e AND acao = 'LANCAMENTO_RETROATIVO'
        AND dados_antes ->> 'status' = 'agendada' AND dados_depois ->> 'status' = 'finalizada') = 1 THEN
    RAISE NOTICE 'PASSOU: auditoria LANCAMENTO_RETROATIVO com antes e depois';
  ELSE RAISE NOTICE 'FALHOU: auditoria'; END IF;
  IF coalesce(current_setting('escolta.lancamento_retroativo', true), '') <> 'on' THEN
    RAISE NOTICE 'PASSOU: variável de sessão desligada no fim';
  ELSE RAISE NOTICE 'FALHOU: variável continuou ligada'; END IF;
END $$;
-- Segundo lançamento na mesma escolta: finalizada não aceita.
SELECT qa.como('qa_gestor');
DO $$
DECLARE m text;
BEGIN
  m := pg_temp.erro(current_setting('t.esc')::uuid, pg_temp.etapas('na_base', now() - interval '1 hour'), 'motivo do teste retroativo');
  IF m IS NOT NULL THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: escolta finalizada não recebe novo lançamento';
  ELSE RAISE NOTICE 'FALHOU: lançou de novo'; END IF;
END $$;
SELECT pg_temp.pg();
ROLLBACK;

-- ── 5. Administrador, a partir de uma etapa do meio, com registro ao vivo anterior ───
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 day', 'no_destino', 'qa_um', 1)::text, true);
-- Ponto ao vivo de 6 horas atrás (o último registro de campo).
INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por, observacoes)
SELECT ev.id, (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'destino'), now() - interval '6 hours', -22.8, -43.3,
       qa.usuario('qa_um'), '{"foto_ids":[]}'
  FROM public.escolta_veiculos ev WHERE ev.escolta_id = current_setting('t.esc')::uuid;
SELECT qa.como('qa_administrador');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; m text; p jsonb; r jsonb;
BEGIN
  m := pg_temp.erro(e, pg_temp.etapas('no_destino', now() - interval '7 hours'), 'motivo do teste retroativo');
  IF m LIKE '%depois do último registro%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: horário anterior ao último registro ao vivo';
  ELSE RAISE NOTICE 'FALHOU: horário anterior ao último registro (%)', m; END IF;
  p := public.lancar_escolta_retroativa(e, pg_temp.etapas('no_destino', now() - interval '5 hours'), 'Celular sem sinal no retorno', true);
  r := public.lancar_escolta_retroativa(e, pg_temp.etapas('no_destino', now() - interval '5 hours'), 'Celular sem sinal no retorno', false, p -> 'resumo');
  IF (r ->> 'de') = 'no_destino' AND (r ->> 'etapas')::int = 4 THEN
    RAISE NOTICE 'PASSOU: administrador lança de No Destino até Finalizada (4 etapas)';
  ELSE RAISE NOTICE 'FALHOU: %', r; END IF;
  IF (SELECT count(*) FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
       WHERE ev.escolta_id = e AND NOT pc.retroativo AND pc.latitude = -22.8) = 1 THEN
    RAISE NOTICE 'PASSOU: ponto ao vivo intacto (retroativo = false, GPS original)';
  ELSE RAISE NOTICE 'FALHOU: ponto ao vivo alterado'; END IF;
END $$;
SELECT pg_temp.pg();
ROLLBACK;

-- ── 6. Registro ao vivo continua igual ────────────────────────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um', 1)::text, true);
SELECT qa.como('qa_um');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; v_ev uuid; x record;
BEGIN
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = e LIMIT 1;
  PERFORM public.registrar_etapa_escolta(e, jsonb_build_array(jsonb_build_object('escolta_veiculo_id', v_ev,
    'tipo_ponto_id', (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'origem'), 'latitude', -22.9, 'longitude', -43.2,
    'observacoes', '{"foto_ids":[]}')), 'em_andamento', 'na_origem', NULL, -22.9, -43.2, NULL, NULL,
    (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'origem'));
  SELECT pc.retroativo, pc.registrado_em, pc.latitude INTO x FROM public.pontos_controle pc WHERE pc.escolta_veiculo_id = v_ev;
  IF NOT x.retroativo AND x.registrado_em IS NOT NULL AND x.latitude = -22.9 THEN
    RAISE NOTICE 'PASSOU: ponto ao vivo com retroativo = false, GPS e registrado_em do servidor';
  ELSE RAISE NOTICE 'FALHOU: ponto ao vivo: %', x; END IF;
  BEGIN
    INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, lancado_por, retroativo)
    VALUES (v_ev, (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'origem'), now(), public.get_meu_usuario_id(), true);
    RAISE NOTICE 'FALHOU: operador gravou ponto marcado como retroativo';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não marca ponto como retroativo';
  END;
END $$;
SELECT pg_temp.pg();
ROLLBACK;
