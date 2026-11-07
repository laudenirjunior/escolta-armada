-- 217_mural_central_reverter.sql
-- ORDEM: primeiro o git revert do código da onda J e o deploy; depois este arquivo; a 211
-- só depois dele. Recria os corpos da 204 (_avisar_app grava direto em notificacoes, só
-- com o payload; marcar_aviso_lido faz SET lida = true) e desliga o Telegram do check-in
-- pelo cron (configuracao_avisos.checkin_telegram_pelo_cron = false).
-- Aviso no aplicativo (tabela notificacoes, canal app).
CREATE OR REPLACE FUNCTION public._avisar_app(p_escolta_id uuid, p_tipo text, p_usuarios uuid[], p_titulo text, p_texto text, p_pedido_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF NOT coalesce((SELECT aviso_ligado FROM public.configuracoes_mural WHERE id = 1), true) THEN RETURN; END IF;
  INSERT INTO public.notificacoes (escolta_id, canal, tipo_evento_id, destino, payload, usuario_dest_id, status_envio)
  SELECT p_escolta_id, 'app', (SELECT id FROM public.dom_tipos_evento WHERE codigo = p_tipo), 'app',
         jsonb_build_object('titulo', p_titulo, 'texto', p_texto, 'pedido_id', p_pedido_id), u, 'enviada'
  FROM unnest(p_usuarios) AS u
  WHERE u IS NOT NULL;
END;
$$;
REVOKE ALL ON FUNCTION public._avisar_app(uuid, text, uuid[], text, text, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.marcar_aviso_lido(p_notificacao_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  UPDATE public.notificacoes SET lida = true WHERE id = p_notificacao_id AND usuario_dest_id = public.get_meu_usuario_id();
  RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.marcar_aviso_lido(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_aviso_lido(uuid) TO authenticated;

-- O Telegram do check-in volta a ser do navegador (reservar_alertas_checkin) até a 217 voltar.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
              AND table_name = 'configuracao_avisos' AND column_name = 'checkin_telegram_pelo_cron') THEN
    UPDATE public.configuracao_avisos SET checkin_telegram_pelo_cron = false WHERE id = 1;
  END IF;
END $$;
