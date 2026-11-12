-- 223_concorrencia_reverter.sql
-- ORDEM: pode rodar antes ou depois do git revert do código. A tela já funciona sem a 223:
-- sem a função, a mensagem de conflito cai no histórico lido direto (ou no texto genérico) e o
-- aviso de atualização mostra "outra pessoa". Idempotente.
--
-- Remove a função de leitura, as duas auxiliares e o índice da auditoria.
-- A PUBLICAÇÃO DO REALTIME FICA como está: escoltas e pontos_controle já eram assinadas pelo
-- Campo, pelo mapa e pela própria página de detalhe antes da 223, e tirar uma tabela da
-- publicação desligaria essas telas. Se precisar mesmo tirar o histórico de status (o único
-- que a 223 pode ter acrescentado), confira antes quem assina (app/dashboard/notificacoes) e
-- rode o comando comentado no fim.
-- Nenhuma RPC existente foi alterada pela 223; não há corpo anterior a devolver.

DROP FUNCTION IF EXISTS public.ultima_alteracao_escolta(uuid);
DROP FUNCTION IF EXISTS lote_interno.texto_mudanca_status(text, text, text, boolean);
DROP FUNCTION IF EXISTS lote_interno.texto_acao_escolta(text, jsonb);
DROP INDEX IF EXISTS public.logs_auditoria_registro_data_idx;

-- Opcional, só com a conferência acima feita:
-- DO $$
-- BEGIN
--   IF EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime'
--               AND schemaname = 'public' AND tablename = 'escolta_status_historico') THEN
--     ALTER PUBLICATION supabase_realtime DROP TABLE public.escolta_status_historico;
--   END IF;
-- END $$;

-- Conferência depois da reversão (esperado: false, false):
-- SELECT to_regprocedure('public.ultima_alteracao_escolta(uuid)') IS NOT NULL AS funcao,
--        to_regclass('public.logs_auditoria_registro_data_idx') IS NOT NULL AS indice;
