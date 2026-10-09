-- 218_poder_total_rpcs.sql
-- Lote 2026-10, onda I (adendo 01, item 4.3). Idempotente. BLOCO 2: aplicar logo depois do
-- deploy, depois da 204 e da 217 (recria funções delas) e da 213 e 214 (bloco 1).
--
-- Por quê (docs/14, seção 12.4; decisões S7, S8, S9 e S15; seção 17, ajustes em C, E e F):
-- as ações da gestão, cada uma numa transação, no servidor:
-- 1. editar_escolta: edição por diferença (viaturas e equipe pelo escolta_veiculo_id), sem
--    apagar e recriar; em rascunho e agendada com os poderes de hoje (campos para gestão,
--    supervisão e central; equipe e viaturas só até supervisor); nos demais status só
--    gestor e administrador, com motivo. Recusa remover viatura com registro de campo,
--    trocar a placa de viatura com registro (S9) e vigilante ou placa repetidos (G).
--    Preserva combustível (E). Não muda versao_gestao.
-- 2. pendencias_da_escolta: o que falta, por etapa e viatura (prévia da conclusão).
-- 3. concluir_escolta_antecipada: finaliza a qualquer momento; as pendências são calculadas
--    aqui (nunca vêm do cliente) e gravadas em escolta_conclusoes_antecipadas.
-- 4. voltar_etapa_escolta e zerar_escolta, com prévia (p_previa = true só devolve a lista
--    do que seria anulado). Destino da volta pela sequência do fluxo (S8), nunca pelo
--    histórico; da finalizada por conclusão antecipada, o status_no_momento gravado. Nada é
--    apagado: os registros ficam anulados (tabela da 12.4.4 em lote_interno.alvos_anulacao).
-- 5. arquivar_escolta (S7: só rascunho, agendada, finalizada ou cancelada) e
--    recuperar_escolta (só administrador).
-- 6. Filtro de arquivada nas funções do mural (204, com o corpo da 217), no envio do
--    Telegram (202) e na registrar_etapa_escolta (214, que já filtra anulado e liga
--    escolta.historico_rpc); presença do mural anulada não vale (T2 depois do zerar).
-- Padrão das RPCs: SECURITY DEFINER, search_path fixo, guarda de perfil, motivo de pelo
-- menos 10 caracteres, SELECT ... FOR UPDATE na escolta, versao_gestao + 1 (menos na
-- edição), histórico com via_rpc, auditoria (lote_interno.auditar, a generalização de
-- _auditar_mural) e aviso (lote_interno.notificar à supervisão e à equipe; Telegram ao chat
-- central por _enfileirar_aviso) na mesma transação. As colunas travadas pela 213 só mudam
-- com a variável escolta.rpc_gestao ligada aqui E perfil de gestão.
-- Funções internas no schema lote_interno, com REVOKE explícito em cada uma (o default
-- privileges do schema não retira o EXECUTE de PUBLIC; ver docs/03, onda J).
-- Reversão: 218_poder_total_rpcs_reverter.sql (recria os corpos anteriores).

-- ── Presença do mural: a anulada (zerar) não impede confirmar de novo ─────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'mural_presencas_escolta_id_vigilante_id_key'
              AND conrelid = 'public.mural_presencas'::regclass) THEN
    ALTER TABLE public.mural_presencas DROP CONSTRAINT mural_presencas_escolta_id_vigilante_id_key;
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS mural_presencas_valida_uk
  ON public.mural_presencas (escolta_id, vigilante_id) WHERE anulado_em IS NULL;

-- ── Auxiliares internas ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lote_interno.rotulo_status(p text) RETURNS text
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT CASE p
    WHEN 'rascunho' THEN 'Rascunho' WHEN 'agendada' THEN 'Agendada' WHEN 'em_pre_inicio' THEN 'Pré-Início'
    WHEN 'em_andamento' THEN 'Em Andamento' WHEN 'na_origem' THEN 'Na Origem'
    WHEN 'em_transito_destino' THEN 'Trânsito p/ Destino' WHEN 'no_destino' THEN 'No Destino'
    WHEN 'em_transito_retorno' THEN 'Trânsito p/ Retorno' WHEN 'retornando' THEN 'Retornando'
    WHEN 'na_base' THEN 'Na Base' WHEN 'finalizada' THEN 'Finalizada' WHEN 'cancelada' THEN 'Cancelada'
    ELSE p END
$$;

-- Ordem linear das etapas (lib/fluxo-escolta.ts, SEQUENCIA_STATUS). Para o fluxo 1 vale a
-- mesma ordem: os saltos legados só servem para avançar (S8).
CREATE OR REPLACE FUNCTION lote_interno.sequencia_status() RETURNS text[]
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT ARRAY['rascunho', 'agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino',
               'no_destino', 'em_transito_retorno', 'retornando', 'na_base', 'finalizada']
$$;

-- Ponto que a entrada na etapa produz (TIPO_PONTO_POR_STATUS).
CREATE OR REPLACE FUNCTION lote_interno.tipo_ponto_da_etapa(p text) RETURNS text
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT CASE p
    WHEN 'em_andamento' THEN 'base_saida' WHEN 'na_origem' THEN 'origem'
    WHEN 'em_transito_destino' THEN 'transito_destino' WHEN 'no_destino' THEN 'destino'
    WHEN 'em_transito_retorno' THEN 'transito_retorno' WHEN 'retornando' THEN 'retorno'
    WHEN 'na_base' THEN 'base_retorno' END
$$;

CREATE OR REPLACE FUNCTION lote_interno.auditar(p_acao text, p_escolta_id uuid, p_antes jsonb, p_depois jsonb) RETURNS void
    LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES (public.get_meu_usuario_id(), p_acao, 'escoltas', p_escolta_id, p_antes, p_depois, now())
$$;

-- Aviso de ação da gestão: central de avisos da supervisão e da equipe (menos quem fez) e
-- Telegram ao chat central (uma mensagem por chave).
CREATE OR REPLACE FUNCTION lote_interno.avisar_acao_gestao(p_escolta_id uuid, p_tipo text, p_chave text,
                                                          p_titulo text, p_linhas text[]) RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_eu uuid := public.get_meu_usuario_id(); v_dest uuid[]; v_ok boolean;
BEGIN
  v_dest := ARRAY(SELECT DISTINCT u FROM unnest(public._supervisao_ids()
                    || public._usuarios_dos_vigilantes(public._ids_da_equipe(public._equipe_atual(p_escolta_id)))) u
                  WHERE u IS DISTINCT FROM v_eu);
  PERFORM lote_interno.notificar(p_chave, p_escolta_id, p_tipo, v_dest, p_titulo, array_to_string(p_linhas, ' '));
  v_ok := public._enfileirar_aviso('gestao:' || p_chave, 'central', p_escolta_id,
            public._texto_aviso_mural(p_titulo, p_escolta_id, p_linhas));
END;
$$;

-- Registros de campo VÁLIDOS da escolta, numa forma só (para a anulação e a prévia).
CREATE OR REPLACE FUNCTION lote_interno.registros_validos(p_escolta_id uuid)
    RETURNS TABLE (tabela text, id uuid, quando timestamptz, carimbo text, sub text, via_rpc boolean, descricao text)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT 'pontos_controle', pc.id, pc.data_hora, pc.status_escolta_no_registro, tp.codigo, false,
         'Ponto ' || tp.nome_exibicao || ' (' || coalesce(ve.placa, 'sem placa') || ')'
    FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
    JOIN public.dom_tipos_ponto tp ON tp.id = pc.tipo_ponto_id LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
   WHERE ev.escolta_id = p_escolta_id AND pc.anulado_em IS NULL
  UNION ALL
  SELECT 'checklists', c.id, coalesce(c.data_inicio, c.criado_em), c.status_escolta_no_registro, c.tipo, false,
         'Checklist de ' || c.tipo || ' (' || coalesce(ve.placa, 'sem placa') || ')'
    FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id
    LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
   WHERE ev.escolta_id = p_escolta_id AND c.anulado_em IS NULL
  UNION ALL
  SELECT 'ocorrencias', o.id, o.data_hora, o.status_escolta_no_registro, NULL, false, 'Ocorrência: ' || left(o.descricao, 80)
    FROM public.ocorrencias o WHERE o.escolta_id = p_escolta_id AND o.anulado_em IS NULL
  UNION ALL
  SELECT 'emergencias', em.id, em.data_hora, em.status_escolta_no_registro, em.status, false, 'Emergência (' || em.status || ')'
    FROM public.emergencias em WHERE em.escolta_id = p_escolta_id AND em.anulado_em IS NULL
  UNION ALL
  SELECT 'presencas', p.id, p.data_hora, p.status_escolta_no_registro, NULL, false, 'Presença de ' || coalesce(v.nome_completo, 'vigilante')
    FROM public.presencas p LEFT JOIN public.vigilantes v ON v.id = p.vigilante_id
   WHERE p.escolta_id = p_escolta_id AND p.anulado_em IS NULL
  UNION ALL
  SELECT 'mural_presencas', mp.id, mp.confirmado_em, mp.status_escolta_no_registro, NULL, false,
         'Presença na base (mural) de ' || coalesce(v.nome_completo, 'vigilante')
    FROM public.mural_presencas mp LEFT JOIN public.vigilantes v ON v.id = mp.vigilante_id
   WHERE mp.escolta_id = p_escolta_id AND mp.anulado_em IS NULL
  UNION ALL
  SELECT 'atualizacoes_status', a.id, a.data_hora, a.status_escolta_no_registro, NULL, false, 'Atualização: ' || left(a.descricao, 80)
    FROM public.atualizacoes_status a WHERE a.escolta_id = p_escolta_id AND a.anulado_em IS NULL
  UNION ALL
  SELECT 'rastreamento', r.id, r.data_hora, r.status_escolta_no_registro, NULL, false,
         'Posição de rastreamento (' || coalesce(ve.placa, 'sem placa') || ')'
    FROM public.rastreamento r JOIN public.escolta_veiculos ev ON ev.id = r.escolta_veiculo_id
    LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
   WHERE ev.escolta_id = p_escolta_id AND r.anulado_em IS NULL
  UNION ALL
  SELECT 'escolta_status_historico', h.id, h.data_hora, h.status_escolta_no_registro, h.status_novo, h.via_rpc,
         'Histórico: ' || lote_interno.rotulo_status(h.status_anterior) || ' para ' || lote_interno.rotulo_status(h.status_novo)
    FROM public.escolta_status_historico h WHERE h.escolta_id = p_escolta_id AND h.anulado_em IS NULL
$$;

-- Horário de referência da entrada na etapa, para os registros antigos sem carimbo: o
-- primeiro ponto válido que a produziu; sem ele, a última linha do histórico gravada por
-- RPC (via_rpc) que levou a ela. Nunca uma linha do histórico gravada pelo cliente.
CREATE OR REPLACE FUNCTION lote_interno.ancora_etapa(p_escolta_id uuid, p_etapa text) RETURNS timestamptz
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(
    (SELECT min(r.quando) FROM lote_interno.registros_validos(p_escolta_id) r
      WHERE r.tabela = 'pontos_controle' AND r.sub = lote_interno.tipo_ponto_da_etapa(p_etapa)),
    (SELECT max(r.quando) FROM lote_interno.registros_validos(p_escolta_id) r
      WHERE r.tabela = 'escolta_status_historico' AND r.sub = p_etapa AND r.via_rpc))
$$;

-- O que é anulado ao desfazer a entrada na etapa p_etapa (docs/14, 12.4.4), ou tudo
-- (zerar). Critério: 'etapa' (o que a entrada produziu, pela tabela), 'historico' (linhas
-- que levaram à etapa), 'carimbo' (gravado enquanto a escolta estava na etapa), 'janela'
-- (registro antigo, sem carimbo, a partir do horário de referência), 'zerar'.
CREATE OR REPLACE FUNCTION lote_interno.alvos_anulacao(p_escolta_id uuid, p_etapa text, p_zerar boolean)
    RETURNS TABLE (tabela text, id uuid, quando timestamptz, descricao text, criterio text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_tipo text; v_ancora timestamptz; v_ancora_nb timestamptz;
BEGIN
  IF p_zerar THEN
    -- Tudo o que é de campo; do histórico, só o que passou de agendada (o planejamento fica).
    RETURN QUERY
      SELECT r.tabela, r.id, r.quando, r.descricao, 'zerar'::text
        FROM lote_interno.registros_validos(p_escolta_id) r
       WHERE NOT (r.tabela = 'escolta_status_historico' AND r.sub IN ('rascunho', 'agendada'));
    RETURN;
  END IF;
  v_tipo := lote_interno.tipo_ponto_da_etapa(p_etapa);
  v_ancora := lote_interno.ancora_etapa(p_escolta_id, p_etapa);
  IF p_etapa = 'finalizada' THEN
    v_ancora_nb := lote_interno.ancora_etapa(p_escolta_id, 'na_base');
  END IF;
  RETURN QUERY
    SELECT r.tabela, r.id, r.quando, r.descricao, x.criterio
      FROM lote_interno.registros_validos(p_escolta_id) r
      CROSS JOIN LATERAL (SELECT CASE
        WHEN r.tabela = 'pontos_controle' AND r.sub = v_tipo THEN 'etapa'
        -- Entrada em em_andamento: checklists do pré-início (a escolta ainda não tem o de entrega).
        WHEN p_etapa = 'em_andamento' AND r.tabela = 'checklists'
             AND (r.carimbo = 'em_pre_inicio' OR r.carimbo IS NULL) THEN 'etapa'
        -- Entrada em finalizada: o checklist de entrega (tipo viatura, gravado na base): pelo
        -- carimbo na_base ou, nos antigos, depois da entrada em na_base. Nunca pelo tipo só.
        WHEN p_etapa = 'finalizada' AND r.tabela = 'checklists' AND r.sub = 'viatura'
             AND (r.carimbo = 'na_base' OR (r.carimbo IS NULL AND v_ancora_nb IS NOT NULL AND r.quando >= v_ancora_nb)) THEN 'etapa'
        WHEN r.tabela = 'escolta_status_historico' AND r.sub = p_etapa THEN 'historico'
        WHEN r.carimbo = p_etapa THEN 'carimbo'
        WHEN r.carimbo IS NULL AND v_ancora IS NOT NULL AND r.quando >= v_ancora
             AND r.tabela <> 'checklists' THEN 'janela'
      END AS criterio) x
     WHERE x.criterio IS NOT NULL;
END;
$$;

-- Destino da volta (S8): o antecessor na sequência; da finalizada por conclusão antecipada,
-- o status em que ela estava. Nunca pelo histórico.
CREATE OR REPLACE FUNCTION lote_interno.destino_voltar(p_escolta_id uuid, p_status text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT CASE
    WHEN p_status = 'finalizada' AND EXISTS (SELECT 1 FROM public.escolta_conclusoes_antecipadas c
                                             WHERE c.escolta_id = p_escolta_id AND c.anulado_em IS NULL)
      THEN (SELECT c.status_no_momento FROM public.escolta_conclusoes_antecipadas c
             WHERE c.escolta_id = p_escolta_id AND c.anulado_em IS NULL)
    ELSE (lote_interno.sequencia_status())[array_position(lote_interno.sequencia_status(), p_status) - 1]
  END
$$;

-- Pendências, por etapa (pré-início até na base) e por viatura, só com registros válidos.
CREATE OR REPLACE FUNCTION lote_interno.pendencias(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_etapa text; v_tipo text; v_nome_tipo text; v_vts jsonb; v_saida jsonb := '[]'::jsonb;
BEGIN
  FOREACH v_etapa IN ARRAY ARRAY['em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino', 'no_destino',
                                 'em_transito_retorno', 'retornando', 'na_base'] LOOP
    v_tipo := lote_interno.tipo_ponto_da_etapa(v_etapa);
    SELECT nome_exibicao INTO v_nome_tipo FROM public.dom_tipos_ponto WHERE codigo = v_tipo;
    SELECT coalesce(jsonb_agg(jsonb_build_object('escolta_veiculo_id', x.id, 'placa', x.placa, 'faltando', to_jsonb(x.faltando))
                              ORDER BY x.criado_em), '[]'::jsonb)
      INTO v_vts
      FROM (
        SELECT ev.id, ev.criado_em, coalesce(ve.placa, 'sem placa') AS placa,
               array_remove(ARRAY[
                 CASE WHEN v_etapa = 'em_pre_inicio' AND NOT EXISTS (
                        SELECT 1 FROM public.checklists c WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'viatura'
                           AND c.concluido AND c.anulado_em IS NULL
                           AND coalesce(c.status_escolta_no_registro, 'em_pre_inicio') NOT IN ('na_base', 'finalizada'))
                      THEN 'Checklist da viatura' END,
                 CASE WHEN v_etapa = 'em_pre_inicio' AND NOT EXISTS (
                        SELECT 1 FROM public.checklists c WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'material'
                           AND c.concluido AND c.anulado_em IS NULL)
                      THEN 'Checklist de material' END,
                 CASE WHEN v_etapa = 'em_pre_inicio' AND ev.quilometragem_saida IS NULL THEN 'KM de saída' END,
                 CASE WHEN v_tipo IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM public.pontos_controle pc JOIN public.dom_tipos_ponto tp ON tp.id = pc.tipo_ponto_id
                         WHERE pc.escolta_veiculo_id = ev.id AND tp.codigo = v_tipo AND pc.anulado_em IS NULL)
                      THEN 'Ponto: ' || v_nome_tipo END,
                 CASE WHEN v_etapa = 'na_base' AND ev.quilometragem_retorno IS NULL THEN 'KM de retorno' END
               ], NULL) AS faltando
          FROM public.escolta_veiculos ev LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
         WHERE ev.escolta_id = p_escolta_id) x
     WHERE cardinality(x.faltando) > 0;
    IF jsonb_array_length(v_vts) > 0 THEN
      v_saida := v_saida || jsonb_build_array(jsonb_build_object('etapa', v_etapa, 'rotulo', lote_interno.rotulo_status(v_etapa),
                                                                 'viaturas', v_vts));
    END IF;
  END LOOP;
  RETURN v_saida;
END;
$$;

-- Guardas comuns.
CREATE OR REPLACE FUNCTION lote_interno.exigir_gestao(p_so_admin boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text := public.get_meu_perfil();
BEGIN
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.' USING ERRCODE = '42501'; END IF;
  IF p_so_admin AND v_perfil <> 'administrador' THEN
    RAISE EXCEPTION 'Só o administrador faz esta ação.' USING ERRCODE = '42501';
  END IF;
  IF v_perfil NOT IN ('administrador', 'gestor') THEN
    RAISE EXCEPTION 'Só o gestor ou o administrador faz esta ação.' USING ERRCODE = '42501';
  END IF;
  RETURN v_perfil;
END;
$$;

CREATE OR REPLACE FUNCTION lote_interno.exigir_motivo(p_motivo text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF p_motivo IS NULL OR length(trim(p_motivo)) < 10 THEN
    RAISE EXCEPTION 'Informe o motivo com pelo menos 10 caracteres.';
  END IF;
  IF length(trim(p_motivo)) > 1000 THEN RAISE EXCEPTION 'O motivo pode ter no máximo 1000 caracteres.'; END IF;
  RETURN trim(p_motivo);
END;
$$;

-- Liga e desliga as variáveis de transação das RPCs da gestão.
CREATE OR REPLACE FUNCTION lote_interno.modo_gestao(p_ligar boolean) RETURNS void
    LANGUAGE plpgsql VOLATILE SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  PERFORM set_config('escolta.rpc_gestao', CASE WHEN p_ligar THEN 'on' ELSE 'off' END, true);
  PERFORM set_config('escolta.historico_rpc', CASE WHEN p_ligar THEN 'on' ELSE 'off' END, true);
  IF NOT p_ligar THEN
    PERFORM set_config('escolta.transicao_especial', '', true);
    PERFORM set_config('escolta.transicao_destino', '', true);
  END IF;
END;
$$;

-- Volta de etapa e zerar (o núcleo das duas RPCs). Chamada só depois das guardas.
CREATE OR REPLACE FUNCTION lote_interno.executar_reset(p_escolta_id uuid, p_tipo text, p_motivo text, p_previa boolean)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  e record; v_eu uuid := public.get_meu_usuario_id(); v_zerar boolean; v_destino text; v_itens jsonb; v_avisos jsonb := '[]'::jsonb;
  v_km jsonb; v_valores jsonb; v_anul uuid := gen_random_uuid(); v_contagem jsonb := '{}'::jsonb; v_n int; t text;
  v_conc uuid; v_reset uuid; v_ancora timestamptz; v_titulo text; v_total int;
BEGIN
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;
  IF e.status IN ('rascunho', 'agendada', 'cancelada') THEN
    RAISE EXCEPTION 'Escolta em %: não há etapa de campo para desfazer.', lote_interno.rotulo_status(e.status);
  END IF;
  IF EXISTS (SELECT 1 FROM public.emergencias em WHERE em.escolta_id = p_escolta_id AND em.status <> 'encerrada' AND em.anulado_em IS NULL) THEN
    RAISE EXCEPTION 'Há emergência aberta nesta escolta: encerre a emergência antes.';
  END IF;

  -- S8: voltar de em_pre_inicio para agendada tem o tratamento do zerar (S15).
  v_zerar := p_tipo = 'zerar' OR e.status = 'em_pre_inicio';
  v_destino := CASE WHEN v_zerar THEN 'agendada' ELSE lote_interno.destino_voltar(p_escolta_id, e.status) END;
  SELECT id INTO v_conc FROM public.escolta_conclusoes_antecipadas WHERE escolta_id = p_escolta_id AND anulado_em IS NULL;

  SELECT coalesce(jsonb_agg(jsonb_build_object('tabela', a.tabela, 'id', a.id, 'quando', a.quando,
                                               'quando_br', public._hora_br(a.quando), 'descricao', a.descricao,
                                               'criterio', a.criterio) ORDER BY a.quando, a.tabela), '[]'::jsonb)
    INTO v_itens
    FROM lote_interno.alvos_anulacao(p_escolta_id, e.status, v_zerar) a;

  SELECT coalesce(jsonb_agg(jsonb_build_object('escolta_veiculo_id', ev.id, 'placa', coalesce(ve.placa, 'sem placa'),
                                               'quilometragem_saida', ev.quilometragem_saida,
                                               'quilometragem_retorno', ev.quilometragem_retorno) ORDER BY ev.criado_em), '[]'::jsonb)
    INTO v_km
    FROM public.escolta_veiculos ev LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id WHERE ev.escolta_id = p_escolta_id;
  v_valores := jsonb_build_object('km', v_km, 'checklist_pendente_no_inicio', e.checklist_pendente_no_inicio,
                                  'data_finalizacao', e.data_finalizacao, 'observacao_fechamento', e.observacao_fechamento,
                                  'conclusao_antecipada_id', v_conc);

  -- Avisos da prévia: registro antigo (sem carimbo) sem horário de referência não é anulado.
  IF NOT v_zerar THEN
    v_ancora := lote_interno.ancora_etapa(p_escolta_id, e.status);
    IF v_ancora IS NULL AND EXISTS (SELECT 1 FROM lote_interno.registros_validos(p_escolta_id) r
                                     WHERE r.carimbo IS NULL AND r.tabela NOT IN ('escolta_status_historico', 'checklists')) THEN
      v_avisos := v_avisos || to_jsonb('Há registros anteriores à atualização (sem carimbo de etapa) e não há horário de referência para a entrada em '
                                       || lote_interno.rotulo_status(e.status) || ': nenhum deles será anulado por horário.'::text);
    ELSIF v_ancora IS NOT NULL THEN
      v_avisos := v_avisos || to_jsonb('Registros antigos (sem carimbo de etapa) contam a partir de ' || public._hora_br(v_ancora) || ' (Brasília).'::text);
    END IF;
  END IF;
  IF (v_zerar OR e.status = 'finalizada') AND v_conc IS NOT NULL THEN
    v_avisos := v_avisos || to_jsonb('A lista de pendências da conclusão antecipada será anulada.'::text);
  END IF;

  IF p_previa THEN
    RETURN jsonb_build_object('previa', true, 'status_atual', e.status, 'rotulo_atual', lote_interno.rotulo_status(e.status),
                              'destino', v_destino, 'rotulo_destino', lote_interno.rotulo_status(v_destino),
                              'tipo', CASE WHEN v_zerar THEN 'zerar' ELSE 'voltar_etapa' END,
                              'itens', v_itens, 'total', jsonb_array_length(v_itens), 'valores', v_valores, 'avisos', v_avisos);
  END IF;

  PERFORM lote_interno.modo_gestao(true);

  -- Anula, tabela a tabela, com o mesmo anulacao_id.
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico'] LOOP
    EXECUTE format('UPDATE public.%I SET anulado_em = now(), anulado_por = $1, motivo_anulacao = $2, anulacao_id = $3
                     WHERE anulado_em IS NULL AND id IN (SELECT (x ->> ''id'')::uuid FROM jsonb_array_elements($4) x
                                                          WHERE x ->> ''tabela'' = $5)', t)
      USING v_eu, p_motivo, v_anul, v_itens, t;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_contagem := v_contagem || jsonb_build_object(t, v_n); END IF;
  END LOOP;
  SELECT coalesce(sum(value::int), 0) INTO v_total FROM jsonb_each_text(v_contagem);

  -- Valores que a entrada na etapa produziu (guardados em valores_anteriores).
  IF v_zerar OR e.status = 'em_andamento' THEN
    UPDATE public.escolta_veiculos SET quilometragem_saida = NULL WHERE escolta_id = p_escolta_id AND quilometragem_saida IS NOT NULL;
  END IF;
  IF v_zerar OR e.status = 'na_base' THEN
    UPDATE public.escolta_veiculos SET quilometragem_retorno = NULL WHERE escolta_id = p_escolta_id AND quilometragem_retorno IS NOT NULL;
  END IF;
  IF (v_zerar OR e.status = 'finalizada') AND v_conc IS NOT NULL THEN
    UPDATE public.escolta_conclusoes_antecipadas SET anulado_em = now(), anulado_por = v_eu, motivo_anulacao = p_motivo, anulacao_id = v_anul
     WHERE id = v_conc;
    v_contagem := v_contagem || jsonb_build_object('escolta_conclusoes_antecipadas', 1);
  END IF;

  -- Status (a trigger aceita só com a variável e o perfil) e versão.
  PERFORM set_config('escolta.transicao_especial', 'reset', true);
  PERFORM set_config('escolta.transicao_destino', v_destino, true);
  UPDATE public.escoltas SET
         status = v_destino,
         versao_gestao = versao_gestao + 1,
         -- A Nova cria com true: sem os checklists (anulados), o pré-início volta a estar pendente.
         checklist_pendente_no_inicio = CASE WHEN v_zerar OR e.status = 'em_andamento' THEN true ELSE checklist_pendente_no_inicio END,
         data_finalizacao = CASE WHEN v_zerar OR e.status = 'finalizada' THEN NULL ELSE data_finalizacao END,
         observacao_fechamento = CASE WHEN v_zerar OR e.status = 'finalizada' THEN NULL ELSE observacao_fechamento END,
         reiniciada_em = CASE WHEN v_zerar THEN now() ELSE reiniciada_em END
   WHERE id = p_escolta_id;

  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora, observacao)
  VALUES (p_escolta_id, e.status, v_destino, v_eu, now(),
          CASE WHEN v_zerar THEN 'Zerada pela gestão: ' ELSE 'Reset: ' END || p_motivo);

  INSERT INTO public.escolta_resets (escolta_id, status_de, status_para, tipo, motivo, feito_por, anulacao_id, valores_anteriores, contagem)
  VALUES (p_escolta_id, e.status, v_destino, CASE WHEN p_tipo = 'zerar' THEN 'zerar' ELSE 'voltar_etapa' END, p_motivo, v_eu, v_anul,
          v_valores, v_contagem)
  RETURNING id INTO v_reset;

  PERFORM lote_interno.auditar(CASE WHEN p_tipo = 'zerar' THEN 'ZERAR_ESCOLTA' ELSE 'VOLTAR_ETAPA' END, p_escolta_id,
    jsonb_build_object('status', e.status, 'valores', v_valores, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', v_destino, 'motivo', p_motivo, 'anulacao_id', v_anul, 'reset_id', v_reset,
                       'anulados', v_contagem, 'versao_gestao', e.versao_gestao + 1));

  v_titulo := CASE WHEN p_tipo = 'zerar' THEN 'Escolta zerada pela gestão: ' ELSE 'Etapa desfeita pela gestão: ' END || e.codigo_escolta;
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'reset_escolta', 'reset:' || v_reset, v_titulo, ARRAY[
    'Voltou de ' || lote_interno.rotulo_status(e.status) || ' para ' || lote_interno.rotulo_status(v_destino) || '.',
    v_total || ' registro(s) anulado(s), nada apagado.',
    'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
    'Motivo: ' || p_motivo]);

  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'de', e.status, 'para', v_destino, 'anulados', v_total, 'contagem', v_contagem,
                            'reset_id', v_reset, 'anulacao_id', v_anul);
END;
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['rotulo_status(text)', 'sequencia_status()', 'tipo_ponto_da_etapa(text)',
                           'auditar(text, uuid, jsonb, jsonb)', 'avisar_acao_gestao(uuid, text, text, text, text[])',
                           'registros_validos(uuid)', 'ancora_etapa(uuid, text)', 'alvos_anulacao(uuid, text, boolean)',
                           'destino_voltar(uuid, text)', 'pendencias(uuid)', 'exigir_gestao(boolean)', 'exigir_motivo(text)',
                           'modo_gestao(boolean)', 'executar_reset(uuid, text, text, boolean)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION lote_interno.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- ── RPCs do cliente ──────────────────────────────────────────────────────────────────

-- 1. Edição.
CREATE OR REPLACE FUNCTION public.editar_escolta(p_escolta_id uuid, p_campos jsonb, p_viaturas jsonb DEFAULT NULL, p_motivo text DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  v_perfil text; v_eu uuid; e record; v_iniciada boolean; v_motivo text; v_campos jsonb := coalesce(p_campos, '{}'::jsonb);
  v_permitidos text[] := ARRAY['cliente_id', 'data_hora_prevista', 'origem_endereco', 'origem_lat', 'origem_lng',
                               'destino_endereco', 'destino_lat', 'destino_lng', 'metadados', 'periodicidade_checkin_min',
                               'valor_cobrado', 'outros_custos', 'observacao_financeira', 'escala_fixa',
                               'origem_uf', 'destino_uf', 'uf_estimada'];
  v_financeiro text[] := ARRAY['valor_cobrado', 'outros_custos', 'observacao_financeira'];
  v_sets text; v_k text; v_antes jsonb; v_depois jsonb; v_equipe_antes jsonb; v_equipe_depois jsonb;
  vt jsonb; m jsonb; v_ev uuid; v_ev_atual record; v_mudou_estrutura boolean := false; v_ids_mantidos uuid[] := '{}';
  v_vigs uuid[] := '{}'; v_veics uuid[] := '{}'; r record; v_n int; v_alterados text[] := '{}';
  v_trocadas jsonb := '{}'::jsonb;
BEGIN
  v_perfil := public.get_meu_perfil();
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') THEN
    RAISE EXCEPTION 'Sem permissão para editar escolta.' USING ERRCODE = '42501';
  END IF;
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;
  v_iniciada := e.status NOT IN ('rascunho', 'agendada');
  IF v_iniciada AND v_perfil NOT IN ('administrador', 'gestor') THEN
    RAISE EXCEPTION 'Escolta já iniciada: só o gestor ou o administrador altera os dados dela.' USING ERRCODE = '42501';
  END IF;
  IF v_iniciada THEN v_motivo := lote_interno.exigir_motivo(p_motivo);
  ELSE v_motivo := nullif(trim(coalesce(p_motivo, '')), '');
  END IF;

  -- Só a lista fechada de campos; financeiro só para quem vê financeiro (a central não grava).
  FOR v_k IN SELECT jsonb_object_keys(v_campos) LOOP
    IF NOT v_k = ANY (v_permitidos) THEN RAISE EXCEPTION 'Campo não editável: %', v_k; END IF;
  END LOOP;
  IF v_perfil = 'central' THEN v_campos := v_campos - v_financeiro; END IF;
  -- Colunas que ainda não existem (UF da onda K) ficam de fora sem erro.
  SELECT string_agg(CASE WHEN a.attname = 'metadados'
                           THEN 'metadados = nullif(jsonb_strip_nulls(coalesce(e.metadados, ''{}''::jsonb) || coalesce(r.metadados, ''{}''::jsonb)), ''{}''::jsonb)'
                         ELSE format('%I = r.%I', a.attname, a.attname) END, ', ')
    INTO v_sets
    FROM pg_attribute a
   WHERE a.attrelid = 'public.escoltas'::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
     AND a.attname::text = ANY (v_permitidos) AND v_campos ? a.attname::text;

  v_antes := to_jsonb(e);
  v_equipe_antes := (SELECT coalesce(jsonb_agg(jsonb_build_object('escolta_veiculo_id', ev.id, 'veiculo_id', ev.veiculo_id,
                       'equipe', (SELECT coalesce(jsonb_agg(jsonb_build_object('vigilante_id', ef.vigilante_id, 'papel', ef.papel_na_escolta)
                                   ORDER BY ef.vigilante_id), '[]'::jsonb) FROM public.escolta_efetivo ef WHERE ef.escolta_veiculo_id = ev.id))
                       ORDER BY ev.criado_em), '[]'::jsonb)
                     FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_escolta_id);

  IF v_sets IS NOT NULL THEN
    EXECUTE format('UPDATE public.escoltas e SET %s FROM jsonb_populate_record(NULL::public.escoltas, $1) r WHERE e.id = $2', v_sets)
      USING v_campos, p_escolta_id;
  END IF;

  -- Viaturas e equipe por diferença (nunca apaga e recria).
  IF p_viaturas IS NOT NULL THEN
    IF jsonb_typeof(p_viaturas) <> 'array' OR jsonb_array_length(p_viaturas) = 0 THEN
      RAISE EXCEPTION 'A escolta precisa de ao menos uma viatura.';
    END IF;
    FOR vt IN SELECT * FROM jsonb_array_elements(p_viaturas) LOOP
      IF (vt ->> 'veiculo_id') IS NULL THEN RAISE EXCEPTION 'Viatura sem veículo selecionado.'; END IF;
      IF (vt ->> 'veiculo_id')::uuid = ANY (v_veics) THEN
        RAISE EXCEPTION 'O veículo % está em duas viaturas. Cada placa entra uma vez só na escolta.',
          coalesce((SELECT placa FROM public.veiculos WHERE id = (vt ->> 'veiculo_id')::uuid), 'selecionado');
      END IF;
      v_veics := v_veics || (vt ->> 'veiculo_id')::uuid;
      FOR m IN SELECT * FROM jsonb_array_elements(coalesce(vt -> 'membros', '[]'::jsonb)) LOOP
        IF (m ->> 'vigilante_id')::uuid = ANY (v_vigs) THEN
          RAISE EXCEPTION 'O vigilante % está escalado duas vezes. Cada vigilante entra uma vez só na escolta.',
            coalesce((SELECT nome_completo FROM public.vigilantes WHERE id = (m ->> 'vigilante_id')::uuid), 'selecionado');
        END IF;
        v_vigs := v_vigs || (m ->> 'vigilante_id')::uuid;
      END LOOP;
      IF (vt ->> 'escolta_veiculo_id') IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.escolta_veiculos WHERE id = (vt ->> 'escolta_veiculo_id')::uuid AND escolta_id = p_escolta_id) THEN
          RAISE EXCEPTION 'Viatura que não pertence a esta escolta.';
        END IF;
        v_ids_mantidos := v_ids_mantidos || (vt ->> 'escolta_veiculo_id')::uuid;
      END IF;
    END LOOP;

    -- Viaturas removidas: só sem registro de campo (S9).
    FOR r IN SELECT ev.id, coalesce(ve.placa, 'sem placa') AS placa FROM public.escolta_veiculos ev
               LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
              WHERE ev.escolta_id = p_escolta_id AND NOT ev.id = ANY (v_ids_mantidos) LOOP
      IF lote_interno.viatura_tem_registro(r.id) THEN
        RAISE EXCEPTION 'A viatura % já tem registro de campo e não pode sair da escolta.', r.placa;
      END IF;
    END LOOP;

    -- Equipe: quem saiu.
    FOR r IN SELECT ef.id FROM public.escolta_efetivo ef WHERE ef.escolta_id = p_escolta_id AND NOT ef.vigilante_id = ANY (v_vigs) LOOP
      DELETE FROM public.escolta_efetivo WHERE id = r.id;
      v_mudou_estrutura := true;
    END LOOP;
    DELETE FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id AND NOT id = ANY (v_ids_mantidos);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_mudou_estrutura := true; END IF;

    -- Troca de placa (só em viatura sem registro, S9): a linha sai e entra de novo com a
    -- placa nova, guardando o combustível. Assim duas viaturas podem trocar de placa entre
    -- si sem esbarrar no índice único (escolta, veículo) da 210; a equipe é regravada abaixo.
    FOR vt IN SELECT * FROM jsonb_array_elements(p_viaturas) LOOP
      CONTINUE WHEN (vt ->> 'escolta_veiculo_id') IS NULL;
      SELECT ev.id, ev.veiculo_id, ev.abastecimento_litros, ev.abastecimento_valor, coalesce(ve.placa, 'sem placa') AS placa INTO v_ev_atual
        FROM public.escolta_veiculos ev LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id WHERE ev.id = (vt ->> 'escolta_veiculo_id')::uuid;
      CONTINUE WHEN v_ev_atual.veiculo_id IS NOT DISTINCT FROM (vt ->> 'veiculo_id')::uuid;
      IF lote_interno.viatura_tem_registro(v_ev_atual.id) THEN
        RAISE EXCEPTION 'A viatura % já tem registro de campo: a placa não pode ser trocada (a foto mostra a placa original).', v_ev_atual.placa;
      END IF;
      v_trocadas := v_trocadas || jsonb_build_object(v_ev_atual.id::text,
        jsonb_build_object('litros', v_ev_atual.abastecimento_litros, 'valor', v_ev_atual.abastecimento_valor));
      DELETE FROM public.escolta_veiculos WHERE id = v_ev_atual.id;
      v_mudou_estrutura := true;
    END LOOP;

    BEGIN
      FOR vt IN SELECT * FROM jsonb_array_elements(p_viaturas) LOOP
        IF (vt ->> 'escolta_veiculo_id') IS NOT NULL AND v_trocadas ? (vt ->> 'escolta_veiculo_id') THEN
          INSERT INTO public.escolta_veiculos (escolta_id, veiculo_id, criado_por, abastecimento_litros, abastecimento_valor)
          VALUES (p_escolta_id, (vt ->> 'veiculo_id')::uuid, v_eu,
                  (v_trocadas -> (vt ->> 'escolta_veiculo_id') ->> 'litros')::numeric,
                  (v_trocadas -> (vt ->> 'escolta_veiculo_id') ->> 'valor')::numeric)
          RETURNING id INTO v_ev;
        ELSIF (vt ->> 'escolta_veiculo_id') IS NOT NULL THEN
          v_ev := (vt ->> 'escolta_veiculo_id')::uuid;
          SELECT ev.veiculo_id, coalesce(ve.placa, 'sem placa') AS placa INTO v_ev_atual
            FROM public.escolta_veiculos ev LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id WHERE ev.id = v_ev;
          IF v_ev_atual.veiculo_id IS DISTINCT FROM (vt ->> 'veiculo_id')::uuid THEN
            IF lote_interno.viatura_tem_registro(v_ev) THEN
              RAISE EXCEPTION 'A viatura % já tem registro de campo: a placa não pode ser trocada (a foto mostra a placa original).', v_ev_atual.placa;
            END IF;
            UPDATE public.escolta_veiculos SET veiculo_id = (vt ->> 'veiculo_id')::uuid, atualizado_por = v_eu WHERE id = v_ev;
            v_mudou_estrutura := true;
          END IF;
        ELSE
          INSERT INTO public.escolta_veiculos (escolta_id, veiculo_id, criado_por)
          VALUES (p_escolta_id, (vt ->> 'veiculo_id')::uuid, v_eu) RETURNING id INTO v_ev;
          v_mudou_estrutura := true;
        END IF;
        FOR m IN SELECT * FROM jsonb_array_elements(coalesce(vt -> 'membros', '[]'::jsonb)) LOOP
          SELECT ef.id, ef.escolta_veiculo_id, ef.papel_na_escolta, ef.valor_pago_vigilante INTO r
            FROM public.escolta_efetivo ef WHERE ef.escolta_id = p_escolta_id AND ef.vigilante_id = (m ->> 'vigilante_id')::uuid;
          IF r.id IS NULL THEN
            INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado,
                                                valor_pago_vigilante, criado_por)
            VALUES (p_escolta_id, v_ev, (m ->> 'vigilante_id')::uuid, coalesce(m ->> 'papel_na_escolta', 'operador'), false,
                    CASE WHEN v_perfil <> 'central' THEN (m ->> 'valor_pago_vigilante')::numeric END, v_eu);
            v_mudou_estrutura := true;
          ELSIF r.escolta_veiculo_id IS DISTINCT FROM v_ev OR r.papel_na_escolta IS DISTINCT FROM coalesce(m ->> 'papel_na_escolta', 'operador') THEN
            UPDATE public.escolta_efetivo SET escolta_veiculo_id = v_ev, papel_na_escolta = coalesce(m ->> 'papel_na_escolta', 'operador'),
                   atualizado_por = v_eu,
                   valor_pago_vigilante = CASE WHEN v_perfil <> 'central' AND m ? 'valor_pago_vigilante'
                                               THEN (m ->> 'valor_pago_vigilante')::numeric ELSE valor_pago_vigilante END
             WHERE id = r.id;
            v_mudou_estrutura := true;
          ELSIF v_perfil <> 'central' AND m ? 'valor_pago_vigilante'
                AND r.valor_pago_vigilante IS DISTINCT FROM (m ->> 'valor_pago_vigilante')::numeric THEN
            UPDATE public.escolta_efetivo SET valor_pago_vigilante = (m ->> 'valor_pago_vigilante')::numeric, atualizado_por = v_eu WHERE id = r.id;
          END IF;
        END LOOP;
      END LOOP;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'A viatura ou um vigilante já está nesta escolta. Revise a equipe e as viaturas.';
    END;
    -- A central edita os dados, mas não a equipe nem as viaturas (como hoje, escolta_efetivo_escrita).
    IF v_mudou_estrutura AND v_perfil = 'central' THEN
      RAISE EXCEPTION 'A central edita os dados da escolta, mas não a equipe nem as viaturas. Fale com o supervisor.' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT to_jsonb(x) INTO v_depois FROM public.escoltas x WHERE x.id = p_escolta_id;
  v_equipe_depois := (SELECT coalesce(jsonb_agg(jsonb_build_object('escolta_veiculo_id', ev.id, 'veiculo_id', ev.veiculo_id,
                       'equipe', (SELECT coalesce(jsonb_agg(jsonb_build_object('vigilante_id', ef.vigilante_id, 'papel', ef.papel_na_escolta)
                                   ORDER BY ef.vigilante_id), '[]'::jsonb) FROM public.escolta_efetivo ef WHERE ef.escolta_veiculo_id = ev.id))
                       ORDER BY ev.criado_em), '[]'::jsonb)
                     FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_escolta_id);
  SELECT coalesce(array_agg(k ORDER BY k), '{}') INTO v_alterados
    FROM jsonb_object_keys(v_depois) k
   WHERE k NOT IN ('atualizado_em', 'atualizado_por') AND (v_depois -> k) IS DISTINCT FROM (v_antes -> k);
  IF v_equipe_antes IS DISTINCT FROM v_equipe_depois THEN v_alterados := v_alterados || 'viaturas_e_equipe'::text; END IF;

  PERFORM lote_interno.auditar('EDITAR_ESCOLTA', p_escolta_id,
    coalesce((SELECT jsonb_object_agg(k, v_antes -> k) FROM unnest(v_alterados) k WHERE v_antes ? k), '{}'::jsonb)
      || jsonb_build_object('status', e.status, 'viaturas', v_equipe_antes),
    coalesce((SELECT jsonb_object_agg(k, v_depois -> k) FROM unnest(v_alterados) k WHERE v_depois ? k), '{}'::jsonb)
      || jsonb_build_object('viaturas', v_equipe_depois, 'motivo', v_motivo, 'campos_alterados', to_jsonb(v_alterados)));

  -- Fora do fluxo normal (escolta iniciada): aviso à supervisão e à equipe.
  IF v_iniciada AND cardinality(v_alterados) > 0 THEN
    PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'edicao_escolta',
      'edicao:' || p_escolta_id || ':' || extract(epoch FROM clock_timestamp())::bigint,
      'Escolta editada pela gestão: ' || e.codigo_escolta, ARRAY[
        'Alterado em ' || lote_interno.rotulo_status(e.status) || ': ' || array_to_string(v_alterados, ', ') || '.',
        'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
        'Motivo: ' || v_motivo]);
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_escolta_id, 'alterados', to_jsonb(v_alterados));
END;
$$;

-- Viatura com registro de campo (S9): ponto, checklist, rastreamento, emergência ou ocorrência.
CREATE OR REPLACE FUNCTION lote_interno.viatura_tem_registro(p_escolta_veiculo_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT EXISTS (SELECT 1 FROM public.pontos_controle WHERE escolta_veiculo_id = p_escolta_veiculo_id)
      OR EXISTS (SELECT 1 FROM public.checklists WHERE escolta_veiculo_id = p_escolta_veiculo_id)
      OR EXISTS (SELECT 1 FROM public.rastreamento WHERE escolta_veiculo_id = p_escolta_veiculo_id)
      OR EXISTS (SELECT 1 FROM public.emergencias WHERE escolta_veiculo_id = p_escolta_veiculo_id)
      OR EXISTS (SELECT 1 FROM public.ocorrencias WHERE escolta_veiculo_id = p_escolta_veiculo_id)
$$;
REVOKE ALL ON FUNCTION lote_interno.viatura_tem_registro(uuid) FROM PUBLIC, anon, authenticated;

-- 2. Pendências (prévia da conclusão).
CREATE OR REPLACE FUNCTION public.pendencias_da_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  IF NOT EXISTS (SELECT 1 FROM public.escoltas WHERE id = p_escolta_id) THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  RETURN lote_interno.pendencias(p_escolta_id);
END;
$$;

-- 3. Conclusão antecipada.
CREATE OR REPLACE FUNCTION public.concluir_escolta_antecipada(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text; v_pend jsonb; v_conc uuid; v_itens int;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;
  IF e.status IN ('rascunho', 'finalizada', 'cancelada') THEN
    RAISE EXCEPTION 'Escolta em %: não pode ser concluída.', lote_interno.rotulo_status(e.status);
  END IF;
  v_pend := lote_interno.pendencias(p_escolta_id);      -- calculada aqui, nunca do cliente
  SELECT count(*) INTO v_itens FROM jsonb_array_elements(v_pend) et, jsonb_array_elements(et -> 'viaturas') vt,
                                    jsonb_array_elements(vt -> 'faltando') it;

  PERFORM lote_interno.modo_gestao(true);
  PERFORM set_config('escolta.transicao_especial', 'conclusao_antecipada', true);
  UPDATE public.escoltas SET status = 'finalizada', data_finalizacao = now(), observacao_fechamento = v_motivo,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora, observacao)
  VALUES (p_escolta_id, e.status, 'finalizada', v_eu, now(),
          CASE WHEN v_itens > 0 THEN 'Conclusão antecipada pela gestão: ' ELSE 'Concluída pela gestão: ' END || v_motivo);
  -- Sem pendência, conclui normalmente, sem a linha.
  IF v_itens > 0 THEN
    INSERT INTO public.escolta_conclusoes_antecipadas (escolta_id, status_no_momento, motivo, concluida_por, pendencias)
    VALUES (p_escolta_id, e.status, v_motivo, v_eu, v_pend) RETURNING id INTO v_conc;
  END IF;
  PERFORM lote_interno.auditar('CONCLUSAO_ANTECIPADA', p_escolta_id,
    jsonb_build_object('status', e.status, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', 'finalizada', 'motivo', v_motivo, 'pendencias', v_pend, 'itens_pendentes', v_itens,
                       'conclusao_id', v_conc, 'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'conclusao_antecipada', 'conclusao:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    CASE WHEN v_itens > 0 THEN 'Concluída com pendências: ' ELSE 'Concluída pela gestão: ' END || e.codigo_escolta, ARRAY[
      'Concluída em ' || lote_interno.rotulo_status(e.status) || CASE WHEN v_itens > 0 THEN ', com ' || v_itens || ' item(ns) pendente(s).' ELSE ', sem pendências.' END,
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Observação: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'pendencias', v_pend, 'itens', v_itens, 'conclusao_id', v_conc);
END;
$$;

-- 4. Voltar uma etapa e zerar.
CREATE OR REPLACE FUNCTION public.voltar_etapa_escolta(p_escolta_id uuid, p_motivo text DEFAULT NULL, p_previa boolean DEFAULT false)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_motivo text;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  IF NOT coalesce(p_previa, false) THEN v_motivo := lote_interno.exigir_motivo(p_motivo); END IF;
  RETURN lote_interno.executar_reset(p_escolta_id, 'voltar_etapa', v_motivo, coalesce(p_previa, false));
END;
$$;

CREATE OR REPLACE FUNCTION public.zerar_escolta(p_escolta_id uuid, p_motivo text DEFAULT NULL, p_previa boolean DEFAULT false)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_motivo text;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  IF NOT coalesce(p_previa, false) THEN v_motivo := lote_interno.exigir_motivo(p_motivo); END IF;
  RETURN lote_interno.executar_reset(p_escolta_id, 'zerar', v_motivo, coalesce(p_previa, false));
END;
$$;

-- 5. Arquivar (S7) e recuperar.
CREATE OR REPLACE FUNCTION public.arquivar_escolta(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text; v_ped int;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Esta escolta já está arquivada.'; END IF;
  IF e.status NOT IN ('rascunho', 'agendada', 'finalizada', 'cancelada') THEN
    RAISE EXCEPTION 'Escolta em andamento não pode ser arquivada: conclua (inclusive com pendências) ou cancele antes.';
  END IF;
  PERFORM lote_interno.modo_gestao(true);
  UPDATE public.escoltas SET arquivada_em = now(), arquivada_por = v_eu, motivo_arquivamento = v_motivo,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  -- Pedido de substituição em análise perde o objeto.
  UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
         observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: a escolta foi arquivada.')
   WHERE escolta_id = p_escolta_id AND status = 'pendente';
  GET DIAGNOSTICS v_ped = ROW_COUNT;
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora, observacao)
  VALUES (p_escolta_id, e.status, e.status, v_eu, now(), 'Arquivada pela gestão: ' || v_motivo);
  PERFORM lote_interno.auditar('ARQUIVAR_ESCOLTA', p_escolta_id,
    jsonb_build_object('status', e.status, 'arquivada_em', NULL, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', e.status, 'arquivada_em', now(), 'motivo', v_motivo, 'pedidos_invalidados', v_ped,
                       'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'arquivamento_escolta', 'arquivamento:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    'Escolta arquivada: ' || e.codigo_escolta, ARRAY[
      'Arquivada em ' || lote_interno.rotulo_status(e.status) || '; some das listas, do mural e dos indicadores.',
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Motivo: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'status', e.status, 'pedidos_invalidados', v_ped);
END;
$$;

CREATE OR REPLACE FUNCTION public.recuperar_escolta(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text;
BEGIN
  PERFORM lote_interno.exigir_gestao(true);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NULL THEN RAISE EXCEPTION 'Esta escolta não está arquivada.'; END IF;
  PERFORM lote_interno.modo_gestao(true);
  UPDATE public.escoltas SET arquivada_em = NULL, arquivada_por = NULL, motivo_arquivamento = NULL,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora, observacao)
  VALUES (p_escolta_id, e.status, e.status, v_eu, now(), 'Recuperada do arquivo: ' || v_motivo);
  PERFORM lote_interno.auditar('RECUPERAR_ESCOLTA', p_escolta_id,
    jsonb_build_object('status', e.status, 'arquivada_em', e.arquivada_em, 'arquivada_por', e.arquivada_por,
                       'motivo_arquivamento', e.motivo_arquivamento, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', e.status, 'arquivada_em', NULL, 'motivo', v_motivo, 'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'recuperacao_escolta', 'recuperacao:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    'Escolta recuperada do arquivo: ' || e.codigo_escolta, ARRAY[
      'Volta em ' || lote_interno.rotulo_status(e.status) || ', no status em que estava.',
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'administrador') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Motivo: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'status', e.status);
END;
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['editar_escolta(uuid, jsonb, jsonb, text)', 'pendencias_da_escolta(uuid)',
                           'concluir_escolta_antecipada(uuid, text)', 'voltar_etapa_escolta(uuid, text, boolean)',
                           'zerar_escolta(uuid, text, boolean)', 'arquivar_escolta(uuid, text)', 'recuperar_escolta(uuid, text)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- ── Funções da 204 (corpo da 217), da 202 e da 214, recriadas com os filtros ───────────
CREATE OR REPLACE FUNCTION public._conflito_comandante(p_vigilante_id uuid, p_escolta_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT o.codigo_escolta
  FROM public.escoltas alvo
  CROSS JOIN public.configuracoes_mural cfg
  JOIN public.escolta_efetivo ee ON ee.vigilante_id = p_vigilante_id AND ee.papel_na_escolta = 'comandante'
  JOIN public.escoltas o ON o.id = ee.escolta_id
  WHERE alvo.id = p_escolta_id AND cfg.id = 1
    AND o.id <> p_escolta_id AND o.status = 'agendada'
    AND o.arquivada_em IS NULL   -- onda I: escolta arquivada não conta
    AND abs(extract(epoch FROM (o.data_hora_prevista - alvo.data_hora_prevista))) < cfg.intervalo_comandante_h * 3600
  LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public._presenca_da_equipe(p_escolta_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT string_agg(v.nome_completo, ', ')
  FROM public.mural_presencas mp
  JOIN public.escolta_efetivo ee ON ee.escolta_id = mp.escolta_id AND ee.vigilante_id = mp.vigilante_id
  JOIN public.vigilantes v ON v.id = mp.vigilante_id
  WHERE mp.escolta_id = p_escolta_id
    AND mp.anulado_em IS NULL   -- onda I: presença anulada (zerar) não vale
$function$;

CREATE OR REPLACE FUNCTION public._executar_substituicao(p_pedido_id uuid, p_via text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  p public.mural_pedidos%ROWTYPE;
  e record; v_motivo text; v_ev uuid; v_acomp uuid; v_equipe_agora jsonb; v_presenca text; v_conflito text;
  v_nome text; v_aviso boolean;
BEGIN
  SELECT * INTO p FROM public.mural_pedidos WHERE id = p_pedido_id;
  IF p.id IS NULL OR p.status NOT IN ('aprovado', 'liberado_por_tempo') THEN
    RAISE EXCEPTION 'Pedido nao esta liberado para execucao.';
  END IF;
  SELECT id, status, escala_fixa, codigo_escolta, data_hora_prevista, arquivada_em INTO e FROM public.escoltas WHERE id = p.escolta_id;
  PERFORM public._travar_vigilante(p.solicitante_vigilante_id);
  v_equipe_agora := public._equipe_atual(p.escolta_id);
  v_presenca := CASE WHEN (SELECT presenca_ligada FROM public.configuracoes_mural WHERE id = 1)
                     THEN public._presenca_da_equipe(p.escolta_id) END;
  v_conflito := public._conflito_comandante(p.solicitante_vigilante_id, p.escolta_id);

  v_motivo := CASE
    WHEN e.arquivada_em IS NOT NULL THEN 'a escolta foi arquivada'   -- onda I
    WHEN e.status IS DISTINCT FROM 'agendada' THEN 'a escolta ja comecou ou foi encerrada'
    WHEN e.escala_fixa THEN 'a escolta passou a ser de escala fixa'
    WHEN now() < e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1))
      THEN 'a escolta foi remarcada e saiu da janela de substituicao'
    WHEN v_presenca IS NOT NULL THEN 'a equipe confirmou presenca na base (' || v_presenca || ')'
    WHEN public._ids_da_equipe(v_equipe_agora) IS DISTINCT FROM public._ids_da_equipe(p.equipe_antes) THEN 'a equipe da escolta mudou depois do pedido'
    WHEN v_conflito IS NOT NULL THEN 'o solicitante passou a comandar a escolta ' || v_conflito || ' a menos do intervalo minimo'
    WHEN NOT EXISTS (SELECT 1 FROM public.vigilantes v JOIN public.usuarios u ON u.id = v.usuario_id
                     WHERE v.id = p.solicitante_vigilante_id AND v.status = 'ativo' AND u.status = 'ativo') THEN 'o solicitante nao esta mais ativo'
    WHEN EXISTS (SELECT 1 FROM unnest(p.acompanhantes) a WHERE NOT EXISTS
                 (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN 'um acompanhante nao esta mais ativo'
    WHEN p.veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p.veiculo_id AND status = 'ativo') THEN 'a viatura indicada nao esta mais ativa'
    -- Onda G (210): a placa escolhida não pode estar em outra viatura da mesma escolta.
    WHEN p.veiculo_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p.escolta_id AND ev.veiculo_id = p.veiculo_id
              AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1))
      THEN 'a viatura indicada já está em outra viatura da escolta'
  END;

  -- Onda G (210): os índices únicos do efetivo e das viaturas recusam repetição. Se uma
  -- gravação esbarrar neles, a troca inteira é desfeita e o pedido é invalidado com o
  -- motivo, em vez de o erro técnico subir para quem aprovou ou para o cron.
  IF v_motivo IS NULL THEN
    BEGIN
      SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1;
      IF p.veiculo_id IS NOT NULL THEN
        UPDATE public.escolta_veiculos SET veiculo_id = p.veiculo_id, atualizado_em = now(), atualizado_por = p.solicitante_usuario_id
         WHERE id = v_ev;
      END IF;
      DELETE FROM public.escolta_efetivo WHERE escolta_id = p.escolta_id;
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p.escolta_id, v_ev, p.solicitante_vigilante_id, 'comandante', true, p.solicitante_usuario_id);
      FOREACH v_acomp IN ARRAY p.acompanhantes LOOP
        IF v_acomp IS DISTINCT FROM p.solicitante_vigilante_id THEN
          INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
          VALUES (p.escolta_id, v_ev, v_acomp, 'operador', false, p.solicitante_usuario_id) ON CONFLICT DO NOTHING;
        END IF;
      END LOOP;
    EXCEPTION WHEN unique_violation THEN
      v_motivo := 'a viatura ou um vigilante indicado já está na escolta';
    END;
  END IF;

  IF v_motivo IS NOT NULL THEN
    UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = coalesce(decidido_em, now()),
           observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: ' || v_motivo || '.')
     WHERE id = p.id;
    INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
    VALUES (p.decidido_por, 'pedido_substituicao_invalidado', 'escoltas', p.escolta_id, jsonb_build_object('pedido_id', p.id),
            jsonb_build_object('pedido_id', p.id, 'via', p_via, 'motivo', v_motivo), now());
    PERFORM public._avisar_app(p.escolta_id, 'decisao_substituicao', ARRAY[p.solicitante_usuario_id],
      'Pedido de substituição invalidado', 'O pedido para a escolta ' || e.codigo_escolta || ' não foi executado: ' || v_motivo || '.', p.id);
    RETURN false;
  END IF;

  SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = p.solicitante_vigilante_id;
  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES (p.solicitante_usuario_id, 'substituicao_de_equipe', 'escoltas', p.escolta_id,
          jsonb_build_object('equipe', p.equipe_antes),
          jsonb_build_object('pedido_id', p.id, 'via', p_via, 'assumida_por', v_nome, 'motivo', p.motivo,
                             'acompanhantes', (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (p.acompanhantes)),
                             'trocou_viatura', p.veiculo_id IS NOT NULL,
                             'decidido_por', (SELECT nome_completo FROM public.usuarios WHERE id = p.decidido_por)),
          now());

  PERFORM public._avisar_app(p.escolta_id, 'substituicao_equipe',
    public._usuarios_dos_vigilantes(public._ids_da_equipe(p.equipe_antes)) || public._supervisao_ids() || ARRAY[p.solicitante_usuario_id],
    'Equipe substituída na escolta ' || e.codigo_escolta,
    v_nome || ' assumiu a escolta em ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo, sem resposta da supervisão)' ELSE ' (aprovado pela supervisão)' END
      || '. Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes) || '. Motivo: ' || p.motivo,
    p.id);
  v_aviso := public._enfileirar_aviso('substituicao:' || p.id, 'central', p.escolta_id,
    public._texto_aviso_mural('Equipe substituída', p.escolta_id, ARRAY[
      'Assumiu: ' || v_nome,
      'Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes),
      'Quando: ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo)' ELSE ' (aprovado)' END,
      'Motivo: ' || p.motivo]));
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[] DEFAULT '{}'::uuid[], p_veiculo_id uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_perfil text; v_usuario uuid; v_vigilante uuid; e record; cfg record; v_qtd int; v_ev uuid; v_acomp uuid;
  v_conflito text; v_presenca text; v_ped record; v_equipe jsonb; v_nome text; v_aviso boolean; v_inicio timestamptz;
  v_acomp_limpo uuid[];
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo. Fale com o administrador.';
  END IF;

  -- Trava a linha: duas pessoas assumindo ao mesmo tempo produziriam duas equipes.
  SELECT id, status, escala_fixa, data_hora_prevista, codigo_escolta, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  IF e.status <> 'agendada' THEN
    RAISE EXCEPTION 'Esta escolta ja comecou e nao pode ter a equipe trocada. Fale com o supervisor.';
  END IF;
  IF e.escala_fixa THEN
    RAISE EXCEPTION 'Escolta de escala fixa: a equipe e definida pela supervisao.';
  END IF;
  PERFORM public._travar_vigilante(v_vigilante);

  v_acomp_limpo := ARRAY(SELECT DISTINCT a FROM unnest(coalesce(p_acompanhantes, '{}')) a WHERE a IS DISTINCT FROM v_vigilante);
  IF EXISTS (SELECT 1 FROM unnest(v_acomp_limpo) a WHERE NOT EXISTS
             (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN
    RAISE EXCEPTION 'Acompanhante invalido ou inativo.';
  END IF;
  IF p_veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p_veiculo_id AND status = 'ativo') THEN
    RAISE EXCEPTION 'Viatura invalida ou fora de operacao.';
  END IF;
  -- Onda G (210): a placa escolhida troca a primeira viatura; não pode ser a de outra
  -- viatura da mesma escolta.
  IF p_veiculo_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_escolta_id AND ev.veiculo_id = p_veiculo_id
          AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1)) THEN
    RAISE EXCEPTION 'Esta viatura já está em outra viatura desta escolta. Escolha outra placa ou mantenha a atual.';
  END IF;

  SELECT * INTO cfg FROM public.configuracoes_mural WHERE id = 1;
  SELECT count(*) INTO v_qtd FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = v_vigilante;

  -- Escolta sem equipe: assume na hora, como antes, com T5.
  IF v_qtd = 0 THEN
    v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
    IF v_conflito IS NOT NULL THEN
      RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
    END IF;
    SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
    IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
    BEGIN
      IF p_veiculo_id IS NOT NULL THEN
        UPDATE public.escolta_veiculos SET veiculo_id = p_veiculo_id, atualizado_em = now(), atualizado_por = v_usuario WHERE id = v_ev;
      END IF;
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
      FOREACH v_acomp IN ARRAY v_acomp_limpo LOOP
        INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
        VALUES (p_escolta_id, v_ev, v_acomp, 'operador', false, v_usuario) ON CONFLICT DO NOTHING;
      END LOOP;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'A viatura ou um vigilante escolhido já está nesta escolta. Revise a equipe e a viatura e tente de novo.';
    END;
    PERFORM public._auditar_mural('assumiu_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
      jsonb_build_object('assumida_por', v_nome, 'acompanhantes',
        (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (v_acomp_limpo)),
        'trocou_viatura', p_veiculo_id IS NOT NULL));
    RETURN jsonb_build_object('ok', true, 'status', 'assumida', 'substituiu_equipe', false);
  END IF;

  -- Escolta com equipe: vira pedido, dentro das travas.
  IF EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
    RAISE EXCEPTION 'Voce ja esta na equipe desta escolta.';
  END IF;
  IF p_motivo IS NULL OR length(trim(p_motivo)) < 20 THEN
    RAISE EXCEPTION 'Informe o motivo da substituicao com pelo menos 20 caracteres.';
  END IF;
  IF length(trim(p_motivo)) > 500 THEN
    RAISE EXCEPTION 'O motivo pode ter no maximo 500 caracteres.';
  END IF;
  v_inicio := e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min);
  IF now() < v_inicio THEN
    RAISE EXCEPTION 'Substituicao de equipe liberada a partir de % (horario de Brasilia).', public._hora_br(v_inicio);
  END IF;
  IF cfg.presenca_ligada THEN
    v_presenca := public._presenca_da_equipe(p_escolta_id);
    IF v_presenca IS NOT NULL THEN
      RAISE EXCEPTION 'A equipe escalada ja confirmou presenca na base. Fale com o supervisor.';
    END IF;
  END IF;
  v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
  IF v_conflito IS NOT NULL THEN
    RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
  END IF;

  SELECT id, solicitante_usuario_id, expira_em INTO v_ped FROM public.mural_pedidos
  WHERE escolta_id = p_escolta_id AND status = 'pendente' FOR UPDATE;
  IF v_ped.id IS NOT NULL THEN
    IF v_ped.solicitante_usuario_id = v_usuario THEN
      RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em, 'ja_existia', true);
    END IF;
    RAISE EXCEPTION 'Ja existe um pedido de substituicao em analise para esta escolta.';
  END IF;

  v_equipe := public._equipe_atual(p_escolta_id);
  INSERT INTO public.mural_pedidos (escolta_id, solicitante_usuario_id, solicitante_vigilante_id, acompanhantes, veiculo_id,
                                    motivo, equipe_antes, expira_em, antecedencia_min)
  VALUES (p_escolta_id, v_usuario, v_vigilante, v_acomp_limpo, p_veiculo_id, trim(p_motivo), v_equipe,
          now() + make_interval(mins => cfg.aprovacao_tempo_limite_min),
          round(extract(epoch FROM (e.data_hora_prevista - now())) / 60)::int)
  RETURNING id, expira_em INTO v_ped;

  PERFORM public._auditar_mural('pedido_substituicao', p_escolta_id, jsonb_build_object('equipe', v_equipe),
    jsonb_build_object('pedido_id', v_ped.id, 'solicitante', v_nome, 'motivo', trim(p_motivo), 'expira_em', v_ped.expira_em));
  PERFORM public._avisar_app(p_escolta_id, 'pedido_substituicao', public._supervisao_ids(),
    'Pedido de substituição na escolta ' || e.codigo_escolta,
    v_nome || ' pediu para assumir. Equipe atual: ' || public._nomes_da_equipe(v_equipe) || '. Motivo: ' || trim(p_motivo)
      || '. Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.', v_ped.id);
  v_aviso := public._enfileirar_aviso('pedido:' || v_ped.id, 'central', p_escolta_id,
    public._texto_aviso_mural('Pedido de substituição de equipe', p_escolta_id, ARRAY[
      'Solicitante: ' || v_nome,
      'Equipe atual: ' || public._nomes_da_equipe(v_equipe),
      'Motivo: ' || trim(p_motivo),
      'Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.']));
  RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em,
                            'aviso_pelo_banco', v_aviso, 'codigo', e.codigo_escolta, 'equipe_atual', public._nomes_da_equipe(v_equipe));
END;
$function$;

CREATE OR REPLACE FUNCTION public.puxar_escolta(p_escolta_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_ev uuid; v_ja int; v_conflito text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo. Fale com o administrador.';
  END IF;
  -- Trava a linha: sem isto, dois operadores puxam a mesma escolta no mesmo instante.
  SELECT id, status, escala_fixa, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'Esta escolta nao esta mais disponivel: ela ja saiu do mural.'; END IF;
  IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: a equipe e definida pela supervisao.'; END IF;
  PERFORM public._travar_vigilante(v_vigilante);
  SELECT count(*) INTO v_ja FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  IF v_ja > 0 THEN RAISE EXCEPTION 'Esta escolta ja tem equipe designada.'; END IF;
  v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
  IF v_conflito IS NOT NULL THEN
    RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito,
      (SELECT intervalo_comandante_h FROM public.configuracoes_mural WHERE id = 1);
  END IF;
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
  INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
  PERFORM public._auditar_mural('puxou_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
    jsonb_build_object('assumida_por', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante)));
  RETURN jsonb_build_object('ok', true, 'escolta_veiculo_id', v_ev);
END;
$function$;

CREATE OR REPLACE FUNCTION public.devolver_escolta(p_escolta_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_vigilante uuid; e record; v_sou_cmd int; v_equipe jsonb; v_gestao boolean;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_vigilante := public.get_meu_vigilante_id();
  v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
  SELECT id, status, escala_fixa, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  -- So devolve enquanto nao comecou. Depois de iniciada, sair da escolta e decisao de supervisor.
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta ja comecou. Fale com o supervisor para sair dela.'; END IF;
  IF NOT v_gestao THEN
    IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: so a supervisao altera a equipe.'; END IF;
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante devolve a escolta ao mural.'; END IF;
  END IF;
  v_equipe := public._equipe_atual(p_escolta_id);
  DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  DELETE FROM public.mural_presencas WHERE escolta_id = p_escolta_id;
  PERFORM public._auditar_mural('devolveu_escolta_ao_mural', p_escolta_id, jsonb_build_object('equipe', v_equipe), '{"equipe": []}'::jsonb);
  -- Quem saiu junto (acompanhantes) fica sabendo pelo aplicativo.
  PERFORM public._avisar_app(p_escolta_id, 'substituicao_equipe',
    ARRAY(SELECT u FROM unnest(public._usuarios_dos_vigilantes(public._ids_da_equipe(v_equipe))) u WHERE u IS DISTINCT FROM public.get_meu_usuario_id()),
    'Escolta devolvida ao mural', 'A escolta ' || (SELECT codigo_escolta FROM public.escoltas WHERE id = p_escolta_id)
      || ' foi devolvida ao mural em ' || public._hora_br(now()) || '. Você não está mais escalado nela.', NULL);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.incluir_vigilante_na_minha_escolta(p_escolta_id uuid, p_vigilante_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_sou_cmd int; v_ev uuid; v_dup int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  SELECT id, status, escala_fixa, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta ja comecou. Alteracao de equipe passa pelo supervisor.'; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') THEN
    IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: so a supervisao altera a equipe.'; END IF;
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante inclui vigilante nesta escolta.'; END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vigilantes WHERE id = p_vigilante_id AND status = 'ativo') THEN
    RAISE EXCEPTION 'Vigilante invalido ou inativo.';
  END IF;
  SELECT count(*) INTO v_dup FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = p_vigilante_id;
  IF v_dup > 0 THEN RAISE EXCEPTION 'Este vigilante ja esta na escolta.'; END IF;
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada.'; END IF;
  BEGIN
    INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
    VALUES (p_escolta_id, v_ev, p_vigilante_id, 'operador', false, v_usuario);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Este vigilante ja esta na escolta.';
  END;
  PERFORM public._auditar_mural('incluiu_vigilante', p_escolta_id, '{}'::jsonb,
    jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = p_vigilante_id)));
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.confirmar_presenca_base(p_escolta_id uuid, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_precisao numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_inicio timestamptz; v_ped uuid;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo.'; END IF;
  SELECT id, status, data_hora_prevista, codigo_escolta, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A presenca na base so e confirmada antes do inicio da escolta.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
    RAISE EXCEPTION 'Voce nao esta na equipe desta escolta.';
  END IF;
  v_inicio := e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1));
  IF now() < v_inicio THEN
    RAISE EXCEPTION 'A confirmacao de presenca abre as % (horario de Brasilia).', public._hora_br(v_inicio);
  END IF;
  INSERT INTO public.mural_presencas (escolta_id, vigilante_id, usuario_id, latitude, longitude, precisao_metros, sem_gps)
  VALUES (p_escolta_id, v_vigilante, v_usuario, p_lat, p_lng, p_precisao, p_lat IS NULL OR p_lng IS NULL)
  ON CONFLICT (escolta_id, vigilante_id) WHERE anulado_em IS NULL DO NOTHING;   -- onda I: a anulada não impede confirmar de novo
  PERFORM public._auditar_mural('presenca_na_base', p_escolta_id, '{}'::jsonb,
    jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante),
                       'latitude', p_lat, 'longitude', p_lng, 'precisao_metros', p_precisao));
  -- Pedido pendente perde o objeto: a equipe chegou.
  UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
         observacao_decisao = 'Invalidado: a equipe confirmou presenca na base.'
   WHERE escolta_id = p_escolta_id AND status = 'pendente'
  RETURNING id INTO v_ped;
  IF v_ped IS NOT NULL THEN
    PERFORM public._avisar_app(p_escolta_id, 'decisao_substituicao',
      ARRAY[(SELECT solicitante_usuario_id FROM public.mural_pedidos WHERE id = v_ped)],
      'Pedido de substituição invalidado', 'A equipe da escolta ' || e.codigo_escolta || ' confirmou presença na base.', v_ped);
  END IF;
  RETURN jsonb_build_object('ok', true, 'confirmado_em', now());
END;
$function$;

CREATE OR REPLACE FUNCTION public.listar_pedidos_mural(p_desde timestamp with time zone DEFAULT (now() - '30 days'::interval))
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  PERFORM public.processar_pedidos_vencidos();
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'escolta_id', p.escolta_id, 'codigo', e.codigo_escolta, 'cliente', c.nome_cliente,
           'data_hora_prevista', e.data_hora_prevista, 'solicitante', sv.nome_completo, 'solicitante_usuario_id', p.solicitante_usuario_id,
           'equipe_antes', public._nomes_da_equipe(p.equipe_antes), 'motivo', p.motivo, 'status', p.status,
           'criado_em', p.criado_em, 'expira_em', p.expira_em, 'antecedencia_min', p.antecedencia_min,
           'decidido_por', du.nome_completo, 'decidido_em', p.decidido_em, 'observacao_decisao', p.observacao_decisao)
         ORDER BY p.criado_em DESC), '[]'::jsonb) INTO v
  FROM public.mural_pedidos p
  JOIN public.escoltas e ON e.id = p.escolta_id
  JOIN public.clientes c ON c.id = e.cliente_id
  JOIN public.vigilantes sv ON sv.id = p.solicitante_vigilante_id
  LEFT JOIN public.usuarios du ON du.id = p.decidido_por
  WHERE p.criado_em >= p_desde
    AND e.arquivada_em IS NULL   -- onda I
    AND (v_perfil IN ('administrador', 'gestor', 'supervisor') OR p.solicitante_usuario_id = v_usuario);
  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mural_info(p_escolta_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; v jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  PERFORM public.processar_pedidos_vencidos();
  SELECT coalesce(jsonb_object_agg(e.id, jsonb_build_object(
           'janela_inicio', e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min),
           'escala_fixa', e.escala_fixa,
           -- O operador não lê o efetivo dos colegas pela RLS; sem isto a tela via toda
           -- escolta agendada como "sem equipe".
           'tem_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id),
           -- Nomes só para a gestão e para a própria equipe (a RLS de mural_presencas é assim).
           'presenca', CASE WHEN public._presenca_da_equipe(e.id) IS NULL THEN NULL
                            WHEN v_perfil IN ('administrador', 'gestor', 'supervisor', 'central')
                              OR EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante)
                            THEN public._presenca_da_equipe(e.id) ELSE 'sim' END,
           'eu_confirmei', EXISTS (SELECT 1 FROM public.mural_presencas mp WHERE mp.escolta_id = e.id AND mp.vigilante_id = v_vigilante AND mp.anulado_em IS NULL),
           'sou_da_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante),
           'pedido', (SELECT jsonb_build_object('id', p.id, 'expira_em', p.expira_em, 'meu', p.solicitante_usuario_id = v_usuario)
                      FROM public.mural_pedidos p WHERE p.escolta_id = e.id AND p.status = 'pendente'))), '{}'::jsonb)
    INTO v
  FROM public.escoltas e CROSS JOIN public.configuracoes_mural cfg
  WHERE e.id = ANY (p_escolta_ids) AND cfg.id = 1 AND e.status = 'agendada' AND e.arquivada_em IS NULL;
  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enviar_avisos_telegram()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r record; v_token text; v_central text; v_base text; v_chat text; v_req bigint; n int := 0;
BEGIN
  IF NOT public.avisos_pelo_banco_ativos() THEN RETURN 0; END IF;
  -- Onda I: aviso pendente de escolta arquivada, gravado antes do arquivamento, não sai
  -- (o aviso do próprio arquivamento nasce na mesma transação e sai).
  UPDATE public.avisos_telegram a SET situacao = 'erro', erro = 'Não enviado: escolta arquivada.'
    FROM public.escoltas e
   WHERE e.id = a.escolta_id AND a.situacao = 'pendente' AND e.arquivada_em IS NOT NULL AND a.criado_em < e.arquivada_em;
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
$function$;

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
  IF v_status IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
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
      RAISE EXCEPTION 'Ponto de controle de viatura que nao pertence a esta escolta.';
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

-- Privilégios das recriadas (CREATE OR REPLACE mantém os anteriores; repetidos por clareza).
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['_conflito_comandante(uuid, uuid)', '_presenca_da_equipe(uuid)', '_executar_substituicao(uuid, text)',
                           'enviar_avisos_telegram()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['assumir_escolta(uuid, uuid[], uuid, text)', 'puxar_escolta(uuid)', 'devolver_escolta(uuid)',
                           'incluir_vigilante_na_minha_escolta(uuid, uuid)', 'confirmar_presenca_base(uuid, numeric, numeric, numeric)',
                           'listar_pedidos_mural(timestamptz)', 'mural_info(uuid[])',
                           'registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- Conferência (funções reescritas em cadeia, docs/14 18.4):
-- SELECT prosrc LIKE '%anulado_em IS NULL%' AND prosrc LIKE '%arquivada%' AND prosrc LIKE '%historico_rpc%'
--   FROM pg_proc WHERE proname = 'registrar_etapa_escolta';                                   -- true
-- SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('editar_escolta',
--   'pendencias_da_escolta','concluir_escolta_antecipada','voltar_etapa_escolta','zerar_escolta','arquivar_escolta','recuperar_escolta');  -- 7
-- SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace
--   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));   -- 0
