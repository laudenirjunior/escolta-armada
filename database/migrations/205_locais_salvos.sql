-- 205_locais_salvos.sql
-- Lote 2026-10, onda D (M2 e M1). Idempotente. Bloco 1 (antes do deploy).
--
-- Por quê (nota de 03/10, itens M2 e M1; docs/13, 2.4): os endereços recorrentes eram
-- digitados e escolhidos na busca da Mapbox a cada escolta, e a busca devolve para a
-- JAMEF uma coordenada 1.327 m longe do lugar onde o GPS dos operadores registra a
-- chegada. Locais salvos, com a coordenada conferida no mapa, viram atalhos de um toque
-- na origem e no destino.
--
-- Decisões de Peçanha (08/10/2026): quem cadastra é supervisor ou acima (decisão 5); a
-- carga inicial nasce "aguardando_conferencia" e só é ativada depois que Peçanha ou
-- Bruno conferirem o pino no mapa (decisão 6), por isso ativar exige gestor ou
-- administrador; CT do Botafogo fica fora até o Bruno informar o endereço.

CREATE TABLE IF NOT EXISTS public.locais_salvos (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome              text NOT NULL CHECK (length(trim(nome)) BETWEEN 2 AND 40),
  endereco          text NOT NULL,
  complemento       text,
  latitude          numeric(10,7) CHECK (latitude BETWEEN -90 AND 90),
  longitude         numeric(10,7) CHECK (longitude BETWEEN -180 AND 180),
  situacao          text NOT NULL DEFAULT 'aguardando_conferencia'
                      CHECK (situacao IN ('ativo', 'inativo', 'aguardando_conferencia')),
  fonte_coordenada  text,
  conferido_por     uuid REFERENCES public.usuarios(id),
  conferido_em      timestamptz,
  criado_por        uuid REFERENCES public.usuarios(id),
  criado_em         timestamptz NOT NULL DEFAULT now(),
  atualizado_por    uuid REFERENCES public.usuarios(id),
  atualizado_em     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT locais_salvos_ativo_com_coordenada CHECK (situacao <> 'ativo' OR (latitude IS NOT NULL AND longitude IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS locais_salvos_nome_unico ON public.locais_salvos (lower(trim(nome))) WHERE situacao <> 'inativo';
COMMENT ON TABLE public.locais_salvos IS 'Lote 2026-10 (M2): atalhos de endereço com coordenada conferida no mapa. Só os ativos aparecem como atalho.';

ALTER TABLE public.locais_salvos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.locais_salvos FROM anon;
REVOKE ALL ON public.locais_salvos FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON public.locais_salvos TO authenticated;
DROP POLICY IF EXISTS locais_salvos_leitura ON public.locais_salvos;
CREATE POLICY locais_salvos_leitura ON public.locais_salvos FOR SELECT TO authenticated
  USING (situacao = 'ativo'
         OR (SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']));
DROP POLICY IF EXISTS locais_salvos_cadastro ON public.locais_salvos;
CREATE POLICY locais_salvos_cadastro ON public.locais_salvos FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']));
DROP POLICY IF EXISTS locais_salvos_edicao ON public.locais_salvos;
CREATE POLICY locais_salvos_edicao ON public.locais_salvos FOR UPDATE TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']))
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']));

-- Ativar exige gestor ou administrador e registra quem conferiu; mexer na coordenada de
-- um local ativo exige nova conferência; criado_por e atualizado_por vêm da sessão.
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
DROP TRIGGER IF EXISTS tr_locais_salvos_regras ON public.locais_salvos;
CREATE TRIGGER tr_locais_salvos_regras BEFORE INSERT OR UPDATE ON public.locais_salvos
  FOR EACH ROW EXECUTE FUNCTION public.locais_salvos_regras();

-- Carga inicial (aguardando conferência). Coordenadas medidas só onde há fonte; as demais
-- ficam nulas e o pino é posto na conferência (desvio declarado da decisão 6).
INSERT INTO public.locais_salvos (nome, endereco, latitude, longitude, situacao, fonte_coordenada)
SELECT v.nome, v.endereco, v.lat, v.lng, 'aguardando_conferencia', v.fonte
FROM (VALUES
  ('JAMEF', 'Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti', -22.799521::numeric, -43.347756::numeric,
   'Média de 5 pontos de GPS de campo (precisão até 15 m) registrados na chegada à JAMEF; conferir o pino'),
  ('Sede', 'Rua Cândido Figueiredo, 204, Tanque, Rio de Janeiro', -22.918625::numeric, -43.362670::numeric,
   'Média de 11 pontos de GPS de campo (precisão até 15 m) de saída e retorno à base; conferir o pino'),
  ('Engenhão', 'Rua das Oficinas, Cachambi, Rio de Janeiro', NULL, NULL, 'Sem medida de campo nem número informado; pôr o pino na conferência'),
  ('Aeroporto do Galeão', 'Aeroporto Internacional do Rio de Janeiro (Galeão), Rio de Janeiro', NULL, NULL, 'Sem endereço informado; pôr o pino no terminal ou portão de carga usado'),
  ('Aeroporto Santos Dumont', 'Aeroporto Santos Dumont, Rio de Janeiro', NULL, NULL, 'Sem endereço informado; pôr o pino no terminal ou portão de carga usado')
) v(nome, endereco, lat, lng, fonte)
WHERE NOT EXISTS (SELECT 1 FROM public.locais_salvos l WHERE lower(trim(l.nome)) = lower(trim(v.nome)));

-- Conferência:
-- SELECT nome, situacao, latitude, longitude FROM locais_salvos ORDER BY nome;   -- 5, todos aguardando_conferencia
