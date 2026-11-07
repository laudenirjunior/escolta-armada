-- 209_historico_sem_trigger.sql
-- Lote 2026-10, onda F. Idempotente. Bloco 1.
--
-- Por quê (docs/13, B10): a trigger tr_registrar_historico_status, que gravava o histórico
-- em dobro junto do app, já foi removida de produção, mas a remoção não estava versionada:
-- recriar o banco pelas migrations a traria de volta. Sem efeito em produção.
DROP TRIGGER IF EXISTS tr_registrar_historico_status ON public.escoltas;
COMMENT ON FUNCTION public.registrar_historico_status_escolta() IS
  'OBSOLETA: sem trigger desde antes de 08/10/2026 (remoção versionada na 209). O histórico é gravado pela RPC registrar_etapa_escolta (207) e pelo app.';
