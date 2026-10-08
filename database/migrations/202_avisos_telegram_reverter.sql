-- 202_avisos_telegram_reverter.sql
-- Desagenda o cron, remove fila, configuração e funções. Remove pg_net e pg_cron só se a
-- 202 os criou (registro em backup_20261008.extensoes_antes_202).
DO $$
BEGIN
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
DO $$
DECLARE r record;
BEGIN
  IF to_regclass('backup_20261008.extensoes_antes_202') IS NULL THEN RETURN; END IF;
  FOR r IN SELECT nome FROM backup_20261008.extensoes_antes_202 WHERE NOT existia LOOP
    EXECUTE format('DROP EXTENSION IF EXISTS %I CASCADE', r.nome);
  END LOOP;
  DROP TABLE backup_20261008.extensoes_antes_202;
END $$;
