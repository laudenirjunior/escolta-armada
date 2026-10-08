-- Lote 2026-10, onda C (M5): travas do mural.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa). Cada caso em transação própria, com ROLLBACK.
-- Esperado: só PASSOU e BLOQUEADO CORRETAMENTE. Os testes de concorrência ficam em
-- /opt/operacao/escolta-homolog/e2e/c_concorrencia.sh (precisam de duas sessões).
\set QUIET on
\pset tuples_only on

-- T1: fora da janela (prevista daqui a 3 h, janela de 60 min).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '3 hours', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_dois');
DO $$
BEGIN
  PERFORM public.assumir_escolta(current_setting('t.esc')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base');
  RAISE NOTICE 'FALHOU: pedido fora da janela foi aceito';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE '%liberada a partir de%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: fora da janela (%)', SQLERRM;
  ELSE RAISE NOTICE 'FALHOU: erro inesperado %', SQLERRM; END IF;
END $$;
ROLLBACK;

-- Motivo curto e T2 presença confirmada.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_dois');
DO $$
BEGIN
  PERFORM public.assumir_escolta(current_setting('t.esc')::uuid, '{}', NULL, 'curto');
  RAISE NOTICE 'FALHOU: motivo curto aceito';
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: motivo com menos de 20 caracteres';
END $$;
RESET ROLE;
SELECT qa.como('qa_um');
SELECT public.confirmar_presenca_base(current_setting('t.esc')::uuid, -22.918, -43.362, 8);
RESET ROLE;
SELECT qa.como('qa_dois');
DO $$
BEGIN
  PERFORM public.assumir_escolta(current_setting('t.esc')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base');
  RAISE NOTICE 'FALHOU: assumiu com presenca confirmada';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE '%confirmou presenca%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: presenca confirmada';
  ELSE RAISE NOTICE 'FALHOU: erro inesperado %', SQLERRM; END IF;
END $$;
ROLLBACK;

-- T3: pedido aprovado, com aviso no app, auditoria e um aviso na fila.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_dois');
SELECT set_config('t.ped', (public.assumir_escolta(current_setting('t.esc')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
RESET ROLE;
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.esc')::uuid AND vigilante_id = qa.vigilante('qa_um');
  IF n = 1 THEN RAISE NOTICE 'PASSOU: pedido criado sem trocar a equipe (status pendente)';
  ELSE RAISE NOTICE 'FALHOU: equipe trocada antes da decisao'; END IF;
END $$;
RESET ROLE;
SELECT qa.como('qa_supervisor');
SELECT public.aprovar_pedido_mural(current_setting('t.ped')::uuid, 'ok');
RESET ROLE;
DO $$
DECLARE cmd uuid; aud int; notif int; fila int;
BEGIN
  SELECT vigilante_id INTO cmd FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.esc')::uuid AND papel_na_escolta = 'comandante';
  SELECT count(*) INTO aud FROM public.logs_auditoria WHERE registro_id = current_setting('t.esc')::uuid AND acao = 'substituicao_de_equipe';
  SELECT count(*) INTO notif FROM public.notificacoes WHERE escolta_id = current_setting('t.esc')::uuid
    AND usuario_dest_id = (SELECT id FROM public.usuarios WHERE metadados->>'login' = 'qa_um');
  SELECT count(*) INTO fila FROM public.avisos_telegram WHERE evento_chave = 'substituicao:' || current_setting('t.ped');
  IF cmd = qa.vigilante('qa_dois') AND aud = 1 AND notif >= 1 AND fila = 1 THEN
    RAISE NOTICE 'PASSOU: aprovado, equipe trocada, auditoria, aviso a equipe substituida e 1 aviso na fila';
  ELSE RAISE NOTICE 'FALHOU: aprovado cmd_ok=% aud=% notif=% fila=%', cmd = qa.vigilante('qa_dois'), aud, notif, fila; END IF;
END $$;
ROLLBACK;

-- T3: pedido recusado.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_dois');
SELECT set_config('t.ped', (public.assumir_escolta(current_setting('t.esc')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
RESET ROLE;
SELECT qa.como('qa_supervisor');
SELECT public.recusar_pedido_mural(current_setting('t.ped')::uuid, 'a equipe avisou que esta chegando');
RESET ROLE;
DO $$
DECLARE cmd uuid; st text;
BEGIN
  SELECT vigilante_id INTO cmd FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.esc')::uuid AND papel_na_escolta = 'comandante';
  SELECT status INTO st FROM public.mural_pedidos WHERE id = current_setting('t.ped')::uuid;
  IF cmd = qa.vigilante('qa_um') AND st = 'recusado' THEN RAISE NOTICE 'PASSOU: recusado, equipe intacta';
  ELSE RAISE NOTICE 'FALHOU: recusa st=%', st; END IF;
END $$;
ROLLBACK;

-- T3: liberado por tempo (pelo banco, sem navegador).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_dois');
SELECT set_config('t.ped', (public.assumir_escolta(current_setting('t.esc')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
RESET ROLE;
UPDATE public.mural_pedidos SET expira_em = now() - interval '1 minute' WHERE id = current_setting('t.ped')::uuid;
SELECT public.processar_pedidos_vencidos();
DO $$
DECLARE cmd uuid; st text;
BEGIN
  SELECT vigilante_id INTO cmd FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.esc')::uuid AND papel_na_escolta = 'comandante';
  SELECT status INTO st FROM public.mural_pedidos WHERE id = current_setting('t.ped')::uuid;
  IF cmd = qa.vigilante('qa_dois') AND st = 'liberado_por_tempo' THEN RAISE NOTICE 'PASSOU: liberado por tempo, equipe trocada';
  ELSE RAISE NOTICE 'FALHOU: liberacao st=%', st; END IF;
END $$;
ROLLBACK;

-- T5: sobreposição de 6 h, para puxar e para assumir sem equipe.
BEGIN;
SELECT set_config('t.a', qa.nova_escolta(now() + interval '2 hours', 'agendada', 'qa_dois')::text, true);
SELECT set_config('t.b', qa.nova_escolta(now() + interval '5 hours', 'agendada', NULL)::text, true);
SELECT qa.como('qa_dois');
DO $$
BEGIN
  BEGIN PERFORM public.puxar_escolta(current_setting('t.b')::uuid); RAISE NOTICE 'FALHOU: puxou com sobreposicao';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: sobreposicao ao puxar'; END;
  BEGIN PERFORM public.assumir_escolta(current_setting('t.b')::uuid); RAISE NOTICE 'FALHOU: assumiu com sobreposicao';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: sobreposicao ao assumir'; END;
END $$;
ROLLBACK;

-- T6: escala fixa (puxar, assumir, devolver e incluir pelo comandante; gestão consegue).
BEGIN;
SELECT set_config('t.livre', qa.nova_escolta(now() + interval '30 minutes', 'agendada', NULL)::text, true);
SELECT set_config('t.cmd', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
UPDATE public.escoltas SET escala_fixa = true WHERE id IN (current_setting('t.livre')::uuid, current_setting('t.cmd')::uuid);
SELECT qa.como('qa_dois');
DO $$
BEGIN
  BEGIN PERFORM public.puxar_escolta(current_setting('t.livre')::uuid); RAISE NOTICE 'FALHOU: puxou escala fixa';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: puxar escala fixa'; END;
  BEGIN PERFORM public.assumir_escolta(current_setting('t.cmd')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base'); RAISE NOTICE 'FALHOU: pediu escala fixa';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: assumir escala fixa'; END;
END $$;
RESET ROLE;
SELECT qa.como('qa_um');
DO $$
BEGIN
  BEGIN PERFORM public.incluir_vigilante_na_minha_escolta(current_setting('t.cmd')::uuid, qa.vigilante('qa_tres')); RAISE NOTICE 'FALHOU: comandante incluiu em escala fixa';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: comandante incluindo em escala fixa'; END;
  BEGIN PERFORM public.devolver_escolta(current_setting('t.cmd')::uuid); RAISE NOTICE 'FALHOU: comandante devolveu escala fixa';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: comandante devolvendo escala fixa'; END;
END $$;
RESET ROLE;
SELECT qa.como('qa_supervisor');
DO $$
BEGIN
  PERFORM public.incluir_vigilante_na_minha_escolta(current_setting('t.cmd')::uuid, qa.vigilante('qa_tres'));
  PERFORM public.devolver_escolta(current_setting('t.cmd')::uuid);
  RAISE NOTICE 'PASSOU: supervisao inclui e devolve em escala fixa';
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: supervisao em escala fixa: %', SQLERRM;
END $$;
ROLLBACK;

-- Chamada direta às funções internas e ao próprio pedido.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_dois');
SELECT set_config('t.ped', (public.assumir_escolta(current_setting('t.esc')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
DO $$
BEGIN
  BEGIN PERFORM public._executar_substituicao(current_setting('t.ped')::uuid, 'aprovado'); RAISE NOTICE 'FALHOU: operador executou substituicao direto';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: _executar_substituicao pela API'; END;
  BEGIN PERFORM public.processar_pedidos_vencidos(); RAISE NOTICE 'FALHOU: operador chamou a liberacao por tempo';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: processar_pedidos_vencidos pela API'; END;
  BEGIN PERFORM public.aprovar_pedido_mural(current_setting('t.ped')::uuid); RAISE NOTICE 'FALHOU: operador aprovou pedido';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador aprovando pedido'; END;
  BEGIN UPDATE public.mural_pedidos SET status = 'aprovado'; RAISE NOTICE 'FALHOU: operador atualizou mural_pedidos';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: UPDATE direto em mural_pedidos'; END;
END $$;
ROLLBACK;
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
INSERT INTO public.mural_pedidos (escolta_id, solicitante_usuario_id, solicitante_vigilante_id, motivo, expira_em)
SELECT current_setting('t.esc')::uuid, u.id, qa.vigilante('qa_dois'), 'pedido de teste com vinte caracteres', now() + interval '15 minutes'
FROM public.usuarios u WHERE u.metadados->>'login' = 'qa_supervisor'
RETURNING set_config('t.ped', id::text, true);
SELECT qa.como('qa_supervisor');
DO $$
BEGIN
  PERFORM public.aprovar_pedido_mural(current_setting('t.ped')::uuid); RAISE NOTICE 'FALHOU: supervisor aprovou o proprio pedido';
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: supervisor decidindo o proprio pedido';
END $$;
ROLLBACK;

-- T7: auditoria de puxar, devolver e incluir.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '20 hours', 'agendada', NULL)::text, true);
SELECT qa.como('qa_tres');
SELECT public.puxar_escolta(current_setting('t.esc')::uuid);
SELECT public.incluir_vigilante_na_minha_escolta(current_setting('t.esc')::uuid, qa.vigilante('qa_dois'));
SELECT public.devolver_escolta(current_setting('t.esc')::uuid);
RESET ROLE;
DO $$
DECLARE acoes text;
BEGIN
  SELECT string_agg(acao, ',' ORDER BY acao) INTO acoes FROM public.logs_auditoria WHERE registro_id = current_setting('t.esc')::uuid;
  IF acoes = 'devolveu_escolta_ao_mural,incluiu_vigilante,puxou_escolta_do_mural' THEN RAISE NOTICE 'PASSOU: auditoria de puxar, incluir e devolver';
  ELSE RAISE NOTICE 'FALHOU: auditoria %', acoes; END IF;
END $$;
ROLLBACK;

-- Revisão adversarial da onda C.
-- Escala fixa só por supervisor ou acima (central e operador não), com trava própria.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_central');
DO $$
BEGIN
  UPDATE public.escoltas SET escala_fixa = true WHERE id = current_setting('t.esc')::uuid;
  RAISE NOTICE 'FALHOU: central marcou escala fixa';
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: central marcando escala fixa';
END $$;
RESET ROLE;
SELECT qa.como('qa_supervisor');
DO $$
BEGIN
  UPDATE public.escoltas SET escala_fixa = true WHERE id = current_setting('t.esc')::uuid;
  RAISE NOTICE 'PASSOU: supervisor marca escala fixa';
EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: supervisor nao marcou escala fixa: %', SQLERRM;
END $$;
ROLLBACK;

-- Escolta remarcada para fora da janela: o pedido pendente não executa ao vencer.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_dois');
SELECT set_config('t.ped', (public.assumir_escolta(current_setting('t.esc')::uuid, '{}', NULL, 'a equipe escalada nao apareceu na base') ->> 'pedido_id'), true);
RESET ROLE;
SELECT set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);  -- como o SQL Editor
UPDATE public.escoltas SET data_hora_prevista = now() + interval '1 day' WHERE id = current_setting('t.esc')::uuid;
UPDATE public.mural_pedidos SET expira_em = now() - interval '1 minute' WHERE id = current_setting('t.ped')::uuid;
SELECT public.processar_pedidos_vencidos();
DO $$
DECLARE cmd uuid; st text;
BEGIN
  SELECT vigilante_id INTO cmd FROM public.escolta_efetivo WHERE escolta_id = current_setting('t.esc')::uuid AND papel_na_escolta = 'comandante';
  SELECT status INTO st FROM public.mural_pedidos WHERE id = current_setting('t.ped')::uuid;
  IF cmd = qa.vigilante('qa_um') AND st = 'invalidado' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: escolta remarcada fora da janela nao troca a equipe';
  ELSE RAISE NOTICE 'FALHOU: remarcada st=%', st; END IF;
END $$;
ROLLBACK;

-- Motivo acima de 500 caracteres.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '30 minutes', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_dois');
DO $$
BEGIN
  PERFORM public.assumir_escolta(current_setting('t.esc')::uuid, '{}', NULL, repeat('motivo longo ', 50));
  RAISE NOTICE 'FALHOU: motivo de 650 caracteres aceito';
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: motivo acima de 500 caracteres';
END $$;
ROLLBACK;
