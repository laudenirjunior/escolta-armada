-- Lote 2026-10, onda J (aviso de 2 segundos e central): migrations 211, 212 e 217.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa). Esperado: só PASSOU e BLOQUEADO CORRETAMENTE.
-- Cada bloco roda numa transação desfeita no fim (o cron não enxerga nada do teste).
\set QUIET on
\pset tuples_only on

-- ── Estrutura e privilégios ────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE n int; v_lista text;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'notificacoes' AND column_name IN ('lida_em', 'titulo', 'texto', 'evento_chave');
  IF n = 4 THEN RAISE NOTICE 'PASSOU: notificacoes tem lida_em, titulo, texto e evento_chave';
  ELSE RAISE NOTICE 'FALHOU: % de 4 colunas da central', n; END IF;

  SELECT count(*) INTO n FROM pg_proc WHERE pronamespace = 'lote_interno'::regnamespace;
  SELECT string_agg(p.proname, ', ') INTO v_lista FROM pg_proc p
   WHERE p.pronamespace = 'lote_interno'::regnamespace
     AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF n >= 5 AND v_lista IS NULL THEN
    RAISE NOTICE 'PASSOU: nenhuma das % funções do lote_interno é executável por anon ou authenticated', n;
  ELSE RAISE NOTICE 'FALHOU: lote_interno com % funções; executáveis por anon ou authenticated: %', n, v_lista; END IF;

  IF has_schema_privilege('anon', 'lote_interno', 'USAGE') OR has_schema_privilege('authenticated', 'lote_interno', 'USAGE') THEN
    RAISE NOTICE 'FALHOU: anon ou authenticated com USAGE no lote_interno';
  ELSE RAISE NOTICE 'BLOQUEADO CORRETAMENTE: lote_interno sem USAGE para anon e authenticated'; END IF;

  -- Observação: ALTER DEFAULT PRIVILEGES por schema não retira o EXECUTE global de PUBLIC
  -- (limite do PostgreSQL); a garantia é o REVOKE explícito em cada função, conferido acima.
  IF has_table_privilege('anon', 'public.notificacoes', 'SELECT') OR has_table_privilege('anon', 'public.notificacoes', 'TRUNCATE')
     OR has_table_privilege('authenticated', 'public.notificacoes', 'INSERT') OR has_table_privilege('authenticated', 'public.notificacoes', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.notificacoes', 'DELETE') OR has_table_privilege('authenticated', 'public.notificacoes', 'TRUNCATE') THEN
    RAISE NOTICE 'FALHOU: privilégio de escrita ou de anon em notificacoes';
  ELSE RAISE NOTICE 'BLOQUEADO CORRETAMENTE: anon sem acesso e authenticated sem escrita direta em notificacoes'; END IF;

  SELECT count(*) INTO n FROM pg_policy WHERE polrelid = 'public.notificacoes'::regclass;
  IF n = 1 AND EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.notificacoes'::regclass AND polname = 'notificacoes_select' AND polcmd = 'r') THEN
    RAISE NOTICE 'PASSOU: só a policy de leitura da própria caixa em notificacoes';
  ELSE RAISE NOTICE 'FALHOU: % policies em notificacoes', n; END IF;

  SELECT count(*) INTO n FROM cron.job WHERE jobname = 'lote2026_avisos_checkin' AND command LIKE '%lote_interno.gerar_avisos_checkin%';
  IF n = 1 THEN RAISE NOTICE 'PASSOU: job lote2026_avisos_checkin agendado no pg_cron';
  ELSE RAISE NOTICE 'FALHOU: job do check-in agendado % vezes', n; END IF;

  IF (SELECT prosrc LIKE '%lote_interno.notificar%' FROM pg_proc WHERE oid = 'public._avisar_app(uuid, text, uuid[], text, text, uuid)'::regprocedure)
     AND (SELECT prosrc LIKE '%lida_em%' FROM pg_proc WHERE oid = 'public.marcar_aviso_lido(uuid)'::regprocedure)
     AND (SELECT prosrc LIKE '%lote_interno.enfileirar_alerta_checkin%' FROM pg_proc WHERE oid = 'public.enfileirar_alerta_checkin(uuid)'::regprocedure) THEN
    RAISE NOTICE 'PASSOU: corpos finais com os acréscimos (_avisar_app, marcar_aviso_lido e enfileirar_alerta_checkin)';
  ELSE RAISE NOTICE 'FALHOU: corpo de _avisar_app, marcar_aviso_lido ou enfileirar_alerta_checkin sem o acréscimo da onda J'; END IF;
END $$;
ROLLBACK;

-- ── Gatilho de sincronia lida e lida_em ────────────────────────────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 day')::text, true);
SELECT lote_interno.notificar('teste_j:sinc', current_setting('t.esc')::uuid, 'checkin_vencido',
  ARRAY[qa.usuario('qa_um'), qa.usuario('qa_dois')], 'Título', 'Texto');
DO $$
DECLARE a record; b record;
BEGIN
  UPDATE public.notificacoes SET lida = true WHERE evento_chave = 'teste_j:sinc' AND usuario_dest_id = qa.usuario('qa_um');
  UPDATE public.notificacoes SET lida_em = now() - interval '1 hour' WHERE evento_chave = 'teste_j:sinc' AND usuario_dest_id = qa.usuario('qa_dois');
  SELECT lida, lida_em INTO a FROM public.notificacoes WHERE evento_chave = 'teste_j:sinc' AND usuario_dest_id = qa.usuario('qa_um');
  SELECT lida, lida_em INTO b FROM public.notificacoes WHERE evento_chave = 'teste_j:sinc' AND usuario_dest_id = qa.usuario('qa_dois');
  IF a.lida AND a.lida_em IS NOT NULL AND b.lida AND b.lida_em IS NOT NULL THEN
    RAISE NOTICE 'PASSOU: gatilho acerta lida_em quando lida muda e lida quando lida_em é gravada';
  ELSE RAISE NOTICE 'FALHOU: sincronia lida=% lida_em=% / lida=% lida_em=%', a.lida, a.lida_em, b.lida, b.lida_em; END IF;
  -- Mesma chave para a mesma pessoa não grava de novo.
  IF lote_interno.notificar('teste_j:sinc', current_setting('t.esc')::uuid, 'checkin_vencido', ARRAY[qa.usuario('qa_um')], 'x', 'y') = 0
     AND (SELECT count(*) FROM public.notificacoes WHERE evento_chave = 'teste_j:sinc') = 2 THEN
    RAISE NOTICE 'PASSOU: chave repetida não duplica o aviso (uma linha por destinatário)';
  ELSE RAISE NOTICE 'FALHOU: chave repetida duplicou o aviso'; END IF;
END $$;
ROLLBACK;

-- ── Check-in vencido pelo servidor: um aviso por período, destinatários S2 ─────────
BEGIN;
-- Nenhuma outra escolta aberta com periodicidade participa (dados QA anteriores).
SET LOCAL session_replication_role = replica;
UPDATE public.escoltas SET periodicidade_checkin_min = NULL WHERE status NOT IN ('finalizada', 'cancelada');
SET LOCAL session_replication_role = origin;
-- Escolta em rua, periodicidade 5 min, efetivo qa_um, primeiro ponto há 6 min (referência).
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um', 1, 5)::text, true);
INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por, observacoes)
SELECT ev.id, (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'origem'), now() - interval '6 min', -22.8, -43.3, qa.usuario('qa_um'),
       '{texto legado que parece JSON'
FROM public.escolta_veiculos ev WHERE ev.escolta_id = current_setting('t.esc')::uuid;
-- Escolta sem periodicidade e escolta agendada com periodicidade: nunca geram aviso.
SELECT set_config('t.sem', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_dois', 1, NULL)::text, true);
SELECT set_config('t.agd', qa.nova_escolta(now() - interval '1 hour', 'agendada', 'qa_tres', 1, 5)::text, true);
SELECT lote_interno.gerar_avisos_checkin();
SELECT lote_interno.gerar_avisos_checkin();
SELECT lote_interno.gerar_avisos_checkin();
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; n int; ch int; dest text;
BEGIN
  SELECT count(*), count(DISTINCT evento_chave) INTO n, ch FROM public.notificacoes
   WHERE escolta_id = e AND tipo_evento_id = (SELECT id FROM public.dom_tipos_evento WHERE codigo = 'checkin_vencido')
     AND usuario_dest_id = qa.usuario('qa_gestor');
  IF n = 1 AND ch = 1 THEN RAISE NOTICE 'PASSOU: três ciclos no mesmo período geram 1 linha para o gestor';
  ELSE RAISE NOTICE 'FALHOU: mesmo período gerou % linhas (% chaves)', n, ch; END IF;
  SELECT string_agg(u.metadados ->> 'login', ',' ORDER BY u.metadados ->> 'login') INTO dest
  FROM public.notificacoes n2 JOIN public.usuarios u ON u.id = n2.usuario_dest_id
  WHERE n2.escolta_id = e AND u.metadados ->> 'login' LIKE 'qa\_%';
  IF dest = 'qa_administrador,qa_central,qa_gestor,qa_supervisor,qa_um' THEN
    RAISE NOTICE 'PASSOU: destinatários S2 (efetivo, administrador, gestor, supervisor e central; não os outros operadores)';
  ELSE RAISE NOTICE 'FALHOU: destinatários QA = %', dest; END IF;
  IF (SELECT bool_and(evento_chave LIKE 'checkin:' || e || ':%:1' AND texto LIKE '%periodicidade de 5 min%' AND texto ~ '\d{2}/\d{2}/\d{4} \d{2}:\d{2} \(Brasília\)')
      FROM public.notificacoes WHERE escolta_id = e) THEN
    RAISE NOTICE 'PASSOU: chave checkin:<escolta>:<referência>:<período> e texto com periodicidade e hora de Brasília';
  ELSE RAISE NOTICE 'FALHOU: chave ou texto do aviso de check-in fora do formato'; END IF;
  SELECT count(*) INTO n FROM public.notificacoes WHERE escolta_id IN (current_setting('t.sem')::uuid, current_setting('t.agd')::uuid);
  IF n = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: escolta sem periodicidade ou fora da rua não gera aviso';
  ELSE RAISE NOTICE 'FALHOU: % avisos para escolta sem periodicidade ou agendada', n; END IF;
END $$;
-- Relógio adiantado em um período: novo aviso; o mesmo período continua com uma linha.
SELECT lote_interno.gerar_avisos_checkin(now() + interval '5 min');
SELECT lote_interno.gerar_avisos_checkin(now() + interval '5 min');
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.notificacoes WHERE escolta_id = current_setting('t.esc')::uuid AND usuario_dest_id = qa.usuario('qa_gestor');
  IF n = 2 THEN RAISE NOTICE 'PASSOU: o período seguinte gera um segundo aviso (2 linhas para o gestor)';
  ELSE RAISE NOTICE 'FALHOU: período seguinte deixou % linhas', n; END IF;
END $$;
-- Check-in registrado (PARADA com reporte_periodico há 1 min): referência nova, em dia.
INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por, observacoes)
SELECT ev.id, 'e1601f15-5ef9-44e8-abd0-17f65b3aa760', now() - interval '1 min', -22.8, -43.3, qa.usuario('qa_um'),
       '{"tipo":"reporte_periodico","tipoLabel":"Reporte Periódico"}'
FROM public.escolta_veiculos ev WHERE ev.escolta_id = current_setting('t.esc')::uuid;
DO $$
DECLARE n int;
BEGIN
  n := lote_interno.gerar_avisos_checkin();
  IF n = 0 THEN RAISE NOTICE 'PASSOU: depois do check-in (reporte_periodico) o cron não avisa';
  ELSE RAISE NOTICE 'FALHOU: % avisos logo depois do check-in', n; END IF;
END $$;
ROLLBACK;

-- ── Telegram do check-in pelo cron (S4): uma mensagem por período, sem navegador ───
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE public.escoltas SET periodicidade_checkin_min = NULL WHERE status NOT IN ('finalizada', 'cancelada');
SET LOCAL session_replication_role = origin;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_transito_destino', 'qa_um', 1, 10)::text, true);
-- Regra antiga: só PARADA conta; última parada há 12 min, periodicidade 10.
INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por, observacoes)
SELECT ev.id, 'e1601f15-5ef9-44e8-abd0-17f65b3aa760', now() - interval '12 min', -22.8, -43.3, qa.usuario('qa_um'), 'parada em texto puro'
FROM public.escolta_veiculos ev WHERE ev.escolta_id = current_setting('t.esc')::uuid;
SELECT lote_interno.gerar_avisos_checkin();
SELECT lote_interno.gerar_avisos_checkin();
SELECT lote_interno.gerar_avisos_checkin();
DO $$
DECLARE n int; v_ativo boolean := public.avisos_pelo_banco_ativos();
BEGIN
  SELECT count(*) INTO n FROM public.avisos_telegram WHERE escolta_id = current_setting('t.esc')::uuid AND evento_chave LIKE 'checkin:%';
  IF v_ativo AND n = 1 THEN RAISE NOTICE 'PASSOU: cron enfileira 1 mensagem de Telegram do check-in em três ciclos';
  ELSIF NOT v_ativo THEN RAISE NOTICE 'FALHOU: envio pelo banco desligado na homologação (segredos do Vault)';
  ELSE RAISE NOTICE 'FALHOU: % mensagens de Telegram do check-in', n; END IF;
END $$;
-- A RPC da 208 continua: gestão pede e a chave segura a mensagem; operador de fora é recusado.
SELECT qa.como('qa_gestor');
SELECT public.enfileirar_alerta_checkin(current_setting('t.esc')::uuid);
RESET ROLE;
SELECT qa.como('qa_tres');
DO $$
BEGIN
  PERFORM public.enfileirar_alerta_checkin(current_setting('t.esc')::uuid);
  RAISE NOTICE 'FALHOU: operador de fora pediu o alerta da escolta';
EXCEPTION WHEN others THEN
  IF SQLERRM LIKE '%Sem permissao%' THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador de fora não pede alerta de check-in';
  ELSE RAISE NOTICE 'FALHOU: erro inesperado: %', SQLERRM; END IF;
END $$;
RESET ROLE;
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.avisos_telegram WHERE escolta_id = current_setting('t.esc')::uuid AND evento_chave LIKE 'checkin:%';
  IF n = 1 THEN RAISE NOTICE 'PASSOU: pedido pela RPC da 208 depois do cron não duplica a mensagem';
  ELSE RAISE NOTICE 'FALHOU: % mensagens depois do pedido pela RPC', n; END IF;
END $$;
ROLLBACK;

-- ── Caixa pessoal: leitura só da própria, sem escrita direta ───────────────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 day', 'agendada', 'qa_um')::text, true);
SELECT lote_interno.notificar('teste_j:caixa', current_setting('t.esc')::uuid, 'edicao_escolta',
  ARRAY[qa.usuario('qa_um'), qa.usuario('qa_dois'), qa.usuario('qa_gestor')], 'Escolta editada', 'Texto do teste');
SELECT lote_interno.notificar('teste_j:caixa2', current_setting('t.esc')::uuid, 'checkin_vencido',
  ARRAY[qa.usuario('qa_um')], 'Check-in', 'Texto do teste');
SELECT set_config('t.outro', (SELECT id::text FROM public.notificacoes WHERE evento_chave = 'teste_j:caixa' AND usuario_dest_id = qa.usuario('qa_dois')), true);
SELECT qa.como('qa_um');
DO $$
DECLARE n int; m int; v jsonb;
BEGIN
  SELECT count(*) INTO n FROM public.notificacoes WHERE evento_chave LIKE 'teste_j:%';
  SELECT count(*) INTO m FROM public.notificacoes WHERE usuario_dest_id <> public.get_meu_usuario_id();
  v := public.meus_avisos(NULL, current_setting('t.esc')::uuid, false, 50, NULL);
  IF n = 2 AND m = 0 AND jsonb_array_length(v) = 2 AND public.contar_avisos_nao_lidos() >= 2 THEN
    RAISE NOTICE 'PASSOU: operador lê a própria caixa (tabela, meus_avisos e contador)';
  ELSE RAISE NOTICE 'FALHOU: operador leu % (% de outros), meus_avisos %', n, m, jsonb_array_length(v); END IF;
  IF jsonb_array_length(public.meus_avisos('checkin_vencido', current_setting('t.esc')::uuid, true, 50, NULL)) = 1
     AND (public.meus_avisos(NULL, current_setting('t.esc')::uuid, false, 1, NULL) -> 0 ->> 'codigo') IS NOT NULL THEN
    RAISE NOTICE 'PASSOU: filtro por tipo e por escolta, com o código da escolta no aviso';
  ELSE RAISE NOTICE 'FALHOU: filtro de meus_avisos'; END IF;
  IF public.marcar_aviso_lido(current_setting('t.outro')::uuid) THEN
    RAISE NOTICE 'FALHOU: operador marcou aviso de outro como lido';
  ELSE RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não marca aviso de outro'; END IF;
  BEGIN
    DELETE FROM public.notificacoes WHERE evento_chave = 'teste_j:caixa';
    RAISE NOTICE 'FALHOU: DELETE direto aceito';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: DELETE direto em notificacoes';
  END;
  BEGIN
    UPDATE public.notificacoes SET lida = true WHERE evento_chave = 'teste_j:caixa';
    RAISE NOTICE 'FALHOU: UPDATE direto aceito';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: UPDATE direto em notificacoes';
  END;
  BEGIN
    INSERT INTO public.notificacoes (escolta_id, canal, tipo_evento_id, destino, usuario_dest_id)
    VALUES (current_setting('t.esc')::uuid, 'app', (SELECT id FROM public.dom_tipos_evento WHERE codigo = 'checkin_vencido'), 'app', public.get_meu_usuario_id());
    RAISE NOTICE 'FALHOU: INSERT direto aceito';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: INSERT direto em notificacoes';
  END;
  BEGIN
    PERFORM lote_interno.notificar('x', current_setting('t.esc')::uuid, 'checkin_vencido', ARRAY[public.get_meu_usuario_id()], 'x', 'x');
    RAISE NOTICE 'FALHOU: operador chamou lote_interno.notificar';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não chama lote_interno.notificar';
  END;
  -- Um comando por vez: a contagem precisa enxergar o UPDATE da chamada anterior.
  n := public.marcar_todos_lidos('checkin_vencido');
  m := public.contar_avisos_nao_lidos();
  IF n = 1 AND m >= 1 THEN
    n := public.marcar_todos_lidos();
    m := public.contar_avisos_nao_lidos();
    IF n >= 1 AND m = 0 THEN RAISE NOTICE 'PASSOU: marcar todos por tipo e depois todos leva o contador a 0';
    ELSE RAISE NOTICE 'FALHOU: marcar todos marcou % e deixou contador %', n, m; END IF;
  ELSE RAISE NOTICE 'FALHOU: marcar todos por tipo marcou % e deixou contador %', n, m; END IF;
END $$;
RESET ROLE;
DO $$
BEGIN
  IF (SELECT lida IS NOT TRUE FROM public.notificacoes WHERE id = current_setting('t.outro')::uuid) THEN
    RAISE NOTICE 'PASSOU: aviso do outro operador continua não lido depois do marcar todos';
  ELSE RAISE NOTICE 'FALHOU: marcar todos alcançou aviso de outro'; END IF;
END $$;
-- Gestão não vê a caixa dos outros (S5).
SELECT qa.como('qa_gestor');
DO $$
DECLARE n int; m int;
BEGIN
  SELECT count(*) INTO n FROM public.notificacoes WHERE usuario_dest_id <> public.get_meu_usuario_id();
  SELECT count(*) INTO m FROM public.notificacoes WHERE evento_chave = 'teste_j:caixa';
  IF n = 0 AND m = 1 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: gestor não lê a caixa dos outros (S5)';
  ELSE RAISE NOTICE 'FALHOU: gestor leu % avisos de outros', n; END IF;
END $$;
RESET ROLE;
-- Anônimo: sem acesso à tabela nem às RPCs.
SET LOCAL ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM count(*) FROM public.notificacoes;
    RAISE NOTICE 'FALHOU: anon leu notificacoes';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: anon não lê notificacoes';
  END;
  BEGIN
    EXECUTE 'TRUNCATE public.notificacoes';
    RAISE NOTICE 'FALHOU: anon truncou notificacoes';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: anon não trunca notificacoes';
  END;
  BEGIN
    PERFORM public.meus_avisos();
    RAISE NOTICE 'FALHOU: anon chamou meus_avisos';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: anon não chama meus_avisos nem contar_avisos_nao_lidos';
  END;
END $$;
RESET ROLE;
ROLLBACK;

-- ── Avisos do mural (onda C) na central; "Ciente" continua gravando ───────────────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 day', 'agendada', 'qa_um')::text, true);
SELECT set_config('t.ped', gen_random_uuid()::text, true);
SELECT public._avisar_app(current_setting('t.esc')::uuid, 'decisao_substituicao', ARRAY[qa.usuario('qa_dois')],
  'Pedido de substituição recusado', 'Recusado no teste.', current_setting('t.ped')::uuid);
SELECT public._avisar_app(current_setting('t.esc')::uuid, 'decisao_substituicao', ARRAY[qa.usuario('qa_dois')],
  'Pedido de substituição recusado', 'Repetido.', current_setting('t.ped')::uuid);
SELECT qa.como('qa_dois');
DO $$
DECLARE v jsonb; m jsonb; v_id uuid; r record;
BEGIN
  v := public.meus_avisos('decisao_substituicao', current_setting('t.esc')::uuid, true, 50, NULL);
  m := public.meus_avisos_mural();
  IF jsonb_array_length(v) = 1 AND v -> 0 ->> 'titulo' = 'Pedido de substituição recusado' AND v -> 0 ->> 'texto' = 'Recusado no teste.'
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(m) x WHERE x ->> 'id' = v -> 0 ->> 'id') THEN
    RAISE NOTICE 'PASSOU: aviso do mural na central (1 linha por pedido) e no mural';
  ELSE RAISE NOTICE 'FALHOU: aviso do mural: central % mural %', jsonb_array_length(v), jsonb_array_length(m); END IF;
  v_id := (v -> 0 ->> 'id')::uuid;
  IF public.marcar_aviso_lido(v_id) THEN
    SELECT lida, lida_em INTO r FROM public.notificacoes WHERE id = v_id;
    IF r.lida AND r.lida_em IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.meus_avisos_mural()) x WHERE x ->> 'id' = v_id::text) THEN
      RAISE NOTICE 'PASSOU: Ciente do mural grava lida e lida_em e tira o aviso do mural e das não lidas';
    ELSE RAISE NOTICE 'FALHOU: Ciente lida=% lida_em=%', r.lida, r.lida_em; END IF;
  ELSE RAISE NOTICE 'FALHOU: Ciente não marcou o próprio aviso'; END IF;
END $$;
RESET ROLE;
-- aviso_ligado = false continua desligando o aviso do mural.
UPDATE public.configuracoes_mural SET aviso_ligado = false WHERE id = 1;
SELECT public._avisar_app(current_setting('t.esc')::uuid, 'pedido_substituicao', ARRAY[qa.usuario('qa_supervisor')], 't', 't', gen_random_uuid());
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.notificacoes WHERE escolta_id = current_setting('t.esc')::uuid AND usuario_dest_id = qa.usuario('qa_supervisor')) THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: aviso do mural desligado por configuracoes_mural.aviso_ligado';
  ELSE RAISE NOTICE 'FALHOU: aviso gravado com aviso_ligado = false'; END IF;
END $$;
ROLLBACK;

-- ── Limpeza de 90 dias e carga de 50 escoltas ──────────────────────────────────────
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE public.escoltas SET periodicidade_checkin_min = NULL WHERE status NOT IN ('finalizada', 'cancelada');
SET LOCAL session_replication_role = origin;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 day')::text, true);
SELECT lote_interno.notificar('teste_j:velha', current_setting('t.esc')::uuid, 'checkin_vencido', ARRAY[qa.usuario('qa_um'), qa.usuario('qa_dois')], 'v', 'v');
UPDATE public.notificacoes SET lida_em = now() - interval '91 days' WHERE evento_chave = 'teste_j:velha' AND usuario_dest_id = qa.usuario('qa_um');
SELECT qa.nova_escolta(now() - interval '2 hours', 'em_andamento', NULL, 1, 5) FROM generate_series(1, 50);
INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por, observacoes)
SELECT ev.id, 'e1601f15-5ef9-44e8-abd0-17f65b3aa760', now() - interval '20 min', -22.8, -43.3, qa.usuario('qa_um'), '{"tipo":"reporte_periodico"}'
FROM public.escolta_veiculos ev JOIN public.escoltas e ON e.id = ev.escolta_id
WHERE e.status = 'em_andamento' AND e.periodicidade_checkin_min = 5;
DO $$
DECLARE j json; t1 numeric; t2 numeric; n int;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) SELECT lote_interno.gerar_avisos_checkin()' INTO j;
  t1 := (j -> 0 ->> 'Execution Time')::numeric;
  EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) SELECT lote_interno.gerar_avisos_checkin()' INTO j;
  t2 := (j -> 0 ->> 'Execution Time')::numeric;
  SELECT count(DISTINCT escolta_id) INTO n FROM public.notificacoes
   WHERE tipo_evento_id = (SELECT id FROM public.dom_tipos_evento WHERE codigo = 'checkin_vencido') AND evento_chave LIKE 'checkin:%';
  IF n = 50 AND t1 < 200 AND t2 < 200 THEN
    RAISE NOTICE 'PASSOU: ciclo com 50 escoltas ativas em % ms (primeiro, gravando) e % ms (seguinte)', round(t1), round(t2);
  ELSE RAISE NOTICE 'FALHOU: ciclo com % escoltas avisadas em % ms e % ms', n, round(t1), round(t2); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.notificacoes WHERE evento_chave = 'teste_j:velha' AND usuario_dest_id = qa.usuario('qa_um'))
     AND EXISTS (SELECT 1 FROM public.notificacoes WHERE evento_chave = 'teste_j:velha' AND usuario_dest_id = qa.usuario('qa_dois')) THEN
    RAISE NOTICE 'PASSOU: limpeza apaga só os lidos há mais de 90 dias';
  ELSE RAISE NOTICE 'FALHOU: limpeza de 90 dias'; END IF;
END $$;
ROLLBACK;
