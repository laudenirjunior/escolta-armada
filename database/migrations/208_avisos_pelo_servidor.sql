-- 208_avisos_pelo_servidor.sql
-- Lote 2026-10, onda F. Idempotente. Bloco 1. Depende da 202 (fila avisos_telegram).
--
-- Por quê (docs/13, H10 e H12; comando, onda F, item 3): o alerta de check-in e o aviso de
-- presença iam ao Telegram uma vez por navegador aberto. Com estas funções o navegador
-- só pede o enfileiramento; a chave única por evento garante uma mensagem, e o envio é
-- do banco (202). Sem o envio pelo banco configurado, as funções devolvem
-- enfileirado = false e o app continua pelo /api/telegram, como antes.
-- Limite declarado: a fila manda só texto; a foto da presença não vai pelo banco.

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
  -- Uma mensagem por prazo vencido (chave: escolta e última parada).
  v_ok := public._enfileirar_aviso('checkin:' || p_escolta_id || ':' || extract(epoch FROM v_ultima)::bigint, 'cliente', p_escolta_id,
    '<b>Alerta: check-in em atraso</b>' || E'\n'
    || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(e.nome_cliente) || E'\n'
    || 'Sem check-in há ' || (v_atraso + e.periodicidade_checkin_min) || ' minutos (periodicidade de '
    || e.periodicidade_checkin_min || ' min).' || E'\n'
    || 'Registrado em ' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (Brasília)');
  RETURN jsonb_build_object('enfileirado', v_ok);
END;
$$;

CREATE OR REPLACE FUNCTION public.enfileirar_aviso_presenca(p_presenca_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; p record; v_ok boolean;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  SELECT pr.id, pr.escolta_id, pr.data_hora, v.nome_completo, es.codigo_escolta, c.nome_cliente INTO p
  FROM public.presencas pr
  JOIN public.vigilantes v ON v.id = pr.vigilante_id
  JOIN public.escoltas es ON es.id = pr.escolta_id
  JOIN public.clientes c ON c.id = es.cliente_id
  WHERE pr.id = p_presenca_id;
  IF p.id IS NULL THEN RETURN jsonb_build_object('enfileirado', false); END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(p.escolta_id) THEN
    RAISE EXCEPTION 'Sem permissao para esta escolta.';
  END IF;
  v_ok := public._enfileirar_aviso('presenca:' || p_presenca_id, 'cliente', p.escolta_id,
    '<b>Presença confirmada</b>' || E'\n'
    || 'Escolta: <code>' || public.escapar_html(p.codigo_escolta) || '</code> · ' || public.escapar_html(p.nome_cliente) || E'\n'
    || public.escapar_html(p.nome_completo) || ' confirmou presença em '
    || to_char(p.data_hora AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (Brasília).');
  RETURN jsonb_build_object('enfileirado', v_ok);
END;
$$;
REVOKE ALL ON FUNCTION public.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.enfileirar_aviso_presenca(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enfileirar_alerta_checkin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.enfileirar_aviso_presenca(uuid) TO authenticated;
