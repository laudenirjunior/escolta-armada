-- 199_troca_senha_obrigatoria_reverter.sql
-- Desmarca só as contas que a 199 marcou (registro em logs_auditoria) e apaga esse registro.
UPDATE public.usuarios SET troca_senha_obrigatoria = false, atualizado_em = now()
WHERE id IN (SELECT registro_id FROM public.logs_auditoria WHERE acao = 'lote_2026_10_troca_senha');
DELETE FROM public.logs_auditoria WHERE acao = 'lote_2026_10_troca_senha';
