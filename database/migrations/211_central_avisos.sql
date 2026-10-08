-- 211_central_avisos.sql
-- Lote 2026-10, onda J (adendo 01, item 4.2). Idempotente. Bloco 1 (antes do deploy;
-- compatível com o código da master 2b3fff9, que não lê nem grava em notificacoes:
-- conferido por git grep; só as RPCs da 204, do bloco 2, gravam nela).
--
-- Por quê (docs/14, seção 11.2): a tabela notificacoes passa a ser a central de avisos de
-- cada pessoa (sino com não lidas, página Avisos, aviso de 2 segundos). Hoje ela não tem
-- data de leitura, texto nem chave de evento; a policy notificacoes_escrita é FOR ALL
-- (destinatário e gestão podiam apagar), a gestão lia a caixa de todos e o anon tinha
-- TRUNCATE (que não passa por RLS).
--
-- O que faz:
-- 1. Schema lote_interno, fora dos schemas expostos pelo PostgREST, para as funções
--    internas do adendo. Nenhuma função dele é executável por anon ou authenticated
--    (default privileges sem EXECUTE para PUBLIC e REVOKE explícito em cada função).
-- 2. Colunas lida_em, titulo, texto e evento_chave; gatilho que mantém lida e lida_em
--    em acordo nos dois sentidos (a marcar_aviso_lido da 204 faz SET lida = true e
--    continua valendo); índice único (evento_chave, usuario_dest_id): uma linha por
--    destinatário por evento.
-- 3. Tipos novos em dom_tipos_evento (check-in vencido e as ações da onda I e da L).
-- 4. lote_interno.notificar: grava o aviso, sem depender de auth.uid() (roda pelo cron).
-- 5. RPCs do app: meus_avisos, contar_avisos_nao_lidos e marcar_todos_lidos.
-- 6. RLS: cada um lê só a própria caixa (decisão S5); nenhuma escrita direta (sem
--    INSERT, UPDATE, DELETE nem TRUNCATE para anon e authenticated); toda escrita por
--    função SECURITY DEFINER.
-- Reversão: 211_central_avisos_reverter.sql (depois da 217 e da 212).

-- 1. Schema interno.
CREATE SCHEMA IF NOT EXISTS lote_interno;
REVOKE ALL ON SCHEMA lote_interno FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA lote_interno REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
COMMENT ON SCHEMA lote_interno IS
  'Lote 2026-10 (adendo 01): funções internas (cron e RPCs SECURITY DEFINER). Fora do PostgREST; nenhuma função executável por anon ou authenticated.';

-- 2. Colunas da central.
ALTER TABLE public.notificacoes
  ADD COLUMN IF NOT EXISTS lida_em      timestamptz,
  ADD COLUMN IF NOT EXISTS titulo       text,
  ADD COLUMN IF NOT EXISTS texto        text,
  ADD COLUMN IF NOT EXISTS evento_chave text;

-- Avisos já gravados pela 204 (título e texto no payload; lidos sem data de leitura).
UPDATE public.notificacoes
   SET titulo = coalesce(titulo, payload ->> 'titulo'),
       texto  = coalesce(texto, payload ->> 'texto'),
       lida_em = CASE WHEN lida AND lida_em IS NULL THEN criado_em ELSE lida_em END
 WHERE (titulo IS NULL AND payload ? 'titulo') OR (texto IS NULL AND payload ? 'texto') OR (lida AND lida_em IS NULL);

CREATE OR REPLACE FUNCTION lote_interno.sincronizar_lida() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  NEW.lida := coalesce(NEW.lida, false);
  IF TG_OP = 'INSERT' THEN
    IF NEW.lida_em IS NOT NULL THEN NEW.lida := true;
    ELSIF NEW.lida THEN NEW.lida_em := now();
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.lida_em IS DISTINCT FROM OLD.lida_em THEN
    NEW.lida := NEW.lida_em IS NOT NULL;             -- quem mexeu na data de leitura manda
  ELSIF NEW.lida IS DISTINCT FROM coalesce(OLD.lida, false) THEN
    NEW.lida_em := CASE WHEN NEW.lida THEN now() END; -- caminho da 204: SET lida = true
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.sincronizar_lida() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tr_notificacoes_sincronizar_lida ON public.notificacoes;
CREATE TRIGGER tr_notificacoes_sincronizar_lida BEFORE INSERT OR UPDATE OF lida, lida_em ON public.notificacoes
  FOR EACH ROW EXECUTE FUNCTION lote_interno.sincronizar_lida();

CREATE UNIQUE INDEX IF NOT EXISTS notificacoes_evento_destinatario_uk
  ON public.notificacoes (evento_chave, usuario_dest_id) WHERE evento_chave IS NOT NULL;
-- Caixa de cada pessoa, da mais nova para a mais antiga (lista e contador).
CREATE INDEX IF NOT EXISTS idx_notificacoes_caixa
  ON public.notificacoes (usuario_dest_id, criado_em DESC);

-- 3. Tipos novos.
INSERT INTO public.dom_tipos_evento (codigo, nome_exibicao, gera_notificacao, ativo)
SELECT v.codigo, v.nome, true, true
FROM (VALUES ('checkin_vencido', 'Check-in vencido'),
             ('edicao_escolta', 'Escolta editada pela gestão'),
             ('reset_escolta', 'Escolta reiniciada pela gestão'),
             ('conclusao_antecipada', 'Conclusão antecipada'),
             ('arquivamento_escolta', 'Escolta arquivada'),
             ('recuperacao_escolta', 'Escolta recuperada do arquivo'),
             ('conflito_offline', 'Registro offline em conflito')) v(codigo, nome)
WHERE NOT EXISTS (SELECT 1 FROM public.dom_tipos_evento d WHERE d.codigo = v.codigo);

-- 4. Gravação de aviso (interna). Uma linha por destinatário; com chave, a mesma chave
--    para a mesma pessoa não grava de novo. Devolve quantas linhas entraram.
CREATE OR REPLACE FUNCTION lote_interno.notificar(p_chave text, p_escolta_id uuid, p_tipo text, p_usuarios uuid[],
                                                  p_titulo text, p_texto text, p_extra jsonb DEFAULT NULL)
    RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_tipo uuid; v_n int;
BEGIN
  SELECT id INTO v_tipo FROM public.dom_tipos_evento WHERE codigo = p_tipo;
  IF v_tipo IS NULL THEN RAISE EXCEPTION 'Tipo de aviso desconhecido: %', p_tipo; END IF;
  IF p_escolta_id IS NULL OR p_usuarios IS NULL THEN RETURN 0; END IF;
  INSERT INTO public.notificacoes (escolta_id, canal, tipo_evento_id, destino, payload, usuario_dest_id, status_envio,
                                   titulo, texto, evento_chave)
  SELECT p_escolta_id, 'app', v_tipo, 'app',
         jsonb_build_object('titulo', p_titulo, 'texto', p_texto) || coalesce(p_extra, '{}'::jsonb),
         u, 'enviada', p_titulo, p_texto, p_chave
  FROM (SELECT DISTINCT u FROM unnest(p_usuarios) AS u WHERE u IS NOT NULL) d
  ON CONFLICT (evento_chave, usuario_dest_id) WHERE evento_chave IS NOT NULL DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.notificar(text, uuid, text, uuid[], text, text, jsonb) FROM PUBLIC, anon, authenticated;

-- 5. RPCs do app. Cada um só vê e marca os próprios avisos.
CREATE OR REPLACE FUNCTION public.meus_avisos(p_tipo text DEFAULT NULL, p_escolta_id uuid DEFAULT NULL,
                                              p_so_nao_lidas boolean DEFAULT false, p_limite integer DEFAULT 50,
                                              p_antes timestamptz DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_eu uuid; v jsonb;
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_eu := public.get_meu_usuario_id();
  SELECT coalesce(jsonb_agg(x.j ORDER BY x.criado_em DESC, x.id DESC), '[]'::jsonb) INTO v
  FROM (
    SELECT n.id, n.criado_em,
           jsonb_build_object('id', n.id, 'escolta_id', n.escolta_id, 'codigo', e.codigo_escolta,
                              'tipo', t.codigo, 'tipo_nome', t.nome_exibicao,
                              'titulo', coalesce(n.titulo, n.payload ->> 'titulo', t.nome_exibicao),
                              'texto', coalesce(n.texto, n.payload ->> 'texto'),
                              'criado_em', n.criado_em, 'lida_em', n.lida_em) AS j
    FROM public.notificacoes n
    JOIN public.dom_tipos_evento t ON t.id = n.tipo_evento_id
    LEFT JOIN public.escoltas e ON e.id = n.escolta_id
    WHERE n.usuario_dest_id = v_eu AND n.canal = 'app'
      AND (p_tipo IS NULL OR t.codigo = p_tipo)
      AND (p_escolta_id IS NULL OR n.escolta_id = p_escolta_id)
      AND (NOT coalesce(p_so_nao_lidas, false) OR n.lida IS NOT TRUE)
      AND (p_antes IS NULL OR n.criado_em < p_antes)
    ORDER BY n.criado_em DESC, n.id DESC
    LIMIT least(greatest(coalesce(p_limite, 50), 1), 200)
  ) x;
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.contar_avisos_nao_lidos() RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  RETURN (SELECT count(*) FROM public.notificacoes
          WHERE usuario_dest_id = public.get_meu_usuario_id() AND canal = 'app' AND lida IS NOT TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.marcar_todos_lidos(p_tipo text DEFAULT NULL) RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n int;
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  UPDATE public.notificacoes n SET lida_em = now()
   WHERE n.usuario_dest_id = public.get_meu_usuario_id() AND n.canal = 'app' AND n.lida IS NOT TRUE
     AND (p_tipo IS NULL OR n.tipo_evento_id = (SELECT id FROM public.dom_tipos_evento WHERE codigo = p_tipo));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['meus_avisos(text, uuid, boolean, integer, timestamptz)', 'contar_avisos_nao_lidos()',
                           'marcar_todos_lidos(text)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- 6. RLS e privilégios: leitura só da própria caixa; nenhuma escrita direta.
DROP POLICY IF EXISTS notificacoes_escrita ON public.notificacoes;
DROP POLICY IF EXISTS notificacoes_insert_so_gestao ON public.notificacoes;   -- 197, fica sem objeto
DROP POLICY IF EXISTS notificacoes_update_restrita ON public.notificacoes;    -- 197, fica sem objeto
DROP POLICY IF EXISTS notificacoes_select ON public.notificacoes;
CREATE POLICY notificacoes_select ON public.notificacoes FOR SELECT TO authenticated
  USING (usuario_dest_id = (SELECT public.get_meu_usuario_id()));
REVOKE ALL ON public.notificacoes FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.notificacoes FROM authenticated;

-- Conferência:
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'notificacoes'
--   AND column_name IN ('lida_em','titulo','texto','evento_chave');                         -- 4
-- SELECT polname FROM pg_policy WHERE polrelid = 'public.notificacoes'::regclass;            -- notificacoes_select
-- SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lote_interno'
--   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE')); -- 0
-- SELECT has_table_privilege('anon', 'public.notificacoes', 'SELECT'),
--        has_table_privilege('authenticated', 'public.notificacoes', 'DELETE');               -- false, false
