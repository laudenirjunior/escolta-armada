-- 207_etapa_atomica_reverter.sql
-- ORDEM: primeiro o git revert do código da onda F e o deploy; depois este arquivo.
DROP FUNCTION IF EXISTS public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid);
