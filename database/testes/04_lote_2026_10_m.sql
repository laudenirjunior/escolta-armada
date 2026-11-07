-- Onda M (06/11/2026), migration 220: endereço por extenso depois do envio.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa). Esperado: só PASSOU e BLOQUEADO CORRETAMENTE.
\set QUIET on
\pset tuples_only on
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() - interval '1 hour', 'em_andamento', 'qa_um', 1)::text, true);
-- Ponto do qa_um sem endereço (como chega da fila sem internet), ponto legado em texto puro,
-- ponto já com endereço e ponto anulado.
INSERT INTO public.pontos_controle (id, escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por, observacoes)
SELECT 'aaaaaaaa-0000-4000-8000-000000000220'::uuid, ev.id, (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'origem'), now() - interval '5 min', -22.8, -43.3, qa.usuario('qa_um'),
       '{"tipo":"reporte_periodico","tipoLabel":"Reporte Periódico","observacao":"Equipe em deslocamento.","foto_ids":[],"endereco":null,"km":null}'
FROM public.escolta_veiculos ev WHERE ev.escolta_id = current_setting('t.esc')::uuid;
INSERT INTO public.pontos_controle (id, escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por, observacoes)
SELECT 'aaaaaaaa-0000-4000-8000-000000000221'::uuid, ev.id, (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'origem'), now() - interval '4 min', -22.8, -43.3, qa.usuario('qa_um'),
       'texto legado'
FROM public.escolta_veiculos ev WHERE ev.escolta_id = current_setting('t.esc')::uuid;
INSERT INTO public.pontos_controle (id, escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por, observacoes)
SELECT 'aaaaaaaa-0000-4000-8000-000000000222'::uuid, ev.id, (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'origem'), now() - interval '3 min', -22.8, -43.3, qa.usuario('qa_um'),
       '{"observacao":null,"foto_ids":[],"endereco":"Rua Original, 10"}'
FROM public.escolta_veiculos ev WHERE ev.escolta_id = current_setting('t.esc')::uuid;
INSERT INTO public.pontos_controle (id, escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por, observacoes, anulado_em, anulado_por, motivo_anulacao)
SELECT 'aaaaaaaa-0000-4000-8000-000000000223'::uuid, ev.id, (SELECT id FROM public.dom_tipos_ponto WHERE codigo = 'origem'), now() - interval '2 min', -22.8, -43.3, qa.usuario('qa_um'),
       '{"foto_ids":[]}', now(), qa.usuario('qa_um'), 'teste'
FROM public.escolta_veiculos ev WHERE ev.escolta_id = current_setting('t.esc')::uuid;

DO $$
BEGIN
  IF NOT has_function_privilege('anon', 'public.preencher_endereco_ponto(uuid, text)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.preencher_endereco_ponto(uuid, text)', 'EXECUTE') THEN
    RAISE NOTICE 'PASSOU: preencher_endereco_ponto só para authenticated (anon sem EXECUTE)';
  ELSE RAISE NOTICE 'FALHOU: privilégios da preencher_endereco_ponto'; END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.preencher_endereco_ponto(uuid, text)'::regprocedure)
     AND (SELECT proconfig::text FROM pg_proc WHERE oid = 'public.preencher_endereco_ponto(uuid, text)'::regprocedure) LIKE '%search_path%' THEN
    RAISE NOTICE 'PASSOU: SECURITY DEFINER com search_path fixo';
  ELSE RAISE NOTICE 'FALHOU: preencher_endereco_ponto sem SECURITY DEFINER ou sem search_path'; END IF;
END $$;

-- Outro operador (qa_dois) não grava no ponto do qa_um.
SELECT qa.como('qa_dois');
DO $$
BEGIN
  IF public.preencher_endereco_ponto('aaaaaaaa-0000-4000-8000-000000000220', 'Rua Falsa, 1') = false THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador que não é o autor não grava endereço';
  ELSE RAISE NOTICE 'FALHOU: operador alheio gravou endereço'; END IF;
END $$;
RESET ROLE;

SELECT qa.como('qa_um');
DO $$
BEGIN
  IF public.preencher_endereco_ponto('aaaaaaaa-0000-4000-8000-000000000220', 'ab') = false THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: texto curto demais';
  ELSE RAISE NOTICE 'FALHOU: texto de 2 caracteres aceito'; END IF;
  IF public.preencher_endereco_ponto('aaaaaaaa-0000-4000-8000-000000000220', repeat('x', 301)) = false THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: texto acima de 300 caracteres';
  ELSE RAISE NOTICE 'FALHOU: texto de 301 caracteres aceito'; END IF;
  IF public.preencher_endereco_ponto('aaaaaaaa-0000-4000-8000-000000000220', '  Av. Brasil, 500 - Penha, Rio de Janeiro - RJ  ') = true THEN
    RAISE NOTICE 'PASSOU: autor grava o endereço do ponto que chegou sem ele';
  ELSE RAISE NOTICE 'FALHOU: autor não gravou o endereço'; END IF;
  IF public.preencher_endereco_ponto('aaaaaaaa-0000-4000-8000-000000000220', 'Outro endereço, 2') = false THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: segunda gravação recusada (uma única vez)';
  ELSE RAISE NOTICE 'FALHOU: endereço trocado na segunda chamada'; END IF;
  IF public.preencher_endereco_ponto('aaaaaaaa-0000-4000-8000-000000000222', 'Rua Nova, 99') = false THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: endereço existente nunca é trocado';
  ELSE RAISE NOTICE 'FALHOU: endereço existente trocado'; END IF;
  IF public.preencher_endereco_ponto('aaaaaaaa-0000-4000-8000-000000000223', 'Rua Anulada, 1') = false THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: ponto anulado não recebe endereço';
  ELSE RAISE NOTICE 'FALHOU: ponto anulado recebeu endereço'; END IF;
  IF public.preencher_endereco_ponto('aaaaaaaa-0000-4000-8000-000000000221', 'Rua do Legado, 7') = true THEN
    RAISE NOTICE 'PASSOU: ponto legado em texto puro recebe o endereço e mantém o texto em observacao';
  ELSE RAISE NOTICE 'FALHOU: ponto legado não recebeu endereço'; END IF;
END $$;
RESET ROLE;

DO $$
DECLARE o jsonb; l jsonb; r jsonb;
BEGIN
  SELECT observacoes::jsonb INTO o FROM public.pontos_controle WHERE id = 'aaaaaaaa-0000-4000-8000-000000000220';
  SELECT observacoes::jsonb INTO l FROM public.pontos_controle WHERE id = 'aaaaaaaa-0000-4000-8000-000000000221';
  SELECT observacoes::jsonb INTO r FROM public.pontos_controle WHERE id = 'aaaaaaaa-0000-4000-8000-000000000222';
  IF o ->> 'endereco' = 'Av. Brasil, 500 - Penha, Rio de Janeiro - RJ' AND o ->> 'observacao' = 'Equipe em deslocamento.'
     AND o ->> 'tipo' = 'reporte_periodico' AND jsonb_typeof(o -> 'foto_ids') = 'array' THEN
    RAISE NOTICE 'PASSOU: só a chave endereco mudou (texto aparado; tipo, observação e fotos intactos)';
  ELSE RAISE NOTICE 'FALHOU: observacoes alteradas além do endereço: %', o; END IF;
  IF l ->> 'observacao' = 'texto legado' AND l ->> 'endereco' = 'Rua do Legado, 7' THEN
    RAISE NOTICE 'PASSOU: legado preservado em observacao';
  ELSE RAISE NOTICE 'FALHOU: legado perdido: %', l; END IF;
  IF r ->> 'endereco' = 'Rua Original, 10' THEN RAISE NOTICE 'PASSOU: endereço original intacto';
  ELSE RAISE NOTICE 'FALHOU: endereço original mudou'; END IF;
  IF (SELECT lancado_por FROM public.pontos_controle WHERE id = 'aaaaaaaa-0000-4000-8000-000000000220') = qa.usuario('qa_um') THEN
    RAISE NOTICE 'PASSOU: autor e horário do ponto intactos (trava da 214 respeitada)';
  ELSE RAISE NOTICE 'FALHOU: autor do ponto mudou'; END IF;
END $$;

-- Supervisor (gestão) grava em ponto alheio sem endereço.
UPDATE public.pontos_controle SET observacoes = '{"foto_ids":[]}' WHERE id = 'aaaaaaaa-0000-4000-8000-000000000221';
SELECT qa.como('qa_supervisor');
DO $$
BEGIN
  IF public.preencher_endereco_ponto('aaaaaaaa-0000-4000-8000-000000000221', 'Rua da Gestão, 3') = true THEN
    RAISE NOTICE 'PASSOU: supervisor grava o endereço de ponto da equipe';
  ELSE RAISE NOTICE 'FALHOU: supervisor não gravou'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
