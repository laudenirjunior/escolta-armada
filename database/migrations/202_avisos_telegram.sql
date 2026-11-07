-- 202_avisos_telegram.sql
-- Lote 2026-10, ondas C e F. Idempotente. Bloco 1 (antes do deploy; compatível com o código atual).
--
-- Por quê: o aviso ao Telegram saía do navegador de cada usuário logado (um por aba
-- aberta) e não havia como mandar aviso sem alguém com a tela aberta (docs/13, H10 e
-- H12). Esta migration cria uma fila no banco, com chave única por evento, e o envio
-- pelo próprio banco: pg_cron a cada minuto chama enviar_avisos_telegram(), que usa
-- pg_net com o token guardado no Vault. Cada evento vira no máximo uma mensagem: não há
-- reenvio automático depois de enviado ou de erro.
--
-- Pré-requisito para enviar (ação do Peçanha, pela tela Vault do painel do Supabase,
-- nunca pelo SQL Editor, que guarda o histórico): segredos telegram_bot_token e
-- telegram_chat_central. Sem eles, ou sem as extensões, avisos_pelo_banco_ativos() fica
-- falso, nada é enfileirado e o aplicativo continua mandando pelo /api/telegram.
--
-- Usada pela onda C (mural) e pela onda F (check-in e presença). Aplicar mesmo que uma
-- delas fique fora do pacote.

-- 1. Extensões. Se o projeto recusar a criação, a fila nasce assim mesmo e o envio
--    pelo banco fica desligado (configuracao_avisos.envio_pelo_banco = false).
--    Guarda se cada uma já existia, para a reversão não apagar o que não criou.
CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261008.extensoes_antes_202 (nome text PRIMARY KEY, existia boolean NOT NULL);
REVOKE ALL ON backup_20261008.extensoes_antes_202 FROM PUBLIC, anon, authenticated;
INSERT INTO backup_20261008.extensoes_antes_202 (nome, existia)
SELECT n, EXISTS (SELECT 1 FROM pg_extension WHERE extname = n) FROM unnest(ARRAY['pg_net', 'pg_cron']) AS n
ON CONFLICT (nome) DO NOTHING;
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
  EXCEPTION WHEN others THEN RAISE NOTICE 'pg_net indisponivel: %', SQLERRM;
  END;
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN others THEN RAISE NOTICE 'pg_cron indisponivel: %', SQLERRM;
  END;
END $$;

-- 2. Configuração (linha única). Sem policy: só o SQL Editor altera. O endereço da API
--    não pode mudar pela aplicação, senão o token iria para outro lugar.
CREATE TABLE IF NOT EXISTS public.configuracao_avisos (
  id                smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  telegram_api_base text NOT NULL DEFAULT 'https://api.telegram.org',
  envio_pelo_banco  boolean NOT NULL DEFAULT true,
  atualizado_em     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.configuracao_avisos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.configuracao_avisos FROM anon, authenticated;
INSERT INTO public.configuracao_avisos (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
UPDATE public.configuracao_avisos SET envio_pelo_banco = false
WHERE NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
   OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron');

-- 3. Fila. Sem policy: só funções SECURITY DEFINER leem e gravam.
CREATE TABLE IF NOT EXISTS public.avisos_telegram (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evento_chave      text NOT NULL UNIQUE,
  destino           text NOT NULL CHECK (destino IN ('central', 'cliente')),
  escolta_id        uuid REFERENCES public.escoltas(id) ON DELETE SET NULL,
  texto             text NOT NULL,
  origem_usuario_id uuid,
  criado_em         timestamptz NOT NULL DEFAULT now(),
  situacao          text NOT NULL DEFAULT 'pendente' CHECK (situacao IN ('pendente', 'enviando', 'enviado', 'erro')),
  enviado_em        timestamptz,
  pg_net_id         bigint,
  erro              text
);
CREATE INDEX IF NOT EXISTS avisos_telegram_situacao_idx ON public.avisos_telegram (situacao, criado_em);
ALTER TABLE public.avisos_telegram ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.avisos_telegram FROM anon, authenticated;
COMMENT ON TABLE public.avisos_telegram IS
  'Lote 2026-10: fila de avisos ao Telegram, enviada pelo banco (pg_cron + pg_net). Uma linha por evento (evento_chave única), no máximo uma mensagem.';

-- 4. Escape de HTML para textos que o banco monta (parse_mode HTML do Telegram).
CREATE OR REPLACE FUNCTION public.escapar_html(p text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;
REVOKE ALL ON FUNCTION public.escapar_html(text) FROM PUBLIC, anon, authenticated;

-- 5. As peças do envio pelo banco estão todas presentes?
CREATE OR REPLACE FUNCTION public.avisos_pelo_banco_ativos() RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v boolean;
BEGIN
  IF NOT coalesce((SELECT envio_pelo_banco FROM public.configuracao_avisos WHERE id = 1), false) THEN RETURN false; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
     OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RETURN false;
  END IF;
  EXECUTE $q$SELECT count(*) = 2 FROM vault.decrypted_secrets
             WHERE name IN ('telegram_bot_token', 'telegram_chat_central')
               AND coalesce(decrypted_secret, '') <> ''$q$ INTO v;
  IF NOT v THEN RETURN false; END IF;
  EXECUTE $q$SELECT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'lote2026_avisos_telegram' AND active)$q$ INTO v;
  RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION public.avisos_pelo_banco_ativos() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avisos_pelo_banco_ativos() TO authenticated;

-- 6. Enfileirar (interna). Só enfileira com o envio pelo banco ativo; senão devolve
--    false e quem chamou avisa pelo caminho antigo. Chave repetida não duplica.
CREATE OR REPLACE FUNCTION public._enfileirar_aviso(p_chave text, p_destino text, p_escolta_id uuid, p_texto text)
    RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF NOT public.avisos_pelo_banco_ativos() THEN RETURN false; END IF;
  INSERT INTO public.avisos_telegram (evento_chave, destino, escolta_id, texto, origem_usuario_id)
  VALUES (p_chave, p_destino, p_escolta_id, left(p_texto, 4000),
          (SELECT id FROM public.usuarios WHERE auth_user_id = auth.uid()))
  ON CONFLICT (evento_chave) DO NOTHING;
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public._enfileirar_aviso(text, text, uuid, text) FROM PUBLIC, anon, authenticated;

-- 7. Envio (interna, pelo cron). Marca 'enviando' antes de pedir ao pg_net: nunca
--    reenvia o mesmo aviso.
CREATE OR REPLACE FUNCTION public.enviar_avisos_telegram() RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  r record; v_token text; v_central text; v_base text; v_chat text; v_req bigint; n int := 0;
BEGIN
  IF NOT public.avisos_pelo_banco_ativos() THEN RETURN 0; END IF;
  EXECUTE $q$SELECT max(decrypted_secret) FILTER (WHERE name = 'telegram_bot_token'),
                    max(decrypted_secret) FILTER (WHERE name = 'telegram_chat_central')
             FROM vault.decrypted_secrets$q$ INTO v_token, v_central;
  SELECT telegram_api_base INTO v_base FROM public.configuracao_avisos WHERE id = 1;
  FOR r IN
    SELECT a.id, a.destino, a.texto, c.telegram_chat_id AS chat_cliente
    FROM public.avisos_telegram a
    LEFT JOIN public.escoltas e ON e.id = a.escolta_id
    LEFT JOIN public.clientes c ON c.id = e.cliente_id
    WHERE a.situacao = 'pendente'
    ORDER BY a.criado_em
    LIMIT 20
    FOR UPDATE OF a SKIP LOCKED
  LOOP
    v_chat := CASE WHEN r.destino = 'cliente' THEN coalesce(nullif(r.chat_cliente, ''), v_central) ELSE v_central END;
    UPDATE public.avisos_telegram SET situacao = 'enviando', enviado_em = now() WHERE id = r.id;
    EXECUTE $q$SELECT net.http_post(url := $1, body := $2, headers := '{"Content-Type": "application/json"}'::jsonb)$q$
      INTO v_req
      USING v_base || '/bot' || v_token || '/sendMessage',
            jsonb_build_object('chat_id', v_chat, 'text', r.texto, 'parse_mode', 'HTML', 'disable_web_page_preview', true);
    UPDATE public.avisos_telegram SET pg_net_id = v_req WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.enviar_avisos_telegram() FROM PUBLIC, anon, authenticated;

-- 8. Conferência das respostas (interna, pelo cron). O erro guardado nunca leva a URL,
--    que contém o token.
CREATE OR REPLACE FUNCTION public.conferir_avisos_telegram() RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE r record; v_status int; v_conteudo text; v_erro text; n int := 0;
BEGIN
  IF to_regclass('net._http_response') IS NULL THEN RETURN 0; END IF;
  FOR r IN SELECT id, pg_net_id, enviado_em FROM public.avisos_telegram WHERE situacao = 'enviando' FOR UPDATE SKIP LOCKED LOOP
    v_status := NULL; v_conteudo := NULL; v_erro := NULL;
    IF r.pg_net_id IS NOT NULL THEN
      EXECUTE $q$SELECT status_code, content::text, error_msg FROM net._http_response WHERE id = $1$q$
        INTO v_status, v_conteudo, v_erro USING r.pg_net_id;
    END IF;
    -- Resposta que não é JSON (proxy devolvendo HTML) não pode derrubar a rodada inteira.
    BEGIN
      v_conteudo := v_conteudo::jsonb ->> 'description';
    EXCEPTION WHEN others THEN
      v_conteudo := NULL;
    END;
    IF v_status = 200 THEN
      UPDATE public.avisos_telegram SET situacao = 'enviado', erro = NULL WHERE id = r.id;
      n := n + 1;
    ELSIF v_status IS NOT NULL OR v_erro IS NOT NULL THEN
      UPDATE public.avisos_telegram
         SET situacao = 'erro',
             erro = regexp_replace(left(coalesce(v_status::text, '') || ' ' ||
                      coalesce(v_conteudo, v_erro, ''), 300),
                    '/bot[^/[:space:]]+', '/bot***', 'g')
       WHERE id = r.id;
    ELSIF r.enviado_em < now() - interval '10 minutes' THEN
      UPDATE public.avisos_telegram SET situacao = 'erro', erro = 'sem resposta em 10 minutos' WHERE id = r.id;
    END IF;
  END LOOP;
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.conferir_avisos_telegram() FROM PUBLIC, anon, authenticated;

-- 9. O pg_net guarda a URL (com o token) na fila e o corpo da resposta: tenta tirar o acesso
--    de anon e authenticated ao schema net (nada do cliente usa pg_net). No Supabase o dono
--    do schema net não é o postgres e o REVOKE pode não ter efeito (aviso "no privileges
--    could be revoked"); nesse caso fica como pendência declarada: o schema net não é
--    exposto pelo PostgREST, então só uma conexão SQL direta com papel de baixo privilégio
--    leria a fila.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'net') THEN
    REVOKE USAGE ON SCHEMA net FROM anon, authenticated;
    REVOKE ALL ON ALL TABLES IN SCHEMA net FROM anon, authenticated;
  END IF;
END $$;

-- 10. Agendamento a cada minuto (só com pg_cron).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    EXECUTE $q$SELECT cron.schedule('lote2026_avisos_telegram', '* * * * *',
      'SELECT public.conferir_avisos_telegram(); SELECT public.enviar_avisos_telegram();')$q$;
  END IF;
END $$;

-- Conferência:
-- SELECT extname FROM pg_extension WHERE extname IN ('pg_cron','pg_net');
-- SELECT envio_pelo_banco FROM configuracao_avisos;
-- SELECT public.avisos_pelo_banco_ativos();   -- true só depois dos segredos no Vault
-- SELECT situacao, count(*) FROM avisos_telegram GROUP BY 1;
