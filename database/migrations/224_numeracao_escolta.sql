-- 224_numeracao_escolta.sql
-- Pedido de Peçanha em 2026-11-13: criar escolta nova dava erro. Idempotente. Depois da 223
-- (funciona também sem ela: só depende da 195 e das colunas da 221).
--
-- Causa:
-- 1. O código ESC-AAAA-NNNN vem da trigger tr_gerar_codigo_escolta (função
--    public.gerar_codigo_escolta, versão de produção na 195): MAX do número do ano + 1.
-- 2. A função era SECURITY INVOKER. O MAX rodava com a RLS de quem cria a escolta e só
--    enxergava as escoltas visíveis para ele.
-- 3. A 221 esconde as excluídas de todos os perfis (policy RESTRICTIVE escoltas_excluida_oculta),
--    e as arquivadas já ficavam escondidas do supervisor (escoltas_arquivada_so_admin). Quando a
--    escolta de maior número do ano está excluída (ex.: ESC-2026-0010 e 0011), o MAX volta um
--    número já gravado e o INSERT colide com escoltas_codigo_escolta_key (23505).
-- 4. Duas criações ao mesmo tempo também calculavam o mesmo número (sem trava).
--
-- O que faz:
-- 1. lote_interno.escolta_codigo_contador (ano, ultimo): o último número dado em cada ano.
--    Carga inicial com o maior número já gravado de cada ano, contando TODAS as escoltas
--    (excluídas, arquivadas e apagadas logicamente incluídas). Sem acesso para anon e
--    authenticated; só as funções abaixo mexem nele.
-- 2. public.gerar_codigo_escolta passa a SECURITY DEFINER (enxerga todas as escoltas, sem a
--    RLS) e reserva o número pelo contador com INSERT ... ON CONFLICT DO UPDATE: a linha do ano
--    fica travada até o fim da transação, então duas criações simultâneas saem com números
--    diferentes. O número é o maior entre o contador e o maior código gravado, mais um: código
--    gravado à mão nunca é repetido. Número de escolta excluída nunca volta a ser usado.
--    Transação desfeita devolve o número (sem buraco). O formato e o ano (TO_CHAR(NOW()))
--    ficam iguais aos de antes; código informado no INSERT continua sendo respeitado.
-- 3. public.criar_escolta(p_campos, p_viaturas): cria escolta, viaturas e equipe numa só
--    transação (tudo ou nada). SECURITY INVOKER de propósito: valem as mesmas policies RLS e
--    triggers do INSERT que a tela fazia direto (escoltas_insert, escolta_veiculos_escrita,
--    escolta_efetivo_escrita), sem abrir permissão nova. Lista fechada de campos (a mesma da
--    editar_escolta da 218); status, data da solicitação, checklist pendente e autor são
--    definidos aqui. Se o código colidir mesmo assim (código gravado por outro caminho na
--    mesma hora), tenta de novo até 5 vezes. Devolve id e codigo_escolta.
--
-- Não muda: tabelas existentes, policies, outras RPCs, a tela de edição (editar_escolta).
-- A tela nova chama criar_escolta; sem esta migration ela cai no caminho antigo (INSERT
-- direto), agora com a mensagem de erro real.
-- Reversão: 224_numeracao_escolta_reverter.sql. Conferência: database/testes/07_numeracao_escolta.sql.

-- ── 1. Contador ──────────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS lote_interno;

CREATE TABLE IF NOT EXISTS lote_interno.escolta_codigo_contador (
  ano           integer PRIMARY KEY CHECK (ano BETWEEN 2000 AND 9999),
  ultimo        integer NOT NULL CHECK (ultimo >= 0),
  atualizado_em timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE lote_interno.escolta_codigo_contador IS
  '224: último número de ESC-AAAA-NNNN dado em cada ano. Só public.gerar_codigo_escolta grava. Nunca diminuir.';
ALTER TABLE lote_interno.escolta_codigo_contador ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE lote_interno.escolta_codigo_contador FROM PUBLIC, anon, authenticated;

-- Carga: o maior número gravado de cada ano, em TODAS as escoltas. Nunca diminui o contador.
INSERT INTO lote_interno.escolta_codigo_contador AS c (ano, ultimo)
SELECT substring(codigo_escolta FROM '^ESC-(\d{4})-')::int,
       max(substring(codigo_escolta FROM '^ESC-\d{4}-(\d+)')::int)
  FROM public.escoltas
 WHERE codigo_escolta ~ '^ESC-\d{4}-\d+'
 GROUP BY 1
ON CONFLICT (ano) DO UPDATE SET ultimo = greatest(c.ultimo, excluded.ultimo), atualizado_em = now();

-- ── 2. Gerador ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.gerar_codigo_escolta() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_ano  text;
  v_max  integer;
  v_seq  integer;
BEGIN
  IF NEW.codigo_escolta IS NULL OR NEW.codigo_escolta = '' THEN
    v_ano := TO_CHAR(NOW(), 'YYYY');
    -- Maior número gravado no ano, em todas as escoltas (SECURITY DEFINER: sem a RLS).
    SELECT COALESCE(MAX(CAST(SUBSTRING(codigo_escolta FROM 'ESC-' || v_ano || '-(\d+)') AS INTEGER)), 0)
      INTO v_max
      FROM public.escoltas
     WHERE codigo_escolta LIKE 'ESC-' || v_ano || '-%';
    -- Reserva: a linha do ano fica travada até o fim da transação (criação simultânea espera).
    INSERT INTO lote_interno.escolta_codigo_contador AS c (ano, ultimo, atualizado_em)
    VALUES (v_ano::int, v_max + 1, now())
    ON CONFLICT (ano) DO UPDATE SET ultimo = greatest(c.ultimo, v_max) + 1, atualizado_em = now()
    RETURNING c.ultimo INTO v_seq;

    NEW.codigo_escolta := 'ESC-' || v_ano || '-' || LPAD(v_seq::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;
-- Função de trigger: ninguém chama direto. A trigger roda com o dono da função.
REVOKE ALL ON FUNCTION public.gerar_codigo_escolta() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.gerar_codigo_escolta() IS
  '224: SECURITY DEFINER e contador em lote_interno.escolta_codigo_contador. Nunca repete código, nem de escolta excluída.';

-- A trigger já existe (195); recriada só se faltar.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tr_gerar_codigo_escolta' AND tgrelid = 'public.escoltas'::regclass) THEN
    CREATE TRIGGER tr_gerar_codigo_escolta BEFORE INSERT ON public.escoltas
      FOR EACH ROW EXECUTE FUNCTION public.gerar_codigo_escolta();
  END IF;
END $$;

-- ── 3. Criação atômica ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.criar_escolta(p_campos jsonb, p_viaturas jsonb)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  v_perfil text; v_eu uuid; v_campos jsonb := coalesce(p_campos, '{}'::jsonb);
  v_permitidos text[] := ARRAY['cliente_id', 'data_hora_prevista', 'origem_endereco', 'origem_lat', 'origem_lng',
                               'destino_endereco', 'destino_lat', 'destino_lng', 'metadados', 'periodicidade_checkin_min',
                               'valor_cobrado', 'outros_custos', 'observacao_financeira', 'escala_fixa',
                               'origem_uf', 'destino_uf', 'origem_uf_estimada', 'destino_uf_estimada'];
  v_k text; v_cols text; v_vals text; vt jsonb; m jsonb; v_ev uuid; v_id uuid; v_codigo text;
  v_vigs uuid[] := '{}'; v_veics uuid[] := '{}'; v_tentativa int := 0; v_restricao text;
  v_i int := 0; v_j int;
BEGIN
  v_perfil := public.get_meu_perfil();
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Sem permissão para criar escolta.' USING ERRCODE = '42501';
  END IF;
  v_eu := public.get_meu_usuario_id();

  -- Campos: lista fechada; obrigatórios conferidos aqui com mensagem clara.
  IF jsonb_typeof(v_campos) <> 'object' THEN RAISE EXCEPTION 'Dados da escolta inválidos.'; END IF;
  FOR v_k IN SELECT jsonb_object_keys(v_campos) LOOP
    IF NOT v_k = ANY (v_permitidos) THEN RAISE EXCEPTION 'Campo não aceito na criação: %', v_k; END IF;
  END LOOP;
  IF nullif(v_campos ->> 'cliente_id', '') IS NULL THEN RAISE EXCEPTION 'Selecione o cliente contratante.'; END IF;
  IF nullif(v_campos ->> 'data_hora_prevista', '') IS NULL THEN RAISE EXCEPTION 'Informe a data e a hora de partida.'; END IF;
  IF nullif(trim(coalesce(v_campos ->> 'origem_endereco', '')), '') IS NULL THEN RAISE EXCEPTION 'Informe o endereço de origem.'; END IF;
  IF nullif(trim(coalesce(v_campos ->> 'destino_endereco', '')), '') IS NULL THEN RAISE EXCEPTION 'Informe o endereço de destino.'; END IF;
  IF coalesce((v_campos ->> 'origem_lat')::numeric, 0) = 0 OR coalesce((v_campos ->> 'origem_lng')::numeric, 0) = 0 THEN
    RAISE EXCEPTION 'Origem sem coordenada. Selecione o endereço na lista de sugestões.';
  END IF;
  IF coalesce((v_campos ->> 'destino_lat')::numeric, 0) = 0 OR coalesce((v_campos ->> 'destino_lng')::numeric, 0) = 0 THEN
    RAISE EXCEPTION 'Destino sem coordenada. Selecione o endereço na lista de sugestões.';
  END IF;

  -- Viaturas e equipe: conferidas antes de gravar qualquer coisa.
  IF p_viaturas IS NULL OR jsonb_typeof(p_viaturas) <> 'array' OR jsonb_array_length(p_viaturas) = 0 THEN
    RAISE EXCEPTION 'A escolta precisa de ao menos uma viatura.';
  END IF;
  FOR vt IN SELECT * FROM jsonb_array_elements(p_viaturas) LOOP
    v_i := v_i + 1;
    IF nullif(vt ->> 'veiculo_id', '') IS NULL THEN RAISE EXCEPTION 'Viatura %: selecione o veículo.', v_i; END IF;
    IF (vt ->> 'veiculo_id')::uuid = ANY (v_veics) THEN
      RAISE EXCEPTION 'O veículo % está em duas viaturas. Cada placa entra uma vez só na escolta.',
        coalesce((SELECT placa FROM public.veiculos WHERE id = (vt ->> 'veiculo_id')::uuid), 'selecionado');
    END IF;
    v_veics := v_veics || (vt ->> 'veiculo_id')::uuid;
    v_j := 0;
    FOR m IN SELECT * FROM jsonb_array_elements(coalesce(vt -> 'membros', '[]'::jsonb)) LOOP
      v_j := v_j + 1;
      IF nullif(m ->> 'vigilante_id', '') IS NULL THEN
        RAISE EXCEPTION 'Viatura %, membro %: selecione o vigilante ou remova a linha.', v_i, v_j;
      END IF;
      IF (m ->> 'vigilante_id')::uuid = ANY (v_vigs) THEN
        RAISE EXCEPTION 'O vigilante % está escalado duas vezes. Cada vigilante entra uma vez só na escolta.',
          coalesce((SELECT nome_completo FROM public.vigilantes WHERE id = (m ->> 'vigilante_id')::uuid), 'selecionado');
      END IF;
      v_vigs := v_vigs || (m ->> 'vigilante_id')::uuid;
    END LOOP;
    IF v_j > 0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(vt -> 'membros') x WHERE x ->> 'papel_na_escolta' = 'comandante') THEN
      RAISE EXCEPTION 'Viatura %: defina um Comandante entre os vigilantes escalados.', v_i;
    END IF;
  END LOOP;

  -- Escolta: só as colunas recebidas (e que existem), mais as fixas da criação.
  v_campos := v_campos || jsonb_build_object('status', 'agendada', 'data_solicitacao', now(),
                                             'checklist_pendente_no_inicio', true, 'criada_por', v_eu);
  SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum),
         string_agg(format('r.%I', a.attname), ', ' ORDER BY a.attnum)
    INTO v_cols, v_vals
    FROM pg_attribute a
   WHERE a.attrelid = 'public.escoltas'::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
     AND a.attname::text = ANY (v_permitidos || ARRAY['status', 'data_solicitacao', 'checklist_pendente_no_inicio', 'criada_por'])
     AND v_campos ? a.attname::text;

  -- O código vem da trigger (224). Colisão (código gravado por outro caminho na mesma hora):
  -- desfaz só a tentativa e tenta de novo; a trigger relê o maior código a cada tentativa.
  LOOP
    v_tentativa := v_tentativa + 1;
    BEGIN
      EXECUTE format('INSERT INTO public.escoltas (%s) SELECT %s FROM jsonb_populate_record(NULL::public.escoltas, $1) r RETURNING id, codigo_escolta',
                     v_cols, v_vals)
        INTO v_id, v_codigo USING v_campos;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      GET STACKED DIAGNOSTICS v_restricao = CONSTRAINT_NAME;
      IF v_restricao IS DISTINCT FROM 'escoltas_codigo_escolta_key' OR v_tentativa >= 5 THEN RAISE; END IF;
    END;
  END LOOP;

  FOR vt IN SELECT * FROM jsonb_array_elements(p_viaturas) LOOP
    INSERT INTO public.escolta_veiculos (escolta_id, veiculo_id)
    VALUES (v_id, (vt ->> 'veiculo_id')::uuid) RETURNING id INTO v_ev;
    FOR m IN SELECT * FROM jsonb_array_elements(coalesce(vt -> 'membros', '[]'::jsonb)) LOOP
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, valor_pago_vigilante)
      VALUES (v_id, v_ev, (m ->> 'vigilante_id')::uuid, coalesce(nullif(m ->> 'papel_na_escolta', ''), 'operador'), false,
              (m ->> 'valor_pago_vigilante')::numeric);
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('id', v_id, 'codigo_escolta', v_codigo);
END;
$$;
REVOKE ALL ON FUNCTION public.criar_escolta(jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.criar_escolta(jsonb, jsonb) TO authenticated;
COMMENT ON FUNCTION public.criar_escolta(jsonb, jsonb) IS
  '224: cria escolta, viaturas e equipe numa transação. SECURITY INVOKER: valem a RLS e as triggers do INSERT direto.';

NOTIFY pgrst, 'reload schema';

-- Conferência rápida (esperado entre parênteses):
-- SELECT prosecdef FROM pg_proc WHERE oid = 'public.gerar_codigo_escolta()'::regprocedure;            -- true
-- SELECT prosecdef FROM pg_proc WHERE oid = 'public.criar_escolta(jsonb, jsonb)'::regprocedure;        -- false
-- SELECT * FROM lote_interno.escolta_codigo_contador ORDER BY ano;  -- o ano corrente com o maior número gravado
-- SELECT has_function_privilege('anon', 'public.criar_escolta(jsonb, jsonb)', 'EXECUTE');              -- false
