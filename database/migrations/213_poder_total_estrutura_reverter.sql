-- 213_poder_total_estrutura_reverter.sql
-- ORDEM: primeiro o git revert do código da onda I e o deploy; depois 218_reverter (bloco 2)
-- e 214_reverter; só então este arquivo. Aborta se a 214 ainda estiver aplicada.
-- Guarda em backup_20261008 as colunas novas que tiverem valor (arquivamento, versão, anulação,
-- carimbo e via_rpc) e as linhas inteiras de escolta_resets e escolta_conclusoes_antecipadas;
-- depois remove a estrutura da 213. Nenhum registro de campo é apagado.
DO $$
BEGIN
  IF to_regprocedure('lote_interno.impedir_edicao_escolta_iniciada()') IS NOT NULL THEN
    RAISE EXCEPTION 'Reverta a 214 antes da 213.';
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261008.poder_total_colunas (
  tabela     text NOT NULL,
  id         uuid NOT NULL,
  dados      jsonb NOT NULL,
  gravado_em timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS backup_20261008.poder_total_linhas (
  tabela     text NOT NULL,
  linha      jsonb NOT NULL,
  gravado_em timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON backup_20261008.poder_total_colunas FROM PUBLIC, anon, authenticated;
REVOKE ALL ON backup_20261008.poder_total_linhas FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t text;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'escoltas' AND column_name = 'versao_gestao') THEN
    EXECUTE $q$
      INSERT INTO backup_20261008.poder_total_colunas (tabela, id, dados)
      SELECT 'escoltas', id, jsonb_build_object('arquivada_em', arquivada_em, 'arquivada_por', arquivada_por,
             'motivo_arquivamento', motivo_arquivamento, 'reiniciada_em', reiniciada_em, 'versao_gestao', versao_gestao)
      FROM public.escoltas
      WHERE arquivada_em IS NOT NULL OR reiniciada_em IS NOT NULL OR versao_gestao <> 0 OR motivo_arquivamento IS NOT NULL$q$;
  END IF;
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico']
  LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = t AND column_name = 'anulado_em') THEN
      EXECUTE format($q$
        INSERT INTO backup_20261008.poder_total_colunas (tabela, id, dados)
        SELECT %L, id, jsonb_build_object('anulado_em', anulado_em, 'anulado_por', anulado_por, 'motivo_anulacao', motivo_anulacao,
               'anulacao_id', anulacao_id, 'status_escolta_no_registro', status_escolta_no_registro)
               || CASE WHEN %L = 'escolta_status_historico' THEN jsonb_build_object('via_rpc', to_jsonb(x) -> 'via_rpc') ELSE '{}'::jsonb END
        FROM public.%I x
        WHERE anulado_em IS NOT NULL OR status_escolta_no_registro IS NOT NULL$q$, t, t, t);
    END IF;
  END LOOP;
  IF to_regclass('public.escolta_resets') IS NOT NULL THEN
    INSERT INTO backup_20261008.poder_total_linhas (tabela, linha) SELECT 'escolta_resets', to_jsonb(r) FROM public.escolta_resets r;
  END IF;
  IF to_regclass('public.escolta_conclusoes_antecipadas') IS NOT NULL THEN
    INSERT INTO backup_20261008.poder_total_linhas (tabela, linha)
    SELECT 'escolta_conclusoes_antecipadas', to_jsonb(c) FROM public.escolta_conclusoes_antecipadas c;
  END IF;
END $$;

DROP VIEW IF EXISTS public.vw_pendencias_conclusao;
DROP TABLE IF EXISTS public.escolta_conclusoes_antecipadas;
DROP TABLE IF EXISTS public.escolta_resets;

DROP TRIGGER IF EXISTS tr_preencher_lancado_por ON public.pontos_controle;
DROP TRIGGER IF EXISTS tr_travar_colunas_gestao_escoltas ON public.escoltas;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_carimbar_etapa_' || t, t);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_travar_colunas_gestao_' || t, t);
    EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS anulado_em, DROP COLUMN IF EXISTS anulado_por,
                    DROP COLUMN IF EXISTS motivo_anulacao, DROP COLUMN IF EXISTS anulacao_id,
                    DROP COLUMN IF EXISTS status_escolta_no_registro', t);
  END LOOP;
END $$;
DROP INDEX IF EXISTS public.idx_anulacao_pontos;
ALTER TABLE public.escolta_status_historico DROP COLUMN IF EXISTS via_rpc;
DROP FUNCTION IF EXISTS lote_interno.carimbar_etapa();
DROP FUNCTION IF EXISTS lote_interno.travar_colunas_gestao();
DROP FUNCTION IF EXISTS lote_interno.preencher_lancado_por();

DROP INDEX IF EXISTS public.idx_escoltas_nao_arquivadas;
ALTER TABLE public.escoltas
  DROP COLUMN IF EXISTS arquivada_em,
  DROP COLUMN IF EXISTS arquivada_por,
  DROP COLUMN IF EXISTS motivo_arquivamento,
  DROP COLUMN IF EXISTS reiniciada_em,
  DROP COLUMN IF EXISTS versao_gestao;
