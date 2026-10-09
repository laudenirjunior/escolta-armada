-- 215_locais_uso_reverter.sql
-- ORDEM: primeiro o git revert do código da onda D2 e o deploy; depois este arquivo (antes
-- da 214_reverter e da 205_reverter). Guarda vezes_usado e uf em backup_20261008.locais_uso
-- (uma linha por local; rodar de novo não apaga o que já foi guardado), tira a trigger de
-- uso, as funções internas e as colunas, devolve o corpo da 205 de locais_salvos_regras e
-- os privilégios de tabela da 205 (INSERT e UPDATE sem lista de colunas).
CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'locais_salvos' AND column_name = 'vezes_usado') THEN
    CREATE TABLE IF NOT EXISTS backup_20261008.locais_uso (local_id uuid PRIMARY KEY, nome text, vezes_usado integer, uf text, guardado_em timestamptz NOT NULL DEFAULT now());
    REVOKE ALL ON backup_20261008.locais_uso FROM PUBLIC, anon, authenticated;
    INSERT INTO backup_20261008.locais_uso (local_id, nome, vezes_usado, uf)
    SELECT id, nome, vezes_usado, uf FROM public.locais_salvos
    ON CONFLICT (local_id) DO UPDATE SET nome = EXCLUDED.nome, vezes_usado = EXCLUDED.vezes_usado, uf = EXCLUDED.uf, guardado_em = now();
  END IF;
END $$;

DROP TRIGGER IF EXISTS tr_contar_uso_local ON public.escoltas;
DROP FUNCTION IF EXISTS lote_interno.contar_uso_local();
DROP FUNCTION IF EXISTS lote_interno.carregar_uso_locais();
DROP FUNCTION IF EXISTS lote_interno.local_do_endereco(text, numeric, numeric);

-- Privilégios da 205 (o REVOKE de tabela também tira os de coluna).
REVOKE INSERT, UPDATE ON public.locais_salvos FROM authenticated;
GRANT INSERT, UPDATE ON public.locais_salvos TO authenticated;

ALTER TABLE public.locais_salvos DROP CONSTRAINT IF EXISTS locais_salvos_uf_formato;
ALTER TABLE public.locais_salvos DROP CONSTRAINT IF EXISTS locais_salvos_vezes_usado_positivo;
ALTER TABLE public.locais_salvos DROP COLUMN IF EXISTS vezes_usado;
ALTER TABLE public.locais_salvos DROP COLUMN IF EXISTS uf;

-- Corpo da 205.
CREATE OR REPLACE FUNCTION public.locais_salvos_regras() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; v_eu uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;      -- SQL Editor e migrations
  SELECT public.get_meu_perfil() INTO v_perfil;
  v_eu := public.get_meu_usuario_id();
  IF TG_OP = 'INSERT' THEN
    NEW.criado_por := v_eu; NEW.criado_em := now();
    IF NEW.situacao = 'ativo' THEN NEW.situacao := 'aguardando_conferencia'; END IF;
    NEW.conferido_por := NULL; NEW.conferido_em := NULL;
  ELSE
    NEW.criado_por := OLD.criado_por; NEW.criado_em := OLD.criado_em;
    -- Local ativo que muda de coordenada, nome, endereço ou complemento volta para
    -- conferência (o texto e o pino são o que a conferência atestou).
    IF OLD.situacao = 'ativo' AND NEW.situacao = 'ativo'
       AND (NEW.latitude IS DISTINCT FROM OLD.latitude OR NEW.longitude IS DISTINCT FROM OLD.longitude
            OR NEW.nome IS DISTINCT FROM OLD.nome OR NEW.endereco IS DISTINCT FROM OLD.endereco
            OR NEW.complemento IS DISTINCT FROM OLD.complemento) THEN
      NEW.situacao := 'aguardando_conferencia';
    END IF;
    IF NEW.situacao = 'ativo' AND OLD.situacao IS DISTINCT FROM 'ativo' THEN
      IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor') THEN
        RAISE EXCEPTION 'Somente gestor ou administrador confere e ativa um local salvo.';
      END IF;
      NEW.conferido_por := v_eu; NEW.conferido_em := now();
    ELSIF NEW.situacao <> 'ativo' THEN
      NEW.conferido_por := CASE WHEN NEW.situacao = 'inativo' THEN OLD.conferido_por END;
      NEW.conferido_em := CASE WHEN NEW.situacao = 'inativo' THEN OLD.conferido_em END;
    ELSE
      NEW.conferido_por := OLD.conferido_por; NEW.conferido_em := OLD.conferido_em;
    END IF;
  END IF;
  NEW.atualizado_por := v_eu; NEW.atualizado_em := now();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.locais_salvos_regras() FROM PUBLIC, anon, authenticated;
