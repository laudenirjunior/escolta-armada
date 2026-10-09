-- Lote 2026-10, onda K (cor por cliente, cartão, filtros e interestadual): migration 216.
-- RODA NA HOMOLOGAÇÃO (usuários QA e schema qa), com os blocos 1 e 2 aplicados.
-- Esperado: só PASSOU e BLOQUEADO CORRETAMENTE. Cada bloco roda numa transação desfeita.
\set QUIET on
\pset tuples_only on

-- ── Auxiliares da sessão (pg_temp, somem no fim) ───────────────────────────────────
-- Volta a ser postgres SEM usuário final (RESET ROLE não limpa as claims do JWT).
CREATE FUNCTION pg_temp.pg() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $$;
CREATE FUNCTION pg_temp.ev(p_esc uuid, p_n int) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_esc ORDER BY criado_em OFFSET p_n - 1 LIMIT 1 $$;
CREATE FUNCTION pg_temp.tp(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.dom_tipos_ponto WHERE codigo = p $$;
CREATE FUNCTION pg_temp.tipo_da_etapa(p text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE p WHEN 'em_andamento' THEN 'base_saida' WHEN 'na_origem' THEN 'origem' WHEN 'em_transito_destino' THEN 'transito_destino'
    WHEN 'no_destino' THEN 'destino' WHEN 'em_transito_retorno' THEN 'transito_retorno' WHEN 'retornando' THEN 'retorno'
    WHEN 'na_base' THEN 'base_retorno' END $$;
-- Avança pela tela (registrar_etapa_escolta) até a etapa pedida, como o usuário da sessão
-- (mesmo roteiro do 04_lote_2026_10_i: checklists do pré-início, KM e um ponto por viatura).
CREATE FUNCTION pg_temp.jornada(p_esc uuid, p_ate text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  seq text[] := ARRAY['agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino', 'no_destino',
                      'em_transito_retorno', 'retornando', 'na_base', 'finalizada'];
  v_status text; v_prox text; v_tipo text; v_pontos jsonb; r record; v_resp uuid;
BEGIN
  v_resp := coalesce(public.get_meu_usuario_id(), qa.usuario('qa_administrador'));
  LOOP
    SELECT status INTO v_status FROM public.escoltas WHERE id = p_esc;
    EXIT WHEN v_status = p_ate OR v_status IS NULL;
    v_prox := seq[array_position(seq, v_status) + 1];
    IF v_prox = 'em_andamento' THEN
      FOR r IN SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_esc LOOP
        INSERT INTO public.checklists (escolta_veiculo_id, tipo, concluido, responsavel_id, data_inicio)
        VALUES (r.id, 'viatura', true, v_resp, clock_timestamp()), (r.id, 'material', true, v_resp, clock_timestamp());
        UPDATE public.escolta_veiculos SET quilometragem_saida = 1000 WHERE id = r.id;
      END LOOP;
    ELSIF v_prox = 'na_base' THEN
      UPDATE public.escolta_veiculos SET quilometragem_retorno = 1100 WHERE escolta_id = p_esc;
    END IF;
    v_tipo := pg_temp.tipo_da_etapa(v_prox);
    v_pontos := CASE WHEN v_tipo IS NULL THEN '[]'::jsonb ELSE
      (SELECT jsonb_agg(jsonb_build_object('escolta_veiculo_id', ev.id, 'tipo_ponto_id', pg_temp.tp(v_tipo),
                                           'data_hora', clock_timestamp(), 'sem_sinal_gps', true, 'lancado_por', v_resp))
         FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_esc) END;
    PERFORM public.registrar_etapa_escolta(p_esc, v_pontos, v_status, v_prox, 'teste onda K', NULL, NULL, NULL, NULL, pg_temp.tp(v_tipo));
  END LOOP;
END $$;
-- Contraste de texto branco sobre a cor (WCAG 2.1), conta feita no próprio banco.
CREATE FUNCTION pg_temp.contraste_branco(p_hex text) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE c double precision[] := '{}'; i int; v double precision;
BEGIN
  FOR i IN 0 .. 2 LOOP
    v := ('x' || substr(p_hex, 2 + 2 * i, 2))::bit(8)::int / 255.0;
    c := c || CASE WHEN v <= 0.04045 THEN v / 12.92 ELSE ((v + 0.055) / 1.055) ^ 2.4 END;
  END LOOP;
  RETURN round((1.05 / (0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3] + 0.05))::numeric, 2);
END $$;

-- ── 1. Estrutura, privilégios e malha ──────────────────────────────────────────────
BEGIN;
DO $$
DECLARE n int; t text; v_ok boolean;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'escoltas' AND column_name IN ('origem_uf', 'destino_uf', 'uf_estimada', 'interestadual');
  IF n = 4 THEN RAISE NOTICE 'PASSOU: escoltas tem origem_uf, destino_uf, uf_estimada e interestadual';
  ELSE RAISE NOTICE 'FALHOU: % de 4 colunas novas', n; END IF;
  SELECT pg_get_expr(d.adbin, d.adrelid) INTO t FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
   WHERE d.adrelid = 'public.escoltas'::regclass AND a.attname = 'interestadual' AND a.attgenerated = 's';
  IF t = '((origem_uf <> ''RJ''::text) OR (destino_uf <> ''RJ''::text))' THEN
    RAISE NOTICE 'PASSOU: interestadual é coluna gerada (origem ou destino fora do RJ)';
  ELSE RAISE NOTICE 'FALHOU: expressão de interestadual %', coalesce(t, 'ausente'); END IF;
  SELECT count(*) INTO n FROM pg_constraint WHERE conrelid = 'public.escoltas'::regclass
     AND conname IN ('escoltas_origem_uf_formato', 'escoltas_destino_uf_formato');
  IF n = 2 AND to_regclass('public.idx_escoltas_interestadual') IS NOT NULL THEN RAISE NOTICE 'PASSOU: CHECK das duas UFs e índice de interestadual';
  ELSE RAISE NOTICE 'FALHOU: % CHECK e índice %', n, to_regclass('public.idx_escoltas_interestadual'); END IF;
  SELECT count(*) INTO n FROM lote_interno.malha_uf WHERE area_caixa IS NOT NULL;
  IF n = 27 THEN RAISE NOTICE 'PASSOU: malha do IBGE com as 27 UFs (% anéis)', (SELECT count(*) FROM lote_interno.malha_uf_aneis);
  ELSE RAISE NOTICE 'FALHOU: malha com % UFs', n; END IF;
  SELECT count(*) INTO n FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace
     AND p.proname IN ('ponto_no_anel', 'distancia_ao_anel_km', 'uf_mais_proxima', 'uf_do_ponto', 'carregar_uf_escoltas',
                       'cor_lab', 'cor_da_paleta', 'normalizar_cor_cliente')
     AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
     AND 'search_path=public, pg_temp' = ANY (p.proconfig);
  IF n = 8 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: as 8 funções internas da 216 no lote_interno, sem EXECUTE para anon e authenticated, search_path fixo';
  ELSE RAISE NOTICE 'FALHOU: % de 8 funções internas corretas', n; END IF;
  SELECT p.prosecdef AND p.provolatile = 's' AND 'search_path=public, pg_temp' = ANY (p.proconfig)
         AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    INTO v_ok FROM pg_proc p WHERE p.oid = 'public.uf_da_coordenada(double precision, double precision)'::regprocedure;
  IF v_ok THEN RAISE NOTICE 'PASSOU: uf_da_coordenada STABLE, SECURITY DEFINER, search_path fixo, só authenticated executa';
  ELSE RAISE NOTICE 'FALHOU: atributos de uf_da_coordenada'; END IF;
  IF NOT has_table_privilege('authenticated', 'lote_interno.malha_uf', 'SELECT') AND NOT has_table_privilege('anon', 'lote_interno.malha_uf', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.paleta_clientes', 'SELECT') AND NOT has_table_privilege('anon', 'public.paleta_clientes', 'SELECT')
     AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.paleta_clientes'::regclass)
     AND NOT has_table_privilege('authenticated', 'backup_20261008.uf_a_conferir', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'backup_20261008.cores_clientes', 'SELECT') THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: malha, paleta (RLS ligada) e backups fora do alcance de anon e authenticated';
  ELSE RAISE NOTICE 'FALHOU: privilégios de malha, paleta ou backups'; END IF;
  SELECT pg_get_functiondef('public.impedir_edicao_por_operador()'::regprocedure) INTO t;
  IF t LIKE '%''origem_uf'',''destino_uf'',''uf_estimada''%' THEN RAISE NOTICE 'PASSOU: impedir_edicao_por_operador recriada com as colunas da UF';
  ELSE RAISE NOTICE 'FALHOU: impedir_edicao_por_operador sem as colunas da UF'; END IF;
  SELECT pg_get_triggerdef(oid) INTO t FROM pg_trigger WHERE tgname = 'tr_normalizar_cor_cliente' AND tgrelid = 'public.clientes'::regclass;
  IF t LIKE '%BEFORE INSERT OR UPDATE OF cor_destaque ON public.clientes FOR EACH ROW%' THEN RAISE NOTICE 'PASSOU: trigger de cor em INSERT e UPDATE de cor_destaque';
  ELSE RAISE NOTICE 'FALHOU: trigger de cor %', coalesce(t, 'ausente'); END IF;
  SELECT column_default INTO t FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'clientes' AND column_name = 'cor_destaque';
  IF t = '''#1D4ED8''::text' AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.clientes'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%cor_destaque%') THEN
    RAISE NOTICE 'PASSOU: DEFAULT da cor é a padrão da paleta (#1D4ED8) e não há CHECK de cor';
  ELSE RAISE NOTICE 'FALHOU: DEFAULT % ou CHECK de cor', t; END IF;
END $$;
ROLLBACK;

-- ── 2. UF pela coordenada: 35 pontos conhecidos (27 capitais e 8 cidades da divisa do RJ) ──
BEGIN;
DO $$
DECLARE r record; v record; v_ok int := 0; v_tot int := 0;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('Rio Branco', 'AC', -9.9747, -67.8243), ('Maceió', 'AL', -9.6658, -35.7353), ('Manaus', 'AM', -3.1190, -60.0217),
      ('Macapá', 'AP', 0.0349, -51.0694), ('Salvador', 'BA', -12.9714, -38.5014), ('Fortaleza', 'CE', -3.7319, -38.5267),
      ('Brasília', 'DF', -15.7939, -47.8828), ('Vitória', 'ES', -20.3155, -40.3128), ('Goiânia', 'GO', -16.6869, -49.2648),
      ('São Luís', 'MA', -2.5307, -44.3068), ('Cuiabá', 'MT', -15.6014, -56.0979), ('Campo Grande', 'MS', -20.4697, -54.6201),
      ('Belo Horizonte', 'MG', -19.9167, -43.9345), ('Belém', 'PA', -1.4558, -48.4902), ('João Pessoa', 'PB', -7.1195, -34.8450),
      ('Curitiba', 'PR', -25.4284, -49.2733), ('Recife', 'PE', -8.0476, -34.8770), ('Teresina', 'PI', -5.0892, -42.8019),
      ('Rio de Janeiro', 'RJ', -22.9068, -43.1729), ('Natal', 'RN', -5.7945, -35.2110), ('Porto Alegre', 'RS', -30.0346, -51.2177),
      ('Porto Velho', 'RO', -8.7612, -63.9004), ('Boa Vista', 'RR', 2.8235, -60.6758), ('Florianópolis', 'SC', -27.5954, -48.5480),
      ('São Paulo', 'SP', -23.5505, -46.6333), ('Aracaju', 'SE', -10.9472, -37.0731), ('Palmas', 'TO', -10.1840, -48.3336),
      ('Juiz de Fora', 'MG', -21.7642, -43.3496), ('Cachoeiro de Itapemirim', 'ES', -20.8489, -41.1129),
      ('Paraty', 'RJ', -23.2178, -44.7131), ('Resende', 'RJ', -22.4705, -44.4509), ('Itaperuna', 'RJ', -21.2050, -41.8878),
      ('Angra dos Reis', 'RJ', -23.0067, -44.3181), ('Petrópolis', 'RJ', -22.5112, -43.1779),
      ('Campos dos Goytacazes', 'RJ', -21.7545, -41.3244)) p(nome, esperado, lat, lng)
  LOOP
    v_tot := v_tot + 1;
    SELECT * INTO v FROM lote_interno.uf_do_ponto(r.lat, r.lng);
    IF v.uf = r.esperado THEN v_ok := v_ok + 1;
    ELSE RAISE NOTICE 'FALHOU: % deu % (esperado %), % km da divisa', r.nome, coalesce(v.uf, 'nula'), r.esperado, v.distancia_divisa_km; END IF;
  END LOOP;
  IF v_ok = v_tot THEN RAISE NOTICE 'PASSOU: % de % pontos conhecidos com a UF certa (capitais, Juiz de Fora, Cachoeiro, Paraty, Resende, Itaperuna, Angra, Petrópolis e Campos)', v_ok, v_tot;
  ELSE RAISE NOTICE 'FALHOU: % de % pontos com a UF certa', v_ok, v_tot; END IF;

  -- Juiz de Fora e Cachoeiro estão dentro da caixa do RJ: a caixa sozinha erraria.
  SELECT * INTO v FROM lote_interno.uf_do_ponto(-21.7642, -43.3496);
  IF v.uf = 'MG' AND -21.7642 BETWEEN (SELECT min_lat FROM lote_interno.malha_uf WHERE uf = 'RJ') AND (SELECT max_lat FROM lote_interno.malha_uf WHERE uf = 'RJ')
     AND -43.3496 BETWEEN (SELECT min_lng FROM lote_interno.malha_uf WHERE uf = 'RJ') AND (SELECT max_lng FROM lote_interno.malha_uf WHERE uf = 'RJ') THEN
    RAISE NOTICE 'PASSOU: Juiz de Fora está dentro da caixa do RJ e mesmo assim sai MG (teste de raio no polígono)';
  ELSE RAISE NOTICE 'FALHOU: Juiz de Fora %', v.uf; END IF;
  -- Galeão (Ilha do Governador) fica fora da malha mínima: UF do polígono mais próximo, marcada fora_da_malha.
  SELECT * INTO v FROM lote_interno.uf_do_ponto(-22.8135, -43.2486);
  IF v.uf = 'RJ' AND v.fora_da_malha THEN RAISE NOTICE 'PASSOU: ponto fora de todos os polígonos (Galeão) recebe a UF mais próxima (RJ) com fora_da_malha';
  ELSE RAISE NOTICE 'FALHOU: Galeão % fora %', v.uf, v.fora_da_malha; END IF;
  -- Além Paraíba (MG) fica a menos de 1 km da divisa com o RJ.
  SELECT * INTO v FROM lote_interno.uf_do_ponto(-21.8856, -42.7044);
  IF v.uf = 'MG' AND v.distancia_divisa_km < 5 THEN RAISE NOTICE 'PASSOU: Além Paraíba MG a % km da divisa (menos de 5 km)', v.distancia_divisa_km;
  ELSE RAISE NOTICE 'FALHOU: Além Paraíba % a % km', v.uf, v.distancia_divisa_km; END IF;
  SELECT * INTO v FROM lote_interno.uf_do_ponto(-22.9068, -43.1729);
  IF v.distancia_divisa_km > 50 THEN RAISE NOTICE 'PASSOU: centro do Rio a % km da divisa (o litoral não conta como divisa)', v.distancia_divisa_km;
  ELSE RAISE NOTICE 'FALHOU: centro do Rio a % km', v.distancia_divisa_km; END IF;
  SELECT * INTO v FROM lote_interno.uf_do_ponto(0, 0);
  IF v.uf IS NULL THEN RAISE NOTICE 'PASSOU: coordenada 0,0 fica sem UF';
  ELSE RAISE NOTICE 'FALHOU: 0,0 deu %', v.uf; END IF;
END $$;
ROLLBACK;

-- ── 3. RPC uf_da_coordenada pelos perfis ───────────────────────────────────────────
BEGIN;
DO $$
DECLARE u text; v record; n int; v_ok int := 0;
BEGIN
  FOREACH u IN ARRAY ARRAY['qa_administrador', 'qa_gestor', 'qa_supervisor', 'qa_central', 'qa_um'] LOOP
    PERFORM qa.como(u);
    SELECT * INTO v FROM public.uf_da_coordenada(-23.5505, -46.6333);
    IF v.uf = 'SP' AND v.fora_da_malha = false THEN v_ok := v_ok + 1; ELSE RAISE NOTICE 'FALHOU: % recebeu % para São Paulo', u, v.uf; END IF;
    SELECT count(*) INTO n FROM public.uf_da_coordenada(NULL, NULL);
    IF n <> 0 THEN RAISE NOTICE 'FALHOU: % recebeu linha para coordenada nula', u; END IF;
    SELECT count(*) INTO n FROM public.uf_da_coordenada(0, 0);
    IF n <> 0 THEN RAISE NOTICE 'FALHOU: % recebeu linha para 0,0', u; END IF;
    PERFORM pg_temp.pg();
  END LOOP;
  IF v_ok = 5 THEN RAISE NOTICE 'PASSOU: uf_da_coordenada responde a administrador, gestor, supervisor, central e operador (SP para São Paulo; nada para nula e 0,0)';
  ELSE RAISE NOTICE 'FALHOU: % de 5 perfis', v_ok; END IF;
  BEGIN
    PERFORM * FROM public.uf_da_coordenada(-22.9, -43.2);
    RAISE NOTICE 'FALHOU: sem usuário final a RPC respondeu';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: uf_da_coordenada sem perfil (sem usuário final) recusada';
  END;
END $$;
ROLLBACK;

-- ── 4. Interestadual pela coluna gerada e formato da UF ─────────────────────────────
BEGIN;
SELECT qa.como('qa_gestor');
DO $$
DECLARE e uuid; r record;
BEGIN
  INSERT INTO public.escoltas (cliente_id, data_hora_prevista, origem_endereco, origem_lat, origem_lng, destino_endereco, destino_lat, destino_lng,
                               data_solicitacao, status, checklist_pendente_no_inicio, criada_por, origem_uf, destino_uf, uf_estimada)
  VALUES ('00000000-0000-4000-a000-0000000000c1', now() + interval '2 days', 'QA K Rio', -22.9068, -43.1729, 'QA K São Paulo', -23.5505, -46.6333,
          now(), 'agendada', true, public.get_meu_usuario_id(), 'RJ', 'SP', false) RETURNING id INTO e;
  SELECT interestadual INTO r FROM public.escoltas WHERE id = e;
  IF r.interestadual THEN RAISE NOTICE 'PASSOU: Rio para São Paulo gravada pela gestão sai interestadual';
  ELSE RAISE NOTICE 'FALHOU: Rio para São Paulo não interestadual'; END IF;
  UPDATE public.escoltas SET destino_uf = 'RJ' WHERE id = e;
  SELECT interestadual INTO r FROM public.escoltas WHERE id = e;
  IF r.interestadual = false THEN RAISE NOTICE 'PASSOU: só RJ não é interestadual';
  ELSE RAISE NOTICE 'FALHOU: só RJ deu %', r.interestadual; END IF;
  UPDATE public.escoltas SET destino_uf = NULL WHERE id = e;
  SELECT interestadual INTO r FROM public.escoltas WHERE id = e;
  IF r.interestadual IS NULL THEN RAISE NOTICE 'PASSOU: RJ e UF desconhecida fica nula (não determinado)';
  ELSE RAISE NOTICE 'FALHOU: RJ e nula deu %', r.interestadual; END IF;
  UPDATE public.escoltas SET origem_uf = 'MG' WHERE id = e;
  SELECT interestadual INTO r FROM public.escoltas WHERE id = e;
  IF r.interestadual THEN RAISE NOTICE 'PASSOU: origem MG e destino desconhecido já é interestadual';
  ELSE RAISE NOTICE 'FALHOU: MG e nula deu %', r.interestadual; END IF;
  BEGIN
    UPDATE public.escoltas SET origem_uf = 'rj' WHERE id = e;
    RAISE NOTICE 'FALHOU: UF minúscula aceita';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: UF fora do formato de duas letras maiúsculas';
  END;
  -- Edição pela RPC da gestão (218): troca a UF e a interestadual acompanha.
  PERFORM public.editar_escolta(e, '{"origem_uf": "RJ", "destino_uf": "SP", "uf_estimada": true}'::jsonb, NULL, NULL);
  SELECT origem_uf, destino_uf, uf_estimada, interestadual INTO r FROM public.escoltas WHERE id = e;
  IF r.origem_uf = 'RJ' AND r.destino_uf = 'SP' AND r.uf_estimada AND r.interestadual THEN
    RAISE NOTICE 'PASSOU: editar_escolta grava origem_uf, destino_uf e uf_estimada, e interestadual acompanha';
  ELSE RAISE NOTICE 'FALHOU: editar_escolta deu % % % %', r.origem_uf, r.destino_uf, r.uf_estimada, r.interestadual; END IF;
  PERFORM public.editar_escolta(e, jsonb_build_object('data_hora_prevista', now() + interval '3 days'), NULL, NULL);
  SELECT origem_uf, destino_uf, uf_estimada INTO r FROM public.escoltas WHERE id = e;
  IF r.origem_uf = 'RJ' AND r.destino_uf = 'SP' AND r.uf_estimada THEN RAISE NOTICE 'PASSOU: editar só a data não mexe na UF';
  ELSE RAISE NOTICE 'FALHOU: editar a data mudou a UF'; END IF;
END $$;
SELECT pg_temp.pg();
ROLLBACK;

-- ── 5. Carga: ESC-2026-0001 e 0007 sem mudança, lista de conferência e escoltas já com UF ──
BEGIN;
-- No banco recriado do zero elas não existem: nascem aqui (sem UF, com coordenada de São Paulo, que a
-- carga preencheria se não as excluísse), só dentro desta transação desfeita.
DO $$
DECLARE c text; e uuid;
BEGIN
  FOREACH c IN ARRAY ARRAY['ESC-2026-0001', 'ESC-2026-0007'] LOOP
    IF NOT EXISTS (SELECT 1 FROM public.escoltas WHERE codigo_escolta = c) THEN
      e := qa.nova_escolta(now() - interval '30 days', 'cancelada');
      UPDATE public.escoltas SET codigo_escolta = c, origem_lat = -23.5505, origem_lng = -46.6333 WHERE id = e;
    END IF;
  END LOOP;
END $$;
CREATE TEMP TABLE k_antes ON COMMIT DROP AS
  SELECT id, codigo_escolta, to_jsonb(e) AS linha FROM public.escoltas e WHERE codigo_escolta IN ('ESC-2026-0001', 'ESC-2026-0007');
DO $$
DECLARE e1 uuid; e2 uuid; e3 uuid; e4 uuid; n int; r record; v_atu timestamptz;
BEGIN
  -- Escolta sem UF de Além Paraíba (perto da divisa) para o Galeão (fora da malha mínima).
  e1 := qa.nova_escolta(now() + interval '1 day');
  UPDATE public.escoltas SET origem_lat = -21.8856, origem_lng = -42.7044, destino_lat = -22.8135, destino_lng = -43.2486 WHERE id = e1;
  -- Escolta de São Paulo para o Rio, sem UF.
  e2 := qa.nova_escolta(now() + interval '1 day');
  UPDATE public.escoltas SET origem_lat = -23.5505, origem_lng = -46.6333 WHERE id = e2;
  -- Escolta que já tem UF gravada (não pode mudar) e escolta sem coordenada (não pode mudar).
  e3 := qa.nova_escolta(now() + interval '1 day');
  UPDATE public.escoltas SET origem_uf = 'ES', destino_uf = 'RJ' WHERE id = e3;
  e4 := qa.nova_escolta(now() + interval '1 day');
  UPDATE public.escoltas SET origem_lat = 0, origem_lng = 0, destino_lat = 0, destino_lng = 0 WHERE id = e4;
  SELECT atualizado_em INTO v_atu FROM public.escoltas WHERE id = e4;

  n := lote_interno.carregar_uf_escoltas();

  SELECT origem_uf, destino_uf, uf_estimada, interestadual INTO r FROM public.escoltas WHERE id = e1;
  IF r.origem_uf = 'MG' AND r.destino_uf = 'RJ' AND r.uf_estimada AND r.interestadual THEN
    RAISE NOTICE 'PASSOU: carga dá MG e RJ pela coordenada, com uf_estimada, e a escolta sai interestadual';
  ELSE RAISE NOTICE 'FALHOU: carga deu % % % %', r.origem_uf, r.destino_uf, r.uf_estimada, r.interestadual; END IF;
  SELECT count(*) INTO n FROM backup_20261008.uf_a_conferir
   WHERE escolta_id = e1 AND ((lado = 'origem' AND distancia_divisa_km < 5 AND NOT fora_da_malha) OR (lado = 'destino' AND fora_da_malha));
  IF n = 2 THEN RAISE NOTICE 'PASSOU: origem a menos de 5 km da divisa e destino fora da malha vão para backup_20261008.uf_a_conferir';
  ELSE RAISE NOTICE 'FALHOU: % de 2 lados na lista de conferência', n; END IF;
  SELECT origem_uf, destino_uf, interestadual INTO r FROM public.escoltas WHERE id = e2;
  IF r.origem_uf = 'SP' AND r.destino_uf = 'RJ' AND r.interestadual
     AND NOT EXISTS (SELECT 1 FROM backup_20261008.uf_a_conferir WHERE escolta_id = e2 AND lado = 'origem') THEN
    RAISE NOTICE 'PASSOU: São Paulo para o Rio pela carga sai interestadual, longe da divisa fora da lista';
  ELSE RAISE NOTICE 'FALHOU: SP para RJ deu % % %', r.origem_uf, r.destino_uf, r.interestadual; END IF;
  SELECT origem_uf, destino_uf, uf_estimada INTO r FROM public.escoltas WHERE id = e3;
  IF r.origem_uf = 'ES' AND r.destino_uf = 'RJ' AND NOT r.uf_estimada THEN RAISE NOTICE 'PASSOU: escolta que já tinha UF não é tocada pela carga';
  ELSE RAISE NOTICE 'FALHOU: escolta com UF mudou para % %', r.origem_uf, r.destino_uf; END IF;
  SELECT origem_uf, destino_uf, uf_estimada, atualizado_em = v_atu AS igual INTO r FROM public.escoltas WHERE id = e4;
  IF r.origem_uf IS NULL AND r.destino_uf IS NULL AND NOT r.uf_estimada AND r.igual THEN
    RAISE NOTICE 'PASSOU: escolta sem coordenada (0,0 nos dois lados, como a Nova trata vazio) fica sem UF e nem é atualizada';
  ELSE RAISE NOTICE 'FALHOU: escolta sem coordenada %', r; END IF;
END $$;
DO $$
DECLARE n_antes int; n_igual int;
BEGIN
  SELECT count(*) INTO n_antes FROM k_antes;
  SELECT count(*) INTO n_igual FROM k_antes a JOIN public.escoltas e ON e.id = a.id
   WHERE to_jsonb(e) = a.linha AND e.origem_uf IS NULL AND e.destino_uf IS NULL AND NOT e.uf_estimada;
  IF n_antes = 2 AND n_antes = n_igual THEN
    RAISE NOTICE 'PASSOU: ESC-2026-0001 e ESC-2026-0007 (% no banco) idênticas linha a linha antes e depois da carga, sem UF', n_antes;
  ELSE RAISE NOTICE 'FALHOU: % de % escoltas protegidas iguais depois da carga', n_igual, n_antes; END IF;
  IF NOT EXISTS (SELECT 1 FROM backup_20261008.uf_a_conferir WHERE codigo_escolta IN ('ESC-2026-0001', 'ESC-2026-0007')) THEN
    RAISE NOTICE 'PASSOU: ESC-2026-0001 e 0007 fora da lista de conferência';
  ELSE RAISE NOTICE 'FALHOU: escolta protegida na lista de conferência'; END IF;
END $$;
ROLLBACK;

-- ── 6. Paleta: cor fora da paleta normalizada, master gravando cor livre, contraste ─────
BEGIN;
DO $$
DECLARE r record; v_ok int := 0; v_tot int := 0; n int;
BEGIN
  -- Contraste de texto branco das 12 cores (script de conferência no banco).
  FOR r IN SELECT cor, nome, pg_temp.contraste_branco(cor) AS c FROM public.paleta_clientes ORDER BY ordem LOOP
    v_tot := v_tot + 1;
    IF r.c >= 4.5 THEN v_ok := v_ok + 1; ELSE RAISE NOTICE 'FALHOU: % (%) com contraste %', r.nome, r.cor, r.c; END IF;
  END LOOP;
  IF v_ok = 12 AND v_tot = 12 THEN RAISE NOTICE 'PASSOU: as 12 cores da paleta com contraste de texto branco de pelo menos 4,5:1 (menor %)',
    (SELECT min(pg_temp.contraste_branco(cor)) FROM public.paleta_clientes);
  ELSE RAISE NOTICE 'FALHOU: % de % cores com contraste', v_ok, v_tot; END IF;
  SELECT count(*) INTO n FROM public.paleta_clientes p WHERE lote_interno.cor_da_paleta(lower(p.cor)) = p.cor;
  IF n = 12 THEN RAISE NOTICE 'PASSOU: cada cor da paleta (também minúscula) fica como está';
  ELSE RAISE NOTICE 'FALHOU: % de 12 cores da paleta preservadas', n; END IF;
END $$;
SELECT qa.como('qa_gestor');
DO $$
DECLARE c uuid; v text; r record; v_ok int := 0; v_tot int := 0;
BEGIN
  -- Como a master grava (cadastros/page.tsx e clientes/page.tsx): INSERT com cor livre do <input type="color">.
  FOR r IN SELECT * FROM (VALUES ('#ff0000', '#B91C1C'), ('#00FF00', '#4D7C0F'), ('#3b82f6', '#1D4ED8'), ('#4A90A4', '#115E59'),
                                 ('#53648A', '#475569'), ('#a855f7', '#7C3AED'), ('azul', '#1D4ED8'), ('', '#1D4ED8'), ('#12345', '#1D4ED8'),
                                 (NULL, '#1D4ED8')) x(entrada, esperado) LOOP
    v_tot := v_tot + 1;
    INSERT INTO public.clientes (nome_cliente, contato, telefone, cor_destaque, status) VALUES ('QA K cliente ' || v_tot, 'QA', '2100000000', r.entrada, 'ativo') RETURNING id, cor_destaque INTO c, v;
    IF v = r.esperado THEN v_ok := v_ok + 1; ELSE RAISE NOTICE 'FALHOU: % gravou %, esperado %', coalesce(r.entrada, 'nula'), v, r.esperado; END IF;
  END LOOP;
  IF v_ok = v_tot THEN RAISE NOTICE 'PASSOU: cadastro como a master (cor livre, minúscula, texto inválido e nula) grava sem erro e cai na paleta (% casos)', v_tot;
  ELSE RAISE NOTICE 'FALHOU: % de % cores normalizadas', v_ok, v_tot; END IF;
  INSERT INTO public.clientes (nome_cliente, contato, telefone, status) VALUES ('QA K sem cor', 'QA', '2100000000', 'ativo') RETURNING cor_destaque INTO v;
  IF v = '#1D4ED8' THEN RAISE NOTICE 'PASSOU: cliente sem cor nasce com a padrão da paleta';
  ELSE RAISE NOTICE 'FALHOU: sem cor nasceu %', v; END IF;
  UPDATE public.clientes SET cor_destaque = '#FFFF00' WHERE id = c RETURNING cor_destaque INTO v;
  IF v = '#4D7C0F' THEN RAISE NOTICE 'PASSOU: UPDATE da cor pela master (#FFFF00) cai na mais próxima (#4D7C0F)';
  ELSE RAISE NOTICE 'FALHOU: UPDATE deu %', v; END IF;
  UPDATE public.clientes SET observacoes = 'teste K' WHERE id = c RETURNING cor_destaque INTO v;
  IF v = '#4D7C0F' THEN RAISE NOTICE 'PASSOU: UPDATE sem a cor não mexe na cor';
  ELSE RAISE NOTICE 'FALHOU: UPDATE sem cor mudou para %', v; END IF;
  -- S6: a mesma cor em dois clientes ativos é aceita.
  UPDATE public.clientes SET cor_destaque = '#4D7C0F' WHERE nome_cliente = 'QA K sem cor' RETURNING cor_destaque INTO v;
  IF v = '#4D7C0F' THEN RAISE NOTICE 'PASSOU: cor não exclusiva (S6): dois clientes ativos com a mesma cor';
  ELSE RAISE NOTICE 'FALHOU: cor repetida recusada'; END IF;
END $$;
SELECT pg_temp.pg();
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.clientes c WHERE NOT EXISTS (SELECT 1 FROM public.paleta_clientes p WHERE p.cor = c.cor_destaque);
  IF n = 0 THEN RAISE NOTICE 'PASSOU: nenhum cliente com cor fora da paleta';
  ELSE RAISE NOTICE 'FALHOU: % clientes fora da paleta', n; END IF;
  SELECT count(*) INTO n FROM backup_20261008.cores_clientes b JOIN public.clientes c ON c.id = b.cliente_id;
  IF n >= 1 THEN RAISE NOTICE 'PASSOU: cor antiga dos clientes guardada em backup_20261008.cores_clientes (% clientes)', n;
  ELSE RAISE NOTICE 'FALHOU: backup das cores vazio'; END IF;
END $$;
ROLLBACK;

-- ── 7. Operador não altera a UF; supervisor e central não alteram UF de escolta iniciada ──
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 hour', 'agendada', 'qa_um', 1)::text, true);
UPDATE public.escoltas SET origem_uf = 'RJ', destino_uf = 'SP', uf_estimada = true WHERE id = current_setting('t.esc')::uuid;
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; f text; v_ok int := 0; v_tot int := 0; n int;
BEGIN
  PERFORM qa.como('qa_um');
  FOREACH f IN ARRAY ARRAY[
      format('UPDATE public.escoltas SET origem_uf = %L WHERE id = %L', 'MG', e),
      format('UPDATE public.escoltas SET destino_uf = %L WHERE id = %L', 'RJ', e),
      format('UPDATE public.escoltas SET destino_uf = NULL WHERE id = %L', e),
      format('UPDATE public.escoltas SET uf_estimada = false WHERE id = %L', e)] LOOP
    v_tot := v_tot + 1;
    BEGIN
      EXECUTE f;
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n = 0 THEN RAISE NOTICE 'FALHOU: o operador não enxerga a própria escolta (% linhas)', n;
      ELSE RAISE NOTICE 'FALHOU: operador executou %', f; END IF;
    EXCEPTION WHEN raise_exception THEN v_ok := v_ok + 1;
    END;
  END LOOP;
  PERFORM pg_temp.pg();
  IF v_ok = v_tot THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador da escolta não altera origem_uf, destino_uf nem uf_estimada (% tentativas)', v_tot;
  ELSE RAISE NOTICE 'FALHOU: % de % tentativas recusadas', v_ok, v_tot; END IF;
END $$;
-- Escolta já iniciada: só gestor e administrador mudam a UF (214, por to_jsonb, sem citar a coluna).
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; u text; v_ok int := 0; n int;
BEGIN
  FOREACH u IN ARRAY ARRAY['qa_supervisor', 'qa_central'] LOOP
    PERFORM qa.como(u);
    BEGIN
      UPDATE public.escoltas SET destino_uf = 'MG' WHERE id = e;
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n = 0 THEN v_ok := v_ok + 1; ELSE RAISE NOTICE 'FALHOU: % mudou a UF de escolta iniciada', u; END IF;
    EXCEPTION WHEN insufficient_privilege OR raise_exception THEN v_ok := v_ok + 1;
    END;
    PERFORM pg_temp.pg();
  END LOOP;
  IF v_ok = 2 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: supervisor e central não mudam a UF de escolta iniciada (trava da 214)';
  ELSE RAISE NOTICE 'FALHOU: % de 2 recusados', v_ok; END IF;
  PERFORM qa.como('qa_gestor');
  UPDATE public.escoltas SET destino_uf = 'MG' WHERE id = e;
  PERFORM pg_temp.pg();
  IF (SELECT destino_uf FROM public.escoltas WHERE id = e) = 'MG' THEN RAISE NOTICE 'PASSOU: gestor muda a UF de escolta iniciada';
  ELSE RAISE NOTICE 'FALHOU: gestor não mudou a UF'; END IF;
END $$;
ROLLBACK;

-- ── 8. Escolta iniciada com UF avança pelo operador, pelo supervisor e pela central ─────
BEGIN;
SELECT set_config('t.esc', qa.nova_escolta(now() + interval '1 hour', 'agendada', 'qa_um', 2)::text, true);
UPDATE public.escoltas SET origem_uf = 'RJ', destino_uf = 'SP', uf_estimada = true WHERE id = current_setting('t.esc')::uuid;
SELECT qa.como('qa_um');
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'em_andamento');
DO $$
DECLARE e uuid := current_setting('t.esc')::uuid; n int;
BEGIN
  -- Como a master grava a etapa (ponto pela tela e UPDATE de status direto), pelo operador.
  INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, sem_sinal_gps, lancado_por)
  SELECT ev.id, pg_temp.tp('origem'), clock_timestamp(), true, public.get_meu_usuario_id() FROM public.escolta_veiculos ev WHERE ev.escolta_id = e;
  UPDATE public.escoltas SET status = 'na_origem' WHERE id = e;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 1 THEN RAISE NOTICE 'PASSOU: operador avança a escolta com UF por UPDATE de status (como a master), de em_andamento para na_origem';
  ELSE RAISE NOTICE 'FALHOU: UPDATE de status do operador mudou % linhas', n; END IF;
END $$;
SELECT pg_temp.pg();
SELECT qa.como('qa_supervisor');
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'no_destino');
SELECT pg_temp.pg();
SELECT qa.como('qa_central');
SELECT pg_temp.jornada(current_setting('t.esc')::uuid, 'na_base');
SELECT pg_temp.pg();
DO $$
DECLARE r record;
BEGIN
  SELECT status, origem_uf, destino_uf, uf_estimada, interestadual INTO r FROM public.escoltas WHERE id = current_setting('t.esc')::uuid;
  IF r.status = 'na_base' AND r.origem_uf = 'RJ' AND r.destino_uf = 'SP' AND r.uf_estimada AND r.interestadual THEN
    RAISE NOTICE 'PASSOU: escolta iniciada com UF avançada pelo operador (registrar_etapa_escolta e UPDATE direto), pelo supervisor e pela central até na_base, UF intacta';
  ELSE RAISE NOTICE 'FALHOU: escolta parou em % com UF % % %', r.status, r.origem_uf, r.destino_uf, r.interestadual; END IF;
END $$;
ROLLBACK;

-- ── 9. Cor do cliente no mural do operador (só a cor, só das escoltas que ele enxerga) ──
BEGIN;
DO $$
DECLARE c2 uuid; e_mural uuid; e_outra uuid; e_minha uuid; n int; v text; v_nome_visivel boolean;
BEGIN
  INSERT INTO public.clientes (nome_cliente, contato, telefone, cor_destaque, status)
  VALUES ('QA K cliente do mural', 'QA', '2100000000', '#BE185D', 'ativo') RETURNING id INTO c2;
  e_mural := qa.nova_escolta(now() + interval '5 hours');                       -- agendada sem equipe (mural)
  UPDATE public.escoltas SET cliente_id = c2 WHERE id = e_mural;
  e_outra := qa.nova_escolta(now() + interval '5 hours', 'em_andamento', 'qa_dois');  -- iniciada de outra equipe
  UPDATE public.escoltas SET cliente_id = c2 WHERE id = e_outra;
  e_minha := qa.nova_escolta(now() + interval '5 hours', 'agendada', 'qa_um');
  PERFORM set_config('t.c2', c2::text, true);

  PERFORM qa.como('qa_um');
  SELECT EXISTS (SELECT 1 FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id WHERE e.id = e_mural) INTO v_nome_visivel;
  SELECT x.cor_destaque INTO v FROM public.cores_clientes_das_escoltas(ARRAY[e_mural]) x;
  IF NOT v_nome_visivel AND v = '#BE185D' THEN
    RAISE NOTICE 'PASSOU: operador não lê o cliente da escolta do mural pela RLS, mas recebe a cor dele (#BE185D) pela RPC';
  ELSE RAISE NOTICE 'FALHOU: mural visível % cor %', v_nome_visivel, v; END IF;
  SELECT count(*) INTO n FROM public.cores_clientes_das_escoltas(ARRAY[e_outra]);
  IF n = 0 THEN RAISE NOTICE 'BLOQUEADO CORRETAMENTE: operador não recebe a cor de escolta iniciada de outra equipe';
  ELSE RAISE NOTICE 'FALHOU: operador recebeu a cor de escolta que não enxerga'; END IF;
  SELECT count(*) INTO n FROM public.cores_clientes_das_escoltas(ARRAY[e_minha, e_mural]);
  IF n = 2 THEN RAISE NOTICE 'PASSOU: operador recebe a cor da própria escolta e da do mural numa chamada';
  ELSE RAISE NOTICE 'FALHOU: % de 2 cores', n; END IF;
  PERFORM pg_temp.pg();
  IF (SELECT array_agg(parameter_name::text ORDER BY ordinal_position) FROM information_schema.parameters p
           JOIN information_schema.routines r ON r.specific_name = p.specific_name
          WHERE r.routine_name = 'cores_clientes_das_escoltas' AND p.parameter_mode = 'OUT') = ARRAY['escolta_id', 'cor_destaque'] THEN
    RAISE NOTICE 'PASSOU: a RPC devolve só escolta_id e cor_destaque (nunca o nome do cliente)';
  ELSE RAISE NOTICE 'FALHOU: colunas devolvidas pela RPC'; END IF;
  IF NOT has_function_privilege('anon', 'public.cores_clientes_das_escoltas(uuid[])', 'EXECUTE') THEN
    RAISE NOTICE 'BLOQUEADO CORRETAMENTE: anon não executa cores_clientes_das_escoltas';
  ELSE RAISE NOTICE 'FALHOU: anon executa cores_clientes_das_escoltas'; END IF;
END $$;
ROLLBACK;
