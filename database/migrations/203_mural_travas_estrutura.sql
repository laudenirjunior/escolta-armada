-- 203_mural_travas_estrutura.sql
-- Lote 2026-10, onda C (M5, travas do mural). Idempotente. Bloco 1 (antes do deploy):
-- só cria estrutura; as RPCs antigas continuam valendo até a 204 (bloco 2).
--
-- Por quê (docs/13, H9): desde 20/08 qualquer operador substitui a equipe escalada a
-- qualquer momento antes do início, com motivo de 5 caracteres. Decisões de Peçanha de
-- 08/10/2026: travas T1 a T7, janela de 60 min, aprovação com tempo limite de 15 min,
-- intervalo de 6 h entre escoltas do mesmo comandante.

-- 1. Parâmetros (linha única), editáveis por gestor e administrador. A auditoria não é
--    parâmetro: é sempre gravada.
CREATE TABLE IF NOT EXISTS public.configuracoes_mural (
  id                          smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  janela_substituicao_min     integer NOT NULL DEFAULT 60 CHECK (janela_substituicao_min BETWEEN 0 AND 1440),
  aprovacao_tempo_limite_min  integer NOT NULL DEFAULT 15 CHECK (aprovacao_tempo_limite_min BETWEEN 1 AND 240),
  intervalo_comandante_h      integer NOT NULL DEFAULT 6 CHECK (intervalo_comandante_h BETWEEN 0 AND 48),
  presenca_ligada             boolean NOT NULL DEFAULT true,
  aviso_ligado                boolean NOT NULL DEFAULT true,
  atualizado_por              uuid REFERENCES public.usuarios(id),
  atualizado_em               timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.configuracoes_mural (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.configuracoes_mural ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.configuracoes_mural FROM anon;
REVOKE INSERT, DELETE, TRUNCATE ON public.configuracoes_mural FROM authenticated;
GRANT SELECT, UPDATE ON public.configuracoes_mural TO authenticated;
DROP POLICY IF EXISTS configuracoes_mural_leitura ON public.configuracoes_mural;
CREATE POLICY configuracoes_mural_leitura ON public.configuracoes_mural FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS configuracoes_mural_edicao ON public.configuracoes_mural;
CREATE POLICY configuracoes_mural_edicao ON public.configuracoes_mural FOR UPDATE TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor']))
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor']));
COMMENT ON TABLE public.configuracoes_mural IS 'Lote 2026-10 (M5): parâmetros das travas do mural, lidos pelas RPCs no servidor.';

-- 2. T6: escala fixa. Some do mural para operadores; só supervisor ou acima muda.
--    Trava própria (não depende da 197 da onda A): central e operador não alteram.
ALTER TABLE public.escoltas ADD COLUMN IF NOT EXISTS escala_fixa boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION public.proteger_escala_fixa() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;      -- SQL Editor e migrations
  IF TG_OP = 'UPDATE' AND NEW.escala_fixa IS NOT DISTINCT FROM OLD.escala_fixa THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' AND NOT NEW.escala_fixa THEN RETURN NEW; END IF;
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Somente supervisor ou acima marca ou desmarca escala fixa.';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.proteger_escala_fixa() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_proteger_escala_fixa ON public.escoltas;
CREATE TRIGGER tr_proteger_escala_fixa BEFORE INSERT OR UPDATE ON public.escoltas
  FOR EACH ROW EXECUTE FUNCTION public.proteger_escala_fixa();
COMMENT ON COLUMN public.escoltas.escala_fixa IS 'Lote 2026-10 (T6): equipe definida pela gestão; não aparece no mural e não é substituída pelo operador.';

-- 3. T2: presença na base confirmada pela equipe escalada.
CREATE TABLE IF NOT EXISTS public.mural_presencas (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id       uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  vigilante_id     uuid NOT NULL REFERENCES public.vigilantes(id),
  usuario_id       uuid NOT NULL REFERENCES public.usuarios(id),
  confirmado_em    timestamptz NOT NULL DEFAULT now(),
  latitude         numeric(10,7),
  longitude        numeric(10,7),
  precisao_metros  numeric(8,2),
  sem_gps          boolean NOT NULL DEFAULT false,
  UNIQUE (escolta_id, vigilante_id)
);
ALTER TABLE public.mural_presencas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mural_presencas FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.mural_presencas FROM authenticated;
GRANT SELECT ON public.mural_presencas TO authenticated;
DROP POLICY IF EXISTS mural_presencas_leitura ON public.mural_presencas;
CREATE POLICY mural_presencas_leitura ON public.mural_presencas FOR SELECT TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor', 'central'])
         OR public.sou_do_efetivo(escolta_id));

-- 4. T3 e T7: pedidos de substituição (e o histórico deles).
CREATE TABLE IF NOT EXISTS public.mural_pedidos (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id                uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  solicitante_usuario_id    uuid NOT NULL REFERENCES public.usuarios(id),
  solicitante_vigilante_id  uuid NOT NULL REFERENCES public.vigilantes(id),
  acompanhantes             uuid[] NOT NULL DEFAULT '{}',
  veiculo_id                uuid REFERENCES public.veiculos(id),
  motivo                    text NOT NULL CHECK (length(trim(motivo)) BETWEEN 20 AND 500),
  equipe_antes              jsonb NOT NULL DEFAULT '[]',
  status                    text NOT NULL DEFAULT 'pendente'
                              CHECK (status IN ('pendente', 'aprovado', 'recusado', 'liberado_por_tempo', 'cancelado', 'invalidado')),
  criado_em                 timestamptz NOT NULL DEFAULT now(),
  expira_em                 timestamptz NOT NULL,
  antecedencia_min          integer,
  decidido_por              uuid REFERENCES public.usuarios(id),
  decidido_em               timestamptz,
  observacao_decisao        text
);
CREATE UNIQUE INDEX IF NOT EXISTS mural_pedidos_um_pendente ON public.mural_pedidos (escolta_id) WHERE status = 'pendente';
CREATE INDEX IF NOT EXISTS mural_pedidos_criado_idx ON public.mural_pedidos (criado_em DESC);
ALTER TABLE public.mural_pedidos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mural_pedidos FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.mural_pedidos FROM authenticated;
GRANT SELECT ON public.mural_pedidos TO authenticated;
DROP POLICY IF EXISTS mural_pedidos_leitura ON public.mural_pedidos;
CREATE POLICY mural_pedidos_leitura ON public.mural_pedidos FOR SELECT TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor'])
         OR solicitante_usuario_id = (SELECT public.get_meu_usuario_id()));
COMMENT ON TABLE public.mural_pedidos IS 'Lote 2026-10 (T3, T7): pedidos de substituição de equipe; só as RPCs do mural gravam.';

-- 5. Tipos de evento dos avisos do mural no aplicativo (tabela notificacoes).
INSERT INTO public.dom_tipos_evento (codigo, nome_exibicao, gera_notificacao, ativo)
SELECT v.codigo, v.nome, true, true
FROM (VALUES ('pedido_substituicao', 'Pedido de substituição de equipe'),
             ('decisao_substituicao', 'Decisão sobre pedido de substituição'),
             ('substituicao_equipe', 'Substituição de equipe')) v(codigo, nome)
WHERE NOT EXISTS (SELECT 1 FROM public.dom_tipos_evento d WHERE d.codigo = v.codigo);

-- Conferência:
-- SELECT * FROM configuracoes_mural;                                   -- 60, 15, 6
-- SELECT count(*) FROM escoltas WHERE escala_fixa;                     -- 0
-- SELECT codigo FROM dom_tipos_evento WHERE codigo LIKE '%substituicao%';  -- 3
