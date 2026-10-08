-- Lote 2026-10, onda F: etapa atômica (ponto, status e histórico) e avisos pelo servidor.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa). Esperado: só PASSOU e BLOQUEADO CORRETAMENTE.
\set QUIET on
\pset tuples_only on

-- Transição recusada não deixa ponto nem histórico.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um')::text, true);
SELECT qa.como('qa_um');
DO $$
DECLARE v_ev uuid; n int; h int;
BEGIN
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = current_setting('t.esc')::uuid;
  BEGIN
    PERFORM public.registrar_etapa_escolta(current_setting('t.esc')::uuid,
      jsonb_build_array(jsonb_build_object('escolta_veiculo_id', v_ev, 'tipo_ponto_id', (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'origem'),
        'latitude', -22.8, 'longitude', -43.3, 'lancado_por', public.get_meu_usuario_id())),
      'na_origem', 'em_transito_destino');   -- status atual errado de propósito
    RAISE NOTICE 'FALHOU: transicao com status atual errado foi aceita';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  SELECT count(*) INTO n FROM public.pontos_controle WHERE escolta_veiculo_id = v_ev;
  SELECT count(*) INTO h FROM public.escolta_status_historico WHERE escolta_id = current_setting('t.esc')::uuid;
  IF n = 0 AND h = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: transicao recusada nao deixa ponto nem historico';
  ELSE RAISE NOTICE 'FALHOU: sobrou ponto=% historico=%', n, h; END IF;
END $$;
ROLLBACK;

-- Comboio: a etapa só avança com o ponto das duas viaturas; histórico com autor e GPS.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um', 2)::text, true);
SELECT qa.como('qa_um');
DO $$
DECLARE v1 uuid; v2 uuid; tp uuid; r jsonb; st text; h record;
BEGIN
  SELECT id INTO v1 FROM public.escolta_veiculos WHERE escolta_id = current_setting('t.esc')::uuid ORDER BY criado_em LIMIT 1;
  SELECT id INTO v2 FROM public.escolta_veiculos WHERE escolta_id = current_setting('t.esc')::uuid ORDER BY criado_em OFFSET 1 LIMIT 1;
  SELECT id INTO tp FROM public.dom_tipos_ponto WHERE codigo = 'origem';
  r := public.registrar_etapa_escolta(current_setting('t.esc')::uuid,
         jsonb_build_array(jsonb_build_object('escolta_veiculo_id', v1, 'tipo_ponto_id', tp, 'latitude', -22.8, 'longitude', -43.3, 'lancado_por', public.get_meu_usuario_id())),
         'em_andamento', 'na_origem', 'chegada', -22.8, -43.3, NULL, NULL, tp);
  SELECT status INTO st FROM public.escoltas WHERE id = current_setting('t.esc')::uuid;
  IF NOT (r ->> 'avancou')::boolean AND st = 'em_andamento' AND jsonb_array_length(r -> 'faltando') = 1
  THEN RAISE NOTICE 'PASSOU: primeira viatura grava o ponto e a etapa espera a segunda (%)', r -> 'faltando';
  ELSE RAISE NOTICE 'FALHOU: comboio primeira viatura % %', r, st; END IF;
  r := public.registrar_etapa_escolta(current_setting('t.esc')::uuid,
         jsonb_build_array(jsonb_build_object('escolta_veiculo_id', v2, 'tipo_ponto_id', tp, 'latitude', -22.8, 'longitude', -43.3, 'lancado_por', public.get_meu_usuario_id())),
         'em_andamento', 'na_origem', 'chegada', -22.8, -43.3, NULL, NULL, tp);
  SELECT status INTO st FROM public.escoltas WHERE id = current_setting('t.esc')::uuid;
  SELECT alterado_por, latitude INTO h FROM public.escolta_status_historico WHERE escolta_id = current_setting('t.esc')::uuid AND status_novo = 'na_origem';
  IF (r ->> 'avancou')::boolean AND st = 'na_origem' AND h.alterado_por = public.get_meu_usuario_id() AND h.latitude IS NOT NULL
  THEN RAISE NOTICE 'PASSOU: segunda viatura avanca a etapa, historico com autor e GPS';
  ELSE RAISE NOTICE 'FALHOU: comboio segunda viatura % %', r, st; END IF;
END $$;
ROLLBACK;

-- Operador de fora não registra etapa (RLS de quem chama).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um')::text, true);
SELECT qa.como('qa_dois');
DO $$
BEGIN
  PERFORM public.registrar_etapa_escolta(current_setting('t.esc')::uuid, '[]', 'em_andamento', 'na_origem');
  RAISE NOTICE 'FALHOU: operador de fora avancou a etapa';
EXCEPTION WHEN raise_exception OR insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador de fora nao registra etapa';
END $$;
ROLLBACK;

-- Alerta de check-in: uma linha na fila por prazo vencido, mesmo chamado várias vezes.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '2 hours', 'em_transito_destino', 'qa_um', 1, 10)::text, true);
INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por)
SELECT id, 'e1601f15-5ef9-44e8-abd0-17f65b3aa760', now() - interval '40 minutes', -22.8, -43.3, qa.usuario('qa_um') FROM public.escolta_veiculos WHERE escolta_id = current_setting('t.esc')::uuid;
SELECT qa.como('qa_um');
SELECT public.enfileirar_alerta_checkin(current_setting('t.esc')::uuid);
SELECT public.enfileirar_alerta_checkin(current_setting('t.esc')::uuid);
SELECT public.enfileirar_alerta_checkin(current_setting('t.esc')::uuid);
RESET ROLE;
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.avisos_telegram WHERE escolta_id = current_setting('t.esc')::uuid AND evento_chave LIKE 'checkin:%';
  IF n = 1 THEN RAISE NOTICE 'PASSOU: tres chamadas, um aviso de check-in na fila';
  ELSE RAISE NOTICE 'FALHOU: % avisos de check-in na fila', n; END IF;
END $$;
ROLLBACK;
