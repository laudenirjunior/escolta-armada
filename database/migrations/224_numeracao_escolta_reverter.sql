-- 224_numeracao_escolta_reverter.sql
-- Volta a numeração ao estado da 195 (MAX visível + 1, SECURITY INVOKER) e retira a criar_escolta.
-- A tela nova cai no caminho antigo (INSERT direto) quando a função não existe.
-- ATENÇÃO: com a reversão, o erro de código repetido volta sempre que a escolta de maior número
-- do ano estiver excluída ou arquivada (invisível para quem cria).
-- O contador fica (só leitura interna, sem efeito sem a função); apagar à mão se quiser:
--   DROP TABLE lote_interno.escolta_codigo_contador;

DROP FUNCTION IF EXISTS public.criar_escolta(jsonb, jsonb);

CREATE OR REPLACE FUNCTION public.gerar_codigo_escolta() RETURNS trigger
    LANGUAGE plpgsql SECURITY INVOKER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_ano TEXT;
  v_seq INTEGER;
BEGIN
  IF NEW.codigo_escolta IS NULL OR NEW.codigo_escolta = '' THEN
    v_ano := TO_CHAR(NOW(), 'YYYY');
    SELECT COALESCE(
      MAX(CAST(SUBSTRING(codigo_escolta FROM 'ESC-' || v_ano || '-(\d+)') AS INTEGER)),
      0
    ) + 1
    INTO v_seq
    FROM escoltas
    WHERE codigo_escolta LIKE 'ESC-' || v_ano || '-%';

    NEW.codigo_escolta := 'ESC-' || v_ano || '-' || LPAD(v_seq::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;
GRANT EXECUTE ON FUNCTION public.gerar_codigo_escolta() TO PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.gerar_codigo_escolta() IS NULL;

NOTIFY pgrst, 'reload schema';
