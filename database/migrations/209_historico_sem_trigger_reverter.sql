-- 209_historico_sem_trigger_reverter.sql
-- A trigger não existia em produção antes da 209; a reversão só devolve o comentário.
COMMENT ON FUNCTION public.registrar_historico_status_escolta() IS 'OBSOLETA. A trigger foi removida porque duplicava o registro que o app ja faz com autor, observacao e GPS. Mantida apenas como referencia. Escrita direta em escoltas fora do app fica sem historico: e detectada pela reconciliacao descrita em docs/07 - Runbook.md.';
