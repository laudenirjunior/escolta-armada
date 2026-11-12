-- Conferência da 222 (lançamento retroativo) numa linha. Esperado: todas as colunas true.
-- Depois da reversão: rpc, trava, tipo_aviso e silencio false (as colunas ficam, ver o _reverter).
SELECT
  (SELECT count(*) = 4 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'escoltas'
     AND column_name IN ('lancamento_retroativo', 'retroativo_por', 'retroativo_em', 'retroativo_motivo'))           AS colunas_escoltas,
  (SELECT count(*) = 9 FROM information_schema.columns WHERE table_schema = 'public'
     AND table_name IN ('escolta_status_historico', 'pontos_controle', 'fotos')
     AND column_name IN ('registrado_em', 'retroativo', 'motivo_retroativo'))                                        AS colunas_registros,
  (SELECT count(*) = 2 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'fotos'
     AND column_name IN ('origem', 'origem_localizacao'))                                                            AS colunas_fotos,
  (SELECT count(*) = 2 FROM pg_constraint WHERE conname IN ('fotos_galeria_sem_gps_do_aparelho', 'pontos_retroativo_sem_gps')) AS checks_sem_gps,
  (SELECT count(*) = 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'lancar_escolta_retroativa') AS rpc,
  (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc
    WHERE oid = 'public.lancar_escolta_retroativa(uuid, jsonb, text, boolean, jsonb)'::regprocedure)                 AS definer_search_path,
  NOT has_function_privilege('anon', 'public.lancar_escolta_retroativa(uuid, jsonb, text, boolean, jsonb)', 'EXECUTE') AS anon_sem_execute,
  has_function_privilege('authenticated', 'public.lancar_escolta_retroativa(uuid, jsonb, text, boolean, jsonb)', 'EXECUTE') AS authenticated_executa,
  NOT has_function_privilege('authenticated', 'lote_interno.ultimo_registro_campo(uuid)', 'EXECUTE')               AS internas_fechadas,
  (SELECT count(*) = 4 FROM pg_trigger WHERE tgname = 'tr_travar_colunas_retroativo')                               AS trava,
  (SELECT count(*) = 1 FROM public.dom_tipos_evento WHERE codigo = 'lancamento_retroativo')                         AS tipo_aviso,
  (SELECT prosrc LIKE '%escolta.lancamento_retroativo%' FROM pg_proc
    WHERE oid = 'public._enfileirar_aviso(text, text, uuid, text)'::regprocedure)
  AND (SELECT prosrc LIKE '%escolta.lancamento_retroativo%' FROM pg_proc
    WHERE oid = 'lote_interno.notificar(text, uuid, text, uuid[], text, text, jsonb)'::regprocedure)                AS silencio;
