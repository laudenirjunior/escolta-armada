-- 210_efetivo_unico.sql
-- Lote 2026-10, onda G (escolta com dois vigilantes). Idempotente. Bloco 1 (antes do
-- deploy; compatível com o código da master, que nunca grava repetição de propósito).
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
-- 2. Dois índices únicos: (escolta_id, vigilante_id) no efetivo e (escolta_id, veiculo_id)
--    nas viaturas da escolta.
--
-- A auditoria de devolver_escolta não é desta migration: vai na 217 (bloco 2).
--
-- Conferência (esperado: 2 linhas):
-- SELECT indexname FROM pg_indexes WHERE schemaname = 'public'
--  AND indexname IN ('escolta_efetivo_escolta_vigilante_uk', 'escolta_veiculos_escolta_veiculo_uk');

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
CREATE UNIQUE INDEX IF NOT EXISTS escolta_veiculos_escolta_veiculo_uk
  ON public.escolta_veiculos (escolta_id, veiculo_id);

COMMENT ON INDEX public.escolta_efetivo_escolta_vigilante_uk IS
  'Lote 2026-10, onda G (210): o mesmo vigilante entra uma vez só em cada escolta, em qualquer viatura.';
COMMENT ON INDEX public.escolta_veiculos_escolta_veiculo_uk IS
  'Lote 2026-10, onda G (210): a mesma viatura entra uma vez só em cada escolta.';
