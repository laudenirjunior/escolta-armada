-- 210_efetivo_unico.sql
-- Lote 2026-10, onda G (escolta com dois vigilantes). Idempotente. BLOCO 2: aplicar logo
-- DEPOIS do deploy, em seguida à 204. Não vai no bloco 1: o formulário da master não
-- recusa vigilante nem placa repetidos e grava a escolta em várias requisições, sem
-- transação; com o índice antes do deploy, um engano desses deixaria a escolta pela
-- metade (revisão adversarial G, achado 2). O formulário novo recusa a repetição antes
-- de gravar, e as RPCs da 204 tratam o índice com mensagem (sem erro técnico).
--
-- Por quê (docs/14, seção 10; analise/onda-g.md): escolta_efetivo e escolta_veiculos não
-- tinham restrição única. A tela de criação aceitava o mesmo vigilante duas vezes na
-- escolta (na mesma viatura ou em viaturas diferentes) e a mesma placa em duas viaturas,
-- e o ON CONFLICT DO NOTHING de assumir_escolta não tinha índice em que se apoiar.
--
-- O que faz:
-- 1. Conferência embutida: se já houver vigilante repetido na mesma escolta ou veículo
--    repetido na mesma escolta, aborta sem mudar nada (no backup de 08/10: 0 e 0). A
--    correção desses dados é decisão da gestão, fora deste pacote.
-- 2. Duas travas de unicidade: índice único (escolta_id, vigilante_id) no efetivo e
--    restrição UNIQUE (escolta_id, veiculo_id) nas viaturas da escolta.
--    A das viaturas é DEFERRABLE INITIALLY IMMEDIATE (revisão adversarial da onda I, médio 1):
--    vale na hora para todos, como um índice único, mas a editar_escolta (218) adia a
--    conferência para o fim da própria transação (SET CONSTRAINTS ... DEFERRED) e assim duas
--    viaturas da mesma escolta trocam de placa entre si com UPDATE de veiculo_id, sem apagar
--    linha. Nenhuma função nem tela usa ON CONFLICT em escolta_veiculos (o ON CONFLICT da 204
--    é em escolta_efetivo, e por isso o efetivo continua índice: ON CONFLICT não aceita
--    restrição adiável como árbitro).
--
-- A auditoria de devolver_escolta não é desta migration: vai na 217 (bloco 2).
--
-- Conferência (esperado: 2 linhas, as duas com indisunique = true; a das viaturas com
-- indimmediate = true e a restrição com condeferrable = true):
-- SELECT c.relname, i.indisunique, i.indimmediate FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
--  WHERE c.relname IN ('escolta_efetivo_escolta_vigilante_uk', 'escolta_veiculos_escolta_veiculo_uk');
-- SELECT condeferrable, condeferred FROM pg_constraint WHERE conname = 'escolta_veiculos_escolta_veiculo_uk';   -- true, false

DO $$
DECLARE
  v_vig int;
  v_vei int;
BEGIN
  SELECT count(*) INTO v_vig FROM (
    SELECT 1 FROM public.escolta_efetivo GROUP BY escolta_id, vigilante_id HAVING count(*) > 1
  ) d;
  SELECT count(*) INTO v_vei FROM (
    SELECT 1 FROM public.escolta_veiculos GROUP BY escolta_id, veiculo_id HAVING count(*) > 1
  ) d;
  IF v_vig > 0 OR v_vei > 0 THEN
    RAISE EXCEPTION '210: abortada sem mudar nada. Vigilante repetido na mesma escolta: % caso(s); veículo repetido na mesma escolta: % caso(s). Corrija pela gestão e aplique de novo.', v_vig, v_vei;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS escolta_efetivo_escolta_vigilante_uk
  ON public.escolta_efetivo (escolta_id, vigilante_id);
-- Viaturas: restrição adiável. Quem aplicou a versão anterior desta migration tem um índice
-- único simples com o mesmo nome: ele sai e entra a restrição (mesmas colunas, mesmo nome).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'escolta_veiculos_escolta_veiculo_uk'
                  AND conrelid = 'public.escolta_veiculos'::regclass) THEN
    DROP INDEX IF EXISTS public.escolta_veiculos_escolta_veiculo_uk;
    ALTER TABLE public.escolta_veiculos ADD CONSTRAINT escolta_veiculos_escolta_veiculo_uk
      UNIQUE (escolta_id, veiculo_id) DEFERRABLE INITIALLY IMMEDIATE;
  END IF;
END $$;

COMMENT ON INDEX public.escolta_efetivo_escolta_vigilante_uk IS
  'Lote 2026-10, onda G (210): o mesmo vigilante entra uma vez só em cada escolta, em qualquer viatura.';
COMMENT ON CONSTRAINT escolta_veiculos_escolta_veiculo_uk ON public.escolta_veiculos IS
  'Lote 2026-10, onda G (210): a mesma viatura entra uma vez só em cada escolta. Adiável só dentro da editar_escolta (troca de placas entre viaturas, onda I).';
