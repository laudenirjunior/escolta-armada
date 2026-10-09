-- 214_poder_total_travas.sql
-- Lote 2026-10, onda I (adendo 01, item 4.3). Idempotente. Bloco 1, depois da 213.
-- Compatível com a master 2b3fff9. O que a master grava em escolta iniciada (conferido no
-- código, revisão adversarial I, menor 16): em escoltas, status, data_finalizacao,
-- observacao_fechamento, checklist_pendente_no_inicio e periodicidade_checkin_min
-- ([id]/page.tsx:2010), todas colunas livres; em escolta_veiculos, KM de saída e de retorno
-- (gravarKmViaturas, :1714) e combustível, livres porque placa e escolta não mudam (nessa
-- condição a 214 libera qualquer coluna da viatura, como a letra da 12.3.3); pontos,
-- checklists e respostas, fotos, ocorrências, emergências e histórico (INSERT, sem trava de
-- edição). Não grava anulado nem arquivada e grava lancado_por com o próprio usuário; sem
-- arquivadas e sem anulados (nada disso existe antes da 218), os filtros novos não mudam
-- nenhum resultado. A trava de DELETE do item 6 só recusa o que a master nunca apaga
-- (registro anulado, que só existe depois da 218, e viatura com registro de campo).
--
-- Por quê (docs/14, seção 12.3; decisões S7, S8 e S10; 18.8, itens 6 e 7):
-- 1. validar_transicao_status_escolta ganha um ramo especial, antes do erro, para a volta
--    de etapa (reset) e a conclusão antecipada. Dupla guarda: variável de transação
--    escolta.transicao_especial (ligada só pelas RPCs da 218, com o destino em
--    escolta.transicao_destino) E perfil administrador ou gestor. O botão genérico não pula
--    etapa. A mesma trigger recusa mudar o status de escolta arquivada.
-- 2. tr_impedir_edicao_escolta_iniciada (escoltas, escolta_veiculos e escolta_efetivo): com a
--    escolta fora de rascunho e agendada, só administrador e gestor mudam o que não é do
--    fluxo (S10: supervisor e central perdem no servidor o que a tela já não oferecia).
--    Comparação por to_jsonb(OLD) e to_jsonb(NEW), como a 197, sem as colunas livres e sem as
--    colunas geradas (lidas do catálogo, attgenerated; em trigger BEFORE elas chegam nulas
--    em NEW): vale para colunas que ainda não existem (UF da onda K) sem citá-las por nome.
--    auth.uid() nulo passa (migrations, cargas e cron). Só recusa, não grava nada em NEW:
--    a ordem alfabética entre as BEFORE UPDATE (roda antes de tr_impedir_edicao_por_operador)
--    é indiferente; o teste confere a ordem real.
-- 3. Filtro de anulado em exigir_ponto_transito_retorno, verificar_checklist_pendente e
--    registrar_etapa_escolta (contagem do comboio). registrar_etapa_escolta passa também a
--    ligar escolta.historico_rpc (o histórico dela sai com via_rpc = true) e a gravar
--    lancado_por com o usuário da sessão (em nome de quem fez).
-- 4. Filtros de arquivada e de anulado no aviso de check-in (lote_interno.gerar_avisos_checkin
--    e lote_interno.enfileirar_alerta_checkin, da 212), na reserva do navegador
--    (reservar_alertas_checkin, 212) e na reserva do aviso de presença (reservar_aviso_presenca,
--    208; o plano a chama de enfileirar_aviso_presenca).
-- 5. RLS: escolta arquivada só aparece para o administrador (RESTRICTIVE de SELECT); ponto de
--    controle só no nome de quem grava (RESTRICTIVE de INSERT, depois do preenchimento da
--    213.8); apagar escolta só o administrador, em rascunho e sem registro de campo
--    (RESTRICTIVE de DELETE; decisão 1 do adendo: arquivar, nunca apagar).
-- 6. Nada é apagado (revisão adversarial I, médio 2; decisão 2 do adendo): trigger BEFORE
--    DELETE (tr_impedir_apagar_gestao_<tabela>) recusa, para todos os perfis, apagar linha
--    anulada nas tabelas da 213 (e na de conclusões antecipadas) e apagar viatura da escolta
--    que tenha qualquer registro de campo, anulado ou não (ponto, checklist, rastreamento,
--    ocorrência ou emergência; a cascata levaria tudo junto, inclusive depois de um zerar).
--    Vale também dentro das RPCs (trigger, não policy). Sem usuário final (auth.uid() nulo:
--    migrations, reversões, SQL Editor e cron) passa, como nas demais travas.
-- Reversão: 214_poder_total_travas_reverter.sql (depois da 218).

-- 1. Máquina de estados.
CREATE OR REPLACE FUNCTION public.validar_transicao_status_escolta()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ok boolean := false;
  v_especial text;
  v_seq text[] := ARRAY['rascunho', 'agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino',
                        'no_destino', 'em_transito_retorno', 'retornando', 'na_base', 'finalizada'];
  v_pos_old int; v_pos_new int;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  -- Onda I: escolta arquivada não muda de status (recuperar antes).
  IF OLD.arquivada_em IS NOT NULL THEN
    RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes de mudar o status.'
      USING ERRCODE = 'P0001';
  END IF;

  IF NEW.status = 'cancelada' AND OLD.status NOT IN ('finalizada','cancelada') THEN
    RETURN NEW;
  END IF;

  v_ok := (
    (OLD.status = 'rascunho'            AND NEW.status = 'agendada') OR
    (OLD.status = 'agendada'            AND NEW.status = 'em_pre_inicio') OR
    (OLD.status = 'em_pre_inicio'       AND NEW.status = 'em_andamento') OR
    (OLD.status = 'em_andamento'        AND NEW.status = 'na_origem') OR
    (OLD.status = 'na_origem'           AND NEW.status = 'em_transito_destino') OR
    (OLD.status = 'em_transito_destino' AND NEW.status = 'no_destino') OR
    (OLD.status = 'no_destino'          AND NEW.status = 'em_transito_retorno') OR
    (OLD.status = 'em_transito_retorno' AND NEW.status = 'retornando') OR
    (OLD.status = 'retornando'          AND NEW.status = 'na_base') OR
    (OLD.status = 'na_base'             AND NEW.status = 'finalizada')
  );

  IF NOT v_ok AND COALESCE(NEW.fluxo_versao, 1) = 1 THEN
    v_ok := (
      (OLD.status = 'na_origem'  AND NEW.status = 'no_destino') OR
      (OLD.status = 'no_destino' AND NEW.status = 'retornando')
    );
  END IF;

  -- Onda I: volta de etapa e conclusão antecipada, só pelas RPCs da 218 (variável de
  -- transação) e só para administrador ou gestor (perfil). Uma sem a outra não passa.
  v_especial := coalesce(current_setting('escolta.transicao_especial', true), '');
  IF NOT v_ok AND v_especial IN ('reset', 'conclusao_antecipada')
     AND public.get_meu_perfil() IN ('administrador', 'gestor') THEN
    v_pos_old := array_position(v_seq, OLD.status);
    v_pos_new := array_position(v_seq, NEW.status);
    IF v_especial = 'reset' THEN
      v_ok := NEW.status = coalesce(current_setting('escolta.transicao_destino', true), '')
              AND v_pos_old IS NOT NULL AND v_pos_new IS NOT NULL
              AND v_pos_new < v_pos_old AND v_pos_new >= 2
              AND OLD.status NOT IN ('rascunho', 'agendada', 'cancelada');
    ELSE
      v_ok := NEW.status = 'finalizada' AND OLD.status NOT IN ('rascunho', 'finalizada', 'cancelada');
    END IF;
  END IF;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'Transição de status inválida: % para %', OLD.status, NEW.status
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$function$;

-- 2. Edição de escolta iniciada só pela gestão (S10).
CREATE OR REPLACE FUNCTION lote_interno.impedir_edicao_escolta_iniciada() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_status text; v_old jsonb; v_new jsonb; v_excluir text[]; v_esc uuid;
  v_livres text[] := ARRAY['status', 'atualizado_em', 'periodicidade_checkin_min', 'checklist_pendente_no_inicio',
                           'data_finalizacao', 'observacao_fechamento', 'data_hora_prevista',
                           -- colunas da 213, com trava própria (tr_travar_colunas_gestao_escoltas)
                           'arquivada_em', 'arquivada_por', 'motivo_arquivamento', 'reiniciada_em', 'versao_gestao'];
BEGIN
  IF auth.uid() IS NULL THEN RETURN coalesce(NEW, OLD); END IF;

  IF TG_TABLE_NAME = 'escoltas' THEN
    v_status := OLD.status;
  ELSE
    v_esc := CASE WHEN TG_OP = 'DELETE' THEN OLD.escolta_id ELSE NEW.escolta_id END;
    SELECT status INTO v_status FROM public.escoltas WHERE id = v_esc;
    -- Troca de escolta numa linha existente: vale o status da escolta de origem também.
    IF TG_OP = 'UPDATE' AND OLD.escolta_id IS DISTINCT FROM NEW.escolta_id
       AND v_status IN ('rascunho', 'agendada') THEN
      SELECT status INTO v_status FROM public.escoltas WHERE id = OLD.escolta_id;
    END IF;
  END IF;
  -- Escolta que ainda não começou (ou que está sendo apagada em cascata): como hoje.
  IF v_status IS NULL OR v_status IN ('rascunho', 'agendada') THEN RETURN coalesce(NEW, OLD); END IF;
  IF public.get_meu_perfil() IN ('administrador', 'gestor') THEN RETURN coalesce(NEW, OLD); END IF;

  IF TG_TABLE_NAME = 'escoltas' THEN
    SELECT coalesce(array_agg(attname::text), '{}') INTO v_excluir
      FROM pg_attribute WHERE attrelid = TG_RELID AND attnum > 0 AND NOT attisdropped AND attgenerated <> '';
    v_excluir := v_excluir || v_livres;
    v_old := to_jsonb(OLD) - v_excluir;
    v_new := to_jsonb(NEW) - v_excluir;
    IF v_old IS DISTINCT FROM v_new THEN
      RAISE EXCEPTION 'Escolta já iniciada: só o gestor ou o administrador altera os dados dela.'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'escolta_veiculos' THEN
    IF TG_OP = 'UPDATE' AND NEW.veiculo_id IS NOT DISTINCT FROM OLD.veiculo_id
       AND NEW.escolta_id IS NOT DISTINCT FROM OLD.escolta_id THEN
      RETURN NEW;                                   -- KM e combustível continuam livres
    END IF;
    RAISE EXCEPTION 'Escolta já iniciada: só o gestor ou o administrador muda as viaturas.'
      USING ERRCODE = '42501';
  END IF;

  -- escolta_efetivo: inclusão, retirada e alteração.
  RAISE EXCEPTION 'Escolta já iniciada: só o gestor ou o administrador muda a equipe.'
    USING ERRCODE = '42501';
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.impedir_edicao_escolta_iniciada() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tr_impedir_edicao_escolta_iniciada ON public.escoltas;
CREATE TRIGGER tr_impedir_edicao_escolta_iniciada BEFORE UPDATE ON public.escoltas
  FOR EACH ROW EXECUTE FUNCTION lote_interno.impedir_edicao_escolta_iniciada();
DROP TRIGGER IF EXISTS tr_impedir_edicao_escolta_iniciada ON public.escolta_veiculos;
CREATE TRIGGER tr_impedir_edicao_escolta_iniciada BEFORE INSERT OR UPDATE OR DELETE ON public.escolta_veiculos
  FOR EACH ROW EXECUTE FUNCTION lote_interno.impedir_edicao_escolta_iniciada();
DROP TRIGGER IF EXISTS tr_impedir_edicao_escolta_iniciada ON public.escolta_efetivo;
CREATE TRIGGER tr_impedir_edicao_escolta_iniciada BEFORE INSERT OR UPDATE OR DELETE ON public.escolta_efetivo
  FOR EACH ROW EXECUTE FUNCTION lote_interno.impedir_edicao_escolta_iniciada();

-- 3. Só ponto e checklist válidos contam.
CREATE OR REPLACE FUNCTION public.exigir_ponto_transito_retorno()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tem boolean;
BEGIN
  IF NEW.status = 'na_base' AND OLD.status = 'retornando'
     AND COALESCE(NEW.fluxo_versao, 1) = 2 THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.pontos_controle pc
      JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
      JOIN public.dom_tipos_ponto tp ON tp.id = pc.tipo_ponto_id
      WHERE ev.escolta_id = NEW.id
        AND tp.codigo = 'transito_retorno'
        AND pc.anulado_em IS NULL          -- onda I: ponto anulado não vale
    ) INTO v_tem;

    IF NOT v_tem THEN
      RAISE EXCEPTION 'Não é possível concluir o retorno sem registrar o ponto de Trânsito para o Retorno.'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.verificar_checklist_pendente()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_total_veiculos INTEGER;
  v_veiculos_ok INTEGER;
BEGIN
  IF OLD.status = 'em_pre_inicio' AND NEW.status = 'em_andamento' THEN
    SELECT COUNT(*) INTO v_total_veiculos
    FROM escolta_veiculos WHERE escolta_id = NEW.id;

    SELECT COUNT(DISTINCT ev.id) INTO v_veiculos_ok
    FROM escolta_veiculos ev
    WHERE ev.escolta_id = NEW.id
      AND EXISTS (
        SELECT 1 FROM checklists c
        WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'viatura' AND c.concluido = true AND c.anulado_em IS NULL
      )
      AND EXISTS (
        SELECT 1 FROM checklists c
        WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'material' AND c.concluido = true AND c.anulado_em IS NULL
      );

    IF v_veiculos_ok < v_total_veiculos THEN
      NEW.checklist_pendente_no_inicio := true;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_etapa_escolta(p_escolta_id uuid, p_pontos jsonb DEFAULT '[]'::jsonb, p_status_atual text DEFAULT NULL::text, p_status_novo text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text, p_latitude numeric DEFAULT NULL::numeric, p_longitude numeric DEFAULT NULL::numeric, p_observacao_fechamento text DEFAULT NULL::text, p_data_hora_prevista timestamp with time zone DEFAULT NULL::timestamp with time zone, p_tipo_ponto_todas uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int; v_faltando text[]; v_status text;
BEGIN
  -- 0. Trava a escolta e confere a etapa ANTES de gravar qualquer coisa. Serializa duas
  --    viaturas do comboio registrando ao mesmo tempo (a segunda vê o ponto da primeira)
  --    e impede ponto de uma etapa que já passou.
  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
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
REVOKE ALL ON FUNCTION public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid) TO authenticated;

-- 4. Avisos de check-in e de presença sem arquivada e sem anulado.
CREATE OR REPLACE FUNCTION lote_interno.enfileirar_alerta_checkin(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE e record; v_ultima timestamptz; v_atraso int; v_ok boolean; v_chave text;
BEGIN
  SELECT es.id, es.codigo_escolta, es.status, es.periodicidade_checkin_min, es.arquivada_em, c.nome_cliente INTO e
  FROM public.escoltas es JOIN public.clientes c ON c.id = es.cliente_id WHERE es.id = p_escolta_id;
  IF e.id IS NOT NULL AND e.arquivada_em IS NOT NULL THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'arquivada');
  END IF;
  IF e.id IS NULL OR e.periodicidade_checkin_min IS NULL
     OR e.status NOT IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando') THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem check-in periodico');
  END IF;
  -- Regra antiga (pendência 0.3 de docs/12): qualquer PARADA válida zera o prazo; sem nenhuma, não notifica.
  SELECT max(pc.data_hora) INTO v_ultima
  FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
  WHERE ev.escolta_id = p_escolta_id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
    AND pc.anulado_em IS NULL;
  IF v_ultima IS NULL THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem parada'); END IF;
  v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - e.periodicidade_checkin_min;
  IF v_atraso < 1 THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'em dia'); END IF;
  -- Uma mensagem por período vencido sem check-in (chave: escolta, última parada e
  -- número do período).
  v_chave := 'checkin:' || p_escolta_id || ':' || extract(epoch FROM v_ultima)::bigint
             || ':' || floor(v_atraso::numeric / e.periodicidade_checkin_min)::int;
  -- Já mandada por um navegador (reservar_alertas_checkin): não manda de novo.
  IF EXISTS (SELECT 1 FROM public.avisos_reservados WHERE chave = v_chave) THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'enviado pelo navegador');
  END IF;
  v_ok := public._enfileirar_aviso(v_chave, 'cliente', p_escolta_id,
    '<b>Alerta: check-in em atraso</b>' || E'\n'
    || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(e.nome_cliente) || E'\n'
    || 'Sem check-in há ' || (v_atraso + e.periodicidade_checkin_min) || ' minutos (periodicidade de '
    || e.periodicidade_checkin_min || ' min).' || E'\n'
    || 'Registrado em ' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (Brasília)');
  RETURN jsonb_build_object('enfileirado', v_ok);
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reservar_alertas_checkin() RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text; v_eu uuid; v_gestao boolean; r record; v_ultima timestamptz; v_atraso int;
  v_chave text; v_n int; v_saida jsonb := '[]'::jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  -- O cron manda: nada para o navegador.
  IF public.avisos_pelo_banco_ativos()
     AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false) THEN
    RETURN v_saida;
  END IF;
  v_eu := public.get_meu_usuario_id();
  v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
  FOR r IN
    SELECT e.id, e.codigo_escolta, e.status, e.periodicidade_checkin_min AS per, c.nome_cliente
    FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
    WHERE e.periodicidade_checkin_min > 0
      AND e.arquivada_em IS NULL
      AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
      AND (v_gestao OR public.sou_do_efetivo(e.id))
  LOOP
    -- Regra antiga (pendência 0.3), a mesma de lote_interno.enfileirar_alerta_checkin.
    SELECT max(pc.data_hora) INTO v_ultima
    FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
    WHERE ev.escolta_id = r.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
      AND pc.anulado_em IS NULL;
    CONTINUE WHEN v_ultima IS NULL;
    v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - r.per;
    CONTINUE WHEN v_atraso < 1;
    v_chave := 'checkin:' || r.id || ':' || extract(epoch FROM v_ultima)::bigint || ':' || floor(v_atraso::numeric / r.per)::int;
    -- Já enfileirada pelo cron (envio pelo banco ligado há pouco): não manda de novo.
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.avisos_telegram WHERE evento_chave = v_chave);
    INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES (v_chave, v_eu) ON CONFLICT (chave) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    CONTINUE WHEN v_n = 0;
    v_saida := v_saida || jsonb_build_object(
      'escolta_id', r.id, 'codigo', r.codigo_escolta, 'cliente', r.nome_cliente, 'status', r.status,
      'atraso_min', v_atraso, 'periodicidade_min', r.per,
      'efetivos', coalesce((SELECT jsonb_agg(v.nome_completo || coalesce(' (' || ee.papel_na_escolta || ')', '') ORDER BY ee.papel_na_escolta, v.nome_completo)
                            FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
                            WHERE ee.escolta_id = r.id), '[]'::jsonb));
  END LOOP;
  RETURN v_saida;
END;
$$;
REVOKE ALL ON FUNCTION public.reservar_alertas_checkin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reservar_alertas_checkin() TO authenticated;

CREATE OR REPLACE FUNCTION lote_interno.gerar_avisos_checkin(p_agora timestamptz DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  r record; v_gestao uuid[]; v_n int := 0; v_decorrido numeric; v_atraso int; v_periodo int; v_telegram boolean;
BEGIN
  SELECT coalesce(array_agg(u.id), '{}') INTO v_gestao
  FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor', 'central');
  v_telegram := public.avisos_pelo_banco_ativos()
                AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false);

  -- Onda I: escolta arquivada fora; ponto anulado não é referência.
  FOR r IN
    SELECT e.id, e.codigo_escolta, e.periodicidade_checkin_min AS per, c.nome_cliente,
           coalesce(
             (SELECT max(pc.data_hora) FROM public.pontos_controle pc
                JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
               WHERE ev.escolta_id = e.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
                 AND pc.anulado_em IS NULL
                 AND lote_interno.tipo_da_observacao(pc.observacoes) = 'reporte_periodico'),
             (SELECT min(pc.data_hora) FROM public.pontos_controle pc
                JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
               WHERE ev.escolta_id = e.id AND pc.anulado_em IS NULL),
             e.data_hora_prevista) AS referencia
    FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
    WHERE e.periodicidade_checkin_min > 0
      AND e.arquivada_em IS NULL
      AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
  LOOP
    -- Aviso na central: erro numa escolta (usuário apagado entre a leitura e o INSERT, tipo
    -- ausente) fica nela e vira WARNING; o ciclo segue.
    BEGIN
      IF r.referencia IS NOT NULL THEN
        v_decorrido := extract(epoch FROM (p_agora - r.referencia));
        -- Mesmo arredondamento de minutosAteCheckin: atraso = -floor((per*60 - decorrido) / 60).
        v_atraso := -floor((r.per * 60 - v_decorrido) / 60)::int;
        IF v_atraso >= 1 THEN
          -- Período n: de n a n+1 periodicidades decorridas (o 1º vence com a periodicidade).
          v_periodo := ceil(v_decorrido / (r.per * 60))::int - 1;
          v_n := v_n + lote_interno.notificar(
            'checkin:' || r.id || ':' || floor(extract(epoch FROM r.referencia))::bigint || ':' || v_periodo,
            r.id, 'checkin_vencido',
            ARRAY(SELECT v.usuario_id FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
                   WHERE ee.escolta_id = r.id AND v.usuario_id IS NOT NULL) || v_gestao,
            'Check-in atrasado: ' || r.codigo_escolta,
            'Escolta ' || r.codigo_escolta || ' · ' || r.nome_cliente || ': sem check-in há ' || (v_atraso + r.per)
              || ' min (periodicidade de ' || r.per || ' min, ' || v_atraso || ' min de atraso). Prazo vencido em '
              || to_char((r.referencia + make_interval(mins => r.per * v_periodo)) AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
              || ' (Brasília).',
            jsonb_build_object('referencia', r.referencia, 'periodo', v_periodo, 'periodicidade_min', r.per));
        END IF;
      END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'gerar_avisos_checkin: aviso da escolta % falhou: %', r.id, SQLERRM;
    END;
    -- Telegram pela regra antiga (a função decide); erro numa escolta não para o ciclo.
    IF v_telegram THEN
      BEGIN
        PERFORM lote_interno.enfileirar_alerta_checkin(r.id);
      EXCEPTION WHEN others THEN
        RAISE WARNING 'gerar_avisos_checkin: Telegram da escolta % falhou: %', r.id, SQLERRM;
      END;
    END IF;
  END LOOP;

  DELETE FROM public.notificacoes WHERE lida AND lida_em < p_agora - interval '90 days';
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.gerar_avisos_checkin(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reservar_aviso_presenca(p_presenca_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; v_esc uuid; v_n int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  -- Onda I: presença anulada ou de escolta arquivada não vai ao Telegram.
  SELECT p.escolta_id INTO v_esc FROM public.presencas p JOIN public.escoltas e ON e.id = p.escolta_id
   WHERE p.id = p_presenca_id AND p.anulado_em IS NULL AND e.arquivada_em IS NULL;
  IF v_esc IS NULL THEN RETURN false; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(v_esc) THEN
    RETURN false;
  END IF;
  INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES ('presenca:' || p_presenca_id, public.get_meu_usuario_id())
  ON CONFLICT (chave) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n = 1;
END;
$$;
REVOKE ALL ON FUNCTION public.reservar_aviso_presenca(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reservar_aviso_presenca(uuid) TO authenticated;

-- 5. RLS.
-- Escolta arquivada some para todos, menos o administrador (lista, mural, Campo, mapa,
-- indicadores e embeds escolta:escoltas(...) passam a vir nulos para quem não vê).
DROP POLICY IF EXISTS escoltas_arquivada_so_admin ON public.escoltas;
CREATE POLICY escoltas_arquivada_so_admin ON public.escoltas AS RESTRICTIVE FOR SELECT TO authenticated
  USING (arquivada_em IS NULL OR (SELECT public.get_meu_perfil()) = 'administrador');

-- Ponto sempre no nome de quem grava (o nulo é preenchido pela trigger da 213 antes disto).
DROP POLICY IF EXISTS pontos_insert_autor ON public.pontos_controle;
CREATE POLICY pontos_insert_autor ON public.pontos_controle AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (lancado_por = (SELECT public.get_meu_usuario_id()));

-- Apagar escolta: só o administrador, em rascunho e sem nenhum registro de campo.
DROP POLICY IF EXISTS escoltas_delete_so_rascunho ON public.escoltas;
CREATE POLICY escoltas_delete_so_rascunho ON public.escoltas AS RESTRICTIVE FOR DELETE TO authenticated
  USING ((SELECT public.get_meu_perfil()) = 'administrador'
         AND status = 'rascunho'
         AND NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
                          WHERE ev.escolta_id = escoltas.id
                            AND (EXISTS (SELECT 1 FROM public.pontos_controle pc WHERE pc.escolta_veiculo_id = ev.id)
                                 OR EXISTS (SELECT 1 FROM public.checklists ck WHERE ck.escolta_veiculo_id = ev.id)
                                 OR EXISTS (SELECT 1 FROM public.rastreamento ra WHERE ra.escolta_veiculo_id = ev.id)))
         AND NOT EXISTS (SELECT 1 FROM public.ocorrencias o WHERE o.escolta_id = escoltas.id)
         AND NOT EXISTS (SELECT 1 FROM public.emergencias em WHERE em.escolta_id = escoltas.id)
         AND NOT EXISTS (SELECT 1 FROM public.presencas pr WHERE pr.escolta_id = escoltas.id)
         AND NOT EXISTS (SELECT 1 FROM public.atualizacoes_status au WHERE au.escolta_id = escoltas.id));

-- 6. Nada é apagado: linha anulada e viatura com registro de campo.
CREATE OR REPLACE FUNCTION lote_interno.impedir_apagar_registro() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN OLD; END IF;
  IF TG_TABLE_NAME = 'escolta_veiculos' THEN
    IF EXISTS (SELECT 1 FROM public.pontos_controle WHERE escolta_veiculo_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.checklists WHERE escolta_veiculo_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.rastreamento WHERE escolta_veiculo_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.ocorrencias WHERE escolta_veiculo_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.emergencias WHERE escolta_veiculo_id = OLD.id) THEN
      RAISE EXCEPTION 'Esta viatura tem registro de campo (válido ou anulado) e não pode ser apagada: nada é apagado.'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;
  IF to_jsonb(OLD) ->> 'anulado_em' IS NOT NULL THEN
    RAISE EXCEPTION 'Registro anulado não pode ser apagado: ele fica como prova do que a gestão desfez.'
      USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.impedir_apagar_registro() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico',
                           'escolta_conclusoes_antecipadas', 'escolta_veiculos']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_impedir_apagar_gestao_' || t, t);
    EXECUTE format('CREATE TRIGGER %I BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION lote_interno.impedir_apagar_registro()',
                   'tr_impedir_apagar_gestao_' || t, t);
  END LOOP;
END $$;

-- Conferência:
-- SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_impedir_apagar_gestao_%';           -- 11
-- SELECT prosrc LIKE '%transicao_especial%' FROM pg_proc WHERE oid = 'public.validar_transicao_status_escolta()'::regprocedure;  -- true
-- SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_impedir_edicao_escolta_iniciada';     -- 3
-- SELECT polname FROM pg_policy WHERE polname IN ('escoltas_arquivada_so_admin', 'pontos_insert_autor', 'escoltas_delete_so_rascunho'); -- 3
-- SELECT prosrc LIKE '%historico_rpc%' AND prosrc LIKE '%anulado_em IS NULL%' FROM pg_proc WHERE proname = 'registrar_etapa_escolta';  -- true
