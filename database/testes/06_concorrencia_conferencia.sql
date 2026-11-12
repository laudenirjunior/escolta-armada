-- Conferência da 223 (concorrência) numa linha. Esperado: todas as colunas true.
-- Depois da reversão: funcao, internas_existem e indice false (a publicação do Realtime fica,
-- ver o _reverter).
SELECT
  to_regprocedure('public.ultima_alteracao_escolta(uuid)') IS NOT NULL                                    AS funcao,
  (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc
    WHERE oid = 'public.ultima_alteracao_escolta(uuid)'::regprocedure)                                      AS definer_search_path,
  NOT has_function_privilege('anon', 'public.ultima_alteracao_escolta(uuid)', 'EXECUTE')                   AS anon_sem_execute,
  has_function_privilege('authenticated', 'public.ultima_alteracao_escolta(uuid)', 'EXECUTE')              AS authenticated_executa,
  (to_regprocedure('lote_interno.texto_acao_escolta(text, jsonb)') IS NOT NULL
   AND to_regprocedure('lote_interno.texto_mudanca_status(text, text, text, boolean)') IS NOT NULL)        AS internas_existem,
  (NOT has_function_privilege('authenticated', 'lote_interno.texto_acao_escolta(text, jsonb)', 'EXECUTE')
   AND NOT has_function_privilege('authenticated', 'lote_interno.texto_mudanca_status(text, text, text, boolean)', 'EXECUTE')) AS internas_fechadas,
  to_regclass('public.logs_auditoria_registro_data_idx') IS NOT NULL                                      AS indice,
  (SELECT count(*) = 3 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
     AND tablename IN ('escoltas', 'escolta_status_historico', 'pontos_controle'))                          AS realtime;
