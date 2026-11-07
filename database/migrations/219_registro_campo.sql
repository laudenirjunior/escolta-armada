-- 219_registro_campo.sql
-- Lote 2026-10, onda L (adendo 01, item 4.7): operação de campo sem internet. Idempotente.
-- BLOCO 2: aplicar logo depois do deploy, depois da 218 (usa versao_gestao e arquivada_em da
-- 213, a trava de colunas da 214, a registrar_etapa_escolta da 218 e lote_interno.notificar
-- da 211). Reversão: 219_registro_campo_reverter.sql (só depois de todos os aparelhos que
-- informaram nos últimos 7 dias estarem com zero pendentes; docs/14, seção 16.5).
--
-- Por quê (docs/14, seções 16.1, 16.2 e 18.8; decisões S11, S12 e S13): o operador segue
-- registrando sem sinal; o aparelho guarda cada registro com um identificador único
-- (client_id) e o manda quando a conexão volta. O servidor precisa (a) aplicar cada registro
-- uma única vez, (b) guardar a hora da ação e a do envio, (c) nunca descartar um registro que
-- não pode mais ser aplicado (conflito, visível à supervisão), (d) não dar privilégio novo a
-- ninguém: as gravações rodam com a RLS e as triggers de quem chama.
--
-- O que faz:
-- 1. registros_campo (livro: idempotência, resultado e conflitos). RLS ligada; SELECT do
--    próprio ou da gestão (G4: administrador, gestor, supervisor, central) e só nas colunas
--    liberadas (motivo_detalhe fica de fora: GRANT por coluna, lido pela listar_conflitos);
--    nenhuma escrita direta. escolta_id sem chave estrangeira (o caso escolta_apagada depende
--    disso); o código da escolta fica gravado para a tela de conflitos.
-- 2. registros_campo_aparelhos: cada envio informa quantos registros ainda estão no aparelho
--    (informar_pendentes); usado para decidir a reversão.
-- 3. escolta_efetivo_saidas, gravada por trigger SECURITY DEFINER (AFTER DELETE e AFTER
--    UPDATE OF vigilante_id em escolta_efetivo, inclusive na cascata de uma escolta apagada;
--    uma BEFORE DELETE em escoltas grava a saída com o código da escolta apagada). escolta_id sem FK.
-- 4. lote_interno.livro_registrar e lote_interno.livro_resultado (SECURITY DEFINER, EXECUTE só
--    para authenticated, porque a registrar_campo é INVOKER e precisa chamá-las; USAGE no
--    schema lote_interno para authenticated; todas as outras funções do schema continuam sem
--    EXECUTE para ninguém). Conferem usuario_id = get_meu_usuario_id(). Vínculo: atual
--    (efetivo ou G4) segue para a gravação; perdido (saída registrada, escolta arquivada ou
--    apagada) vira conflito com motivo sem_acesso e o detalhe em motivo_detalhe; quem nunca
--    teve vínculo nem é G4 recebe SEM_VINCULO e nada é gravado nem avisado.
-- 5. registrar_campo (SECURITY INVOKER): envelope de transporte (S11). Ramos estáticos por
--    tabela (fotos, pontos_controle, checklists, checklist_respostas, ocorrencias,
--    emergencias e o KM de escolta_veiculos), lista fechada de colunas escrita aqui, sem SQL
--    dinâmico; FOR UPDATE na escolta antes de conferir; regras de conflito da 16.2.5
--    (versao_gestao, status, finalizada ou cancelada, viatura removida, ponto de etapa
--    repetido, recusa de RLS ou trigger); emergência nunca vira conflito por status nem por
--    versão; gravação numa subtransação; a etapa pela registrar_etapa_escolta com a hora da
--    ação no histórico e a presença na base pela confirmar_presenca_base.
-- 6. Avisos de conflito (lote_interno.avisar_conflito, chamada por livro_resultado): Central
--    da supervisão (tipo conflito_offline, chave conflito:<client_id>) e fila do Telegram
--    (mesma chave), no máximo 5 por usuário a cada 10 minutos (os demais ficam no livro e na
--    tela). Emergência em conflito: o primeiro aviso na hora; os seguintes da mesma pessoa e
--    escolta somados num único aviso, fechado pelo cron de minuto da 212
--    (lote_interno.fechar_avisos_agrupados). Escolta apagada: notificacoes.escolta_id é NOT
--    NULL (onda J), então o aviso vai só pela fila do Telegram (escolta_id nulo) e pela tela de
--    conflitos (listar_conflitos); decisão registrada em portoes.md e no docs/03.
-- 7. tratar_conflito e listar_conflitos (supervisor ou acima), reservar_aviso_campo (Telegram
--    do registro aplicado, uma vez, chave campo:<client_id>, padrão da 208), config_offline e
--    informar_pendentes.
-- 8. registrar_etapa_escolta (207, 214, 218): mesma assinatura; a hora do histórico passa a
--    vir da variável de transação escolta.data_hora_acao (ligada só pela registrar_campo;
--    sem ela, now(), como antes) e o ponto aceita o id vindo do aparelho.
-- 9. configuracao_avisos.offline_ligado (chave de liga e desliga, lida pelo app por
--    config_offline) e telefone_central (botão de ligar da emergência offline).

-- ── 1. Configuração ──────────────────────────────────────────────────────────────────
ALTER TABLE public.configuracao_avisos
  ADD COLUMN IF NOT EXISTS offline_ligado   boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS telefone_central text;
COMMENT ON COLUMN public.configuracao_avisos.offline_ligado IS
  'Lote 2026-10 (onda L): false = o app grava direto, como antes, e continua esvaziando a fila que já existir no aparelho.';
COMMENT ON COLUMN public.configuracao_avisos.telefone_central IS
  'Lote 2026-10 (onda L): número do botão "Ligar para a central" na emergência sem conexão. Nulo: só o texto.';

-- ── 2. Tabelas ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.registros_campo (
  client_id                uuid PRIMARY KEY,
  usuario_id               uuid NOT NULL REFERENCES public.usuarios(id),
  auth_user_id             uuid NOT NULL,
  escolta_id               uuid NOT NULL,           -- sem FK de propósito (escolta_apagada)
  escolta_codigo           text,
  escolta_veiculo_id       uuid,                    -- sem FK (viatura removida)
  tipo                     text NOT NULL CHECK (tipo IN ('linhas', 'etapa', 'presenca_base', 'emergencia')),
  payload                  jsonb NOT NULL,
  versao_gestao_vista      integer,
  data_hora_acao           timestamptz NOT NULL,
  relogio                  jsonb,
  recebido_em              timestamptz NOT NULL DEFAULT now(),
  resultado                text CHECK (resultado IN ('aplicado', 'conflito')),
  motivo                   text,
  motivo_detalhe           text,
  status_servidor_no_envio text,
  versao_gestao_no_envio   integer,
  resposta                 jsonb,
  aviso                    text CHECK (aviso IN ('enviado', 'limitado', 'agrupado')),
  aviso_em                 timestamptz,
  tratado_por              uuid REFERENCES public.usuarios(id),
  tratado_em               timestamptz,
  tratamento               text
);
CREATE INDEX IF NOT EXISTS registros_campo_usuario_idx ON public.registros_campo (usuario_id, recebido_em DESC);
CREATE INDEX IF NOT EXISTS registros_campo_conflitos_idx ON public.registros_campo (recebido_em DESC)
  WHERE resultado = 'conflito';
CREATE INDEX IF NOT EXISTS registros_campo_escolta_idx ON public.registros_campo (escolta_id);
COMMENT ON TABLE public.registros_campo IS
  'Lote 2026-10 (onda L): livro dos registros de campo enviados pelo aparelho (idempotência por client_id, hora da ação e do envio, conflitos). Escrita só por lote_interno.livro_registrar, livro_resultado e tratar_conflito.';

CREATE TABLE IF NOT EXISTS public.registros_campo_aparelhos (
  auth_user_id uuid NOT NULL,
  aparelho_id  text NOT NULL,
  pendentes    integer NOT NULL CHECK (pendentes >= 0),
  informado_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (auth_user_id, aparelho_id)
);
COMMENT ON TABLE public.registros_campo_aparelhos IS
  'Lote 2026-10 (onda L): quantos registros cada aparelho ainda guarda (informar_pendentes). A reversão da onda só roda com zero em todos os que informaram nos últimos 7 dias.';

CREATE TABLE IF NOT EXISTS public.escolta_efetivo_saidas (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id     uuid NOT NULL,                     -- sem FK de propósito (escolta_apagada)
  escolta_codigo text,
  vigilante_id   uuid,
  usuario_id     uuid,
  saiu_em        timestamptz NOT NULL DEFAULT now(),
  motivo         text NOT NULL CHECK (motivo IN ('retirado', 'substituido', 'escolta_apagada'))
);
CREATE INDEX IF NOT EXISTS escolta_efetivo_saidas_idx ON public.escolta_efetivo_saidas (escolta_id, usuario_id);
COMMENT ON TABLE public.escolta_efetivo_saidas IS
  'Lote 2026-10 (onda L): quem saiu do efetivo de cada escolta (retirado, substituído ou escolta apagada). Gravada só pela trigger; serve para aceitar como conflito, e não recusar, o registro offline de quem perdeu o vínculo.';

CREATE TABLE IF NOT EXISTS public.registros_campo_avisos_agrupados (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id     uuid NOT NULL,
  escolta_id     uuid NOT NULL,
  escolta_codigo text,
  aberto_em      timestamptz NOT NULL DEFAULT now(),
  pendentes      integer NOT NULL DEFAULT 0,
  primeiro_em    timestamptz,
  ultimo_em      timestamptz,
  fechado_em     timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS registros_campo_avisos_agrupados_aberto_uk
  ON public.registros_campo_avisos_agrupados (usuario_id, escolta_id) WHERE fechado_em IS NULL;
COMMENT ON TABLE public.registros_campo_avisos_agrupados IS
  'Lote 2026-10 (onda L): janela de 10 minutos dos avisos de emergência em conflito (o primeiro sai na hora; os seguintes da mesma pessoa e escolta saem somados, pelo cron).';

ALTER TABLE public.registros_campo                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.registros_campo_aparelhos        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.escolta_efetivo_saidas           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.registros_campo_avisos_agrupados ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.registros_campo, public.registros_campo_aparelhos, public.escolta_efetivo_saidas,
              public.registros_campo_avisos_agrupados FROM PUBLIC, anon, authenticated;
-- Leitura do livro: o próprio ou G4, sem motivo_detalhe (GRANT por coluna).
GRANT SELECT (client_id, usuario_id, auth_user_id, escolta_id, escolta_codigo, escolta_veiculo_id, tipo, payload,
              versao_gestao_vista, data_hora_acao, relogio, recebido_em, resultado, motivo,
              status_servidor_no_envio, versao_gestao_no_envio, resposta, aviso, aviso_em,
              tratado_por, tratado_em, tratamento)
  ON public.registros_campo TO authenticated;
DROP POLICY IF EXISTS registros_campo_select ON public.registros_campo;
CREATE POLICY registros_campo_select ON public.registros_campo FOR SELECT TO authenticated
  USING (usuario_id = (SELECT public.get_meu_usuario_id())
         OR (SELECT public.get_meu_perfil()) IN ('administrador', 'gestor', 'supervisor', 'central'));

-- ── 3. Saídas do efetivo (trigger SECURITY DEFINER, sem GRANT) ─────────────────────────
CREATE OR REPLACE FUNCTION lote_interno.registrar_saida_efetivo() RETURNS trigger
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_motivo text; v_cod text; v_achou boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_motivo := 'retirado';
  ELSIF NEW.vigilante_id IS DISTINCT FROM OLD.vigilante_id OR NEW.escolta_id IS DISTINCT FROM OLD.escolta_id THEN
    v_motivo := 'substituido';
  ELSE
    RETURN NULL;
  END IF;
  SELECT codigo_escolta, true INTO v_cod, v_achou FROM public.escoltas WHERE id = OLD.escolta_id;
  IF v_achou IS NULL THEN
    -- Cascata de uma escolta apagada: a BEFORE DELETE de escoltas (marcar_escolta_apagada)
    -- já gravou a saída com o código; aqui só se ela não gravou.
    IF EXISTS (SELECT 1 FROM public.escolta_efetivo_saidas
                WHERE escolta_id = OLD.escolta_id AND vigilante_id = OLD.vigilante_id AND motivo = 'escolta_apagada') THEN
      RETURN NULL;
    END IF;
    v_motivo := 'escolta_apagada';
  END IF;
  INSERT INTO public.escolta_efetivo_saidas (escolta_id, escolta_codigo, vigilante_id, usuario_id, motivo)
  SELECT OLD.escolta_id, v_cod, OLD.vigilante_id, v.usuario_id, v_motivo
    FROM public.vigilantes v WHERE v.id = OLD.vigilante_id;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.registrar_saida_efetivo() FROM PUBLIC, anon, authenticated;

-- Antes de apagar a escolta (a cascata do efetivo já não enxerga a escolta): a saída de cada
-- membro do efetivo, com o código da escolta.
CREATE OR REPLACE FUNCTION lote_interno.marcar_escolta_apagada() RETURNS trigger
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  INSERT INTO public.escolta_efetivo_saidas (escolta_id, escolta_codigo, vigilante_id, usuario_id, motivo)
  SELECT OLD.id, OLD.codigo_escolta, ee.vigilante_id, v.usuario_id, 'escolta_apagada'
    FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
   WHERE ee.escolta_id = OLD.id;
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.marcar_escolta_apagada() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tr_escolta_efetivo_saida_delete ON public.escolta_efetivo;
CREATE TRIGGER tr_escolta_efetivo_saida_delete AFTER DELETE ON public.escolta_efetivo
  FOR EACH ROW EXECUTE FUNCTION lote_interno.registrar_saida_efetivo();
DROP TRIGGER IF EXISTS tr_escolta_efetivo_saida_update ON public.escolta_efetivo;
CREATE TRIGGER tr_escolta_efetivo_saida_update AFTER UPDATE OF vigilante_id, escolta_id ON public.escolta_efetivo
  FOR EACH ROW EXECUTE FUNCTION lote_interno.registrar_saida_efetivo();
DROP TRIGGER IF EXISTS tr_escoltas_marcar_apagada ON public.escoltas;
CREATE TRIGGER tr_escoltas_marcar_apagada BEFORE DELETE ON public.escoltas
  FOR EACH ROW EXECUTE FUNCTION lote_interno.marcar_escolta_apagada();

-- ── 4. registrar_etapa_escolta: hora da ação e id do ponto vindos do aparelho ──────────
-- Mesma assinatura e mesmo corpo da 218 (filtro de anulado da 214, recusa de arquivada e
-- escolta.historico_rpc da 218), com duas diferenças: o ponto aceita o "id" do aparelho e o
-- histórico usa a hora da variável de transação escolta.data_hora_acao, que só a
-- registrar_campo liga (e desliga logo depois). Sem ela, now(), como antes.
CREATE OR REPLACE FUNCTION public.registrar_etapa_escolta(p_escolta_id uuid, p_pontos jsonb DEFAULT '[]'::jsonb, p_status_atual text DEFAULT NULL::text, p_status_novo text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text, p_latitude numeric DEFAULT NULL::numeric, p_longitude numeric DEFAULT NULL::numeric, p_observacao_fechamento text DEFAULT NULL::text, p_data_hora_prevista timestamp with time zone DEFAULT NULL::timestamp with time zone, p_tipo_ponto_todas uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int; v_faltando text[]; v_status text; v_arquivada timestamptz; v_quando timestamptz;
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
  -- Onda L (219): hora da ação (registro feito sem conexão), ligada só pela registrar_campo.
  v_quando := coalesce(nullif(current_setting('escolta.data_hora_acao', true), '')::timestamptz, now());

  -- 1. Pontos de controle (todas as viaturas num statement só). Onda I: o autor é sempre
  --    quem está na sessão (em nome de quem fez); sem sessão (SQL), vale o informado.
  --    Onda L: o id do ponto pode vir do aparelho.
  IF jsonb_array_length(coalesce(p_pontos, '[]'::jsonb)) > 0 THEN
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid)
               WHERE NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
                                 WHERE ev.id = x.escolta_veiculo_id AND ev.escolta_id = p_escolta_id)) THEN
      RAISE EXCEPTION 'Ponto de controle de viatura que não pertence a esta escolta.';
    END IF;
    INSERT INTO public.pontos_controle (id, escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude,
                                        precisao_metros, sem_sinal_gps, foto_id, lancado_por, observacoes,
                                        sincronizado, criado_offline)
    SELECT coalesce(x.id, gen_random_uuid()), x.escolta_veiculo_id, x.tipo_ponto_id, coalesce(x.data_hora, now()), x.latitude, x.longitude,
           x.precisao_metros, coalesce(x.sem_sinal_gps, false), x.foto_id,
           coalesce(public.get_meu_usuario_id(), x.lancado_por), x.observacoes,
           coalesce(x.sincronizado, true), coalesce(x.criado_offline, false)
    FROM jsonb_to_recordset(p_pontos) AS x(id uuid, escolta_veiculo_id uuid, tipo_ponto_id uuid, data_hora timestamptz,
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
  --    Onda L: data_hora = hora da ação (a do envio fica em registros_campo.recebido_em).
  PERFORM set_config('escolta.historico_rpc', 'on', true);
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora,
                                               latitude, longitude, observacao)
  VALUES (p_escolta_id, p_status_atual, p_status_novo, public.get_meu_usuario_id(), v_quando,
          p_latitude, p_longitude, p_observacao);
  PERFORM set_config('escolta.historico_rpc', 'off', true);

  RETURN jsonb_build_object('ok', true, 'avancou', true);
END;
$function$;

-- ── 5. Textos e avisos (internos, sem GRANT) ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION lote_interno.hora_br(p timestamptz) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$ SELECT to_char(p AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') $$;
REVOKE ALL ON FUNCTION lote_interno.hora_br(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION lote_interno.texto_motivo_campo(p_motivo text, p_detalhe text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT CASE p_motivo
    WHEN 'versao' THEN 'a gestão mudou a escolta (zerar, voltar etapa, concluir, arquivar ou recuperar) depois que o aparelho a leu'
    WHEN 'status' THEN 'a escolta já não estava na etapa que o aparelho esperava'
    WHEN 'status_final' THEN 'a escolta já estava finalizada ou cancelada'
    WHEN 'viatura_removida' THEN 'a viatura não faz mais parte da escolta'
    WHEN 'ponto_repetido' THEN 'a viatura já tinha o ponto dessa etapa (outro aparelho registrou antes)'
    WHEN 'recusado' THEN 'o servidor recusou a gravação'
    WHEN 'sem_acesso' THEN CASE p_detalhe
      WHEN 'arquivada' THEN 'a escolta foi arquivada'
      WHEN 'escolta_apagada' THEN 'a escolta foi apagada'
      WHEN 'retirado' THEN 'quem registrou saiu da equipe da escolta'
      ELSE 'quem registrou perdeu o acesso à escolta' END
    ELSE coalesce(p_motivo, 'motivo não informado') END
$$;
REVOKE ALL ON FUNCTION lote_interno.texto_motivo_campo(text, text) FROM PUBLIC, anon, authenticated;

-- Aviso de conflito à supervisão (Central e Telegram). Limite comum: 5 por usuário a cada
-- 10 minutos. Emergência: janela agrupada (o primeiro na hora, os seguintes somados pelo cron).
CREATE OR REPLACE FUNCTION lote_interno.avisar_conflito(p_client_id uuid) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  r public.registros_campo; v_nome text; v_dest uuid[]; v_titulo text; v_texto text; v_n int;
  v_existe boolean; g public.registros_campo_avisos_agrupados; v_rotulo text;
BEGIN
  SELECT * INTO r FROM public.registros_campo WHERE client_id = p_client_id;
  IF r.client_id IS NULL OR r.resultado IS DISTINCT FROM 'conflito' THEN RETURN NULL; END IF;
  SELECT nome_completo INTO v_nome FROM public.usuarios WHERE id = r.usuario_id;
  v_existe := EXISTS (SELECT 1 FROM public.escoltas WHERE id = r.escolta_id);
  v_rotulo := CASE r.tipo WHEN 'etapa' THEN 'Etapa' WHEN 'linhas' THEN 'Registro de campo'
                          WHEN 'presenca_base' THEN 'Presença na base' WHEN 'emergencia' THEN 'EMERGÊNCIA' END;

  IF r.tipo = 'emergencia' THEN
    -- Janela agrupada: fecha a vencida (o cron também fecha) e abre ou soma.
    PERFORM lote_interno.fechar_avisos_agrupados(now());
    SELECT * INTO g FROM public.registros_campo_avisos_agrupados
     WHERE usuario_id = r.usuario_id AND escolta_id = r.escolta_id AND fechado_em IS NULL FOR UPDATE;
    IF g.id IS NOT NULL THEN
      UPDATE public.registros_campo_avisos_agrupados
         SET pendentes = pendentes + 1, primeiro_em = coalesce(primeiro_em, r.recebido_em), ultimo_em = r.recebido_em
       WHERE id = g.id;
      RETURN 'agrupado';
    END IF;
    INSERT INTO public.registros_campo_avisos_agrupados (usuario_id, escolta_id, escolta_codigo)
    VALUES (r.usuario_id, r.escolta_id, r.escolta_codigo);
    v_titulo := 'EMERGÊNCIA não aceita (registro sem conexão)';
  ELSE
    SELECT count(*) INTO v_n FROM public.registros_campo
     WHERE usuario_id = r.usuario_id AND tipo <> 'emergencia' AND aviso = 'enviado'
       AND aviso_em > now() - interval '10 minutes';
    IF v_n >= 5 THEN RETURN 'limitado'; END IF;
    v_titulo := 'Registro sem conexão em conflito';
  END IF;

  v_texto := format('%s de %s na escolta %s: registrado em %s, enviado em %s (Brasília). Não foi aplicado: %s. Veja em Conflitos.',
                    v_rotulo, coalesce(v_nome, 'usuário'), coalesce(r.escolta_codigo, 'sem código'),
                    lote_interno.hora_br(r.data_hora_acao), lote_interno.hora_br(r.recebido_em),
                    lote_interno.texto_motivo_campo(r.motivo, r.motivo_detalhe));
  SELECT array_agg(u.id) INTO v_dest FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
   WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor');
  -- Escolta apagada: notificacoes exige escolta_id (onda J); o aviso vai só pelo Telegram
  -- e pela tela de conflitos.
  IF v_existe THEN
    PERFORM lote_interno.notificar('conflito:' || r.client_id, r.escolta_id, 'conflito_offline', v_dest, v_titulo, v_texto,
                                   jsonb_build_object('client_id', r.client_id, 'emergencia', r.tipo = 'emergencia'));
  END IF;
  PERFORM public._enfileirar_aviso('conflito:' || r.client_id, 'central', CASE WHEN v_existe THEN r.escolta_id END,
                                   v_titulo || E'\n' || v_texto);
  RETURN 'enviado';
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.avisar_conflito(uuid) FROM PUBLIC, anon, authenticated;

-- Fecha as janelas de emergência vencidas (10 minutos) e manda o aviso somado de cada uma
-- que juntou registros. Chamada pelo cron de minuto da 212 e pela própria avisar_conflito.
CREATE OR REPLACE FUNCTION lote_interno.fechar_avisos_agrupados(p_agora timestamptz DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE g record; v_n int := 0; v_dest uuid[]; v_texto text; v_nome text; v_existe boolean;
BEGIN
  FOR g IN SELECT * FROM public.registros_campo_avisos_agrupados
            WHERE fechado_em IS NULL AND aberto_em <= p_agora - interval '10 minutes'
            ORDER BY aberto_em FOR UPDATE SKIP LOCKED LOOP
    UPDATE public.registros_campo_avisos_agrupados SET fechado_em = p_agora WHERE id = g.id;
    CONTINUE WHEN g.pendentes = 0;
    SELECT nome_completo INTO v_nome FROM public.usuarios WHERE id = g.usuario_id;
    v_existe := EXISTS (SELECT 1 FROM public.escoltas WHERE id = g.escolta_id);
    v_texto := format('Mais %s emergência(s) de %s na escolta %s, enviadas sem conexão entre %s e %s (Brasília), não foram aceitas. Veja em Conflitos.',
                      g.pendentes, coalesce(v_nome, 'usuário'), coalesce(g.escolta_codigo, 'sem código'),
                      lote_interno.hora_br(g.primeiro_em), lote_interno.hora_br(g.ultimo_em));
    SELECT array_agg(u.id) INTO v_dest FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
     WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor');
    IF v_existe THEN
      PERFORM lote_interno.notificar('emergencia_agrupada:' || g.id, g.escolta_id, 'conflito_offline', v_dest,
                                     'EMERGÊNCIAS não aceitas (registros sem conexão)', v_texto,
                                     jsonb_build_object('emergencia', true, 'agrupado', g.pendentes));
    END IF;
    PERFORM public._enfileirar_aviso('emergencia_agrupada:' || g.id, 'central', CASE WHEN v_existe THEN g.escolta_id END,
                                     'EMERGÊNCIAS não aceitas (registros sem conexão)' || E'\n' || v_texto);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.fechar_avisos_agrupados(timestamptz) FROM PUBLIC, anon, authenticated;

-- ── 6. O livro (SECURITY DEFINER; EXECUTE só para authenticated) ─────────────────────
-- livro_registrar: reenvio do mesmo client_id devolve o resultado gravado; decide o vínculo;
-- grava a linha (resultado ainda nulo). SEM_VINCULO: erro, nada gravado.
CREATE OR REPLACE FUNCTION lote_interno.livro_registrar(p_client_id uuid, p_tipo text, p_escolta_id uuid,
    p_escolta_veiculo_id uuid, p_payload jsonb, p_versao_gestao integer, p_data_hora_acao timestamptz, p_relogio jsonb)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_eu uuid := public.get_meu_usuario_id(); v_perfil text := public.get_meu_perfil();
  r public.registros_campo; e record; v_g4 boolean; v_efetivo boolean; v_saiu boolean; v_sem text; v_codigo text;
BEGIN
  IF v_eu IS NULL OR v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.' USING ERRCODE = '42501'; END IF;
  IF p_client_id IS NULL OR p_escolta_id IS NULL OR p_tipo IS NULL THEN
    RAISE EXCEPTION 'PAYLOAD_INVALIDO: client_id, tipo e escolta são obrigatórios.' USING ERRCODE = '22023';
  END IF;

  -- Reenvio: devolve o que foi gravado (só ao dono do registro).
  SELECT * INTO r FROM public.registros_campo WHERE client_id = p_client_id;
  IF r.client_id IS NOT NULL THEN
    IF r.usuario_id <> v_eu THEN
      RAISE EXCEPTION 'Identificador de registro já usado por outro usuário.' USING ERRCODE = '42501';
    END IF;
    RETURN jsonb_build_object('duplicado', true, 'resultado', r.resultado,
                              'motivo', r.motivo, 'recebido_em', r.recebido_em, 'resposta', r.resposta);
  END IF;

  -- Vínculo (lido sem a RLS).
  SELECT id, codigo_escolta, arquivada_em, status, versao_gestao INTO e FROM public.escoltas WHERE id = p_escolta_id;
  v_g4 := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
  v_efetivo := e.id IS NOT NULL AND public.sou_do_efetivo(e.id);
  v_saiu := EXISTS (SELECT 1 FROM public.escolta_efetivo_saidas s WHERE s.escolta_id = p_escolta_id AND s.usuario_id = v_eu);
  v_codigo := e.codigo_escolta;
  IF e.id IS NULL THEN
    IF NOT (v_saiu OR v_g4) THEN RAISE EXCEPTION 'SEM_VINCULO' USING HINT = 'Você não tem vínculo com esta escolta.'; END IF;
    v_sem := 'escolta_apagada';
    SELECT s.escolta_codigo INTO v_codigo FROM public.escolta_efetivo_saidas s
     WHERE s.escolta_id = p_escolta_id AND s.escolta_codigo IS NOT NULL ORDER BY s.saiu_em DESC LIMIT 1;
  ELSIF e.arquivada_em IS NOT NULL THEN
    IF NOT (v_efetivo OR v_g4 OR v_saiu) THEN RAISE EXCEPTION 'SEM_VINCULO' USING HINT = 'Você não tem vínculo com esta escolta.'; END IF;
    v_sem := 'arquivada';
  ELSIF NOT (v_efetivo OR v_g4) THEN
    IF NOT v_saiu THEN RAISE EXCEPTION 'SEM_VINCULO' USING HINT = 'Você não tem vínculo com esta escolta.'; END IF;
    v_sem := 'retirado';
  END IF;

  INSERT INTO public.registros_campo (client_id, usuario_id, auth_user_id, escolta_id, escolta_codigo, escolta_veiculo_id,
                                      tipo, payload, versao_gestao_vista, data_hora_acao, relogio, motivo_detalhe)
  VALUES (p_client_id, v_eu, auth.uid(), p_escolta_id, v_codigo, p_escolta_veiculo_id, p_tipo, p_payload,
          p_versao_gestao, coalesce(p_data_hora_acao, now()), p_relogio, v_sem)
  ON CONFLICT (client_id) DO NOTHING;
  IF NOT FOUND THEN
    -- Outra aba do mesmo aparelho gravou entre a leitura e o INSERT: devolve o dela.
    SELECT * INTO r FROM public.registros_campo WHERE client_id = p_client_id;
    IF r.usuario_id <> v_eu THEN RAISE EXCEPTION 'Identificador de registro já usado por outro usuário.' USING ERRCODE = '42501'; END IF;
    RETURN jsonb_build_object('duplicado', true, 'resultado', r.resultado,
                              'motivo', r.motivo, 'recebido_em', r.recebido_em, 'resposta', r.resposta);
  END IF;
  RETURN jsonb_build_object('duplicado', false, 'sem_acesso', v_sem, 'status', e.status, 'versao_gestao', e.versao_gestao);
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.livro_registrar(uuid, text, uuid, uuid, jsonb, integer, timestamptz, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION lote_interno.livro_registrar(uuid, text, uuid, uuid, jsonb, integer, timestamptz, jsonb) TO authenticated;

-- livro_resultado: grava o resultado uma vez (o próprio registro, ainda sem resultado) e
-- chama o aviso do conflito.
CREATE OR REPLACE FUNCTION lote_interno.livro_resultado(p_client_id uuid, p_resultado text, p_motivo text,
    p_motivo_detalhe text, p_status text, p_versao_gestao integer, p_resposta jsonb)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_eu uuid := public.get_meu_usuario_id(); r public.registros_campo; v_motivo text; v_detalhe text; v_aviso text;
        v_texto text;
BEGIN
  IF v_eu IS NULL THEN RAISE EXCEPTION 'Sessão inválida.' USING ERRCODE = '42501'; END IF;
  IF p_resultado IS NULL OR p_resultado NOT IN ('aplicado', 'conflito') THEN
    RAISE EXCEPTION 'Resultado inválido.' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO r FROM public.registros_campo WHERE client_id = p_client_id FOR UPDATE;
  IF r.client_id IS NULL OR r.usuario_id <> v_eu THEN
    RAISE EXCEPTION 'Registro de outro usuário ou inexistente.' USING ERRCODE = '42501';
  END IF;
  IF r.resultado IS NOT NULL THEN
    RAISE EXCEPTION 'O resultado deste registro já foi gravado e não muda.' USING ERRCODE = '42501';
  END IF;
  -- Vínculo perdido decidido pelo livro: nunca aplicado; o motivo visível é sempre sem_acesso.
  IF r.motivo_detalhe IN ('arquivada', 'escolta_apagada', 'retirado') THEN
    IF p_resultado = 'aplicado' THEN
      RAISE EXCEPTION 'Registro de quem perdeu o vínculo só entra como conflito.' USING ERRCODE = '42501';
    END IF;
    v_motivo := 'sem_acesso'; v_detalhe := r.motivo_detalhe;
  ELSIF p_resultado = 'conflito' THEN
    v_motivo := coalesce(p_motivo, 'recusado'); v_detalhe := p_motivo_detalhe;
  END IF;
  UPDATE public.registros_campo
     SET resultado = p_resultado, motivo = v_motivo, motivo_detalhe = v_detalhe,
         status_servidor_no_envio = p_status, versao_gestao_no_envio = p_versao_gestao, resposta = p_resposta
   WHERE client_id = p_client_id;
  IF p_resultado = 'conflito' THEN
    v_aviso := lote_interno.avisar_conflito(p_client_id);
    UPDATE public.registros_campo SET aviso = v_aviso, aviso_em = CASE WHEN v_aviso IS NOT NULL THEN now() END
     WHERE client_id = p_client_id;
  END IF;
  -- Texto do Telegram do registro aplicado feito sem conexão (16.2.7): as duas horas.
  IF p_resultado = 'aplicado' AND abs(extract(epoch FROM r.recebido_em - r.data_hora_acao)) > 120 THEN
    v_texto := 'Registrado às ' ||
      CASE WHEN (r.data_hora_acao AT TIME ZONE 'America/Sao_Paulo')::date = (r.recebido_em AT TIME ZONE 'America/Sao_Paulo')::date
           THEN to_char(r.data_hora_acao AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI')
           ELSE lote_interno.hora_br(r.data_hora_acao) END ||
      ' sem conexão, enviado às ' || to_char(r.recebido_em AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') || ' (Brasília)';
  END IF;
  RETURN jsonb_build_object('resultado', p_resultado, 'motivo', v_motivo, 'recebido_em', r.recebido_em,
                            'resposta', p_resposta, 'texto_offline', v_texto);
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.livro_resultado(uuid, text, text, text, text, integer, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION lote_interno.livro_resultado(uuid, text, text, text, text, integer, jsonb) TO authenticated;

-- A registrar_campo (INVOKER) chama as duas funções do livro; só elas têm EXECUTE.
GRANT USAGE ON SCHEMA lote_interno TO authenticated;

-- ── 7. registrar_campo: o envelope de transporte (SECURITY INVOKER) ───────────────────
CREATE OR REPLACE FUNCTION public.registrar_campo(p_client_id uuid, p_tipo text, p_payload jsonb,
    p_versao_gestao integer DEFAULT NULL, p_data_hora_acao timestamptz DEFAULT NULL, p_relogio jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY INVOKER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  -- Lista fechada de colunas por tabela (sem as colunas da 213, que só a gestão e as
  -- triggers gravam). Nenhum identificador vem do payload: cada tabela tem o seu INSERT.
  c_cols CONSTANT jsonb := jsonb_build_object(
    'fotos', jsonb_build_array('id', 'caminho_arquivo', 'tipo_foto_id', 'latitude', 'longitude', 'precisao_metros',
                               'data_hora_captura', 'carimbo_aplicado', 'enviada_telegram', 'sincronizada', 'criado_por'),
    'checklists', jsonb_build_array('id', 'escolta_veiculo_id', 'modelo_id', 'tipo', 'concluido', 'data_conclusao',
                                    'responsavel_id', 'sincronizado', 'data_inicio'),
    'checklist_respostas', jsonb_build_array('id', 'checklist_id', 'descricao_item', 'conforme', 'observacao', 'foto_id'),
    'pontos_controle', jsonb_build_array('id', 'escolta_veiculo_id', 'tipo_ponto_id', 'data_hora', 'latitude', 'longitude',
                                         'precisao_metros', 'foto_id', 'lancado_por', 'sincronizado', 'criado_offline',
                                         'observacoes', 'sem_sinal_gps'),
    'ocorrencias', jsonb_build_array('id', 'escolta_id', 'escolta_veiculo_id', 'tipo_ocorrencia_id', 'descricao', 'data_hora',
                                     'latitude', 'longitude', 'foto_id', 'registrado_por', 'sincronizado'),
    'emergencias', jsonb_build_array('id', 'escolta_id', 'escolta_veiculo_id', 'acionado_por', 'data_hora', 'latitude',
                                     'longitude', 'status', 'observacao', 'sem_sinal_gps'),
    'km', jsonb_build_array('escolta_veiculo_id', 'quilometragem_saida', 'quilometragem_retorno'));
  c_topo CONSTANT jsonb := jsonb_build_array('escolta_id', 'escolta_veiculo_id', 'status_esperado', 'linhas', 'etapa',
                                             'presenca', 'meta');
  c_etapa CONSTANT jsonb := jsonb_build_array('pontos', 'status_atual', 'status_novo', 'observacao', 'latitude', 'longitude',
                                              'observacao_fechamento', 'data_hora_prevista', 'tipo_ponto_todas');
  c_presenca CONSTANT jsonb := jsonb_build_array('latitude', 'longitude', 'precisao');
  c_tipos_etapa CONSTANT text[] := ARRAY['base_saida', 'origem', 'transito_destino', 'destino', 'transito_retorno',
                                         'retorno', 'base_retorno'];
  v_esc uuid; v_linhas jsonb; v_etapa jsonb; v_pres jsonb; v_vazio CONSTANT jsonb := '[]'::jsonb;
  k text; v_bad text; v_livro jsonb; v_status text; v_versao int; v_esperado text;
  v_resultado text := 'aplicado'; v_motivo text; v_detalhe text; v_resposta jsonb; v_n int; v_eu uuid;
  v_quando timestamptz := coalesce(p_data_hora_acao, now()); v_fim jsonb; v_pontos jsonb; v_veics uuid[];
BEGIN
  -- 1. Forma do envelope (antes de qualquer gravação; recusa sem gravar nada).
  IF p_client_id IS NULL THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: client_id ausente.' USING ERRCODE = '22023'; END IF;
  IF p_tipo IS NULL OR p_tipo NOT IN ('linhas', 'etapa', 'presenca_base', 'emergencia') THEN
    RAISE EXCEPTION 'PAYLOAD_INVALIDO: tipo % fora da lista.', p_tipo USING ERRCODE = '22023';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'PAYLOAD_INVALIDO: payload precisa ser um objeto.' USING ERRCODE = '22023';
  END IF;
  SELECT x INTO v_bad FROM jsonb_object_keys(p_payload) x WHERE NOT c_topo ? x LIMIT 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: chave % fora da lista.', v_bad USING ERRCODE = '22023'; END IF;
  BEGIN
    v_esc := (p_payload ->> 'escolta_id')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'PAYLOAD_INVALIDO: escolta_id inválido.' USING ERRCODE = '22023';
  END;
  IF v_esc IS NULL THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: escolta_id ausente.' USING ERRCODE = '22023'; END IF;
  v_linhas := coalesce(p_payload -> 'linhas', '{}'::jsonb);
  v_etapa := p_payload -> 'etapa';
  v_pres := p_payload -> 'presenca';
  IF jsonb_typeof(v_linhas) <> 'object' THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: linhas precisa ser um objeto.' USING ERRCODE = '22023'; END IF;
  FOR k IN SELECT jsonb_object_keys(v_linhas) LOOP
    IF NOT c_cols ? k THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: tabela % fora da lista.', k USING ERRCODE = '22023'; END IF;
    IF jsonb_typeof(v_linhas -> k) <> 'array' THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: % precisa ser uma lista.', k USING ERRCODE = '22023'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_linhas -> k) it WHERE jsonb_typeof(it) <> 'object') THEN
      RAISE EXCEPTION 'PAYLOAD_INVALIDO: linha de % que não é objeto.', k USING ERRCODE = '22023';
    END IF;
    SELECT c INTO v_bad FROM jsonb_array_elements(v_linhas -> k) it, jsonb_object_keys(it) c
     WHERE NOT (c_cols -> k) ? c LIMIT 1;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: coluna %.% fora da lista.', k, v_bad USING ERRCODE = '22023'; END IF;
    IF k <> 'km' AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_linhas -> k) it WHERE nullif(it ->> 'id', '') IS NULL) THEN
      RAISE EXCEPTION 'PAYLOAD_INVALIDO: linha de % sem id (o id vem do aparelho).', k USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF v_etapa IS NOT NULL THEN
    IF p_tipo <> 'etapa' OR jsonb_typeof(v_etapa) <> 'object' THEN
      RAISE EXCEPTION 'PAYLOAD_INVALIDO: etapa só no tipo etapa, como objeto.' USING ERRCODE = '22023';
    END IF;
    SELECT x INTO v_bad FROM jsonb_object_keys(v_etapa) x WHERE NOT c_etapa ? x LIMIT 1;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: etapa.% fora da lista.', v_bad USING ERRCODE = '22023'; END IF;
    IF jsonb_typeof(coalesce(v_etapa -> 'pontos', v_vazio)) <> 'array'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(v_etapa -> 'pontos', v_vazio)) it WHERE jsonb_typeof(it) <> 'object') THEN
      RAISE EXCEPTION 'PAYLOAD_INVALIDO: etapa.pontos precisa ser uma lista de objetos.' USING ERRCODE = '22023';
    END IF;
    SELECT c INTO v_bad FROM jsonb_array_elements(coalesce(v_etapa -> 'pontos', v_vazio)) it, jsonb_object_keys(it) c
     WHERE NOT (c_cols -> 'pontos_controle') ? c LIMIT 1;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: coluna etapa.pontos.% fora da lista.', v_bad USING ERRCODE = '22023'; END IF;
  ELSIF p_tipo = 'etapa' THEN
    RAISE EXCEPTION 'PAYLOAD_INVALIDO: tipo etapa sem etapa.' USING ERRCODE = '22023';
  END IF;
  IF v_pres IS NOT NULL THEN
    IF p_tipo <> 'presenca_base' OR jsonb_typeof(v_pres) <> 'object' THEN
      RAISE EXCEPTION 'PAYLOAD_INVALIDO: presenca só no tipo presenca_base, como objeto.' USING ERRCODE = '22023';
    END IF;
    SELECT x INTO v_bad FROM jsonb_object_keys(v_pres) x WHERE NOT c_presenca ? x LIMIT 1;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'PAYLOAD_INVALIDO: presenca.% fora da lista.', v_bad USING ERRCODE = '22023'; END IF;
  END IF;
  -- Emergência só pelo tipo emergencia (a regra "nunca vira conflito por status" não vale
  -- para outra coisa), e o tipo emergencia só leva fotos e emergências.
  IF p_tipo = 'emergencia' THEN
    IF jsonb_array_length(coalesce(v_linhas -> 'emergencias', v_vazio)) = 0
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_linhas) x WHERE x NOT IN ('fotos', 'emergencias')) THEN
      RAISE EXCEPTION 'PAYLOAD_INVALIDO: tipo emergencia leva só emergencias e fotos.' USING ERRCODE = '22023';
    END IF;
  ELSIF v_linhas ? 'emergencias' THEN
    RAISE EXCEPTION 'PAYLOAD_INVALIDO: emergência só pelo tipo emergencia.' USING ERRCODE = '22023';
  END IF;
  IF p_tipo = 'linhas' AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(v_linhas)) THEN
    RAISE EXCEPTION 'PAYLOAD_INVALIDO: tipo linhas sem linhas.' USING ERRCODE = '22023';
  END IF;
  -- Tudo da mesma escolta do envelope.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(v_linhas -> 'ocorrencias', v_vazio) || coalesce(v_linhas -> 'emergencias', v_vazio)) it
              WHERE nullif(it ->> 'escolta_id', '') IS NOT NULL AND (it ->> 'escolta_id')::uuid <> v_esc) THEN
    RAISE EXCEPTION 'PAYLOAD_INVALIDO: linha de outra escolta.' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(v_linhas -> 'fotos', v_vazio)) it
              WHERE public.escolta_do_caminho(it ->> 'caminho_arquivo') IS DISTINCT FROM v_esc) THEN
    RAISE EXCEPTION 'PAYLOAD_INVALIDO: foto com caminho de outra escolta.' USING ERRCODE = '22023';
  END IF;

  -- 2. Trava a escolta (o efetivo e a gestão têm UPDATE pela escoltas_update): dois aparelhos
  --    não passam juntos pela conferência. Invisível (RLS) ou apagada: o livro decide.
  SELECT status, versao_gestao INTO v_status, v_versao FROM public.escoltas WHERE id = v_esc FOR UPDATE;

  -- 3. Livro: reenvio, vínculo e a linha (SEM_VINCULO sai daqui como erro).
  v_livro := lote_interno.livro_registrar(p_client_id, p_tipo, v_esc, nullif(p_payload ->> 'escolta_veiculo_id', '')::uuid,
                                          p_payload, p_versao_gestao, v_quando, p_relogio);
  IF (v_livro ->> 'duplicado')::boolean THEN
    RETURN (v_livro - 'duplicado') || jsonb_build_object('ok', true, 'duplicado', true, 'client_id', p_client_id);
  END IF;
  v_status := coalesce(v_status, v_livro ->> 'status');
  v_versao := coalesce(v_versao, (v_livro ->> 'versao_gestao')::int);
  v_eu := public.get_meu_usuario_id();

  -- 4. Fotos: entram sempre que a RLS aceitar (também no conflito, para a supervisão ver).
  IF jsonb_array_length(coalesce(v_linhas -> 'fotos', v_vazio)) > 0 THEN
    BEGIN
      INSERT INTO public.fotos (id, caminho_arquivo, tipo_foto_id, latitude, longitude, precisao_metros, data_hora_captura,
                                carimbo_aplicado, enviada_telegram, sincronizada, criado_por)
      SELECT r.id, r.caminho_arquivo, r.tipo_foto_id, r.latitude, r.longitude, r.precisao_metros,
             coalesce(r.data_hora_captura, v_quando), coalesce(r.carimbo_aplicado, false), coalesce(r.enviada_telegram, false),
             coalesce(r.sincronizada, true), coalesce(r.criado_por, v_eu)
        FROM jsonb_array_elements(v_linhas -> 'fotos') it, jsonb_populate_record(NULL::public.fotos, it) r
      ON CONFLICT (id) DO NOTHING;
    EXCEPTION WHEN OTHERS THEN
      v_detalhe := left('fotos: ' || SQLSTATE || ': ' || SQLERRM, 500);
    END;
  END IF;

  -- 5. Regras de conflito (16.2.5), na ordem. Emergência só pelo vínculo.
  IF v_livro ->> 'sem_acesso' IS NOT NULL THEN
    v_resultado := 'conflito'; v_motivo := 'sem_acesso';
  ELSIF p_tipo <> 'emergencia' THEN
    v_esperado := coalesce(nullif(p_payload ->> 'status_esperado', ''), v_etapa ->> 'status_atual');
    v_pontos := coalesce(v_linhas -> 'pontos_controle', v_vazio) || coalesce(v_etapa -> 'pontos', v_vazio);
    SELECT array_agg(DISTINCT x) INTO v_veics FROM (
      SELECT nullif(it ->> 'escolta_veiculo_id', '')::uuid AS x
        FROM jsonb_array_elements(v_pontos || coalesce(v_linhas -> 'checklists', v_vazio) || coalesce(v_linhas -> 'km', v_vazio)
                                  || coalesce(v_linhas -> 'ocorrencias', v_vazio)) it) z WHERE x IS NOT NULL;
    IF p_versao_gestao IS NOT NULL AND p_versao_gestao IS DISTINCT FROM v_versao THEN
      v_resultado := 'conflito'; v_motivo := 'versao';
    ELSIF v_status IN ('finalizada', 'cancelada') THEN
      v_resultado := 'conflito'; v_motivo := 'status_final';
    ELSIF v_esperado IS NOT NULL AND v_esperado IS DISTINCT FROM v_status THEN
      v_resultado := 'conflito'; v_motivo := 'status';
    ELSIF EXISTS (SELECT 1 FROM unnest(v_veics) x
                   WHERE NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev WHERE ev.id = x AND ev.escolta_id = v_esc)) THEN
      v_resultado := 'conflito'; v_motivo := 'viatura_removida';
    ELSIF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_pontos) x(escolta_veiculo_id uuid, tipo_ponto_id uuid)
                    JOIN public.dom_tipos_ponto t ON t.id = x.tipo_ponto_id AND t.codigo = ANY (c_tipos_etapa)
                   WHERE EXISTS (SELECT 1 FROM public.pontos_controle pc
                                  WHERE pc.escolta_veiculo_id = x.escolta_veiculo_id AND pc.tipo_ponto_id = x.tipo_ponto_id
                                    AND pc.anulado_em IS NULL)) THEN
      v_resultado := 'conflito'; v_motivo := 'ponto_repetido';
    END IF;
  END IF;

  -- 6. Gravação numa subtransação: RLS e triggers de quem chama; qualquer recusa vira conflito.
  IF v_resultado = 'aplicado' THEN
    BEGIN
      IF jsonb_array_length(coalesce(v_linhas -> 'checklists', v_vazio)) > 0 THEN
        INSERT INTO public.checklists (id, escolta_veiculo_id, modelo_id, tipo, concluido, data_conclusao, responsavel_id,
                                       sincronizado, data_inicio)
        SELECT r.id, r.escolta_veiculo_id, r.modelo_id, r.tipo, coalesce(r.concluido, false), r.data_conclusao,
               coalesce(r.responsavel_id, v_eu), coalesce(r.sincronizado, true), r.data_inicio
          FROM jsonb_array_elements(v_linhas -> 'checklists') it, jsonb_populate_record(NULL::public.checklists, it) r;
      END IF;
      IF jsonb_array_length(coalesce(v_linhas -> 'checklist_respostas', v_vazio)) > 0 THEN
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_linhas -> 'checklist_respostas') it
                    WHERE NOT EXISTS (SELECT 1 FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id
                                       WHERE c.id = nullif(it ->> 'checklist_id', '')::uuid AND ev.escolta_id = v_esc)) THEN
          RAISE EXCEPTION 'Resposta de checklist que não é desta escolta.' USING ERRCODE = '42501';
        END IF;
        INSERT INTO public.checklist_respostas (id, checklist_id, descricao_item, conforme, observacao, foto_id)
        SELECT r.id, r.checklist_id, r.descricao_item, r.conforme, r.observacao, r.foto_id
          FROM jsonb_array_elements(v_linhas -> 'checklist_respostas') it, jsonb_populate_record(NULL::public.checklist_respostas, it) r;
      END IF;
      IF jsonb_array_length(coalesce(v_linhas -> 'pontos_controle', v_vazio)) > 0 THEN
        INSERT INTO public.pontos_controle (id, escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, precisao_metros,
                                            foto_id, lancado_por, sincronizado, criado_offline, observacoes, sem_sinal_gps)
        SELECT r.id, r.escolta_veiculo_id, r.tipo_ponto_id, coalesce(r.data_hora, v_quando), r.latitude, r.longitude,
               r.precisao_metros, r.foto_id, coalesce(r.lancado_por, v_eu), coalesce(r.sincronizado, true),
               coalesce(r.criado_offline, false), r.observacoes, coalesce(r.sem_sinal_gps, false)
          FROM jsonb_array_elements(v_linhas -> 'pontos_controle') it, jsonb_populate_record(NULL::public.pontos_controle, it) r;
      END IF;
      IF jsonb_array_length(coalesce(v_linhas -> 'ocorrencias', v_vazio)) > 0 THEN
        INSERT INTO public.ocorrencias (id, escolta_id, escolta_veiculo_id, tipo_ocorrencia_id, descricao, data_hora, latitude,
                                        longitude, foto_id, registrado_por, sincronizado)
        SELECT r.id, v_esc, r.escolta_veiculo_id, r.tipo_ocorrencia_id, r.descricao, coalesce(r.data_hora, v_quando),
               r.latitude, r.longitude, r.foto_id, coalesce(r.registrado_por, v_eu), coalesce(r.sincronizado, true)
          FROM jsonb_array_elements(v_linhas -> 'ocorrencias') it, jsonb_populate_record(NULL::public.ocorrencias, it) r;
      END IF;
      IF jsonb_array_length(coalesce(v_linhas -> 'emergencias', v_vazio)) > 0 THEN
        -- Emergência de viatura que saiu da escolta grava sem a viatura (nunca se perde por isso).
        INSERT INTO public.emergencias (id, escolta_id, escolta_veiculo_id, acionado_por, data_hora, latitude, longitude,
                                        status, observacao, sem_sinal_gps)
        SELECT r.id, v_esc,
               CASE WHEN EXISTS (SELECT 1 FROM public.escolta_veiculos ev WHERE ev.id = r.escolta_veiculo_id AND ev.escolta_id = v_esc)
                    THEN r.escolta_veiculo_id END,
               coalesce(r.acionado_por, v_eu), coalesce(r.data_hora, v_quando), r.latitude, r.longitude,
               coalesce(r.status, 'aberta'), r.observacao, coalesce(r.sem_sinal_gps, false)
          FROM jsonb_array_elements(v_linhas -> 'emergencias') it, jsonb_populate_record(NULL::public.emergencias, it) r;
      END IF;
      IF jsonb_array_length(coalesce(v_linhas -> 'km', v_vazio)) > 0 THEN
        -- Só as duas colunas de KM, por escolta_veiculo_id da escolta do envelope.
        UPDATE public.escolta_veiculos ev SET
               quilometragem_saida = CASE WHEN it ? 'quilometragem_saida' THEN (it ->> 'quilometragem_saida')::numeric
                                          ELSE ev.quilometragem_saida END,
               quilometragem_retorno = CASE WHEN it ? 'quilometragem_retorno' THEN (it ->> 'quilometragem_retorno')::numeric
                                            ELSE ev.quilometragem_retorno END
          FROM jsonb_array_elements(v_linhas -> 'km') it
         WHERE ev.id = nullif(it ->> 'escolta_veiculo_id', '')::uuid AND ev.escolta_id = v_esc;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n <> jsonb_array_length(v_linhas -> 'km') THEN
          RAISE EXCEPTION 'KM não aceito para todas as viaturas (% de %).', v_n, jsonb_array_length(v_linhas -> 'km')
            USING ERRCODE = '42501';
        END IF;
      END IF;
      IF p_tipo = 'etapa' THEN
        PERFORM set_config('escolta.data_hora_acao', v_quando::text, true);
        v_resposta := public.registrar_etapa_escolta(
          v_esc, coalesce(v_etapa -> 'pontos', v_vazio), v_etapa ->> 'status_atual', v_etapa ->> 'status_novo',
          v_etapa ->> 'observacao', (v_etapa ->> 'latitude')::numeric, (v_etapa ->> 'longitude')::numeric,
          v_etapa ->> 'observacao_fechamento', (v_etapa ->> 'data_hora_prevista')::timestamptz,
          nullif(v_etapa ->> 'tipo_ponto_todas', '')::uuid);
        PERFORM set_config('escolta.data_hora_acao', '', true);
      ELSIF p_tipo = 'presenca_base' THEN
        v_resposta := public.confirmar_presenca_base(v_esc, (v_pres ->> 'latitude')::numeric, (v_pres ->> 'longitude')::numeric,
                                                     (v_pres ->> 'precisao')::numeric);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_resultado := 'conflito';
      v_motivo := CASE WHEN SQLERRM = 'ERRO_SEM_TRANSICAO' THEN 'status' ELSE 'recusado' END;
      v_detalhe := left(coalesce(v_detalhe || '; ', '') || SQLSTATE || ': ' || SQLERRM, 1000);
      v_resposta := NULL;
    END;
  END IF;

  -- 7. Resultado no livro (e o aviso, se for conflito).
  v_fim := lote_interno.livro_resultado(p_client_id, v_resultado, v_motivo, v_detalhe, v_status, v_versao, v_resposta);
  RETURN v_fim || jsonb_build_object('ok', true, 'duplicado', false, 'client_id', p_client_id);
END;
$$;
REVOKE ALL ON FUNCTION public.registrar_campo(uuid, text, jsonb, integer, timestamptz, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_campo(uuid, text, jsonb, integer, timestamptz, jsonb) TO authenticated;

-- ── 8. RPCs do app (SECURITY DEFINER) ────────────────────────────────────────────────
-- Telegram do registro aplicado: true uma única vez por client_id (padrão da 208).
CREATE OR REPLACE FUNCTION public.reservar_aviso_campo(p_client_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_eu uuid := public.get_meu_usuario_id(); v_n int;
BEGIN
  IF v_eu IS NULL THEN RAISE EXCEPTION 'Sessão inválida.' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.registros_campo
                  WHERE client_id = p_client_id AND usuario_id = v_eu AND resultado = 'aplicado') THEN
    RETURN false;
  END IF;
  INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES ('campo:' || p_client_id, v_eu)
  ON CONFLICT (chave) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n = 1;
END;
$$;
REVOKE ALL ON FUNCTION public.reservar_aviso_campo(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reservar_aviso_campo(uuid) TO authenticated;

-- Contagem de pendentes do aparelho (usada na reversão).
CREATE OR REPLACE FUNCTION public.informar_pendentes(p_aparelho_id text, p_pendentes integer) RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessão inválida.' USING ERRCODE = '42501'; END IF;
  IF p_aparelho_id IS NULL OR length(p_aparelho_id) NOT BETWEEN 8 AND 64 OR p_pendentes IS NULL OR p_pendentes < 0 THEN
    RAISE EXCEPTION 'Contagem inválida.' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.registros_campo_aparelhos (auth_user_id, aparelho_id, pendentes, informado_em)
  VALUES (auth.uid(), p_aparelho_id, p_pendentes, now())
  ON CONFLICT (auth_user_id, aparelho_id) DO UPDATE SET pendentes = EXCLUDED.pendentes, informado_em = EXCLUDED.informado_em;
END;
$$;
REVOKE ALL ON FUNCTION public.informar_pendentes(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.informar_pendentes(text, integer) TO authenticated;

-- Chave de liga e desliga e telefone da central (configuracao_avisos não é lida pelo app).
CREATE OR REPLACE FUNCTION public.config_offline() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v jsonb;
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessão inválida.' USING ERRCODE = '42501'; END IF;
  SELECT jsonb_build_object('offline_ligado', offline_ligado, 'telefone_central', telefone_central) INTO v
    FROM public.configuracao_avisos WHERE id = 1;
  RETURN coalesce(v, jsonb_build_object('offline_ligado', false, 'telefone_central', NULL));
END;
$$;
REVOKE ALL ON FUNCTION public.config_offline() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.config_offline() TO authenticated;

-- Tela de conflitos (supervisor ou acima): conteúdo completo, com o detalhe do motivo e o
-- código da escolta (também arquivada ou apagada).
CREATE OR REPLACE FUNCTION public.listar_conflitos(p_so_abertos boolean DEFAULT true, p_limite integer DEFAULT 100,
    p_antes timestamptz DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v jsonb;
BEGIN
  IF coalesce(public.get_meu_perfil(), '') NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Só supervisor, gestor ou administrador veem os conflitos.' USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(jsonb_agg(x.j ORDER BY x.recebido_em DESC), '[]'::jsonb) INTO v FROM (
    SELECT r.recebido_em, jsonb_build_object(
      'client_id', r.client_id, 'tipo', r.tipo, 'usuario_id', r.usuario_id, 'usuario_nome', u.nome_completo,
      'escolta_id', r.escolta_id, 'escolta_codigo', coalesce(e.codigo_escolta, r.escolta_codigo),
      'escolta_existe', e.id IS NOT NULL, 'escolta_arquivada', e.arquivada_em IS NOT NULL,
      'escolta_veiculo_id', r.escolta_veiculo_id, 'payload', r.payload,
      'versao_gestao_vista', r.versao_gestao_vista, 'versao_gestao_no_envio', r.versao_gestao_no_envio,
      'status_servidor_no_envio', r.status_servidor_no_envio,
      'data_hora_acao', r.data_hora_acao, 'recebido_em', r.recebido_em, 'relogio', r.relogio,
      'motivo', r.motivo, 'motivo_detalhe', r.motivo_detalhe,
      'motivo_texto', lote_interno.texto_motivo_campo(r.motivo, r.motivo_detalhe),
      'aviso', r.aviso, 'tratado_por', r.tratado_por, 'tratado_por_nome', t.nome_completo,
      'tratado_em', r.tratado_em, 'tratamento', r.tratamento,
      'fotos', coalesce((SELECT jsonb_agg(f ->> 'caminho_arquivo') FROM jsonb_array_elements(coalesce(r.payload #> '{linhas,fotos}', '[]'::jsonb)) f), '[]'::jsonb)) AS j
    FROM public.registros_campo r
    LEFT JOIN public.usuarios u ON u.id = r.usuario_id
    LEFT JOIN public.usuarios t ON t.id = r.tratado_por
    LEFT JOIN public.escoltas e ON e.id = r.escolta_id
    WHERE r.resultado = 'conflito'
      AND (NOT coalesce(p_so_abertos, true) OR r.tratado_em IS NULL)
      AND (p_antes IS NULL OR r.recebido_em < p_antes)
    ORDER BY r.recebido_em DESC
    LIMIT least(greatest(coalesce(p_limite, 100), 1), 500)) x;
  RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION public.listar_conflitos(boolean, integer, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.listar_conflitos(boolean, integer, timestamptz) TO authenticated;

-- Marcar tratado com justificativa (supervisor ou acima). Nada é apagado.
CREATE OR REPLACE FUNCTION public.tratar_conflito(p_client_id uuid, p_tratamento text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_texto text; r public.registros_campo;
BEGIN
  IF coalesce(public.get_meu_perfil(), '') NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Só supervisor, gestor ou administrador tratam conflitos.' USING ERRCODE = '42501';
  END IF;
  v_texto := lote_interno.exigir_motivo(p_tratamento);
  SELECT * INTO r FROM public.registros_campo WHERE client_id = p_client_id FOR UPDATE;
  IF r.client_id IS NULL OR r.resultado IS DISTINCT FROM 'conflito' THEN
    RAISE EXCEPTION 'Conflito não encontrado.';
  END IF;
  IF r.tratado_em IS NOT NULL THEN
    RAISE EXCEPTION 'Este conflito já foi tratado em % (Brasília).', lote_interno.hora_br(r.tratado_em);
  END IF;
  UPDATE public.registros_campo SET tratado_por = public.get_meu_usuario_id(), tratado_em = now(), tratamento = v_texto
   WHERE client_id = p_client_id;
  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES (public.get_meu_usuario_id(), 'TRATAR_CONFLITO_OFFLINE', 'registros_campo', p_client_id,
          jsonb_build_object('escolta_id', r.escolta_id, 'motivo', r.motivo, 'motivo_detalhe', r.motivo_detalhe),
          jsonb_build_object('tratamento', v_texto), now());
  RETURN jsonb_build_object('ok', true, 'tratado_em', now());
END;
$$;
REVOKE ALL ON FUNCTION public.tratar_conflito(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tratar_conflito(uuid, text) TO authenticated;

-- ── 9. Cron de minuto da 212: fecha também as janelas de emergência (18.8.2) ──────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('lote2026_avisos_checkin', '* * * * *',
      'SELECT lote_interno.gerar_avisos_checkin(); SELECT lote_interno.fechar_avisos_agrupados();');
  END IF;
END $$;

-- Conferência:
-- SELECT offline_ligado, telefone_central FROM configuracao_avisos;                       -- true, nulo
-- SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lote_interno'
--   AND has_function_privilege('authenticated', p.oid, 'EXECUTE');                       -- livro_registrar, livro_resultado
-- SELECT command FROM cron.job WHERE jobname = 'lote2026_avisos_checkin';               -- com fechar_avisos_agrupados
-- SELECT count(*) FROM registros_campo;                                                 -- 0 logo depois de aplicar
