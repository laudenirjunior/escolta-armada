-- 201_checkin_desligado_reverter.sql
-- ORDEM: primeiro o git revert do código da onda B e o deploy; depois este arquivo.
-- Com o código novo no ar e sem a tabela, o X do aviso deixa de valer.
-- Devolve a periodicidade guardada e remove alertas_dispensados.
DO $$
BEGIN
  IF to_regclass('backup_20261008.periodicidade_checkin') IS NOT NULL THEN
    UPDATE public.escoltas e SET periodicidade_checkin_min = b.periodicidade_checkin_min
    FROM backup_20261008.periodicidade_checkin b
    WHERE b.escolta_id = e.id AND e.periodicidade_checkin_min IS NULL;
  END IF;
END $$;
DROP TABLE IF EXISTS backup_20261008.periodicidade_checkin;
DROP TABLE IF EXISTS public.alertas_dispensados;
