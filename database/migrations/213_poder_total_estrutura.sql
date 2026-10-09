-- 213_poder_total_estrutura.sql
-- Lote 2026-10, onda I (adendo 01, item 4.3). Idempotente. Bloco 1, depois da 212.
-- Aditiva e compatível com a master 2b3fff9: só acrescenta colunas com padrão, tabelas,
-- view e triggers que preenchem ou recusam valores que o código antigo nunca manda.
--
-- Por quê (docs/14, seção 12.2): gestor e administrador passam a voltar etapa, zerar,
-- concluir com pendências e arquivar escoltas. Nada é apagado: os registros de campo da
-- etapa desfeita ficam ANULADOS (marcados), e as telas e o banco passam a contar só os
-- válidos. Esta migration cria só a estrutura; as travas vêm na 214 e as RPCs na 218.
--
-- O que faz:
-- 1. escoltas: arquivada_em, arquivada_por, motivo_arquivamento, reiniciada_em (S15) e
--    versao_gestao (incrementada só por voltar etapa, zerar, concluir antes, arquivar e
--    recuperar; nunca pela edição). ADD COLUMN com padrão constante não reescreve a linha
--    nem dispara trigger: ESC-2026-0001 e ESC-2026-0007 não mudam (atualizado_em igual).
-- 2. Anulação (anulado_em, anulado_por, motivo_anulacao, anulacao_id) nas 9 tabelas de
--    campo; fotos e checklist_respostas herdam do pai.
-- 3. Carimbo de etapa status_escolta_no_registro, preenchido por trigger BEFORE INSERT com
--    o status da escolta no momento (o valor mandado pelo cliente é ignorado).
-- 4. escolta_resets (histórico das voltas de etapa e zerar, com os valores guardados).
-- 5. escolta_conclusoes_antecipadas e vw_pendencias_conclusao (uma linha por item).
-- 6. Trava das colunas da gestão (tr_travar_colunas_gestao_<tabela>): UPDATE de anulado_*,
--    arquivada_*, versao_gestao, reiniciada_em, status_escolta_no_registro e via_rpc só com
--    a variável de transação escolta.rpc_gestao ligada E perfil administrador ou gestor
--    (dupla guarda: ligar a variável sozinho não basta), ou sem usuário final (auth.uid()
--    nulo: migrations, SQL Editor e cron). No INSERT, recusa só valor diferente do padrão
--    (nulo e 0 passam); o carimbo fica fora da trava de INSERT (é a trigger da 213.3 que o
--    preenche), e a ordem entre as duas triggers não importa.
-- 7. escolta_status_historico.via_rpc, ligada pela variável escolta.historico_rpc (as RPCs
--    a ligam: registrar_etapa_escolta na 214 e as da 218). Linha gravada direto pelo
--    cliente fica false. A anulação por janela de tempo usa só linhas via_rpc.
-- 8. pontos_controle.lancado_por nulo vira o usuário da sessão (a master pode mandar
--    user?.id nulo com sessão válida; a policy da 214 confere o autor depois disto).
-- Chaves estrangeiras de anulado_por, arquivada_por, concluida_por e feito_por para
-- usuarios SEM ação (18.8, item 7): excluir quem anulou ou arquivou é recusado.
-- Reversão: 213_poder_total_estrutura_reverter.sql (depois da 214), que guarda as colunas
-- novas e as tabelas em backup_20261008 antes de remover.

-- 1. Arquivamento, reinício e versão da gestão.
ALTER TABLE public.escoltas
  ADD COLUMN IF NOT EXISTS arquivada_em        timestamptz,
  ADD COLUMN IF NOT EXISTS arquivada_por       uuid REFERENCES public.usuarios(id),
  ADD COLUMN IF NOT EXISTS motivo_arquivamento text,
  ADD COLUMN IF NOT EXISTS reiniciada_em       timestamptz,
  ADD COLUMN IF NOT EXISTS versao_gestao       integer NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_escoltas_nao_arquivadas
  ON public.escoltas (status, data_hora_prevista) WHERE arquivada_em IS NULL;
COMMENT ON COLUMN public.escoltas.arquivada_em IS 'Lote 2026-10 (onda I): arquivada pela gestão (some das listas, do mural, do Campo e dos indicadores). Só pela RPC arquivar_escolta.';
COMMENT ON COLUMN public.escoltas.reiniciada_em IS 'Lote 2026-10 (onda I, S15): última vez que a gestão zerou a escolta para agendada.';
COMMENT ON COLUMN public.escoltas.versao_gestao IS 'Lote 2026-10 (onda I): +1 a cada voltar etapa, zerar, concluir antes, arquivar e recuperar. A edição não muda. Usada pela onda L para detectar conflito.';

-- 2 e 3. Anulação e carimbo de etapa nas tabelas de campo.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico']
  LOOP
    EXECUTE format('ALTER TABLE public.%I
      ADD COLUMN IF NOT EXISTS anulado_em timestamptz,
      ADD COLUMN IF NOT EXISTS anulado_por uuid REFERENCES public.usuarios(id),
      ADD COLUMN IF NOT EXISTS motivo_anulacao text,
      ADD COLUMN IF NOT EXISTS anulacao_id uuid,
      ADD COLUMN IF NOT EXISTS status_escolta_no_registro text', t);
    EXECUTE format('COMMENT ON COLUMN public.%I.anulado_em IS %L', t,
      'Lote 2026-10 (onda I): registro anulado pela gestão (voltar etapa ou zerar). Não é apagado; não conta como válido.');
    EXECUTE format('COMMENT ON COLUMN public.%I.status_escolta_no_registro IS %L', t,
      'Lote 2026-10 (onda I): status da escolta quando o registro foi gravado (trigger; o valor do cliente é ignorado). Nulo nos registros anteriores à 213.');
  END LOOP;
END $$;
CREATE INDEX IF NOT EXISTS idx_anulacao_pontos ON public.pontos_controle (anulacao_id) WHERE anulacao_id IS NOT NULL;

-- 7. Histórico gravado por RPC.
ALTER TABLE public.escolta_status_historico ADD COLUMN IF NOT EXISTS via_rpc boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.escolta_status_historico.via_rpc IS
  'Lote 2026-10 (onda I): true quando a linha foi gravada por uma RPC do servidor (variável escolta.historico_rpc). Linhas do cliente ficam false e não servem de âncora para a anulação.';

-- 3 e 7. Carimbo (BEFORE INSERT). SECURITY DEFINER: lê o status mesmo de escolta que a RLS
-- de quem grava esconderia.
CREATE OR REPLACE FUNCTION lote_interno.carimbar_etapa() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_j jsonb := to_jsonb(NEW); v_esc uuid; v_status text;
BEGIN
  IF v_j ? 'escolta_id' THEN
    v_esc := (v_j ->> 'escolta_id')::uuid;
  ELSE
    SELECT ev.escolta_id INTO v_esc FROM public.escolta_veiculos ev WHERE ev.id = (v_j ->> 'escolta_veiculo_id')::uuid;
  END IF;
  SELECT e.status INTO v_status FROM public.escoltas e WHERE e.id = v_esc;
  NEW.status_escolta_no_registro := v_status;
  IF TG_TABLE_NAME = 'escolta_status_historico' THEN
    NEW.via_rpc := coalesce(current_setting('escolta.historico_rpc', true), '') = 'on';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.carimbar_etapa() FROM PUBLIC, anon, authenticated;

-- 6. Trava das colunas da gestão (BEFORE INSERT OR UPDATE).
CREATE OR REPLACE FUNCTION lote_interno.travar_colunas_gestao() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_new jsonb := to_jsonb(NEW); v_old jsonb; v_cols text[]; c text;
BEGIN
  -- Sem usuário final (migration, SQL Editor, cron): passa, como na 197 e na 206.
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  -- Dupla guarda: variável de transação ligada pela RPC E perfil de quem chama.
  IF coalesce(current_setting('escolta.rpc_gestao', true), '') = 'on'
     AND public.get_meu_perfil() IN ('administrador', 'gestor') THEN
    RETURN NEW;
  END IF;
  IF TG_TABLE_NAME = 'escoltas' THEN
    v_cols := ARRAY['arquivada_em', 'arquivada_por', 'motivo_arquivamento', 'reiniciada_em', 'versao_gestao'];
  ELSE
    v_cols := ARRAY['anulado_em', 'anulado_por', 'motivo_anulacao', 'anulacao_id'];
  END IF;
  IF TG_OP = 'INSERT' THEN
    FOREACH c IN ARRAY v_cols LOOP
      IF (c = 'versao_gestao' AND coalesce((v_new ->> c)::int, 0) <> 0)
         OR (c <> 'versao_gestao' AND jsonb_typeof(v_new -> c) IS DISTINCT FROM 'null' AND v_new ? c) THEN
        RAISE EXCEPTION 'O campo % só é preenchido pelas ações da gestão.', c USING ERRCODE = '42501';
      END IF;
    END LOOP;
    RETURN NEW;
  END IF;
  v_old := to_jsonb(OLD);
  IF TG_TABLE_NAME <> 'escoltas' THEN
    v_cols := v_cols || ARRAY['status_escolta_no_registro'];
    IF v_new ? 'via_rpc' THEN v_cols := v_cols || ARRAY['via_rpc']; END IF;
  END IF;
  FOREACH c IN ARRAY v_cols LOOP
    IF (v_new -> c) IS DISTINCT FROM (v_old -> c) THEN
      RAISE EXCEPTION 'O campo % só muda pelas ações da gestão.', c USING ERRCODE = '42501';
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.travar_colunas_gestao() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_carimbar_etapa_' || t, t);
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION lote_interno.carimbar_etapa()',
                   'tr_carimbar_etapa_' || t, t);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_travar_colunas_gestao_' || t, t);
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION lote_interno.travar_colunas_gestao()',
                   'tr_travar_colunas_gestao_' || t, t);
  END LOOP;
END $$;
DROP TRIGGER IF EXISTS tr_travar_colunas_gestao_escoltas ON public.escoltas;
CREATE TRIGGER tr_travar_colunas_gestao_escoltas BEFORE INSERT OR UPDATE ON public.escoltas
  FOR EACH ROW EXECUTE FUNCTION lote_interno.travar_colunas_gestao();

-- 8. Autor do ponto preenchido no servidor quando vier nulo.
CREATE OR REPLACE FUNCTION lote_interno.preencher_lancado_por() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF NEW.lancado_por IS NULL THEN NEW.lancado_por := public.get_meu_usuario_id(); END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.preencher_lancado_por() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_preencher_lancado_por ON public.pontos_controle;
CREATE TRIGGER tr_preencher_lancado_por BEFORE INSERT ON public.pontos_controle
  FOR EACH ROW EXECUTE FUNCTION lote_interno.preencher_lancado_por();

-- 4. Voltas de etapa e zerar.
CREATE TABLE IF NOT EXISTS public.escolta_resets (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id         uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  status_de          text NOT NULL,
  status_para        text NOT NULL,
  tipo               text NOT NULL CHECK (tipo IN ('voltar_etapa', 'zerar')),
  motivo             text NOT NULL,
  feito_por          uuid REFERENCES public.usuarios(id),
  feito_em           timestamptz NOT NULL DEFAULT now(),
  anulacao_id        uuid NOT NULL,
  valores_anteriores jsonb NOT NULL DEFAULT '{}'::jsonb,   -- KM por viatura, checklist_pendente_no_inicio, data_finalizacao, observacao_fechamento
  contagem           jsonb NOT NULL DEFAULT '{}'::jsonb    -- quantos registros foram anulados, por tabela
);
CREATE INDEX IF NOT EXISTS idx_escolta_resets_escolta ON public.escolta_resets (escolta_id, feito_em DESC);
ALTER TABLE public.escolta_resets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.escolta_resets FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.escolta_resets TO authenticated;
DROP POLICY IF EXISTS escolta_resets_leitura ON public.escolta_resets;
CREATE POLICY escolta_resets_leitura ON public.escolta_resets FOR SELECT TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']));
COMMENT ON TABLE public.escolta_resets IS 'Lote 2026-10 (onda I): voltas de etapa e zerar feitos pela gestão. Escrita só pelas RPCs da 218.';

-- 5. Conclusão antecipada e pendências.
CREATE TABLE IF NOT EXISTS public.escolta_conclusoes_antecipadas (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id        uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  status_no_momento text NOT NULL,
  motivo            text NOT NULL,
  concluida_por     uuid REFERENCES public.usuarios(id),
  concluida_em      timestamptz NOT NULL DEFAULT now(),
  pendencias        jsonb NOT NULL DEFAULT '[]'::jsonb,
  anulado_em        timestamptz,
  anulado_por       uuid REFERENCES public.usuarios(id),
  motivo_anulacao   text,
  anulacao_id       uuid
);
CREATE UNIQUE INDEX IF NOT EXISTS escolta_conclusoes_antecipadas_valida_uk
  ON public.escolta_conclusoes_antecipadas (escolta_id) WHERE anulado_em IS NULL;
ALTER TABLE public.escolta_conclusoes_antecipadas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.escolta_conclusoes_antecipadas FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.escolta_conclusoes_antecipadas TO authenticated;
DROP POLICY IF EXISTS escolta_conclusoes_leitura ON public.escolta_conclusoes_antecipadas;
CREATE POLICY escolta_conclusoes_leitura ON public.escolta_conclusoes_antecipadas FOR SELECT TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor'])
         OR public.sou_do_efetivo(escolta_id));
COMMENT ON TABLE public.escolta_conclusoes_antecipadas IS
  'Lote 2026-10 (onda I): escolta concluída pela gestão antes do fim, com a lista do que não foi feito (calculada no servidor). Uma válida por escolta.';

-- Uma linha por item não feito (security_invoker: vale a RLS de quem lê).
CREATE OR REPLACE VIEW public.vw_pendencias_conclusao WITH (security_invoker = on) AS
SELECT c.id                              AS conclusao_id,
       c.escolta_id,
       e.codigo_escolta,
       e.cliente_id,
       et ->> 'etapa'                    AS etapa,
       et ->> 'rotulo'                   AS rotulo_etapa,
       (vt ->> 'escolta_veiculo_id')::uuid AS escolta_veiculo_id,
       vt ->> 'placa'                    AS placa,
       it.item,
       c.concluida_por,
       c.concluida_em,
       c.motivo                          AS observacao,
       c.status_no_momento
FROM public.escolta_conclusoes_antecipadas c
JOIN public.escoltas e ON e.id = c.escolta_id
CROSS JOIN LATERAL jsonb_array_elements(c.pendencias) et
CROSS JOIN LATERAL jsonb_array_elements(coalesce(et -> 'viaturas', '[]'::jsonb)) vt
CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(vt -> 'faltando', '[]'::jsonb)) AS it(item)
WHERE c.anulado_em IS NULL;
REVOKE ALL ON public.vw_pendencias_conclusao FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.vw_pendencias_conclusao TO authenticated;

-- Conferência:
-- SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND column_name = 'anulado_em';   -- 10 (9 tabelas + conclusões)
-- SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_carimbar_etapa_%';          -- 9
-- SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_travar_colunas_gestao_%';   -- 10
-- SELECT count(*) FROM escoltas WHERE versao_gestao <> 0 OR arquivada_em IS NOT NULL; -- 0
