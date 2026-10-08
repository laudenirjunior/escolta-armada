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

-- Revisão adversarial da onda F: finalizar, cancelar e reagendar pela RPC; presença única.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '5 hours', 'na_base', 'qa_um')::text, true);
SELECT qa.como('qa_um');
DO $$
DECLARE r record;
BEGIN
  PERFORM public.registrar_etapa_escolta(current_setting('t.esc')::uuid, '[]', 'na_base', 'finalizada', 'fim', NULL, NULL, 'relatorio final QA');
  SELECT status, observacao_fechamento, data_finalizacao INTO r FROM public.escoltas WHERE id = current_setting('t.esc')::uuid;
  IF r.status = 'finalizada' AND r.observacao_fechamento = 'relatorio final QA' AND r.data_finalizacao IS NOT NULL
  THEN RAISE NOTICE 'PASSOU: operador finaliza pela RPC com relatorio e data de termino';
  ELSE RAISE NOTICE 'FALHOU: finalizacao %', r; END IF;
END $$;
ROLLBACK;
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '5 hours', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_supervisor');
DO $$
DECLARE r record;
BEGIN
  PERFORM public.registrar_etapa_escolta(current_setting('t.esc')::uuid, '[]', 'agendada', 'cancelada', 'Cancelamento: cliente desistiu', NULL, NULL, 'cliente desistiu');
  SELECT status, observacao_fechamento INTO r FROM public.escoltas WHERE id = current_setting('t.esc')::uuid;
  IF r.status = 'cancelada' AND r.observacao_fechamento = 'cliente desistiu' THEN RAISE NOTICE 'PASSOU: supervisor cancela pela RPC com o motivo';
  ELSE RAISE NOTICE 'FALHOU: cancelamento %', r; END IF;
END $$;
ROLLBACK;
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 hour', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_um');
DO $$
BEGIN
  PERFORM public.registrar_etapa_escolta(current_setting('t.esc')::uuid, '[]', 'agendada', 'agendada', 'x', NULL, NULL, NULL, now() + interval '2 days');
  RAISE NOTICE 'FALHOU: operador reagendou';
EXCEPTION WHEN raise_exception OR insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador nao reagenda';
END $$;
RESET ROLE;
SELECT qa.como('qa_supervisor');
DO $$
DECLARE r record;
BEGIN
  PERFORM public.registrar_etapa_escolta(current_setting('t.esc')::uuid, '[]', 'agendada', 'agendada', 'Reagendamento', NULL, NULL, NULL, now() + interval '2 days');
  SELECT status, observacao_fechamento, data_hora_prevista > now() + interval '1 day' AS remarcou INTO r FROM public.escoltas WHERE id = current_setting('t.esc')::uuid;
  IF r.status = 'agendada' AND r.observacao_fechamento IS NULL AND r.remarcou THEN RAISE NOTICE 'PASSOU: supervisor reagenda pela RPC com a nova data';
  ELSE RAISE NOTICE 'FALHOU: reagendamento %', r; END IF;
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: reagendamento recusado: %', SQLERRM;
END $$;
ROLLBACK;
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um')::text, true);
INSERT INTO public.fotos (id, caminho_arquivo, tipo_foto_id, data_hora_captura)
VALUES ('00000000-0000-4000-a000-00000000fafa', 'presenca/' || current_setting('t.esc') || '/p.jpg', (SELECT id FROM public.dom_tipos_foto LIMIT 1), now());
INSERT INTO public.presencas (id, escolta_id, vigilante_id, foto_id, data_hora, latitude, longitude)
VALUES ('00000000-0000-4000-a000-00000000fbfb', current_setting('t.esc')::uuid, qa.vigilante('qa_um'), '00000000-0000-4000-a000-00000000fafa', now(), -22.9, -43.3);
SELECT qa.como('qa_um');
DO $$
DECLARE a boolean; b boolean; c boolean;
BEGIN
  a := public.reservar_aviso_presenca('00000000-0000-4000-a000-00000000fbfb');
  b := public.reservar_aviso_presenca('00000000-0000-4000-a000-00000000fbfb');
  c := public.reservar_aviso_presenca('00000000-0000-4000-a000-00000000fbfb');
  IF a AND NOT b AND NOT c THEN RAISE NOTICE 'PASSOU: tres navegadores, so o primeiro envia a presenca';
  ELSE RAISE NOTICE 'FALHOU: reservas % % %', a, b, c; END IF;
END $$;
ROLLBACK;
