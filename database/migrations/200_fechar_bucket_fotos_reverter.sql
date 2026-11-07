-- 200_fechar_bucket_fotos_reverter.sql
-- Reabre o bucket e recria as policies guardadas pela 200.
UPDATE storage.buckets SET public = true WHERE id = 'fotos';
DO $$
DECLARE r record;
BEGIN
  IF to_regclass('backup_20261008.policies_storage') IS NULL THEN RETURN; END IF;
  FOR r IN SELECT policyname, definicao FROM backup_20261008.policies_storage LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = r.policyname) THEN
      EXECUTE r.definicao;
    END IF;
  END LOOP;
END $$;
DROP TABLE IF EXISTS backup_20261008.policies_storage;
DROP FUNCTION IF EXISTS backup_20261008.alcanca_fotos(text);
-- O schema backup_20261008 fica: outras migrations do lote também guardam backup nele.
