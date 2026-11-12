-- 222_lancamento_retroativo_reverter.sql
-- ORDEM: primeiro o git revert do código do lançamento retroativo e o deploy (a tela deixa de
-- oferecer o botão; se o código ficar, a conferência só mostra a mensagem de "depende da
-- migration 222"); depois este arquivo. Idempotente.
--
-- Remove a RPC, as auxiliares, a trava e o tipo de aviso, e devolve _enfileirar_aviso (202) e
-- lote_interno.notificar (211) aos corpos anteriores.
-- AS COLUNAS FICAM (escoltas.lancamento_retroativo, retroativo_por, retroativo_em,
-- retroativo_motivo; registrado_em, retroativo e motivo_retroativo em escolta_status_historico,
-- pontos_controle e fotos; fotos.origem e origem_localizacao) e os CHECK também: são a única
-- marca de que aqueles registros foram lançados depois do fato, e apagá-las faria um
-- lançamento retroativo parecer registro ao vivo. Sem a trava, elas passam a aceitar escrita de
-- quem já escreve na tabela; nenhum código da master as lê ou grava. Para removê-las de vez,
-- guarde antes os ids marcados (SELECT id FROM ... WHERE retroativo) e rode os DROP COLUMN
-- comentados no fim.
-- Os avisos já gravados do tipo lancamento_retroativo são apagados junto com o tipo
-- (notificacoes.tipo_evento_id aponta para dom_tipos_evento); a auditoria fica.

DROP FUNCTION IF EXISTS public.lancar_escolta_retroativa(uuid, jsonb, text, boolean, jsonb);
DROP FUNCTION IF EXISTS lote_interno.retroativo_partidas();
DROP FUNCTION IF EXISTS lote_interno.rotulo_ponto(text);
DROP FUNCTION IF EXISTS lote_interno.ultimo_registro_campo(uuid);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['escoltas', 'escolta_status_historico', 'pontos_controle', 'fotos'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS tr_travar_colunas_retroativo ON public.%I', t);
  END LOOP;
END $$;
DROP FUNCTION IF EXISTS lote_interno.travar_colunas_retroativo();

DELETE FROM public.notificacoes WHERE tipo_evento_id IN
  (SELECT id FROM public.dom_tipos_evento WHERE codigo = 'lancamento_retroativo');
DELETE FROM public.dom_tipos_evento WHERE codigo = 'lancamento_retroativo';

-- _enfileirar_aviso: corpo da 202.
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

-- lote_interno.notificar: corpo da 211.
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
  -- notificacoes.escolta_id é NOT NULL (com FK em cascata): aviso sem escolta não é gravado.
  -- A onda L (conflito de escolta apagada) precisa tratar isso na própria migration.
  IF p_escolta_id IS NULL THEN
    RAISE WARNING 'lote_interno.notificar: aviso % sem escolta não gravado (notificacoes exige escolta_id).', p_tipo;
    RETURN 0;
  END IF;
  IF p_usuarios IS NULL THEN RETURN 0; END IF;
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

NOTIFY pgrst, 'reload schema';

-- Remoção das colunas (opcional, só depois de guardar os ids marcados):
-- ALTER TABLE public.pontos_controle DROP CONSTRAINT IF EXISTS pontos_retroativo_sem_gps;
-- ALTER TABLE public.fotos DROP CONSTRAINT IF EXISTS fotos_galeria_sem_gps_do_aparelho,
--   DROP CONSTRAINT IF EXISTS fotos_origem_localizacao_valida, DROP CONSTRAINT IF EXISTS fotos_origem_valida,
--   DROP COLUMN IF EXISTS origem, DROP COLUMN IF EXISTS origem_localizacao;
-- ALTER TABLE public.escoltas DROP COLUMN IF EXISTS lancamento_retroativo, DROP COLUMN IF EXISTS retroativo_por,
--   DROP COLUMN IF EXISTS retroativo_em, DROP COLUMN IF EXISTS retroativo_motivo;
-- ALTER TABLE public.escolta_status_historico DROP COLUMN IF EXISTS registrado_em, DROP COLUMN IF EXISTS retroativo,
--   DROP COLUMN IF EXISTS motivo_retroativo;   -- idem em pontos_controle e fotos

-- Conferência:
-- SELECT count(*) FROM pg_proc WHERE proname = 'lancar_escolta_retroativa';                              -- 0
-- SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_travar_colunas_retroativo';                          -- 0
-- SELECT prosrc LIKE '%lancamento_retroativo%' FROM pg_proc WHERE oid = 'public._enfileirar_aviso(text, text, uuid, text)'::regprocedure; -- false
