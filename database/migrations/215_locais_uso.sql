-- 215_locais_uso.sql
-- Lote 2026-10, onda D2 (acréscimos da onda D, item 4.6 do adendo 01; docs/14, seção 14).
-- Idempotente. Bloco 1, depois da 214. Compatível com a master 2b3fff9: a master não lê nem
-- grava locais_salvos; as triggers novas só leem escoltas, só escrevem em locais_salvos e
-- nunca recusam nada (erro interno vira aviso no log e linha em lote_interno.locais_uso_falhas).
--
-- Por quê:
-- 1. Ordenação dos atalhos pelos mais usados: locais_salvos.vezes_usado é o número de vezes
--    que o local é origem ou destino de uma escolta NÃO cancelada (cada lado conta uma vez),
--    calculado a partir das escoltas, nunca somado às cegas. Assim "Usado N vezes" na tela de
--    locais é o número real: ida e volta de uma edição não infla, cancelar desconta,
--    descancelar volta a contar.
--    - Trigger AFTER INSERT OR DELETE OR UPDATE OF origem_endereco, destino_endereco,
--      origem_lat, origem_lng, destino_lat, destino_lng, status em escoltas: quando o lado
--      mudou de fato (IS DISTINCT FROM) ou a escolta entrou ou saiu de 'cancelada', recalcula
--      o local antigo e o novo daquele lado. Mudança de status entre não canceladas, KM, UF
--      (onda K) e as cargas não mexem em nada.
--    - Trigger por comando em locais_salvos (INSERT, DELETE e UPDATE de nome, endereço,
--      complemento, coordenada ou situação): recalcula todos os locais, porque um local novo
--      ou mudado pode passar a ser o local de escoltas que já existem.
-- 2. Qual local corresponde a um endereço gravado (lote_interno.local_do_endereco): a Nova
--    grava o complemento no texto (enderecoComComplemento: "endereço, complemento"). Vence,
--    nesta ordem: o texto completo igual a "endereço, complemento" do local (ou só o endereço,
--    para local sem complemento); o texto que começa pelo endereço do local; a coordenada mais
--    próxima até 100 m; o local sem complemento; o nome. Com "JAMEF" e "JAMEF Doca 9" no
--    mesmo endereço, "..., Doca 9" conta para a doca, o endereço sem complemento conta para a
--    JAMEF e um complemento que nenhum dos dois tem conta para a JAMEF. Inativo não conta.
-- 3. UF do local (para o atalho preencher a UF da escolta quando a onda K existir):
--    locais_salvos.uf, CHECK de duas letras maiúsculas; os 5 locais da carga da 205 são RJ.
-- 4. Nenhum perfil altera vezes_usado pela API: INSERT e UPDATE de authenticated passam a ser
--    por coluna, sem vezes_usado (o operador já não tinha UPDATE em locais_salvos, 205). Só as
--    funções internas (SECURITY DEFINER, sem GRANT) gravam.
-- 5. locais_salvos_regras (205) ignora o UPDATE que só muda vezes_usado (senão o uso de um
--    local pela escolta de um operador gravaria o operador em atualizado_por) e passa a
--    devolver para conferência o local ativo cuja UF mudou (a UF é parte do que a
--    conferência atesta, como o nome, o texto, o complemento e o pino).
-- 6. Falha da contagem: as triggers rodam com lock_timeout de 500 ms (espera pela linha do
--    local vira erro capturado, nunca o statement_timeout de 8 s do PostgREST derrubando a
--    escolta); o erro vira WARNING e uma linha em lote_interno.locais_uso_falhas (sem GRANT;
--    gestor e administrador veem o total na tela de locais pela locais_uso_falhas_resumo()).
-- 7. Carga do uso a partir das escoltas existentes: só LÊ escoltas (UPDATE só em
--    locais_salvos). ESC-2026-0001 e ESC-2026-0007 não mudam. Recalcula tudo, então
--    reaplicar dá o mesmo número.
--
-- Conferência:
-- SELECT nome, uf, vezes_usado, situacao FROM locais_salvos ORDER BY vezes_usado DESC, nome;  -- 5 com uf RJ
-- SELECT count(*) FROM pg_trigger WHERE tgname IN ('tr_contar_uso_local', 'tr_recontar_uso_locais');  -- 2
-- SELECT has_column_privilege('authenticated', 'public.locais_salvos', 'vezes_usado', 'UPDATE');  -- false
-- SELECT count(*) FROM lote_interno.locais_uso_falhas;                                          -- 0
-- Reversão: 215_locais_uso_reverter.sql (guarda vezes_usado e uf em backup_20261008.locais_uso).

CREATE SCHEMA IF NOT EXISTS lote_interno;
REVOKE ALL ON SCHEMA lote_interno FROM PUBLIC, anon, authenticated;

-- A. Qual local salvo (não inativo) corresponde a um endereço gravado. Interna, sem GRANT.
CREATE OR REPLACE FUNCTION lote_interno.local_do_endereco(p_endereco text, p_lat numeric, p_lng numeric)
    RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  WITH c AS (
    SELECT l.id, l.nome,
           coalesce(trim(l.complemento), '') = '' AS sem_complemento,
           (p_endereco IS NOT NULL AND trim(l.endereco) <> ''
            AND lower(trim(p_endereco)) = lower(trim(l.endereco)
                  || CASE WHEN coalesce(trim(l.complemento), '') <> '' THEN ', ' || trim(l.complemento) ELSE '' END)) AS pelo_texto_completo,
           (p_endereco IS NOT NULL AND trim(l.endereco) <> ''
            AND (lower(trim(p_endereco)) = lower(trim(l.endereco))
                 OR left(lower(trim(p_endereco)), length(trim(l.endereco)) + 2) = lower(trim(l.endereco)) || ', ')) AS pelo_endereco,
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
   WHERE pelo_texto_completo OR pelo_endereco OR metros <= 100
   ORDER BY pelo_texto_completo DESC, pelo_endereco DESC, metros NULLS LAST, sem_complemento DESC, nome
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION lote_interno.local_do_endereco(text, numeric, numeric) FROM PUBLIC, anon, authenticated;

-- B. Quantas vezes um local é origem ou destino de escolta não cancelada. Só os lados que
-- podem bater com o local (texto começando pelo endereço ou coordenada numa caixa de ~110 m)
-- passam pela local_do_endereco, que decide o empate entre locais.
CREATE OR REPLACE FUNCTION lote_interno.contar_escoltas_do_local(p_local uuid) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  WITH l AS (
    SELECT lower(trim(endereco)) AS ender, latitude AS lat, longitude AS lng
      FROM public.locais_salvos WHERE id = p_local AND situacao <> 'inativo'
  ), lados AS (
    SELECT e.origem_endereco AS ender, e.origem_lat AS lat, e.origem_lng AS lng FROM public.escoltas e WHERE e.status <> 'cancelada'
    UNION ALL
    SELECT e.destino_endereco, e.destino_lat, e.destino_lng FROM public.escoltas e WHERE e.status <> 'cancelada'
  )
  SELECT count(*)::integer FROM lados s, l
   WHERE ((l.ender <> '' AND (lower(trim(s.ender)) = l.ender OR left(lower(trim(s.ender)), length(l.ender) + 2) = l.ender || ', '))
          OR (l.lat IS NOT NULL AND l.lng IS NOT NULL AND s.lat IS NOT NULL AND s.lng IS NOT NULL
              AND abs(s.lat - l.lat) <= 0.001 AND abs(s.lng - l.lng) <= 0.001 / cos(radians(l.lat::float8))))
     AND lote_interno.local_do_endereco(s.ender, s.lat, s.lng) = p_local
$$;
REVOKE ALL ON FUNCTION lote_interno.contar_escoltas_do_local(uuid) FROM PUBLIC, anon, authenticated;

-- C. Colunas novas.
DO $$
BEGIN
  ALTER TABLE public.locais_salvos ADD COLUMN IF NOT EXISTS vezes_usado integer NOT NULL DEFAULT 0;
  ALTER TABLE public.locais_salvos ADD COLUMN IF NOT EXISTS uf text;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'locais_salvos_uf_formato') THEN
    ALTER TABLE public.locais_salvos ADD CONSTRAINT locais_salvos_uf_formato CHECK (uf ~ '^[A-Z]{2}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'locais_salvos_vezes_usado_positivo') THEN
    ALTER TABLE public.locais_salvos ADD CONSTRAINT locais_salvos_vezes_usado_positivo CHECK (vezes_usado >= 0);
  END IF;
END $$;
COMMENT ON COLUMN public.locais_salvos.vezes_usado IS 'Lote 2026-10 (D2): quantas vezes o local é origem ou destino de escolta não cancelada (cada lado conta uma vez). Recalculado pelas triggers tr_contar_uso_local e tr_recontar_uso_locais; ordena os atalhos.';
COMMENT ON COLUMN public.locais_salvos.uf IS 'Lote 2026-10 (D2): UF do local; o atalho preenche a UF da escolta (onda K).';

-- D. Carga (e recálculo) do uso de todos os locais a partir das escoltas: só leitura de
-- escoltas. Local sem escolta (ou inativo) fica com 0. Devolve quantos locais mudaram.
CREATE OR REPLACE FUNCTION lote_interno.carregar_uso_locais() RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n integer;
BEGIN
  -- Trava os locais (sempre na ordem do id, como a trigger das escoltas) antes de contar,
  -- para a contagem ver as escoltas gravadas por quem segurava a linha.
  PERFORM 1 FROM public.locais_salvos ORDER BY id FOR UPDATE;
  WITH usos AS (
    SELECT lote_interno.local_do_endereco(e.origem_endereco, e.origem_lat, e.origem_lng) AS local_id FROM public.escoltas e WHERE e.status <> 'cancelada'
    UNION ALL
    SELECT lote_interno.local_do_endereco(e.destino_endereco, e.destino_lat, e.destino_lng) FROM public.escoltas e WHERE e.status <> 'cancelada'
  ), contagem AS (
    SELECT local_id, count(*)::integer AS n FROM usos WHERE local_id IS NOT NULL GROUP BY local_id
  ), novo AS (
    SELECT l.id, coalesce(c.n, 0) AS n FROM public.locais_salvos l LEFT JOIN contagem c ON c.local_id = l.id
  )
  UPDATE public.locais_salvos l SET vezes_usado = novo.n
    FROM novo WHERE novo.id = l.id AND l.vezes_usado IS DISTINCT FROM novo.n;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.carregar_uso_locais() FROM PUBLIC, anon, authenticated;

-- E. Privilégios por coluna: ninguém grava vezes_usado pela API (as policies da 205 continuam).
REVOKE INSERT, UPDATE ON public.locais_salvos FROM authenticated;
GRANT INSERT (nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, uf) ON public.locais_salvos TO authenticated;
GRANT UPDATE (nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, uf) ON public.locais_salvos TO authenticated;

-- F. Regras do local (205) com o UPDATE só de vezes_usado ignorado e a UF na reconferência.
CREATE OR REPLACE FUNCTION public.locais_salvos_regras() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; v_eu uuid;
BEGIN
  -- Uso recalculado pelas triggers da 215: não é edição do local.
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

-- G. Registro das falhas da contagem (sem GRANT; leitura só pelo resumo abaixo).
CREATE TABLE IF NOT EXISTS lote_interno.locais_uso_falhas (
  id bigserial PRIMARY KEY,
  quando timestamptz NOT NULL DEFAULT now(),
  origem text NOT NULL,              -- 'escoltas' (trigger por linha) ou 'locais_salvos' (por comando)
  escolta_id uuid,
  erro text,
  codigo text
);
ALTER TABLE lote_interno.locais_uso_falhas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON lote_interno.locais_uso_falhas FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE lote_interno.locais_uso_falhas_id_seq FROM PUBLIC, anon, authenticated;

-- Resumo para a tela de locais (gestor e administrador): total de falhas e a última.
CREATE OR REPLACE FUNCTION public.locais_uso_falhas_resumo()
    RETURNS TABLE (total integer, ultima text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF auth.uid() IS NULL OR coalesce(public.get_meu_perfil(), '') NOT IN ('administrador', 'gestor') THEN
    RAISE EXCEPTION 'Sem permissão para ver as falhas da contagem de uso.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT count(*)::integer, to_char(max(f.quando) AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
      FROM lote_interno.locais_uso_falhas f;
END;
$$;
REVOKE ALL ON FUNCTION public.locais_uso_falhas_resumo() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.locais_uso_falhas_resumo() TO authenticated;

-- H. Trigger das escoltas: recalcula o local antigo e o novo do lado que mudou (ou dos dois
-- lados, quando a escolta entra ou sai de 'cancelada'). Nunca recusa a gravação da escolta.
CREATE OR REPLACE FUNCTION lote_interno.contar_uso_local() RETURNS trigger
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    SET lock_timeout TO '500ms'
    AS $$
DECLARE v_ids uuid[] := ARRAY[]::uuid[]; v_id uuid; v_n integer; v_cancelada_mudou boolean;
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' THEN
      v_ids := ARRAY[lote_interno.local_do_endereco(NEW.origem_endereco, NEW.origem_lat, NEW.origem_lng),
                     lote_interno.local_do_endereco(NEW.destino_endereco, NEW.destino_lat, NEW.destino_lng)];
    ELSIF TG_OP = 'DELETE' THEN
      v_ids := ARRAY[lote_interno.local_do_endereco(OLD.origem_endereco, OLD.origem_lat, OLD.origem_lng),
                     lote_interno.local_do_endereco(OLD.destino_endereco, OLD.destino_lat, OLD.destino_lng)];
    ELSE
      v_cancelada_mudou := (OLD.status = 'cancelada') IS DISTINCT FROM (NEW.status = 'cancelada');
      IF v_cancelada_mudou OR NEW.origem_endereco IS DISTINCT FROM OLD.origem_endereco
         OR NEW.origem_lat IS DISTINCT FROM OLD.origem_lat OR NEW.origem_lng IS DISTINCT FROM OLD.origem_lng THEN
        v_ids := v_ids || lote_interno.local_do_endereco(NEW.origem_endereco, NEW.origem_lat, NEW.origem_lng)
                       || lote_interno.local_do_endereco(OLD.origem_endereco, OLD.origem_lat, OLD.origem_lng);
      END IF;
      IF v_cancelada_mudou OR NEW.destino_endereco IS DISTINCT FROM OLD.destino_endereco
         OR NEW.destino_lat IS DISTINCT FROM OLD.destino_lat OR NEW.destino_lng IS DISTINCT FROM OLD.destino_lng THEN
        v_ids := v_ids || lote_interno.local_do_endereco(NEW.destino_endereco, NEW.destino_lat, NEW.destino_lng)
                       || lote_interno.local_do_endereco(OLD.destino_endereco, OLD.destino_lat, OLD.destino_lng);
      END IF;
    END IF;
    SELECT array_agg(DISTINCT x ORDER BY x) INTO v_ids FROM unnest(v_ids) x WHERE x IS NOT NULL;
    IF v_ids IS NOT NULL THEN
      -- Trava os locais na ordem do id (duas escoltas com origem e destino cruzados não
      -- entram em impasse) e só depois conta, para ver o que quem segurava a linha gravou.
      PERFORM 1 FROM public.locais_salvos WHERE id = ANY (v_ids) ORDER BY id FOR UPDATE;
      FOREACH v_id IN ARRAY v_ids LOOP
        v_n := lote_interno.contar_escoltas_do_local(v_id);
        UPDATE public.locais_salvos SET vezes_usado = v_n WHERE id = v_id AND vezes_usado IS DISTINCT FROM v_n;
      END LOOP;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'contar_uso_local: % (%)', SQLERRM, SQLSTATE;
    BEGIN
      INSERT INTO lote_interno.locais_uso_falhas (origem, escolta_id, erro, codigo)
      VALUES ('escoltas', CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END, SQLERRM, SQLSTATE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.contar_uso_local() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_contar_uso_local ON public.escoltas;
CREATE TRIGGER tr_contar_uso_local
  AFTER INSERT OR DELETE OR UPDATE OF origem_endereco, destino_endereco, origem_lat, origem_lng, destino_lat, destino_lng, status
  ON public.escoltas FOR EACH ROW EXECUTE FUNCTION lote_interno.contar_uso_local();

-- I. Trigger por comando em locais_salvos: local novo, apagado ou com nome, texto, pino ou
-- situação mudados recalcula todos (o UPDATE só de vezes_usado não a dispara). Nunca recusa.
CREATE OR REPLACE FUNCTION lote_interno.recontar_uso_locais() RETURNS trigger
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    SET lock_timeout TO '500ms'
    AS $$
BEGIN
  BEGIN
    PERFORM lote_interno.carregar_uso_locais();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'recontar_uso_locais: % (%)', SQLERRM, SQLSTATE;
    BEGIN
      INSERT INTO lote_interno.locais_uso_falhas (origem, erro, codigo) VALUES ('locais_salvos', SQLERRM, SQLSTATE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.recontar_uso_locais() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_recontar_uso_locais ON public.locais_salvos;
CREATE TRIGGER tr_recontar_uso_locais
  AFTER INSERT OR DELETE OR UPDATE OF nome, endereco, complemento, latitude, longitude, situacao
  ON public.locais_salvos FOR EACH STATEMENT EXECUTE FUNCTION lote_interno.recontar_uso_locais();

-- J. UF dos 5 locais da carga da 205 (todos no Rio de Janeiro).
UPDATE public.locais_salvos SET uf = 'RJ'
 WHERE uf IS NULL AND nome IN ('JAMEF', 'Sede', 'Engenhão', 'Aeroporto do Galeão', 'Aeroporto Santos Dumont');

-- K. Carga do uso a partir das escoltas existentes (só leitura de escoltas).
SELECT lote_interno.carregar_uso_locais();
