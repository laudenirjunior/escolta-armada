-- 222_lancamento_retroativo.sql
-- Pedido de Peçanha em 2026-11-12: lançar depois do fato uma escolta que aconteceu, mas não foi
-- registrada na hora (sem sinal, celular sem bateria, esquecimento), com os horários reais e sem
-- falsificar nada. Idempotente. Depois da 221 (usa 211, 213, 214, 218 e 221).
-- Aditiva: colunas novas com padrão (os registros ao vivo antigos não mudam), funções novas que o
-- código atual não chama e dois corpos recriados (_enfileirar_aviso da 202 e lote_interno.notificar
-- da 211) que só ganham um retorno antecipado quando a variável escolta.lancamento_retroativo está
-- ligada, coisa que só a RPC desta migration faz. Fluxo ao vivo: nenhuma mudança de comportamento.
--
-- O que faz:
-- 1. Colunas.
--    escoltas: lancamento_retroativo (false), retroativo_por, retroativo_em, retroativo_motivo.
--    escolta_status_historico, pontos_controle e fotos: registrado_em (horário do servidor em que
--    a linha entrou; o operacional continua em data_hora / data_hora_captura), retroativo (false)
--    e motivo_retroativo. registrado_em nasce NULO nas linhas antigas (não se inventa horário de
--    registro para elas; a tela usa data_hora) e com padrão now() nas novas.
--    fotos: origem ('camera' ou 'galeria'; NULO nas antigas, que são todas da câmera) e
--    origem_localizacao ('gps', 'exif' ou 'nenhuma').
--    CHECK: foto da galeria nunca com localização 'gps'; 'nenhuma' sempre sem latitude e
--    longitude; ponto retroativo sempre sem latitude e longitude (nada de GPS inventado).
-- 2. Trava (tr_travar_colunas_retroativo, BEFORE INSERT OR UPDATE nas quatro tabelas):
--    registrado_em é sempre o now() do servidor no INSERT e não muda depois; as colunas do
--    retroativo só mudam com a variável escolta.lancamento_retroativo ligada E perfil
--    administrador ou gestor (a mesma dupla guarda da 213), ou sem usuário final (SQL Editor).
-- 3. Silêncio durante o lançamento: _enfileirar_aviso (Telegram) e lote_interno.notificar
--    (central de avisos) não gravam nada enquanto a variável está ligada. A RPC desliga a
--    variável antes do resumo, que sai uma vez só.
-- 4. RPC public.lancar_escolta_retroativa(p_escolta_id, p_etapas, p_motivo, p_previa, p_resumo):
--    - só gestor e administrador (lote_interno.exigir_gestao(false)); motivo de 10 a 1000
--      caracteres (lote_interno.exigir_motivo), também na prévia;
--    - escolta existente, não excluída, não arquivada, sem emergência aberta;
--    - status de partida: Agendada até Na Base (lote_interno.retroativo_partidas). Rascunho
--      (não foi agendada), Finalizada e Cancelada são recusadas;
--    - etapas na ordem de lote_interno.sequencia_status() a partir do status atual, sem pular e
--      sem repetir, terminando SEMPRE em Finalizada. Parar numa etapa intermediária não é
--      aceito: a escolta ficaria "rodando" com o último registro no passado e o cron do
--      check-in (212/214) acusaria atraso na hora;
--    - horários com fuso explícito (ISO com Z ou +-HH:MM), ESTRITAMENTE crescentes (duas etapas
--      no mesmo instante deixariam a linha do tempo sem ordem), nenhum no futuro além de 5
--      minutos, nenhum com mais de 30 dias, e todos depois do último registro de campo válido
--      da escolta (lote_interno.ultimo_registro_campo; o planejamento, isto é, as linhas do
--      histórico que levam a Rascunho ou Agendada, não conta, para a escolta criada depois do
--      fato poder ser lançada);
--    - prévia (p_previa = true) devolve as etapas normalizadas, os avisos e o resumo
--      (versao_gestao, status, último registro e hash das etapas); a confirmação manda o
--      resumo de volta e é recusada se a escolta ou as etapas mudaram desde a prévia;
--    - grava, etapa a etapa e na ordem da registrar_etapa_escolta: um ponto por viatura (sem
--      latitude e longitude, retroativo = true, data_hora = horário operacional, registrado_em
--      = now()), o status e a linha de histórico (data_hora = horário operacional, via_rpc,
--      retroativo = true). data_finalizacao = horário informado para Finalizada. Não há coluna
--      data_inicio em escoltas: o início fica no histórico e no ponto de Saída da Base;
--    - fotos: sobem antes pelo caminho atual do storage (<prefixo>/<escolta_id>/<arquivo>) e a
--      linha de fotos é gravada pelo cliente sem latitude e longitude; aqui vêm só os ids em
--      p_etapas[].foto_ids (até 3 por etapa com ponto). A RPC confere (da escolta, do próprio
--      usuário, criada há menos de 1 dia, sem GPS, não usada em outro ponto) e marca
--      retroativo = true, origem = 'galeria', origem_localizacao = 'nenhuma' e
--      data_hora_captura = horário operacional da etapa (a hora real da captura não é lida do
--      arquivo). EXIF não é lido nesta versão;
--    - foto obrigatória ao vivo e ausente: o lançamento é aceito sem foto, com aviso na prévia,
--      "sem foto" no histórico e "sem_foto": true no JSON do ponto. Pré-início sem checklists
--      liga checklist_pendente_no_inicio (a trigger de sempre); KM e checklist de entrega não
--      são lançados aqui (aviso na prévia);
--    - pedidos de substituição pendentes são invalidados (a escolta deixa de estar agendada);
--    - escolta marcada (lancamento_retroativo, retroativo_por, retroativo_em, retroativo_motivo),
--      versao_gestao + 1, auditoria LANCAMENTO_RETROATIVO com antes e depois e um único aviso
--      (lote_interno.avisar_acao_gestao: central de avisos da supervisão e da equipe e um
--      resumo ao chat central do Telegram, chave gestao:retroativo:<escolta>:<versão>). Sem o
--      envio pelo banco ativo, o resumo fica só na central de avisos, como nas demais ações da
--      gestão (não há reenvio pelo navegador).
-- 5. Tipo de aviso lancamento_retroativo.
--
-- Não muda: concluir_escolta_antecipada (nem é chamada), registrar_etapa_escolta, as travas de
-- "nada é apagado" e a máquina de estados (as transições usadas são as lineares de sempre).
-- Reversão: 222_lancamento_retroativo_reverter.sql.

-- ── 1. Colunas ───────────────────────────────────────────────────────────────────────
ALTER TABLE public.escoltas
  ADD COLUMN IF NOT EXISTS lancamento_retroativo boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS retroativo_por        uuid REFERENCES public.usuarios(id),
  ADD COLUMN IF NOT EXISTS retroativo_em         timestamptz,
  ADD COLUMN IF NOT EXISTS retroativo_motivo     text;
COMMENT ON COLUMN public.escoltas.lancamento_retroativo IS
  '222: etapas lançadas depois do fato pela gestão (lancar_escolta_retroativa). Só muda pela RPC.';

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['escolta_status_historico', 'pontos_controle', 'fotos'] LOOP
    -- Sem padrão no ADD: as linhas antigas ficam NULAS (não recebem o horário da migration).
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS registrado_em timestamptz', t);
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN registrado_em SET DEFAULT now()', t);
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS retroativo boolean NOT NULL DEFAULT false', t);
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS motivo_retroativo text', t);
    EXECUTE format('COMMENT ON COLUMN public.%I.registrado_em IS %L', t,
      '222: horário do servidor em que a linha foi gravada. O horário operacional fica na coluna de sempre. NULO nas linhas anteriores à 222.');
    EXECUTE format('COMMENT ON COLUMN public.%I.retroativo IS %L', t,
      '222: gravado pelo lançamento retroativo da gestão (lancar_escolta_retroativa), não ao vivo.');
  END LOOP;
END $$;

ALTER TABLE public.fotos
  ADD COLUMN IF NOT EXISTS origem             text,
  ADD COLUMN IF NOT EXISTS origem_localizacao text;
COMMENT ON COLUMN public.fotos.origem IS '222: camera ou galeria. NULO nas fotos anteriores (todas da câmera ao vivo).';
COMMENT ON COLUMN public.fotos.origem_localizacao IS '222: gps (aparelho na hora), exif (lido do arquivo) ou nenhuma.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fotos_origem_valida' AND conrelid = 'public.fotos'::regclass) THEN
    ALTER TABLE public.fotos ADD CONSTRAINT fotos_origem_valida
      CHECK (origem IS NULL OR origem IN ('camera', 'galeria'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fotos_origem_localizacao_valida' AND conrelid = 'public.fotos'::regclass) THEN
    ALTER TABLE public.fotos ADD CONSTRAINT fotos_origem_localizacao_valida
      CHECK (origem_localizacao IS NULL OR origem_localizacao IN ('gps', 'exif', 'nenhuma'));
  END IF;
  -- Foto da galeria nunca leva o GPS do aparelho; "nenhuma" é sem coordenada.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fotos_galeria_sem_gps_do_aparelho' AND conrelid = 'public.fotos'::regclass) THEN
    ALTER TABLE public.fotos ADD CONSTRAINT fotos_galeria_sem_gps_do_aparelho
      CHECK ((origem IS DISTINCT FROM 'galeria' OR origem_localizacao IN ('exif', 'nenhuma'))
             AND (origem_localizacao IS DISTINCT FROM 'nenhuma' OR (latitude IS NULL AND longitude IS NULL)));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pontos_retroativo_sem_gps' AND conrelid = 'public.pontos_controle'::regclass) THEN
    ALTER TABLE public.pontos_controle ADD CONSTRAINT pontos_retroativo_sem_gps
      CHECK (NOT retroativo OR (latitude IS NULL AND longitude IS NULL));
  END IF;
END $$;

-- ── 2. Trava das colunas ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lote_interno.travar_colunas_retroativo() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_new jsonb; v_old jsonb; v_cols text[]; c text;
BEGIN
  -- registrado_em é do servidor: no INSERT, sempre now(); depois, não muda (salvo SQL direto).
  IF TG_TABLE_NAME <> 'escoltas' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.registrado_em := now();
    ELSIF auth.uid() IS NOT NULL THEN
      NEW.registrado_em := OLD.registrado_em;
    END IF;
  END IF;
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  -- Dupla guarda: variável de transação ligada pela RPC E perfil de quem chama.
  IF coalesce(current_setting('escolta.lancamento_retroativo', true), '') = 'on'
     AND public.get_meu_perfil() IN ('administrador', 'gestor') THEN
    RETURN NEW;
  END IF;
  v_cols := CASE TG_TABLE_NAME
    WHEN 'escoltas' THEN ARRAY['lancamento_retroativo', 'retroativo_por', 'retroativo_em', 'retroativo_motivo']
    WHEN 'fotos' THEN ARRAY['retroativo', 'motivo_retroativo', 'origem', 'origem_localizacao']
    ELSE ARRAY['retroativo', 'motivo_retroativo'] END;
  v_new := to_jsonb(NEW);
  v_old := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
  FOREACH c IN ARRAY v_cols LOOP
    IF TG_OP = 'INSERT' THEN
      IF coalesce(v_new -> c, 'null'::jsonb) NOT IN ('null'::jsonb, 'false'::jsonb) THEN
        RAISE EXCEPTION 'O campo % só é preenchido pelo lançamento retroativo da gestão.', c USING ERRCODE = '42501';
      END IF;
    ELSIF (v_new -> c) IS DISTINCT FROM (v_old -> c) THEN
      RAISE EXCEPTION 'O campo % só muda pelo lançamento retroativo da gestão.', c USING ERRCODE = '42501';
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.travar_colunas_retroativo() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['escoltas', 'escolta_status_historico', 'pontos_controle', 'fotos'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS tr_travar_colunas_retroativo ON public.%I', t);
    EXECUTE format('CREATE TRIGGER tr_travar_colunas_retroativo BEFORE INSERT OR UPDATE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION lote_interno.travar_colunas_retroativo()', t);
  END LOOP;
END $$;

-- ── 3. Silêncio durante o lançamento ─────────────────────────────────────────────────
-- Corpo da 202, com o retorno antecipado marcado. true = "tratado": quem chamou não cai no
-- caminho antigo (envio pelo navegador).
CREATE OR REPLACE FUNCTION public._enfileirar_aviso(p_chave text, p_destino text, p_escolta_id uuid, p_texto text)
    RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  -- 222: durante o lançamento retroativo nenhum aviso por etapa; o resumo sai no fim, uma vez.
  IF coalesce(current_setting('escolta.lancamento_retroativo', true), '') = 'on' THEN RETURN true; END IF;
  IF NOT public.avisos_pelo_banco_ativos() THEN RETURN false; END IF;
  INSERT INTO public.avisos_telegram (evento_chave, destino, escolta_id, texto, origem_usuario_id)
  VALUES (p_chave, p_destino, p_escolta_id, left(p_texto, 4000),
          (SELECT id FROM public.usuarios WHERE auth_user_id = auth.uid()))
  ON CONFLICT (evento_chave) DO NOTHING;
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public._enfileirar_aviso(text, text, uuid, text) FROM PUBLIC, anon, authenticated;

-- Corpo da 211, com o retorno antecipado marcado.
CREATE OR REPLACE FUNCTION lote_interno.notificar(p_chave text, p_escolta_id uuid, p_tipo text, p_usuarios uuid[],
                                                  p_titulo text, p_texto text, p_extra jsonb DEFAULT NULL)
    RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_tipo uuid; v_n int;
BEGIN
  -- 222: durante o lançamento retroativo nenhum aviso por etapa; o resumo sai no fim, uma vez.
  IF coalesce(current_setting('escolta.lancamento_retroativo', true), '') = 'on' THEN RETURN 0; END IF;
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

-- ── 4. Auxiliares internas ───────────────────────────────────────────────────────────
-- Status de partida aceitos (agendada até na_base). Espelho em lib/lancamento-retroativo.ts.
CREATE OR REPLACE FUNCTION lote_interno.retroativo_partidas() RETURNS text[]
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT ARRAY['agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino',
               'no_destino', 'em_transito_retorno', 'retornando', 'na_base']
$$;

-- Rótulo do ponto como a tela grava ao vivo (tipoLabel em observacoes).
CREATE OR REPLACE FUNCTION lote_interno.rotulo_ponto(p text) RETURNS text
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT CASE p
    WHEN 'base_saida' THEN 'Saída da Base' WHEN 'origem' THEN 'Chegada na Origem'
    WHEN 'transito_destino' THEN 'Trânsito ao Destino' WHEN 'destino' THEN 'Chegada no Destino'
    WHEN 'transito_retorno' THEN 'Trânsito para o Retorno' WHEN 'retorno' THEN 'Retorno'
    WHEN 'base_retorno' THEN 'Chegada na Base' ELSE p END
$$;

-- Último registro de campo válido da escolta. O planejamento (histórico que leva a rascunho
-- ou agendada) não conta: a escolta criada depois do fato pode ser lançada.
CREATE OR REPLACE FUNCTION lote_interno.ultimo_registro_campo(p_escolta_id uuid) RETURNS timestamptz
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT max(r.quando) FROM lote_interno.registros_validos(p_escolta_id) r
   WHERE NOT (r.tabela = 'escolta_status_historico' AND r.sub IN ('rascunho', 'agendada'))
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['retroativo_partidas()', 'rotulo_ponto(text)', 'ultimo_registro_campo(uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION lote_interno.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- ── 5. Tipo de aviso ─────────────────────────────────────────────────────────────────
INSERT INTO public.dom_tipos_evento (codigo, nome_exibicao, gera_notificacao, ativo)
SELECT 'lancamento_retroativo', 'Lançamento retroativo', true, true
WHERE NOT EXISTS (SELECT 1 FROM public.dom_tipos_evento d WHERE d.codigo = 'lancamento_retroativo');

-- ── 6. RPC ───────────────────────────────────────────────────────────────────────────
-- p_etapas: [{ "status": "em_pre_inicio", "data_hora": "2026-11-10T08:00:00-03:00",
--              "observacao": "opcional", "foto_ids": ["uuid", ...], "fotos_previstas": 2 }, ...]
-- fotos_previstas vale só na prévia (as fotos sobem entre a prévia e a confirmação).
CREATE OR REPLACE FUNCTION public.lancar_escolta_retroativa(p_escolta_id uuid, p_etapas jsonb, p_motivo text,
                                                            p_previa boolean DEFAULT false, p_resumo jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  e record; f record; v_eu uuid; v_motivo text; v_previa boolean := coalesce(p_previa, false);
  v_seq text[] := lote_interno.sequencia_status(); v_pos int; v_i int := 0; v_n int;
  v_et jsonb; v_status text; v_esperado text; v_anterior text; v_txt text; v_quando timestamptz; v_ant timestamptz;
  v_ultimo timestamptz; v_agora timestamptz := now(); v_obs text; v_tipo text; v_tipo_id uuid;
  v_fotos uuid[]; v_todas uuid[] := '{}'; v_fid uuid; v_qtd int; v_sem_foto boolean;
  v_norm jsonb := '[]'::jsonb; v_avisos jsonb := '[]'::jsonb; v_resumo jsonb; v_hash text;
  v_total_fotos int := 0; v_etapas_sem_foto int := 0; v_viaturas int; v_comboio boolean;
  v_pontos int := 0; v_hist int := 0; v_ped int := 0; v_linhas text[]; v_final timestamptz;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL OR e.excluida_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN
    RAISE EXCEPTION 'Escolta arquivada: recupere do arquivo antes do lançamento retroativo.';
  END IF;
  IF NOT e.status = ANY (lote_interno.retroativo_partidas()) THEN
    RAISE EXCEPTION 'Escolta em %: o lançamento retroativo vale para escolta de Agendada até Na Base.',
      lote_interno.rotulo_status(e.status);
  END IF;
  IF EXISTS (SELECT 1 FROM public.emergencias em WHERE em.escolta_id = p_escolta_id AND em.status <> 'encerrada' AND em.anulado_em IS NULL) THEN
    RAISE EXCEPTION 'Há emergência aberta nesta escolta: encerre a emergência antes.';
  END IF;
  IF p_etapas IS NULL OR jsonb_typeof(p_etapas) <> 'array' OR jsonb_array_length(p_etapas) = 0 THEN
    RAISE EXCEPTION 'Informe as etapas a lançar, da próxima etapa até Finalizada.';
  END IF;

  SELECT count(*) INTO v_viaturas FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id;
  v_comboio := v_viaturas > 1;
  v_ultimo := lote_interno.ultimo_registro_campo(p_escolta_id);
  v_pos := array_position(v_seq, e.status);
  v_anterior := e.status;

  -- Validação e normalização, etapa a etapa.
  FOR v_et IN SELECT value FROM jsonb_array_elements(p_etapas) WITH ORDINALITY AS x(value, ordem) ORDER BY ordem LOOP
    v_i := v_i + 1;
    v_esperado := v_seq[v_pos + v_i];
    v_status := v_et ->> 'status';
    IF v_esperado IS NULL THEN
      RAISE EXCEPTION 'Etapa a mais depois de Finalizada: o lançamento termina em Finalizada.';
    END IF;
    IF v_status IS NULL OR array_position(v_seq, v_status) IS NULL THEN
      RAISE EXCEPTION 'Etapa % sem status válido.', v_i;
    END IF;
    IF v_status = v_anterior OR array_position(v_seq, v_status) < array_position(v_seq, v_esperado) THEN
      RAISE EXCEPTION 'Etapa repetida ou fora de ordem: % já foi registrada. A próxima é %.',
        lote_interno.rotulo_status(v_status), lote_interno.rotulo_status(v_esperado);
    END IF;
    IF v_status <> v_esperado THEN
      RAISE EXCEPTION 'Etapa pulada: falta % antes de %.', lote_interno.rotulo_status(v_esperado), lote_interno.rotulo_status(v_status);
    END IF;

    v_txt := v_et ->> 'data_hora';
    IF v_txt IS NULL OR v_txt !~ '(Z|z|[+-][0-9]{2}(:?[0-9]{2})?)$' THEN
      RAISE EXCEPTION 'Horário de % sem fuso: informe data e hora com o fuso (Brasília).', lote_interno.rotulo_status(v_status);
    END IF;
    BEGIN
      v_quando := v_txt::timestamptz;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Horário inválido em %.', lote_interno.rotulo_status(v_status);
    END;
    IF v_quando > v_agora + interval '5 minutes' THEN
      RAISE EXCEPTION 'Horário no futuro em % (% em Brasília).', lote_interno.rotulo_status(v_status), public._hora_br(v_quando);
    END IF;
    IF v_quando < v_agora - interval '30 days' THEN
      RAISE EXCEPTION 'Lançamento retroativo vale para até 30 dias: % está em % (Brasília).',
        lote_interno.rotulo_status(v_status), public._hora_br(v_quando);
    END IF;
    IF v_ant IS NOT NULL AND v_quando <= v_ant THEN
      RAISE EXCEPTION 'Horários fora de ordem: % (%) precisa ser depois de % (%).',
        lote_interno.rotulo_status(v_status), public._hora_br(v_quando),
        lote_interno.rotulo_status(v_anterior), public._hora_br(v_ant);
    END IF;
    IF v_ultimo IS NOT NULL AND v_quando <= v_ultimo THEN
      RAISE EXCEPTION 'O horário de % (%) precisa ser depois do último registro da escolta (%, Brasília).',
        lote_interno.rotulo_status(v_status), public._hora_br(v_quando), public._hora_br(v_ultimo);
    END IF;

    v_obs := nullif(trim(coalesce(v_et ->> 'observacao', '')), '');
    IF length(v_obs) > 500 THEN
      RAISE EXCEPTION 'A observação de % pode ter no máximo 500 caracteres.', lote_interno.rotulo_status(v_status);
    END IF;

    v_tipo := lote_interno.tipo_ponto_da_etapa(v_status);
    IF v_tipo IS NOT NULL AND v_viaturas = 0 THEN
      RAISE EXCEPTION 'A escolta não tem viatura: inclua a viatura antes do lançamento retroativo.';
    END IF;
    IF (v_et -> 'foto_ids') IS NOT NULL AND jsonb_typeof(v_et -> 'foto_ids') NOT IN ('array', 'null') THEN
      RAISE EXCEPTION 'Fotos de % em formato inválido.', lote_interno.rotulo_status(v_status);
    END IF;
    BEGIN
      SELECT coalesce(array_agg(x::uuid), '{}') INTO v_fotos
        FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(v_et -> 'foto_ids') = 'array' THEN v_et -> 'foto_ids' ELSE '[]'::jsonb END) x;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'Foto inválida em %.', lote_interno.rotulo_status(v_status);
    END;
    IF cardinality(v_fotos) > 0 AND v_tipo IS NULL THEN
      RAISE EXCEPTION '% não tem ponto de controle: foto não se aplica a esta etapa.', lote_interno.rotulo_status(v_status);
    END IF;
    IF cardinality(v_fotos) > 3 THEN
      RAISE EXCEPTION 'No máximo 3 fotos em %.', lote_interno.rotulo_status(v_status);
    END IF;
    FOREACH v_fid IN ARRAY v_fotos LOOP
      IF v_fid = ANY (v_todas) THEN RAISE EXCEPTION 'A mesma foto foi enviada duas vezes.'; END IF;
      v_todas := v_todas || v_fid;
      SELECT * INTO f FROM public.fotos WHERE id = v_fid;
      IF f.id IS NULL
         OR public.escolta_do_caminho(f.caminho_arquivo) IS DISTINCT FROM p_escolta_id
         OR f.criado_por IS DISTINCT FROM v_eu
         OR f.retroativo
         OR f.criado_em < v_agora - interval '1 day'
         OR f.latitude IS NOT NULL OR f.longitude IS NOT NULL
         OR EXISTS (SELECT 1 FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
                     WHERE ev.escolta_id = p_escolta_id AND (pc.foto_id = v_fid OR pc.observacoes LIKE '%' || v_fid::text || '%')) THEN
        RAISE EXCEPTION 'Foto que não serve para este lançamento em % (de outra escolta, de outro usuário, antiga, com GPS ou já usada). Envie de novo pela tela.',
          lote_interno.rotulo_status(v_status);
      END IF;
    END LOOP;
    v_qtd := CASE WHEN v_tipo IS NULL THEN 0
                  WHEN v_previa AND cardinality(v_fotos) = 0
                  THEN greatest(least(coalesce((v_et ->> 'fotos_previstas')::int, 0), 3), 0)
                  ELSE cardinality(v_fotos) END;
    v_sem_foto := v_tipo IS NOT NULL AND v_qtd = 0;
    v_total_fotos := v_total_fotos + v_qtd;
    IF v_sem_foto THEN
      v_etapas_sem_foto := v_etapas_sem_foto + 1;
      v_avisos := v_avisos || to_jsonb(lote_interno.rotulo_status(v_status)
        || ' sem foto: ao vivo a etapa exige de 1 a 3 fotos por viatura. Será lançada sem foto, com a falta marcada no registro.');
    END IF;

    v_norm := v_norm || jsonb_build_array(jsonb_build_object(
      'ordem', v_i, 'status', v_status, 'rotulo', lote_interno.rotulo_status(v_status),
      'data_hora', v_quando, 'data_hora_br', public._hora_br(v_quando), 'observacao', v_obs,
      'tipo_ponto', v_tipo, 'foto_ids', to_jsonb(v_fotos), 'fotos', v_qtd, 'sem_foto', v_sem_foto));
    v_ant := v_quando;
    v_anterior := v_status;
  END LOOP;

  IF v_anterior <> 'finalizada' THEN
    RAISE EXCEPTION 'O lançamento precisa ir até Finalizada: falta %.', lote_interno.rotulo_status(v_seq[v_pos + v_i + 1]);
  END IF;
  v_final := v_ant;

  IF e.status IN ('agendada', 'em_pre_inicio') THEN
    v_avisos := v_avisos || to_jsonb('Checklists do pré-início e KM de saída não são lançados aqui: a escolta fica com o checklist pendente no início.'::text);
  END IF;
  v_avisos := v_avisos || to_jsonb('Fotos da viatura na finalização, checklist de entrega e KM de retorno não são lançados aqui.'::text);
  v_avisos := v_avisos || to_jsonb('Pontos sem localização: o lançamento não usa o GPS do aparelho.'::text);

  -- Resumo da prévia: a confirmação só vale para a mesma escolta e as mesmas etapas.
  SELECT md5(string_agg((x ->> 'status') || '|' || extract(epoch FROM (x ->> 'data_hora')::timestamptz)::bigint || '|' || coalesce(x ->> 'observacao', ''),
                        ',' ORDER BY (x ->> 'ordem')::int))
    INTO v_hash FROM jsonb_array_elements(v_norm) x;
  v_resumo := jsonb_build_object('versao_gestao', e.versao_gestao, 'status', e.status,
                                 'ultimo_registro', v_ultimo, 'hash', v_hash);

  IF v_previa THEN
    RETURN jsonb_build_object('previa', true, 'status_atual', e.status, 'rotulo_atual', lote_interno.rotulo_status(e.status),
      'etapas', v_norm, 'total_etapas', jsonb_array_length(v_norm), 'fotos', v_total_fotos, 'etapas_sem_foto', v_etapas_sem_foto,
      'viaturas', v_viaturas, 'data_finalizacao', v_final, 'data_finalizacao_br', public._hora_br(v_final),
      'ultimo_registro', v_ultimo, 'ultimo_registro_br', CASE WHEN v_ultimo IS NOT NULL THEN public._hora_br(v_ultimo) END,
      'motivo', v_motivo, 'avisos', v_avisos, 'resumo', v_resumo);
  END IF;
  IF p_resumo IS NULL OR jsonb_typeof(p_resumo) <> 'object' THEN
    RAISE EXCEPTION 'Confira antes: a confirmação precisa do resumo que a conferência devolve.';
  END IF;
  IF (p_resumo ->> 'versao_gestao') IS DISTINCT FROM (v_resumo ->> 'versao_gestao')
     OR (p_resumo ->> 'status') IS DISTINCT FROM (v_resumo ->> 'status')
     OR (p_resumo ->> 'ultimo_registro') IS DISTINCT FROM (v_resumo ->> 'ultimo_registro')
     OR (p_resumo ->> 'hash') IS DISTINCT FROM (v_resumo ->> 'hash') THEN
    RAISE EXCEPTION 'A escolta ou as etapas mudaram desde a conferência: confira de novo antes de confirmar.';
  END IF;

  -- Gravação. Mesma ordem da registrar_etapa_escolta: pontos, status, histórico.
  PERFORM lote_interno.modo_gestao(true);
  PERFORM set_config('escolta.lancamento_retroativo', 'on', true);
  v_anterior := e.status;
  FOR v_et IN SELECT value FROM jsonb_array_elements(v_norm) ORDER BY (value ->> 'ordem')::int LOOP
    v_status := v_et ->> 'status';
    v_quando := (v_et ->> 'data_hora')::timestamptz;
    v_obs := v_et ->> 'observacao';
    v_tipo := v_et ->> 'tipo_ponto';
    v_sem_foto := (v_et ->> 'sem_foto')::boolean;
    SELECT coalesce(array_agg(x::uuid), '{}') INTO v_fotos FROM jsonb_array_elements_text(v_et -> 'foto_ids') x;

    IF v_tipo IS NOT NULL THEN
      SELECT id INTO v_tipo_id FROM public.dom_tipos_ponto WHERE codigo = v_tipo;
      IF v_tipo_id IS NULL THEN RAISE EXCEPTION 'Tipo de ponto % não cadastrado.', v_tipo; END IF;
      INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, precisao_metros,
                                          sem_sinal_gps, foto_id, lancado_por, observacoes, sincronizado, criado_offline,
                                          retroativo, motivo_retroativo)
      SELECT ev.id, v_tipo_id, v_quando, NULL, NULL, NULL, false, v_fotos[1], v_eu,
             jsonb_build_object('tipo', v_tipo,
                                'tipoLabel', lote_interno.rotulo_ponto(v_tipo)
                                             || CASE WHEN v_comboio THEN ' (' || coalesce(ve.placa, 'sem placa') || ')' ELSE '' END,
                                'observacao', v_obs, 'foto_ids', to_jsonb(v_fotos), 'endereco', NULL, 'km', NULL,
                                'retroativo', true, 'sem_foto', v_sem_foto)::text,
             true, false, true, v_motivo
        FROM public.escolta_veiculos ev LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
       WHERE ev.escolta_id = p_escolta_id
       ORDER BY ev.criado_em;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_pontos := v_pontos + v_n;
      IF cardinality(v_fotos) > 0 THEN
        UPDATE public.fotos SET retroativo = true, motivo_retroativo = v_motivo, origem = 'galeria',
               origem_localizacao = 'nenhuma', data_hora_captura = v_quando
         WHERE id = ANY (v_fotos);
      END IF;
    END IF;

    UPDATE public.escoltas SET
           status = v_status,
           data_finalizacao = CASE WHEN v_status = 'finalizada' THEN v_quando ELSE data_finalizacao END,
           observacao_fechamento = CASE WHEN v_status = 'finalizada'
                                        THEN coalesce(v_obs, 'Lançamento retroativo. Motivo: ' || v_motivo)
                                        ELSE observacao_fechamento END
     WHERE id = p_escolta_id;

    INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora,
                                                 latitude, longitude, observacao, retroativo, motivo_retroativo)
    VALUES (p_escolta_id, v_anterior, v_status, v_eu, v_quando, NULL, NULL,
            'Lançamento retroativo' || CASE WHEN v_sem_foto THEN ', sem foto' ELSE '' END || '. '
              || coalesce(v_obs || '. ', '') || 'Motivo: ' || v_motivo,
            true, v_motivo);
    v_hist := v_hist + 1;
    v_anterior := v_status;
  END LOOP;

  UPDATE public.escoltas SET lancamento_retroativo = true, retroativo_por = v_eu, retroativo_em = now(),
         retroativo_motivo = v_motivo, versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
         observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: a escolta foi lançada retroativamente.')
   WHERE escolta_id = p_escolta_id AND status = 'pendente';
  GET DIAGNOSTICS v_ped = ROW_COUNT;

  -- Fim do silêncio: daqui em diante, o único resumo.
  PERFORM set_config('escolta.lancamento_retroativo', 'off', true);

  PERFORM lote_interno.auditar('LANCAMENTO_RETROATIVO', p_escolta_id,
    jsonb_build_object('status', e.status, 'data_finalizacao', e.data_finalizacao, 'observacao_fechamento', e.observacao_fechamento,
                       'checklist_pendente_no_inicio', e.checklist_pendente_no_inicio, 'lancamento_retroativo', e.lancamento_retroativo,
                       'ultimo_registro', v_ultimo, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', 'finalizada', 'etapas', v_norm, 'data_finalizacao', v_final, 'motivo', v_motivo,
                       'fotos', v_total_fotos, 'etapas_sem_foto', v_etapas_sem_foto, 'pontos', v_pontos, 'historico', v_hist,
                       'pedidos_invalidados', v_ped, 'lancamento_retroativo', true, 'registrado_em', now(),
                       'versao_gestao', e.versao_gestao + 1));

  v_linhas := ARRAY['Lançamento retroativo, de ' || lote_interno.rotulo_status(e.status) || ' até Finalizada. Horários em que aconteceu (Brasília):']
    || ARRAY(SELECT (x ->> 'ordem') || '. ' || (x ->> 'rotulo') || ': ' || (x ->> 'data_hora_br')
                    || CASE WHEN (x ->> 'sem_foto')::boolean THEN ' (sem foto)' ELSE '' END
               FROM jsonb_array_elements(v_norm) x ORDER BY (x ->> 'ordem')::int)
    || ARRAY['Fotos da galeria: ' || v_total_fotos || CASE WHEN v_etapas_sem_foto > 0 THEN '; etapas sem foto: ' || v_etapas_sem_foto ELSE '' END || '.',
             'Lançado por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão')
               || ' em ' || public._hora_br(now()) || ' (Brasília).',
             'Motivo: ' || v_motivo];
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'lancamento_retroativo',
    'retroativo:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    'Lançamento retroativo: ' || e.codigo_escolta, v_linhas);

  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'de', e.status, 'para', 'finalizada', 'etapas', jsonb_array_length(v_norm),
                            'pontos', v_pontos, 'fotos', v_total_fotos, 'etapas_sem_foto', v_etapas_sem_foto,
                            'data_finalizacao', v_final, 'pedidos_invalidados', v_ped);
END;
$$;

REVOKE ALL ON FUNCTION public.lancar_escolta_retroativa(uuid, jsonb, text, boolean, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lancar_escolta_retroativa(uuid, jsonb, text, boolean, jsonb) TO authenticated;

-- PostgREST: recarrega o cache de funções para a RPC nova aparecer já.
NOTIFY pgrst, 'reload schema';

-- Conferência: database/testes/05_lancamento_retroativo_conferencia.sql (uma linha, tudo true).
