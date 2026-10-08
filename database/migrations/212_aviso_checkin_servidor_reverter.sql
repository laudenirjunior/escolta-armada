-- 212_aviso_checkin_servidor_reverter.sql
-- ORDEM: primeiro o git revert do código da onda J e o deploy (o alerta volta a ser
-- calculado no navegador); depois este arquivo; a 211 só depois dele.
-- Desagenda o cron, remove as funções internas e devolve enfileirar_alerta_checkin ao
-- corpo da 208. Os avisos de check-in já gravados ficam (a reversão da 211 os guarda).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lote2026_avisos_checkin';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.enfileirar_alerta_checkin(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; e record; v_ultima timestamptz; v_atraso int; v_ok boolean;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(p_escolta_id) THEN
    RAISE EXCEPTION 'Sem permissao para esta escolta.';
  END IF;
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
  -- número do período). Antes saía uma a cada 5 min por navegador aberto.
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
REVOKE ALL ON FUNCTION public.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enfileirar_alerta_checkin(uuid) TO authenticated;

DROP FUNCTION IF EXISTS lote_interno.gerar_avisos_checkin(timestamptz);
DROP FUNCTION IF EXISTS lote_interno.enfileirar_alerta_checkin(uuid);
DROP FUNCTION IF EXISTS lote_interno.tipo_da_observacao(text);
