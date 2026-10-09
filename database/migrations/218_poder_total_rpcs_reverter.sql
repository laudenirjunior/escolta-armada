-- 218_poder_total_rpcs_reverter.sql
-- ORDEM: primeiro o git revert do código da onda I e o deploy; depois este arquivo; a 214 e
-- a 213 só depois dele. Tira as RPCs da gestão e as auxiliares do lote_interno, devolve os
-- corpos anteriores (204 com a 217, 202 e 214) e a restrição única de mural_presencas.
-- Presenças do mural anuladas que repetem uma válida vão para backup_20261008 antes (senão
-- a restrição única não volta); voltam pelo 213_poder_total_estrutura_restaurar.sql.
DROP FUNCTION IF EXISTS public.editar_escolta(uuid, jsonb, jsonb, text);
DROP FUNCTION IF EXISTS public.pendencias_da_escolta(uuid);
DROP FUNCTION IF EXISTS public.concluir_escolta_antecipada(uuid, text);
DROP FUNCTION IF EXISTS public.voltar_etapa_escolta(uuid, text, boolean, jsonb);
DROP FUNCTION IF EXISTS public.zerar_escolta(uuid, text, boolean, jsonb);
DROP FUNCTION IF EXISTS public.voltar_etapa_escolta(uuid, text, boolean);
DROP FUNCTION IF EXISTS public.zerar_escolta(uuid, text, boolean);
DROP FUNCTION IF EXISTS public.arquivar_escolta(uuid, text);
DROP FUNCTION IF EXISTS public.recuperar_escolta(uuid, text);
DROP FUNCTION IF EXISTS lote_interno.executar_reset(uuid, text, text, boolean, jsonb);
DROP FUNCTION IF EXISTS lote_interno.executar_reset(uuid, text, text, boolean);
DROP FUNCTION IF EXISTS lote_interno.viatura_tem_registro(uuid);
DROP FUNCTION IF EXISTS lote_interno.modo_gestao(boolean);
DROP FUNCTION IF EXISTS lote_interno.exigir_motivo(text);
DROP FUNCTION IF EXISTS lote_interno.exigir_gestao(boolean);
DROP FUNCTION IF EXISTS lote_interno.pendencias(uuid);
DROP FUNCTION IF EXISTS lote_interno.destino_voltar(uuid, text);
DROP FUNCTION IF EXISTS lote_interno.alvos_anulacao(uuid, text, boolean);
DROP FUNCTION IF EXISTS lote_interno.ancora_etapa(uuid, text);
DROP FUNCTION IF EXISTS lote_interno.registros_validos(uuid);
DROP FUNCTION IF EXISTS lote_interno.avisar_acao_gestao(uuid, text, text, text, text[]);
DROP FUNCTION IF EXISTS lote_interno.auditar(text, uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS lote_interno.tipo_ponto_da_etapa(text);
DROP FUNCTION IF EXISTS lote_interno.sequencia_status();
DROP FUNCTION IF EXISTS lote_interno.rotulo_status(text);

CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261008.mural_presencas_anuladas (linha jsonb NOT NULL, gravado_em timestamptz NOT NULL DEFAULT now());
REVOKE ALL ON backup_20261008.mural_presencas_anuladas FROM PUBLIC, anon, authenticated;
-- Uma linha por presença (rodar de novo, ou reverter outra vez depois de reaplicar, não duplica).
DELETE FROM backup_20261008.mural_presencas_anuladas a USING backup_20261008.mural_presencas_anuladas b
 WHERE a.linha ->> 'id' = b.linha ->> 'id' AND (a.gravado_em, a.ctid) < (b.gravado_em, b.ctid);
CREATE UNIQUE INDEX IF NOT EXISTS mural_presencas_anuladas_uk ON backup_20261008.mural_presencas_anuladas ((linha ->> 'id'));
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'mural_presencas_escolta_id_vigilante_id_key'
                  AND conrelid = 'public.mural_presencas'::regclass) THEN
    INSERT INTO backup_20261008.mural_presencas_anuladas (linha)
    SELECT to_jsonb(m) FROM public.mural_presencas m
     WHERE m.anulado_em IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.mural_presencas o WHERE o.escolta_id = m.escolta_id AND o.vigilante_id = m.vigilante_id AND o.id <> m.id)
    ON CONFLICT ((linha ->> 'id')) DO UPDATE SET linha = EXCLUDED.linha, gravado_em = now();
    DELETE FROM public.mural_presencas m
     WHERE m.anulado_em IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.mural_presencas o WHERE o.escolta_id = m.escolta_id AND o.vigilante_id = m.vigilante_id AND o.id <> m.id);
    DROP INDEX IF EXISTS public.mural_presencas_valida_uk;
    ALTER TABLE public.mural_presencas ADD CONSTRAINT mural_presencas_escolta_id_vigilante_id_key UNIQUE (escolta_id, vigilante_id);
  END IF;
END $$;
DROP INDEX IF EXISTS public.mural_presencas_valida_uk;

-- Corpos anteriores (copiados do banco montado na ordem dos blocos, antes da 218).
CREATE OR REPLACE FUNCTION public._conflito_comandante(p_vigilante_id uuid, p_escolta_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT o.codigo_escolta
  FROM public.escoltas alvo
  CROSS JOIN public.configuracoes_mural cfg
  JOIN public.escolta_efetivo ee ON ee.vigilante_id = p_vigilante_id AND ee.papel_na_escolta = 'comandante'
  JOIN public.escoltas o ON o.id = ee.escolta_id
  WHERE alvo.id = p_escolta_id AND cfg.id = 1
    AND o.id <> p_escolta_id AND o.status = 'agendada'
    AND abs(extract(epoch FROM (o.data_hora_prevista - alvo.data_hora_prevista))) < cfg.intervalo_comandante_h * 3600
  LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public._presenca_da_equipe(p_escolta_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT string_agg(v.nome_completo, ', ')
  FROM public.mural_presencas mp
  JOIN public.escolta_efetivo ee ON ee.escolta_id = mp.escolta_id AND ee.vigilante_id = mp.vigilante_id
  JOIN public.vigilantes v ON v.id = mp.vigilante_id
  WHERE mp.escolta_id = p_escolta_id
$function$;

CREATE OR REPLACE FUNCTION public._executar_substituicao(p_pedido_id uuid, p_via text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  p public.mural_pedidos%ROWTYPE;
  e record; v_motivo text; v_ev uuid; v_acomp uuid; v_equipe_agora jsonb; v_presenca text; v_conflito text;
  v_nome text; v_aviso boolean;
BEGIN
  SELECT * INTO p FROM public.mural_pedidos WHERE id = p_pedido_id;
  IF p.id IS NULL OR p.status NOT IN ('aprovado', 'liberado_por_tempo') THEN
    RAISE EXCEPTION 'Pedido nao esta liberado para execucao.';
  END IF;
  SELECT id, status, escala_fixa, codigo_escolta, data_hora_prevista INTO e FROM public.escoltas WHERE id = p.escolta_id;
  PERFORM public._travar_vigilante(p.solicitante_vigilante_id);
  v_equipe_agora := public._equipe_atual(p.escolta_id);
  v_presenca := CASE WHEN (SELECT presenca_ligada FROM public.configuracoes_mural WHERE id = 1)
                     THEN public._presenca_da_equipe(p.escolta_id) END;
  v_conflito := public._conflito_comandante(p.solicitante_vigilante_id, p.escolta_id);

  v_motivo := CASE
    WHEN e.status IS DISTINCT FROM 'agendada' THEN 'a escolta ja comecou ou foi encerrada'
    WHEN e.escala_fixa THEN 'a escolta passou a ser de escala fixa'
    WHEN now() < e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1))
      THEN 'a escolta foi remarcada e saiu da janela de substituicao'
    WHEN v_presenca IS NOT NULL THEN 'a equipe confirmou presenca na base (' || v_presenca || ')'
    WHEN public._ids_da_equipe(v_equipe_agora) IS DISTINCT FROM public._ids_da_equipe(p.equipe_antes) THEN 'a equipe da escolta mudou depois do pedido'
    WHEN v_conflito IS NOT NULL THEN 'o solicitante passou a comandar a escolta ' || v_conflito || ' a menos do intervalo minimo'
    WHEN NOT EXISTS (SELECT 1 FROM public.vigilantes v JOIN public.usuarios u ON u.id = v.usuario_id
                     WHERE v.id = p.solicitante_vigilante_id AND v.status = 'ativo' AND u.status = 'ativo') THEN 'o solicitante nao esta mais ativo'
    WHEN EXISTS (SELECT 1 FROM unnest(p.acompanhantes) a WHERE NOT EXISTS
                 (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN 'um acompanhante nao esta mais ativo'
    WHEN p.veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p.veiculo_id AND status = 'ativo') THEN 'a viatura indicada nao esta mais ativa'
    -- Onda G (210): a placa escolhida não pode estar em outra viatura da mesma escolta.
    WHEN p.veiculo_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p.escolta_id AND ev.veiculo_id = p.veiculo_id
              AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1))
      THEN 'a viatura indicada já está em outra viatura da escolta'
  END;

  -- Onda G (210): os índices únicos do efetivo e das viaturas recusam repetição. Se uma
  -- gravação esbarrar neles, a troca inteira é desfeita e o pedido é invalidado com o
  -- motivo, em vez de o erro técnico subir para quem aprovou ou para o cron.
  IF v_motivo IS NULL THEN
    BEGIN
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
    EXCEPTION WHEN unique_violation THEN
      v_motivo := 'a viatura ou um vigilante indicado já está na escolta';
    END;
  END IF;

  IF v_motivo IS NOT NULL THEN
    UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = coalesce(decidido_em, now()),
           observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: ' || v_motivo || '.')
     WHERE id = p.id;
    INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
    VALUES (p.decidido_por, 'pedido_substituicao_invalidado', 'escoltas', p.escolta_id, jsonb_build_object('pedido_id', p.id),
            jsonb_build_object('pedido_id', p.id, 'via', p_via, 'motivo', v_motivo), now());
    PERFORM public._avisar_app(p.escolta_id, 'decisao_substituicao', ARRAY[p.solicitante_usuario_id],
      'Pedido de substituição invalidado', 'O pedido para a escolta ' || e.codigo_escolta || ' não foi executado: ' || v_motivo || '.', p.id);
    RETURN false;
  END IF;

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
$function$;

CREATE OR REPLACE FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[] DEFAULT '{}'::uuid[], p_veiculo_id uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  PERFORM public._travar_vigilante(v_vigilante);

  v_acomp_limpo := ARRAY(SELECT DISTINCT a FROM unnest(coalesce(p_acompanhantes, '{}')) a WHERE a IS DISTINCT FROM v_vigilante);
  IF EXISTS (SELECT 1 FROM unnest(v_acomp_limpo) a WHERE NOT EXISTS
             (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN
    RAISE EXCEPTION 'Acompanhante invalido ou inativo.';
  END IF;
  IF p_veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p_veiculo_id AND status = 'ativo') THEN
    RAISE EXCEPTION 'Viatura invalida ou fora de operacao.';
  END IF;
  -- Onda G (210): a placa escolhida troca a primeira viatura; não pode ser a de outra
  -- viatura da mesma escolta.
  IF p_veiculo_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_escolta_id AND ev.veiculo_id = p_veiculo_id
          AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1)) THEN
    RAISE EXCEPTION 'Esta viatura já está em outra viatura desta escolta. Escolha outra placa ou mantenha a atual.';
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
    BEGIN
      IF p_veiculo_id IS NOT NULL THEN
        UPDATE public.escolta_veiculos SET veiculo_id = p_veiculo_id, atualizado_em = now(), atualizado_por = v_usuario WHERE id = v_ev;
      END IF;
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
      FOREACH v_acomp IN ARRAY v_acomp_limpo LOOP
        INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
        VALUES (p_escolta_id, v_ev, v_acomp, 'operador', false, v_usuario) ON CONFLICT DO NOTHING;
      END LOOP;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'A viatura ou um vigilante escolhido já está nesta escolta. Revise a equipe e a viatura e tente de novo.';
    END;
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
  IF length(trim(p_motivo)) > 500 THEN
    RAISE EXCEPTION 'O motivo pode ter no maximo 500 caracteres.';
  END IF;
  v_inicio := e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min);
  IF now() < v_inicio THEN
    RAISE EXCEPTION 'Substituicao de equipe liberada a partir de % (horario de Brasilia).', public._hora_br(v_inicio);
  END IF;
  IF cfg.presenca_ligada THEN
    v_presenca := public._presenca_da_equipe(p_escolta_id);
    IF v_presenca IS NOT NULL THEN
      RAISE EXCEPTION 'A equipe escalada ja confirmou presenca na base. Fale com o supervisor.';
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
$function$;

CREATE OR REPLACE FUNCTION public.puxar_escolta(p_escolta_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  PERFORM public._travar_vigilante(v_vigilante);
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
$function$;

CREATE OR REPLACE FUNCTION public.devolver_escolta(p_escolta_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  -- Quem saiu junto (acompanhantes) fica sabendo pelo aplicativo.
  PERFORM public._avisar_app(p_escolta_id, 'substituicao_equipe',
    ARRAY(SELECT u FROM unnest(public._usuarios_dos_vigilantes(public._ids_da_equipe(v_equipe))) u WHERE u IS DISTINCT FROM public.get_meu_usuario_id()),
    'Escolta devolvida ao mural', 'A escolta ' || (SELECT codigo_escolta FROM public.escoltas WHERE id = p_escolta_id)
      || ' foi devolvida ao mural em ' || public._hora_br(now()) || '. Você não está mais escalado nela.', NULL);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.incluir_vigilante_na_minha_escolta(p_escolta_id uuid, p_vigilante_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  BEGIN
    INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
    VALUES (p_escolta_id, v_ev, p_vigilante_id, 'operador', false, v_usuario);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Este vigilante ja esta na escolta.';
  END;
  PERFORM public._auditar_mural('incluiu_vigilante', p_escolta_id, '{}'::jsonb,
    jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = p_vigilante_id)));
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.confirmar_presenca_base(p_escolta_id uuid, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_precisao numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.listar_pedidos_mural(p_desde timestamp with time zone DEFAULT (now() - '30 days'::interval))
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.mural_info(p_escolta_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
           -- Nomes só para a gestão e para a própria equipe (a RLS de mural_presencas é assim).
           'presenca', CASE WHEN public._presenca_da_equipe(e.id) IS NULL THEN NULL
                            WHEN v_perfil IN ('administrador', 'gestor', 'supervisor', 'central')
                              OR EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante)
                            THEN public._presenca_da_equipe(e.id) ELSE 'sim' END,
           'eu_confirmei', EXISTS (SELECT 1 FROM public.mural_presencas mp WHERE mp.escolta_id = e.id AND mp.vigilante_id = v_vigilante),
           'sou_da_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante),
           'pedido', (SELECT jsonb_build_object('id', p.id, 'expira_em', p.expira_em, 'meu', p.solicitante_usuario_id = v_usuario)
                      FROM public.mural_pedidos p WHERE p.escolta_id = e.id AND p.status = 'pendente'))), '{}'::jsonb)
    INTO v
  FROM public.escoltas e CROSS JOIN public.configuracoes_mural cfg
  WHERE e.id = ANY (p_escolta_ids) AND cfg.id = 1 AND e.status = 'agendada';
  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enviar_avisos_telegram()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r record; v_token text; v_central text; v_base text; v_chat text; v_req bigint; n int := 0;
BEGIN
  IF NOT public.avisos_pelo_banco_ativos() THEN RETURN 0; END IF;
  EXECUTE $q$SELECT max(decrypted_secret) FILTER (WHERE name = 'telegram_bot_token'),
                    max(decrypted_secret) FILTER (WHERE name = 'telegram_chat_central')
             FROM vault.decrypted_secrets$q$ INTO v_token, v_central;
  SELECT telegram_api_base INTO v_base FROM public.configuracao_avisos WHERE id = 1;
  FOR r IN
    SELECT a.id, a.destino, a.texto, c.telegram_chat_id AS chat_cliente
    FROM public.avisos_telegram a
    LEFT JOIN public.escoltas e ON e.id = a.escolta_id
    LEFT JOIN public.clientes c ON c.id = e.cliente_id
    WHERE a.situacao = 'pendente'
    ORDER BY a.criado_em
    LIMIT 20
    FOR UPDATE OF a SKIP LOCKED
  LOOP
    v_chat := CASE WHEN r.destino = 'cliente' THEN coalesce(nullif(r.chat_cliente, ''), v_central) ELSE v_central END;
    UPDATE public.avisos_telegram SET situacao = 'enviando', enviado_em = now() WHERE id = r.id;
    EXECUTE $q$SELECT net.http_post(url := $1, body := $2, headers := '{"Content-Type": "application/json"}'::jsonb)$q$
      INTO v_req
      USING v_base || '/bot' || v_token || '/sendMessage',
            jsonb_build_object('chat_id', v_chat, 'text', r.texto, 'parse_mode', 'HTML', 'disable_web_page_preview', true);
    UPDATE public.avisos_telegram SET pg_net_id = v_req WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_etapa_escolta(p_escolta_id uuid, p_pontos jsonb DEFAULT '[]'::jsonb, p_status_atual text DEFAULT NULL::text, p_status_novo text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text, p_latitude numeric DEFAULT NULL::numeric, p_longitude numeric DEFAULT NULL::numeric, p_observacao_fechamento text DEFAULT NULL::text, p_data_hora_prevista timestamp with time zone DEFAULT NULL::timestamp with time zone, p_tipo_ponto_todas uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int; v_faltando text[]; v_status text;
BEGIN
  -- 0. Trava a escolta e confere a etapa ANTES de gravar qualquer coisa. Serializa duas
  --    viaturas do comboio registrando ao mesmo tempo (a segunda vê o ponto da primeira)
  --    e impede ponto de uma etapa que já passou.
  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF p_status_atual IS NOT NULL AND v_status IS DISTINCT FROM p_status_atual THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 1. Pontos de controle (todas as viaturas num statement só). Onda I: o autor é sempre
  --    quem está na sessão (em nome de quem fez); sem sessão (SQL), vale o informado.
  IF jsonb_array_length(coalesce(p_pontos, '[]'::jsonb)) > 0 THEN
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid)
               WHERE NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
                                 WHERE ev.id = x.escolta_veiculo_id AND ev.escolta_id = p_escolta_id)) THEN
      RAISE EXCEPTION 'Ponto de controle de viatura que não pertence a esta escolta.';
    END IF;
    INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude,
                                        precisao_metros, sem_sinal_gps, foto_id, lancado_por, observacoes,
                                        sincronizado, criado_offline)
    SELECT x.escolta_veiculo_id, x.tipo_ponto_id, coalesce(x.data_hora, now()), x.latitude, x.longitude,
           x.precisao_metros, coalesce(x.sem_sinal_gps, false), x.foto_id,
           coalesce(public.get_meu_usuario_id(), x.lancado_por), x.observacoes,
           coalesce(x.sincronizado, true), coalesce(x.criado_offline, false)
    FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid, tipo_ponto_id uuid, data_hora timestamptz,
                                           latitude numeric, longitude numeric, precisao_metros numeric,
                                           sem_sinal_gps boolean, foto_id uuid, lancado_por uuid, observacoes text,
                                           sincronizado boolean, criado_offline boolean);
  END IF;

  IF p_status_novo IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'avancou', false);
  END IF;

  -- 2. Comboio: a etapa só avança quando todas as viaturas registraram o ponto dela.
  --    Onda I: ponto anulado (etapa desfeita pela gestão) não conta.
  IF p_tipo_ponto_todas IS NOT NULL THEN
    SELECT array_agg(coalesce(ve.placa, 'sem placa') ORDER BY ev.criado_em) INTO v_faltando
    FROM public.escolta_veiculos ev
    LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
    WHERE ev.escolta_id = p_escolta_id
      AND NOT EXISTS (SELECT 1 FROM public.pontos_controle pc
                      WHERE pc.escolta_veiculo_id = ev.id AND pc.tipo_ponto_id = p_tipo_ponto_todas
                        AND pc.anulado_em IS NULL);
    IF v_faltando IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'avancou', false, 'faltando', to_jsonb(v_faltando));
    END IF;
  END IF;

  -- 3. Status, com a guarda do status atual (a trigger valida a transição).
  UPDATE public.escoltas SET
         status = p_status_novo,
         observacao_fechamento = CASE
           WHEN p_status_novo IN ('finalizada', 'cancelada') THEN p_observacao_fechamento
           WHEN p_data_hora_prevista IS NOT NULL THEN NULL
           ELSE observacao_fechamento END,
         data_finalizacao = CASE WHEN p_status_novo = 'finalizada' THEN now() ELSE data_finalizacao END,
         data_hora_prevista = coalesce(p_data_hora_prevista, data_hora_prevista)
   WHERE id = p_escolta_id AND status = p_status_atual;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 4. Histórico, com autor, na mesma transação. Onda I: via_rpc = true (escolta.historico_rpc).
  PERFORM set_config('escolta.historico_rpc', 'on', true);
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora,
                                               latitude, longitude, observacao)
  VALUES (p_escolta_id, p_status_atual, p_status_novo, public.get_meu_usuario_id(), now(),
          p_latitude, p_longitude, p_observacao);
  PERFORM set_config('escolta.historico_rpc', 'off', true);

  RETURN jsonb_build_object('ok', true, 'avancou', true);
END;
$function$;

-- Privilégios das recriadas (CREATE OR REPLACE mantém os anteriores; repetidos por clareza).
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['_conflito_comandante(uuid, uuid)', '_presenca_da_equipe(uuid)', '_executar_substituicao(uuid, text)',
                           'enviar_avisos_telegram()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['assumir_escolta(uuid, uuid[], uuid, text)', 'puxar_escolta(uuid)', 'devolver_escolta(uuid)',
                           'incluir_vigilante_na_minha_escolta(uuid, uuid)', 'confirmar_presenca_base(uuid, numeric, numeric, numeric)',
                           'listar_pedidos_mural(timestamptz)', 'mural_info(uuid[])',
                           'registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

