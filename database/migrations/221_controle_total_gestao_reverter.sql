-- 221_controle_total_gestao_reverter.sql
-- ORDEM: primeiro o git revert do código do controle total e o deploy (a tela deixa de chamar
-- as RPCs novas; se o código ficar, excluir e cancelar finalizada só mostram a mensagem de
-- "depende da migration 221"); depois este arquivo. Idempotente.
-- Guarda em backup_20261112.exclusoes as escoltas excluídas (id, quando, por quem e motivo)
-- antes de remover as colunas. Elas CONTINUAM ARQUIVADAS (a 221 sempre arquiva junto), e
-- portanto fora das listas, do mural e do Campo, visíveis só ao administrador em Arquivadas.
-- Nada de campo é apagado. A escolta cancelada a partir de finalizada continua cancelada
-- (o status não volta sozinho; está no histórico e na auditoria CANCELAR_ESCOLTA_GESTAO).

CREATE SCHEMA IF NOT EXISTS backup_20261112;
REVOKE ALL ON SCHEMA backup_20261112 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261112.exclusoes (
  escolta_id      uuid PRIMARY KEY,
  excluida_em     timestamptz,
  excluida_por    uuid,
  motivo_exclusao text,
  gravado_em      timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON backup_20261112.exclusoes FROM PUBLIC, anon, authenticated;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'escoltas'
              AND column_name = 'excluida_em') THEN
    EXECUTE $q$
      INSERT INTO backup_20261112.exclusoes (escolta_id, excluida_em, excluida_por, motivo_exclusao)
      SELECT id, excluida_em, excluida_por, motivo_exclusao FROM public.escoltas WHERE excluida_em IS NOT NULL
      ON CONFLICT (escolta_id) DO UPDATE SET excluida_em = EXCLUDED.excluida_em, excluida_por = EXCLUDED.excluida_por,
        motivo_exclusao = EXCLUDED.motivo_exclusao, gravado_em = now()$q$;
  END IF;
END $$;

-- RPCs novas.
DROP FUNCTION IF EXISTS public.cancelar_escolta_gestao(uuid, text);
DROP FUNCTION IF EXISTS public.excluir_escolta(uuid, text);
DROP FUNCTION IF EXISTS public.listar_escoltas_excluidas();
DROP FUNCTION IF EXISTS public.restaurar_escolta_excluida(uuid, text);

-- Avisos dos tipos novos e os tipos (notificacoes.tipo_evento_id aponta para dom_tipos_evento).
DELETE FROM public.notificacoes WHERE tipo_evento_id IN
  (SELECT id FROM public.dom_tipos_evento WHERE codigo IN ('cancelamento_gestao', 'exclusao_escolta', 'restauracao_escolta'));
DELETE FROM public.dom_tipos_evento WHERE codigo IN ('cancelamento_gestao', 'exclusao_escolta', 'restauracao_escolta');

-- RLS como na 214 (arquivada só para o administrador) e sem a policy da exclusão.
DROP POLICY IF EXISTS escoltas_excluida_oculta ON public.escoltas;
DROP POLICY IF EXISTS escoltas_arquivada_so_admin ON public.escoltas;
CREATE POLICY escoltas_arquivada_so_admin ON public.escoltas AS RESTRICTIVE FOR SELECT TO authenticated
  USING (arquivada_em IS NULL OR (SELECT public.get_meu_perfil()) = 'administrador');

-- Trava e colunas.
DROP TRIGGER IF EXISTS tr_travar_colunas_exclusao ON public.escoltas;
DROP FUNCTION IF EXISTS lote_interno.travar_colunas_exclusao();
ALTER TABLE public.escoltas DROP CONSTRAINT IF EXISTS escoltas_excluida_e_arquivada;
ALTER TABLE public.escoltas
  DROP COLUMN IF EXISTS excluida_em,
  DROP COLUMN IF EXISTS excluida_por,
  DROP COLUMN IF EXISTS motivo_exclusao;

-- Máquina de estados: corpo da 214.
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

-- recuperar_escolta: corpo da 218 (só o administrador).
CREATE OR REPLACE FUNCTION public.recuperar_escolta(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text;
BEGIN
  PERFORM lote_interno.exigir_gestao(true);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NULL THEN RAISE EXCEPTION 'Esta escolta não está arquivada.'; END IF;
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
REVOKE ALL ON FUNCTION public.recuperar_escolta(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recuperar_escolta(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Conferência:
-- SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'escoltas'
--   AND column_name IN ('excluida_em', 'excluida_por', 'motivo_exclusao');                              -- 0
-- SELECT prosrc LIKE '%cancelamento_gestao%' FROM pg_proc WHERE oid = 'public.validar_transicao_status_escolta()'::regprocedure; -- false
-- SELECT prosrc LIKE '%exigir_gestao(true)%' FROM pg_proc WHERE proname = 'recuperar_escolta';           -- true
-- SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('cancelar_escolta_gestao',
--   'excluir_escolta', 'listar_escoltas_excluidas', 'restaurar_escolta_excluida');                     -- 0
