-- 206_combustivel.sql
-- Lote 2026-10, onda E (M3). Idempotente. Bloco 1 (antes do deploy).
--
-- Por quê: o custo real de combustível por viatura passa a ser lançado
-- (escolta_veiculos.abastecimento_litros e abastecimento_valor, colunas que já existiam
-- e que Indicadores, PDF e resumo financeiro já somam). A policy escolta_veiculos_escrita
-- vale também para o operador do efetivo (ele grava o KM), então sem esta trava o
-- operador gravaria o custo pela API. Os CHECK de valor não negativo já existem.

CREATE OR REPLACE FUNCTION public.impedir_combustivel_por_operador() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;          -- SQL Editor e migrations
  IF public.get_meu_perfil() = ANY (ARRAY['administrador', 'gestor', 'supervisor', 'central']) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.abastecimento_litros IS NOT NULL OR NEW.abastecimento_valor IS NOT NULL THEN
      RAISE EXCEPTION 'Combustivel e lancado pela supervisao.';
    END IF;
  ELSIF NEW.abastecimento_litros IS DISTINCT FROM OLD.abastecimento_litros
     OR NEW.abastecimento_valor IS DISTINCT FROM OLD.abastecimento_valor THEN
    RAISE EXCEPTION 'Combustivel e lancado pela supervisao.';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.impedir_combustivel_por_operador() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_impedir_combustivel_por_operador ON public.escolta_veiculos;
CREATE TRIGGER tr_impedir_combustivel_por_operador BEFORE INSERT OR UPDATE ON public.escolta_veiculos
  FOR EACH ROW EXECUTE FUNCTION public.impedir_combustivel_por_operador();
