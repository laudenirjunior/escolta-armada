-- 217_mural_central.sql
-- Lote 2026-10, onda J (ajuste da onda C). Idempotente. Bloco 2, depois da 204 (recria
-- funções dela), da 211 (usa lote_interno.notificar e as colunas da central) e da 212
-- (liga a coluna checkin_telegram_pelo_cron).
--
-- Por quê (docs/14, seções 11.3a e 17): os avisos do mural (pedido, decisão e
-- substituição) passam a cair na central de avisos e no sino, gravados uma vez por
-- destinatário e por evento, com título e texto nas colunas da central.
-- 1. _avisar_app chama lote_interno.notificar, com chave <tipo>:<pedido_id> (sem pedido,
--    sem chave, como antes) e o pedido_id no payload; aviso_ligado continua valendo.
-- 2. marcar_aviso_lido grava lida_em (o gatilho da 211 acerta lida); o nome do parâmetro
--    não muda (avisos-mural.tsx e a central chamam por ele).
-- 3. devolver_escolta: a auditoria pedida pela onda G ('devolveu_escolta_ao_mural', por
--    _auditar_mural) já está no corpo da 204 desta branch; nada a mudar aqui.
-- 4. Liga configuracao_avisos.checkin_telegram_pelo_cron (coluna da 212): a partir daqui,
--    com o envio pelo banco ativo, o Telegram do check-in vencido sai pelo cron. Antes
--    (bloco 1, master no ar), o navegador da master mandava, e o cron não podia mandar junto.
-- Reversão: 217_mural_central_reverter.sql recria os corpos da 204 e desliga a coluna.

CREATE OR REPLACE FUNCTION public._avisar_app(p_escolta_id uuid, p_tipo text, p_usuarios uuid[], p_titulo text, p_texto text, p_pedido_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF NOT coalesce((SELECT aviso_ligado FROM public.configuracoes_mural WHERE id = 1), true) THEN RETURN; END IF;
  PERFORM lote_interno.notificar(CASE WHEN p_pedido_id IS NOT NULL THEN p_tipo || ':' || p_pedido_id END,
                                 p_escolta_id, p_tipo, p_usuarios, p_titulo, p_texto,
                                 jsonb_build_object('pedido_id', p_pedido_id));
END;
$$;
REVOKE ALL ON FUNCTION public._avisar_app(uuid, text, uuid[], text, text, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.marcar_aviso_lido(p_notificacao_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  UPDATE public.notificacoes SET lida_em = coalesce(lida_em, now())
   WHERE id = p_notificacao_id AND usuario_dest_id = public.get_meu_usuario_id();
  RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.marcar_aviso_lido(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_aviso_lido(uuid) TO authenticated;

UPDATE public.configuracao_avisos SET checkin_telegram_pelo_cron = true WHERE id = 1;

-- Conferência:
-- SELECT prosrc LIKE '%lote_interno.notificar%' FROM pg_proc WHERE proname = '_avisar_app';     -- true
-- SELECT prosrc LIKE '%lida_em%' FROM pg_proc WHERE proname = 'marcar_aviso_lido';             -- true
-- SELECT checkin_telegram_pelo_cron FROM configuracao_avisos;                                -- true
