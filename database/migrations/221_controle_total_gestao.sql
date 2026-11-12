-- 221_controle_total_gestao.sql
-- Pedido de Peçanha em 2026-11-12: gestor e administrador com controle total de todas as
-- escoltas, em todos os estados. Idempotente. Depois da 220 (usa 213, 214 e 218).
-- Aditiva e compatível com a master fa3ea0b: colunas novas com padrão nulo, funções novas
-- que a master não chama, e três corpos recriados (validar_transicao_status_escolta,
-- recuperar_escolta e a policy de arquivada) que só AMPLIAM para o gestor o que já existia.
-- Supervisor, central e operador: nenhuma mudança de poder.
--
-- O que faz:
-- 1. escoltas: excluida_em, excluida_por, motivo_exclusao (exclusão LÓGICA, distinta de
--    arquivar). CHECK: excluída é sempre arquivada (excluida_em só com arquivada_em), de modo
--    que todos os filtros de arquivada que já existem (listas, mural, Campo, Telegram, cron do
--    check-in, registrar_etapa_escolta, registrar_campo, assumir/puxar) valem também para ela.
-- 2. Trava das colunas da exclusão (tr_travar_colunas_exclusao): só mudam com a variável
--    escolta.rpc_gestao ligada E perfil administrador ou gestor (a mesma dupla guarda da 213),
--    ou sem usuário final (SQL Editor, migrations).
-- 3. RLS de escoltas: a escolta excluída some para TODOS os perfis no SELECT direto
--    (RESTRICTIVE escoltas_excluida_oculta); gestor e administrador a veem e restauram só pelas
--    RPCs listar_escoltas_excluidas e restaurar_escolta_excluida. A arquivada passa a aparecer
--    para o gestor também (escoltas_arquivada_so_admin recriada com administrador e gestor).
-- 4. validar_transicao_status_escolta: finalizada para cancelada, só pela RPC
--    cancelar_escolta_gestao (variável escolta.transicao_especial = 'cancelamento_gestao') e só
--    para administrador ou gestor. As demais transições ficam como na 214.
-- 5. recuperar_escolta: gestor também (antes só o administrador); recusa escolta excluída.
-- 6. RPCs novas (SECURITY DEFINER, search_path fixo, guarda de perfil administrador/gestor,
--    motivo de 10 a 1000 caracteres, FOR UPDATE, auditoria e aviso na mesma transação):
--    - cancelar_escolta_gestao(p_escolta_id, p_motivo): cancela em qualquer status antes de
--      cancelada, inclusive finalizada. Arquivada: recuperar antes (o status de arquivada não
--      muda, trava da 214).
--    - excluir_escolta(p_escolta_id, p_motivo): exclusão lógica em qualquer status, inclusive
--      arquivada. Escolta em andamento é cancelada na mesma transação (com linha de histórico);
--      a não arquivada é arquivada; pedidos de substituição pendentes são invalidados. Nada é
--      apagado: fotos, GPS, pontos, checklists, ocorrências, histórico e financeiro ficam.
--      Recusa com emergência aberta (sumiria da central).
--    - listar_escoltas_excluidas(): as excluídas, para a tela da gestão.
--    - restaurar_escolta_excluida(p_escolta_id, p_motivo): desfaz a exclusão; a escolta volta
--      ARQUIVADA (no status em que ficou) e sai do arquivo pela recuperar_escolta.
-- 7. Tipos de aviso: cancelamento_gestao, exclusao_escolta, restauracao_escolta.
--
-- Não muda: escoltas_delete_so_rascunho (DELETE físico continua só do administrador, em
-- rascunho e sem registro de campo; a tela não oferece) nem as travas de "nada é apagado".
-- Reversão: 221_controle_total_gestao_reverter.sql.

-- 1. Colunas.
ALTER TABLE public.escoltas
  ADD COLUMN IF NOT EXISTS excluida_em     timestamptz,
  ADD COLUMN IF NOT EXISTS excluida_por    uuid REFERENCES public.usuarios(id),
  ADD COLUMN IF NOT EXISTS motivo_exclusao text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'escoltas_excluida_e_arquivada'
                  AND conrelid = 'public.escoltas'::regclass) THEN
    ALTER TABLE public.escoltas ADD CONSTRAINT escoltas_excluida_e_arquivada
      CHECK (excluida_em IS NULL OR arquivada_em IS NOT NULL);
  END IF;
END $$;
COMMENT ON COLUMN public.escoltas.excluida_em IS '221 (controle total): excluída pela gestão (exclusão lógica). Some para todos os perfis; só pelas RPCs excluir_escolta e restaurar_escolta_excluida. Sempre junto de arquivada_em.';

-- 2. Trava das colunas da exclusão.
CREATE OR REPLACE FUNCTION lote_interno.travar_colunas_exclusao() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_new jsonb := to_jsonb(NEW); v_old jsonb; c text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF coalesce(current_setting('escolta.rpc_gestao', true), '') = 'on'
     AND public.get_meu_perfil() IN ('administrador', 'gestor') THEN
    RETURN NEW;
  END IF;
  v_old := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
  FOREACH c IN ARRAY ARRAY['excluida_em', 'excluida_por', 'motivo_exclusao'] LOOP
    IF (v_new -> c) IS DISTINCT FROM coalesce(v_old -> c, 'null'::jsonb) THEN
      RAISE EXCEPTION 'A exclusão de escolta só é feita pela gestão (gestor ou administrador), pela tela da escolta.'
        USING ERRCODE = '42501';
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.travar_colunas_exclusao() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_travar_colunas_exclusao ON public.escoltas;
CREATE TRIGGER tr_travar_colunas_exclusao BEFORE INSERT OR UPDATE ON public.escoltas
  FOR EACH ROW EXECUTE FUNCTION lote_interno.travar_colunas_exclusao();

-- 3. RLS.
DROP POLICY IF EXISTS escoltas_excluida_oculta ON public.escoltas;
CREATE POLICY escoltas_excluida_oculta ON public.escoltas AS RESTRICTIVE FOR SELECT TO authenticated
  USING (excluida_em IS NULL);
DROP POLICY IF EXISTS escoltas_arquivada_so_admin ON public.escoltas;
CREATE POLICY escoltas_arquivada_so_admin ON public.escoltas AS RESTRICTIVE FOR SELECT TO authenticated
  USING (arquivada_em IS NULL OR (SELECT public.get_meu_perfil()) IN ('administrador', 'gestor'));

-- 4. Máquina de estados (corpo da 214, mais o ramo do cancelamento da finalizada).
CREATE OR REPLACE FUNCTION public.validar_transicao_status_escolta()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ok boolean := false;
  v_especial text;
  v_seq text[] := ARRAY['rascunho', 'agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino',
                        'no_destino', 'em_transito_retorno', 'retornando', 'na_base', 'finalizada'];
  v_pos_old int; v_pos_new int;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  -- Onda I: escolta arquivada não muda de status (recuperar antes).
  IF OLD.arquivada_em IS NOT NULL THEN
    RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes de mudar o status.'
      USING ERRCODE = 'P0001';
  END IF;

  IF NEW.status = 'cancelada' AND OLD.status NOT IN ('finalizada','cancelada') THEN
    RETURN NEW;
  END IF;

  -- 221 (controle total): finalizada para cancelada, só pela RPC cancelar_escolta_gestao
  -- (variável de transação) e só para administrador ou gestor (perfil). Uma sem a outra não passa.
  IF NEW.status = 'cancelada' AND OLD.status = 'finalizada'
     AND coalesce(current_setting('escolta.transicao_especial', true), '') = 'cancelamento_gestao'
     AND public.get_meu_perfil() IN ('administrador', 'gestor') THEN
    RETURN NEW;
  END IF;

  v_ok := (
    (OLD.status = 'rascunho'            AND NEW.status = 'agendada') OR
    (OLD.status = 'agendada'            AND NEW.status = 'em_pre_inicio') OR
    (OLD.status = 'em_pre_inicio'       AND NEW.status = 'em_andamento') OR
    (OLD.status = 'em_andamento'        AND NEW.status = 'na_origem') OR
    (OLD.status = 'na_origem'           AND NEW.status = 'em_transito_destino') OR
    (OLD.status = 'em_transito_destino' AND NEW.status = 'no_destino') OR
    (OLD.status = 'no_destino'          AND NEW.status = 'em_transito_retorno') OR
    (OLD.status = 'em_transito_retorno' AND NEW.status = 'retornando') OR
    (OLD.status = 'retornando'          AND NEW.status = 'na_base') OR
    (OLD.status = 'na_base'             AND NEW.status = 'finalizada')
  );

  IF NOT v_ok AND COALESCE(NEW.fluxo_versao, 1) = 1 THEN
    v_ok := (
      (OLD.status = 'na_origem'  AND NEW.status = 'no_destino') OR
      (OLD.status = 'no_destino' AND NEW.status = 'retornando')
    );
  END IF;

  -- Onda I: volta de etapa e conclusão antecipada, só pelas RPCs da 218 (variável de
  -- transação) e só para administrador ou gestor (perfil). Uma sem a outra não passa.
  v_especial := coalesce(current_setting('escolta.transicao_especial', true), '');
  IF NOT v_ok AND v_especial IN ('reset', 'conclusao_antecipada')
     AND public.get_meu_perfil() IN ('administrador', 'gestor') THEN
    v_pos_old := array_position(v_seq, OLD.status);
    v_pos_new := array_position(v_seq, NEW.status);
    IF v_especial = 'reset' THEN
      v_ok := NEW.status = coalesce(current_setting('escolta.transicao_destino', true), '')
              AND v_pos_old IS NOT NULL AND v_pos_new IS NOT NULL
              AND v_pos_new < v_pos_old AND v_pos_new >= 2
              AND OLD.status NOT IN ('rascunho', 'agendada', 'cancelada');
    ELSE
      v_ok := NEW.status = 'finalizada' AND OLD.status NOT IN ('rascunho', 'finalizada', 'cancelada');
    END IF;
  END IF;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'Transição de status inválida: % para %', OLD.status, NEW.status
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$function$;

-- 5. Recuperar do arquivo: gestor também; excluída não (corpo da 218, com as duas mudanças marcadas).
CREATE OR REPLACE FUNCTION public.recuperar_escolta(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);   -- 221: gestor também (antes só o administrador)
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NULL THEN RAISE EXCEPTION 'Esta escolta não está arquivada.'; END IF;
  -- 221: excluída fica arquivada; restaurar a exclusão antes (restaurar_escolta_excluida).
  IF e.excluida_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta excluída: restaure a exclusão antes de recuperá-la do arquivo.'; END IF;
  PERFORM lote_interno.modo_gestao(true);
  UPDATE public.escoltas SET arquivada_em = NULL, arquivada_por = NULL, motivo_arquivamento = NULL,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  -- Sem linha de histórico (o status não muda): a recuperação fica na auditoria.
  PERFORM lote_interno.auditar('RECUPERAR_ESCOLTA', p_escolta_id,
    jsonb_build_object('status', e.status, 'arquivada_em', e.arquivada_em, 'arquivada_por', e.arquivada_por,
                       'motivo_arquivamento', e.motivo_arquivamento, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', e.status, 'arquivada_em', NULL, 'motivo', v_motivo, 'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'recuperacao_escolta', 'recuperacao:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    'Escolta recuperada do arquivo: ' || e.codigo_escolta, ARRAY[
      'Volta em ' || lote_interno.rotulo_status(e.status) || ', no status em que estava.',
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'administrador') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Motivo: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'status', e.status);
END;
$$;

-- 6. Tipos de aviso.
INSERT INTO public.dom_tipos_evento (codigo, nome_exibicao, gera_notificacao, ativo)
SELECT v.codigo, v.nome, true, true
FROM (VALUES ('cancelamento_gestao', 'Escolta cancelada pela gestão'),
             ('exclusao_escolta', 'Escolta excluída pela gestão'),
             ('restauracao_escolta', 'Exclusão de escolta desfeita')) v(codigo, nome)
WHERE NOT EXISTS (SELECT 1 FROM public.dom_tipos_evento d WHERE d.codigo = v.codigo);

-- 7. RPCs novas.
CREATE OR REPLACE FUNCTION public.cancelar_escolta_gestao(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text; v_ped int;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL OR e.excluida_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN
    RAISE EXCEPTION 'Escolta arquivada: recupere do arquivo antes de cancelar (ou exclua).';
  END IF;
  IF e.status = 'cancelada' THEN RAISE EXCEPTION 'Esta escolta já está cancelada.'; END IF;

  PERFORM lote_interno.modo_gestao(true);
  IF e.status = 'finalizada' THEN
    PERFORM set_config('escolta.transicao_especial', 'cancelamento_gestao', true);
  END IF;
  -- data_finalizacao fica como estava (a finalizada guarda o horário em que terminou).
  UPDATE public.escoltas SET status = 'cancelada', observacao_fechamento = v_motivo,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora, observacao)
  VALUES (p_escolta_id, e.status, 'cancelada', v_eu, now(), 'Cancelamento pela gestão: ' || v_motivo);
  UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
         observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: a escolta foi cancelada.')
   WHERE escolta_id = p_escolta_id AND status = 'pendente';
  GET DIAGNOSTICS v_ped = ROW_COUNT;
  PERFORM lote_interno.auditar('CANCELAR_ESCOLTA_GESTAO', p_escolta_id,
    jsonb_build_object('status', e.status, 'observacao_fechamento', e.observacao_fechamento, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', 'cancelada', 'motivo', v_motivo, 'pedidos_invalidados', v_ped, 'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'cancelamento_gestao', 'cancelamento:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    'Escolta cancelada pela gestão: ' || e.codigo_escolta, ARRAY[
      'Cancelada quando estava em ' || lote_interno.rotulo_status(e.status) || '.',
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Motivo: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'status_anterior', e.status, 'pedidos_invalidados', v_ped);
END;
$$;

CREATE OR REPLACE FUNCTION public.excluir_escolta(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text; v_ped int; v_cancelou boolean := false;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.excluida_em IS NOT NULL THEN RAISE EXCEPTION 'Esta escolta já está excluída.'; END IF;
  -- Excluída some de todos: a emergência aberta sumiria da central.
  IF EXISTS (SELECT 1 FROM public.emergencias em WHERE em.escolta_id = p_escolta_id AND em.status <> 'encerrada' AND em.anulado_em IS NULL) THEN
    RAISE EXCEPTION 'Há emergência aberta nesta escolta: encerre a emergência antes.';
  END IF;

  PERFORM lote_interno.modo_gestao(true);
  -- Em andamento (pré-início até na base) não fica "rodando" escondida: cancela antes.
  IF e.arquivada_em IS NULL AND e.status NOT IN ('rascunho', 'agendada', 'finalizada', 'cancelada') THEN
    UPDATE public.escoltas SET status = 'cancelada', observacao_fechamento = 'Excluída pela gestão: ' || v_motivo
     WHERE id = p_escolta_id;
    INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora, observacao)
    VALUES (p_escolta_id, e.status, 'cancelada', v_eu, now(), 'Cancelada na exclusão pela gestão: ' || v_motivo);
    v_cancelou := true;
  END IF;
  UPDATE public.escoltas SET
         arquivada_em = coalesce(arquivada_em, now()),
         arquivada_por = coalesce(arquivada_por, v_eu),
         motivo_arquivamento = coalesce(motivo_arquivamento, 'Excluída pela gestão: ' || v_motivo),
         excluida_em = now(), excluida_por = v_eu, motivo_exclusao = v_motivo,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
         observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: a escolta foi excluída.')
   WHERE escolta_id = p_escolta_id AND status = 'pendente';
  GET DIAGNOSTICS v_ped = ROW_COUNT;
  PERFORM lote_interno.auditar('EXCLUIR_ESCOLTA', p_escolta_id,
    jsonb_build_object('status', e.status, 'arquivada_em', e.arquivada_em, 'motivo_arquivamento', e.motivo_arquivamento,
                       'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', CASE WHEN v_cancelou THEN 'cancelada' ELSE e.status END, 'cancelada_na_exclusao', v_cancelou,
                       'excluida_em', now(), 'motivo', v_motivo, 'pedidos_invalidados', v_ped, 'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'exclusao_escolta', 'exclusao:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    'Escolta excluída: ' || e.codigo_escolta, ARRAY[
      'Excluída quando estava em ' || lote_interno.rotulo_status(e.status) || CASE WHEN v_cancelou THEN ' (cancelada na exclusão)' ELSE '' END
        || '; some das listas, do mural, do Campo e dos indicadores.',
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Motivo: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'status_anterior', e.status, 'cancelada_na_exclusao', v_cancelou, 'pedidos_invalidados', v_ped);
END;
$$;

CREATE OR REPLACE FUNCTION public.listar_escoltas_excluidas() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', e.id, 'codigo_escolta', e.codigo_escolta, 'status', e.status,
             'data_hora_prevista', e.data_hora_prevista, 'origem_endereco', e.origem_endereco,
             'destino_endereco', e.destino_endereco, 'cliente', c.nome_cliente,
             'excluida_em', e.excluida_em, 'motivo_exclusao', e.motivo_exclusao, 'excluida_por', u.nome_completo)
           ORDER BY e.excluida_em DESC)
      FROM public.escoltas e
      LEFT JOIN public.clientes c ON c.id = e.cliente_id
      LEFT JOIN public.usuarios u ON u.id = e.excluida_por
     WHERE e.excluida_em IS NOT NULL), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.restaurar_escolta_excluida(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.excluida_em IS NULL THEN RAISE EXCEPTION 'Esta escolta não está excluída.'; END IF;
  PERFORM lote_interno.modo_gestao(true);
  -- Volta arquivada (no status em que ficou); sai do arquivo pela recuperar_escolta.
  UPDATE public.escoltas SET excluida_em = NULL, excluida_por = NULL, motivo_exclusao = NULL,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  PERFORM lote_interno.auditar('RESTAURAR_ESCOLTA_EXCLUIDA', p_escolta_id,
    jsonb_build_object('status', e.status, 'excluida_em', e.excluida_em, 'excluida_por', e.excluida_por,
                       'motivo_exclusao', e.motivo_exclusao, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', e.status, 'excluida_em', NULL, 'motivo', v_motivo, 'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'restauracao_escolta', 'restauracao:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    'Exclusão desfeita: ' || e.codigo_escolta, ARRAY[
      'A escolta volta para Arquivadas, em ' || lote_interno.rotulo_status(e.status) || '.',
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Motivo: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'status', e.status);
END;
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['cancelar_escolta_gestao(uuid, text)', 'excluir_escolta(uuid, text)',
                           'listar_escoltas_excluidas()', 'restaurar_escolta_excluida(uuid, text)',
                           'recuperar_escolta(uuid, text)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- PostgREST: recarrega o cache de funções para as RPCs novas aparecerem já.
NOTIFY pgrst, 'reload schema';

-- Conferência:
-- SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'escoltas'
--   AND column_name IN ('excluida_em', 'excluida_por', 'motivo_exclusao');                              -- 3
-- SELECT polname FROM pg_policy WHERE polname IN ('escoltas_excluida_oculta', 'escoltas_arquivada_so_admin'); -- 2
-- SELECT pg_get_expr(polqual, polrelid) FROM pg_policy WHERE polname = 'escoltas_arquivada_so_admin';  -- com 'gestor'
-- SELECT prosrc LIKE '%cancelamento_gestao%' FROM pg_proc WHERE oid = 'public.validar_transicao_status_escolta()'::regprocedure; -- true
-- SELECT prosrc LIKE '%exigir_gestao(false)%' AND prosrc LIKE '%excluida_em%' FROM pg_proc WHERE proname = 'recuperar_escolta'; -- true
-- SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('cancelar_escolta_gestao',
--   'excluir_escolta', 'listar_escoltas_excluidas', 'restaurar_escolta_excluida');                     -- 4
-- SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_travar_colunas_exclusao';                           -- 1
-- SELECT has_function_privilege('anon', 'public.excluir_escolta(uuid, text)', 'EXECUTE');                -- false
