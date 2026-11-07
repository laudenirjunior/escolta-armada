-- 219_registro_campo_reverter.sql
-- ORDEM (docs/14, seção 16.5): (1) configuracao_avisos.offline_ligado = false e esperar até
-- todos os aparelhos que informaram nos últimos 7 dias estarem com zero pendentes:
--   SELECT count(*) FROM registros_campo_aparelhos WHERE informado_em > now() - interval '7 days' AND pendentes > 0;  -- 0
-- (2) git revert do código da onda L com o sw.js de reversão (apaga os caches e se
-- desregistra) e o deploy; (3) este arquivo. A 218 e as anteriores só depois dele.
-- Guarda o livro, as saídas do efetivo e a contagem dos aparelhos em backup_20261008 (uma
-- linha por registro; rodar de novo não duplica), devolve a registrar_etapa_escolta da 218 e
-- o cron de minuto da 212, tira o USAGE do lote_interno para authenticated.
CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
DO $$
BEGIN
  IF to_regclass('public.registros_campo') IS NOT NULL THEN
    CREATE TABLE IF NOT EXISTS backup_20261008.registros_campo_219 (LIKE public.registros_campo);
    INSERT INTO backup_20261008.registros_campo_219
    SELECT r.* FROM public.registros_campo r
     WHERE NOT EXISTS (SELECT 1 FROM backup_20261008.registros_campo_219 b WHERE b.client_id = r.client_id);
  END IF;
  IF to_regclass('public.escolta_efetivo_saidas') IS NOT NULL THEN
    CREATE TABLE IF NOT EXISTS backup_20261008.escolta_efetivo_saidas_219 (LIKE public.escolta_efetivo_saidas);
    INSERT INTO backup_20261008.escolta_efetivo_saidas_219
    SELECT s.* FROM public.escolta_efetivo_saidas s
     WHERE NOT EXISTS (SELECT 1 FROM backup_20261008.escolta_efetivo_saidas_219 b WHERE b.id = s.id);
  END IF;
  IF to_regclass('public.registros_campo_aparelhos') IS NOT NULL THEN
    CREATE TABLE IF NOT EXISTS backup_20261008.registros_campo_aparelhos_219 (LIKE public.registros_campo_aparelhos);
    DELETE FROM backup_20261008.registros_campo_aparelhos_219;
    INSERT INTO backup_20261008.registros_campo_aparelhos_219 SELECT * FROM public.registros_campo_aparelhos;
  END IF;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;

-- Cron de minuto: volta ao comando da 212.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('lote2026_avisos_checkin', '* * * * *', 'SELECT lote_interno.gerar_avisos_checkin();');
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.registrar_campo(uuid, text, jsonb, integer, timestamptz, jsonb);
DROP FUNCTION IF EXISTS public.reservar_aviso_campo(uuid);
DROP FUNCTION IF EXISTS public.informar_pendentes(text, integer);
DROP FUNCTION IF EXISTS public.config_offline();
DROP FUNCTION IF EXISTS public.listar_conflitos(boolean, integer, timestamptz);
DROP FUNCTION IF EXISTS public.tratar_conflito(uuid, text);
DROP FUNCTION IF EXISTS lote_interno.livro_registrar(uuid, text, uuid, uuid, jsonb, integer, timestamptz, jsonb);
DROP FUNCTION IF EXISTS lote_interno.livro_resultado(uuid, text, text, text, text, integer, jsonb);
DROP FUNCTION IF EXISTS lote_interno.avisar_conflito(uuid);
DROP FUNCTION IF EXISTS lote_interno.fechar_avisos_agrupados(timestamptz);
DROP FUNCTION IF EXISTS lote_interno.texto_motivo_campo(text, text);
DROP FUNCTION IF EXISTS lote_interno.hora_br(timestamptz);
DROP TRIGGER IF EXISTS tr_escolta_efetivo_saida_delete ON public.escolta_efetivo;
DROP TRIGGER IF EXISTS tr_escolta_efetivo_saida_update ON public.escolta_efetivo;
DROP TRIGGER IF EXISTS tr_escoltas_marcar_apagada ON public.escoltas;
DROP FUNCTION IF EXISTS lote_interno.registrar_saida_efetivo();
DROP FUNCTION IF EXISTS lote_interno.marcar_escolta_apagada();
DROP TABLE IF EXISTS public.registros_campo_avisos_agrupados;
DROP TABLE IF EXISTS public.registros_campo_aparelhos;
DROP TABLE IF EXISTS public.escolta_efetivo_saidas;
DROP TABLE IF EXISTS public.registros_campo;
ALTER TABLE public.configuracao_avisos DROP COLUMN IF EXISTS offline_ligado, DROP COLUMN IF EXISTS telefone_central;
REVOKE USAGE ON SCHEMA lote_interno FROM authenticated;

-- registrar_etapa_escolta: corpo da 218 (sem a hora da ação e sem o id do aparelho).
CREATE OR REPLACE FUNCTION public.registrar_etapa_escolta(p_escolta_id uuid, p_pontos jsonb DEFAULT '[]'::jsonb, p_status_atual text DEFAULT NULL::text, p_status_novo text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text, p_latitude numeric DEFAULT NULL::numeric, p_longitude numeric DEFAULT NULL::numeric, p_observacao_fechamento text DEFAULT NULL::text, p_data_hora_prevista timestamp with time zone DEFAULT NULL::timestamp with time zone, p_tipo_ponto_todas uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int; v_faltando text[]; v_status text; v_arquivada timestamptz;
BEGIN
  -- 0. Trava a escolta e confere a etapa ANTES de gravar qualquer coisa. Serializa duas
  --    viaturas do comboio registrando ao mesmo tempo (a segunda vê o ponto da primeira)
  --    e impede ponto de uma etapa que já passou.
  SELECT status, arquivada_em INTO v_status, v_arquivada FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  -- Onda I (218): escolta arquivada não recebe registro (só o administrador a enxerga).
  IF v_arquivada IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;
  IF p_status_atual IS NOT NULL AND v_status IS DISTINCT FROM p_status_atual THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 1. Pontos de controle (todas as viaturas num statement só). Onda I: o autor é sempre
  --    quem está na sessão (em nome de quem fez); sem sessão (SQL), vale o informado.
  IF jsonb_array_length(coalesce(p_pontos, '[]'::jsonb)) > 0 THEN
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid)
               WHERE NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
                                 WHERE ev.id = x.escolta_veiculo_id AND ev.escolta_id = p_escolta_id)) THEN
      RAISE EXCEPTION 'Ponto de controle de viatura que não pertence a esta escolta.';
    END IF;
    INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude,
                                        precisao_metros, sem_sinal_gps, foto_id, lancado_por, observacoes,
                                        sincronizado, criado_offline)
    SELECT x.escolta_veiculo_id, x.tipo_ponto_id, coalesce(x.data_hora, now()), x.latitude, x.longitude,
           x.precisao_metros, coalesce(x.sem_sinal_gps, false), x.foto_id,
           coalesce(public.get_meu_usuario_id(), x.lancado_por), x.observacoes,
           coalesce(x.sincronizado, true), coalesce(x.criado_offline, false)
    FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid, tipo_ponto_id uuid, data_hora timestamptz,
                                           latitude numeric, longitude numeric, precisao_metros numeric,
                                           sem_sinal_gps boolean, foto_id uuid, lancado_por uuid, observacoes text,
                                           sincronizado boolean, criado_offline boolean);
  END IF;

  IF p_status_novo IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'avancou', false);
  END IF;

  -- 2. Comboio: a etapa só avança quando todas as viaturas registraram o ponto dela.
  --    Onda I: ponto anulado (etapa desfeita pela gestão) não conta.
  IF p_tipo_ponto_todas IS NOT NULL THEN
    SELECT array_agg(coalesce(ve.placa, 'sem placa') ORDER BY ev.criado_em) INTO v_faltando
    FROM public.escolta_veiculos ev
    LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
    WHERE ev.escolta_id = p_escolta_id
      AND NOT EXISTS (SELECT 1 FROM public.pontos_controle pc
                      WHERE pc.escolta_veiculo_id = ev.id AND pc.tipo_ponto_id = p_tipo_ponto_todas
                        AND pc.anulado_em IS NULL);
    IF v_faltando IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'avancou', false, 'faltando', to_jsonb(v_faltando));
    END IF;
  END IF;

  -- 3. Status, com a guarda do status atual (a trigger valida a transição).
  UPDATE public.escoltas SET
         status = p_status_novo,
         observacao_fechamento = CASE
           WHEN p_status_novo IN ('finalizada', 'cancelada') THEN p_observacao_fechamento
           WHEN p_data_hora_prevista IS NOT NULL THEN NULL
           ELSE observacao_fechamento END,
         data_finalizacao = CASE WHEN p_status_novo = 'finalizada' THEN now() ELSE data_finalizacao END,
         data_hora_prevista = coalesce(p_data_hora_prevista, data_hora_prevista)
   WHERE id = p_escolta_id AND status = p_status_atual;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 4. Histórico, com autor, na mesma transação. Onda I: via_rpc = true (escolta.historico_rpc).
  PERFORM set_config('escolta.historico_rpc', 'on', true);
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora,
                                               latitude, longitude, observacao)
  VALUES (p_escolta_id, p_status_atual, p_status_novo, public.get_meu_usuario_id(), now(),
          p_latitude, p_longitude, p_observacao);
  PERFORM set_config('escolta.historico_rpc', 'off', true);

  RETURN jsonb_build_object('ok', true, 'avancou', true);
END;
$function$;

