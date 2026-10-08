-- Lote 2026-10, onda A (segurança): testes de comportamento por perfil.
-- RODA NA HOMOLOGAÇÃO (Supabase local da VPS), que tem os usuários QA e as funções
-- auxiliares do schema qa (qa.como, qa.nova_escolta, qa.vigilante). Cada caso abre uma
-- transação, cria o que precisa, entra como o usuário QA e termina em ROLLBACK.
-- Resultado esperado: só linhas "PASSOU" e "BLOQUEADO CORRETAMENTE". Qualquer "FALHOU" é regressão.
\set QUIET on
\pset tuples_only on

-- Operador do efetivo não altera financeiro, fluxo, periodicidade nem cancela.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '3 hours', 'agendada', 'qa_um')::text, true);
SELECT qa.como('qa_um');
DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['valor_cobrado = 999', 'fluxo_versao = 1', 'periodicidade_checkin_min = 30',
                           'outros_custos = 5', 'checklist_pendente_no_inicio = true', 'status = ''cancelada''']
  LOOP
    BEGIN
      EXECUTE format('UPDATE public.escoltas SET %s WHERE id = %L', c, current_setting('t.esc'));
      RAISE NOTICE 'FALHOU: operador conseguiu %', c;
    EXCEPTION WHEN raise_exception THEN
      RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador %', c;
    END;
  END LOOP;
END $$;
ROLLBACK;

-- Fluxo legítimo do operador: avança etapa, e o início com checklist pendente funciona
-- (tr_verificar_checklist_pendente grava a marca depois da trava do operador).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '3 hours', 'em_pre_inicio', 'qa_um')::text, true);
SELECT qa.como('qa_um');
DO $$
DECLARE v boolean;
BEGIN
  UPDATE public.escoltas SET status = 'em_andamento' WHERE id = current_setting('t.esc')::uuid;
  SELECT checklist_pendente_no_inicio INTO v FROM public.escoltas WHERE id = current_setting('t.esc')::uuid;
  RAISE NOTICE 'PASSOU: operador inicia a escolta (checklist pendente = %)', v;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'FALHOU: operador nao conseguiu iniciar: %', SQLERRM;
END $$;
ROLLBACK;
-- Finalização como o app faz: status, relatório e término no mesmo UPDATE, a partir de Na Base.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '4 hours', 'na_base', 'qa_um')::text, true);
SELECT qa.como('qa_um');
DO $$
BEGIN
  UPDATE public.escoltas SET status = 'finalizada', observacao_fechamento = 'teste', data_finalizacao = now()
  WHERE id = current_setting('t.esc')::uuid;
  RAISE NOTICE 'PASSOU: operador finaliza com o relatorio final';
EXCEPTION WHEN others THEN
  RAISE NOTICE 'FALHOU: finalizacao recusada: %', SQLERRM;
END $$;
ROLLBACK;

-- Operador não apaga evidência (DELETE negado por RLS devolve 0 linhas).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '3 hours', 'em_andamento', 'qa_um', 2)::text, true);
INSERT INTO public.emergencias (escolta_id, data_hora, acionado_por, latitude, longitude)
SELECT current_setting('t.esc')::uuid, now(), u.id, -22.9, -43.3 FROM public.usuarios u WHERE u.metadados->>'login' = 'qa_um';
SELECT qa.como('qa_um');
DO $$
DECLARE n int; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['escolta_veiculos', 'emergencias'] LOOP
    EXECUTE format('WITH d AS (DELETE FROM public.%I WHERE escolta_id = %L RETURNING 1) SELECT count(*) FROM d', t, current_setting('t.esc')) INTO n;
    IF n = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador apagando %', t;
    ELSE RAISE NOTICE 'FALHOU: operador apagou % linhas de %', n, t; END IF;
  END LOOP;
END $$;
ROLLBACK;

-- Supervisor (G4) continua apagando viatura (edição de escolta).
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '3 hours', 'agendada', NULL, 2)::text, true);
SELECT qa.como('qa_supervisor');
DO $$
DECLARE n int;
BEGIN
  WITH d AS (DELETE FROM public.escolta_veiculos WHERE escolta_id = current_setting('t.esc')::uuid RETURNING 1) SELECT count(*) INTO n FROM d;
  IF n = 2 THEN RAISE NOTICE 'PASSOU: supervisor apaga viaturas na edicao'; ELSE RAISE NOTICE 'FALHOU: supervisor apagou %', n; END IF;
END $$;
ROLLBACK;

-- Auditoria e notificação não são forjáveis pela API.
BEGIN;
INSERT INTO public.notificacoes (escolta_id, canal, tipo_evento_id, destino, usuario_dest_id)
SELECT qa.nova_escolta(now() + interval '3 hours'), 'app', (SELECT id FROM public.dom_tipos_evento LIMIT 1), 'app', u.id
FROM public.usuarios u WHERE u.metadados->>'login' = 'qa_um';
SELECT qa.como('qa_um');
DO $$
BEGIN
  BEGIN
    INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada) VALUES (NULL, 'forjado', 'x');
    RAISE NOTICE 'FALHOU: operador gravou auditoria';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: auditoria forjada';
  END;
  BEGIN
    INSERT INTO public.notificacoes (escolta_id, canal, tipo_evento_id, destino)
    SELECT escolta_id, 'app', tipo_evento_id, 'x' FROM public.notificacoes LIMIT 1;
    RAISE NOTICE 'FALHOU: operador criou notificacao';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: notificacao forjada';
  END;
  BEGIN
    UPDATE public.notificacoes SET usuario_dest_id = (SELECT id FROM public.usuarios WHERE metadados->>'login' = 'qa_dois');
    RAISE NOTICE 'FALHOU: operador repassou a notificacao a outro usuario';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: notificacao repassada';
  END;
  -- Com a 211 (onda J) não há mais UPDATE direto: o destinatário marca pela RPC.
  IF has_table_privilege('authenticated', 'public.notificacoes', 'UPDATE') THEN
    UPDATE public.notificacoes SET lida = true;
  ELSE
    PERFORM public.marcar_aviso_lido(id) FROM public.notificacoes;
  END IF;
  IF EXISTS (SELECT 1 FROM public.notificacoes WHERE lida) THEN RAISE NOTICE 'PASSOU: destinatario marca a propria notificacao como lida';
  ELSE RAISE NOTICE 'FALHOU: destinatario nao marcou como lida'; END IF;
END $$;
ROLLBACK;

-- Usuário bloqueado perde o acesso às escoltas dele.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_tres')::text, true);
UPDATE public.usuarios SET status = 'bloqueado' WHERE metadados->>'login' = 'qa_tres';
SELECT qa.como('qa_tres');
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.escoltas WHERE id = current_setting('t.esc')::uuid;
  IF n = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador bloqueado nao le a escolta';
  ELSE RAISE NOTICE 'FALHOU: operador bloqueado ainda le a escolta'; END IF;
END $$;
ROLLBACK;

-- Gestor não mexe em administrador nem redefine senha de outro gestor.
BEGIN;
SELECT qa.como('qa_gestor');
DO $$
BEGIN
  BEGIN
    UPDATE public.usuarios SET status = 'bloqueado' WHERE metadados->>'login' = 'qa_administrador';
    RAISE NOTICE 'FALHOU: gestor bloqueou administrador';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: gestor alterando administrador';
  END;
  BEGIN
    PERFORM public.redefinir_senha_usuario((SELECT auth_user_id FROM public.usuarios WHERE nome_completo = 'Bruno Ficticio QA'), 'outrasenha1');
    RAISE NOTICE 'FALHOU: gestor redefiniu senha de outro gestor';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: gestor redefinindo senha de gestor';
  END;
  BEGIN
    PERFORM public.redefinir_senha_usuario((SELECT auth_user_id FROM public.usuarios WHERE metadados->>'login' = 'qa_dois'), 'outrasenha1');
    RAISE NOTICE 'PASSOU: gestor redefine senha de operador';
  EXCEPTION WHEN others THEN RAISE NOTICE 'FALHOU: gestor nao redefiniu senha de operador: %', SQLERRM;
  END;
END $$;
ROLLBACK;

-- Fotos 2 a 5 e storage: quem é do efetivo lê pelo caminho; quem não é, não.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um')::text, true);
INSERT INTO public.fotos (caminho_arquivo, tipo_foto_id, data_hora_captura)
SELECT 'origem/' || current_setting('t.esc') || '/qa-foto-2.jpg', (SELECT id FROM public.dom_tipos_foto LIMIT 1), now();
INSERT INTO storage.objects (bucket_id, name) VALUES ('fotos', 'origem/' || current_setting('t.esc') || '/qa-foto-2.jpg');
SELECT qa.como('qa_um');
DO $$
DECLARE n int; m int;
BEGIN
  SELECT count(*) INTO n FROM public.fotos WHERE caminho_arquivo LIKE '%' || current_setting('t.esc') || '%';
  SELECT count(*) INTO m FROM storage.objects WHERE name LIKE '%' || current_setting('t.esc') || '%';
  IF n = 1 AND m = 1 THEN RAISE NOTICE 'PASSOU: membro do efetivo le a foto 2 (tabela e bucket)';
  ELSE RAISE NOTICE 'FALHOU: membro do efetivo leu fotos=% objetos=%', n, m; END IF;
END $$;
ROLLBACK;
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um')::text, true);
INSERT INTO public.fotos (caminho_arquivo, tipo_foto_id, data_hora_captura)
SELECT 'origem/' || current_setting('t.esc') || '/qa-foto-2.jpg', (SELECT id FROM public.dom_tipos_foto LIMIT 1), now();
INSERT INTO storage.objects (bucket_id, name) VALUES ('fotos', 'origem/' || current_setting('t.esc') || '/qa-foto-2.jpg');
SELECT qa.como('qa_dois');
DO $$
DECLARE n int; m int;
BEGIN
  SELECT count(*) INTO n FROM public.fotos WHERE caminho_arquivo LIKE '%' || current_setting('t.esc') || '%';
  SELECT count(*) INTO m FROM storage.objects WHERE name LIKE '%' || current_setting('t.esc') || '%';
  IF n = 0 AND m = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador de fora nao le a foto';
  ELSE RAISE NOTICE 'FALHOU: operador de fora leu fotos=% objetos=%', n, m; END IF;
END $$;
ROLLBACK;

-- Revisão adversarial da onda A: escolta encerrada, relatório final e caminho forjado.
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '5 hours', 'finalizada', 'qa_um')::text, true);
SELECT set_config('t.rua', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um')::text, true);
SELECT qa.como('qa_um');
DO $$
BEGIN
  BEGIN
    UPDATE public.escoltas SET observacao_fechamento = 'reescrito depois' WHERE id = current_setting('t.esc')::uuid;
    RAISE NOTICE 'FALHOU: operador reescreveu o relatorio de escolta finalizada';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: escolta finalizada nao muda pelo operador';
  END;
  BEGIN
    UPDATE public.escoltas SET observacao_fechamento = 'antes da hora' WHERE id = current_setting('t.rua')::uuid;
    RAISE NOTICE 'FALHOU: operador gravou relatorio final fora da finalizacao';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: relatorio final fora da finalizacao';
  END;
  BEGIN
    UPDATE public.escoltas SET metadados = '{"x":1}' WHERE id = current_setting('t.rua')::uuid;
    RAISE NOTICE 'FALHOU: operador alterou metadados';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador alterando metadados';
  END;
END $$;
ROLLBACK;

BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um')::text, true);
INSERT INTO storage.objects (bucket_id, name) VALUES ('fotos', 'origem/' || current_setting('t.esc') || '/alheia.jpg');
SELECT qa.como('qa_dois');
DO $$
DECLARE m int;
BEGIN
  -- qa_dois não é do efetivo; grava uma linha em fotos apontando para o arquivo alheio.
  INSERT INTO public.fotos (caminho_arquivo, tipo_foto_id, data_hora_captura, criado_por)
  VALUES ('origem/' || current_setting('t.esc') || '/alheia.jpg', (SELECT id FROM public.dom_tipos_foto LIMIT 1), now(), public.get_meu_usuario_id());
  SELECT count(*) INTO m FROM storage.objects WHERE name LIKE '%' || current_setting('t.esc') || '/alheia.jpg';
  IF m = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: caminho forjado em fotos nao abre arquivo de outra escolta';
  ELSE RAISE NOTICE 'FALHOU: caminho forjado abriu arquivo de outra escolta'; END IF;
END $$;
ROLLBACK;
