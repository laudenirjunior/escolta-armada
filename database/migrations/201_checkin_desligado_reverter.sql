-- 201_checkin_desligado_reverter.sql
-- Devolve a periodicidade guardada e remove alertas_dispensados.
UPDATE public.escoltas e SET periodicidade_checkin_min = b.periodicidade_checkin_min
FROM backup_20261008.periodicidade_checkin b
WHERE b.escolta_id = e.id AND e.periodicidade_checkin_min IS NULL;
DROP TABLE IF EXISTS backup_20261008.periodicidade_checkin;
DROP TABLE IF EXISTS public.alertas_dispensados;
