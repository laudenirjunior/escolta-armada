-- 195_referencia_estado_atual.sql
--
-- REFERÊNCIA. NÃO APLICAR. Nada aqui deve ser executado no banco.
--
-- Por quê: até 08/10/2026 o repositório só versionava as migrations 111, 193 e 194;
-- as migrations 100 a 192 e as RPCs do mural existiam apenas no banco. Este arquivo
-- guarda a definição atual de produção de todas as funções, triggers, policies e views
-- do schema public, extraída por pg_dump --schema-only em 08/10/2026 (projeto
-- qthoyxujyzskydulvcfy), para que as migrations seguintes (196 em diante) tenham uma
-- base legível e para que cada reversão saiba para onde voltar.
--
-- Limites: não inclui tabelas, constraints, índices nem grants (estão no dump completo,
-- guardado fora do Git), nem os schemas storage e auth.
--
-- Para impedir execução acidental, o bloco abaixo aborta se alguém rodar o arquivo.
DO $$ BEGIN RAISE EXCEPTION '195_referencia_estado_atual.sql e so referencia: nao aplicar.'; END $$;

--
-- Name: assumir_escolta(uuid, uuid[], uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[] DEFAULT '{}'::uuid[], p_veiculo_id uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil       text;
  v_usuario      uuid;
  v_vigilante    uuid;
  v_status       text;
  v_ev           uuid;
  v_equipe_antes jsonb;
  v_veic_antes   jsonb;
  v_acomp        uuid;
  v_qtd_antes    int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN
    RAISE EXCEPTION 'Sessao invalida.';
  END IF;

  SELECT id INTO v_usuario   FROM public.usuarios   WHERE auth_user_id = auth.uid();
  SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante. Fale com o administrador.';
  END IF;

  -- Trava a linha: duas pessoas assumindo ao mesmo tempo produziriam duas equipes.
  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Escolta nao encontrada.';
  END IF;
  IF v_status <> 'agendada' THEN
    RAISE EXCEPTION 'Esta escolta ja comecou e nao pode ter a equipe trocada. Fale com o supervisor.';
  END IF;

  SELECT count(*) INTO v_qtd_antes FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;

  -- Substituir equipe de colega exige justificativa escrita. Assumir escolta vazia, nao.
  IF v_qtd_antes > 0 AND (p_motivo IS NULL OR length(trim(p_motivo)) < 5) THEN
    RAISE EXCEPTION 'Informe o motivo da substituicao da equipe.';
  END IF;

  -- Fotografa o estado anterior ANTES de apagar. Este e o registro que permite
  -- reconstruir depois quem estava escalado, quem assumiu e por que.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'vigilante', v.nome_completo,
           'papel', ee.papel_na_escolta
         ) ORDER BY ee.papel_na_escolta), '[]'::jsonb)
    INTO v_equipe_antes
  FROM public.escolta_efetivo ee
  JOIN public.vigilantes v ON v.id = ee.vigilante_id
  WHERE ee.escolta_id = p_escolta_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object('placa', ve.placa, 'modelo', ve.modelo)), '[]'::jsonb)
    INTO v_veic_antes
  FROM public.escolta_veiculos ev
  JOIN public.veiculos ve ON ve.id = ev.veiculo_id
  WHERE ev.escolta_id = p_escolta_id;

  SELECT id INTO v_ev FROM public.escolta_veiculos
  WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN
    RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.';
  END IF;

  -- Troca de viatura, quando pedida. A escolta ainda nao comecou, entao nao ha ponto de
  -- controle apontando para o vinculo antigo.
  IF p_veiculo_id IS NOT NULL THEN
    UPDATE public.escolta_veiculos
       SET veiculo_id = p_veiculo_id, atualizado_em = now(), atualizado_por = v_usuario
     WHERE id = v_ev;
  END IF;

  DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;

  INSERT INTO public.escolta_efetivo
    (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);

  FOREACH v_acomp IN ARRAY coalesce(p_acompanhantes, '{}')
  LOOP
    IF v_acomp IS DISTINCT FROM v_vigilante THEN
      INSERT INTO public.escolta_efetivo
        (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p_escolta_id, v_ev, v_acomp, 'operador', false, v_usuario)
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  INSERT INTO public.logs_auditoria
    (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES (
    v_usuario,
    CASE WHEN v_qtd_antes > 0 THEN 'substituicao_de_equipe' ELSE 'assumiu_escolta_do_mural' END,
    'escoltas',
    p_escolta_id,
    jsonb_build_object('equipe', v_equipe_antes, 'viaturas', v_veic_antes),
    jsonb_build_object(
      'assumida_por', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante),
      'acompanhantes', (
        SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb)
        FROM public.vigilantes WHERE id = ANY(coalesce(p_acompanhantes, '{}'))
      ),
      'motivo', nullif(trim(coalesce(p_motivo, '')), ''),
      'trocou_viatura', p_veiculo_id IS NOT NULL
    ),
    now()
  );

  RETURN jsonb_build_object(
    'ok', true,
    'substituiu_equipe', v_qtd_antes > 0,
    'equipe_anterior', v_equipe_antes
  );
END;
$$;


--
--
-- Name: FUNCTION assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[], p_veiculo_id uuid, p_motivo text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[], p_veiculo_id uuid, p_motivo text) IS 'Operador assume escolta agendada, inclusive quando ja ha equipe escalada. Grava a equipe e a viatura anteriores em logs_auditoria antes de substituir, e exige motivo quando ha equipe a substituir. So funciona enquanto a escolta nao comecou.';


--
--
-- Name: cadastrar_operador(text, text, text, text, text, uuid, text, text, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cadastrar_operador(p_nome text, p_login_base text, p_cpf text DEFAULT NULL::text, p_telefone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_funcao_id uuid DEFAULT NULL::uuid, p_cnv text DEFAULT NULL::text, p_extensao text DEFAULT NULL::text, p_valor_padrao numeric DEFAULT NULL::numeric, p_status text DEFAULT 'ativo'::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
declare
  v_perfil_chamador text;
  v_perfil_operador uuid;
  v_login   text;
  v_email   text;
  v_dominio text := 'operador.local';
  v_sufixo  int  := 1;
  v_auth_uid uuid;
  v_usuario_id uuid;
  v_criador uuid;
  v_meta jsonb;
begin
  -- Permissão: administrador, gestor ou supervisor
  select public.perfil_usuario_atual() into v_perfil_chamador;
  if v_perfil_chamador is null or v_perfil_chamador not in ('administrador','gestor','supervisor') then
    raise exception 'Permissão negada para cadastrar operador.';
  end if;

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'O nome do operador é obrigatório.';
  end if;
  if coalesce(trim(p_login_base),'') = '' then
    raise exception 'Login base inválido.';
  end if;
  if p_funcao_id is null then
    raise exception 'Selecione a função do operador.';
  end if;

  select id into v_perfil_operador from public.dom_perfis where codigo = 'operador' limit 1;
  if v_perfil_operador is null then
    raise exception 'Perfil operador não encontrado.';
  end if;

  -- Gera login único no formato primeironome_ultimonome (com desambiguação)
  v_login := lower(p_login_base);
  v_email := v_login || '@' || v_dominio;
  while exists (select 1 from auth.users where email = v_email)
     or exists (select 1 from public.usuarios where email = v_email) loop
    v_sufixo := v_sufixo + 1;
    v_login  := lower(p_login_base) || v_sufixo::text;
    v_email  := v_login || '@' || v_dominio;
  end loop;

  v_criador := (select id from public.usuarios where auth_user_id = auth.uid() limit 1);

  if p_email is not null and trim(p_email) <> '' then
    v_meta := jsonb_build_object('login', v_login, 'email_contato', lower(trim(p_email)));
  else
    v_meta := jsonb_build_object('login', v_login);
  end if;

  -- 1. Conta de autenticação (senha inicial 123456, troca obrigatória)
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data, is_super_admin,
    confirmation_token, recovery_token,
    email_change, email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
  ) values (
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(),
    'authenticated', 'authenticated', v_email,
    crypt('123456', gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}',
    jsonb_build_object('nome_completo', p_nome),
    false,
    '', '',
    '', '', '', '', '', ''
  ) returning id into v_auth_uid;

  -- Sem esta linha a conta nasce sem conseguir autenticar.
  insert into auth.identities (id, user_id, identity_data, provider, provider_id,
                               last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_auth_uid,
          jsonb_build_object('sub', v_auth_uid::text, 'email', v_email,
                             'email_verified', true, 'phone_verified', false),
          'email', v_auth_uid::text, null, now(), now());

  -- 2. Governança de acessos (perfil operador)
  insert into public.usuarios (
    auth_user_id, nome_completo, email, cpf, telefone, perfil_id,
    status, troca_senha_obrigatoria, metadados, criado_por
  ) values (
    v_auth_uid, p_nome, v_email,
    nullif(trim(coalesce(p_cpf,'')),''), nullif(trim(coalesce(p_telefone,'')),''),
    v_perfil_operador, coalesce(nullif(trim(p_status),''),'ativo'), true, v_meta, v_criador
  ) returning id into v_usuario_id;

  -- 3. Vigilante vinculado ao usuário
  insert into public.vigilantes (
    usuario_id, nome_completo, cpf, funcao_id, cnv,
    extensao_escolta_armada, valor_padrao_pago, status, criado_por
  ) values (
    v_usuario_id, p_nome, nullif(trim(coalesce(p_cpf,'')),''), p_funcao_id, nullif(trim(coalesce(p_cnv,'')),''),
    nullif(trim(coalesce(p_extensao,'')),''), p_valor_padrao, coalesce(nullif(trim(p_status),''),'ativo'), v_criador
  );

  return json_build_object(
    'login',        v_login,
    'email',        v_email,
    'senha',        '123456',
    'usuario_id',   v_usuario_id,
    'auth_user_id', v_auth_uid
  );
exception
  when unique_violation then
    raise exception 'Já existe um cadastro com esses dados.';
end;
$$;


--
--
-- Name: criar_usuario_completo(text, text, text, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.criar_usuario_completo(p_email text, p_senha_temporaria text, p_nome text, p_perfil_id uuid, p_telefone text DEFAULT NULL::text, p_cpf text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  v_auth_uid    UUID;
  v_usuario_id  UUID;
  v_perfil_cha  TEXT;
BEGIN
  -- Verificar permissão de quem está chamando
  SELECT public.perfil_usuario_atual() INTO v_perfil_cha;
  IF v_perfil_cha IS NULL OR v_perfil_cha NOT IN ('administrador', 'gestor') THEN
    RAISE EXCEPTION 'Permissão negada. Apenas administradores e gestores podem criar usuários.';
  END IF;

  -- Verificar duplicata de e-mail
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = lower(p_email)) THEN
    RAISE EXCEPTION 'Já existe um usuário cadastrado com este e-mail.';
  END IF;

  -- Criar conta no Supabase Auth
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    created_at,
    updated_at,
    raw_app_meta_data,
    raw_user_meta_data,
    is_super_admin,
    confirmation_token,
    recovery_token
  )
  VALUES (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    lower(p_email),
    crypt(p_senha_temporaria, gen_salt('bf')),
    NOW(),
    NOW(),
    NOW(),
    '{"provider":"email","providers":["email"]}',
    jsonb_build_object('nome_completo', p_nome),
    false,
    encode(gen_random_bytes(32), 'hex'),
    encode(gen_random_bytes(32), 'hex')
  )
  RETURNING id INTO v_auth_uid;

  -- Criar registro em public.usuarios
  INSERT INTO public.usuarios (
    auth_user_id,
    nome_completo,
    email,
    cpf,
    telefone,
    perfil_id,
    status,
    troca_senha_obrigatoria,
    criado_por
  )
  VALUES (
    v_auth_uid,
    p_nome,
    lower(p_email),
    COALESCE(NULLIF(TRIM(p_cpf), ''), NULL),
    NULLIF(TRIM(p_telefone), ''),
    p_perfil_id,
    'ativo',
    true,  -- força troca de senha no primeiro acesso
    (SELECT id FROM public.usuarios WHERE auth_user_id = auth.uid() LIMIT 1)
  )
  RETURNING id INTO v_usuario_id;

  RETURN json_build_object(
    'auth_user_id', v_auth_uid,
    'usuario_id',   v_usuario_id,
    'email',        lower(p_email)
  );

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'E-mail já cadastrado no sistema.';
  WHEN others THEN
    RAISE EXCEPTION '%', SQLERRM;
END;
$$;


--
--
-- Name: FUNCTION criar_usuario_completo(p_email text, p_senha_temporaria text, p_nome text, p_perfil_id uuid, p_telefone text, p_cpf text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.criar_usuario_completo(p_email text, p_senha_temporaria text, p_nome text, p_perfil_id uuid, p_telefone text, p_cpf text) IS 'OBSOLETA. Nao cria auth.identities nem preenche as colunas de texto do GoTrue, entao as contas criadas por ela nascem sem conseguir fazer login. Use criar_usuario_por_login. Mantida apenas como referencia historica.';


--
--
-- Name: criar_usuario_por_login(text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.criar_usuario_por_login(p_nome text, p_cpf text, p_telefone text, p_perfil_id uuid) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions', 'pg_temp'
    AS $$
DECLARE
  v_perfil_chamador text;
  v_perfil_alvo text;
  v_limpo text; v_partes text[]; v_login text; v_base text; v_email text;
  v_sufixo int := 1; v_auth_uid uuid; v_usuario_id uuid; v_criador uuid;
  v_cpf text; v_funcao uuid; v_vigilante_id uuid;
BEGIN
  SELECT public.perfil_usuario_atual() INTO v_perfil_chamador;
  IF v_perfil_chamador IS NULL OR v_perfil_chamador NOT IN ('administrador','gestor') THEN
    RAISE EXCEPTION 'Permissao negada. Apenas administradores e gestores podem cadastrar usuarios.';
  END IF;

  SELECT codigo INTO v_perfil_alvo FROM public.dom_perfis WHERE id = p_perfil_id;
  IF v_perfil_alvo IS NULL THEN
    RAISE EXCEPTION 'Selecione o perfil de acesso.';
  END IF;
  IF v_perfil_alvo = 'administrador' AND v_perfil_chamador <> 'administrador' THEN
    RAISE EXCEPTION 'Apenas um administrador pode criar outra conta de administrador.';
  END IF;

  IF coalesce(trim(p_nome),'') = '' THEN
    RAISE EXCEPTION 'O nome completo e obrigatorio.';
  END IF;

  v_cpf := nullif(regexp_replace(coalesce(p_cpf,''), '[^0-9]', '', 'g'), '');
  IF v_cpf IS NULL OR length(v_cpf) <> 11 THEN
    RAISE EXCEPTION 'CPF invalido. Informe os 11 digitos.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.usuarios WHERE regexp_replace(coalesce(cpf,''),'[^0-9]','','g') = v_cpf) THEN
    RAISE EXCEPTION 'Ja existe um usuario cadastrado com este CPF.';
  END IF;

  v_limpo := lower(translate(trim(p_nome),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇç',
    'aaaaaaaaaaeeeeeeeeiiiiiiiioooooooooouuuuuuuucc'));
  v_limpo := regexp_replace(v_limpo, '[^a-z ]', '', 'g');
  v_partes := regexp_split_to_array(trim(v_limpo), '\s+');
  IF array_length(v_partes,1) IS NULL OR v_partes[1] = '' THEN
    RAISE EXCEPTION 'Nao foi possivel gerar o login a partir do nome informado.';
  END IF;
  IF array_length(v_partes,1) = 1 THEN
    v_base := v_partes[1];
  ELSE
    v_base := v_partes[1] || '_' || v_partes[array_length(v_partes,1)];
  END IF;

  v_login := v_base;
  v_email := v_login || '@operador.local';
  WHILE EXISTS (SELECT 1 FROM auth.users WHERE email = v_email)
     OR EXISTS (SELECT 1 FROM public.usuarios WHERE email = v_email) LOOP
    v_sufixo := v_sufixo + 1;
    v_login  := v_base || v_sufixo::text;
    v_email  := v_login || '@operador.local';
  END LOOP;

  v_criador := (SELECT id FROM public.usuarios WHERE auth_user_id = auth.uid() LIMIT 1);

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data, is_super_admin,
    confirmation_token, recovery_token,
    email_change, email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(),
    'authenticated', 'authenticated', v_email,
    crypt('123456', gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}',
    jsonb_build_object('nome_completo', p_nome, 'login', v_login),
    false, '', '', '', '', '', '', '', ''
  ) RETURNING id INTO v_auth_uid;

  INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id,
                               last_sign_in_at, created_at, updated_at)
  VALUES (gen_random_uuid(), v_auth_uid,
          jsonb_build_object('sub', v_auth_uid::text, 'email', v_email,
                             'email_verified', true, 'phone_verified', false),
          'email', v_auth_uid::text, NULL, now(), now());

  INSERT INTO public.usuarios (
    auth_user_id, nome_completo, email, cpf, telefone, perfil_id,
    status, troca_senha_obrigatoria, metadados, criado_por
  ) VALUES (
    v_auth_uid, trim(p_nome), v_email, v_cpf,
    nullif(regexp_replace(coalesce(p_telefone,''), '[^0-9]', '', 'g'), ''),
    p_perfil_id, 'ativo', true,
    jsonb_build_object('login', v_login), v_criador
  ) RETURNING id INTO v_usuario_id;

  -- Operador precisa de vigilante vinculado, senao a RLS de campo o tranca.
  IF v_perfil_alvo = 'operador' THEN
    SELECT id INTO v_funcao FROM public.dom_funcoes WHERE ativo ORDER BY nome LIMIT 1;
    INSERT INTO public.vigilantes (usuario_id, nome_completo, cpf, funcao_id, status, criado_por)
    VALUES (v_usuario_id, trim(p_nome), v_cpf, v_funcao, 'ativo', v_criador)
    RETURNING id INTO v_vigilante_id;
  END IF;

  RETURN json_build_object(
    'login', v_login,
    'senha', '123456',
    'email_interno', v_email,
    'usuario_id', v_usuario_id,
    'vigilante_id', v_vigilante_id,
    'auth_user_id', v_auth_uid
  );
END;
$$;


--
--
-- Name: devolver_escolta(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.devolver_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil    text;
  v_usuario   uuid;
  v_vigilante uuid;
  v_status    text;
  v_sou_cmd   int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  SELECT id INTO v_usuario FROM public.usuarios WHERE auth_user_id = auth.uid();
  SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;

  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Escolta nao encontrada.';
  END IF;

  -- So devolve enquanto nao comecou. Depois de iniciada, sair da escolta e decisao de
  -- supervisor, nao do proprio operador: ja existe registro de ponto no nome dele.
  IF v_status <> 'agendada' THEN
    RAISE EXCEPTION 'A escolta ja comecou. Fale com o supervisor para sair dela.';
  END IF;

  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador','gestor','supervisor','central') THEN
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante
      AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN
      RAISE EXCEPTION 'Apenas o comandante devolve a escolta ao mural.';
    END IF;
  END IF;

  DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;


--
--
-- Name: equipe_escalada(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.equipe_escalada(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text;
  v_status text;
  v_equipe jsonb;
  v_viatura jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN
    RAISE EXCEPTION 'Sessao invalida.';
  END IF;

  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Escolta nao encontrada.';
  END IF;

  -- Fora do mural, vale a regra normal: so quem e do efetivo ou da gestao consulta.
  -- Sem esta guarda, a funcao viraria um caminho para ler o efetivo de qualquer escolta.
  IF v_status <> 'agendada'
     AND v_perfil NOT IN ('administrador','gestor','supervisor','central')
     AND NOT public.sou_do_efetivo(p_escolta_id) THEN
    RAISE EXCEPTION 'Sem permissao para consultar esta escolta.';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'vigilante_id', ee.vigilante_id,
           'nome', v.nome_completo,
           'papel', ee.papel_na_escolta
         ) ORDER BY (ee.papel_na_escolta <> 'comandante'), v.nome_completo), '[]'::jsonb)
    INTO v_equipe
  FROM public.escolta_efetivo ee
  JOIN public.vigilantes v ON v.id = ee.vigilante_id
  WHERE ee.escolta_id = p_escolta_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'escolta_veiculo_id', ev.id,
           'veiculo_id', ev.veiculo_id,
           'placa', ve.placa,
           'modelo', ve.modelo
         ) ORDER BY ev.criado_em), '[]'::jsonb)
    INTO v_viatura
  FROM public.escolta_veiculos ev
  JOIN public.veiculos ve ON ve.id = ev.veiculo_id
  WHERE ev.escolta_id = p_escolta_id;

  -- Sem valor_pago_vigilante e sem valor_cobrado_cliente, de proposito.
  RETURN jsonb_build_object('equipe', v_equipe, 'viaturas', v_viatura);
END;
$$;


--
--
-- Name: FUNCTION equipe_escalada(p_escolta_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.equipe_escalada(p_escolta_id uuid) IS 'Equipe e viatura de uma escolta, sem nenhum campo financeiro. Escolta agendada e consultavel por qualquer usuario ativo, porque e do mural; fora disso vale a regra normal de efetivo ou gestao.';


--
--
-- Name: excluir_auth_usuario(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.excluir_auth_usuario(p_auth_uid uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_perfil TEXT;
  v_caller_auth_id UUID;
BEGIN
  v_caller_auth_id := auth.uid();

  -- Verificar se o chamador tem permissão (apenas administrador)
  SELECT p.codigo INTO v_caller_perfil
  FROM public.usuarios u
  INNER JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.auth_user_id = v_caller_auth_id
    AND u.status = 'ativo';

  IF v_caller_perfil IS NULL OR v_caller_perfil NOT IN ('administrador') THEN
    RAISE EXCEPTION 'Permissão negada. Apenas administradores podem excluir usuários.';
  END IF;

  -- Impedir que o admin exclua a si mesmo
  IF p_auth_uid = v_caller_auth_id THEN
    RAISE EXCEPTION 'Você não pode excluir sua própria conta.';
  END IF;

  -- Excluir do auth.users (cascade limpa auth.identities etc.)
  DELETE FROM auth.users WHERE id = p_auth_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuário não encontrado na autenticação.';
  END IF;

END;
$$;


--
--
-- Name: exigir_ponto_transito_retorno(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.exigir_ponto_transito_retorno() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_tem boolean;
BEGIN
  IF NEW.status = 'na_base' AND OLD.status = 'retornando'
     AND COALESCE(NEW.fluxo_versao, 1) = 2 THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.pontos_controle pc
      JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
      JOIN public.dom_tipos_ponto tp ON tp.id = pc.tipo_ponto_id
      WHERE ev.escolta_id = NEW.id
        AND tp.codigo = 'transito_retorno'
    ) INTO v_tem;

    IF NOT v_tem THEN
      RAISE EXCEPTION 'Nao e possivel concluir o retorno sem registrar o ponto de Transito para o Retorno.'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
--
-- Name: garantir_vinculo_operador(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.garantir_vinculo_operador() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_perfil text;
begin
  select codigo
    into v_perfil
  from dom_perfis
  where id = new.perfil_id;

  if v_perfil is distinct from 'operador' then
    return new;
  end if;

  if exists (
    select 1
    from vigilantes
    where usuario_id = new.id
  ) then
    return new;
  end if;

  update vigilantes v
     set usuario_id = new.id,
         atualizado_em = now()
   where v.id = (
     select vv.id
     from vigilantes vv
     where vv.usuario_id is null
       and regexp_replace(vv.cpf, '[^0-9]', '', 'g') = regexp_replace(new.cpf, '[^0-9]', '', 'g')
     order by vv.criado_em
     limit 1
   )
   and (
     select count(*)
     from vigilantes w
     where w.usuario_id is null
       and regexp_replace(w.cpf, '[^0-9]', '', 'g') = regexp_replace(new.cpf, '[^0-9]', '', 'g')
   ) = 1;

  return new;
end;
$$;


--
--
-- Name: gerar_codigo_escolta(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gerar_codigo_escolta() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_ano TEXT;
  v_seq INTEGER;
BEGIN
  IF NEW.codigo_escolta IS NULL OR NEW.codigo_escolta = '' THEN
    v_ano := TO_CHAR(NOW(), 'YYYY');
    SELECT COALESCE(
      MAX(CAST(SUBSTRING(codigo_escolta FROM 'ESC-' || v_ano || '-(\d+)') AS INTEGER)),
      0
    ) + 1
    INTO v_seq
    FROM escoltas
    WHERE codigo_escolta LIKE 'ESC-' || v_ano || '-%';

    NEW.codigo_escolta := 'ESC-' || v_ano || '-' || LPAD(v_seq::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;


--
--
-- Name: get_meu_perfil(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_meu_perfil() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT dp.codigo
  FROM usuarios u
  JOIN dom_perfis dp ON dp.id = u.perfil_id
  WHERE u.auth_user_id = auth.uid()
    AND u.status = 'ativo'
  LIMIT 1;
$$;


--
--
-- Name: get_meu_usuario_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_meu_usuario_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT id FROM usuarios
  WHERE auth_user_id = auth.uid()
    AND status = 'ativo'
  LIMIT 1;
$$;


--
--
-- Name: get_meu_vigilante_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_meu_vigilante_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT v.id FROM vigilantes v
  JOIN usuarios u ON u.id = v.usuario_id
  WHERE u.auth_user_id = auth.uid()
    AND u.status = 'ativo'
    AND v.status = 'ativo'
  LIMIT 1;
$$;


--
--
-- Name: impedir_autopromocao(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.impedir_autopromocao() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil      text;
  v_eu          uuid;
  v_cod_novo    text;
  v_cod_antigo  text;
BEGIN
  v_eu := auth.uid();

  -- Sem sessao de usuario final: SQL direto, migration ou service role.
  -- Passa de proposito, e o unico caminho de reparo do banco. O controle
  -- desse caminho e a reconciliacao detectiva, nao esta trigger.
  IF v_eu IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT public.get_meu_perfil() INTO v_perfil;

  -- O vinculo com auth.users nunca muda pela API: trocar auth_user_id
  -- e sequestro de conta, nao edicao de cadastro.
  IF NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
    RAISE EXCEPTION 'O vinculo de autenticacao nao pode ser alterado pela aplicacao.';
  END IF;

  -- 1. Ninguem mexe no proprio perfil nem no proprio status, nem administrador.
  --    Confere OLD e NEW para o caso de a linha ser reapontada na mesma instrucao.
  IF OLD.auth_user_id = v_eu OR NEW.auth_user_id = v_eu THEN
    IF NEW.perfil_id IS DISTINCT FROM OLD.perfil_id THEN
      RAISE EXCEPTION 'Voce nao pode alterar o proprio perfil de acesso.';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'Voce nao pode alterar o proprio status.';
    END IF;
    RETURN NEW;
  END IF;

  -- 2. Mexer no perfil de terceiro exige perfil de gestao.
  IF NEW.perfil_id IS DISTINCT FROM OLD.perfil_id THEN
    IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor') THEN
      RAISE EXCEPTION 'Permissao negada para alterar perfil de acesso.';
    END IF;

    SELECT codigo INTO v_cod_novo   FROM public.dom_perfis WHERE id = NEW.perfil_id;
    SELECT codigo INTO v_cod_antigo FROM public.dom_perfis WHERE id = OLD.perfil_id;

    -- 3. Conceder ou retirar 'administrador' e privativo de administrador.
    --    Sem isto, o gestor promove um comparsa em vez de a si mesmo.
    IF v_perfil <> 'administrador'
       AND 'administrador' IN (coalesce(v_cod_novo, ''), coalesce(v_cod_antigo, '')) THEN
      RAISE EXCEPTION 'Somente um administrador concede ou remove o perfil administrador.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
--
-- Name: FUNCTION impedir_autopromocao(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.impedir_autopromocao() IS 'Barra escalada de privilegio por UPDATE direto em usuarios: ninguem altera o proprio perfil ou status, so gestao altera perfil de terceiro, e apenas administrador concede ou remove o perfil administrador. auth_user_id e imutavel pela API. Sessao sem auth.uid() (SQL direto) passa, por ser a via de reparo.';


--
--
-- Name: impedir_criacao_perfil_superior(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.impedir_criacao_perfil_superior() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil_chamador text;
  v_perfil_alvo text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil_chamador;

  -- Sem sessao e criacao por rotina interna (service_role), que ja e privilegiada.
  IF v_perfil_chamador IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT codigo INTO v_perfil_alvo FROM public.dom_perfis WHERE id = NEW.perfil_id;

  IF v_perfil_alvo = 'administrador' AND v_perfil_chamador <> 'administrador' THEN
    RAISE EXCEPTION 'Apenas um administrador pode criar outra conta de administrador.';
  END IF;

  RETURN NEW;
END;
$$;


--
--
-- Name: impedir_edicao_por_operador(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.impedir_edicao_por_operador() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text;
BEGIN
  -- Sem sessao de usuario final: SQL direto, migration ou service role. Passa, como nas
  -- demais funcoes deste banco, por ser a via de reparo.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil = ANY (ARRAY['administrador','gestor','supervisor','central']) THEN
    RETURN NEW;
  END IF;

  -- Daqui para baixo e operador ou vigilante. Ele so pode mover a escolta pelo fluxo:
  -- status, e os carimbos que o proprio avanco preenche.
  IF NEW.cliente_id          IS DISTINCT FROM OLD.cliente_id
     OR NEW.data_hora_prevista IS DISTINCT FROM OLD.data_hora_prevista
     OR NEW.origem_endereco  IS DISTINCT FROM OLD.origem_endereco
     OR NEW.origem_lat       IS DISTINCT FROM OLD.origem_lat
     OR NEW.origem_lng       IS DISTINCT FROM OLD.origem_lng
     OR NEW.destino_endereco IS DISTINCT FROM OLD.destino_endereco
     OR NEW.destino_lat      IS DISTINCT FROM OLD.destino_lat
     OR NEW.destino_lng      IS DISTINCT FROM OLD.destino_lng
  THEN
    RAISE EXCEPTION 'Operador nao edita dados da escolta. Fale com o supervisor para alterar cliente, data ou local.';
  END IF;

  RETURN NEW;
END;
$$;


--
--
-- Name: incluir_vigilante_na_minha_escolta(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.incluir_vigilante_na_minha_escolta(p_escolta_id uuid, p_vigilante_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil    text;
  v_usuario   uuid;
  v_vigilante uuid;
  v_status    text;
  v_sou_cmd   int;
  v_ev        uuid;
  v_dup       int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  SELECT id INTO v_usuario FROM public.usuarios WHERE auth_user_id = auth.uid();
  SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;

  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Escolta nao encontrada.';
  END IF;
  IF v_status <> 'agendada' THEN
    RAISE EXCEPTION 'A escolta ja comecou. Alteracao de equipe passa pelo supervisor.';
  END IF;

  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador','gestor','supervisor','central') THEN
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante
      AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN
      RAISE EXCEPTION 'Apenas o comandante inclui vigilante nesta escolta.';
    END IF;
  END IF;

  SELECT count(*) INTO v_dup FROM public.escolta_efetivo
  WHERE escolta_id = p_escolta_id AND vigilante_id = p_vigilante_id;
  IF v_dup > 0 THEN
    RAISE EXCEPTION 'Este vigilante ja esta na escolta.';
  END IF;

  SELECT id INTO v_ev FROM public.escolta_veiculos
  WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN
    RAISE EXCEPTION 'Escolta sem viatura vinculada.';
  END IF;

  INSERT INTO public.escolta_efetivo
    (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, p_vigilante_id, 'operador', false, v_usuario);

  RETURN jsonb_build_object('ok', true);
END;
$$;


--
--
-- Name: ler_credencial(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ler_credencial(p_usuario_id uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text;
  v_meu_id uuid;
  v_senha  text;
  v_alvo   text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL OR v_perfil <> 'administrador' THEN
    RAISE EXCEPTION 'Apenas administrador pode consultar credencial.';
  END IF;

  SELECT id INTO v_meu_id FROM public.usuarios WHERE auth_user_id = auth.uid();
  SELECT senha INTO v_senha FROM public.usuarios_credenciais WHERE usuario_id = p_usuario_id;
  SELECT nome_completo INTO v_alvo FROM public.usuarios WHERE id = p_usuario_id;

  -- A auditoria e o que faz "somente o administrador le" ser conferivel depois. Se ela
  -- falhar, a leitura tambem falha, de proposito: consulta de senha sem rastro nao vale.
  INSERT INTO public.logs_auditoria
    (usuario_id, acao, entidade_afetada, registro_id, dados_depois, data_hora)
  VALUES (
    v_meu_id, 'consulta_credencial', 'usuarios', p_usuario_id,
    jsonb_build_object('alvo', v_alvo, 'encontrada', v_senha IS NOT NULL),
    now()
  );

  RETURN v_senha;
END;
$$;


--
--
-- Name: perfil_usuario_atual(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.perfil_usuario_atual() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT p.codigo
  FROM public.usuarios u
  JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.auth_user_id = auth.uid()
  LIMIT 1
$$;


--
--
-- Name: puxar_escolta(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.puxar_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil    text;
  v_usuario   uuid;
  v_vigilante uuid;
  v_status    text;
  v_ev        uuid;
  v_ja        int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN
    RAISE EXCEPTION 'Sessao invalida.';
  END IF;

  SELECT id INTO v_usuario FROM public.usuarios WHERE auth_user_id = auth.uid();
  SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante. Fale com o administrador.';
  END IF;

  -- Trava a linha: sem isto, dois operadores puxam a mesma escolta no mesmo instante e
  -- os dois viram comandante.
  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Escolta nao encontrada.';
  END IF;
  IF v_status <> 'agendada' THEN
    RAISE EXCEPTION 'Esta escolta nao esta mais disponivel: ela ja saiu do mural.';
  END IF;

  SELECT count(*) INTO v_ja FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  IF v_ja > 0 THEN
    RAISE EXCEPTION 'Esta escolta ja tem equipe designada.';
  END IF;

  SELECT id INTO v_ev FROM public.escolta_veiculos
  WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN
    RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.';
  END IF;

  INSERT INTO public.escolta_efetivo
    (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);

  RETURN jsonb_build_object('ok', true, 'escolta_veiculo_id', v_ev);
END;
$$;


--
--
-- Name: redefinir_senha_usuario(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.redefinir_senha_usuario(p_usuario_id uuid, p_nova_senha text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions', 'pg_temp'
    AS $$
DECLARE
  v_caller_perfil TEXT;
  v_alvo_perfil   TEXT;
BEGIN
  -- Perfil de quem chama
  SELECT p.codigo INTO v_caller_perfil
  FROM public.usuarios u
  INNER JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.auth_user_id = auth.uid()
    AND u.status = 'ativo';

  IF v_caller_perfil IS NULL OR v_caller_perfil NOT IN ('administrador', 'gestor') THEN
    RAISE EXCEPTION 'Permissão negada. Apenas administradores e gestores podem redefinir senhas.';
  END IF;

  -- Perfil do alvo. p_usuario_id e o auth_user_id do alvo.
  SELECT p.codigo INTO v_alvo_perfil
  FROM public.usuarios u
  INNER JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.auth_user_id = p_usuario_id;

  IF v_alvo_perfil IS NULL THEN
    RAISE EXCEPTION 'Usuário alvo não encontrado.';
  END IF;

  -- Somente administrador redefine a senha de um administrador.
  IF v_alvo_perfil = 'administrador' AND v_caller_perfil <> 'administrador' THEN
    RAISE EXCEPTION 'Permissão negada. Apenas um administrador pode redefinir a senha de outro administrador.';
  END IF;

  IF length(p_nova_senha) < 6 THEN
    RAISE EXCEPTION 'A senha deve ter pelo menos 6 caracteres.';
  END IF;

  UPDATE auth.users
  SET encrypted_password = crypt(p_nova_senha, gen_salt('bf')),
      updated_at = now()
  WHERE id = p_usuario_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuário não encontrado na autenticação.';
  END IF;

  UPDATE public.usuarios
  SET troca_senha_obrigatoria = true,
      atualizado_em = now()
  WHERE auth_user_id = p_usuario_id;
END;
$$;


--
--
-- Name: registrar_credencial(uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registrar_credencial(p_usuario_id uuid, p_senha text, p_provisoria boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_eu     uuid := auth.uid();
  v_perfil text;
  v_meu_id uuid;
BEGIN
  IF p_senha IS NULL OR length(p_senha) < 6 THEN
    RAISE EXCEPTION 'Senha invalida.';
  END IF;

  SELECT public.get_meu_perfil() INTO v_perfil;
  SELECT id INTO v_meu_id FROM public.usuarios WHERE auth_user_id = v_eu;

  -- Cada um registra a propria; administrador e gestor registram a de terceiro, que e o
  -- caso da criacao de conta e da redefinicao. Sem sessao (migration, service role) passa,
  -- pelo mesmo motivo das demais funcoes deste banco: e a via de reparo.
  IF v_eu IS NOT NULL
     AND p_usuario_id IS DISTINCT FROM v_meu_id
     AND (v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor')) THEN
    RAISE EXCEPTION 'Permissao negada para registrar credencial de outro usuario.';
  END IF;

  INSERT INTO public.usuarios_credenciais (usuario_id, senha, definida_por, provisoria)
  VALUES (p_usuario_id, p_senha, v_meu_id, p_provisoria)
  ON CONFLICT (usuario_id) DO UPDATE
    SET senha = excluded.senha,
        definida_em = now(),
        definida_por = excluded.definida_por,
        provisoria = excluded.provisoria;
END;
$$;


--
--
-- Name: registrar_historico_status_escolta(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registrar_historico_status_escolta() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO escolta_status_historico (
      escolta_id, status_anterior, status_novo, alterado_por, data_hora
    ) VALUES (
      NEW.id, OLD.status, NEW.status, NEW.atualizado_por, NOW()
    );
  END IF;
  RETURN NEW;
END;
$$;


--
--
-- Name: FUNCTION registrar_historico_status_escolta(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.registrar_historico_status_escolta() IS 'OBSOLETA. A trigger foi removida porque duplicava o registro que o app ja faz com autor, observacao e GPS. Mantida apenas como referencia. Escrita direta em escoltas fora do app fica sem historico: e detectada pela reconciliacao descrita em docs/07 - Runbook.md.';


--
--
-- Name: sou_do_efetivo(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sou_do_efetivo(p_escolta_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.escolta_efetivo ee
    JOIN public.vigilantes v ON v.id = ee.vigilante_id
    JOIN public.usuarios u   ON u.id = v.usuario_id
    WHERE ee.escolta_id = p_escolta_id
      AND u.auth_user_id = auth.uid()
  );
$$;


--
--
-- Name: sou_do_efetivo_veiculo(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sou_do_efetivo_veiculo(p_escolta_veiculo_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.escolta_veiculos ev
    WHERE ev.id = p_escolta_veiculo_id
      AND public.sou_do_efetivo(ev.escolta_id)
  );
$$;


--
--
-- Name: sync_auth_user_on_usuarios(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_auth_user_on_usuarios() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  -- Atualiza o ultimo_acesso quando auth user faz login (chamado via webhook ou app)
  RETURN NEW;
END;
$$;


--
--
-- Name: update_atualizado_em(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_atualizado_em() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  NEW.atualizado_em = NOW();
  RETURN NEW;
END;
$$;


--
--
-- Name: validar_transicao_status_escolta(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validar_transicao_status_escolta() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_ok boolean := false;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'cancelada' AND OLD.status NOT IN ('finalizada','cancelada') THEN
    RETURN NEW;
  END IF;

  v_ok := (
    (OLD.status = 'rascunho'            AND NEW.status = 'agendada') OR
    (OLD.status = 'agendada'            AND NEW.status = 'em_pre_inicio') OR
    (OLD.status = 'em_pre_inicio'       AND NEW.status = 'em_andamento') OR
    (OLD.status = 'em_andamento'        AND NEW.status = 'na_origem') OR
    (OLD.status = 'na_origem'           AND NEW.status = 'em_transito_destino') OR
    (OLD.status = 'em_transito_destino' AND NEW.status = 'no_destino') OR
    (OLD.status = 'no_destino'          AND NEW.status = 'em_transito_retorno') OR
    (OLD.status = 'em_transito_retorno' AND NEW.status = 'retornando') OR
    (OLD.status = 'retornando'          AND NEW.status = 'na_base') OR
    (OLD.status = 'na_base'             AND NEW.status = 'finalizada')
  );

  IF NOT v_ok AND COALESCE(NEW.fluxo_versao, 1) = 1 THEN
    v_ok := (
      (OLD.status = 'na_origem'  AND NEW.status = 'no_destino') OR
      (OLD.status = 'no_destino' AND NEW.status = 'retornando')
    );
  END IF;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'Transicao de status invalida: % para %', OLD.status, NEW.status
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;


--
--
-- Name: verificar_checklist_pendente(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verificar_checklist_pendente() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_total_veiculos INTEGER;
  v_veiculos_ok INTEGER;
BEGIN
  IF OLD.status = 'em_pre_inicio' AND NEW.status = 'em_andamento' THEN
    SELECT COUNT(*) INTO v_total_veiculos
    FROM escolta_veiculos WHERE escolta_id = NEW.id;

    SELECT COUNT(DISTINCT ev.id) INTO v_veiculos_ok
    FROM escolta_veiculos ev
    WHERE ev.escolta_id = NEW.id
      AND EXISTS (
        SELECT 1 FROM checklists c
        WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'viatura' AND c.concluido = true
      )
      AND EXISTS (
        SELECT 1 FROM checklists c
        WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'material' AND c.concluido = true
      );

    IF v_veiculos_ok < v_total_veiculos THEN
      NEW.checklist_pendente_no_inicio := true;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
--
-- Name: vigilantes_para_escala(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.vigilantes_para_escala() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text;
  v_lista  jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN
    RAISE EXCEPTION 'Sessao invalida.';
  END IF;

  -- Somente id, nome e funcao. Sem CPF, sem telefone, sem valor pago.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id,
           'nome', v.nome_completo,
           'funcao', f.nome
         ) ORDER BY v.nome_completo), '[]'::jsonb)
    INTO v_lista
  FROM public.vigilantes v
  LEFT JOIN public.dom_funcoes f ON f.id = v.funcao_id
  WHERE v.status = 'ativo';

  RETURN v_lista;
END;
$$;


--
--
-- Name: FUNCTION vigilantes_para_escala(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.vigilantes_para_escala() IS 'Lista de vigilantes ativos com id, nome e funcao, para montar equipe. Sem CPF, telefone ou valor pago: esses campos continuam restritos pela politica da tabela.';


--
--
-- Name: vincular_vigilante_a_usuario(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.vincular_vigilante_a_usuario() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_uid uuid;
begin
  if new.usuario_id is not null then
    return new;
  end if;

  select u.id
    into v_uid
  from usuarios u
  join dom_perfis dp on dp.id = u.perfil_id
  where dp.codigo = 'operador'
    and regexp_replace(u.cpf, '[^0-9]', '', 'g') = regexp_replace(new.cpf, '[^0-9]', '', 'g')
    and not exists (
      select 1
      from vigilantes v
      where v.usuario_id = u.id
    )
  limit 1;

  new.usuario_id := v_uid;

  return new;
end;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
--
-- Name: vw_historico_divergente; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_historico_divergente WITH (security_invoker='on') AS
 SELECT e.id,
    e.codigo_escolta,
    e.status AS status_atual,
    h.status_novo AS ultimo_status_no_historico,
    h.data_hora AS ultimo_registro,
    e.atualizado_em
   FROM (public.escoltas e
     LEFT JOIN LATERAL ( SELECT escolta_status_historico.status_novo,
            escolta_status_historico.data_hora
           FROM public.escolta_status_historico
          WHERE (escolta_status_historico.escolta_id = e.id)
          ORDER BY escolta_status_historico.data_hora DESC
         LIMIT 1) h ON (true))
  WHERE (((e.status <> ALL (ARRAY['rascunho'::text, 'agendada'::text])) AND (h.status_novo IS NULL)) OR ((h.status_novo IS NOT NULL) AND (h.status_novo <> e.status)));


--
--
-- Name: VIEW vw_historico_divergente; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.vw_historico_divergente IS 'Auditoria: escoltas cujo status diverge da ultima linha de escolta_status_historico. security_invoker ligado e sem grant para authenticated: consulta apenas por service_role ou conexao direta. Deve voltar vazia; linhas indicam status alterado fora do aplicativo.';


--
--
-- Name: vw_operador_sem_vinculo; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.vw_operador_sem_vinculo WITH (security_invoker='on') AS
 SELECT u.id AS usuario_id,
    u.nome_completo,
    u.cpf,
    u.email
   FROM (public.usuarios u
     JOIN public.dom_perfis dp ON ((dp.id = u.perfil_id)))
  WHERE ((dp.codigo = 'operador'::text) AND (NOT (EXISTS ( SELECT 1
           FROM public.vigilantes v
          WHERE (v.usuario_id = u.id)))));


--
--
-- Name: armamentos tr_armamentos_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_armamentos_atualizado_em BEFORE UPDATE ON public.armamentos FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: checklist_modelos tr_checklist_modelos_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_checklist_modelos_atualizado_em BEFORE UPDATE ON public.checklist_modelos FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: checklist_respostas tr_checklist_respostas_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_checklist_respostas_atualizado_em BEFORE UPDATE ON public.checklist_respostas FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: checklists tr_checklists_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_checklists_atualizado_em BEFORE UPDATE ON public.checklists FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: clientes tr_clientes_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_clientes_atualizado_em BEFORE UPDATE ON public.clientes FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: emergencias tr_emergencias_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_emergencias_atualizado_em BEFORE UPDATE ON public.emergencias FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: escolta_armamentos tr_escolta_armamentos_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_escolta_armamentos_atualizado_em BEFORE UPDATE ON public.escolta_armamentos FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: escolta_efetivo tr_escolta_efetivo_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_escolta_efetivo_atualizado_em BEFORE UPDATE ON public.escolta_efetivo FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: escolta_veiculos tr_escolta_veiculos_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_escolta_veiculos_atualizado_em BEFORE UPDATE ON public.escolta_veiculos FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: escoltas tr_escoltas_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_escoltas_atualizado_em BEFORE UPDATE ON public.escoltas FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: escoltas tr_exigir_transito_retorno; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_exigir_transito_retorno BEFORE UPDATE OF status ON public.escoltas FOR EACH ROW EXECUTE FUNCTION public.exigir_ponto_transito_retorno();


--
--
-- Name: fotos tr_fotos_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_fotos_atualizado_em BEFORE UPDATE ON public.fotos FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: escoltas tr_gerar_codigo_escolta; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_gerar_codigo_escolta BEFORE INSERT ON public.escoltas FOR EACH ROW EXECUTE FUNCTION public.gerar_codigo_escolta();


--
--
-- Name: usuarios tr_impedir_autopromocao; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_impedir_autopromocao BEFORE UPDATE ON public.usuarios FOR EACH ROW EXECUTE FUNCTION public.impedir_autopromocao();


--
--
-- Name: usuarios tr_impedir_criacao_perfil_superior; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_impedir_criacao_perfil_superior BEFORE INSERT ON public.usuarios FOR EACH ROW EXECUTE FUNCTION public.impedir_criacao_perfil_superior();


--
--
-- Name: escoltas tr_impedir_edicao_por_operador; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_impedir_edicao_por_operador BEFORE UPDATE ON public.escoltas FOR EACH ROW EXECUTE FUNCTION public.impedir_edicao_por_operador();


--
--
-- Name: ocorrencias tr_ocorrencias_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_ocorrencias_atualizado_em BEFORE UPDATE ON public.ocorrencias FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: pontos_controle tr_pontos_controle_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_pontos_controle_atualizado_em BEFORE UPDATE ON public.pontos_controle FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: presencas tr_presencas_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_presencas_atualizado_em BEFORE UPDATE ON public.presencas FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: usuarios tr_usuarios_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_usuarios_atualizado_em BEFORE UPDATE ON public.usuarios FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: escoltas tr_validar_transicao_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_validar_transicao_status BEFORE UPDATE OF status ON public.escoltas FOR EACH ROW EXECUTE FUNCTION public.validar_transicao_status_escolta();


--
--
-- Name: veiculos tr_veiculos_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_veiculos_atualizado_em BEFORE UPDATE ON public.veiculos FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: escoltas tr_verificar_checklist_pendente; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_verificar_checklist_pendente BEFORE UPDATE OF status ON public.escoltas FOR EACH ROW EXECUTE FUNCTION public.verificar_checklist_pendente();


--
--
-- Name: vigilantes tr_vigilantes_atualizado_em; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tr_vigilantes_atualizado_em BEFORE UPDATE ON public.vigilantes FOR EACH ROW EXECUTE FUNCTION public.update_atualizado_em();


--
--
-- Name: usuarios trg_garantir_vinculo_operador; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_garantir_vinculo_operador AFTER INSERT OR UPDATE OF perfil_id ON public.usuarios FOR EACH ROW EXECUTE FUNCTION public.garantir_vinculo_operador();


--
--
-- Name: vigilantes trg_vincular_vigilante_a_usuario; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_vincular_vigilante_a_usuario BEFORE INSERT OR UPDATE OF cpf, usuario_id ON public.vigilantes FOR EACH ROW EXECUTE FUNCTION public.vincular_vigilante_a_usuario();


--
--
-- Name: armamentos armamentos_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY armamentos_escrita ON public.armamentos TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: armamentos armamentos_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY armamentos_leitura ON public.armamentos FOR SELECT TO authenticated USING (true);


--
--
-- Name: atualizacoes_status atualizacoes_status_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY atualizacoes_status_all ON public.atualizacoes_status TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id))) WITH CHECK (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: chat_mensagens chat_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_insert ON public.chat_mensagens FOR INSERT TO authenticated WITH CHECK ((de_usuario_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)));


--
--
-- Name: chat_mensagens chat_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_select ON public.chat_mensagens FOR SELECT TO authenticated USING (((de_usuario_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)) OR (para_usuario_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id))));


--
--
-- Name: chat_mensagens chat_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_update ON public.chat_mensagens FOR UPDATE TO authenticated USING ((para_usuario_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)));


--
--
-- Name: checklist_modelo_itens checklist_modelo_itens_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY checklist_modelo_itens_escrita ON public.checklist_modelo_itens TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: checklist_modelo_itens checklist_modelo_itens_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY checklist_modelo_itens_leitura ON public.checklist_modelo_itens FOR SELECT TO authenticated USING (true);


--
--
-- Name: checklist_modelos checklist_modelos_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY checklist_modelos_escrita ON public.checklist_modelos TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: checklist_modelos checklist_modelos_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY checklist_modelos_leitura ON public.checklist_modelos FOR SELECT TO authenticated USING (true);


--
--
-- Name: checklist_respostas checklist_respostas_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY checklist_respostas_all ON public.checklist_respostas TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.checklists c
  WHERE (c.id = checklist_respostas.checklist_id)))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.checklists c
  WHERE (c.id = checklist_respostas.checklist_id))));


--
--
-- Name: checklists checklists_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY checklists_escrita ON public.checklists TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo_veiculo(escolta_veiculo_id))) WITH CHECK (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo_veiculo(escolta_veiculo_id)));


--
--
-- Name: checklists checklists_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY checklists_select ON public.checklists FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo_veiculo(escolta_veiculo_id)));


--
--
-- Name: clientes clientes_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY clientes_escrita ON public.clientes TO authenticated USING ((public.get_meu_perfil() = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: clientes clientes_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY clientes_leitura ON public.clientes FOR SELECT TO authenticated USING ((public.get_meu_perfil() = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])));


--
--
-- Name: clientes clientes_operador_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY clientes_operador_select ON public.clientes FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.escoltas e
  WHERE ((e.cliente_id = clientes.id) AND public.sou_do_efetivo(e.id)))));


--
--
-- Name: usuarios_credenciais credenciais_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY credenciais_select ON public.usuarios_credenciais FOR SELECT TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = 'administrador'::text));


--
--
-- Name: dom_calibres dom_calibres_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_calibres_escrita ON public.dom_calibres TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: dom_calibres dom_calibres_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_calibres_leitura ON public.dom_calibres FOR SELECT TO authenticated USING (true);


--
--
-- Name: dom_funcoes dom_funcoes_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_funcoes_escrita ON public.dom_funcoes TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: dom_funcoes dom_funcoes_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_funcoes_leitura ON public.dom_funcoes FOR SELECT TO authenticated USING (true);


--
--
-- Name: dom_perfis dom_perfis_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_perfis_escrita ON public.dom_perfis TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: dom_perfis dom_perfis_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_perfis_leitura ON public.dom_perfis FOR SELECT TO authenticated USING (true);


--
--
-- Name: dom_tipos_armamento dom_tipos_armamento_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_armamento_escrita ON public.dom_tipos_armamento TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: dom_tipos_armamento dom_tipos_armamento_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_armamento_leitura ON public.dom_tipos_armamento FOR SELECT TO authenticated USING (true);


--
--
-- Name: dom_tipos_evento dom_tipos_evento_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_evento_escrita ON public.dom_tipos_evento TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: dom_tipos_evento dom_tipos_evento_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_evento_leitura ON public.dom_tipos_evento FOR SELECT TO authenticated USING (true);


--
--
-- Name: dom_tipos_foto dom_tipos_foto_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_foto_escrita ON public.dom_tipos_foto TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: dom_tipos_foto dom_tipos_foto_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_foto_leitura ON public.dom_tipos_foto FOR SELECT TO authenticated USING (true);


--
--
-- Name: dom_tipos_ocorrencia dom_tipos_ocorrencia_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_ocorrencia_escrita ON public.dom_tipos_ocorrencia TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: dom_tipos_ocorrencia dom_tipos_ocorrencia_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_ocorrencia_leitura ON public.dom_tipos_ocorrencia FOR SELECT TO authenticated USING (true);


--
--
-- Name: dom_tipos_ponto dom_tipos_ponto_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_ponto_escrita ON public.dom_tipos_ponto TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: dom_tipos_ponto dom_tipos_ponto_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_ponto_leitura ON public.dom_tipos_ponto FOR SELECT TO authenticated USING (true);


--
--
-- Name: dom_tipos_veiculo dom_tipos_veiculo_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_veiculo_escrita ON public.dom_tipos_veiculo TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: dom_tipos_veiculo dom_tipos_veiculo_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dom_tipos_veiculo_leitura ON public.dom_tipos_veiculo FOR SELECT TO authenticated USING (true);


--
--
-- Name: emergencias emergencias_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY emergencias_all ON public.emergencias TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id))) WITH CHECK (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: escolta_armamentos escolta_armamentos_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escolta_armamentos_escrita ON public.escolta_armamentos TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: escolta_armamentos escolta_armamentos_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escolta_armamentos_select ON public.escolta_armamentos FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo_veiculo(escolta_veiculo_id)));


--
--
-- Name: escolta_efetivo escolta_efetivo_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escolta_efetivo_escrita ON public.escolta_efetivo TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: escolta_efetivo escolta_efetivo_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escolta_efetivo_select ON public.escolta_efetivo FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: escolta_veiculos escolta_veiculos_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escolta_veiculos_escrita ON public.escolta_veiculos TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id))) WITH CHECK (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: escolta_veiculos escolta_veiculos_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escolta_veiculos_select ON public.escolta_veiculos FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: escoltas escoltas_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escoltas_delete ON public.escoltas FOR DELETE TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: escoltas escoltas_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escoltas_insert ON public.escoltas FOR INSERT TO authenticated WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: escoltas escoltas_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escoltas_select ON public.escoltas FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(id) OR (status = 'agendada'::text)));


--
--
-- Name: POLICY escoltas_select ON escoltas; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON POLICY escoltas_select ON public.escoltas IS 'Gestao ve tudo; membro do efetivo ve a sua; e qualquer autenticado ve as agendadas, porque elas formam o mural de onde o operador puxa escolta. A ocultacao do financeiro no mural e feita na tela, nao aqui: RLS do PostgREST nao filtra coluna.';


--
--
-- Name: escoltas escoltas_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escoltas_update ON public.escoltas FOR UPDATE TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(id)));


--
--
-- Name: fotos fotos_atualizacao; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fotos_atualizacao ON public.fotos FOR UPDATE TO authenticated USING (((criado_por = public.get_meu_usuario_id()) OR (public.get_meu_perfil() = ANY (ARRAY['administrador'::text, 'gestor'::text]))));


--
--
-- Name: fotos fotos_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fotos_insert ON public.fotos FOR INSERT TO authenticated WITH CHECK ((criado_por = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)));


--
--
-- Name: fotos fotos_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fotos_select ON public.fotos FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR (criado_por = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)) OR (EXISTS ( SELECT 1
   FROM public.pontos_controle pc
  WHERE ((pc.foto_id = fotos.id) AND public.sou_do_efetivo_veiculo(pc.escolta_veiculo_id)))) OR (EXISTS ( SELECT 1
   FROM (public.checklist_respostas cr
     JOIN public.checklists c ON ((c.id = cr.checklist_id)))
  WHERE ((cr.foto_id = fotos.id) AND public.sou_do_efetivo_veiculo(c.escolta_veiculo_id)))) OR (EXISTS ( SELECT 1
   FROM public.presencas pr
  WHERE ((pr.foto_id = fotos.id) AND public.sou_do_efetivo(pr.escolta_id)))) OR (EXISTS ( SELECT 1
   FROM public.ocorrencias oc
  WHERE ((oc.foto_id = fotos.id) AND public.sou_do_efetivo(oc.escolta_id))))));


--
--
-- Name: POLICY fotos_select ON fotos; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON POLICY fotos_select ON public.fotos IS 'Gestao ve tudo. Operador ve o que criou e o que pertence a escolta em que esta no efetivo, por qualquer um dos quatro caminhos: ponto de controle, checklist, presenca e ocorrencia.';


--
--
-- Name: escolta_status_historico historico_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY historico_insert ON public.escolta_status_historico FOR INSERT TO authenticated WITH CHECK (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: escolta_status_historico historico_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY historico_select ON public.escolta_status_historico FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: logs_auditoria logs_auditoria_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY logs_auditoria_insert ON public.logs_auditoria FOR INSERT TO authenticated WITH CHECK (true);


--
--
-- Name: logs_auditoria logs_auditoria_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY logs_auditoria_select ON public.logs_auditoria FOR SELECT TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: notificacoes notificacoes_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notificacoes_escrita ON public.notificacoes TO authenticated USING (((usuario_dest_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)) OR (( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])))) WITH CHECK (true);


--
--
-- Name: notificacoes notificacoes_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notificacoes_select ON public.notificacoes FOR SELECT TO authenticated USING (((usuario_dest_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)) OR (( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text]))));


--
--
-- Name: ocorrencias ocorrencias_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ocorrencias_insert ON public.ocorrencias FOR INSERT TO authenticated WITH CHECK (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: ocorrencias ocorrencias_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ocorrencias_select ON public.ocorrencias FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: ocorrencias ocorrencias_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ocorrencias_update ON public.ocorrencias FOR UPDATE TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: pontos_controle pontos_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pontos_insert ON public.pontos_controle FOR INSERT TO authenticated WITH CHECK (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo_veiculo(escolta_veiculo_id)));


--
--
-- Name: pontos_controle pontos_insert_mesma_escolta; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pontos_insert_mesma_escolta ON public.pontos_controle FOR INSERT TO authenticated WITH CHECK (((lancado_por = ( SELECT u.id
   FROM public.usuarios u
  WHERE (u.auth_user_id = auth.uid())
 LIMIT 1)) AND public.sou_do_efetivo(( SELECT ev.escolta_id
   FROM public.escolta_veiculos ev
  WHERE (ev.id = pontos_controle.escolta_veiculo_id)))));


--
--
-- Name: pontos_controle pontos_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pontos_select ON public.pontos_controle FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo_veiculo(escolta_veiculo_id)));


--
--
-- Name: pontos_controle pontos_select_mesma_escolta; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pontos_select_mesma_escolta ON public.pontos_controle FOR SELECT TO authenticated USING (public.sou_do_efetivo(( SELECT ev.escolta_id
   FROM public.escolta_veiculos ev
  WHERE (ev.id = pontos_controle.escolta_veiculo_id))));


--
--
-- Name: pontos_controle pontos_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pontos_update ON public.pontos_controle FOR UPDATE TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: presencas presencas_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY presencas_all ON public.presencas TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id))) WITH CHECK (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo(escolta_id)));


--
--
-- Name: rastreamento rastreamento_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rastreamento_all ON public.rastreamento TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo_veiculo(escolta_veiculo_id))) WITH CHECK (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR public.sou_do_efetivo_veiculo(escolta_veiculo_id)));


--
--
-- Name: usuarios usuarios_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY usuarios_delete ON public.usuarios FOR DELETE TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = 'administrador'::text));


--
--
-- Name: usuarios usuarios_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY usuarios_insert ON public.usuarios FOR INSERT TO authenticated WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text])));


--
--
-- Name: usuarios usuarios_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY usuarios_select ON public.usuarios FOR SELECT TO authenticated USING (true);


--
--
-- Name: POLICY usuarios_select ON usuarios; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON POLICY usuarios_select ON public.usuarios IS 'Leitura ampla entre autenticados. Necessaria para os embeds de autoria da timeline e para a lista de contatos do chat. Expoe CPF e telefone entre funcionarios: trade-off registrado em docs/05 - Decisoes Tecnicas.md. A escrita continua restrita e a autopromocao continua bloqueada por trigger.';


--
--
-- Name: usuarios usuarios_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY usuarios_update ON public.usuarios FOR UPDATE TO authenticated USING (((auth_user_id = auth.uid()) OR (( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text]))));


--
--
-- Name: veiculos veiculos_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY veiculos_escrita ON public.veiculos TO authenticated USING ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text]))) WITH CHECK ((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: veiculos veiculos_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY veiculos_leitura ON public.veiculos FOR SELECT TO authenticated USING (true);


--
--
-- Name: vigilantes vigilantes_escrita; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vigilantes_escrita ON public.vigilantes TO authenticated USING ((public.get_meu_perfil() = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text])));


--
--
-- Name: vigilantes vigilantes_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vigilantes_select ON public.vigilantes FOR SELECT TO authenticated USING (((( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])) OR (usuario_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)) OR (EXISTS ( SELECT 1
   FROM public.escolta_efetivo ee
  WHERE ((ee.vigilante_id = vigilantes.id) AND public.sou_do_efetivo(ee.escolta_id))))));


--
