-- 216_uf_e_paleta_reverter.sql
-- ORDEM: primeiro o git revert do código da onda K e o deploy; depois este arquivo (antes da
-- 215_reverter). Guarda UF, marcas de estimada e coordenadas em backup_20261008.escoltas_uf
-- (uma linha por escolta com UF ou marca; rodar de novo atualiza) e a cor de cada cliente no
-- momento em backup_20261008.cores_reversao, para a reaplicação da 216 devolver as duas coisas
-- sem transformar em estimada uma UF que não era e sem mudar cor escolhida (revisão K, menor
-- 13). Devolve a cor antiga (backup_20261008.cores_clientes) aos clientes que continuam com a
-- cor da carga (quem trocou de cor depois da 216 fica com a da paleta, que também é válida),
-- devolve o DEFAULT antigo da cor, tira as triggers de cor e de UF, a paleta, as RPCs
-- uf_da_coordenada e cores_clientes_das_escoltas, as funções internas, a malha, o índice, as
-- restrições e as colunas (a gerada primeiro) e recria impedir_edicao_por_operador com o corpo
-- da 197. A lista de conferência (backup_20261008.uf_a_conferir) e os backups ficam.
CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'escoltas' AND column_name = 'origem_uf') THEN
    CREATE TABLE IF NOT EXISTS backup_20261008.escoltas_uf (escolta_id uuid PRIMARY KEY, codigo_escolta text,
      origem_uf text, destino_uf text, guardado_em timestamptz NOT NULL DEFAULT now());
    ALTER TABLE backup_20261008.escoltas_uf ADD COLUMN IF NOT EXISTS origem_uf_estimada boolean;
    ALTER TABLE backup_20261008.escoltas_uf ADD COLUMN IF NOT EXISTS destino_uf_estimada boolean;
    ALTER TABLE backup_20261008.escoltas_uf ADD COLUMN IF NOT EXISTS origem_lat numeric;
    ALTER TABLE backup_20261008.escoltas_uf ADD COLUMN IF NOT EXISTS origem_lng numeric;
    ALTER TABLE backup_20261008.escoltas_uf ADD COLUMN IF NOT EXISTS destino_lat numeric;
    ALTER TABLE backup_20261008.escoltas_uf ADD COLUMN IF NOT EXISTS destino_lng numeric;
    REVOKE ALL ON backup_20261008.escoltas_uf FROM PUBLIC, anon, authenticated;
    EXECUTE $q$
      INSERT INTO backup_20261008.escoltas_uf (escolta_id, codigo_escolta, origem_uf, destino_uf, origem_uf_estimada, destino_uf_estimada,
                                               origem_lat, origem_lng, destino_lat, destino_lng)
      SELECT id, codigo_escolta, origem_uf, destino_uf, origem_uf_estimada, destino_uf_estimada,
             origem_lat, origem_lng, destino_lat, destino_lng FROM public.escoltas
       WHERE origem_uf IS NOT NULL OR destino_uf IS NOT NULL OR origem_uf_estimada OR destino_uf_estimada
      ON CONFLICT (escolta_id) DO UPDATE SET origem_uf = EXCLUDED.origem_uf, destino_uf = EXCLUDED.destino_uf,
        origem_uf_estimada = EXCLUDED.origem_uf_estimada, destino_uf_estimada = EXCLUDED.destino_uf_estimada,
        origem_lat = EXCLUDED.origem_lat, origem_lng = EXCLUDED.origem_lng, destino_lat = EXCLUDED.destino_lat,
        destino_lng = EXCLUDED.destino_lng, guardado_em = now()$q$;
  END IF;
END $$;

-- Triggers e funções da UF no servidor.
DROP TRIGGER IF EXISTS tr_escoltas_uf_2_recalcular ON public.escoltas;
DROP TRIGGER IF EXISTS tr_escoltas_uf_1_informada_origem ON public.escoltas;
DROP TRIGGER IF EXISTS tr_escoltas_uf_1_informada_destino ON public.escoltas;
DROP FUNCTION IF EXISTS lote_interno.recalcular_uf_escolta();
DROP FUNCTION IF EXISTS lote_interno.anotar_uf_informada();

-- Cor: trigger fora antes de devolver a cor antiga (senão ela voltaria para a paleta).
DROP TRIGGER IF EXISTS tr_normalizar_cor_cliente ON public.clientes;
DROP FUNCTION IF EXISTS lote_interno.normalizar_cor_cliente();
DO $$
BEGIN
  IF to_regclass('backup_20261008.cores_clientes') IS NOT NULL AND to_regclass('public.paleta_clientes') IS NOT NULL THEN
    -- Cor de cada cliente agora (para a reaplicação) e a que a reversão devolve.
    CREATE TABLE IF NOT EXISTS backup_20261008.cores_reversao (cliente_id uuid PRIMARY KEY, cor_na_reversao text,
      cor_devolvida text, guardado_em timestamptz NOT NULL DEFAULT now());
    REVOKE ALL ON backup_20261008.cores_reversao FROM PUBLIC, anon, authenticated;
    INSERT INTO backup_20261008.cores_reversao (cliente_id, cor_na_reversao, cor_devolvida)
    SELECT c.id, c.cor_destaque,
           CASE WHEN b.cliente_id IS NOT NULL AND c.cor_destaque IS NOT DISTINCT FROM b.cor_nova THEN b.cor_antiga ELSE c.cor_destaque END
      FROM public.clientes c LEFT JOIN backup_20261008.cores_clientes b ON b.cliente_id = c.id
    ON CONFLICT (cliente_id) DO UPDATE SET cor_na_reversao = EXCLUDED.cor_na_reversao, cor_devolvida = EXCLUDED.cor_devolvida,
      guardado_em = now();
    UPDATE public.clientes c SET cor_destaque = b.cor_antiga
      FROM backup_20261008.cores_clientes b
     WHERE b.cliente_id = c.id AND c.cor_destaque IS NOT DISTINCT FROM b.cor_nova
       AND c.cor_destaque IS DISTINCT FROM b.cor_antiga;
  END IF;
END $$;
ALTER TABLE public.clientes ALTER COLUMN cor_destaque SET DEFAULT '#3B82F6'::text;
DROP FUNCTION IF EXISTS lote_interno.cor_da_paleta(text, text[]);
DROP TABLE IF EXISTS public.paleta_clientes;
DROP FUNCTION IF EXISTS lote_interno.cor_lab(text);

-- UF.
DROP FUNCTION IF EXISTS public.cores_clientes_das_escoltas(uuid[]);
DROP FUNCTION IF EXISTS public.uf_da_coordenada(double precision, double precision);
DROP FUNCTION IF EXISTS lote_interno.carregar_uf_escoltas();
DROP FUNCTION IF EXISTS lote_interno.uf_do_ponto(double precision, double precision);
DROP FUNCTION IF EXISTS lote_interno.uf_mais_proxima(double precision, double precision, text);
DROP FUNCTION IF EXISTS lote_interno.distancia_ao_anel_km(double precision, double precision, double precision[], double precision[]);
DROP FUNCTION IF EXISTS lote_interno.ponto_no_anel(double precision, double precision, double precision[], double precision[]);
DROP TABLE IF EXISTS lote_interno.malha_uf_aneis;
DROP TABLE IF EXISTS lote_interno.malha_uf;
DROP INDEX IF EXISTS public.idx_escoltas_interestadual;
ALTER TABLE public.escoltas DROP CONSTRAINT IF EXISTS escoltas_origem_uf_formato;
ALTER TABLE public.escoltas DROP CONSTRAINT IF EXISTS escoltas_destino_uf_formato;
ALTER TABLE public.escoltas DROP COLUMN IF EXISTS interestadual;
ALTER TABLE public.escoltas DROP COLUMN IF EXISTS destino_uf_estimada;
ALTER TABLE public.escoltas DROP COLUMN IF EXISTS origem_uf_estimada;
ALTER TABLE public.escoltas DROP COLUMN IF EXISTS destino_uf;
ALTER TABLE public.escoltas DROP COLUMN IF EXISTS origem_uf;

-- Corpo da 197 (sem as colunas da UF).
CREATE OR REPLACE FUNCTION public.impedir_edicao_por_operador() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text;
  v_col    text;
  v_old    jsonb;
  v_new    jsonb;
BEGIN
  -- Sem sessao de usuario final: SQL direto, migration ou service role. Passa, como nas
  -- demais funcoes deste banco, por ser a via de reparo.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil = ANY (ARRAY['administrador','gestor','supervisor','central']) THEN
    RETURN NEW;
  END IF;

  -- Daqui para baixo e operador ou vigilante. Ele so pode mover a escolta pelo fluxo:
  -- status, e os carimbos que o proprio avanco preenche.
  -- ATENCAO (lote 2026-10): esta trigger compara checklist_pendente_no_inicio, que a
  -- tr_verificar_checklist_pendente grava no mesmo UPDATE. Funciona porque as BEFORE
  -- UPDATE rodam em ordem alfabetica e tr_impedir_... vem antes de tr_verificar_...
  -- Nao renomear nenhuma das duas sem rever isto.
  IF NEW.cliente_id          IS DISTINCT FROM OLD.cliente_id
     OR NEW.data_hora_prevista IS DISTINCT FROM OLD.data_hora_prevista
     OR NEW.origem_endereco  IS DISTINCT FROM OLD.origem_endereco
     OR NEW.origem_lat       IS DISTINCT FROM OLD.origem_lat
     OR NEW.origem_lng       IS DISTINCT FROM OLD.origem_lng
     OR NEW.destino_endereco IS DISTINCT FROM OLD.destino_endereco
     OR NEW.destino_lat      IS DISTINCT FROM OLD.destino_lat
     OR NEW.destino_lng      IS DISTINCT FROM OLD.destino_lng
  THEN
    RAISE EXCEPTION 'Operador nao edita dados da escolta. Fale com o supervisor para alterar cliente, data ou local.';
  END IF;

  -- Lote 2026-10: financeiro, controle do fluxo e escala. Comparacao por jsonb para valer
  -- tambem para coluna criada depois desta funcao (escala_fixa, onda C).
  v_old := to_jsonb(OLD);
  v_new := to_jsonb(NEW);
  -- Escolta encerrada não muda mais pelo operador (relatório final e horário de término).
  IF OLD.status IN ('finalizada', 'cancelada') THEN
    RAISE EXCEPTION 'Escolta encerrada. Fale com o supervisor para corrigir.';
  END IF;

  -- Relatório final e término só junto da própria finalização.
  IF (NEW.observacao_fechamento IS DISTINCT FROM OLD.observacao_fechamento
      OR NEW.data_finalizacao IS DISTINCT FROM OLD.data_finalizacao)
     AND NEW.status IS DISTINCT FROM 'finalizada' THEN
    RAISE EXCEPTION 'O relatorio final so e gravado na finalizacao da escolta.';
  END IF;

  FOREACH v_col IN ARRAY ARRAY['valor_cobrado','outros_custos','observacao_financeira','fluxo_versao',
                               'checklist_pendente_no_inicio','periodicidade_checkin_min','codigo_escolta',
                               'criada_por','escala_fixa','metadados','data_solicitacao','criado_em']
  LOOP
    IF (v_new -> v_col) IS DISTINCT FROM (v_old -> v_col) THEN
      RAISE EXCEPTION 'Operador nao altera este campo da escolta (%). Fale com o supervisor.', v_col;
    END IF;
  END LOOP;

  IF NEW.status = 'cancelada' AND OLD.status IS DISTINCT FROM 'cancelada' THEN
    RAISE EXCEPTION 'Somente a supervisao cancela uma escolta.';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.impedir_edicao_por_operador() FROM PUBLIC, anon, authenticated;
