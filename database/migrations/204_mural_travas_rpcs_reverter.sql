-- 204_mural_travas_rpcs_reverter.sql
-- ORDEM: primeiro o git revert do código da onda C e o deploy; depois este arquivo; a 203
-- só depois deste. Devolve as RPCs do mural ao corpo de produção de 08/10/2026 (migration
-- 195) e remove as funções novas e o agendamento.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lote2026_pedidos_vencidos';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[] DEFAULT '{}'::uuid[], p_veiculo_id uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil       text;
  v_usuario      uuid;
  v_vigilante    uuid;
  v_status       text;
  v_ev           uuid;
  v_equipe_antes jsonb;
  v_veic_antes   jsonb;
  v_acomp        uuid;
  v_qtd_antes    int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN
    RAISE EXCEPTION 'Sessao invalida.';
  END IF;

  SELECT id INTO v_usuario   FROM public.usuarios   WHERE auth_user_id = auth.uid();
  SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante. Fale com o administrador.';
  END IF;

  -- Trava a linha: duas pessoas assumindo ao mesmo tempo produziriam duas equipes.
  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Escolta nao encontrada.';
  END IF;
  IF v_status <> 'agendada' THEN
    RAISE EXCEPTION 'Esta escolta ja comecou e nao pode ter a equipe trocada. Fale com o supervisor.';
  END IF;

  SELECT count(*) INTO v_qtd_antes FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;

  -- Substituir equipe de colega exige justificativa escrita. Assumir escolta vazia, nao.
  IF v_qtd_antes > 0 AND (p_motivo IS NULL OR length(trim(p_motivo)) < 5) THEN
    RAISE EXCEPTION 'Informe o motivo da substituicao da equipe.';
  END IF;

  -- Fotografa o estado anterior ANTES de apagar. Este e o registro que permite
  -- reconstruir depois quem estava escalado, quem assumiu e por que.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'vigilante', v.nome_completo,
           'papel', ee.papel_na_escolta
         ) ORDER BY ee.papel_na_escolta), '[]'::jsonb)
    INTO v_equipe_antes
  FROM public.escolta_efetivo ee
  JOIN public.vigilantes v ON v.id = ee.vigilante_id
  WHERE ee.escolta_id = p_escolta_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object('placa', ve.placa, 'modelo', ve.modelo)), '[]'::jsonb)
    INTO v_veic_antes
  FROM public.escolta_veiculos ev
  JOIN public.veiculos ve ON ve.id = ev.veiculo_id
  WHERE ev.escolta_id = p_escolta_id;

  SELECT id INTO v_ev FROM public.escolta_veiculos
  WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN
    RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.';
  END IF;

  -- Troca de viatura, quando pedida. A escolta ainda nao comecou, entao nao ha ponto de
  -- controle apontando para o vinculo antigo.
  IF p_veiculo_id IS NOT NULL THEN
    UPDATE public.escolta_veiculos
       SET veiculo_id = p_veiculo_id, atualizado_em = now(), atualizado_por = v_usuario
     WHERE id = v_ev;
  END IF;

  DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;

  INSERT INTO public.escolta_efetivo
    (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);

  FOREACH v_acomp IN ARRAY coalesce(p_acompanhantes, '{}')
  LOOP
    IF v_acomp IS DISTINCT FROM v_vigilante THEN
      INSERT INTO public.escolta_efetivo
        (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p_escolta_id, v_ev, v_acomp, 'operador', false, v_usuario)
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  INSERT INTO public.logs_auditoria
    (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES (
    v_usuario,
    CASE WHEN v_qtd_antes > 0 THEN 'substituicao_de_equipe' ELSE 'assumiu_escolta_do_mural' END,
    'escoltas',
    p_escolta_id,
    jsonb_build_object('equipe', v_equipe_antes, 'viaturas', v_veic_antes),
    jsonb_build_object(
      'assumida_por', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante),
      'acompanhantes', (
        SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb)
        FROM public.vigilantes WHERE id = ANY(coalesce(p_acompanhantes, '{}'))
      ),
      'motivo', nullif(trim(coalesce(p_motivo, '')), ''),
      'trocou_viatura', p_veiculo_id IS NOT NULL
    ),
    now()
  );

  RETURN jsonb_build_object(
    'ok', true,
    'substituiu_equipe', v_qtd_antes > 0,
    'equipe_anterior', v_equipe_antes
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.puxar_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil    text;
  v_usuario   uuid;
  v_vigilante uuid;
  v_status    text;
  v_ev        uuid;
  v_ja        int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN
    RAISE EXCEPTION 'Sessao invalida.';
  END IF;

  SELECT id INTO v_usuario FROM public.usuarios WHERE auth_user_id = auth.uid();
  SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante. Fale com o administrador.';
  END IF;

  -- Trava a linha: sem isto, dois operadores puxam a mesma escolta no mesmo instante e
  -- os dois viram comandante.
  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Escolta nao encontrada.';
  END IF;
  IF v_status <> 'agendada' THEN
    RAISE EXCEPTION 'Esta escolta nao esta mais disponivel: ela ja saiu do mural.';
  END IF;

  SELECT count(*) INTO v_ja FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  IF v_ja > 0 THEN
    RAISE EXCEPTION 'Esta escolta ja tem equipe designada.';
  END IF;

  SELECT id INTO v_ev FROM public.escolta_veiculos
  WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN
    RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.';
  END IF;

  INSERT INTO public.escolta_efetivo
    (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);

  RETURN jsonb_build_object('ok', true, 'escolta_veiculo_id', v_ev);
END;
$$;

CREATE OR REPLACE FUNCTION public.devolver_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil    text;
  v_usuario   uuid;
  v_vigilante uuid;
  v_status    text;
  v_sou_cmd   int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  SELECT id INTO v_usuario FROM public.usuarios WHERE auth_user_id = auth.uid();
  SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;

  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Escolta nao encontrada.';
  END IF;

  -- So devolve enquanto nao comecou. Depois de iniciada, sair da escolta e decisao de
  -- supervisor, nao do proprio operador: ja existe registro de ponto no nome dele.
  IF v_status <> 'agendada' THEN
    RAISE EXCEPTION 'A escolta ja comecou. Fale com o supervisor para sair dela.';
  END IF;

  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador','gestor','supervisor','central') THEN
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante
      AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN
      RAISE EXCEPTION 'Apenas o comandante devolve a escolta ao mural.';
    END IF;
  END IF;

  DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.incluir_vigilante_na_minha_escolta(p_escolta_id uuid, p_vigilante_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil    text;
  v_usuario   uuid;
  v_vigilante uuid;
  v_status    text;
  v_sou_cmd   int;
  v_ev        uuid;
  v_dup       int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  SELECT id INTO v_usuario FROM public.usuarios WHERE auth_user_id = auth.uid();
  SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;

  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Escolta nao encontrada.';
  END IF;
  IF v_status <> 'agendada' THEN
    RAISE EXCEPTION 'A escolta ja comecou. Alteracao de equipe passa pelo supervisor.';
  END IF;

  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador','gestor','supervisor','central') THEN
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante
      AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN
      RAISE EXCEPTION 'Apenas o comandante inclui vigilante nesta escolta.';
    END IF;
  END IF;

  SELECT count(*) INTO v_dup FROM public.escolta_efetivo
  WHERE escolta_id = p_escolta_id AND vigilante_id = p_vigilante_id;
  IF v_dup > 0 THEN
    RAISE EXCEPTION 'Este vigilante ja esta na escolta.';
  END IF;

  SELECT id INTO v_ev FROM public.escolta_veiculos
  WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN
    RAISE EXCEPTION 'Escolta sem viatura vinculada.';
  END IF;

  INSERT INTO public.escolta_efetivo
    (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, p_vigilante_id, 'operador', false, v_usuario);

  RETURN jsonb_build_object('ok', true);
END;
$$;

COMMENT ON FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[], p_veiculo_id uuid, p_motivo text) IS 'Operador assume escolta agendada, inclusive quando ja ha equipe escalada. Grava a equipe e a viatura anteriores em logs_auditoria antes de substituir, e exige motivo quando ha equipe a substituir. So funciona enquanto a escolta nao comecou.';

DROP FUNCTION IF EXISTS public.avisos_telegram_resumo();
DROP FUNCTION IF EXISTS public.mural_travas_ativas();
DROP FUNCTION IF EXISTS public.meus_avisos_mural();
DROP FUNCTION IF EXISTS public.marcar_aviso_lido(uuid);
DROP FUNCTION IF EXISTS public.mural_info(uuid[]);
DROP FUNCTION IF EXISTS public.consultar_pedido_mural(uuid);
DROP FUNCTION IF EXISTS public.listar_pedidos_mural(timestamptz);
DROP FUNCTION IF EXISTS public.cancelar_meu_pedido_mural(uuid);
DROP FUNCTION IF EXISTS public.recusar_pedido_mural(uuid, text);
DROP FUNCTION IF EXISTS public.aprovar_pedido_mural(uuid, text);
DROP FUNCTION IF EXISTS public.confirmar_presenca_base(uuid, numeric, numeric, numeric);
DROP FUNCTION IF EXISTS public.processar_pedidos_vencidos();
DROP FUNCTION IF EXISTS public._executar_substituicao(uuid, text);
DROP FUNCTION IF EXISTS public._texto_aviso_mural(text, uuid, text[]);
DROP FUNCTION IF EXISTS public._auditar_mural(text, uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS public._avisar_app(uuid, text, uuid[], text, text, uuid);
DROP FUNCTION IF EXISTS public._usuarios_dos_vigilantes(uuid[]);
DROP FUNCTION IF EXISTS public._supervisao_ids();
DROP FUNCTION IF EXISTS public._presenca_da_equipe(uuid);
DROP FUNCTION IF EXISTS public._conflito_comandante(uuid, uuid);
DROP FUNCTION IF EXISTS public._nomes_da_equipe(jsonb);
DROP FUNCTION IF EXISTS public._ids_da_equipe(jsonb);
DROP FUNCTION IF EXISTS public._equipe_atual(uuid);
DROP FUNCTION IF EXISTS public._hora_br(timestamptz);
