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
-- reporte_periodico, senão o primeiro ponto da escolta, senão a data prevista. Atraso com
-- o mesmo arredondamento da tela (-floor((periodicidade - decorrido) / 1 min)): o primeiro
-- aviso sai logo que a periodicidade vence (atraso 1, como o Painel e o detalhe mostram),
-- e os seguintes a cada periodicidade (período n cobre de n a n+1 periodicidades). Um
-- aviso por período vencido (S3): chave checkin:<escolta>:<epoch da referência>:<n>.
-- Destinatários (S2): efetivo da escolta, administrador, gestor, supervisor e central ativos.
-- Cada escolta do ciclo roda no próprio bloco BEGIN ... EXCEPTION: erro numa não desfaz
-- os avisos das outras, o Telegram nem a limpeza.
-- Telegram (S4): mesma regra e mesmo texto da 208 (regra antiga, pendência 0.3). Quem manda:
-- - o cron, só com o envio pelo banco ativo (avisos_pelo_banco_ativos) E
--   configuracao_avisos.checkin_telegram_pelo_cron ligada. A coluna nasce falsa aqui
--   (bloco 1) e a 217 (bloco 2, depois do deploy) a liga: até o deploy, quem manda é o
--   navegador da master (CheckinAlertProvider), e o cron não pode mandar junto (dobraria);
-- - fora disso (Vault sem segredo, pg_net ou pg_cron recusados, envio desligado), o
--   navegador de quem recebe o aviso (gestão ou equipe da escolta) pelo /api/telegram, como
--   a master fazia, mas só depois de reservar a chave do evento no banco por
--   reservar_alertas_checkin() (padrão da reservar_aviso_presenca da 208): uma mensagem por
--   evento, mesmo com vários navegadores abertos (item 6.2.3: não calar o Telegram de hoje).
-- A chave reservada pelo navegador e a enfileirada pelo cron são a mesma: quem chega
-- depois não manda (troca de caminho sem mensagem dobrada).
-- enfileirar_alerta_checkin (208) continua para o app e passa a delegar à função interna
-- depois da guarda de perfil.
-- Arquivamento e anulação (onda I) não existem aqui: a 214 recria gerar_avisos_checkin
-- com os dois filtros.
-- Limpeza: avisos lidos há mais de 90 dias são apagados pelo mesmo cron.

-- Quem manda o Telegram do check-in (ver o cabeçalho). Falsa até a 217 (bloco 2).
ALTER TABLE public.configuracao_avisos
  ADD COLUMN IF NOT EXISTS checkin_telegram_pelo_cron boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.configuracao_avisos.checkin_telegram_pelo_cron IS
  'Lote 2026-10 (onda J): o cron enfileira o Telegram do check-in vencido. Ligada pela 217 (bloco 2), depois do deploy; antes, o navegador da master manda.';

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
DECLARE e record; v_ultima timestamptz; v_atraso int; v_ok boolean; v_chave text;
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
  v_chave := 'checkin:' || p_escolta_id || ':' || extract(epoch FROM v_ultima)::bigint
             || ':' || floor(v_atraso::numeric / e.periodicidade_checkin_min)::int;
  -- Já mandada por um navegador (reservar_alertas_checkin): não manda de novo.
  IF EXISTS (SELECT 1 FROM public.avisos_reservados WHERE chave = v_chave) THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'enviado pelo navegador');
  END IF;
  v_ok := public._enfileirar_aviso(v_chave, 'cliente', p_escolta_id,
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
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(p_escolta_id) THEN
    RAISE EXCEPTION 'Sem permissão para esta escolta.';
  END IF;
  RETURN lote_interno.enfileirar_alerta_checkin(p_escolta_id);
END;
$$;
REVOKE ALL ON FUNCTION public.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enfileirar_alerta_checkin(uuid) TO authenticated;

-- Telegram do check-in pelo navegador, quando o cron não manda (ver o cabeçalho). Devolve as
-- escoltas cujo alerta este navegador acabou de reservar, com o que a mensagem antiga leva
-- (mesmo texto e destino da master: /api/telegram com escolta_id, chat do cliente). Só a
-- gestão (todas as escoltas) e a equipe (as próprias) recebem algo; a chave é a mesma do
-- cron, e só o primeiro navegador a reserva.
CREATE OR REPLACE FUNCTION public.reservar_alertas_checkin() RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text; v_eu uuid; v_gestao boolean; r record; v_ultima timestamptz; v_atraso int;
  v_chave text; v_n int; v_saida jsonb := '[]'::jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  -- O cron manda: nada para o navegador.
  IF public.avisos_pelo_banco_ativos()
     AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false) THEN
    RETURN v_saida;
  END IF;
  v_eu := public.get_meu_usuario_id();
  v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
  FOR r IN
    SELECT e.id, e.codigo_escolta, e.status, e.periodicidade_checkin_min AS per, c.nome_cliente
    FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
    WHERE e.periodicidade_checkin_min > 0
      AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
      AND (v_gestao OR public.sou_do_efetivo(e.id))
  LOOP
    -- Regra antiga (pendência 0.3), a mesma de lote_interno.enfileirar_alerta_checkin.
    SELECT max(pc.data_hora) INTO v_ultima
    FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
    WHERE ev.escolta_id = r.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760';
    CONTINUE WHEN v_ultima IS NULL;
    v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - r.per;
    CONTINUE WHEN v_atraso < 1;
    v_chave := 'checkin:' || r.id || ':' || extract(epoch FROM v_ultima)::bigint || ':' || floor(v_atraso::numeric / r.per)::int;
    -- Já enfileirada pelo cron (envio pelo banco ligado há pouco): não manda de novo.
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.avisos_telegram WHERE evento_chave = v_chave);
    INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES (v_chave, v_eu) ON CONFLICT (chave) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    CONTINUE WHEN v_n = 0;
    v_saida := v_saida || jsonb_build_object(
      'escolta_id', r.id, 'codigo', r.codigo_escolta, 'cliente', r.nome_cliente, 'status', r.status,
      'atraso_min', v_atraso, 'periodicidade_min', r.per,
      'efetivos', coalesce((SELECT jsonb_agg(v.nome_completo || coalesce(' (' || ee.papel_na_escolta || ')', '') ORDER BY ee.papel_na_escolta, v.nome_completo)
                            FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
                            WHERE ee.escolta_id = r.id), '[]'::jsonb));
  END LOOP;
  RETURN v_saida;
END;
$$;
REVOKE ALL ON FUNCTION public.reservar_alertas_checkin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reservar_alertas_checkin() TO authenticated;

-- Ciclo do cron. p_agora existe só para o teste avançar o relógio; o cron usa now().
CREATE OR REPLACE FUNCTION lote_interno.gerar_avisos_checkin(p_agora timestamptz DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  r record; v_gestao uuid[]; v_n int := 0; v_decorrido numeric; v_atraso int; v_periodo int; v_telegram boolean;
BEGIN
  SELECT coalesce(array_agg(u.id), '{}') INTO v_gestao
  FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor', 'central');
  v_telegram := public.avisos_pelo_banco_ativos()
                AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false);

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
    -- Aviso na central: erro numa escolta (usuário apagado entre a leitura e o INSERT, tipo
    -- ausente) fica nela e vira WARNING; o ciclo segue.
    BEGIN
      IF r.referencia IS NOT NULL THEN
        v_decorrido := extract(epoch FROM (p_agora - r.referencia));
        -- Mesmo arredondamento de minutosAteCheckin: atraso = -floor((per*60 - decorrido) / 60).
        v_atraso := -floor((r.per * 60 - v_decorrido) / 60)::int;
        IF v_atraso >= 1 THEN
          -- Período n: de n a n+1 periodicidades decorridas (o 1º vence com a periodicidade).
          v_periodo := ceil(v_decorrido / (r.per * 60))::int - 1;
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
    EXCEPTION WHEN others THEN
      RAISE WARNING 'gerar_avisos_checkin: aviso da escolta % falhou: %', r.id, SQLERRM;
    END;
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
-- SELECT checkin_telegram_pelo_cron FROM configuracao_avisos;   -- false até a 217 (bloco 2)
-- SELECT lote_interno.gerar_avisos_checkin();   -- 0 enquanto nenhuma escolta aberta tiver periodicidade
-- SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lote_interno'
--   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE')); -- 0
