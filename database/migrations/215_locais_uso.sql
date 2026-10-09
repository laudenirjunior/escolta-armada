-- 215_locais_uso.sql
-- Lote 2026-10, onda D2 (acréscimos da onda D, item 4.6 do adendo 01; docs/14, seção 14).
-- Idempotente. Bloco 1, depois da 214. Compatível com a master 2b3fff9: a master não lê nem
-- grava locais_salvos; a trigger nova em escoltas só lê o endereço gravado, só escreve em
-- locais_salvos e nunca recusa nada (erro interno vira aviso no log, e a escolta é gravada).
--
-- Por quê:
-- 1. Ordenação dos atalhos pelos mais usados: locais_salvos.vezes_usado, somado por uma
--    trigger AFTER INSERT OR UPDATE OF origem_endereco, destino_endereco, origem_lat,
--    origem_lng, destino_lat, destino_lng em escoltas. Só conta quando a origem ou o
--    destino mudou de fato (IS DISTINCT FROM) e passou a bater com outro local: um local
--    bate quando o endereço gravado é o endereço do local, sozinho ou seguido de ", " e do
--    complemento (a Nova grava o complemento no texto, enderecoComComplemento), ou quando a
--    coordenada está a até 100 m da do local. Mudança de status, KM, UF e as cargas não
--    contam (não tocam essas colunas). Locais inativos não contam.
-- 2. UF do local (para o atalho preencher a UF da escolta quando a onda K existir):
--    locais_salvos.uf, CHECK de duas letras maiúsculas; os 5 locais da carga da 205 são RJ.
-- 3. O operador não altera vezes_usado nem uf (não tem UPDATE em locais_salvos, 205), e
--    nenhum perfil altera vezes_usado pela API: INSERT e UPDATE de authenticated passam a
--    ser por coluna, sem vezes_usado. Só a trigger (SECURITY DEFINER, sem GRANT) soma.
-- 4. locais_salvos_regras (205) ignora o UPDATE que só muda vezes_usado (senão o uso de um
--    local pela escolta de um operador gravaria o operador em atualizado_por) e passa a
--    devolver para conferência o local ativo cuja UF mudou (a UF é parte do que a
--    conferência atesta, como o texto e o pino).
-- 5. Carga inicial do uso a partir das escoltas existentes: só LÊ escoltas (UPDATE só em
--    locais_salvos). ESC-2026-0001 e ESC-2026-0007 não mudam. Roda só na primeira
--    aplicação (quando a coluna nasce), para a reaplicação não recontar.
--
-- Conferência:
-- SELECT nome, uf, vezes_usado, situacao FROM locais_salvos ORDER BY vezes_usado DESC, nome;  -- 5 com uf RJ
-- SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_contar_uso_local';                       -- 1
-- SELECT has_column_privilege('authenticated', 'public.locais_salvos', 'vezes_usado', 'UPDATE');  -- false
-- Reversão: 215_locais_uso_reverter.sql (guarda vezes_usado e uf em backup_20261008.locais_uso).

CREATE SCHEMA IF NOT EXISTS lote_interno;
REVOKE ALL ON SCHEMA lote_interno FROM PUBLIC, anon, authenticated;

-- A. Qual local salvo (não inativo) corresponde a um endereço gravado: primeiro o texto,
-- depois a coordenada mais próxima até 100 m. Interna, sem GRANT.
CREATE OR REPLACE FUNCTION lote_interno.local_do_endereco(p_endereco text, p_lat numeric, p_lng numeric)
    RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  WITH c AS (
    SELECT l.id, l.nome,
           (p_endereco IS NOT NULL AND trim(l.endereco) <> ''
            AND (lower(trim(p_endereco)) = lower(trim(l.endereco))
                 OR left(lower(trim(p_endereco)), length(trim(l.endereco)) + 2) = lower(trim(l.endereco)) || ', ')) AS pelo_texto,
           CASE WHEN p_lat IS NULL OR p_lng IS NULL OR (p_lat = 0 AND p_lng = 0)
                     OR l.latitude IS NULL OR l.longitude IS NULL THEN NULL
                ELSE 2 * 6371000 * asin(sqrt(
                       power(sin(radians((l.latitude - p_lat)::float8) / 2), 2)
                       + cos(radians(p_lat::float8)) * cos(radians(l.latitude::float8))
                         * power(sin(radians((l.longitude - p_lng)::float8) / 2), 2)))
           END AS metros
      FROM public.locais_salvos l
     WHERE l.situacao <> 'inativo'
  )
  SELECT id FROM c
   WHERE pelo_texto OR metros <= 100
   ORDER BY pelo_texto DESC, metros NULLS LAST, nome
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION lote_interno.local_do_endereco(text, numeric, numeric) FROM PUBLIC, anon, authenticated;

-- B. Carga do uso a partir das escoltas existentes: só leitura de escoltas. Devolve quantos
-- locais tiveram o uso gravado.
CREATE OR REPLACE FUNCTION lote_interno.carregar_uso_locais() RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n integer;
BEGIN
  WITH usos AS (
    SELECT lote_interno.local_do_endereco(e.origem_endereco, e.origem_lat, e.origem_lng) AS local_id FROM public.escoltas e
    UNION ALL
    SELECT lote_interno.local_do_endereco(e.destino_endereco, e.destino_lat, e.destino_lng) FROM public.escoltas e
  ), contagem AS (
    SELECT local_id, count(*)::integer AS n FROM usos WHERE local_id IS NOT NULL GROUP BY local_id
  )
  UPDATE public.locais_salvos l SET vezes_usado = c.n
    FROM contagem c WHERE c.local_id = l.id AND l.vezes_usado IS DISTINCT FROM c.n;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.carregar_uso_locais() FROM PUBLIC, anon, authenticated;

-- C. Colunas novas e, só quando vezes_usado nasce, a carga do uso a partir das escoltas
-- (a reaplicação não reconta).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'locais_salvos' AND column_name = 'vezes_usado') THEN
    ALTER TABLE public.locais_salvos ADD COLUMN vezes_usado integer NOT NULL DEFAULT 0;
    PERFORM lote_interno.carregar_uso_locais();
  END IF;
  ALTER TABLE public.locais_salvos ADD COLUMN IF NOT EXISTS uf text;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'locais_salvos_uf_formato') THEN
    ALTER TABLE public.locais_salvos ADD CONSTRAINT locais_salvos_uf_formato CHECK (uf ~ '^[A-Z]{2}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'locais_salvos_vezes_usado_positivo') THEN
    ALTER TABLE public.locais_salvos ADD CONSTRAINT locais_salvos_vezes_usado_positivo CHECK (vezes_usado >= 0);
  END IF;
END $$;
COMMENT ON COLUMN public.locais_salvos.vezes_usado IS 'Lote 2026-10 (D2): quantas vezes o local virou origem ou destino de escolta. Só a trigger tr_contar_uso_local soma; ordena os atalhos.';
COMMENT ON COLUMN public.locais_salvos.uf IS 'Lote 2026-10 (D2): UF do local; o atalho preenche a UF da escolta (onda K).';

-- D. Privilégios por coluna: ninguém grava vezes_usado pela API (as policies da 205 continuam).
REVOKE INSERT, UPDATE ON public.locais_salvos FROM authenticated;
GRANT INSERT (nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, uf) ON public.locais_salvos TO authenticated;
GRANT UPDATE (nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, uf) ON public.locais_salvos TO authenticated;

-- E. Regras do local (205) com o UPDATE só de vezes_usado ignorado e a UF na reconferência.
CREATE OR REPLACE FUNCTION public.locais_salvos_regras() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; v_eu uuid;
BEGIN
  -- Uso contado pela trigger das escoltas (215): não é edição do local.
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'vezes_usado') = (to_jsonb(OLD) - 'vezes_usado') THEN
    RETURN NEW;
  END IF;
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;      -- SQL Editor e migrations
  SELECT public.get_meu_perfil() INTO v_perfil;
  v_eu := public.get_meu_usuario_id();
  IF TG_OP = 'INSERT' THEN
    NEW.criado_por := v_eu; NEW.criado_em := now();
    IF NEW.situacao = 'ativo' THEN NEW.situacao := 'aguardando_conferencia'; END IF;
    NEW.conferido_por := NULL; NEW.conferido_em := NULL;
    NEW.vezes_usado := 0;
  ELSE
    NEW.criado_por := OLD.criado_por; NEW.criado_em := OLD.criado_em;
    NEW.vezes_usado := OLD.vezes_usado;
    -- Local ativo que muda de coordenada, nome, endereço, complemento ou UF volta para
    -- conferência (o texto, o pino e a UF são o que a conferência atestou).
    IF OLD.situacao = 'ativo' AND NEW.situacao = 'ativo'
       AND (NEW.latitude IS DISTINCT FROM OLD.latitude OR NEW.longitude IS DISTINCT FROM OLD.longitude
            OR NEW.nome IS DISTINCT FROM OLD.nome OR NEW.endereco IS DISTINCT FROM OLD.endereco
            OR NEW.complemento IS DISTINCT FROM OLD.complemento OR NEW.uf IS DISTINCT FROM OLD.uf) THEN
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

-- F. Trigger de uso. Só age quando o local da origem ou do destino mudou de fato; nunca
-- recusa a gravação da escolta (erro interno vira WARNING).
CREATE OR REPLACE FUNCTION lote_interno.contar_uso_local() RETURNS trigger
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_novo uuid; v_antigo uuid; v_lado text;
BEGIN
  FOREACH v_lado IN ARRAY ARRAY['origem', 'destino'] LOOP
    BEGIN
      IF v_lado = 'origem' THEN
        IF TG_OP = 'UPDATE' AND NOT (NEW.origem_endereco IS DISTINCT FROM OLD.origem_endereco
                                     OR NEW.origem_lat IS DISTINCT FROM OLD.origem_lat
                                     OR NEW.origem_lng IS DISTINCT FROM OLD.origem_lng) THEN
          CONTINUE;
        END IF;
        v_novo := lote_interno.local_do_endereco(NEW.origem_endereco, NEW.origem_lat, NEW.origem_lng);
        v_antigo := CASE WHEN TG_OP = 'UPDATE' THEN lote_interno.local_do_endereco(OLD.origem_endereco, OLD.origem_lat, OLD.origem_lng) END;
      ELSE
        IF TG_OP = 'UPDATE' AND NOT (NEW.destino_endereco IS DISTINCT FROM OLD.destino_endereco
                                     OR NEW.destino_lat IS DISTINCT FROM OLD.destino_lat
                                     OR NEW.destino_lng IS DISTINCT FROM OLD.destino_lng) THEN
          CONTINUE;
        END IF;
        v_novo := lote_interno.local_do_endereco(NEW.destino_endereco, NEW.destino_lat, NEW.destino_lng);
        v_antigo := CASE WHEN TG_OP = 'UPDATE' THEN lote_interno.local_do_endereco(OLD.destino_endereco, OLD.destino_lat, OLD.destino_lng) END;
      END IF;
      IF v_novo IS NOT NULL AND v_novo IS DISTINCT FROM v_antigo THEN
        UPDATE public.locais_salvos SET vezes_usado = vezes_usado + 1 WHERE id = v_novo;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'contar_uso_local (%): % (%)', v_lado, SQLERRM, SQLSTATE;
    END;
  END LOOP;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.contar_uso_local() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_contar_uso_local ON public.escoltas;
CREATE TRIGGER tr_contar_uso_local
  AFTER INSERT OR UPDATE OF origem_endereco, destino_endereco, origem_lat, origem_lng, destino_lat, destino_lng
  ON public.escoltas FOR EACH ROW EXECUTE FUNCTION lote_interno.contar_uso_local();

-- G. UF dos 5 locais da carga da 205 (todos no Rio de Janeiro).
UPDATE public.locais_salvos SET uf = 'RJ'
 WHERE uf IS NULL AND nome IN ('JAMEF', 'Sede', 'Engenhão', 'Aeroporto do Galeão', 'Aeroporto Santos Dumont');
