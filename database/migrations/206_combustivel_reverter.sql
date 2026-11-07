-- 206_combustivel_reverter.sql
DROP TRIGGER IF EXISTS tr_impedir_combustivel_por_operador ON public.escolta_veiculos;
DROP FUNCTION IF EXISTS public.impedir_combustivel_por_operador();
