-- Lote 2026-10, onda E (M3): combustível só pela gestão; KM continua com o operador.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa). Esperado: só PASSOU e BLOQUEADO CORRETAMENTE.
\set QUIET on
\pset tuples_only on
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um', 2)::text, true);
SELECT qa.como('qa_um');
DO $$
BEGIN
  BEGIN
    UPDATE public.escolta_veiculos SET abastecimento_valor = 100 WHERE escolta_id = current_setting('t.esc')::uuid;
    RAISE NOTICE 'FALHOU: operador lancou combustivel';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador lancando combustivel';
  END;
  UPDATE public.escolta_veiculos SET quilometragem_retorno = 1200 WHERE escolta_id = current_setting('t.esc')::uuid;
  RAISE NOTICE 'PASSOU: operador continua gravando o KM';
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: operador nao gravou KM: %', SQLERRM;
END $$;
RESET ROLE;
SELECT qa.como('qa_supervisor');
DO $$
DECLARE n int;
BEGIN
  UPDATE public.escolta_veiculos SET abastecimento_litros = 40, abastecimento_valor = 250 WHERE escolta_id = current_setting('t.esc')::uuid;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 2 THEN RAISE NOTICE 'PASSOU: supervisor lanca combustivel nas duas viaturas';
  ELSE RAISE NOTICE 'FALHOU: supervisor atualizou % viaturas', n; END IF;
  BEGIN
    UPDATE public.escolta_veiculos SET abastecimento_valor = -1 WHERE escolta_id = current_setting('t.esc')::uuid;
    RAISE NOTICE 'FALHOU: valor negativo aceito';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: valor negativo';
  END;
END $$;
ROLLBACK;
