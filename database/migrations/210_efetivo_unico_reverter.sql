-- 210_efetivo_unico_reverter.sql
-- Tira os dois índices únicos da 210. Nenhum dado muda.
DROP INDEX IF EXISTS public.escolta_efetivo_escolta_vigilante_uk;
DROP INDEX IF EXISTS public.escolta_veiculos_escolta_veiculo_uk;
