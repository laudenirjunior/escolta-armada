-- 208_avisos_pelo_servidor_reverter.sql
-- ORDEM: primeiro o git revert do código da onda F e o deploy; depois este arquivo.
DROP FUNCTION IF EXISTS public.enfileirar_alerta_checkin(uuid);
DROP FUNCTION IF EXISTS public.reservar_aviso_presenca(uuid);
DROP TABLE IF EXISTS public.avisos_reservados;
