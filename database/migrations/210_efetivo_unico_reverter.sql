-- 210_efetivo_unico_reverter.sql
-- Tira as duas travas de unicidade da 210 (o índice do efetivo e a restrição das viaturas).
-- Nenhum dado muda. Depois da 218_reverter (a editar_escolta usa a restrição das viaturas).
DROP INDEX IF EXISTS public.escolta_efetivo_escolta_vigilante_uk;
ALTER TABLE public.escolta_veiculos DROP CONSTRAINT IF EXISTS escolta_veiculos_escolta_veiculo_uk;
DROP INDEX IF EXISTS public.escolta_veiculos_escolta_veiculo_uk;
