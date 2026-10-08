-- 200_fechar_bucket_fotos.sql
-- Lote 2026-10, onda A (segurança). Idempotente.
-- APLICAR SÓ DEPOIS do deploy do código da onda A e do teste de produção das fotos:
-- antes disso, as telas ainda usam URL pública e todas as fotos sumiriam.
--
-- Por quê (docs/13, H7): o bucket fotos era público para leitura. Foto operacional com
-- GPS e horário ficava acessível por URL sem sessão, com caminho previsível. O código da
-- onda A passa a usar URL assinada em todas as telas e no Telegram, e a migration 198
-- deu leitura a quem tem direito à escolta.
--
-- O que faz:
-- Regra: depois da 200, a única policy de leitura do bucket fotos é fotos_leitura_autenticada.
-- 1. ABORTA sem mudar nada se houver policy FOR ALL em storage.objects que alcance o bucket
--    fotos (ela pode ser a que libera o upload) ou se nenhuma policy de INSERT o alcançar.
-- 2. Guarda em backup_20261008.policies_storage (schema não exposto pela API) toda outra
--    policy FOR SELECT que alcance o bucket, para a reversão recriá-la, e a apaga.
-- 3. Torna o bucket privado.

CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261008.policies_storage (
  policyname text PRIMARY KEY,
  definicao  text NOT NULL,
  guardada_em timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON backup_20261008.policies_storage FROM PUBLIC, anon, authenticated;

-- Uma policy "alcança fotos" quando o predicado menciona o bucket fotos ou não filtra
-- bucket_id nenhum (USING (true), só auth.role() etc.).
CREATE OR REPLACE FUNCTION backup_20261008.alcanca_fotos(p_qual text) RETURNS boolean
  LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce(p_qual, '') ILIKE '%''fotos''%' OR coalesce(p_qual, '') NOT ILIKE '%bucket_id%'
$f$;

DO $$
DECLARE v_amplas text; v_insert int; r record; v_def text; v_with text;
BEGIN
  -- (1) FOR ALL que alcança fotos: pode ser a que libera o upload. Aborta sem mudar nada.
  SELECT string_agg(policyname, ', ') INTO v_amplas
  FROM pg_policies
  WHERE schemaname = 'storage' AND tablename = 'objects' AND cmd = 'ALL'
    AND backup_20261008.alcanca_fotos(qual);
  IF v_amplas IS NOT NULL THEN
    RAISE EXCEPTION 'Policy FOR ALL que alcanca o bucket fotos (%): pode ser a que libera o upload. Nada foi alterado; decidir antes de fechar o bucket.', v_amplas;
  END IF;

  -- (1b) Sem policy de INSERT que alcance fotos, o upload já estaria quebrado: investigar antes.
  SELECT count(*) INTO v_insert
  FROM pg_policies
  WHERE schemaname = 'storage' AND tablename = 'objects' AND cmd = 'INSERT'
    AND (coalesce(with_check, '') ILIKE '%''fotos''%' OR coalesce(with_check, '') NOT ILIKE '%bucket_id%');
  IF v_insert = 0 THEN
    RAISE EXCEPTION 'Nenhuma policy de INSERT alcanca o bucket fotos. Nada foi alterado; conferir o upload antes de fechar o bucket.';
  END IF;

  -- (2) Toda outra SELECT que alcança fotos: guarda e apaga.
  FOR r IN
    SELECT policyname, permissive, roles, qual
    FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects' AND cmd = 'SELECT'
      AND permissive = 'PERMISSIVE'   -- restritiva só estreita o acesso; apagar ampliaria
      AND policyname <> 'fotos_leitura_autenticada'
      AND backup_20261008.alcanca_fotos(qual)
  LOOP
    v_def := format('CREATE POLICY %I ON storage.objects AS %s FOR SELECT TO %s USING (%s)',
                    r.policyname, r.permissive, array_to_string(r.roles, ', '), r.qual);
    INSERT INTO backup_20261008.policies_storage (policyname, definicao)
    VALUES (r.policyname, v_def) ON CONFLICT (policyname) DO NOTHING;
    EXECUTE format('DROP POLICY %I ON storage.objects', r.policyname);
    RAISE NOTICE 'Policy de leitura ampla removida (guardada): %', r.policyname;
  END LOOP;
END $$;

UPDATE storage.buckets SET public = false WHERE id = 'fotos' AND public;

-- Conferência:
-- SELECT id, public FROM storage.buckets WHERE id = 'fotos';            -- esperado: false
-- SELECT policyname, cmd, roles FROM pg_policies WHERE schemaname = 'storage';
-- Teste: abrir a URL pública antiga de uma foto em aba anônima deve dar erro.
