-- 223_concorrencia.sql
-- Pedido de Peçanha em 2026-11-12: várias pessoas (gestão, central, supervisor, operador em
-- campo) mexem na mesma escolta ao mesmo tempo. Quando a ação de uma delas é recusada porque
-- outra alterou a escolta antes, a tela precisa dizer QUEM alterou, O QUÊ e QUANDO, em vez de
-- "a etapa já foi avançada em outra tela". E a página de detalhe passa a se atualizar sozinha
-- quando outra pessoa altera a escolta (Realtime). Idempotente. Depois da 222.
--
-- Só leitura e configuração: NENHUMA RPC existente muda de corpo, nenhuma política RLS muda,
-- nenhuma coluna é criada. O código da tela funciona sem esta migration (cai na mensagem com o
-- histórico lido direto, ou na mensagem genérica) e passa a usar a função quando ela existir.
--
-- O que faz:
-- 1. public.ultima_alteracao_escolta(p_escolta_id): devolve a última alteração da escolta
--    (quem, perfil, o quê, quando) num jsonb. Fontes, nesta ordem de precedência:
--    - logs_auditoria (entidade 'escoltas'): as ações da gestão (voltar etapa, zerar, concluir
--      antes, arquivar, recuperar, editar, cancelar pela gestão, excluir, restaurar, lançamento
--      retroativo) e as do mural (assumir, puxar, devolver, incluir vigilante, presença);
--    - escolta_status_historico: toda mudança de status (avanço de etapa pelo campo, pela
--      central ou pela gestão; cancelamento; reagendamento).
--    Vale a mais recente pelo horário do servidor (registrado_em da 222 quando houver, senão
--    data_hora; assim o lançamento retroativo conta pela hora em que foi lançado, não pela
--    hora operacional informada). Empate (a RPC da gestão grava as duas na mesma transação,
--    com o mesmo now()): vale a auditoria, que descreve a ação com mais precisão.
--    escoltas.atualizado_por NÃO é usada: não é preenchida de forma confiável (só a trigger de
--    atualizado_em roda em todo UPDATE), e apontaria a pessoa errada.
--    Quem pode ler: o mesmo recorte da RLS de SELECT de escoltas (133 e 221), sem a exceção do
--    mural: gestão, supervisão e central, ou quem é do efetivo da escolta. Arquivada só para
--    administrador e gestor; excluída para ninguém. Fora disso, devolve NULL (não um erro, para
--    a tela cair na mensagem genérica sem barulho). Sem perfil ativo: 'Permissão negada.'.
-- 2. Índice em logs_auditoria (registro_id, data_hora DESC), para a leitura acima não varrer
--    a auditoria inteira a cada conflito.
-- 3. Realtime: escoltas, escolta_status_historico e pontos_controle na publicação
--    supabase_realtime, se ainda não estiverem (confere pg_publication_tables antes; sem a
--    publicação, como num Postgres local, não faz nada). O Realtime entrega a linha só a quem
--    a RLS de SELECT da tabela deixa ver (escoltas_select, historico_select, pontos_select e
--    pontos_select_mesma_escolta): gestão, supervisão, central e o efetivo da escolta. Nenhuma
--    política é afrouxada. A presença na página (quem está com a escolta aberta) usa o
--    Presence do Realtime, que não depende de tabela nem de migration.
--
-- Não muda: registrar_etapa_escolta, voltar_etapa_escolta, zerar_escolta,
-- lancar_escolta_retroativa, as demais RPCs e as políticas RLS. O texto das recusas continua
-- igual; a tela é que lê a última alteração depois de uma recusa de conflito.
-- Reversão: 223_concorrencia_reverter.sql.

-- ── 1. Texto da ação de auditoria (interna) ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION lote_interno.texto_acao_escolta(p_acao text, p_depois jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT CASE p_acao
    WHEN 'VOLTAR_ETAPA' THEN 'etapa voltada para ' || lote_interno.rotulo_status(coalesce(p_depois ->> 'status', ''))
    WHEN 'ZERAR_ESCOLTA' THEN 'escolta zerada para Agendada'
    WHEN 'CONCLUSAO_ANTECIPADA' THEN 'escolta concluída antes do fim'
    WHEN 'ARQUIVAR_ESCOLTA' THEN 'escolta arquivada'
    WHEN 'RECUPERAR_ESCOLTA' THEN 'escolta recuperada do arquivo'
    WHEN 'EDITAR_ESCOLTA' THEN 'dados da escolta editados'
    WHEN 'CANCELAR_ESCOLTA_GESTAO' THEN 'escolta cancelada pela gestão'
    WHEN 'EXCLUIR_ESCOLTA' THEN 'escolta excluída'
    WHEN 'RESTAURAR_ESCOLTA_EXCLUIDA' THEN 'escolta restaurada'
    WHEN 'LANCAMENTO_RETROATIVO' THEN 'etapas lançadas depois do fato até Finalizada'
    WHEN 'assumiu_escolta_do_mural' THEN 'escolta assumida pelo mural'
    WHEN 'puxou_escolta_do_mural' THEN 'escolta puxada do mural'
    WHEN 'devolveu_escolta_ao_mural' THEN 'escolta devolvida ao mural'
    WHEN 'incluiu_vigilante' THEN 'vigilante incluído na equipe'
    WHEN 'presenca_na_base' THEN 'presença na base confirmada'
    WHEN 'pedido_substituicao' THEN 'pedido de substituição registrado'
    WHEN 'pedido_substituicao_aprovado' THEN 'pedido de substituição aprovado'
    WHEN 'pedido_substituicao_recusado' THEN 'pedido de substituição recusado'
    WHEN 'pedido_substituicao_cancelado' THEN 'pedido de substituição cancelado'
    ELSE 'escolta alterada' END
$$;
REVOKE ALL ON FUNCTION lote_interno.texto_acao_escolta(text, jsonb) FROM PUBLIC, anon, authenticated;

-- Texto de uma linha do histórico de status (interna).
CREATE OR REPLACE FUNCTION lote_interno.texto_mudanca_status(p_de text, p_para text, p_observacao text, p_retroativo boolean)
    RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT CASE
    WHEN p_para = 'cancelada' THEN 'escolta cancelada'
    WHEN coalesce(p_observacao, '') LIKE 'Zerada pela gestão:%' THEN 'escolta zerada para Agendada'
    WHEN coalesce(p_observacao, '') LIKE 'Reset:%' THEN 'etapa voltada para ' || lote_interno.rotulo_status(p_para)
    WHEN coalesce(p_observacao, '') LIKE 'Reagendamento%' THEN 'escolta reagendada'
    WHEN coalesce(array_position(lote_interno.sequencia_status(), p_para), 0)
         > coalesce(array_position(lote_interno.sequencia_status(), p_de), 0)
      THEN 'etapa avançada para ' || lote_interno.rotulo_status(p_para)
           || CASE WHEN p_retroativo THEN ' (lançamento retroativo)' ELSE '' END
    ELSE 'status alterado de ' || lote_interno.rotulo_status(coalesce(p_de, '')) || ' para ' || lote_interno.rotulo_status(p_para)
  END
$$;
REVOKE ALL ON FUNCTION lote_interno.texto_mudanca_status(text, text, text, boolean) FROM PUBLIC, anon, authenticated;

-- ── 2. Leitura da última alteração (RPC) ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ultima_alteracao_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text := public.get_meu_perfil();
  v_eu uuid := public.get_meu_usuario_id();
  e jsonb;
  h record; a record;
  v_h_quando timestamptz; v_quem uuid; v_quando timestamptz; v_oque text; v_fonte text;
  v_nome text; v_perfil_nome text; v_perfil_codigo text;
BEGIN
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Permissão negada.' USING ERRCODE = '42501'; END IF;

  -- to_jsonb: arquivada_em (213) e excluida_em (221) lidas sem depender de a coluna existir.
  SELECT to_jsonb(x) INTO e FROM public.escoltas x WHERE x.id = p_escolta_id;
  IF e IS NULL THEN RETURN NULL; END IF;
  -- O recorte da RLS de SELECT de escoltas, sem a exceção do mural (agendada para todos).
  IF NOT (v_perfil IN ('administrador', 'gestor', 'supervisor', 'central') OR public.sou_do_efetivo(p_escolta_id)) THEN
    RETURN NULL;
  END IF;
  IF (e ->> 'excluida_em') IS NOT NULL THEN RETURN NULL; END IF;
  IF (e ->> 'arquivada_em') IS NOT NULL AND v_perfil NOT IN ('administrador', 'gestor') THEN RETURN NULL; END IF;

  -- Última linha do histórico, pelo horário do servidor (registrado_em da 222, se houver).
  SELECT x.status_anterior, x.status_novo, x.alterado_por, x.observacao,
         coalesce((to_jsonb(x) ->> 'registrado_em')::timestamptz, x.data_hora) AS quando,
         coalesce((to_jsonb(x) ->> 'retroativo')::boolean, false) AS retroativo
    INTO h
    FROM public.escolta_status_historico x
   WHERE x.escolta_id = p_escolta_id
   ORDER BY coalesce((to_jsonb(x) ->> 'registrado_em')::timestamptz, x.data_hora) DESC
   LIMIT 1;
  v_h_quando := h.quando;

  SELECT l.usuario_id, l.acao, l.dados_depois, l.data_hora INTO a
    FROM public.logs_auditoria l
   WHERE l.registro_id = p_escolta_id AND l.entidade_afetada = 'escoltas'
   ORDER BY l.data_hora DESC
   LIMIT 1;

  IF a.data_hora IS NOT NULL AND (v_h_quando IS NULL OR a.data_hora >= v_h_quando) THEN
    v_quem := a.usuario_id; v_quando := a.data_hora; v_fonte := 'auditoria';
    v_oque := lote_interno.texto_acao_escolta(a.acao, a.dados_depois);
  ELSIF v_h_quando IS NOT NULL THEN
    v_quem := h.alterado_por; v_quando := v_h_quando; v_fonte := 'historico';
    v_oque := lote_interno.texto_mudanca_status(h.status_anterior, h.status_novo, h.observacao, h.retroativo);
  END IF;

  IF v_quem IS NOT NULL THEN
    SELECT u.nome_completo, dp.nome_exibicao, dp.codigo INTO v_nome, v_perfil_nome, v_perfil_codigo
      FROM public.usuarios u LEFT JOIN public.dom_perfis dp ON dp.id = u.perfil_id
     WHERE u.id = v_quem;
  END IF;

  RETURN jsonb_build_object(
    'escolta_id', p_escolta_id,
    'status', e ->> 'status',
    'versao_gestao', (e ->> 'versao_gestao')::int,
    'quem_id', v_quem,
    'quem_nome', v_nome,
    'perfil', v_perfil_nome,
    'perfil_codigo', v_perfil_codigo,
    'eu', v_quem IS NOT NULL AND v_quem = v_eu,
    'o_que', v_oque,
    'quando', v_quando,
    'fonte', v_fonte);
END;
$$;
REVOKE ALL ON FUNCTION public.ultima_alteracao_escolta(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ultima_alteracao_escolta(uuid) TO authenticated;
COMMENT ON FUNCTION public.ultima_alteracao_escolta(uuid) IS
  '223: última alteração da escolta (quem, perfil, o quê, quando) para a mensagem de conflito e o aviso de atualização da tela. Só leitura.';

-- ── 3. Índice da auditoria por escolta ───────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS logs_auditoria_registro_data_idx ON public.logs_auditoria (registro_id, data_hora DESC);

-- ── 4. Realtime ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    RAISE NOTICE 'Publicação supabase_realtime ausente: Realtime não configurado aqui.';
    RETURN;
  END IF;
  FOREACH t IN ARRAY ARRAY['escoltas', 'escolta_status_historico', 'pontos_controle'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END $$;

-- Conferência rápida: database/testes/06_concorrencia_conferencia.sql (uma linha, tudo true).
