-- 213_poder_total_estrutura_restaurar.sql
-- Lote 2026-10, onda I (revisão adversarial I, menor 16). NÃO é migration: é a volta do que a
-- 213_poder_total_estrutura_reverter.sql (e a 218_poder_total_rpcs_reverter.sql) guardaram em
-- backup_20261008, para quando a onda I for reaplicada depois de uma reversão.
--
-- ORDEM: reaplicar a 213, a 214 e a 218 (e o código da onda I); só então este arquivo, no SQL
-- Editor (sem usuário final: as travas da 213 e da 214 deixam passar). Idempotente: rodar de
-- novo não muda nada, e o que a gestão já tiver feito depois da reaplicação prevalece (cada
-- coluna só é preenchida se estiver vazia; linha que já existe não é tocada).
--
-- O que volta:
-- 1. escoltas: arquivada_em, arquivada_por, motivo_arquivamento, reiniciada_em e versao_gestao
--    (a versão fica com a maior das duas). A trigger de atualizado_em marca a hora da volta.
-- 2. Nas 9 tabelas de campo: anulado_em, anulado_por, motivo_anulacao, anulacao_id e o carimbo
--    status_escolta_no_registro; no histórico, via_rpc.
-- 3. Linhas inteiras de escolta_resets e escolta_conclusoes_antecipadas (só de escolta que
--    ainda existe; a conclusão válida só volta se a escolta não tiver outra válida).
-- 4. Presenças do mural anuladas que a 218_reverter tirou (repetiam uma válida), com o carimbo
--    original.
-- O backup fica como está (a conferência pode ser refeita).

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'escoltas'
                  AND column_name = 'versao_gestao') THEN
    RAISE EXCEPTION 'Reaplique a 213 (e a 214 e a 218) antes de restaurar.';
  END IF;
  IF to_regclass('backup_20261008.poder_total_colunas') IS NULL THEN
    RAISE NOTICE 'Nada a restaurar: backup_20261008.poder_total_colunas não existe.';
  END IF;
END $$;

DO $$
DECLARE t text; v_n int; v_total int := 0;
BEGIN
  IF to_regclass('backup_20261008.poder_total_colunas') IS NULL THEN RETURN; END IF;

  -- 1. Escoltas.
  UPDATE public.escoltas e SET
         arquivada_em        = coalesce(e.arquivada_em, (b.dados ->> 'arquivada_em')::timestamptz),
         arquivada_por       = coalesce(e.arquivada_por, (b.dados ->> 'arquivada_por')::uuid),
         motivo_arquivamento = coalesce(e.motivo_arquivamento, b.dados ->> 'motivo_arquivamento'),
         reiniciada_em       = coalesce(e.reiniciada_em, (b.dados ->> 'reiniciada_em')::timestamptz),
         versao_gestao       = greatest(e.versao_gestao, coalesce((b.dados ->> 'versao_gestao')::int, 0))
    FROM backup_20261008.poder_total_colunas b
   WHERE b.tabela = 'escoltas' AND b.id = e.id
     AND (e.arquivada_em IS DISTINCT FROM coalesce(e.arquivada_em, (b.dados ->> 'arquivada_em')::timestamptz)
          OR e.reiniciada_em IS DISTINCT FROM coalesce(e.reiniciada_em, (b.dados ->> 'reiniciada_em')::timestamptz)
          OR e.motivo_arquivamento IS DISTINCT FROM coalesce(e.motivo_arquivamento, b.dados ->> 'motivo_arquivamento')
          OR e.versao_gestao < coalesce((b.dados ->> 'versao_gestao')::int, 0));
  GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
  RAISE NOTICE 'escoltas restauradas: %', v_n;

  -- 4. Presenças do mural anuladas tiradas pela 218_reverter (antes do item 2, que lhes
  --    devolve a anulação e o carimbo junto com as demais).
  IF to_regclass('backup_20261008.mural_presencas_anuladas') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'mural_presencas_escolta_id_vigilante_id_key') THEN
    INSERT INTO public.mural_presencas
    SELECT (jsonb_populate_record(NULL::public.mural_presencas, b.linha)).*
      FROM backup_20261008.mural_presencas_anuladas b
     WHERE EXISTS (SELECT 1 FROM public.escoltas e WHERE e.id = (b.linha ->> 'escolta_id')::uuid)
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    -- A trigger de carimbo regrava o status no INSERT: devolve o original.
    UPDATE public.mural_presencas m SET status_escolta_no_registro = b.linha ->> 'status_escolta_no_registro'
      FROM backup_20261008.mural_presencas_anuladas b
     WHERE m.id = (b.linha ->> 'id')::uuid
       AND m.status_escolta_no_registro IS DISTINCT FROM b.linha ->> 'status_escolta_no_registro';
    RAISE NOTICE 'presenças do mural anuladas devolvidas: %', v_n;
  END IF;

  -- 2. Tabelas de campo.
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico']
  LOOP
    EXECUTE format($q$
      UPDATE public.%I x SET
             anulado_em      = coalesce(x.anulado_em, (b.dados ->> 'anulado_em')::timestamptz),
             anulado_por     = coalesce(x.anulado_por, (b.dados ->> 'anulado_por')::uuid),
             motivo_anulacao = coalesce(x.motivo_anulacao, b.dados ->> 'motivo_anulacao'),
             anulacao_id     = coalesce(x.anulacao_id, (b.dados ->> 'anulacao_id')::uuid),
             status_escolta_no_registro = coalesce(x.status_escolta_no_registro, b.dados ->> 'status_escolta_no_registro')
             %s
        FROM backup_20261008.poder_total_colunas b
       WHERE b.tabela = %L AND b.id = x.id
         AND ((x.anulado_em IS NULL AND b.dados ->> 'anulado_em' IS NOT NULL)
              OR (x.status_escolta_no_registro IS NULL AND b.dados ->> 'status_escolta_no_registro' IS NOT NULL)
              %s)$q$,
      t,
      CASE WHEN t = 'escolta_status_historico' THEN ', via_rpc = x.via_rpc OR coalesce((b.dados ->> ''via_rpc'')::boolean, false)' ELSE '' END,
      t,
      CASE WHEN t = 'escolta_status_historico' THEN 'OR (NOT x.via_rpc AND coalesce((b.dados ->> ''via_rpc'')::boolean, false))' ELSE '' END);
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    IF v_n > 0 THEN RAISE NOTICE '% restaurados: %', t, v_n; END IF;
  END LOOP;

  -- 3. Linhas inteiras.
  INSERT INTO public.escolta_resets
  SELECT (jsonb_populate_record(NULL::public.escolta_resets, b.linha)).*
    FROM backup_20261008.poder_total_linhas b
   WHERE b.tabela = 'escolta_resets'
     AND EXISTS (SELECT 1 FROM public.escoltas e WHERE e.id = (b.linha ->> 'escolta_id')::uuid)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
  RAISE NOTICE 'escolta_resets devolvidas: %', v_n;
  INSERT INTO public.escolta_conclusoes_antecipadas
  SELECT (jsonb_populate_record(NULL::public.escolta_conclusoes_antecipadas, b.linha)).*
    FROM backup_20261008.poder_total_linhas b
   WHERE b.tabela = 'escolta_conclusoes_antecipadas'
     AND EXISTS (SELECT 1 FROM public.escoltas e WHERE e.id = (b.linha ->> 'escolta_id')::uuid)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
  RAISE NOTICE 'escolta_conclusoes_antecipadas devolvidas: %', v_n;
  RAISE NOTICE 'Restauração concluída: % linha(s) tocada(s).', v_total;
END $$;

-- Conferência (depois de restaurar; compare com as contagens tiradas antes da reversão):
-- SELECT count(*) FILTER (WHERE arquivada_em IS NOT NULL) AS arquivadas, count(*) FILTER (WHERE versao_gestao <> 0) AS com_versao FROM escoltas;
-- SELECT count(*) FROM pontos_controle WHERE anulado_em IS NOT NULL;
-- SELECT (SELECT count(*) FROM escolta_resets), (SELECT count(*) FROM escolta_conclusoes_antecipadas);
