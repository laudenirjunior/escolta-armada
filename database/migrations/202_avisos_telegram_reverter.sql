-- 202_avisos_telegram_reverter.sql
-- ORDEM: reverter antes a 204 (as RPCs do mural chamam a fila) e o código das ondas C e F.
-- Este arquivo aborta se a 204 ainda estiver aplicada. Desagenda só os jobs do lote e não
-- remove pg_cron nem pg_net (removê-las apagaria qualquer outro agendamento do projeto).
DO $$
BEGIN
  IF to_regprocedure('public.mural_travas_ativas()') IS NOT NULL THEN
    RAISE EXCEPTION 'Reverta a 204 antes da 202: as RPCs do mural usam a fila de avisos.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lote2026_avisos_telegram';
  END IF;
END $$;
DROP FUNCTION IF EXISTS public.conferir_avisos_telegram();
DROP FUNCTION IF EXISTS public.enviar_avisos_telegram();
DROP FUNCTION IF EXISTS public._enfileirar_aviso(text, text, uuid, text);
DROP FUNCTION IF EXISTS public.avisos_pelo_banco_ativos();
DROP FUNCTION IF EXISTS public.escapar_html(text);
DROP TABLE IF EXISTS public.avisos_telegram;
DROP TABLE IF EXISTS public.configuracao_avisos;
DROP TABLE IF EXISTS backup_20261008.extensoes_antes_202;
