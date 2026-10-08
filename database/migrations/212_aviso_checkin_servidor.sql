-- 212_aviso_checkin_servidor.sql
-- Lote 2026-10, onda J. Idempotente. Bloco 1, depois da 211 (usa lote_interno.notificar) e
-- da 208 (reescreve enfileirar_alerta_checkin). Compatível com a master: o código antigo
-- não chama nada daqui, e com a periodicidade nula em todas as escoltas abertas (201) o
-- cron não gera nada até um cliente ter a chave de check-in.
--
-- Por quê (docs/14, seção 11.3; decisões S2, S3 e S4): o aviso de check-in vencido era
-- calculado em cada navegador aberto (N+2 consultas por escolta por minuto) e o Telegram
-- dependia de haver navegador aberto. Agora o banco calcula uma vez por minuto (pg_cron),
-- grava o aviso na central de cada destinatário e enfileira o Telegram.
--
-- Regra (porte de minutosAteCheckin, lib/checkin.ts): status em STATUS_COM_CHECKIN, com
-- periodicidade; referência = último ponto PARADA com observacoes JSON tipo
-- reporte_periodico, senão o primeiro ponto da escolta, senão a data prevista; vencido
-- quando o atraso passa de 1 minuto. Um aviso por período vencido (S3): chave
-- checkin:<escolta>:<epoch da referência>:<n do período>. Destinatários (S2): efetivo da
-- escolta, administrador, gestor, supervisor e central ativos.
-- Telegram (S4): mesma regra e mesmo texto da 208 (regra antiga, pendência 0.3), agora
-- chamado pelo cron; enfileirar_alerta_checkin (208) continua para o app e passa a
-- delegar à função interna depois da guarda de perfil.
-- Arquivamento e anulação (onda I) não existem aqui: a 214 recria gerar_avisos_checkin
-- com os dois filtros.
-- Limpeza: avisos lidos há mais de 90 dias são apagados pelo mesmo cron.

-- Tipo da observação JSON do ponto; texto legado ou JSON quebrado nunca derruba o cron.
CREATE OR REPLACE FUNCTION lote_interno.tipo_da_observacao(p_obs text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF p_obs IS NULL OR left(ltrim(p_obs), 1) <> '{' THEN RETURN NULL; END IF;
  RETURN p_obs::jsonb ->> 'tipo';
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.tipo_da_observacao(text) FROM PUBLIC, anon, authenticated;

-- Telegram do check-in: corpo da 208 sem a guarda de perfil (o cron roda sem usuário).
CREATE OR REPLACE FUNCTION lote_interno.enfileirar_alerta_checkin(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE e record; v_ultima timestamptz; v_atraso int; v_ok boolean;
BEGIN
  SELECT es.id, es.codigo_escolta, es.status, es.periodicidade_checkin_min, c.nome_cliente INTO e
  FROM public.escoltas es JOIN public.clientes c ON c.id = es.cliente_id WHERE es.id = p_escolta_id;
  IF e.id IS NULL OR e.periodicidade_checkin_min IS NULL
     OR e.status NOT IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando') THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem check-in periodico');
  END IF;
  -- Regra antiga (pendência 0.3 de docs/12): qualquer PARADA zera o prazo; sem nenhuma, não notifica.
  SELECT max(pc.data_hora) INTO v_ultima
  FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
  WHERE ev.escolta_id = p_escolta_id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760';
  IF v_ultima IS NULL THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem parada'); END IF;
  v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - e.periodicidade_checkin_min;
  IF v_atraso < 1 THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'em dia'); END IF;
  -- Uma mensagem por período vencido sem check-in (chave: escolta, última parada e
  -- número do período).
  v_ok := public._enfileirar_aviso('checkin:' || p_escolta_id || ':' || extract(epoch FROM v_ultima)::bigint
                                   || ':' || floor(v_atraso::numeric / e.periodicidade_checkin_min)::int, 'cliente', p_escolta_id,
    '<b>Alerta: check-in em atraso</b>' || E'\n'
    || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(e.nome_cliente) || E'\n'
    || 'Sem check-in há ' || (v_atraso + e.periodicidade_checkin_min) || ' minutos (periodicidade de '
    || e.periodicidade_checkin_min || ' min).' || E'\n'
    || 'Registrado em ' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (Brasília)');
  RETURN jsonb_build_object('enfileirado', v_ok);
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon, authenticated;

-- RPC da 208 (o app ainda pode chamar): guarda de perfil e delega.
CREATE OR REPLACE FUNCTION public.enfileirar_alerta_checkin(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(p_escolta_id) THEN
    RAISE EXCEPTION 'Sem permissao para esta escolta.';
  END IF;
  RETURN lote_interno.enfileirar_alerta_checkin(p_escolta_id);
END;
$$;
REVOKE ALL ON FUNCTION public.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enfileirar_alerta_checkin(uuid) TO authenticated;

-- Ciclo do cron. p_agora existe só para o teste avançar o relógio; o cron usa now().
CREATE OR REPLACE FUNCTION lote_interno.gerar_avisos_checkin(p_agora timestamptz DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  r record; v_gestao uuid[]; v_n int := 0; v_atraso int; v_periodo int; v_telegram boolean;
BEGIN
  SELECT coalesce(array_agg(u.id), '{}') INTO v_gestao
  FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor', 'central');
  v_telegram := public.avisos_pelo_banco_ativos();

  FOR r IN
    SELECT e.id, e.codigo_escolta, e.periodicidade_checkin_min AS per, c.nome_cliente,
           coalesce(
             (SELECT max(pc.data_hora) FROM public.pontos_controle pc
                JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
               WHERE ev.escolta_id = e.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
                 AND lote_interno.tipo_da_observacao(pc.observacoes) = 'reporte_periodico'),
             (SELECT min(pc.data_hora) FROM public.pontos_controle pc
                JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
               WHERE ev.escolta_id = e.id),
             e.data_hora_prevista) AS referencia
    FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
    WHERE e.periodicidade_checkin_min > 0
      AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
  LOOP
    IF r.referencia IS NOT NULL THEN
      v_atraso := floor(extract(epoch FROM (p_agora - r.referencia)) / 60) - r.per;
      IF v_atraso >= 1 THEN
        v_periodo := floor(extract(epoch FROM (p_agora - r.referencia)) / 60 / r.per)::int;
        v_n := v_n + lote_interno.notificar(
          'checkin:' || r.id || ':' || floor(extract(epoch FROM r.referencia))::bigint || ':' || v_periodo,
          r.id, 'checkin_vencido',
          ARRAY(SELECT v.usuario_id FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
                 WHERE ee.escolta_id = r.id AND v.usuario_id IS NOT NULL) || v_gestao,
          'Check-in atrasado: ' || r.codigo_escolta,
          'Escolta ' || r.codigo_escolta || ' · ' || r.nome_cliente || ': sem check-in há ' || (v_atraso + r.per)
            || ' min (periodicidade de ' || r.per || ' min, ' || v_atraso || ' min de atraso). Prazo vencido em '
            || to_char((r.referencia + make_interval(mins => r.per * v_periodo)) AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
            || ' (Brasília).',
          jsonb_build_object('referencia', r.referencia, 'periodo', v_periodo, 'periodicidade_min', r.per));
      END IF;
    END IF;
    -- Telegram pela regra antiga (a função decide); erro numa escolta não para o ciclo.
    IF v_telegram THEN
      BEGIN
        PERFORM lote_interno.enfileirar_alerta_checkin(r.id);
      EXCEPTION WHEN others THEN
        RAISE WARNING 'gerar_avisos_checkin: Telegram da escolta % falhou: %', r.id, SQLERRM;
      END;
    END IF;
  END LOOP;

  DELETE FROM public.notificacoes WHERE lida AND lida_em < p_agora - interval '90 days';
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.gerar_avisos_checkin(timestamptz) FROM PUBLIC, anon, authenticated;

-- Agendamento a cada minuto (só com pg_cron). cron.schedule com o mesmo nome atualiza.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    EXECUTE $q$SELECT cron.schedule('lote2026_avisos_checkin', '* * * * *', 'SELECT lote_interno.gerar_avisos_checkin();')$q$;
  END IF;
END $$;

-- Conferência:
-- SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'lote2026_avisos_checkin';   -- 1 linha
-- SELECT lote_interno.gerar_avisos_checkin();   -- 0 enquanto nenhuma escolta aberta tiver periodicidade
-- SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lote_interno'
--   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE')); -- 0
