-- 211_central_avisos_reverter.sql
-- ORDEM: primeiro o git revert do código da onda J e o deploy; depois 217_reverter (bloco 2)
-- e 212_reverter; só então este arquivo. Aborta se a 212 ou a 217 ainda estiverem aplicadas
-- (elas chamam lote_interno.notificar).
-- Guarda as colunas novas em backup_20261008.notificacoes_central (e as linhas inteiras dos
-- tipos novos, que somem com os tipos), devolve as policies e os grants da 195 e recria as
-- restritivas da 197 (para o M3 não reabrir).
DO $$
BEGIN
  IF to_regprocedure('lote_interno.gerar_avisos_checkin(timestamptz)') IS NOT NULL THEN
    RAISE EXCEPTION 'Reverta a 212 antes da 211: o cron do check-in usa lote_interno.notificar.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname = '_avisar_app' AND p.prosrc LIKE '%lote_interno.notificar%') THEN
    RAISE EXCEPTION 'Reverta a 217 antes da 211: _avisar_app chama lote_interno.notificar.';
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261008.notificacoes_central (
  id           uuid PRIMARY KEY,
  lida_em      timestamptz,
  titulo       text,
  texto        text,
  evento_chave text,
  linha        jsonb,          -- linha inteira, só para os tipos novos (apagados abaixo)
  gravado_em   timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON backup_20261008.notificacoes_central FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'notificacoes' AND column_name = 'evento_chave') THEN
    EXECUTE $q$
      INSERT INTO backup_20261008.notificacoes_central (id, lida_em, titulo, texto, evento_chave, linha)
      SELECT n.id, n.lida_em, n.titulo, n.texto, n.evento_chave,
             CASE WHEN t.codigo IN ('checkin_vencido', 'edicao_escolta', 'reset_escolta', 'conclusao_antecipada',
                                    'arquivamento_escolta', 'recuperacao_escolta', 'conflito_offline')
                  THEN to_jsonb(n) END
      FROM public.notificacoes n JOIN public.dom_tipos_evento t ON t.id = n.tipo_evento_id
      WHERE n.lida_em IS NOT NULL OR n.titulo IS NOT NULL OR n.texto IS NOT NULL OR n.evento_chave IS NOT NULL
      ON CONFLICT (id) DO UPDATE SET lida_em = EXCLUDED.lida_em, titulo = EXCLUDED.titulo, texto = EXCLUDED.texto,
        evento_chave = EXCLUDED.evento_chave, linha = EXCLUDED.linha, gravado_em = now()$q$;
  END IF;
END $$;

DELETE FROM public.notificacoes WHERE tipo_evento_id IN
  (SELECT id FROM public.dom_tipos_evento WHERE codigo IN ('checkin_vencido', 'edicao_escolta', 'reset_escolta',
     'conclusao_antecipada', 'arquivamento_escolta', 'recuperacao_escolta', 'conflito_offline'));
DELETE FROM public.dom_tipos_evento WHERE codigo IN ('checkin_vencido', 'edicao_escolta', 'reset_escolta',
  'conclusao_antecipada', 'arquivamento_escolta', 'recuperacao_escolta', 'conflito_offline');

DROP FUNCTION IF EXISTS public.meus_avisos(text, uuid, boolean, integer, timestamptz, uuid);
DROP FUNCTION IF EXISTS public.meus_avisos(text, uuid, boolean, integer, timestamptz);
DROP FUNCTION IF EXISTS public.contar_avisos_nao_lidos();
DROP FUNCTION IF EXISTS public.marcar_todos_lidos(text, uuid);
DROP FUNCTION IF EXISTS public.marcar_todos_lidos(text);

DROP TRIGGER IF EXISTS tr_notificacoes_sincronizar_lida ON public.notificacoes;
DROP INDEX IF EXISTS public.notificacoes_evento_destinatario_uk;
DROP INDEX IF EXISTS public.idx_notificacoes_caixa;
ALTER TABLE public.notificacoes
  DROP COLUMN IF EXISTS lida_em,
  DROP COLUMN IF EXISTS titulo,
  DROP COLUMN IF EXISTS texto,
  DROP COLUMN IF EXISTS evento_chave;

-- Policies da 195 e restritivas da 197.
DROP POLICY IF EXISTS notificacoes_select ON public.notificacoes;
CREATE POLICY notificacoes_select ON public.notificacoes FOR SELECT TO authenticated USING (((usuario_dest_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)) OR (( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text]))));
DROP POLICY IF EXISTS notificacoes_escrita ON public.notificacoes;
CREATE POLICY notificacoes_escrita ON public.notificacoes TO authenticated USING (((usuario_dest_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)) OR (( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])))) WITH CHECK (true);
DROP POLICY IF EXISTS notificacoes_insert_so_gestao ON public.notificacoes;
CREATE POLICY notificacoes_insert_so_gestao ON public.notificacoes AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central']));
DROP POLICY IF EXISTS notificacoes_update_restrita ON public.notificacoes;
CREATE POLICY notificacoes_update_restrita ON public.notificacoes AS RESTRICTIVE FOR UPDATE TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central'])
         OR usuario_dest_id = (SELECT public.get_meu_usuario_id()))
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central'])
         OR usuario_dest_id = (SELECT public.get_meu_usuario_id()));
GRANT ALL ON public.notificacoes TO anon;
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON public.notificacoes TO authenticated;

-- Schema interno: só cai vazio (as ondas I e L também criam funções nele e revertem antes).
DROP FUNCTION IF EXISTS lote_interno.notificar(text, uuid, text, uuid[], text, text, jsonb);
DROP FUNCTION IF EXISTS lote_interno.sincronizar_lida();
DO $$
BEGIN
  IF to_regnamespace('lote_interno') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'lote_interno'::regnamespace)
     AND NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = 'lote_interno'::regnamespace) THEN
    ALTER DEFAULT PRIVILEGES IN SCHEMA lote_interno GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
    DROP SCHEMA lote_interno;
  END IF;
END $$;
