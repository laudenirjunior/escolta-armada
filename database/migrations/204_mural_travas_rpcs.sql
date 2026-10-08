-- 204_mural_travas_rpcs.sql
-- Lote 2026-10, onda C (M5, travas do mural). Idempotente.
-- BLOCO 2: aplicar logo DEPOIS do deploy do código da onda C. Antes do deploy, o diálogo
-- antigo mandaria motivo de 5 caracteres e esperaria troca imediata.
-- Depende da 202 (fila de avisos) e da 203 (estrutura).
--
-- Regras (decisões de Peçanha de 08/10/2026), todas validadas aqui, no servidor:
--   T1 janela: escolta com equipe só pode ser pedida a partir de N min antes da hora prevista.
--   T2 presença: com presença na base confirmada pela equipe escalada, ninguém assume.
--   T3 aprovação: dentro da janela e sem presença, assumir escolta com equipe vira pedido;
--      supervisor ou acima aprova ou recusa; sem resposta em N min, o banco libera sozinho
--      (pg_cron a cada minuto e toda consulta de pedido).
--   T4 aviso: equipe substituída e supervisão avisadas no aplicativo; chat central do
--      Telegram pela fila (uma mensagem por evento). Não há chat por pessoa no sistema.
--   T5 sobreposição: ninguém fica comandante de duas escoltas agendadas a menos de N h.
--   T6 escala fixa: some do mural; só a gestão muda a equipe.
--   T7 auditoria: puxar, assumir, pedir, decidir, substituir, devolver, incluir e
--      confirmar presença ficam em logs_auditoria; pedidos ficam em mural_pedidos.
-- Concorrência: toda decisão trava primeiro a escolta e depois o pedido, e muda o status
-- do pedido com UPDATE ... WHERE status = 'pendente'; só segue se uma linha mudar.

-- ── Auxiliares internas (sem GRANT a ninguém) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public._hora_br(p timestamptz) RETURNS text
    LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT to_char(p AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
$$;

CREATE OR REPLACE FUNCTION public._equipe_atual(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('vigilante_id', ee.vigilante_id, 'vigilante', v.nome_completo,
                                               'papel', ee.papel_na_escolta)
                            ORDER BY (ee.papel_na_escolta <> 'comandante'), v.nome_completo), '[]'::jsonb)
  FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
  WHERE ee.escolta_id = p_escolta_id
$$;

CREATE OR REPLACE FUNCTION public._ids_da_equipe(p_equipe jsonb) RETURNS uuid[]
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(array_agg((e ->> 'vigilante_id')::uuid ORDER BY (e ->> 'vigilante_id')), '{}')
  FROM jsonb_array_elements(coalesce(p_equipe, '[]'::jsonb)) e
  WHERE e ? 'vigilante_id'
$$;

CREATE OR REPLACE FUNCTION public._nomes_da_equipe(p_equipe jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(string_agg(e ->> 'vigilante', ', '), 'sem equipe') FROM jsonb_array_elements(coalesce(p_equipe, '[]'::jsonb)) e
$$;

-- T5: código de outra escolta agendada em que o vigilante é comandante, a menos de N h.
CREATE OR REPLACE FUNCTION public._conflito_comandante(p_vigilante_id uuid, p_escolta_id uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT o.codigo_escolta
  FROM public.escoltas alvo
  CROSS JOIN public.configuracoes_mural cfg
  JOIN public.escolta_efetivo ee ON ee.vigilante_id = p_vigilante_id AND ee.papel_na_escolta = 'comandante'
  JOIN public.escoltas o ON o.id = ee.escolta_id
  WHERE alvo.id = p_escolta_id AND cfg.id = 1
    AND o.id <> p_escolta_id AND o.status = 'agendada'
    AND abs(extract(epoch FROM (o.data_hora_prevista - alvo.data_hora_prevista))) < cfg.intervalo_comandante_h * 3600
  LIMIT 1
$$;

-- T2: alguém da equipe atual confirmou presença na base?
CREATE OR REPLACE FUNCTION public._presenca_da_equipe(p_escolta_id uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT string_agg(v.nome_completo, ', ')
  FROM public.mural_presencas mp
  JOIN public.escolta_efetivo ee ON ee.escolta_id = mp.escolta_id AND ee.vigilante_id = mp.vigilante_id
  JOIN public.vigilantes v ON v.id = mp.vigilante_id
  WHERE mp.escolta_id = p_escolta_id
$$;

CREATE OR REPLACE FUNCTION public._supervisao_ids() RETURNS uuid[]
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(array_agg(u.id), '{}') FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor')
$$;

CREATE OR REPLACE FUNCTION public._usuarios_dos_vigilantes(p_vigilantes uuid[]) RETURNS uuid[]
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(array_agg(DISTINCT v.usuario_id), '{}') FROM public.vigilantes v
  WHERE v.id = ANY (p_vigilantes) AND v.usuario_id IS NOT NULL
$$;

-- Aviso no aplicativo (tabela notificacoes, canal app).
CREATE OR REPLACE FUNCTION public._avisar_app(p_escolta_id uuid, p_tipo text, p_usuarios uuid[], p_titulo text, p_texto text, p_pedido_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF NOT coalesce((SELECT aviso_ligado FROM public.configuracoes_mural WHERE id = 1), true) THEN RETURN; END IF;
  INSERT INTO public.notificacoes (escolta_id, canal, tipo_evento_id, destino, payload, usuario_dest_id, status_envio)
  SELECT p_escolta_id, 'app', (SELECT id FROM public.dom_tipos_evento WHERE codigo = p_tipo), 'app',
         jsonb_build_object('titulo', p_titulo, 'texto', p_texto, 'pedido_id', p_pedido_id), u, 'enviada'
  FROM unnest(p_usuarios) AS u
  WHERE u IS NOT NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public._auditar_mural(p_acao text, p_escolta_id uuid, p_antes jsonb, p_depois jsonb) RETURNS void
    LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES ((SELECT id FROM public.usuarios WHERE auth_user_id = auth.uid()), p_acao, 'escoltas', p_escolta_id, p_antes, p_depois, now())
$$;

-- Texto de aviso ao chat central (HTML escapado, hora de Brasília).
CREATE OR REPLACE FUNCTION public._texto_aviso_mural(p_titulo text, p_escolta_id uuid, p_linhas text[]) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT '<b>' || public.escapar_html(p_titulo) || '</b>' || E'\n'
      || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(c.nome_cliente) || E'\n'
      || 'Prevista: ' || public._hora_br(e.data_hora_prevista) || E'\n'
      || coalesce((SELECT string_agg(public.escapar_html(l), E'\n') FROM unnest(p_linhas) l), '')
  FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id WHERE e.id = p_escolta_id
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['_hora_br(timestamptz)', '_equipe_atual(uuid)', '_ids_da_equipe(jsonb)', '_nomes_da_equipe(jsonb)',
                           '_conflito_comandante(uuid, uuid)', '_presenca_da_equipe(uuid)', '_supervisao_ids()',
                           '_usuarios_dos_vigilantes(uuid[])', '_avisar_app(uuid, text, uuid[], text, text, uuid)',
                           '_auditar_mural(text, uuid, jsonb, jsonb)', '_texto_aviso_mural(text, uuid, text[])']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- ── Execução da substituição (interna) ───────────────────────────────────────────
-- Só é chamada depois que o pedido mudou de 'pendente' para 'aprovado' ou
-- 'liberado_por_tempo' sob trava (escolta e pedido). Confere tudo de novo.
CREATE OR REPLACE FUNCTION public._executar_substituicao(p_pedido_id uuid, p_via text) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  p public.mural_pedidos%ROWTYPE;
  e record; v_motivo text; v_ev uuid; v_acomp uuid; v_equipe_agora jsonb; v_presenca text; v_conflito text;
  v_nome text; v_aviso boolean;
BEGIN
  SELECT * INTO p FROM public.mural_pedidos WHERE id = p_pedido_id;
  IF p.id IS NULL OR p.status NOT IN ('aprovado', 'liberado_por_tempo') THEN
    RAISE EXCEPTION 'Pedido nao esta liberado para execucao.';
  END IF;
  SELECT id, status, escala_fixa, codigo_escolta INTO e FROM public.escoltas WHERE id = p.escolta_id;
  v_equipe_agora := public._equipe_atual(p.escolta_id);
  v_presenca := CASE WHEN (SELECT presenca_ligada FROM public.configuracoes_mural WHERE id = 1)
                     THEN public._presenca_da_equipe(p.escolta_id) END;
  v_conflito := public._conflito_comandante(p.solicitante_vigilante_id, p.escolta_id);

  v_motivo := CASE
    WHEN e.status IS DISTINCT FROM 'agendada' THEN 'a escolta ja comecou ou foi encerrada'
    WHEN e.escala_fixa THEN 'a escolta passou a ser de escala fixa'
    WHEN v_presenca IS NOT NULL THEN 'a equipe confirmou presenca na base (' || v_presenca || ')'
    WHEN public._ids_da_equipe(v_equipe_agora) IS DISTINCT FROM public._ids_da_equipe(p.equipe_antes) THEN 'a equipe da escolta mudou depois do pedido'
    WHEN v_conflito IS NOT NULL THEN 'o solicitante passou a comandar a escolta ' || v_conflito || ' a menos do intervalo minimo'
    WHEN NOT EXISTS (SELECT 1 FROM public.vigilantes v JOIN public.usuarios u ON u.id = v.usuario_id
                     WHERE v.id = p.solicitante_vigilante_id AND v.status = 'ativo' AND u.status = 'ativo') THEN 'o solicitante nao esta mais ativo'
    WHEN EXISTS (SELECT 1 FROM unnest(p.acompanhantes) a WHERE NOT EXISTS
                 (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN 'um acompanhante nao esta mais ativo'
    WHEN p.veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p.veiculo_id AND status = 'ativo') THEN 'a viatura indicada nao esta mais ativa'
  END;
  IF v_motivo IS NOT NULL THEN
    UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = coalesce(decidido_em, now()),
           observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: ' || v_motivo || '.')
     WHERE id = p.id;
    PERFORM public._avisar_app(p.escolta_id, 'decisao_substituicao', ARRAY[p.solicitante_usuario_id],
      'Pedido de substituição invalidado', 'O pedido para a escolta ' || e.codigo_escolta || ' não foi executado: ' || v_motivo || '.', p.id);
    RETURN false;
  END IF;

  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1;
  IF p.veiculo_id IS NOT NULL THEN
    UPDATE public.escolta_veiculos SET veiculo_id = p.veiculo_id, atualizado_em = now(), atualizado_por = p.solicitante_usuario_id
     WHERE id = v_ev;
  END IF;
  DELETE FROM public.escolta_efetivo WHERE escolta_id = p.escolta_id;
  INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p.escolta_id, v_ev, p.solicitante_vigilante_id, 'comandante', true, p.solicitante_usuario_id);
  FOREACH v_acomp IN ARRAY p.acompanhantes LOOP
    IF v_acomp IS DISTINCT FROM p.solicitante_vigilante_id THEN
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p.escolta_id, v_ev, v_acomp, 'operador', false, p.solicitante_usuario_id) ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = p.solicitante_vigilante_id;
  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES (p.solicitante_usuario_id, 'substituicao_de_equipe', 'escoltas', p.escolta_id,
          jsonb_build_object('equipe', p.equipe_antes),
          jsonb_build_object('pedido_id', p.id, 'via', p_via, 'assumida_por', v_nome, 'motivo', p.motivo,
                             'acompanhantes', (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (p.acompanhantes)),
                             'trocou_viatura', p.veiculo_id IS NOT NULL,
                             'decidido_por', (SELECT nome_completo FROM public.usuarios WHERE id = p.decidido_por)),
          now());

  PERFORM public._avisar_app(p.escolta_id, 'substituicao_equipe',
    public._usuarios_dos_vigilantes(public._ids_da_equipe(p.equipe_antes)) || public._supervisao_ids() || ARRAY[p.solicitante_usuario_id],
    'Equipe substituída na escolta ' || e.codigo_escolta,
    v_nome || ' assumiu a escolta em ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo, sem resposta da supervisão)' ELSE ' (aprovado pela supervisão)' END
      || '. Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes) || '. Motivo: ' || p.motivo,
    p.id);
  v_aviso := public._enfileirar_aviso('substituicao:' || p.id, 'central', p.escolta_id,
    public._texto_aviso_mural('Equipe substituída', p.escolta_id, ARRAY[
      'Assumiu: ' || v_nome,
      'Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes),
      'Quando: ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo)' ELSE ' (aprovado)' END,
      'Motivo: ' || p.motivo]));
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public._executar_substituicao(uuid, text) FROM PUBLIC, anon, authenticated;

-- ── Liberação por tempo (interna; pg_cron e consultas) ─────────────────────────────
CREATE OR REPLACE FUNCTION public.processar_pedidos_vencidos() RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT id, escolta_id FROM public.mural_pedidos WHERE status = 'pendente' AND expira_em < now() ORDER BY criado_em LOOP
    PERFORM 1 FROM public.escoltas WHERE id = r.escolta_id FOR UPDATE;
    UPDATE public.mural_pedidos SET status = 'liberado_por_tempo', decidido_em = now()
     WHERE id = r.id AND status = 'pendente' AND expira_em < now();
    IF FOUND THEN
      PERFORM public._executar_substituicao(r.id, 'liberado_por_tempo');
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.processar_pedidos_vencidos() FROM PUBLIC, anon, authenticated;

-- ── RPCs do cliente ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[] DEFAULT '{}'::uuid[],
                                                 p_veiculo_id uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  v_perfil text; v_usuario uuid; v_vigilante uuid; e record; cfg record; v_qtd int; v_ev uuid; v_acomp uuid;
  v_conflito text; v_presenca text; v_ped record; v_equipe jsonb; v_nome text; v_aviso boolean; v_inicio timestamptz;
  v_acomp_limpo uuid[];
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo. Fale com o administrador.';
  END IF;

  -- Trava a linha: duas pessoas assumindo ao mesmo tempo produziriam duas equipes.
  SELECT id, status, escala_fixa, data_hora_prevista, codigo_escolta INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.status <> 'agendada' THEN
    RAISE EXCEPTION 'Esta escolta ja comecou e nao pode ter a equipe trocada. Fale com o supervisor.';
  END IF;
  IF e.escala_fixa THEN
    RAISE EXCEPTION 'Escolta de escala fixa: a equipe e definida pela supervisao.';
  END IF;

  v_acomp_limpo := ARRAY(SELECT DISTINCT a FROM unnest(coalesce(p_acompanhantes, '{}')) a WHERE a IS DISTINCT FROM v_vigilante);
  IF EXISTS (SELECT 1 FROM unnest(v_acomp_limpo) a WHERE NOT EXISTS
             (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN
    RAISE EXCEPTION 'Acompanhante invalido ou inativo.';
  END IF;
  IF p_veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p_veiculo_id AND status = 'ativo') THEN
    RAISE EXCEPTION 'Viatura invalida ou fora de operacao.';
  END IF;

  SELECT * INTO cfg FROM public.configuracoes_mural WHERE id = 1;
  SELECT count(*) INTO v_qtd FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = v_vigilante;

  -- Escolta sem equipe: assume na hora, como antes, com T5.
  IF v_qtd = 0 THEN
    v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
    IF v_conflito IS NOT NULL THEN
      RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
    END IF;
    SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
    IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
    IF p_veiculo_id IS NOT NULL THEN
      UPDATE public.escolta_veiculos SET veiculo_id = p_veiculo_id, atualizado_em = now(), atualizado_por = v_usuario WHERE id = v_ev;
    END IF;
    INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
    VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
    FOREACH v_acomp IN ARRAY v_acomp_limpo LOOP
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p_escolta_id, v_ev, v_acomp, 'operador', false, v_usuario) ON CONFLICT DO NOTHING;
    END LOOP;
    PERFORM public._auditar_mural('assumiu_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
      jsonb_build_object('assumida_por', v_nome, 'acompanhantes',
        (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (v_acomp_limpo)),
        'trocou_viatura', p_veiculo_id IS NOT NULL));
    RETURN jsonb_build_object('ok', true, 'status', 'assumida', 'substituiu_equipe', false);
  END IF;

  -- Escolta com equipe: vira pedido, dentro das travas.
  IF EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
    RAISE EXCEPTION 'Voce ja esta na equipe desta escolta.';
  END IF;
  IF p_motivo IS NULL OR length(trim(p_motivo)) < 20 THEN
    RAISE EXCEPTION 'Informe o motivo da substituicao com pelo menos 20 caracteres.';
  END IF;
  v_inicio := e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min);
  IF now() < v_inicio THEN
    RAISE EXCEPTION 'Substituicao de equipe liberada a partir de % (horario de Brasilia).', public._hora_br(v_inicio);
  END IF;
  IF cfg.presenca_ligada THEN
    v_presenca := public._presenca_da_equipe(p_escolta_id);
    IF v_presenca IS NOT NULL THEN
      RAISE EXCEPTION 'A equipe escalada ja confirmou presenca na base (%). Fale com o supervisor.', v_presenca;
    END IF;
  END IF;
  v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
  IF v_conflito IS NOT NULL THEN
    RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
  END IF;

  SELECT id, solicitante_usuario_id, expira_em INTO v_ped FROM public.mural_pedidos
  WHERE escolta_id = p_escolta_id AND status = 'pendente' FOR UPDATE;
  IF v_ped.id IS NOT NULL THEN
    IF v_ped.solicitante_usuario_id = v_usuario THEN
      RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em, 'ja_existia', true);
    END IF;
    RAISE EXCEPTION 'Ja existe um pedido de substituicao em analise para esta escolta.';
  END IF;

  v_equipe := public._equipe_atual(p_escolta_id);
  INSERT INTO public.mural_pedidos (escolta_id, solicitante_usuario_id, solicitante_vigilante_id, acompanhantes, veiculo_id,
                                    motivo, equipe_antes, expira_em, antecedencia_min)
  VALUES (p_escolta_id, v_usuario, v_vigilante, v_acomp_limpo, p_veiculo_id, trim(p_motivo), v_equipe,
          now() + make_interval(mins => cfg.aprovacao_tempo_limite_min),
          round(extract(epoch FROM (e.data_hora_prevista - now())) / 60)::int)
  RETURNING id, expira_em INTO v_ped;

  PERFORM public._auditar_mural('pedido_substituicao', p_escolta_id, jsonb_build_object('equipe', v_equipe),
    jsonb_build_object('pedido_id', v_ped.id, 'solicitante', v_nome, 'motivo', trim(p_motivo), 'expira_em', v_ped.expira_em));
  PERFORM public._avisar_app(p_escolta_id, 'pedido_substituicao', public._supervisao_ids(),
    'Pedido de substituição na escolta ' || e.codigo_escolta,
    v_nome || ' pediu para assumir. Equipe atual: ' || public._nomes_da_equipe(v_equipe) || '. Motivo: ' || trim(p_motivo)
      || '. Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.', v_ped.id);
  v_aviso := public._enfileirar_aviso('pedido:' || v_ped.id, 'central', p_escolta_id,
    public._texto_aviso_mural('Pedido de substituição de equipe', p_escolta_id, ARRAY[
      'Solicitante: ' || v_nome,
      'Equipe atual: ' || public._nomes_da_equipe(v_equipe),
      'Motivo: ' || trim(p_motivo),
      'Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.']));
  RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em,
                            'aviso_pelo_banco', v_aviso, 'codigo', e.codigo_escolta, 'equipe_atual', public._nomes_da_equipe(v_equipe));
END;
$$;
COMMENT ON FUNCTION public.assumir_escolta(uuid, uuid[], uuid, text) IS
  'Lote 2026-10 (M5): escolta sem equipe é assumida na hora (T5, T6); com equipe, vira pedido à supervisão dentro das travas T1, T2, T5, T6, com motivo de 20 caracteres.';

CREATE OR REPLACE FUNCTION public.puxar_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_ev uuid; v_ja int; v_conflito text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo. Fale com o administrador.';
  END IF;
  -- Trava a linha: sem isto, dois operadores puxam a mesma escolta no mesmo instante.
  SELECT id, status, escala_fixa INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'Esta escolta nao esta mais disponivel: ela ja saiu do mural.'; END IF;
  IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: a equipe e definida pela supervisao.'; END IF;
  SELECT count(*) INTO v_ja FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  IF v_ja > 0 THEN RAISE EXCEPTION 'Esta escolta ja tem equipe designada.'; END IF;
  v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
  IF v_conflito IS NOT NULL THEN
    RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito,
      (SELECT intervalo_comandante_h FROM public.configuracoes_mural WHERE id = 1);
  END IF;
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
  INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
  PERFORM public._auditar_mural('puxou_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
    jsonb_build_object('assumida_por', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante)));
  RETURN jsonb_build_object('ok', true, 'escolta_veiculo_id', v_ev);
END;
$$;

CREATE OR REPLACE FUNCTION public.devolver_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_vigilante uuid; e record; v_sou_cmd int; v_equipe jsonb; v_gestao boolean;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_vigilante := public.get_meu_vigilante_id();
  v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
  SELECT id, status, escala_fixa INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  -- So devolve enquanto nao comecou. Depois de iniciada, sair da escolta e decisao de supervisor.
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta ja comecou. Fale com o supervisor para sair dela.'; END IF;
  IF NOT v_gestao THEN
    IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: so a supervisao altera a equipe.'; END IF;
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante devolve a escolta ao mural.'; END IF;
  END IF;
  v_equipe := public._equipe_atual(p_escolta_id);
  DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  DELETE FROM public.mural_presencas WHERE escolta_id = p_escolta_id;
  PERFORM public._auditar_mural('devolveu_escolta_ao_mural', p_escolta_id, jsonb_build_object('equipe', v_equipe), '{"equipe": []}'::jsonb);
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.incluir_vigilante_na_minha_escolta(p_escolta_id uuid, p_vigilante_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_sou_cmd int; v_ev uuid; v_dup int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  SELECT id, status, escala_fixa INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta ja comecou. Alteracao de equipe passa pelo supervisor.'; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') THEN
    IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: so a supervisao altera a equipe.'; END IF;
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante inclui vigilante nesta escolta.'; END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vigilantes WHERE id = p_vigilante_id AND status = 'ativo') THEN
    RAISE EXCEPTION 'Vigilante invalido ou inativo.';
  END IF;
  SELECT count(*) INTO v_dup FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = p_vigilante_id;
  IF v_dup > 0 THEN RAISE EXCEPTION 'Este vigilante ja esta na escolta.'; END IF;
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada.'; END IF;
  INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, p_vigilante_id, 'operador', false, v_usuario);
  PERFORM public._auditar_mural('incluiu_vigilante', p_escolta_id, '{}'::jsonb,
    jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = p_vigilante_id)));
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- T2: presença na base.
CREATE OR REPLACE FUNCTION public.confirmar_presenca_base(p_escolta_id uuid, p_lat numeric DEFAULT NULL, p_lng numeric DEFAULT NULL,
                                                         p_precisao numeric DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_inicio timestamptz; v_ped uuid;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo.'; END IF;
  SELECT id, status, data_hora_prevista, codigo_escolta INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A presenca na base so e confirmada antes do inicio da escolta.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
    RAISE EXCEPTION 'Voce nao esta na equipe desta escolta.';
  END IF;
  v_inicio := e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1));
  IF now() < v_inicio THEN
    RAISE EXCEPTION 'A confirmacao de presenca abre as % (horario de Brasilia).', public._hora_br(v_inicio);
  END IF;
  INSERT INTO public.mural_presencas (escolta_id, vigilante_id, usuario_id, latitude, longitude, precisao_metros, sem_gps)
  VALUES (p_escolta_id, v_vigilante, v_usuario, p_lat, p_lng, p_precisao, p_lat IS NULL OR p_lng IS NULL)
  ON CONFLICT (escolta_id, vigilante_id) DO NOTHING;
  PERFORM public._auditar_mural('presenca_na_base', p_escolta_id, '{}'::jsonb,
    jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante),
                       'latitude', p_lat, 'longitude', p_lng, 'precisao_metros', p_precisao));
  -- Pedido pendente perde o objeto: a equipe chegou.
  UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
         observacao_decisao = 'Invalidado: a equipe confirmou presenca na base.'
   WHERE escolta_id = p_escolta_id AND status = 'pendente'
  RETURNING id INTO v_ped;
  IF v_ped IS NOT NULL THEN
    PERFORM public._avisar_app(p_escolta_id, 'decisao_substituicao',
      ARRAY[(SELECT solicitante_usuario_id FROM public.mural_pedidos WHERE id = v_ped)],
      'Pedido de substituição invalidado', 'A equipe da escolta ' || e.codigo_escolta || ' confirmou presença na base.', v_ped);
  END IF;
  RETURN jsonb_build_object('ok', true, 'confirmado_em', now());
END;
$$;

-- T3: decisões.
CREATE OR REPLACE FUNCTION public.aprovar_pedido_mural(p_pedido_id uuid, p_observacao text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_esc uuid; v_sol uuid; v_ok boolean; v_status text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Apenas supervisor ou acima decide pedidos de substituicao.';
  END IF;
  v_usuario := public.get_meu_usuario_id();
  SELECT escolta_id, solicitante_usuario_id INTO v_esc, v_sol FROM public.mural_pedidos WHERE id = p_pedido_id;
  IF v_esc IS NULL THEN RAISE EXCEPTION 'Pedido nao encontrado.'; END IF;
  IF v_sol = v_usuario THEN RAISE EXCEPTION 'Voce nao pode decidir o proprio pedido.'; END IF;
  PERFORM 1 FROM public.escoltas WHERE id = v_esc FOR UPDATE;          -- ordem fixa: escolta, depois pedido
  UPDATE public.mural_pedidos SET status = 'aprovado', decidido_por = v_usuario, decidido_em = now(),
         observacao_decisao = nullif(trim(coalesce(p_observacao, '')), '')
   WHERE id = p_pedido_id AND status = 'pendente'
  RETURNING status INTO v_status;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Este pedido ja foi decidido.'; END IF;
  v_ok := public._executar_substituicao(p_pedido_id, 'aprovado');
  PERFORM public._avisar_app(v_esc, 'decisao_substituicao', ARRAY[v_sol],
    CASE WHEN v_ok THEN 'Pedido de substituição aprovado' ELSE 'Pedido de substituição não executado' END,
    CASE WHEN v_ok THEN 'Você assumiu a escolta.' ELSE 'O pedido foi aprovado, mas a escolta mudou antes da execução.' END, p_pedido_id);
  PERFORM public._auditar_mural('pedido_substituicao_aprovado', v_esc, '{}'::jsonb, jsonb_build_object('pedido_id', p_pedido_id, 'executado', v_ok));
  RETURN jsonb_build_object('ok', true, 'executado', v_ok, 'aviso_pelo_banco', public.avisos_pelo_banco_ativos());
END;
$$;

CREATE OR REPLACE FUNCTION public.recusar_pedido_mural(p_pedido_id uuid, p_motivo text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_esc uuid; v_sol uuid; v_status text; v_aviso boolean; v_nome text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Apenas supervisor ou acima decide pedidos de substituicao.';
  END IF;
  v_usuario := public.get_meu_usuario_id();
  SELECT escolta_id, solicitante_usuario_id INTO v_esc, v_sol FROM public.mural_pedidos WHERE id = p_pedido_id;
  IF v_esc IS NULL THEN RAISE EXCEPTION 'Pedido nao encontrado.'; END IF;
  IF v_sol = v_usuario THEN RAISE EXCEPTION 'Voce nao pode decidir o proprio pedido.'; END IF;
  PERFORM 1 FROM public.escoltas WHERE id = v_esc FOR UPDATE;
  UPDATE public.mural_pedidos SET status = 'recusado', decidido_por = v_usuario, decidido_em = now(),
         observacao_decisao = nullif(trim(coalesce(p_motivo, '')), '')
   WHERE id = p_pedido_id AND status = 'pendente'
  RETURNING status INTO v_status;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Este pedido ja foi decidido.'; END IF;
  SELECT nome_completo INTO v_nome FROM public.usuarios WHERE id = v_usuario;
  PERFORM public._avisar_app(v_esc, 'decisao_substituicao', ARRAY[v_sol], 'Pedido de substituição recusado',
    'Recusado por ' || v_nome || coalesce('. Motivo: ' || nullif(trim(coalesce(p_motivo, '')), ''), '') || '.', p_pedido_id);
  PERFORM public._auditar_mural('pedido_substituicao_recusado', v_esc, '{}'::jsonb,
    jsonb_build_object('pedido_id', p_pedido_id, 'motivo', p_motivo));
  v_aviso := public._enfileirar_aviso('decisao:' || p_pedido_id, 'central', v_esc,
    public._texto_aviso_mural('Pedido de substituição recusado', v_esc, ARRAY['Recusado por: ' || v_nome,
      'Motivo: ' || coalesce(nullif(trim(coalesce(p_motivo, '')), ''), 'não informado')]));
  RETURN jsonb_build_object('ok', true, 'aviso_pelo_banco', v_aviso);
END;
$$;

CREATE OR REPLACE FUNCTION public.cancelar_meu_pedido_mural(p_pedido_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_usuario uuid; v_esc uuid; v_status text;
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  SELECT escolta_id INTO v_esc FROM public.mural_pedidos WHERE id = p_pedido_id AND solicitante_usuario_id = v_usuario;
  IF v_esc IS NULL THEN RAISE EXCEPTION 'Pedido nao encontrado.'; END IF;
  PERFORM 1 FROM public.escoltas WHERE id = v_esc FOR UPDATE;
  UPDATE public.mural_pedidos SET status = 'cancelado', decidido_em = now()
   WHERE id = p_pedido_id AND status = 'pendente' RETURNING status INTO v_status;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Este pedido ja foi decidido.'; END IF;
  PERFORM public._auditar_mural('pedido_substituicao_cancelado', v_esc, '{}'::jsonb, jsonb_build_object('pedido_id', p_pedido_id));
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Leitura (VOLATILE: primeiro libera os pedidos vencidos).
CREATE OR REPLACE FUNCTION public.listar_pedidos_mural(p_desde timestamptz DEFAULT now() - interval '30 days') RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  PERFORM public.processar_pedidos_vencidos();
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'escolta_id', p.escolta_id, 'codigo', e.codigo_escolta, 'cliente', c.nome_cliente,
           'data_hora_prevista', e.data_hora_prevista, 'solicitante', sv.nome_completo, 'solicitante_usuario_id', p.solicitante_usuario_id,
           'equipe_antes', public._nomes_da_equipe(p.equipe_antes), 'motivo', p.motivo, 'status', p.status,
           'criado_em', p.criado_em, 'expira_em', p.expira_em, 'antecedencia_min', p.antecedencia_min,
           'decidido_por', du.nome_completo, 'decidido_em', p.decidido_em, 'observacao_decisao', p.observacao_decisao)
         ORDER BY p.criado_em DESC), '[]'::jsonb) INTO v
  FROM public.mural_pedidos p
  JOIN public.escoltas e ON e.id = p.escolta_id
  JOIN public.clientes c ON c.id = e.cliente_id
  JOIN public.vigilantes sv ON sv.id = p.solicitante_vigilante_id
  LEFT JOIN public.usuarios du ON du.id = p.decidido_por
  WHERE p.criado_em >= p_desde
    AND (v_perfil IN ('administrador', 'gestor', 'supervisor') OR p.solicitante_usuario_id = v_usuario);
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.consultar_pedido_mural(p_pedido_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v jsonb;
BEGIN
  v := public.listar_pedidos_mural('-infinity');
  RETURN (SELECT x FROM jsonb_array_elements(v) x WHERE (x ->> 'id')::uuid = p_pedido_id);
END;
$$;

-- Estado do mural para a tela (janela, presença, escala fixa, pedido pendente, minha equipe).
CREATE OR REPLACE FUNCTION public.mural_info(p_escolta_ids uuid[]) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; v jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  PERFORM public.processar_pedidos_vencidos();
  SELECT coalesce(jsonb_object_agg(e.id, jsonb_build_object(
           'janela_inicio', e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min),
           'escala_fixa', e.escala_fixa,
           -- O operador não lê o efetivo dos colegas pela RLS; sem isto a tela via toda
           -- escolta agendada como "sem equipe".
           'tem_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id),
           'presenca', public._presenca_da_equipe(e.id),
           'eu_confirmei', EXISTS (SELECT 1 FROM public.mural_presencas mp WHERE mp.escolta_id = e.id AND mp.vigilante_id = v_vigilante),
           'sou_da_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante),
           'pedido', (SELECT jsonb_build_object('id', p.id, 'expira_em', p.expira_em, 'meu', p.solicitante_usuario_id = v_usuario)
                      FROM public.mural_pedidos p WHERE p.escolta_id = e.id AND p.status = 'pendente'))), '{}'::jsonb)
    INTO v
  FROM public.escoltas e CROSS JOIN public.configuracoes_mural cfg
  WHERE e.id = ANY (p_escolta_ids) AND cfg.id = 1 AND e.status = 'agendada';
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.marcar_aviso_lido(p_notificacao_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  UPDATE public.notificacoes SET lida = true WHERE id = p_notificacao_id AND usuario_dest_id = public.get_meu_usuario_id();
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.meus_avisos_mural() RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v jsonb;
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'escolta_id', n.escolta_id, 'titulo', n.payload ->> 'titulo',
           'texto', n.payload ->> 'texto', 'criado_em', n.criado_em, 'tipo', t.codigo) ORDER BY n.criado_em DESC), '[]'::jsonb)
    INTO v
  FROM public.notificacoes n JOIN public.dom_tipos_evento t ON t.id = n.tipo_evento_id
  WHERE n.usuario_dest_id = public.get_meu_usuario_id() AND n.canal = 'app' AND NOT coalesce(n.lida, false)
    AND t.codigo IN ('pedido_substituicao', 'decisao_substituicao', 'substituicao_equipe')
    AND n.criado_em > now() - interval '7 days';
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.mural_travas_ativas() RETURNS boolean
    LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp' AS $$ SELECT true $$;

CREATE OR REPLACE FUNCTION public.avisos_telegram_resumo() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Permissao negada.';
  END IF;
  RETURN jsonb_build_object(
    'envio_pelo_banco', public.avisos_pelo_banco_ativos(),
    'erro_24h', (SELECT count(*) FROM public.avisos_telegram WHERE situacao = 'erro' AND criado_em > now() - interval '24 hours'),
    'pendente', (SELECT count(*) FROM public.avisos_telegram WHERE situacao IN ('pendente', 'enviando')),
    'enviado_24h', (SELECT count(*) FROM public.avisos_telegram WHERE situacao = 'enviado' AND criado_em > now() - interval '24 hours'));
END;
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['assumir_escolta(uuid, uuid[], uuid, text)', 'puxar_escolta(uuid)', 'devolver_escolta(uuid)',
                           'incluir_vigilante_na_minha_escolta(uuid, uuid)', 'confirmar_presenca_base(uuid, numeric, numeric, numeric)',
                           'aprovar_pedido_mural(uuid, text)', 'recusar_pedido_mural(uuid, text)', 'cancelar_meu_pedido_mural(uuid)',
                           'listar_pedidos_mural(timestamptz)', 'consultar_pedido_mural(uuid)', 'mural_info(uuid[])',
                           'marcar_aviso_lido(uuid)', 'meus_avisos_mural()', 'mural_travas_ativas()', 'avisos_telegram_resumo()']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- Liberação por tempo pelo banco, a cada minuto (com pg_cron).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    EXECUTE $q$SELECT cron.schedule('lote2026_pedidos_vencidos', '* * * * *', 'SELECT public.processar_pedidos_vencidos();')$q$;
  END IF;
END $$;

-- Conferência:
-- SELECT public.mural_travas_ativas();                                         -- true
-- SELECT jobname, active FROM cron.job WHERE jobname LIKE 'lote2026%';          -- 2 linhas
-- SELECT has_function_privilege('authenticated', 'public._executar_substituicao(uuid, text)', 'EXECUTE'); -- false
