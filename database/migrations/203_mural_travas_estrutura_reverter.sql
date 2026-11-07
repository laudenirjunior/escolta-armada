-- 203_mural_travas_estrutura_reverter.sql
-- Guarda pedidos e presenças em backup_20261008 (se houver linhas) e remove a estrutura.
-- Reverta antes a 204, que depende destas tabelas.
CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
DO $$
BEGIN
  IF to_regclass('public.mural_pedidos') IS NOT NULL AND EXISTS (SELECT 1 FROM public.mural_pedidos) THEN
    EXECUTE 'CREATE TABLE IF NOT EXISTS backup_20261008.mural_pedidos AS SELECT * FROM public.mural_pedidos WITH NO DATA';
    EXECUTE 'INSERT INTO backup_20261008.mural_pedidos SELECT * FROM public.mural_pedidos';
  END IF;
  IF to_regclass('public.mural_presencas') IS NOT NULL AND EXISTS (SELECT 1 FROM public.mural_presencas) THEN
    EXECUTE 'CREATE TABLE IF NOT EXISTS backup_20261008.mural_presencas AS SELECT * FROM public.mural_presencas WITH NO DATA';
    EXECUTE 'INSERT INTO backup_20261008.mural_presencas SELECT * FROM public.mural_presencas';
  END IF;
END $$;
DROP TABLE IF EXISTS public.mural_pedidos;
DROP TABLE IF EXISTS public.mural_presencas;
DROP TABLE IF EXISTS public.configuracoes_mural;
DROP TRIGGER IF EXISTS tr_proteger_escala_fixa ON public.escoltas;
DROP FUNCTION IF EXISTS public.proteger_escala_fixa();
ALTER TABLE public.escoltas DROP COLUMN IF EXISTS escala_fixa;
DELETE FROM public.notificacoes WHERE tipo_evento_id IN
  (SELECT id FROM public.dom_tipos_evento WHERE codigo IN ('pedido_substituicao', 'decisao_substituicao', 'substituicao_equipe'));
DELETE FROM public.dom_tipos_evento WHERE codigo IN ('pedido_substituicao', 'decisao_substituicao', 'substituicao_equipe');
