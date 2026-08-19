-- Fase 3: trigger de validacao completa da maquina de estados.
--
-- Corrige o erro relatado ("Transicao de status invalida: na_origem ->
-- em_transito_destino") e acrescenta as arestas da etapa nova de retorno.
--
-- STATUS: PENDENTE DE APLICACAO.
-- A aplicacao via MCP foi bloqueada pelo classificador de permissoes.
-- Aplicar pelo SQL Editor do Supabase ou liberar a permissao.

CREATE OR REPLACE FUNCTION public.validar_transicao_status_escolta()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ok boolean := false;
  v_tem_transito_retorno boolean;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  -- Cancelamento a partir de qualquer estado nao terminal.
  IF NEW.status = 'cancelada' AND OLD.status NOT IN ('finalizada','cancelada') THEN
    RETURN NEW;
  END IF;

  -- Fluxo canonico de 9 etapas.
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

  -- Compatibilidade das escoltas anteriores a esta migration (fluxo_versao = 1):
  -- podem pular as duas etapas de transito, que nao existiam quando comecaram.
  IF NOT v_ok AND COALESCE(NEW.fluxo_versao, 1) = 1 THEN
    v_ok := (
      (OLD.status = 'na_origem'  AND NEW.status = 'no_destino') OR
      (OLD.status = 'no_destino' AND NEW.status = 'retornando')
    );
  END IF;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'Transicao de status invalida: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'P0001';
  END IF;

  -- Requisito: para CONCLUIR o retorno e preciso ter o ponto de transito do retorno.
  -- So para o fluxo novo, senao as escoltas ja em "retornando" travariam.
  IF NEW.status = 'na_base' AND OLD.status = 'retornando'
     AND COALESCE(NEW.fluxo_versao, 1) = 2 THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.pontos_controle pc
      JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
      JOIN public.dom_tipos_ponto tp ON tp.id = pc.tipo_ponto_id
      WHERE ev.escolta_id = NEW.id
        AND tp.codigo = 'transito_retorno'
    ) INTO v_tem_transito_retorno;

    IF NOT v_tem_transito_retorno THEN
      RAISE EXCEPTION 'Nao e possivel concluir o retorno sem registrar o ponto de Transito para o Retorno.'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;
