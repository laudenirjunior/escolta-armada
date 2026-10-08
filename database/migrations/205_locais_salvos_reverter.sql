-- 205_locais_salvos_reverter.sql
-- ORDEM: primeiro o git revert do código da onda D e o deploy; depois este arquivo.
-- Guarda os locais (com quem conferiu) em backup_20261008 antes de remover a tabela.
CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
DO $$
BEGIN
  IF to_regclass('public.locais_salvos') IS NOT NULL THEN
    DROP TABLE IF EXISTS backup_20261008.locais_salvos;
    CREATE TABLE backup_20261008.locais_salvos AS SELECT * FROM public.locais_salvos;
    REVOKE ALL ON backup_20261008.locais_salvos FROM PUBLIC, anon, authenticated;
  END IF;
END $$;
DROP TABLE IF EXISTS public.locais_salvos;
DROP FUNCTION IF EXISTS public.locais_salvos_regras();
