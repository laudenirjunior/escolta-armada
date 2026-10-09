-- PACOTE_2026-10-08.sql
-- Lote 2026-10 do Escolta Armada: pacote de publicação no banco de produção
-- (projeto qthoyxujyzskydulvcfy). Gerado a partir das migrations 196 a 218 (as do lote que existem, 215 incluída) testadas na
-- homologação da VPS (banco recriado do zero com o esquema de produção de 08/10/2026).
--
-- NÃO APLICAR SEM O "publicar" DO PEÇANHA. Não há caminho de DDL para produção na VPS:
-- quem aplica é o Peçanha, no SQL Editor do Supabase (ou por psql no próprio terminal).
--
-- ORDEM
--   0. Backup novo (database/ferramentas/backup.mjs) conferido, e a CONSULTA PRÉVIA abaixo,
--      com o resultado colado na conversa.
--   1. BLOCO 1, antes do deploy (tudo compatível com o código que está no ar).
--      Depois: segredos telegram_bot_token e telegram_chat_central pela tela Vault do
--      painel do Supabase (nunca pelo SQL Editor). Responder "aplicado 1".
--   2. Push das ondas para a master, uma a uma, com o teste de produção depois de cada uma.
--   3. BLOCO 2, logo depois do deploy das ondas A, C, G, J e I. Responder "aplicado 2".
--   Cada bloco roda inteiro numa transação: se qualquer comando falhar, nada do bloco fica.
--   Se o SQL Editor recusar BEGIN/COMMIT, rode migration por migration, na ordem.
--
-- REVERSÃO: no fim deste arquivo, na ordem inversa. Antes de reverter uma migration, o
-- código da onda correspondente já deve ter sido revertido (git revert) e publicado.

-- ════════════════════════════════════════════════════════════════════════════
-- CONSULTA PRÉVIA (somente leitura). Colar o resultado na conversa antes do bloco 1.
-- ════════════════════════════════════════════════════════════════════════════
SELECT 'storage policy' AS item, policyname || ' [' || cmd || '] ' || array_to_string(roles, ',') || ' USING ' || coalesce(qual, '-') || ' CHECK ' || coalesce(with_check, '-') AS valor
  FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
UNION ALL SELECT 'bucket fotos publico', public::text FROM storage.buckets WHERE id = 'fotos'
UNION ALL SELECT 'extensao instalada', extname FROM pg_extension WHERE extname IN ('pg_cron', 'pg_net', 'supabase_vault')
UNION ALL SELECT 'extensao disponivel', name || ' ' || default_version FROM pg_available_extensions WHERE name IN ('pg_cron', 'pg_net')
UNION ALL SELECT 'contas Douglas e Bruno', count(*)::text FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE (u.id = '9b0c6047-d9eb-42a5-b980-d87ef7b5f611' AND p.codigo = 'administrador') OR (u.id = '130db52b-c966-44d9-aa35-622e24eb953c' AND p.codigo = 'gestor')
UNION ALL SELECT 'escoltas abertas com periodicidade', count(*)::text FROM public.escoltas WHERE status NOT IN ('finalizada', 'cancelada') AND periodicidade_checkin_min IS NOT NULL
UNION ALL SELECT 'efetivo de escolta aberta com usuario nao ativo (perde acesso na 196)', count(*)::text
  FROM public.escolta_efetivo ee JOIN public.escoltas e ON e.id = ee.escolta_id JOIN public.vigilantes v ON v.id = ee.vigilante_id JOIN public.usuarios u ON u.id = v.usuario_id
  WHERE e.status NOT IN ('finalizada', 'cancelada') AND u.status <> 'ativo'
UNION ALL SELECT 'migrations registradas (ultima)', coalesce(max(version), '-') FROM supabase_migrations.schema_migrations
UNION ALL SELECT 'vigilante repetido na mesma escolta (a 210, no bloco 2, aborta se > 0)', count(*)::text
  FROM (SELECT 1 FROM public.escolta_efetivo GROUP BY escolta_id, vigilante_id HAVING count(*) > 1) d
UNION ALL SELECT 'veículo repetido na mesma escolta (a 210, no bloco 2, aborta se > 0)', count(*)::text
  FROM (SELECT 1 FROM public.escolta_veiculos GROUP BY escolta_id, veiculo_id HAVING count(*) > 1) d
ORDER BY 1, 2;
-- Regra de decisão: policy de storage FOR ALL que mencione o bucket fotos ou que não
-- filtre bucket, ou nenhuma policy de INSERT para o bucket: a 200 aborta sozinha no
-- bloco 2 e o fechamento do bucket vira pendência (as fotos continuam por URL assinada).

-- ════════════════════════════════════════════════════════════════════════════
-- BLOCO 1 (antes do deploy)
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ──────── 196_identidade_e_higiene.sql ────────
-- 196_identidade_e_higiene.sql
-- Lote 2026-10, onda A (segurança). Idempotente. Aplicar ANTES do deploy da onda A.
--
-- Por quê:
-- 1. Bloquear usuário não cortava o acesso (docs/13, H1). get_meu_perfil já exigia
--    status = 'ativo', mas perfil_usuario_atual (usada por cadastrar_operador e
--    criar_usuario_por_login) e sou_do_efetivo (usada por quase toda a RLS de campo)
--    não. Um operador bloqueado continuava lendo e gravando nas escoltas dele, e um
--    gestor bloqueado continuava criando contas.
-- 2. Quatro funções SECURITY DEFINER sem pg_temp no search_path (B2), contra a regra
--    de database/migrations/README.md.
-- 3. Funções de trigger com EXECUTE para PUBLIC e uma com GRANT a anon (B1). Trigger
--    dispara sem depender de EXECUTE de quem faz o UPDATE; o grant só abre superfície.
-- 4. vw_operador_sem_vinculo legível por anon e authenticated (B3); a outra view de
--    conferência (vw_historico_divergente) já é só service_role.

CREATE OR REPLACE FUNCTION public.perfil_usuario_atual() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT p.codigo
  FROM public.usuarios u
  JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.auth_user_id = auth.uid()
    AND u.status = 'ativo'
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.sou_do_efetivo(p_escolta_id uuid) RETURNS boolean
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
      AND u.status = 'ativo'
  );
$$;
-- sou_do_efetivo_veiculo delega a sou_do_efetivo e herda a regra sem alteração.

ALTER FUNCTION public.cadastrar_operador(text, text, text, text, text, uuid, text, text, numeric, text)
  SET search_path TO 'public', 'auth', 'extensions', 'pg_temp';
ALTER FUNCTION public.criar_usuario_completo(text, text, text, uuid, text, text)
  SET search_path TO 'public', 'auth', 'extensions', 'pg_temp';
ALTER FUNCTION public.excluir_auth_usuario(uuid)
  SET search_path TO 'public', 'pg_temp';

-- Funções de trigger: ninguém precisa chamá-las diretamente.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS f
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prorettype = 'trigger'::regtype
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.f);
  END LOOP;
END $$;

REVOKE ALL ON public.vw_operador_sem_vinculo FROM anon, authenticated;

-- Conferência (esperado: 0 linhas em cada):
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE nspname='public' AND prosecdef AND has_function_privilege('anon', p.oid, 'EXECUTE');
-- SELECT proname FROM pg_proc WHERE proname IN ('perfil_usuario_atual','sou_do_efetivo')
--  AND pg_get_functiondef(oid) NOT LIKE '%status = ''ativo''%';

-- ──────── 197_escrita_do_operador.sql ────────
-- 197_escrita_do_operador.sql
-- Lote 2026-10, onda A (segurança). Idempotente. Aplicar ANTES do deploy da onda A.
--
-- Por quê (docs/13):
-- H2. escoltas_update libera UPDATE ao membro do efetivo em todas as colunas, e a
--     trigger impedir_edicao_por_operador só barrava cliente, data e endereços. Pela
--     API o operador mudava financeiro, fluxo_versao (voltar para 1 desliga a exigência
--     do ponto de trânsito de retorno), checklist_pendente_no_inicio, a periodicidade do
--     check-in e cancelava a escolta. A tela nunca ofereceu nada disso: o operador só
--     avança status e, na finalização, grava observacao_fechamento e data_finalizacao
--     (no mesmo UPDATE que muda o status para finalizada). Depois de encerrada, a escolta
--     não muda mais pelo operador.
-- H3. Policies sem FOR valem também para DELETE: o membro do efetivo apagava emergência,
--     presença, rastreamento, checklist, respostas, atualização de status e a viatura
--     (que leva pontos e checklists em cascata). O app só apaga escolta_veiculos na
--     edição, feita pela gestão. Policies RESTRICTIVE de DELETE fecham isso sem mexer
--     nas permissivas atuais.
-- M3. logs_auditoria aceitava INSERT de qualquer autenticado (auditoria forjável) e
--     notificacoes aceitava INSERT com qualquer destino. O app não grava em nenhuma das
--     duas; as RPCs SECURITY DEFINER gravam sem depender de policy.
-- H4. Gestor alterava a linha de um administrador (inclusive o status, o que tranca o
--     administrador fora pela RLS) e redefinia a senha de outro gestor.

-- (a) Colunas que só a gestão altera em escoltas.
CREATE OR REPLACE FUNCTION public.impedir_edicao_por_operador() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text;
  v_col    text;
  v_old    jsonb;
  v_new    jsonb;
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
  -- ATENCAO (lote 2026-10): esta trigger compara checklist_pendente_no_inicio, que a
  -- tr_verificar_checklist_pendente grava no mesmo UPDATE. Funciona porque as BEFORE
  -- UPDATE rodam em ordem alfabetica e tr_impedir_... vem antes de tr_verificar_...
  -- Nao renomear nenhuma das duas sem rever isto.
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

  -- Lote 2026-10: financeiro, controle do fluxo e escala. Comparacao por jsonb para valer
  -- tambem para coluna criada depois desta funcao (escala_fixa, onda C).
  v_old := to_jsonb(OLD);
  v_new := to_jsonb(NEW);
  -- Escolta encerrada não muda mais pelo operador (relatório final e horário de término).
  IF OLD.status IN ('finalizada', 'cancelada') THEN
    RAISE EXCEPTION 'Escolta encerrada. Fale com o supervisor para corrigir.';
  END IF;

  -- Relatório final e término só junto da própria finalização.
  IF (NEW.observacao_fechamento IS DISTINCT FROM OLD.observacao_fechamento
      OR NEW.data_finalizacao IS DISTINCT FROM OLD.data_finalizacao)
     AND NEW.status IS DISTINCT FROM 'finalizada' THEN
    RAISE EXCEPTION 'O relatorio final so e gravado na finalizacao da escolta.';
  END IF;

  FOREACH v_col IN ARRAY ARRAY['valor_cobrado','outros_custos','observacao_financeira','fluxo_versao',
                               'checklist_pendente_no_inicio','periodicidade_checkin_min','codigo_escolta',
                               'criada_por','escala_fixa','metadados','data_solicitacao','criado_em']
  LOOP
    IF (v_new -> v_col) IS DISTINCT FROM (v_old -> v_col) THEN
      RAISE EXCEPTION 'Operador nao altera este campo da escolta (%). Fale com o supervisor.', v_col;
    END IF;
  END LOOP;

  IF NEW.status = 'cancelada' AND OLD.status IS DISTINCT FROM 'cancelada' THEN
    RAISE EXCEPTION 'Somente a supervisao cancela uma escolta.';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.impedir_edicao_por_operador() FROM PUBLIC, anon, authenticated;

-- (b) Apagar evidência de campo só pela gestão (G4). RESTRICTIVE soma com AND às atuais.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['emergencias','presencas','rastreamento','atualizacoes_status',
                           'checklists','checklist_respostas','escolta_veiculos']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_delete_so_gestao', t);
    EXECUTE format($f$CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated
      USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central']))$f$,
      t || '_delete_so_gestao', t);
  END LOOP;
END $$;

-- (c) Auditoria e notificação só por RPC SECURITY DEFINER.
DROP POLICY IF EXISTS logs_auditoria_insert ON public.logs_auditoria;
DROP POLICY IF EXISTS notificacoes_insert_so_gestao ON public.notificacoes;
CREATE POLICY notificacoes_insert_so_gestao ON public.notificacoes AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central']));
-- O destinatário só marca a própria notificação; não a reescreve para outra pessoa.
DROP POLICY IF EXISTS notificacoes_update_restrita ON public.notificacoes;
CREATE POLICY notificacoes_update_restrita ON public.notificacoes AS RESTRICTIVE FOR UPDATE TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central'])
         OR usuario_dest_id = (SELECT public.get_meu_usuario_id()))
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central'])
         OR usuario_dest_id = (SELECT public.get_meu_usuario_id()));

-- (d) Linha de administrador só por administrador (ou pelo próprio dono, que já tinha
--     as travas de perfil e status).
CREATE OR REPLACE FUNCTION public.impedir_autopromocao() RETURNS trigger
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

  -- 1b. Lote 2026-10: linha de administrador (antes ou depois) so por administrador.
  --     Sem isto, o gestor bloqueava todos os administradores pelo status.
  SELECT codigo INTO v_cod_antigo FROM public.dom_perfis WHERE id = OLD.perfil_id;
  IF v_cod_antigo = 'administrador' AND (v_perfil IS NULL OR v_perfil <> 'administrador') THEN
    RAISE EXCEPTION 'Somente um administrador altera a conta de outro administrador.';
  END IF;

  -- 2. Mexer no perfil de terceiro exige perfil de gestao.
  IF NEW.perfil_id IS DISTINCT FROM OLD.perfil_id THEN
    IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor') THEN
      RAISE EXCEPTION 'Permissao negada para alterar perfil de acesso.';
    END IF;

    SELECT codigo INTO v_cod_novo   FROM public.dom_perfis WHERE id = NEW.perfil_id;

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
REVOKE ALL ON FUNCTION public.impedir_autopromocao() FROM PUBLIC, anon, authenticated;

-- (e) Gestor só redefine senha de supervisor, central e operador.
CREATE OR REPLACE FUNCTION public.redefinir_senha_usuario(p_usuario_id uuid, p_nova_senha text) RETURNS void
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

  -- Lote 2026-10: gestor nao redefine a senha de outro gestor (tomaria a conta dele).
  IF v_alvo_perfil = 'gestor' AND v_caller_perfil <> 'administrador' AND p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Permissão negada. Apenas um administrador pode redefinir a senha de um gestor.';
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

-- ──────── 198_fotos_leitura_por_escolta.sql ────────
-- 198_fotos_leitura_por_escolta.sql
-- Lote 2026-10, onda A (segurança). Idempotente e aditiva. Aplicar ANTES do deploy da onda A.
--
-- Por quê (docs/13, H7 e H8):
-- 1. As fotos 2 a 5 de cada ponto ficam no JSON observacoes.foto_ids e a policy
--    fotos_select só alcança a foto 1 (pontos_controle.foto_id). Com o bucket público
--    isso ficava escondido, porque a tela monta a URL pelo caminho. Para fechar o bucket
--    (migration 200) quem tem direito à escolta precisa ler todas as fotos dela.
-- 2. Todo arquivo de foto de escolta é gravado como <prefixo>/<escolta_id>/<arquivo>
--    (app/dashboard/campo/page.tsx:793 e app/dashboard/escoltas/[id]/page.tsx:1546).
--    O segundo segmento identifica a escolta; a leitura passa a valer para quem é do
--    efetivo dela, o que cobre fotos 1 a 5, as de outra viatura da mesma escolta e as
--    de atualização de status, sem depender do JSON.
-- 3. Logos de cliente (logos/clientes/<id>/...) ficam legíveis por qualquer autenticado,
--    porque saem nos relatórios.
-- Com o bucket ainda público nada muda para quem usa URL pública: esta migration só
-- acrescenta caminhos de leitura.

CREATE OR REPLACE FUNCTION public.escolta_do_caminho(p_caminho text) RETURNS uuid
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT CASE
    WHEN split_part(p_caminho, '/', 2) ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    THEN split_part(p_caminho, '/', 2)::uuid
  END
$$;
COMMENT ON FUNCTION public.escolta_do_caminho(text) IS
  'Escolta dona de um arquivo de foto, pelo segundo segmento do caminho (<prefixo>/<escolta_id>/<arquivo>). NULL quando não for caminho de escolta.';

DROP POLICY IF EXISTS fotos_select_por_escolta ON public.fotos;
CREATE POLICY fotos_select_por_escolta ON public.fotos FOR SELECT TO authenticated
  USING (public.sou_do_efetivo(public.escolta_do_caminho(caminho_arquivo)));
COMMENT ON POLICY fotos_select_por_escolta ON public.fotos IS
  'Lote 2026-10: membro do efetivo lê todas as fotos da escolta (1 a 5 de cada ponto, qualquer viatura), pelo caminho do arquivo.';

DROP POLICY IF EXISTS fotos_leitura_autenticada ON storage.objects;
CREATE POLICY fotos_leitura_autenticada ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'fotos'
    AND (
      (SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central'])
      OR name LIKE 'logos/%'
      OR public.sou_do_efetivo(public.escolta_do_caminho(name))
      -- Quem enviou o arquivo (dono no storage). Não usa a tabela fotos, cujo caminho o
      -- autor consegue escrever: isso permitiria adivinhar caminhos de outra escolta.
      OR owner_id = (SELECT auth.uid())::text
    )
  );

-- Conferência: SELECT policyname FROM pg_policies WHERE policyname IN
--   ('fotos_select_por_escolta','fotos_leitura_autenticada');   -- esperado: 2 linhas

-- ──────── 199_troca_senha_obrigatoria.sql ────────
-- 199_troca_senha_obrigatoria.sql
-- Lote 2026-10, onda A (segurança). Idempotente. Aplicar ANTES do deploy da onda A.
--
-- Por quê: as contas de Douglas (administrador) e Bruno Moreira (gestor) foram criadas
-- com a senha provisória padrão. O pedido é marcar troca obrigatória no próximo login,
-- pelo mesmo mecanismo da senha provisória (usuarios.troca_senha_obrigatoria, conferido
-- em app/dashboard/layout.tsx), SEM trocar a senha.
--
-- Como: pelos ids das duas contas, lidos do backup de 08/10/2026 (Douglas, administrador,
-- e Bruno, gestor), conferindo o perfil esperado. Não lê nem troca senha. Contas já
-- marcadas não mudam (Douglas já estava marcado em 08/10).
-- Os ids alterados ficam registrados em logs_auditoria (acao lote_2026_10_troca_senha),
-- que é o que a reversão usa.

DO $$
DECLARE v_ids uuid[]; v_qtd int; v_esperadas int;
BEGIN
  -- Confere que os dois ids existem com o perfil esperado; senão aborta sem alterar nada.
  SELECT count(*) INTO v_esperadas
  FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE (u.id = '9b0c6047-d9eb-42a5-b980-d87ef7b5f611' AND p.codigo = 'administrador')
     OR (u.id = '130db52b-c966-44d9-aa35-622e24eb953c' AND p.codigo = 'gestor');
  IF v_esperadas <> 2 THEN
    RAISE EXCEPTION 'As contas de Douglas (administrador) e Bruno (gestor) nao foram encontradas com o perfil esperado (% de 2). Nada foi alterado.', v_esperadas;
  END IF;

  SELECT array_agg(u.id), count(*) INTO v_ids, v_qtd
  FROM public.usuarios u
  WHERE u.id IN ('9b0c6047-d9eb-42a5-b980-d87ef7b5f611', '130db52b-c966-44d9-aa35-622e24eb953c')
    AND u.troca_senha_obrigatoria IS DISTINCT FROM true;

  IF v_qtd = 0 THEN
    RAISE NOTICE 'Nenhuma conta a marcar (ja marcadas).';
    RETURN;
  END IF;

  UPDATE public.usuarios SET troca_senha_obrigatoria = true, atualizado_em = now()
  WHERE id = ANY (v_ids);

  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  SELECT NULL, 'lote_2026_10_troca_senha', 'usuarios', id,
         jsonb_build_object('troca_senha_obrigatoria', false),
         jsonb_build_object('troca_senha_obrigatoria', true, 'motivo', 'senha padrao, lote 2026-10'), now()
  FROM unnest(v_ids) AS id;
  RAISE NOTICE 'Contas marcadas: %', v_qtd;
END $$;

-- Conferência (esperado: as contas de Douglas e Bruno com troca = true):
-- SELECT u.nome_completo, p.codigo, u.troca_senha_obrigatoria FROM usuarios u
--   JOIN dom_perfis p ON p.id = u.perfil_id
--  WHERE u.id IN ('9b0c6047-d9eb-42a5-b980-d87ef7b5f611','130db52b-c966-44d9-aa35-622e24eb953c');

-- ──────── 201_checkin_desligado.sql ────────
-- 201_checkin_desligado.sql
-- Lote 2026-10, onda B (M4). Idempotente. Bloco 1 (antes do deploy; compatível com o código atual)
-- e DE NOVO no bloco 2, depois do push da onda B: até o deploy, o formulário antigo ainda
-- grava 30 min em escolta nova ou editada. A segunda aplicação zera o que entrou nessa janela.
-- Não reaplicar depois disso sem conferir os clientes religados (metadados.checkin_periodico_min).
--
-- Por quê (decisão 3 de Peçanha, 08/10/2026): o check-in periódico fica desligado por
-- padrão; a coluna e a lógica de lib/checkin.ts continuam, para religar por cliente.
-- 1. Zera periodicidade_checkin_min das escoltas abertas (não finalizadas nem canceladas).
--    Inclui ESC-2026-0001 e ESC-2026-0007, só esse campo: desliga o alerta, não muda
--    status, histórico, equipe nem metadados. O valor anterior fica em
--    backup_20261008.periodicidade_checkin (schema não exposto pela API) para a reversão.
-- 2. alertas_dispensados: o X do aviso passa a valer por escolta até mudança real de
--    estado (novo check-in, novo status ou nova periodicidade), guardado no banco.
--    Antes o X só limpava a memória da aba e o aviso voltava a cada 5 minutos.

CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261008.periodicidade_checkin (
  escolta_id uuid PRIMARY KEY,
  periodicidade_checkin_min integer NOT NULL,
  gravado_em timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON backup_20261008.periodicidade_checkin FROM PUBLIC, anon, authenticated;

INSERT INTO backup_20261008.periodicidade_checkin (escolta_id, periodicidade_checkin_min)
SELECT id, periodicidade_checkin_min FROM public.escoltas
WHERE status NOT IN ('finalizada', 'cancelada') AND periodicidade_checkin_min IS NOT NULL
ON CONFLICT (escolta_id) DO NOTHING;

UPDATE public.escoltas SET periodicidade_checkin_min = NULL
WHERE status NOT IN ('finalizada', 'cancelada') AND periodicidade_checkin_min IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.alertas_dispensados (
  usuario_id    uuid NOT NULL REFERENCES public.usuarios(id) ON DELETE CASCADE,
  escolta_id    uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  tipo          text NOT NULL CHECK (tipo IN ('checkin')),
  assinatura    text NOT NULL,
  dispensado_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (usuario_id, escolta_id, tipo)
);
COMMENT ON TABLE public.alertas_dispensados IS
  'Lote 2026-10: aviso fechado pelo usuário. Vale enquanto a assinatura do estado da escolta (status | referência do prazo | periodicidade) for a mesma.';
ALTER TABLE public.alertas_dispensados ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.alertas_dispensados FROM anon;
REVOKE ALL ON public.alertas_dispensados FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.alertas_dispensados TO authenticated;
DROP POLICY IF EXISTS alertas_dispensados_proprio ON public.alertas_dispensados;
CREATE POLICY alertas_dispensados_proprio ON public.alertas_dispensados FOR ALL TO authenticated
  USING (usuario_id = (SELECT public.get_meu_usuario_id()))
  WITH CHECK (usuario_id = (SELECT public.get_meu_usuario_id()));

-- Conferência:
-- SELECT count(*) FROM escoltas WHERE status NOT IN ('finalizada','cancelada') AND periodicidade_checkin_min IS NOT NULL; -- 0
-- SELECT count(*) FROM backup_20261008.periodicidade_checkin;   -- 8 em 08/10/2026

-- ──────── 202_avisos_telegram.sql ────────
-- 202_avisos_telegram.sql
-- Lote 2026-10, ondas C e F. Idempotente. Bloco 1 (antes do deploy; compatível com o código atual).
--
-- Por quê: o aviso ao Telegram saía do navegador de cada usuário logado (um por aba
-- aberta) e não havia como mandar aviso sem alguém com a tela aberta (docs/13, H10 e
-- H12). Esta migration cria uma fila no banco, com chave única por evento, e o envio
-- pelo próprio banco: pg_cron a cada minuto chama enviar_avisos_telegram(), que usa
-- pg_net com o token guardado no Vault. Cada evento vira no máximo uma mensagem: não há
-- reenvio automático depois de enviado ou de erro.
--
-- Pré-requisito para enviar (ação do Peçanha, pela tela Vault do painel do Supabase,
-- nunca pelo SQL Editor, que guarda o histórico): segredos telegram_bot_token e
-- telegram_chat_central. Sem eles, ou sem as extensões, avisos_pelo_banco_ativos() fica
-- falso, nada é enfileirado e o aplicativo continua mandando pelo /api/telegram.
--
-- Usada pela onda C (mural) e pela onda F (check-in e presença). Aplicar mesmo que uma
-- delas fique fora do pacote.

-- 1. Extensões. Se o projeto recusar a criação, a fila nasce assim mesmo e o envio
--    pelo banco fica desligado (configuracao_avisos.envio_pelo_banco = false).
--    Guarda se cada uma já existia, para a reversão não apagar o que não criou.
CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261008.extensoes_antes_202 (nome text PRIMARY KEY, existia boolean NOT NULL);
REVOKE ALL ON backup_20261008.extensoes_antes_202 FROM PUBLIC, anon, authenticated;
INSERT INTO backup_20261008.extensoes_antes_202 (nome, existia)
SELECT n, EXISTS (SELECT 1 FROM pg_extension WHERE extname = n) FROM unnest(ARRAY['pg_net', 'pg_cron']) AS n
ON CONFLICT (nome) DO NOTHING;
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
  EXCEPTION WHEN others THEN RAISE NOTICE 'pg_net indisponivel: %', SQLERRM;
  END;
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN others THEN RAISE NOTICE 'pg_cron indisponivel: %', SQLERRM;
  END;
END $$;

-- 2. Configuração (linha única). Sem policy: só o SQL Editor altera. O endereço da API
--    não pode mudar pela aplicação, senão o token iria para outro lugar.
CREATE TABLE IF NOT EXISTS public.configuracao_avisos (
  id                smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  telegram_api_base text NOT NULL DEFAULT 'https://api.telegram.org',
  envio_pelo_banco  boolean NOT NULL DEFAULT true,
  atualizado_em     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.configuracao_avisos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.configuracao_avisos FROM anon, authenticated;
INSERT INTO public.configuracao_avisos (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
UPDATE public.configuracao_avisos SET envio_pelo_banco = false
WHERE NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
   OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron');

-- 3. Fila. Sem policy: só funções SECURITY DEFINER leem e gravam.
CREATE TABLE IF NOT EXISTS public.avisos_telegram (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evento_chave      text NOT NULL UNIQUE,
  destino           text NOT NULL CHECK (destino IN ('central', 'cliente')),
  escolta_id        uuid REFERENCES public.escoltas(id) ON DELETE SET NULL,
  texto             text NOT NULL,
  origem_usuario_id uuid,
  criado_em         timestamptz NOT NULL DEFAULT now(),
  situacao          text NOT NULL DEFAULT 'pendente' CHECK (situacao IN ('pendente', 'enviando', 'enviado', 'erro')),
  enviado_em        timestamptz,
  pg_net_id         bigint,
  erro              text
);
CREATE INDEX IF NOT EXISTS avisos_telegram_situacao_idx ON public.avisos_telegram (situacao, criado_em);
ALTER TABLE public.avisos_telegram ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.avisos_telegram FROM anon, authenticated;
COMMENT ON TABLE public.avisos_telegram IS
  'Lote 2026-10: fila de avisos ao Telegram, enviada pelo banco (pg_cron + pg_net). Uma linha por evento (evento_chave única), no máximo uma mensagem.';

-- 4. Escape de HTML para textos que o banco monta (parse_mode HTML do Telegram).
CREATE OR REPLACE FUNCTION public.escapar_html(p text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;
REVOKE ALL ON FUNCTION public.escapar_html(text) FROM PUBLIC, anon, authenticated;

-- 5. As peças do envio pelo banco estão todas presentes?
CREATE OR REPLACE FUNCTION public.avisos_pelo_banco_ativos() RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v boolean;
BEGIN
  IF NOT coalesce((SELECT envio_pelo_banco FROM public.configuracao_avisos WHERE id = 1), false) THEN RETURN false; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
     OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RETURN false;
  END IF;
  EXECUTE $q$SELECT count(*) = 2 FROM vault.decrypted_secrets
             WHERE name IN ('telegram_bot_token', 'telegram_chat_central')
               AND coalesce(decrypted_secret, '') <> ''$q$ INTO v;
  IF NOT v THEN RETURN false; END IF;
  EXECUTE $q$SELECT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'lote2026_avisos_telegram' AND active)$q$ INTO v;
  RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION public.avisos_pelo_banco_ativos() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avisos_pelo_banco_ativos() TO authenticated;

-- 6. Enfileirar (interna). Só enfileira com o envio pelo banco ativo; senão devolve
--    false e quem chamou avisa pelo caminho antigo. Chave repetida não duplica.
CREATE OR REPLACE FUNCTION public._enfileirar_aviso(p_chave text, p_destino text, p_escolta_id uuid, p_texto text)
    RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF NOT public.avisos_pelo_banco_ativos() THEN RETURN false; END IF;
  INSERT INTO public.avisos_telegram (evento_chave, destino, escolta_id, texto, origem_usuario_id)
  VALUES (p_chave, p_destino, p_escolta_id, left(p_texto, 4000),
          (SELECT id FROM public.usuarios WHERE auth_user_id = auth.uid()))
  ON CONFLICT (evento_chave) DO NOTHING;
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public._enfileirar_aviso(text, text, uuid, text) FROM PUBLIC, anon, authenticated;

-- 7. Envio (interna, pelo cron). Marca 'enviando' antes de pedir ao pg_net: nunca
--    reenvia o mesmo aviso.
CREATE OR REPLACE FUNCTION public.enviar_avisos_telegram() RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  r record; v_token text; v_central text; v_base text; v_chat text; v_req bigint; n int := 0;
BEGIN
  IF NOT public.avisos_pelo_banco_ativos() THEN RETURN 0; END IF;
  EXECUTE $q$SELECT max(decrypted_secret) FILTER (WHERE name = 'telegram_bot_token'),
                    max(decrypted_secret) FILTER (WHERE name = 'telegram_chat_central')
             FROM vault.decrypted_secrets$q$ INTO v_token, v_central;
  SELECT telegram_api_base INTO v_base FROM public.configuracao_avisos WHERE id = 1;
  FOR r IN
    SELECT a.id, a.destino, a.texto, c.telegram_chat_id AS chat_cliente
    FROM public.avisos_telegram a
    LEFT JOIN public.escoltas e ON e.id = a.escolta_id
    LEFT JOIN public.clientes c ON c.id = e.cliente_id
    WHERE a.situacao = 'pendente'
    ORDER BY a.criado_em
    LIMIT 20
    FOR UPDATE OF a SKIP LOCKED
  LOOP
    v_chat := CASE WHEN r.destino = 'cliente' THEN coalesce(nullif(r.chat_cliente, ''), v_central) ELSE v_central END;
    UPDATE public.avisos_telegram SET situacao = 'enviando', enviado_em = now() WHERE id = r.id;
    EXECUTE $q$SELECT net.http_post(url := $1, body := $2, headers := '{"Content-Type": "application/json"}'::jsonb)$q$
      INTO v_req
      USING v_base || '/bot' || v_token || '/sendMessage',
            jsonb_build_object('chat_id', v_chat, 'text', r.texto, 'parse_mode', 'HTML', 'disable_web_page_preview', true);
    UPDATE public.avisos_telegram SET pg_net_id = v_req WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.enviar_avisos_telegram() FROM PUBLIC, anon, authenticated;

-- 8. Conferência das respostas (interna, pelo cron). O erro guardado nunca leva a URL,
--    que contém o token.
CREATE OR REPLACE FUNCTION public.conferir_avisos_telegram() RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE r record; v_status int; v_conteudo text; v_erro text; n int := 0;
BEGIN
  IF to_regclass('net._http_response') IS NULL THEN RETURN 0; END IF;
  FOR r IN SELECT id, pg_net_id, enviado_em FROM public.avisos_telegram WHERE situacao = 'enviando' FOR UPDATE SKIP LOCKED LOOP
    v_status := NULL; v_conteudo := NULL; v_erro := NULL;
    IF r.pg_net_id IS NOT NULL THEN
      EXECUTE $q$SELECT status_code, content::text, error_msg FROM net._http_response WHERE id = $1$q$
        INTO v_status, v_conteudo, v_erro USING r.pg_net_id;
    END IF;
    -- Resposta que não é JSON (proxy devolvendo HTML) não pode derrubar a rodada inteira.
    BEGIN
      v_conteudo := v_conteudo::jsonb ->> 'description';
    EXCEPTION WHEN others THEN
      v_conteudo := NULL;
    END;
    IF v_status = 200 THEN
      UPDATE public.avisos_telegram SET situacao = 'enviado', erro = NULL WHERE id = r.id;
      n := n + 1;
    ELSIF v_status IS NOT NULL OR v_erro IS NOT NULL THEN
      UPDATE public.avisos_telegram
         SET situacao = 'erro',
             erro = regexp_replace(left(coalesce(v_status::text, '') || ' ' ||
                      coalesce(v_conteudo, v_erro, ''), 300),
                    '/bot[^/[:space:]]+', '/bot***', 'g')
       WHERE id = r.id;
    ELSIF r.enviado_em < now() - interval '10 minutes' THEN
      UPDATE public.avisos_telegram SET situacao = 'erro', erro = 'sem resposta em 10 minutos' WHERE id = r.id;
    END IF;
  END LOOP;
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.conferir_avisos_telegram() FROM PUBLIC, anon, authenticated;

-- 9. O pg_net guarda a URL (com o token) na fila e o corpo da resposta: tenta tirar o acesso
--    de anon e authenticated ao schema net (nada do cliente usa pg_net). No Supabase o dono
--    do schema net não é o postgres e o REVOKE pode não ter efeito (aviso "no privileges
--    could be revoked"); nesse caso fica como pendência declarada: o schema net não é
--    exposto pelo PostgREST, então só uma conexão SQL direta com papel de baixo privilégio
--    leria a fila.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'net') THEN
    REVOKE USAGE ON SCHEMA net FROM anon, authenticated;
    REVOKE ALL ON ALL TABLES IN SCHEMA net FROM anon, authenticated;
  END IF;
END $$;

-- 10. Agendamento a cada minuto (só com pg_cron).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    EXECUTE $q$SELECT cron.schedule('lote2026_avisos_telegram', '* * * * *',
      'SELECT public.conferir_avisos_telegram(); SELECT public.enviar_avisos_telegram();')$q$;
  END IF;
END $$;

-- Conferência:
-- SELECT extname FROM pg_extension WHERE extname IN ('pg_cron','pg_net');
-- SELECT envio_pelo_banco FROM configuracao_avisos;
-- SELECT public.avisos_pelo_banco_ativos();   -- true só depois dos segredos no Vault
-- SELECT situacao, count(*) FROM avisos_telegram GROUP BY 1;

-- ──────── 203_mural_travas_estrutura.sql ────────
-- 203_mural_travas_estrutura.sql
-- Lote 2026-10, onda C (M5, travas do mural). Idempotente. Bloco 1 (antes do deploy):
-- só cria estrutura; as RPCs antigas continuam valendo até a 204 (bloco 2).
--
-- Por quê (docs/13, H9): desde 20/08 qualquer operador substitui a equipe escalada a
-- qualquer momento antes do início, com motivo de 5 caracteres. Decisões de Peçanha de
-- 08/10/2026: travas T1 a T7, janela de 60 min, aprovação com tempo limite de 15 min,
-- intervalo de 6 h entre escoltas do mesmo comandante.

-- 1. Parâmetros (linha única), editáveis por gestor e administrador. A auditoria não é
--    parâmetro: é sempre gravada.
CREATE TABLE IF NOT EXISTS public.configuracoes_mural (
  id                          smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  janela_substituicao_min     integer NOT NULL DEFAULT 60 CHECK (janela_substituicao_min BETWEEN 0 AND 1440),
  aprovacao_tempo_limite_min  integer NOT NULL DEFAULT 15 CHECK (aprovacao_tempo_limite_min BETWEEN 1 AND 240),
  intervalo_comandante_h      integer NOT NULL DEFAULT 6 CHECK (intervalo_comandante_h BETWEEN 0 AND 48),
  presenca_ligada             boolean NOT NULL DEFAULT true,
  aviso_ligado                boolean NOT NULL DEFAULT true,
  atualizado_por              uuid REFERENCES public.usuarios(id),
  atualizado_em               timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.configuracoes_mural (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.configuracoes_mural ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.configuracoes_mural FROM anon;
REVOKE INSERT, DELETE, TRUNCATE ON public.configuracoes_mural FROM authenticated;
GRANT SELECT, UPDATE ON public.configuracoes_mural TO authenticated;
DROP POLICY IF EXISTS configuracoes_mural_leitura ON public.configuracoes_mural;
CREATE POLICY configuracoes_mural_leitura ON public.configuracoes_mural FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS configuracoes_mural_edicao ON public.configuracoes_mural;
CREATE POLICY configuracoes_mural_edicao ON public.configuracoes_mural FOR UPDATE TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor']))
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor']));
COMMENT ON TABLE public.configuracoes_mural IS 'Lote 2026-10 (M5): parâmetros das travas do mural, lidos pelas RPCs no servidor.';

-- 2. T6: escala fixa. Some do mural para operadores; só supervisor ou acima muda.
--    Trava própria (não depende da 197 da onda A): central e operador não alteram.
ALTER TABLE public.escoltas ADD COLUMN IF NOT EXISTS escala_fixa boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION public.proteger_escala_fixa() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;      -- SQL Editor e migrations
  IF TG_OP = 'UPDATE' AND NEW.escala_fixa IS NOT DISTINCT FROM OLD.escala_fixa THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' AND NOT NEW.escala_fixa THEN RETURN NEW; END IF;
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Somente supervisor ou acima marca ou desmarca escala fixa.';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.proteger_escala_fixa() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_proteger_escala_fixa ON public.escoltas;
CREATE TRIGGER tr_proteger_escala_fixa BEFORE INSERT OR UPDATE ON public.escoltas
  FOR EACH ROW EXECUTE FUNCTION public.proteger_escala_fixa();
COMMENT ON COLUMN public.escoltas.escala_fixa IS 'Lote 2026-10 (T6): equipe definida pela gestão; não aparece no mural e não é substituída pelo operador.';

-- 3. T2: presença na base confirmada pela equipe escalada.
CREATE TABLE IF NOT EXISTS public.mural_presencas (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id       uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  vigilante_id     uuid NOT NULL REFERENCES public.vigilantes(id),
  usuario_id       uuid NOT NULL REFERENCES public.usuarios(id),
  confirmado_em    timestamptz NOT NULL DEFAULT now(),
  latitude         numeric(10,7),
  longitude        numeric(10,7),
  precisao_metros  numeric(8,2),
  sem_gps          boolean NOT NULL DEFAULT false,
  UNIQUE (escolta_id, vigilante_id)
);
ALTER TABLE public.mural_presencas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mural_presencas FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.mural_presencas FROM authenticated;
GRANT SELECT ON public.mural_presencas TO authenticated;
DROP POLICY IF EXISTS mural_presencas_leitura ON public.mural_presencas;
CREATE POLICY mural_presencas_leitura ON public.mural_presencas FOR SELECT TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor', 'central'])
         OR public.sou_do_efetivo(escolta_id));

-- 4. T3 e T7: pedidos de substituição (e o histórico deles).
CREATE TABLE IF NOT EXISTS public.mural_pedidos (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id                uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  solicitante_usuario_id    uuid NOT NULL REFERENCES public.usuarios(id),
  solicitante_vigilante_id  uuid NOT NULL REFERENCES public.vigilantes(id),
  acompanhantes             uuid[] NOT NULL DEFAULT '{}',
  veiculo_id                uuid REFERENCES public.veiculos(id),
  motivo                    text NOT NULL CHECK (length(trim(motivo)) BETWEEN 20 AND 500),
  equipe_antes              jsonb NOT NULL DEFAULT '[]',
  status                    text NOT NULL DEFAULT 'pendente'
                              CHECK (status IN ('pendente', 'aprovado', 'recusado', 'liberado_por_tempo', 'cancelado', 'invalidado')),
  criado_em                 timestamptz NOT NULL DEFAULT now(),
  expira_em                 timestamptz NOT NULL,
  antecedencia_min          integer,
  decidido_por              uuid REFERENCES public.usuarios(id),
  decidido_em               timestamptz,
  observacao_decisao        text
);
CREATE UNIQUE INDEX IF NOT EXISTS mural_pedidos_um_pendente ON public.mural_pedidos (escolta_id) WHERE status = 'pendente';
CREATE INDEX IF NOT EXISTS mural_pedidos_criado_idx ON public.mural_pedidos (criado_em DESC);
ALTER TABLE public.mural_pedidos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mural_pedidos FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.mural_pedidos FROM authenticated;
GRANT SELECT ON public.mural_pedidos TO authenticated;
DROP POLICY IF EXISTS mural_pedidos_leitura ON public.mural_pedidos;
CREATE POLICY mural_pedidos_leitura ON public.mural_pedidos FOR SELECT TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor'])
         OR solicitante_usuario_id = (SELECT public.get_meu_usuario_id()));
COMMENT ON TABLE public.mural_pedidos IS 'Lote 2026-10 (T3, T7): pedidos de substituição de equipe; só as RPCs do mural gravam.';

-- 5. Tipos de evento dos avisos do mural no aplicativo (tabela notificacoes).
INSERT INTO public.dom_tipos_evento (codigo, nome_exibicao, gera_notificacao, ativo)
SELECT v.codigo, v.nome, true, true
FROM (VALUES ('pedido_substituicao', 'Pedido de substituição de equipe'),
             ('decisao_substituicao', 'Decisão sobre pedido de substituição'),
             ('substituicao_equipe', 'Substituição de equipe')) v(codigo, nome)
WHERE NOT EXISTS (SELECT 1 FROM public.dom_tipos_evento d WHERE d.codigo = v.codigo);

-- Conferência:
-- SELECT * FROM configuracoes_mural;                                   -- 60, 15, 6
-- SELECT count(*) FROM escoltas WHERE escala_fixa;                     -- 0
-- SELECT codigo FROM dom_tipos_evento WHERE codigo LIKE '%substituicao%';  -- 3

-- ──────── 205_locais_salvos.sql ────────
-- 205_locais_salvos.sql
-- Lote 2026-10, onda D (M2 e M1). Idempotente. Bloco 1 (antes do deploy).
--
-- Por quê (nota de 03/10, itens M2 e M1; docs/13, 2.4): os endereços recorrentes eram
-- digitados e escolhidos na busca da Mapbox a cada escolta, e a busca devolve para a
-- JAMEF uma coordenada 1.327 m longe do lugar onde o GPS dos operadores registra a
-- chegada. Locais salvos, com a coordenada conferida no mapa, viram atalhos de um toque
-- na origem e no destino.
--
-- Decisões de Peçanha (08/10/2026): quem cadastra é supervisor ou acima (decisão 5); a
-- carga inicial nasce "aguardando_conferencia" e só é ativada depois que Peçanha ou
-- Bruno conferirem o pino no mapa (decisão 6), por isso ativar exige gestor ou
-- administrador; CT do Botafogo fica fora até o Bruno informar o endereço.

CREATE TABLE IF NOT EXISTS public.locais_salvos (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome              text NOT NULL CHECK (length(trim(nome)) BETWEEN 2 AND 40),
  endereco          text NOT NULL,
  complemento       text,
  latitude          numeric(10,7) CHECK (latitude BETWEEN -90 AND 90),
  longitude         numeric(10,7) CHECK (longitude BETWEEN -180 AND 180),
  situacao          text NOT NULL DEFAULT 'aguardando_conferencia'
                      CHECK (situacao IN ('ativo', 'inativo', 'aguardando_conferencia')),
  fonte_coordenada  text,
  conferido_por     uuid REFERENCES public.usuarios(id),
  conferido_em      timestamptz,
  criado_por        uuid REFERENCES public.usuarios(id),
  criado_em         timestamptz NOT NULL DEFAULT now(),
  atualizado_por    uuid REFERENCES public.usuarios(id),
  atualizado_em     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT locais_salvos_ativo_com_coordenada CHECK (situacao <> 'ativo' OR (latitude IS NOT NULL AND longitude IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS locais_salvos_nome_unico ON public.locais_salvos (lower(trim(nome))) WHERE situacao <> 'inativo';
COMMENT ON TABLE public.locais_salvos IS 'Lote 2026-10 (M2): atalhos de endereço com coordenada conferida no mapa. Só os ativos aparecem como atalho.';

ALTER TABLE public.locais_salvos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.locais_salvos FROM anon;
REVOKE ALL ON public.locais_salvos FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON public.locais_salvos TO authenticated;
DROP POLICY IF EXISTS locais_salvos_leitura ON public.locais_salvos;
CREATE POLICY locais_salvos_leitura ON public.locais_salvos FOR SELECT TO authenticated
  USING (situacao = 'ativo'
         OR (SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']));
DROP POLICY IF EXISTS locais_salvos_cadastro ON public.locais_salvos;
CREATE POLICY locais_salvos_cadastro ON public.locais_salvos FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']));
DROP POLICY IF EXISTS locais_salvos_edicao ON public.locais_salvos;
CREATE POLICY locais_salvos_edicao ON public.locais_salvos FOR UPDATE TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']))
  WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']));

-- Ativar exige gestor ou administrador e registra quem conferiu; mexer na coordenada de
-- um local ativo exige nova conferência; criado_por e atualizado_por vêm da sessão.
CREATE OR REPLACE FUNCTION public.locais_salvos_regras() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; v_eu uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;      -- SQL Editor e migrations
  SELECT public.get_meu_perfil() INTO v_perfil;
  v_eu := public.get_meu_usuario_id();
  IF TG_OP = 'INSERT' THEN
    NEW.criado_por := v_eu; NEW.criado_em := now();
    IF NEW.situacao = 'ativo' THEN NEW.situacao := 'aguardando_conferencia'; END IF;
    NEW.conferido_por := NULL; NEW.conferido_em := NULL;
  ELSE
    NEW.criado_por := OLD.criado_por; NEW.criado_em := OLD.criado_em;
    -- Local ativo que muda de coordenada, nome, endereço ou complemento volta para
    -- conferência (o texto e o pino são o que a conferência atestou).
    IF OLD.situacao = 'ativo' AND NEW.situacao = 'ativo'
       AND (NEW.latitude IS DISTINCT FROM OLD.latitude OR NEW.longitude IS DISTINCT FROM OLD.longitude
            OR NEW.nome IS DISTINCT FROM OLD.nome OR NEW.endereco IS DISTINCT FROM OLD.endereco
            OR NEW.complemento IS DISTINCT FROM OLD.complemento) THEN
      NEW.situacao := 'aguardando_conferencia';
    END IF;
    IF NEW.situacao = 'ativo' AND OLD.situacao IS DISTINCT FROM 'ativo' THEN
      IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor') THEN
        RAISE EXCEPTION 'Somente gestor ou administrador confere e ativa um local salvo.';
      END IF;
      NEW.conferido_por := v_eu; NEW.conferido_em := now();
    ELSIF NEW.situacao <> 'ativo' THEN
      NEW.conferido_por := CASE WHEN NEW.situacao = 'inativo' THEN OLD.conferido_por END;
      NEW.conferido_em := CASE WHEN NEW.situacao = 'inativo' THEN OLD.conferido_em END;
    ELSE
      NEW.conferido_por := OLD.conferido_por; NEW.conferido_em := OLD.conferido_em;
    END IF;
  END IF;
  NEW.atualizado_por := v_eu; NEW.atualizado_em := now();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.locais_salvos_regras() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_locais_salvos_regras ON public.locais_salvos;
CREATE TRIGGER tr_locais_salvos_regras BEFORE INSERT OR UPDATE ON public.locais_salvos
  FOR EACH ROW EXECUTE FUNCTION public.locais_salvos_regras();

-- Carga inicial (aguardando conferência). Coordenadas medidas só onde há fonte; as demais
-- ficam nulas e o pino é posto na conferência (desvio declarado da decisão 6).
INSERT INTO public.locais_salvos (nome, endereco, latitude, longitude, situacao, fonte_coordenada)
SELECT v.nome, v.endereco, v.lat, v.lng, 'aguardando_conferencia', v.fonte
FROM (VALUES
  ('JAMEF', 'Av. Arthur Antônio Sendas, 999, Parque Santana, São João de Meriti', -22.799521::numeric, -43.347756::numeric,
   'Média de 5 pontos de GPS de campo (precisão até 15 m) registrados na chegada à JAMEF; conferir o pino'),
  ('Sede', 'Rua Cândido Figueiredo, 204, Tanque, Rio de Janeiro', -22.918625::numeric, -43.362670::numeric,
   'Média de 11 pontos de GPS de campo (precisão até 15 m) de saída e retorno à base; conferir o pino'),
  ('Engenhão', 'Rua das Oficinas, Cachambi, Rio de Janeiro', NULL, NULL, 'Sem medida de campo nem número informado; pôr o pino na conferência'),
  ('Aeroporto do Galeão', 'Aeroporto Internacional do Rio de Janeiro (Galeão), Rio de Janeiro', NULL, NULL, 'Sem endereço informado; pôr o pino no terminal ou portão de carga usado'),
  ('Aeroporto Santos Dumont', 'Aeroporto Santos Dumont, Rio de Janeiro', NULL, NULL, 'Sem endereço informado; pôr o pino no terminal ou portão de carga usado')
) v(nome, endereco, lat, lng, fonte)
WHERE NOT EXISTS (SELECT 1 FROM public.locais_salvos l WHERE lower(trim(l.nome)) = lower(trim(v.nome)));

-- Conferência:
-- SELECT nome, situacao, latitude, longitude FROM locais_salvos ORDER BY nome;   -- 5, todos aguardando_conferencia

-- ──────── 206_combustivel.sql ────────
-- 206_combustivel.sql
-- Lote 2026-10, onda E (M3). Idempotente. Bloco 1 (antes do deploy).
--
-- Por quê: o custo real de combustível por viatura passa a ser lançado
-- (escolta_veiculos.abastecimento_litros e abastecimento_valor, colunas que já existiam
-- e que Indicadores, PDF e resumo financeiro já somam). A policy escolta_veiculos_escrita
-- vale também para o operador do efetivo (ele grava o KM), então sem esta trava o
-- operador gravaria o custo pela API. Os CHECK de valor não negativo já existem.

CREATE OR REPLACE FUNCTION public.impedir_combustivel_por_operador() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;          -- SQL Editor e migrations
  IF public.get_meu_perfil() = ANY (ARRAY['administrador', 'gestor', 'supervisor', 'central']) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.abastecimento_litros IS NOT NULL OR NEW.abastecimento_valor IS NOT NULL THEN
      RAISE EXCEPTION 'Combustivel e lancado pela supervisao.';
    END IF;
  ELSIF NEW.abastecimento_litros IS DISTINCT FROM OLD.abastecimento_litros
     OR NEW.abastecimento_valor IS DISTINCT FROM OLD.abastecimento_valor THEN
    RAISE EXCEPTION 'Combustivel e lancado pela supervisao.';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.impedir_combustivel_por_operador() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_impedir_combustivel_por_operador ON public.escolta_veiculos;
CREATE TRIGGER tr_impedir_combustivel_por_operador BEFORE INSERT OR UPDATE ON public.escolta_veiculos
  FOR EACH ROW EXECUTE FUNCTION public.impedir_combustivel_por_operador();

-- ──────── 207_etapa_atomica.sql ────────
-- 207_etapa_atomica.sql
-- Lote 2026-10, onda F (dívida técnica). Idempotente. Bloco 1 (aditiva; o código atual não a usa).
--
-- Por quê (docs/13, M6; comando, onda F, item 1): cada etapa era gravada pelo navegador em
-- três chamadas separadas (pontos, status, histórico). Falha no meio deixava registro
-- órfão: ponto sem transição, ou status avançado sem histórico (12 inserts de histórico
-- da tela de detalhe ignoravam o erro). Esta função faz as três coisas numa transação.
--
-- SECURITY INVOKER: roda com a RLS e as triggers de quem chama; não dá privilégio novo.
-- Não é o "Caminho 2" (um escritor por etapa em lib/etapas.ts): cada tela continua com o
-- próprio fluxo; só a gravação final ficou atômica.

CREATE OR REPLACE FUNCTION public.registrar_etapa_escolta(
  p_escolta_id            uuid,
  p_pontos                jsonb       DEFAULT '[]'::jsonb,
  p_status_atual          text        DEFAULT NULL,
  p_status_novo           text        DEFAULT NULL,
  p_observacao            text        DEFAULT NULL,
  p_latitude              numeric     DEFAULT NULL,
  p_longitude             numeric     DEFAULT NULL,
  p_observacao_fechamento text        DEFAULT NULL,
  p_data_hora_prevista    timestamptz DEFAULT NULL,
  p_tipo_ponto_todas      uuid        DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY INVOKER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n int; v_faltando text[]; v_status text;
BEGIN
  -- 0. Trava a escolta e confere a etapa ANTES de gravar qualquer coisa. Serializa duas
  --    viaturas do comboio registrando ao mesmo tempo (a segunda vê o ponto da primeira)
  --    e impede ponto de uma etapa que já passou.
  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF p_status_atual IS NOT NULL AND v_status IS DISTINCT FROM p_status_atual THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 1. Pontos de controle (todas as viaturas num statement só).
  IF jsonb_array_length(coalesce(p_pontos, '[]'::jsonb)) > 0 THEN
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid)
               WHERE NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
                                 WHERE ev.id = x.escolta_veiculo_id AND ev.escolta_id = p_escolta_id)) THEN
      RAISE EXCEPTION 'Ponto de controle de viatura que nao pertence a esta escolta.';
    END IF;
    INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude,
                                        precisao_metros, sem_sinal_gps, foto_id, lancado_por, observacoes,
                                        sincronizado, criado_offline)
    SELECT x.escolta_veiculo_id, x.tipo_ponto_id, coalesce(x.data_hora, now()), x.latitude, x.longitude,
           x.precisao_metros, coalesce(x.sem_sinal_gps, false), x.foto_id, x.lancado_por, x.observacoes,
           coalesce(x.sincronizado, true), coalesce(x.criado_offline, false)
    FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid, tipo_ponto_id uuid, data_hora timestamptz,
                                           latitude numeric, longitude numeric, precisao_metros numeric,
                                           sem_sinal_gps boolean, foto_id uuid, lancado_por uuid, observacoes text,
                                           sincronizado boolean, criado_offline boolean);
  END IF;

  IF p_status_novo IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'avancou', false);
  END IF;

  -- 2. Comboio: a etapa só avança quando todas as viaturas registraram o ponto dela.
  IF p_tipo_ponto_todas IS NOT NULL THEN
    SELECT array_agg(coalesce(ve.placa, 'sem placa') ORDER BY ev.criado_em) INTO v_faltando
    FROM public.escolta_veiculos ev
    LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
    WHERE ev.escolta_id = p_escolta_id
      AND NOT EXISTS (SELECT 1 FROM public.pontos_controle pc
                      WHERE pc.escolta_veiculo_id = ev.id AND pc.tipo_ponto_id = p_tipo_ponto_todas);
    IF v_faltando IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'avancou', false, 'faltando', to_jsonb(v_faltando));
    END IF;
  END IF;

  -- 3. Status, com a guarda do status atual (a trigger valida a transição).
  UPDATE public.escoltas SET
         status = p_status_novo,
         observacao_fechamento = CASE
           WHEN p_status_novo IN ('finalizada', 'cancelada') THEN p_observacao_fechamento
           WHEN p_data_hora_prevista IS NOT NULL THEN NULL
           ELSE observacao_fechamento END,
         data_finalizacao = CASE WHEN p_status_novo = 'finalizada' THEN now() ELSE data_finalizacao END,
         data_hora_prevista = coalesce(p_data_hora_prevista, data_hora_prevista)
   WHERE id = p_escolta_id AND status = p_status_atual;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 4. Histórico, com autor, na mesma transação.
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora,
                                               latitude, longitude, observacao)
  VALUES (p_escolta_id, p_status_atual, p_status_novo, public.get_meu_usuario_id(), now(),
          p_latitude, p_longitude, p_observacao);

  RETURN jsonb_build_object('ok', true, 'avancou', true);
END;
$$;
REVOKE ALL ON FUNCTION public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid) TO authenticated;

-- ──────── 208_avisos_pelo_servidor.sql ────────
-- 208_avisos_pelo_servidor.sql
-- Lote 2026-10, onda F. Idempotente. Bloco 1. Depende da 202 (fila avisos_telegram).
--
-- Por quê (docs/13, H10 e H12; comando, onda F, item 3): o alerta de check-in e o aviso de
-- presença iam ao Telegram uma vez por navegador aberto. Com estas funções o navegador
-- só pede o enfileiramento do alerta de check-in; a chave única por evento garante uma
-- mensagem, e o envio é do banco (202). Sem o envio pelo banco configurado, as funções devolvem
-- enfileirado = false e o app continua pelo /api/telegram, como antes.
-- Presença: vai com foto pelo /api/telegram, mas só uma vez por presença, mesmo com
-- várias abas abertas: reservar_aviso_presenca() grava a reserva no banco e só o primeiro
-- navegador recebe true (a fila do banco manda só texto e perderia a foto).

CREATE OR REPLACE FUNCTION public.enfileirar_alerta_checkin(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; e record; v_ultima timestamptz; v_atraso int; v_ok boolean;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(p_escolta_id) THEN
    RAISE EXCEPTION 'Sem permissao para esta escolta.';
  END IF;
  SELECT es.id, es.codigo_escolta, es.status, es.periodicidade_checkin_min, c.nome_cliente INTO e
  FROM public.escoltas es JOIN public.clientes c ON c.id = es.cliente_id WHERE es.id = p_escolta_id;
  IF e.id IS NULL OR e.periodicidade_checkin_min IS NULL
     OR e.status NOT IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando') THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem check-in periodico');
  END IF;
  -- Regra antiga (pendência 0.3 de docs/12): qualquer PARADA zera o prazo; sem nenhuma, não notifica.
  SELECT max(pc.data_hora) INTO v_ultima
  FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
  WHERE ev.escolta_id = p_escolta_id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760';
  IF v_ultima IS NULL THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem parada'); END IF;
  v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - e.periodicidade_checkin_min;
  IF v_atraso < 1 THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'em dia'); END IF;
  -- Uma mensagem por período vencido sem check-in (chave: escolta, última parada e
  -- número do período). Antes saía uma a cada 5 min por navegador aberto.
  v_ok := public._enfileirar_aviso('checkin:' || p_escolta_id || ':' || extract(epoch FROM v_ultima)::bigint
                                   || ':' || floor(v_atraso::numeric / e.periodicidade_checkin_min)::int, 'cliente', p_escolta_id,
    '<b>Alerta: check-in em atraso</b>' || E'\n'
    || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(e.nome_cliente) || E'\n'
    || 'Sem check-in há ' || (v_atraso + e.periodicidade_checkin_min) || ' minutos (periodicidade de '
    || e.periodicidade_checkin_min || ' min).' || E'\n'
    || 'Registrado em ' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (Brasília)');
  RETURN jsonb_build_object('enfileirado', v_ok);
END;
$$;

CREATE TABLE IF NOT EXISTS public.avisos_reservados (
  chave        text PRIMARY KEY,
  reservado_em timestamptz NOT NULL DEFAULT now(),
  usuario_id   uuid
);
ALTER TABLE public.avisos_reservados ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.avisos_reservados FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.reservar_aviso_presenca(p_presenca_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; v_esc uuid; v_n int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  SELECT escolta_id INTO v_esc FROM public.presencas WHERE id = p_presenca_id;
  IF v_esc IS NULL THEN RETURN false; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(v_esc) THEN
    RETURN false;
  END IF;
  INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES ('presenca:' || p_presenca_id, public.get_meu_usuario_id())
  ON CONFLICT (chave) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n = 1;
END;
$$;
REVOKE ALL ON FUNCTION public.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reservar_aviso_presenca(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enfileirar_alerta_checkin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reservar_aviso_presenca(uuid) TO authenticated;

-- ──────── 209_historico_sem_trigger.sql ────────
-- 209_historico_sem_trigger.sql
-- Lote 2026-10, onda F. Idempotente. Bloco 1.
--
-- Por quê (docs/13, B10): a trigger tr_registrar_historico_status, que gravava o histórico
-- em dobro junto do app, já foi removida de produção, mas a remoção não estava versionada:
-- recriar o banco pelas migrations a traria de volta. Sem efeito em produção.
DROP TRIGGER IF EXISTS tr_registrar_historico_status ON public.escoltas;
COMMENT ON FUNCTION public.registrar_historico_status_escolta() IS
  'OBSOLETA: sem trigger desde antes de 08/10/2026 (remoção versionada na 209). O histórico é gravado pela RPC registrar_etapa_escolta (207) e pelo app.';

-- ──────── 211_central_avisos.sql ────────
-- 211_central_avisos.sql
-- Lote 2026-10, onda J (adendo 01, item 4.2). Idempotente. Bloco 1 (antes do deploy;
-- compatível com o código da master 2b3fff9, que não lê nem grava em notificacoes:
-- conferido por git grep; só as RPCs da 204, do bloco 2, gravam nela).
--
-- Por quê (docs/14, seção 11.2): a tabela notificacoes passa a ser a central de avisos de
-- cada pessoa (sino com não lidas, página Avisos, aviso de 2 segundos). Hoje ela não tem
-- data de leitura, texto nem chave de evento; a policy notificacoes_escrita é FOR ALL
-- (destinatário e gestão podiam apagar), a gestão lia a caixa de todos e o anon tinha
-- TRUNCATE (que não passa por RLS).
--
-- O que faz:
-- 1. Schema lote_interno, fora dos schemas expostos pelo PostgREST, para as funções
--    internas do adendo. Nenhuma função dele é executável por anon ou authenticated
--    (default privileges sem EXECUTE para PUBLIC e REVOKE explícito em cada função).
-- 2. Colunas lida_em, titulo, texto e evento_chave; gatilho que mantém lida e lida_em
--    em acordo nos dois sentidos (a marcar_aviso_lido da 204 faz SET lida = true e
--    continua valendo); índice único (evento_chave, usuario_dest_id): uma linha por
--    destinatário por evento.
-- 3. Tipos novos em dom_tipos_evento (check-in vencido e as ações da onda I e da L).
-- 4. lote_interno.notificar: grava o aviso, sem depender de auth.uid() (roda pelo cron).
-- 5. RPCs do app: meus_avisos, contar_avisos_nao_lidos e marcar_todos_lidos.
-- 6. RLS: cada um lê só a própria caixa (decisão S5); nenhuma escrita direta (sem
--    INSERT, UPDATE, DELETE nem TRUNCATE para anon e authenticated); toda escrita por
--    função SECURITY DEFINER.
-- Reversão: 211_central_avisos_reverter.sql (depois da 217 e da 212).

-- 1. Schema interno.
CREATE SCHEMA IF NOT EXISTS lote_interno;
REVOKE ALL ON SCHEMA lote_interno FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA lote_interno REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
COMMENT ON SCHEMA lote_interno IS
  'Lote 2026-10 (adendo 01): funções internas (cron e RPCs SECURITY DEFINER). Fora do PostgREST; nenhuma função executável por anon ou authenticated.';

-- 2. Colunas da central.
ALTER TABLE public.notificacoes
  ADD COLUMN IF NOT EXISTS lida_em      timestamptz,
  ADD COLUMN IF NOT EXISTS titulo       text,
  ADD COLUMN IF NOT EXISTS texto        text,
  ADD COLUMN IF NOT EXISTS evento_chave text;

-- Avisos já gravados pela 204 (título e texto no payload; lidos sem data de leitura).
UPDATE public.notificacoes
   SET titulo = coalesce(titulo, payload ->> 'titulo'),
       texto  = coalesce(texto, payload ->> 'texto'),
       lida_em = CASE WHEN lida AND lida_em IS NULL THEN criado_em ELSE lida_em END
 WHERE (titulo IS NULL AND payload ? 'titulo') OR (texto IS NULL AND payload ? 'texto') OR (lida AND lida_em IS NULL);

CREATE OR REPLACE FUNCTION lote_interno.sincronizar_lida() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  NEW.lida := coalesce(NEW.lida, false);
  IF TG_OP = 'INSERT' THEN
    IF NEW.lida_em IS NOT NULL THEN NEW.lida := true;
    ELSIF NEW.lida THEN NEW.lida_em := now();
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.lida_em IS DISTINCT FROM OLD.lida_em THEN
    NEW.lida := NEW.lida_em IS NOT NULL;             -- quem mexeu na data de leitura manda
  ELSIF NEW.lida IS DISTINCT FROM coalesce(OLD.lida, false) THEN
    NEW.lida_em := CASE WHEN NEW.lida THEN now() END; -- caminho da 204: SET lida = true
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.sincronizar_lida() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tr_notificacoes_sincronizar_lida ON public.notificacoes;
CREATE TRIGGER tr_notificacoes_sincronizar_lida BEFORE INSERT OR UPDATE OF lida, lida_em ON public.notificacoes
  FOR EACH ROW EXECUTE FUNCTION lote_interno.sincronizar_lida();

CREATE UNIQUE INDEX IF NOT EXISTS notificacoes_evento_destinatario_uk
  ON public.notificacoes (evento_chave, usuario_dest_id) WHERE evento_chave IS NOT NULL;
-- Caixa de cada pessoa, da mais nova para a mais antiga (lista e contador).
CREATE INDEX IF NOT EXISTS idx_notificacoes_caixa
  ON public.notificacoes (usuario_dest_id, criado_em DESC);

-- 3. Tipos novos.
INSERT INTO public.dom_tipos_evento (codigo, nome_exibicao, gera_notificacao, ativo)
SELECT v.codigo, v.nome, true, true
FROM (VALUES ('checkin_vencido', 'Check-in vencido'),
             ('edicao_escolta', 'Escolta editada pela gestão'),
             ('reset_escolta', 'Escolta reiniciada pela gestão'),
             ('conclusao_antecipada', 'Conclusão antecipada'),
             ('arquivamento_escolta', 'Escolta arquivada'),
             ('recuperacao_escolta', 'Escolta recuperada do arquivo'),
             ('conflito_offline', 'Registro offline em conflito')) v(codigo, nome)
WHERE NOT EXISTS (SELECT 1 FROM public.dom_tipos_evento d WHERE d.codigo = v.codigo);

-- 4. Gravação de aviso (interna). Uma linha por destinatário; com chave, a mesma chave
--    para a mesma pessoa não grava de novo. Devolve quantas linhas entraram.
CREATE OR REPLACE FUNCTION lote_interno.notificar(p_chave text, p_escolta_id uuid, p_tipo text, p_usuarios uuid[],
                                                  p_titulo text, p_texto text, p_extra jsonb DEFAULT NULL)
    RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_tipo uuid; v_n int;
BEGIN
  SELECT id INTO v_tipo FROM public.dom_tipos_evento WHERE codigo = p_tipo;
  IF v_tipo IS NULL THEN RAISE EXCEPTION 'Tipo de aviso desconhecido: %', p_tipo; END IF;
  -- notificacoes.escolta_id é NOT NULL (com FK em cascata): aviso sem escolta não é gravado.
  -- A onda L (conflito de escolta apagada) precisa tratar isso na própria migration.
  IF p_escolta_id IS NULL THEN
    RAISE WARNING 'lote_interno.notificar: aviso % sem escolta não gravado (notificacoes exige escolta_id).', p_tipo;
    RETURN 0;
  END IF;
  IF p_usuarios IS NULL THEN RETURN 0; END IF;
  INSERT INTO public.notificacoes (escolta_id, canal, tipo_evento_id, destino, payload, usuario_dest_id, status_envio,
                                   titulo, texto, evento_chave)
  SELECT p_escolta_id, 'app', v_tipo, 'app',
         jsonb_build_object('titulo', p_titulo, 'texto', p_texto) || coalesce(p_extra, '{}'::jsonb),
         u, 'enviada', p_titulo, p_texto, p_chave
  FROM (SELECT DISTINCT u FROM unnest(p_usuarios) AS u WHERE u IS NOT NULL) d
  ON CONFLICT (evento_chave, usuario_dest_id) WHERE evento_chave IS NOT NULL DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.notificar(text, uuid, text, uuid[], text, text, jsonb) FROM PUBLIC, anon, authenticated;

-- 5. RPCs do app. Cada um só vê e marca os próprios avisos.
--    Paginação por cursor (criado_em, id): os avisos gravados numa mesma execução do cron
--    têm o mesmo criado_em, e o corte só pela data pulava os que ficavam na página seguinte.
--    Versões anteriores desta branch (sem p_antes_id e marcar_todos_lidos sem escolta) saem
--    antes, para não ficarem duas assinaturas.
DROP FUNCTION IF EXISTS public.meus_avisos(text, uuid, boolean, integer, timestamptz);
DROP FUNCTION IF EXISTS public.marcar_todos_lidos(text);
CREATE OR REPLACE FUNCTION public.meus_avisos(p_tipo text DEFAULT NULL, p_escolta_id uuid DEFAULT NULL,
                                              p_so_nao_lidas boolean DEFAULT false, p_limite integer DEFAULT 50,
                                              p_antes timestamptz DEFAULT NULL, p_antes_id uuid DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_eu uuid; v jsonb;
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  v_eu := public.get_meu_usuario_id();
  SELECT coalesce(jsonb_agg(x.j ORDER BY x.criado_em DESC, x.id DESC), '[]'::jsonb) INTO v
  FROM (
    SELECT n.id, n.criado_em,
           jsonb_build_object('id', n.id, 'escolta_id', n.escolta_id, 'codigo', e.codigo_escolta,
                              'tipo', t.codigo, 'tipo_nome', t.nome_exibicao,
                              'titulo', coalesce(n.titulo, n.payload ->> 'titulo', t.nome_exibicao),
                              'texto', coalesce(n.texto, n.payload ->> 'texto'),
                              'criado_em', n.criado_em, 'lida_em', n.lida_em) AS j
    FROM public.notificacoes n
    JOIN public.dom_tipos_evento t ON t.id = n.tipo_evento_id
    LEFT JOIN public.escoltas e ON e.id = n.escolta_id
    WHERE n.usuario_dest_id = v_eu AND n.canal = 'app'
      AND (p_tipo IS NULL OR t.codigo = p_tipo)
      AND (p_escolta_id IS NULL OR n.escolta_id = p_escolta_id)
      AND (NOT coalesce(p_so_nao_lidas, false) OR n.lida IS NOT TRUE)
      AND (p_antes IS NULL
           OR (n.criado_em, n.id) < (p_antes, coalesce(p_antes_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
    ORDER BY n.criado_em DESC, n.id DESC
    LIMIT least(greatest(coalesce(p_limite, 50), 1), 200)
  ) x;
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.contar_avisos_nao_lidos() RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  RETURN (SELECT count(*) FROM public.notificacoes
          WHERE usuario_dest_id = public.get_meu_usuario_id() AND canal = 'app' AND lida IS NOT TRUE);
END;
$$;

-- Marcar todas respeita os filtros da Central: tipo e escolta (nulos = todos).
CREATE OR REPLACE FUNCTION public.marcar_todos_lidos(p_tipo text DEFAULT NULL, p_escolta_id uuid DEFAULT NULL) RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n int;
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  UPDATE public.notificacoes n SET lida_em = now()
   WHERE n.usuario_dest_id = public.get_meu_usuario_id() AND n.canal = 'app' AND n.lida IS NOT TRUE
     AND (p_tipo IS NULL OR n.tipo_evento_id = (SELECT id FROM public.dom_tipos_evento WHERE codigo = p_tipo))
     AND (p_escolta_id IS NULL OR n.escolta_id = p_escolta_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['meus_avisos(text, uuid, boolean, integer, timestamptz, uuid)', 'contar_avisos_nao_lidos()',
                           'marcar_todos_lidos(text, uuid)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- 6. RLS e privilégios: leitura só da própria caixa; nenhuma escrita direta.
DROP POLICY IF EXISTS notificacoes_escrita ON public.notificacoes;
DROP POLICY IF EXISTS notificacoes_insert_so_gestao ON public.notificacoes;   -- 197, fica sem objeto
DROP POLICY IF EXISTS notificacoes_update_restrita ON public.notificacoes;    -- 197, fica sem objeto
DROP POLICY IF EXISTS notificacoes_select ON public.notificacoes;
CREATE POLICY notificacoes_select ON public.notificacoes FOR SELECT TO authenticated
  USING (usuario_dest_id = (SELECT public.get_meu_usuario_id()));
REVOKE ALL ON public.notificacoes FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.notificacoes FROM authenticated;

-- Conferência:
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'notificacoes'
--   AND column_name IN ('lida_em','titulo','texto','evento_chave');                         -- 4
-- SELECT polname FROM pg_policy WHERE polrelid = 'public.notificacoes'::regclass;            -- notificacoes_select
-- SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lote_interno'
--   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE')); -- 0
-- SELECT has_table_privilege('anon', 'public.notificacoes', 'SELECT'),
--        has_table_privilege('authenticated', 'public.notificacoes', 'DELETE');               -- false, false

-- ──────── 212_aviso_checkin_servidor.sql ────────
-- 212_aviso_checkin_servidor.sql
-- Lote 2026-10, onda J. Idempotente. Bloco 1, depois da 211 (usa lote_interno.notificar) e
-- da 208 (reescreve enfileirar_alerta_checkin). Compatível com a master: o código antigo
-- não chama nada daqui, e com a periodicidade nula em todas as escoltas abertas (201) o
-- cron não gera nada até um cliente ter a chave de check-in.
--
-- Por quê (docs/14, seção 11.3; decisões S2, S3 e S4): o aviso de check-in vencido era
-- calculado em cada navegador aberto (N+2 consultas por escolta por minuto) e o Telegram
-- dependia de haver navegador aberto. Agora o banco calcula uma vez por minuto (pg_cron),
-- grava o aviso na central de cada destinatário e enfileira o Telegram.
--
-- Regra (porte de minutosAteCheckin, lib/checkin.ts): status em STATUS_COM_CHECKIN, com
-- periodicidade; referência = último ponto PARADA com observacoes JSON tipo
-- reporte_periodico, senão o primeiro ponto da escolta, senão a data prevista. Atraso com
-- o mesmo arredondamento da tela (-floor((periodicidade - decorrido) / 1 min)): o primeiro
-- aviso sai logo que a periodicidade vence (atraso 1, como o Painel e o detalhe mostram),
-- e os seguintes a cada periodicidade (período n cobre de n a n+1 periodicidades). Um
-- aviso por período vencido (S3): chave checkin:<escolta>:<epoch da referência>:<n>.
-- Destinatários (S2): efetivo da escolta, administrador, gestor, supervisor e central ativos.
-- Cada escolta do ciclo roda no próprio bloco BEGIN ... EXCEPTION: erro numa não desfaz
-- os avisos das outras, o Telegram nem a limpeza.
-- Telegram (S4): mesma regra e mesmo texto da 208 (regra antiga, pendência 0.3). Quem manda:
-- - o cron, só com o envio pelo banco ativo (avisos_pelo_banco_ativos) E
--   configuracao_avisos.checkin_telegram_pelo_cron ligada. A coluna nasce falsa aqui
--   (bloco 1) e a 217 (bloco 2, depois do deploy) a liga: até o deploy, quem manda é o
--   navegador da master (CheckinAlertProvider), e o cron não pode mandar junto (dobraria);
-- - fora disso (Vault sem segredo, pg_net ou pg_cron recusados, envio desligado), o
--   navegador de quem recebe o aviso (gestão ou equipe da escolta) pelo /api/telegram, como
--   a master fazia, mas só depois de reservar a chave do evento no banco por
--   reservar_alertas_checkin() (padrão da reservar_aviso_presenca da 208): uma mensagem por
--   evento, mesmo com vários navegadores abertos (item 6.2.3: não calar o Telegram de hoje).
-- A chave reservada pelo navegador e a enfileirada pelo cron são a mesma: quem chega
-- depois não manda (troca de caminho sem mensagem dobrada).
-- enfileirar_alerta_checkin (208) continua para o app e passa a delegar à função interna
-- depois da guarda de perfil.
-- Arquivamento e anulação (onda I) não existem aqui: a 214 recria gerar_avisos_checkin
-- com os dois filtros.
-- Limpeza: avisos lidos há mais de 90 dias são apagados pelo mesmo cron.

-- Quem manda o Telegram do check-in (ver o cabeçalho). Falsa até a 217 (bloco 2).
ALTER TABLE public.configuracao_avisos
  ADD COLUMN IF NOT EXISTS checkin_telegram_pelo_cron boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.configuracao_avisos.checkin_telegram_pelo_cron IS
  'Lote 2026-10 (onda J): o cron enfileira o Telegram do check-in vencido. Ligada pela 217 (bloco 2), depois do deploy; antes, o navegador da master manda.';

-- Tipo da observação JSON do ponto; texto legado ou JSON quebrado nunca derruba o cron.
CREATE OR REPLACE FUNCTION lote_interno.tipo_da_observacao(p_obs text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF p_obs IS NULL OR left(ltrim(p_obs), 1) <> '{' THEN RETURN NULL; END IF;
  RETURN p_obs::jsonb ->> 'tipo';
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.tipo_da_observacao(text) FROM PUBLIC, anon, authenticated;

-- Telegram do check-in: corpo da 208 sem a guarda de perfil (o cron roda sem usuário).
CREATE OR REPLACE FUNCTION lote_interno.enfileirar_alerta_checkin(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE e record; v_ultima timestamptz; v_atraso int; v_ok boolean; v_chave text;
BEGIN
  SELECT es.id, es.codigo_escolta, es.status, es.periodicidade_checkin_min, c.nome_cliente INTO e
  FROM public.escoltas es JOIN public.clientes c ON c.id = es.cliente_id WHERE es.id = p_escolta_id;
  IF e.id IS NULL OR e.periodicidade_checkin_min IS NULL
     OR e.status NOT IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando') THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem check-in periodico');
  END IF;
  -- Regra antiga (pendência 0.3 de docs/12): qualquer PARADA zera o prazo; sem nenhuma, não notifica.
  SELECT max(pc.data_hora) INTO v_ultima
  FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
  WHERE ev.escolta_id = p_escolta_id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760';
  IF v_ultima IS NULL THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem parada'); END IF;
  v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - e.periodicidade_checkin_min;
  IF v_atraso < 1 THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'em dia'); END IF;
  -- Uma mensagem por período vencido sem check-in (chave: escolta, última parada e
  -- número do período).
  v_chave := 'checkin:' || p_escolta_id || ':' || extract(epoch FROM v_ultima)::bigint
             || ':' || floor(v_atraso::numeric / e.periodicidade_checkin_min)::int;
  -- Já mandada por um navegador (reservar_alertas_checkin): não manda de novo.
  IF EXISTS (SELECT 1 FROM public.avisos_reservados WHERE chave = v_chave) THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'enviado pelo navegador');
  END IF;
  v_ok := public._enfileirar_aviso(v_chave, 'cliente', p_escolta_id,
    '<b>Alerta: check-in em atraso</b>' || E'\n'
    || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(e.nome_cliente) || E'\n'
    || 'Sem check-in há ' || (v_atraso + e.periodicidade_checkin_min) || ' minutos (periodicidade de '
    || e.periodicidade_checkin_min || ' min).' || E'\n'
    || 'Registrado em ' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (Brasília)');
  RETURN jsonb_build_object('enfileirado', v_ok);
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon, authenticated;

-- RPC da 208 (o app ainda pode chamar): guarda de perfil e delega.
CREATE OR REPLACE FUNCTION public.enfileirar_alerta_checkin(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(p_escolta_id) THEN
    RAISE EXCEPTION 'Sem permissão para esta escolta.';
  END IF;
  RETURN lote_interno.enfileirar_alerta_checkin(p_escolta_id);
END;
$$;
REVOKE ALL ON FUNCTION public.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enfileirar_alerta_checkin(uuid) TO authenticated;

-- Telegram do check-in pelo navegador, quando o cron não manda (ver o cabeçalho). Devolve as
-- escoltas cujo alerta este navegador acabou de reservar, com o que a mensagem antiga leva
-- (mesmo texto e destino da master: /api/telegram com escolta_id, chat do cliente). Só a
-- gestão (todas as escoltas) e a equipe (as próprias) recebem algo; a chave é a mesma do
-- cron, e só o primeiro navegador a reserva.
CREATE OR REPLACE FUNCTION public.reservar_alertas_checkin() RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text; v_eu uuid; v_gestao boolean; r record; v_ultima timestamptz; v_atraso int;
  v_chave text; v_n int; v_saida jsonb := '[]'::jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  -- O cron manda: nada para o navegador.
  IF public.avisos_pelo_banco_ativos()
     AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false) THEN
    RETURN v_saida;
  END IF;
  v_eu := public.get_meu_usuario_id();
  v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
  FOR r IN
    SELECT e.id, e.codigo_escolta, e.status, e.periodicidade_checkin_min AS per, c.nome_cliente
    FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
    WHERE e.periodicidade_checkin_min > 0
      AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
      AND (v_gestao OR public.sou_do_efetivo(e.id))
  LOOP
    -- Regra antiga (pendência 0.3), a mesma de lote_interno.enfileirar_alerta_checkin.
    SELECT max(pc.data_hora) INTO v_ultima
    FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
    WHERE ev.escolta_id = r.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760';
    CONTINUE WHEN v_ultima IS NULL;
    v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - r.per;
    CONTINUE WHEN v_atraso < 1;
    v_chave := 'checkin:' || r.id || ':' || extract(epoch FROM v_ultima)::bigint || ':' || floor(v_atraso::numeric / r.per)::int;
    -- Já enfileirada pelo cron (envio pelo banco ligado há pouco): não manda de novo.
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.avisos_telegram WHERE evento_chave = v_chave);
    INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES (v_chave, v_eu) ON CONFLICT (chave) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    CONTINUE WHEN v_n = 0;
    v_saida := v_saida || jsonb_build_object(
      'escolta_id', r.id, 'codigo', r.codigo_escolta, 'cliente', r.nome_cliente, 'status', r.status,
      'atraso_min', v_atraso, 'periodicidade_min', r.per,
      'efetivos', coalesce((SELECT jsonb_agg(v.nome_completo || coalesce(' (' || ee.papel_na_escolta || ')', '') ORDER BY ee.papel_na_escolta, v.nome_completo)
                            FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
                            WHERE ee.escolta_id = r.id), '[]'::jsonb));
  END LOOP;
  RETURN v_saida;
END;
$$;
REVOKE ALL ON FUNCTION public.reservar_alertas_checkin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reservar_alertas_checkin() TO authenticated;

-- Ciclo do cron. p_agora existe só para o teste avançar o relógio; o cron usa now().
CREATE OR REPLACE FUNCTION lote_interno.gerar_avisos_checkin(p_agora timestamptz DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  r record; v_gestao uuid[]; v_n int := 0; v_decorrido numeric; v_atraso int; v_periodo int; v_telegram boolean;
BEGIN
  SELECT coalesce(array_agg(u.id), '{}') INTO v_gestao
  FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor', 'central');
  v_telegram := public.avisos_pelo_banco_ativos()
                AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false);

  FOR r IN
    SELECT e.id, e.codigo_escolta, e.periodicidade_checkin_min AS per, c.nome_cliente,
           coalesce(
             (SELECT max(pc.data_hora) FROM public.pontos_controle pc
                JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
               WHERE ev.escolta_id = e.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
                 AND lote_interno.tipo_da_observacao(pc.observacoes) = 'reporte_periodico'),
             (SELECT min(pc.data_hora) FROM public.pontos_controle pc
                JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
               WHERE ev.escolta_id = e.id),
             e.data_hora_prevista) AS referencia
    FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
    WHERE e.periodicidade_checkin_min > 0
      AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
  LOOP
    -- Aviso na central: erro numa escolta (usuário apagado entre a leitura e o INSERT, tipo
    -- ausente) fica nela e vira WARNING; o ciclo segue.
    BEGIN
      IF r.referencia IS NOT NULL THEN
        v_decorrido := extract(epoch FROM (p_agora - r.referencia));
        -- Mesmo arredondamento de minutosAteCheckin: atraso = -floor((per*60 - decorrido) / 60).
        v_atraso := -floor((r.per * 60 - v_decorrido) / 60)::int;
        IF v_atraso >= 1 THEN
          -- Período n: de n a n+1 periodicidades decorridas (o 1º vence com a periodicidade).
          v_periodo := ceil(v_decorrido / (r.per * 60))::int - 1;
          v_n := v_n + lote_interno.notificar(
            'checkin:' || r.id || ':' || floor(extract(epoch FROM r.referencia))::bigint || ':' || v_periodo,
            r.id, 'checkin_vencido',
            ARRAY(SELECT v.usuario_id FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
                   WHERE ee.escolta_id = r.id AND v.usuario_id IS NOT NULL) || v_gestao,
            'Check-in atrasado: ' || r.codigo_escolta,
            'Escolta ' || r.codigo_escolta || ' · ' || r.nome_cliente || ': sem check-in há ' || (v_atraso + r.per)
              || ' min (periodicidade de ' || r.per || ' min, ' || v_atraso || ' min de atraso). Prazo vencido em '
              || to_char((r.referencia + make_interval(mins => r.per * v_periodo)) AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
              || ' (Brasília).',
            jsonb_build_object('referencia', r.referencia, 'periodo', v_periodo, 'periodicidade_min', r.per));
        END IF;
      END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'gerar_avisos_checkin: aviso da escolta % falhou: %', r.id, SQLERRM;
    END;
    -- Telegram pela regra antiga (a função decide); erro numa escolta não para o ciclo.
    IF v_telegram THEN
      BEGIN
        PERFORM lote_interno.enfileirar_alerta_checkin(r.id);
      EXCEPTION WHEN others THEN
        RAISE WARNING 'gerar_avisos_checkin: Telegram da escolta % falhou: %', r.id, SQLERRM;
      END;
    END IF;
  END LOOP;

  DELETE FROM public.notificacoes WHERE lida AND lida_em < p_agora - interval '90 days';
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.gerar_avisos_checkin(timestamptz) FROM PUBLIC, anon, authenticated;

-- Agendamento a cada minuto (só com pg_cron). cron.schedule com o mesmo nome atualiza.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    EXECUTE $q$SELECT cron.schedule('lote2026_avisos_checkin', '* * * * *', 'SELECT lote_interno.gerar_avisos_checkin();')$q$;
  END IF;
END $$;

-- Conferência:
-- SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'lote2026_avisos_checkin';   -- 1 linha
-- SELECT checkin_telegram_pelo_cron FROM configuracao_avisos;   -- false até a 217 (bloco 2)
-- SELECT lote_interno.gerar_avisos_checkin();   -- 0 enquanto nenhuma escolta aberta tiver periodicidade
-- SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lote_interno'
--   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE')); -- 0


-- ──────── 213_poder_total_estrutura.sql ────────
-- 213_poder_total_estrutura.sql
-- Lote 2026-10, onda I (adendo 01, item 4.3). Idempotente. Bloco 1, depois da 212.
-- Aditiva e compatível com a master 2b3fff9: só acrescenta colunas com padrão, tabelas,
-- view e triggers que preenchem ou recusam valores que o código antigo nunca manda.
--
-- Por quê (docs/14, seção 12.2): gestor e administrador passam a voltar etapa, zerar,
-- concluir com pendências e arquivar escoltas. Nada é apagado: os registros de campo da
-- etapa desfeita ficam ANULADOS (marcados), e as telas e o banco passam a contar só os
-- válidos. Esta migration cria só a estrutura; as travas vêm na 214 e as RPCs na 218.
--
-- O que faz:
-- 1. escoltas: arquivada_em, arquivada_por, motivo_arquivamento, reiniciada_em (S15) e
--    versao_gestao (incrementada só por voltar etapa, zerar, concluir antes, arquivar e
--    recuperar; nunca pela edição). ADD COLUMN com padrão constante não reescreve a linha
--    nem dispara trigger: ESC-2026-0001 e ESC-2026-0007 não mudam (atualizado_em igual).
-- 2. Anulação (anulado_em, anulado_por, motivo_anulacao, anulacao_id) nas 9 tabelas de
--    campo; fotos e checklist_respostas herdam do pai.
-- 3. Carimbo de etapa status_escolta_no_registro, preenchido por trigger BEFORE INSERT com
--    o status da escolta no momento (o valor mandado pelo cliente é ignorado).
-- 4. escolta_resets (histórico das voltas de etapa e zerar, com os valores guardados).
-- 5. escolta_conclusoes_antecipadas e vw_pendencias_conclusao (uma linha por item).
-- 6. Trava das colunas da gestão (tr_travar_colunas_gestao_<tabela>): UPDATE de anulado_*,
--    arquivada_*, versao_gestao, reiniciada_em, status_escolta_no_registro e via_rpc só com
--    a variável de transação escolta.rpc_gestao ligada E perfil administrador ou gestor
--    (dupla guarda: ligar a variável sozinho não basta), ou sem usuário final (auth.uid()
--    nulo: migrations, SQL Editor e cron). No INSERT, recusa só valor diferente do padrão
--    (nulo e 0 passam); o carimbo fica fora da trava de INSERT (é a trigger da 213.3 que o
--    preenche), e a ordem entre as duas triggers não importa.
-- 7. escolta_status_historico.via_rpc, ligada pela variável escolta.historico_rpc (as RPCs
--    a ligam: registrar_etapa_escolta na 214 e as da 218). Linha gravada direto pelo
--    cliente fica false. A anulação por janela de tempo usa só linhas via_rpc.
-- 8. pontos_controle.lancado_por nulo vira o usuário da sessão (a master pode mandar
--    user?.id nulo com sessão válida; a policy da 214 confere o autor depois disto).
--    Ponto já gravado não muda de autor nem de horário (revisão adversarial I, menor 8):
--    UPDATE de lancado_por e data_hora em pontos_controle entra na mesma trava do item 6
--    (só as RPCs da gestão, ou sem usuário final). A master nunca faz UPDATE de ponto.
-- A central lê a conclusão antecipada e a lista de pendências da escolta que vê (revisão
-- adversarial I, médio 4; adendo 4.3.6: a lista aparece na tela da escolta e no relatório
-- para quem vê a escolta). A tela "Pendências de conclusão" continua supervisor ou acima.
-- Chaves estrangeiras de anulado_por, arquivada_por, concluida_por e feito_por para
-- usuarios SEM ação (18.8, item 7): excluir quem anulou ou arquivou é recusado.
-- Reversão: 213_poder_total_estrutura_reverter.sql (depois da 214), que guarda as colunas
-- novas e as tabelas em backup_20261008 antes de remover.

-- 1. Arquivamento, reinício e versão da gestão.
ALTER TABLE public.escoltas
  ADD COLUMN IF NOT EXISTS arquivada_em        timestamptz,
  ADD COLUMN IF NOT EXISTS arquivada_por       uuid REFERENCES public.usuarios(id),
  ADD COLUMN IF NOT EXISTS motivo_arquivamento text,
  ADD COLUMN IF NOT EXISTS reiniciada_em       timestamptz,
  ADD COLUMN IF NOT EXISTS versao_gestao       integer NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_escoltas_nao_arquivadas
  ON public.escoltas (status, data_hora_prevista) WHERE arquivada_em IS NULL;
COMMENT ON COLUMN public.escoltas.arquivada_em IS 'Lote 2026-10 (onda I): arquivada pela gestão (some das listas, do mural, do Campo e dos indicadores). Só pela RPC arquivar_escolta.';
COMMENT ON COLUMN public.escoltas.reiniciada_em IS 'Lote 2026-10 (onda I, S15): última vez que a gestão zerou a escolta para agendada.';
COMMENT ON COLUMN public.escoltas.versao_gestao IS 'Lote 2026-10 (onda I): +1 a cada voltar etapa, zerar, concluir antes, arquivar e recuperar. A edição não muda. Usada pela onda L para detectar conflito.';

-- 2 e 3. Anulação e carimbo de etapa nas tabelas de campo.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico']
  LOOP
    EXECUTE format('ALTER TABLE public.%I
      ADD COLUMN IF NOT EXISTS anulado_em timestamptz,
      ADD COLUMN IF NOT EXISTS anulado_por uuid REFERENCES public.usuarios(id),
      ADD COLUMN IF NOT EXISTS motivo_anulacao text,
      ADD COLUMN IF NOT EXISTS anulacao_id uuid,
      ADD COLUMN IF NOT EXISTS status_escolta_no_registro text', t);
    EXECUTE format('COMMENT ON COLUMN public.%I.anulado_em IS %L', t,
      'Lote 2026-10 (onda I): registro anulado pela gestão (voltar etapa ou zerar). Não é apagado; não conta como válido.');
    EXECUTE format('COMMENT ON COLUMN public.%I.status_escolta_no_registro IS %L', t,
      'Lote 2026-10 (onda I): status da escolta quando o registro foi gravado (trigger; o valor do cliente é ignorado). Nulo nos registros anteriores à 213.');
  END LOOP;
END $$;
CREATE INDEX IF NOT EXISTS idx_anulacao_pontos ON public.pontos_controle (anulacao_id) WHERE anulacao_id IS NOT NULL;

-- 7. Histórico gravado por RPC.
ALTER TABLE public.escolta_status_historico ADD COLUMN IF NOT EXISTS via_rpc boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.escolta_status_historico.via_rpc IS
  'Lote 2026-10 (onda I): true quando a linha foi gravada por uma RPC do servidor (variável escolta.historico_rpc). Linhas do cliente ficam false e não servem de âncora para a anulação.';

-- 3 e 7. Carimbo (BEFORE INSERT). SECURITY DEFINER: lê o status mesmo de escolta que a RLS
-- de quem grava esconderia.
CREATE OR REPLACE FUNCTION lote_interno.carimbar_etapa() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_j jsonb := to_jsonb(NEW); v_esc uuid; v_status text;
BEGIN
  IF v_j ? 'escolta_id' THEN
    v_esc := (v_j ->> 'escolta_id')::uuid;
  ELSE
    SELECT ev.escolta_id INTO v_esc FROM public.escolta_veiculos ev WHERE ev.id = (v_j ->> 'escolta_veiculo_id')::uuid;
  END IF;
  SELECT e.status INTO v_status FROM public.escoltas e WHERE e.id = v_esc;
  NEW.status_escolta_no_registro := v_status;
  IF TG_TABLE_NAME = 'escolta_status_historico' THEN
    NEW.via_rpc := coalesce(current_setting('escolta.historico_rpc', true), '') = 'on';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.carimbar_etapa() FROM PUBLIC, anon, authenticated;

-- 6. Trava das colunas da gestão (BEFORE INSERT OR UPDATE).
CREATE OR REPLACE FUNCTION lote_interno.travar_colunas_gestao() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_new jsonb := to_jsonb(NEW); v_old jsonb; v_cols text[]; c text;
BEGIN
  -- Sem usuário final (migration, SQL Editor, cron): passa, como na 197 e na 206.
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  -- Dupla guarda: variável de transação ligada pela RPC E perfil de quem chama.
  IF coalesce(current_setting('escolta.rpc_gestao', true), '') = 'on'
     AND public.get_meu_perfil() IN ('administrador', 'gestor') THEN
    RETURN NEW;
  END IF;
  IF TG_TABLE_NAME = 'escoltas' THEN
    v_cols := ARRAY['arquivada_em', 'arquivada_por', 'motivo_arquivamento', 'reiniciada_em', 'versao_gestao'];
  ELSE
    v_cols := ARRAY['anulado_em', 'anulado_por', 'motivo_anulacao', 'anulacao_id'];
  END IF;
  IF TG_OP = 'INSERT' THEN
    FOREACH c IN ARRAY v_cols LOOP
      IF (c = 'versao_gestao' AND coalesce((v_new ->> c)::int, 0) <> 0)
         OR (c <> 'versao_gestao' AND jsonb_typeof(v_new -> c) IS DISTINCT FROM 'null' AND v_new ? c) THEN
        RAISE EXCEPTION 'O campo % só é preenchido pelas ações da gestão.', c USING ERRCODE = '42501';
      END IF;
    END LOOP;
    RETURN NEW;
  END IF;
  v_old := to_jsonb(OLD);
  IF TG_TABLE_NAME <> 'escoltas' THEN
    v_cols := v_cols || ARRAY['status_escolta_no_registro'];
    IF v_new ? 'via_rpc' THEN v_cols := v_cols || ARRAY['via_rpc']; END IF;
    -- Em nome de quem fez e quando: ponto gravado não muda de autor nem de horário.
    IF TG_TABLE_NAME = 'pontos_controle' THEN v_cols := v_cols || ARRAY['lancado_por', 'data_hora']; END IF;
  END IF;
  FOREACH c IN ARRAY v_cols LOOP
    IF (v_new -> c) IS DISTINCT FROM (v_old -> c) THEN
      RAISE EXCEPTION 'O campo % só muda pelas ações da gestão.', c USING ERRCODE = '42501';
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.travar_colunas_gestao() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_carimbar_etapa_' || t, t);
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION lote_interno.carimbar_etapa()',
                   'tr_carimbar_etapa_' || t, t);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_travar_colunas_gestao_' || t, t);
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION lote_interno.travar_colunas_gestao()',
                   'tr_travar_colunas_gestao_' || t, t);
  END LOOP;
END $$;
DROP TRIGGER IF EXISTS tr_travar_colunas_gestao_escoltas ON public.escoltas;
CREATE TRIGGER tr_travar_colunas_gestao_escoltas BEFORE INSERT OR UPDATE ON public.escoltas
  FOR EACH ROW EXECUTE FUNCTION lote_interno.travar_colunas_gestao();

-- 8. Autor do ponto preenchido no servidor quando vier nulo.
CREATE OR REPLACE FUNCTION lote_interno.preencher_lancado_por() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF NEW.lancado_por IS NULL THEN NEW.lancado_por := public.get_meu_usuario_id(); END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.preencher_lancado_por() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_preencher_lancado_por ON public.pontos_controle;
CREATE TRIGGER tr_preencher_lancado_por BEFORE INSERT ON public.pontos_controle
  FOR EACH ROW EXECUTE FUNCTION lote_interno.preencher_lancado_por();

-- 4. Voltas de etapa e zerar.
CREATE TABLE IF NOT EXISTS public.escolta_resets (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id         uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  status_de          text NOT NULL,
  status_para        text NOT NULL,
  tipo               text NOT NULL CHECK (tipo IN ('voltar_etapa', 'zerar')),
  motivo             text NOT NULL,
  feito_por          uuid REFERENCES public.usuarios(id),
  feito_em           timestamptz NOT NULL DEFAULT now(),
  anulacao_id        uuid NOT NULL,
  valores_anteriores jsonb NOT NULL DEFAULT '{}'::jsonb,   -- KM por viatura, checklist_pendente_no_inicio, data_finalizacao, observacao_fechamento
  contagem           jsonb NOT NULL DEFAULT '{}'::jsonb    -- quantos registros foram anulados, por tabela
);
CREATE INDEX IF NOT EXISTS idx_escolta_resets_escolta ON public.escolta_resets (escolta_id, feito_em DESC);
ALTER TABLE public.escolta_resets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.escolta_resets FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.escolta_resets TO authenticated;
DROP POLICY IF EXISTS escolta_resets_leitura ON public.escolta_resets;
CREATE POLICY escolta_resets_leitura ON public.escolta_resets FOR SELECT TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor']));
COMMENT ON TABLE public.escolta_resets IS 'Lote 2026-10 (onda I): voltas de etapa e zerar feitos pela gestão. Escrita só pelas RPCs da 218.';

-- 5. Conclusão antecipada e pendências. Leitura: quem vê a escolta pela operação (gestão,
-- supervisão e central) e o efetivo dela; a view segue a RLS de quem lê (security_invoker).
CREATE TABLE IF NOT EXISTS public.escolta_conclusoes_antecipadas (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escolta_id        uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  status_no_momento text NOT NULL,
  motivo            text NOT NULL,
  concluida_por     uuid REFERENCES public.usuarios(id),
  concluida_em      timestamptz NOT NULL DEFAULT now(),
  pendencias        jsonb NOT NULL DEFAULT '[]'::jsonb,
  anulado_em        timestamptz,
  anulado_por       uuid REFERENCES public.usuarios(id),
  motivo_anulacao   text,
  anulacao_id       uuid
);
CREATE UNIQUE INDEX IF NOT EXISTS escolta_conclusoes_antecipadas_valida_uk
  ON public.escolta_conclusoes_antecipadas (escolta_id) WHERE anulado_em IS NULL;
ALTER TABLE public.escolta_conclusoes_antecipadas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.escolta_conclusoes_antecipadas FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.escolta_conclusoes_antecipadas TO authenticated;
DROP POLICY IF EXISTS escolta_conclusoes_leitura ON public.escolta_conclusoes_antecipadas;
CREATE POLICY escolta_conclusoes_leitura ON public.escolta_conclusoes_antecipadas FOR SELECT TO authenticated
  USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador', 'gestor', 'supervisor', 'central'])
         OR public.sou_do_efetivo(escolta_id));
COMMENT ON TABLE public.escolta_conclusoes_antecipadas IS
  'Lote 2026-10 (onda I): escolta concluída pela gestão antes do fim, com a lista do que não foi feito (calculada no servidor). Uma válida por escolta.';

-- Uma linha por item não feito (security_invoker: vale a RLS de quem lê).
CREATE OR REPLACE VIEW public.vw_pendencias_conclusao WITH (security_invoker = on) AS
SELECT c.id                              AS conclusao_id,
       c.escolta_id,
       e.codigo_escolta,
       e.cliente_id,
       et ->> 'etapa'                    AS etapa,
       et ->> 'rotulo'                   AS rotulo_etapa,
       (vt ->> 'escolta_veiculo_id')::uuid AS escolta_veiculo_id,
       vt ->> 'placa'                    AS placa,
       it.item,
       c.concluida_por,
       c.concluida_em,
       c.motivo                          AS observacao,
       c.status_no_momento
FROM public.escolta_conclusoes_antecipadas c
JOIN public.escoltas e ON e.id = c.escolta_id
CROSS JOIN LATERAL jsonb_array_elements(c.pendencias) et
CROSS JOIN LATERAL jsonb_array_elements(coalesce(et -> 'viaturas', '[]'::jsonb)) vt
CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(vt -> 'faltando', '[]'::jsonb)) AS it(item)
WHERE c.anulado_em IS NULL;
REVOKE ALL ON public.vw_pendencias_conclusao FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.vw_pendencias_conclusao TO authenticated;

-- Conferência:
-- SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND column_name = 'anulado_em';   -- 10 (9 tabelas + conclusões)
-- SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_carimbar_etapa_%';          -- 9
-- SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_travar_colunas_gestao_%';   -- 10
-- SELECT count(*) FROM escoltas WHERE versao_gestao <> 0 OR arquivada_em IS NOT NULL; -- 0

-- ──────── 214_poder_total_travas.sql ────────
-- 214_poder_total_travas.sql
-- Lote 2026-10, onda I (adendo 01, item 4.3). Idempotente. Bloco 1, depois da 213.
-- Compatível com a master 2b3fff9. O que a master grava em escolta iniciada (conferido no
-- código, revisão adversarial I, menor 16): em escoltas, status, data_finalizacao,
-- observacao_fechamento, checklist_pendente_no_inicio e periodicidade_checkin_min
-- ([id]/page.tsx:2010), todas colunas livres; em escolta_veiculos, KM de saída e de retorno
-- (gravarKmViaturas, :1714) e combustível, livres porque placa e escolta não mudam (nessa
-- condição a 214 libera qualquer coluna da viatura, como a letra da 12.3.3); pontos,
-- checklists e respostas, fotos, ocorrências, emergências e histórico (INSERT, sem trava de
-- edição). Não grava anulado nem arquivada e grava lancado_por com o próprio usuário; sem
-- arquivadas e sem anulados (nada disso existe antes da 218), os filtros novos não mudam
-- nenhum resultado. A trava de DELETE do item 6 só recusa o que a master nunca apaga
-- (registro anulado, que só existe depois da 218, e viatura com registro de campo).
--
-- Por quê (docs/14, seção 12.3; decisões S7, S8 e S10; 18.8, itens 6 e 7):
-- 1. validar_transicao_status_escolta ganha um ramo especial, antes do erro, para a volta
--    de etapa (reset) e a conclusão antecipada. Dupla guarda: variável de transação
--    escolta.transicao_especial (ligada só pelas RPCs da 218, com o destino em
--    escolta.transicao_destino) E perfil administrador ou gestor. O botão genérico não pula
--    etapa. A mesma trigger recusa mudar o status de escolta arquivada.
-- 2. tr_impedir_edicao_escolta_iniciada (escoltas, escolta_veiculos e escolta_efetivo): com a
--    escolta fora de rascunho e agendada, só administrador e gestor mudam o que não é do
--    fluxo (S10: supervisor e central perdem no servidor o que a tela já não oferecia).
--    Comparação por to_jsonb(OLD) e to_jsonb(NEW), como a 197, sem as colunas livres e sem as
--    colunas geradas (lidas do catálogo, attgenerated; em trigger BEFORE elas chegam nulas
--    em NEW): vale para colunas que ainda não existem (UF da onda K) sem citá-las por nome.
--    auth.uid() nulo passa (migrations, cargas e cron). Só recusa, não grava nada em NEW:
--    a ordem alfabética entre as BEFORE UPDATE (roda antes de tr_impedir_edicao_por_operador)
--    é indiferente; o teste confere a ordem real.
-- 3. Filtro de anulado em exigir_ponto_transito_retorno, verificar_checklist_pendente e
--    registrar_etapa_escolta (contagem do comboio). registrar_etapa_escolta passa também a
--    ligar escolta.historico_rpc (o histórico dela sai com via_rpc = true) e a gravar
--    lancado_por com o usuário da sessão (em nome de quem fez).
-- 4. Filtros de arquivada e de anulado no aviso de check-in (lote_interno.gerar_avisos_checkin
--    e lote_interno.enfileirar_alerta_checkin, da 212), na reserva do navegador
--    (reservar_alertas_checkin, 212) e na reserva do aviso de presença (reservar_aviso_presenca,
--    208; o plano a chama de enfileirar_aviso_presenca).
-- 5. RLS: escolta arquivada só aparece para o administrador (RESTRICTIVE de SELECT); ponto de
--    controle só no nome de quem grava (RESTRICTIVE de INSERT, depois do preenchimento da
--    213.8); apagar escolta só o administrador, em rascunho e sem registro de campo
--    (RESTRICTIVE de DELETE; decisão 1 do adendo: arquivar, nunca apagar).
-- 6. Nada é apagado (revisão adversarial I, médio 2; decisão 2 do adendo): trigger BEFORE
--    DELETE (tr_impedir_apagar_gestao_<tabela>) recusa, para todos os perfis, apagar linha
--    anulada nas tabelas da 213 (e na de conclusões antecipadas) e apagar viatura da escolta
--    que tenha qualquer registro de campo, anulado ou não (ponto, checklist, rastreamento,
--    ocorrência ou emergência; a cascata levaria tudo junto, inclusive depois de um zerar).
--    Vale também dentro das RPCs (trigger, não policy). Sem usuário final (auth.uid() nulo:
--    migrations, reversões, SQL Editor e cron) passa, como nas demais travas.
-- Reversão: 214_poder_total_travas_reverter.sql (depois da 218).

-- 1. Máquina de estados.
CREATE OR REPLACE FUNCTION public.validar_transicao_status_escolta()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ok boolean := false;
  v_especial text;
  v_seq text[] := ARRAY['rascunho', 'agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino',
                        'no_destino', 'em_transito_retorno', 'retornando', 'na_base', 'finalizada'];
  v_pos_old int; v_pos_new int;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  -- Onda I: escolta arquivada não muda de status (recuperar antes).
  IF OLD.arquivada_em IS NOT NULL THEN
    RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes de mudar o status.'
      USING ERRCODE = 'P0001';
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

  -- Onda I: volta de etapa e conclusão antecipada, só pelas RPCs da 218 (variável de
  -- transação) e só para administrador ou gestor (perfil). Uma sem a outra não passa.
  v_especial := coalesce(current_setting('escolta.transicao_especial', true), '');
  IF NOT v_ok AND v_especial IN ('reset', 'conclusao_antecipada')
     AND public.get_meu_perfil() IN ('administrador', 'gestor') THEN
    v_pos_old := array_position(v_seq, OLD.status);
    v_pos_new := array_position(v_seq, NEW.status);
    IF v_especial = 'reset' THEN
      v_ok := NEW.status = coalesce(current_setting('escolta.transicao_destino', true), '')
              AND v_pos_old IS NOT NULL AND v_pos_new IS NOT NULL
              AND v_pos_new < v_pos_old AND v_pos_new >= 2
              AND OLD.status NOT IN ('rascunho', 'agendada', 'cancelada');
    ELSE
      v_ok := NEW.status = 'finalizada' AND OLD.status NOT IN ('rascunho', 'finalizada', 'cancelada');
    END IF;
  END IF;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'Transição de status inválida: % para %', OLD.status, NEW.status
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$function$;

-- 2. Edição de escolta iniciada só pela gestão (S10).
CREATE OR REPLACE FUNCTION lote_interno.impedir_edicao_escolta_iniciada() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_status text; v_old jsonb; v_new jsonb; v_excluir text[]; v_esc uuid;
  v_livres text[] := ARRAY['status', 'atualizado_em', 'periodicidade_checkin_min', 'checklist_pendente_no_inicio',
                           'data_finalizacao', 'observacao_fechamento', 'data_hora_prevista',
                           -- colunas da 213, com trava própria (tr_travar_colunas_gestao_escoltas)
                           'arquivada_em', 'arquivada_por', 'motivo_arquivamento', 'reiniciada_em', 'versao_gestao'];
BEGIN
  IF auth.uid() IS NULL THEN RETURN coalesce(NEW, OLD); END IF;

  IF TG_TABLE_NAME = 'escoltas' THEN
    v_status := OLD.status;
  ELSE
    v_esc := CASE WHEN TG_OP = 'DELETE' THEN OLD.escolta_id ELSE NEW.escolta_id END;
    SELECT status INTO v_status FROM public.escoltas WHERE id = v_esc;
    -- Troca de escolta numa linha existente: vale o status da escolta de origem também.
    IF TG_OP = 'UPDATE' AND OLD.escolta_id IS DISTINCT FROM NEW.escolta_id
       AND v_status IN ('rascunho', 'agendada') THEN
      SELECT status INTO v_status FROM public.escoltas WHERE id = OLD.escolta_id;
    END IF;
  END IF;
  -- Escolta que ainda não começou (ou que está sendo apagada em cascata): como hoje.
  IF v_status IS NULL OR v_status IN ('rascunho', 'agendada') THEN RETURN coalesce(NEW, OLD); END IF;
  IF public.get_meu_perfil() IN ('administrador', 'gestor') THEN RETURN coalesce(NEW, OLD); END IF;

  IF TG_TABLE_NAME = 'escoltas' THEN
    SELECT coalesce(array_agg(attname::text), '{}') INTO v_excluir
      FROM pg_attribute WHERE attrelid = TG_RELID AND attnum > 0 AND NOT attisdropped AND attgenerated <> '';
    v_excluir := v_excluir || v_livres;
    v_old := to_jsonb(OLD) - v_excluir;
    v_new := to_jsonb(NEW) - v_excluir;
    IF v_old IS DISTINCT FROM v_new THEN
      RAISE EXCEPTION 'Escolta já iniciada: só o gestor ou o administrador altera os dados dela.'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'escolta_veiculos' THEN
    IF TG_OP = 'UPDATE' AND NEW.veiculo_id IS NOT DISTINCT FROM OLD.veiculo_id
       AND NEW.escolta_id IS NOT DISTINCT FROM OLD.escolta_id THEN
      RETURN NEW;                                   -- KM e combustível continuam livres
    END IF;
    RAISE EXCEPTION 'Escolta já iniciada: só o gestor ou o administrador muda as viaturas.'
      USING ERRCODE = '42501';
  END IF;

  -- escolta_efetivo: inclusão, retirada e alteração.
  RAISE EXCEPTION 'Escolta já iniciada: só o gestor ou o administrador muda a equipe.'
    USING ERRCODE = '42501';
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.impedir_edicao_escolta_iniciada() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tr_impedir_edicao_escolta_iniciada ON public.escoltas;
CREATE TRIGGER tr_impedir_edicao_escolta_iniciada BEFORE UPDATE ON public.escoltas
  FOR EACH ROW EXECUTE FUNCTION lote_interno.impedir_edicao_escolta_iniciada();
DROP TRIGGER IF EXISTS tr_impedir_edicao_escolta_iniciada ON public.escolta_veiculos;
CREATE TRIGGER tr_impedir_edicao_escolta_iniciada BEFORE INSERT OR UPDATE OR DELETE ON public.escolta_veiculos
  FOR EACH ROW EXECUTE FUNCTION lote_interno.impedir_edicao_escolta_iniciada();
DROP TRIGGER IF EXISTS tr_impedir_edicao_escolta_iniciada ON public.escolta_efetivo;
CREATE TRIGGER tr_impedir_edicao_escolta_iniciada BEFORE INSERT OR UPDATE OR DELETE ON public.escolta_efetivo
  FOR EACH ROW EXECUTE FUNCTION lote_interno.impedir_edicao_escolta_iniciada();

-- 3. Só ponto e checklist válidos contam.
CREATE OR REPLACE FUNCTION public.exigir_ponto_transito_retorno()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
        AND pc.anulado_em IS NULL          -- onda I: ponto anulado não vale
    ) INTO v_tem;

    IF NOT v_tem THEN
      RAISE EXCEPTION 'Não é possível concluir o retorno sem registrar o ponto de Trânsito para o Retorno.'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.verificar_checklist_pendente()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
        WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'viatura' AND c.concluido = true AND c.anulado_em IS NULL
      )
      AND EXISTS (
        SELECT 1 FROM checklists c
        WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'material' AND c.concluido = true AND c.anulado_em IS NULL
      );

    IF v_veiculos_ok < v_total_veiculos THEN
      NEW.checklist_pendente_no_inicio := true;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_etapa_escolta(p_escolta_id uuid, p_pontos jsonb DEFAULT '[]'::jsonb, p_status_atual text DEFAULT NULL::text, p_status_novo text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text, p_latitude numeric DEFAULT NULL::numeric, p_longitude numeric DEFAULT NULL::numeric, p_observacao_fechamento text DEFAULT NULL::text, p_data_hora_prevista timestamp with time zone DEFAULT NULL::timestamp with time zone, p_tipo_ponto_todas uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int; v_faltando text[]; v_status text;
BEGIN
  -- 0. Trava a escolta e confere a etapa ANTES de gravar qualquer coisa. Serializa duas
  --    viaturas do comboio registrando ao mesmo tempo (a segunda vê o ponto da primeira)
  --    e impede ponto de uma etapa que já passou.
  SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF p_status_atual IS NOT NULL AND v_status IS DISTINCT FROM p_status_atual THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 1. Pontos de controle (todas as viaturas num statement só). Onda I: o autor é sempre
  --    quem está na sessão (em nome de quem fez); sem sessão (SQL), vale o informado.
  IF jsonb_array_length(coalesce(p_pontos, '[]'::jsonb)) > 0 THEN
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid)
               WHERE NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
                                 WHERE ev.id = x.escolta_veiculo_id AND ev.escolta_id = p_escolta_id)) THEN
      RAISE EXCEPTION 'Ponto de controle de viatura que não pertence a esta escolta.';
    END IF;
    INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude,
                                        precisao_metros, sem_sinal_gps, foto_id, lancado_por, observacoes,
                                        sincronizado, criado_offline)
    SELECT x.escolta_veiculo_id, x.tipo_ponto_id, coalesce(x.data_hora, now()), x.latitude, x.longitude,
           x.precisao_metros, coalesce(x.sem_sinal_gps, false), x.foto_id,
           coalesce(public.get_meu_usuario_id(), x.lancado_por), x.observacoes,
           coalesce(x.sincronizado, true), coalesce(x.criado_offline, false)
    FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid, tipo_ponto_id uuid, data_hora timestamptz,
                                           latitude numeric, longitude numeric, precisao_metros numeric,
                                           sem_sinal_gps boolean, foto_id uuid, lancado_por uuid, observacoes text,
                                           sincronizado boolean, criado_offline boolean);
  END IF;

  IF p_status_novo IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'avancou', false);
  END IF;

  -- 2. Comboio: a etapa só avança quando todas as viaturas registraram o ponto dela.
  --    Onda I: ponto anulado (etapa desfeita pela gestão) não conta.
  IF p_tipo_ponto_todas IS NOT NULL THEN
    SELECT array_agg(coalesce(ve.placa, 'sem placa') ORDER BY ev.criado_em) INTO v_faltando
    FROM public.escolta_veiculos ev
    LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
    WHERE ev.escolta_id = p_escolta_id
      AND NOT EXISTS (SELECT 1 FROM public.pontos_controle pc
                      WHERE pc.escolta_veiculo_id = ev.id AND pc.tipo_ponto_id = p_tipo_ponto_todas
                        AND pc.anulado_em IS NULL);
    IF v_faltando IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'avancou', false, 'faltando', to_jsonb(v_faltando));
    END IF;
  END IF;

  -- 3. Status, com a guarda do status atual (a trigger valida a transição).
  UPDATE public.escoltas SET
         status = p_status_novo,
         observacao_fechamento = CASE
           WHEN p_status_novo IN ('finalizada', 'cancelada') THEN p_observacao_fechamento
           WHEN p_data_hora_prevista IS NOT NULL THEN NULL
           ELSE observacao_fechamento END,
         data_finalizacao = CASE WHEN p_status_novo = 'finalizada' THEN now() ELSE data_finalizacao END,
         data_hora_prevista = coalesce(p_data_hora_prevista, data_hora_prevista)
   WHERE id = p_escolta_id AND status = p_status_atual;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 4. Histórico, com autor, na mesma transação. Onda I: via_rpc = true (escolta.historico_rpc).
  PERFORM set_config('escolta.historico_rpc', 'on', true);
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora,
                                               latitude, longitude, observacao)
  VALUES (p_escolta_id, p_status_atual, p_status_novo, public.get_meu_usuario_id(), now(),
          p_latitude, p_longitude, p_observacao);
  PERFORM set_config('escolta.historico_rpc', 'off', true);

  RETURN jsonb_build_object('ok', true, 'avancou', true);
END;
$function$;
REVOKE ALL ON FUNCTION public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid) TO authenticated;

-- 4. Avisos de check-in e de presença sem arquivada e sem anulado.
CREATE OR REPLACE FUNCTION lote_interno.enfileirar_alerta_checkin(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE e record; v_ultima timestamptz; v_atraso int; v_ok boolean; v_chave text;
BEGIN
  SELECT es.id, es.codigo_escolta, es.status, es.periodicidade_checkin_min, es.arquivada_em, c.nome_cliente INTO e
  FROM public.escoltas es JOIN public.clientes c ON c.id = es.cliente_id WHERE es.id = p_escolta_id;
  IF e.id IS NOT NULL AND e.arquivada_em IS NOT NULL THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'arquivada');
  END IF;
  IF e.id IS NULL OR e.periodicidade_checkin_min IS NULL
     OR e.status NOT IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando') THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem check-in periodico');
  END IF;
  -- Regra antiga (pendência 0.3 de docs/12): qualquer PARADA válida zera o prazo; sem nenhuma, não notifica.
  SELECT max(pc.data_hora) INTO v_ultima
  FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
  WHERE ev.escolta_id = p_escolta_id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
    AND pc.anulado_em IS NULL;
  IF v_ultima IS NULL THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem parada'); END IF;
  v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - e.periodicidade_checkin_min;
  IF v_atraso < 1 THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'em dia'); END IF;
  -- Uma mensagem por período vencido sem check-in (chave: escolta, última parada e
  -- número do período).
  v_chave := 'checkin:' || p_escolta_id || ':' || extract(epoch FROM v_ultima)::bigint
             || ':' || floor(v_atraso::numeric / e.periodicidade_checkin_min)::int;
  -- Já mandada por um navegador (reservar_alertas_checkin): não manda de novo.
  IF EXISTS (SELECT 1 FROM public.avisos_reservados WHERE chave = v_chave) THEN
    RETURN jsonb_build_object('enfileirado', false, 'motivo', 'enviado pelo navegador');
  END IF;
  v_ok := public._enfileirar_aviso(v_chave, 'cliente', p_escolta_id,
    '<b>Alerta: check-in em atraso</b>' || E'\n'
    || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(e.nome_cliente) || E'\n'
    || 'Sem check-in há ' || (v_atraso + e.periodicidade_checkin_min) || ' minutos (periodicidade de '
    || e.periodicidade_checkin_min || ' min).' || E'\n'
    || 'Registrado em ' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (Brasília)');
  RETURN jsonb_build_object('enfileirado', v_ok);
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reservar_alertas_checkin() RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_perfil text; v_eu uuid; v_gestao boolean; r record; v_ultima timestamptz; v_atraso int;
  v_chave text; v_n int; v_saida jsonb := '[]'::jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  -- O cron manda: nada para o navegador.
  IF public.avisos_pelo_banco_ativos()
     AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false) THEN
    RETURN v_saida;
  END IF;
  v_eu := public.get_meu_usuario_id();
  v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
  FOR r IN
    SELECT e.id, e.codigo_escolta, e.status, e.periodicidade_checkin_min AS per, c.nome_cliente
    FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
    WHERE e.periodicidade_checkin_min > 0
      AND e.arquivada_em IS NULL
      AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
      AND (v_gestao OR public.sou_do_efetivo(e.id))
  LOOP
    -- Regra antiga (pendência 0.3), a mesma de lote_interno.enfileirar_alerta_checkin.
    SELECT max(pc.data_hora) INTO v_ultima
    FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
    WHERE ev.escolta_id = r.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
      AND pc.anulado_em IS NULL;
    CONTINUE WHEN v_ultima IS NULL;
    v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - r.per;
    CONTINUE WHEN v_atraso < 1;
    v_chave := 'checkin:' || r.id || ':' || extract(epoch FROM v_ultima)::bigint || ':' || floor(v_atraso::numeric / r.per)::int;
    -- Já enfileirada pelo cron (envio pelo banco ligado há pouco): não manda de novo.
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.avisos_telegram WHERE evento_chave = v_chave);
    INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES (v_chave, v_eu) ON CONFLICT (chave) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    CONTINUE WHEN v_n = 0;
    v_saida := v_saida || jsonb_build_object(
      'escolta_id', r.id, 'codigo', r.codigo_escolta, 'cliente', r.nome_cliente, 'status', r.status,
      'atraso_min', v_atraso, 'periodicidade_min', r.per,
      'efetivos', coalesce((SELECT jsonb_agg(v.nome_completo || coalesce(' (' || ee.papel_na_escolta || ')', '') ORDER BY ee.papel_na_escolta, v.nome_completo)
                            FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
                            WHERE ee.escolta_id = r.id), '[]'::jsonb));
  END LOOP;
  RETURN v_saida;
END;
$$;
REVOKE ALL ON FUNCTION public.reservar_alertas_checkin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reservar_alertas_checkin() TO authenticated;

CREATE OR REPLACE FUNCTION lote_interno.gerar_avisos_checkin(p_agora timestamptz DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  r record; v_gestao uuid[]; v_n int := 0; v_decorrido numeric; v_atraso int; v_periodo int; v_telegram boolean;
BEGIN
  SELECT coalesce(array_agg(u.id), '{}') INTO v_gestao
  FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor', 'central');
  v_telegram := public.avisos_pelo_banco_ativos()
                AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false);

  -- Onda I: escolta arquivada fora; ponto anulado não é referência.
  FOR r IN
    SELECT e.id, e.codigo_escolta, e.periodicidade_checkin_min AS per, c.nome_cliente,
           coalesce(
             (SELECT max(pc.data_hora) FROM public.pontos_controle pc
                JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
               WHERE ev.escolta_id = e.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
                 AND pc.anulado_em IS NULL
                 AND lote_interno.tipo_da_observacao(pc.observacoes) = 'reporte_periodico'),
             (SELECT min(pc.data_hora) FROM public.pontos_controle pc
                JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
               WHERE ev.escolta_id = e.id AND pc.anulado_em IS NULL),
             e.data_hora_prevista) AS referencia
    FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
    WHERE e.periodicidade_checkin_min > 0
      AND e.arquivada_em IS NULL
      AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
  LOOP
    -- Aviso na central: erro numa escolta (usuário apagado entre a leitura e o INSERT, tipo
    -- ausente) fica nela e vira WARNING; o ciclo segue.
    BEGIN
      IF r.referencia IS NOT NULL THEN
        v_decorrido := extract(epoch FROM (p_agora - r.referencia));
        -- Mesmo arredondamento de minutosAteCheckin: atraso = -floor((per*60 - decorrido) / 60).
        v_atraso := -floor((r.per * 60 - v_decorrido) / 60)::int;
        IF v_atraso >= 1 THEN
          -- Período n: de n a n+1 periodicidades decorridas (o 1º vence com a periodicidade).
          v_periodo := ceil(v_decorrido / (r.per * 60))::int - 1;
          v_n := v_n + lote_interno.notificar(
            'checkin:' || r.id || ':' || floor(extract(epoch FROM r.referencia))::bigint || ':' || v_periodo,
            r.id, 'checkin_vencido',
            ARRAY(SELECT v.usuario_id FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
                   WHERE ee.escolta_id = r.id AND v.usuario_id IS NOT NULL) || v_gestao,
            'Check-in atrasado: ' || r.codigo_escolta,
            'Escolta ' || r.codigo_escolta || ' · ' || r.nome_cliente || ': sem check-in há ' || (v_atraso + r.per)
              || ' min (periodicidade de ' || r.per || ' min, ' || v_atraso || ' min de atraso). Prazo vencido em '
              || to_char((r.referencia + make_interval(mins => r.per * v_periodo)) AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
              || ' (Brasília).',
            jsonb_build_object('referencia', r.referencia, 'periodo', v_periodo, 'periodicidade_min', r.per));
        END IF;
      END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'gerar_avisos_checkin: aviso da escolta % falhou: %', r.id, SQLERRM;
    END;
    -- Telegram pela regra antiga (a função decide); erro numa escolta não para o ciclo.
    IF v_telegram THEN
      BEGIN
        PERFORM lote_interno.enfileirar_alerta_checkin(r.id);
      EXCEPTION WHEN others THEN
        RAISE WARNING 'gerar_avisos_checkin: Telegram da escolta % falhou: %', r.id, SQLERRM;
      END;
    END IF;
  END LOOP;

  DELETE FROM public.notificacoes WHERE lida AND lida_em < p_agora - interval '90 days';
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.gerar_avisos_checkin(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reservar_aviso_presenca(p_presenca_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; v_esc uuid; v_n int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  -- Onda I: presença anulada ou de escolta arquivada não vai ao Telegram.
  SELECT p.escolta_id INTO v_esc FROM public.presencas p JOIN public.escoltas e ON e.id = p.escolta_id
   WHERE p.id = p_presenca_id AND p.anulado_em IS NULL AND e.arquivada_em IS NULL;
  IF v_esc IS NULL THEN RETURN false; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(v_esc) THEN
    RETURN false;
  END IF;
  INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES ('presenca:' || p_presenca_id, public.get_meu_usuario_id())
  ON CONFLICT (chave) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n = 1;
END;
$$;
REVOKE ALL ON FUNCTION public.reservar_aviso_presenca(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reservar_aviso_presenca(uuid) TO authenticated;

-- 5. RLS.
-- Escolta arquivada some para todos, menos o administrador (lista, mural, Campo, mapa,
-- indicadores e embeds escolta:escoltas(...) passam a vir nulos para quem não vê).
DROP POLICY IF EXISTS escoltas_arquivada_so_admin ON public.escoltas;
CREATE POLICY escoltas_arquivada_so_admin ON public.escoltas AS RESTRICTIVE FOR SELECT TO authenticated
  USING (arquivada_em IS NULL OR (SELECT public.get_meu_perfil()) = 'administrador');

-- Ponto sempre no nome de quem grava (o nulo é preenchido pela trigger da 213 antes disto).
DROP POLICY IF EXISTS pontos_insert_autor ON public.pontos_controle;
CREATE POLICY pontos_insert_autor ON public.pontos_controle AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (lancado_por = (SELECT public.get_meu_usuario_id()));

-- Apagar escolta: só o administrador, em rascunho e sem nenhum registro de campo.
DROP POLICY IF EXISTS escoltas_delete_so_rascunho ON public.escoltas;
CREATE POLICY escoltas_delete_so_rascunho ON public.escoltas AS RESTRICTIVE FOR DELETE TO authenticated
  USING ((SELECT public.get_meu_perfil()) = 'administrador'
         AND status = 'rascunho'
         AND NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
                          WHERE ev.escolta_id = escoltas.id
                            AND (EXISTS (SELECT 1 FROM public.pontos_controle pc WHERE pc.escolta_veiculo_id = ev.id)
                                 OR EXISTS (SELECT 1 FROM public.checklists ck WHERE ck.escolta_veiculo_id = ev.id)
                                 OR EXISTS (SELECT 1 FROM public.rastreamento ra WHERE ra.escolta_veiculo_id = ev.id)))
         AND NOT EXISTS (SELECT 1 FROM public.ocorrencias o WHERE o.escolta_id = escoltas.id)
         AND NOT EXISTS (SELECT 1 FROM public.emergencias em WHERE em.escolta_id = escoltas.id)
         AND NOT EXISTS (SELECT 1 FROM public.presencas pr WHERE pr.escolta_id = escoltas.id)
         AND NOT EXISTS (SELECT 1 FROM public.atualizacoes_status au WHERE au.escolta_id = escoltas.id));

-- 6. Nada é apagado: linha anulada e viatura com registro de campo.
CREATE OR REPLACE FUNCTION lote_interno.impedir_apagar_registro() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN OLD; END IF;
  IF TG_TABLE_NAME = 'escolta_veiculos' THEN
    IF EXISTS (SELECT 1 FROM public.pontos_controle WHERE escolta_veiculo_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.checklists WHERE escolta_veiculo_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.rastreamento WHERE escolta_veiculo_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.ocorrencias WHERE escolta_veiculo_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.emergencias WHERE escolta_veiculo_id = OLD.id) THEN
      RAISE EXCEPTION 'Esta viatura tem registro de campo (válido ou anulado) e não pode ser apagada: nada é apagado.'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;
  IF to_jsonb(OLD) ->> 'anulado_em' IS NOT NULL THEN
    RAISE EXCEPTION 'Registro anulado não pode ser apagado: ele fica como prova do que a gestão desfez.'
      USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.impedir_apagar_registro() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico',
                           'escolta_conclusoes_antecipadas', 'escolta_veiculos']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_impedir_apagar_gestao_' || t, t);
    EXECUTE format('CREATE TRIGGER %I BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION lote_interno.impedir_apagar_registro()',
                   'tr_impedir_apagar_gestao_' || t, t);
  END LOOP;
END $$;

-- Conferência:
-- SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_impedir_apagar_gestao_%';           -- 11
-- SELECT prosrc LIKE '%transicao_especial%' FROM pg_proc WHERE oid = 'public.validar_transicao_status_escolta()'::regprocedure;  -- true
-- SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_impedir_edicao_escolta_iniciada';     -- 3
-- SELECT polname FROM pg_policy WHERE polname IN ('escoltas_arquivada_so_admin', 'pontos_insert_autor', 'escoltas_delete_so_rascunho'); -- 3
-- SELECT prosrc LIKE '%historico_rpc%' AND prosrc LIKE '%anulado_em IS NULL%' FROM pg_proc WHERE proname = 'registrar_etapa_escolta';  -- true

-- ──────── 215_locais_uso.sql ────────
-- 215_locais_uso.sql
-- Lote 2026-10, onda D2 (acréscimos da onda D, item 4.6 do adendo 01; docs/14, seção 14).
-- Idempotente. Bloco 1, depois da 214. Compatível com a master 2b3fff9: a master não lê nem
-- grava locais_salvos; as triggers novas só leem escoltas, só escrevem em locais_salvos e
-- nunca recusam nada (erro interno vira aviso no log e linha em lote_interno.locais_uso_falhas).
--
-- Por quê:
-- 1. Ordenação dos atalhos pelos mais usados: locais_salvos.vezes_usado é o número de vezes
--    que o local é origem ou destino de uma escolta NÃO cancelada (cada lado conta uma vez),
--    calculado a partir das escoltas, nunca somado às cegas. Assim "Usado N vezes" na tela de
--    locais é o número real: ida e volta de uma edição não infla, cancelar desconta,
--    descancelar volta a contar.
--    - Trigger AFTER INSERT OR DELETE OR UPDATE OF origem_endereco, destino_endereco,
--      origem_lat, origem_lng, destino_lat, destino_lng, status em escoltas: quando o lado
--      mudou de fato (IS DISTINCT FROM) ou a escolta entrou ou saiu de 'cancelada', recalcula
--      o local antigo e o novo daquele lado. Mudança de status entre não canceladas, KM, UF
--      (onda K) e as cargas não mexem em nada.
--    - Trigger por comando em locais_salvos (INSERT, DELETE e UPDATE de nome, endereço,
--      complemento, coordenada ou situação): recalcula todos os locais, porque um local novo
--      ou mudado pode passar a ser o local de escoltas que já existem.
-- 2. Qual local corresponde a um endereço gravado (lote_interno.local_do_endereco): a Nova
--    grava o complemento no texto (enderecoComComplemento: "endereço, complemento"). Vence,
--    nesta ordem: o texto completo igual a "endereço, complemento" do local (ou só o endereço,
--    para local sem complemento); o texto que começa pelo endereço do local; a coordenada mais
--    próxima até 100 m; o local sem complemento; o nome. Com "JAMEF" e "JAMEF Doca 9" no
--    mesmo endereço, "..., Doca 9" conta para a doca, o endereço sem complemento conta para a
--    JAMEF e um complemento que nenhum dos dois tem conta para a JAMEF. Inativo não conta.
-- 3. UF do local (para o atalho preencher a UF da escolta quando a onda K existir):
--    locais_salvos.uf, CHECK de duas letras maiúsculas; os 5 locais da carga da 205 são RJ.
-- 4. Nenhum perfil altera vezes_usado pela API: INSERT e UPDATE de authenticated passam a ser
--    por coluna, sem vezes_usado (o operador já não tinha UPDATE em locais_salvos, 205). Só as
--    funções internas (SECURITY DEFINER, sem GRANT) gravam.
-- 5. locais_salvos_regras (205) ignora o UPDATE que só muda vezes_usado (senão o uso de um
--    local pela escolta de um operador gravaria o operador em atualizado_por) e passa a
--    devolver para conferência o local ativo cuja UF mudou (a UF é parte do que a
--    conferência atesta, como o nome, o texto, o complemento e o pino).
-- 6. Falha da contagem: as triggers rodam com lock_timeout de 500 ms (espera pela linha do
--    local vira erro capturado, nunca o statement_timeout de 8 s do PostgREST derrubando a
--    escolta); o erro vira WARNING e uma linha em lote_interno.locais_uso_falhas (sem GRANT;
--    gestor e administrador veem o total na tela de locais pela locais_uso_falhas_resumo()).
-- 7. Carga do uso a partir das escoltas existentes: só LÊ escoltas (UPDATE só em
--    locais_salvos). ESC-2026-0001 e ESC-2026-0007 não mudam. Recalcula tudo, então
--    reaplicar dá o mesmo número.
--
-- Conferência:
-- SELECT nome, uf, vezes_usado, situacao FROM locais_salvos ORDER BY vezes_usado DESC, nome;  -- 5 com uf RJ
-- SELECT count(*) FROM pg_trigger WHERE tgname IN ('tr_contar_uso_local', 'tr_recontar_uso_locais');  -- 2
-- SELECT has_column_privilege('authenticated', 'public.locais_salvos', 'vezes_usado', 'UPDATE');  -- false
-- SELECT count(*) FROM lote_interno.locais_uso_falhas;                                          -- 0
-- Reversão: 215_locais_uso_reverter.sql (guarda vezes_usado e uf em backup_20261008.locais_uso).

CREATE SCHEMA IF NOT EXISTS lote_interno;
REVOKE ALL ON SCHEMA lote_interno FROM PUBLIC, anon, authenticated;

-- A. Qual local salvo (não inativo) corresponde a um endereço gravado. Interna, sem GRANT.
CREATE OR REPLACE FUNCTION lote_interno.local_do_endereco(p_endereco text, p_lat numeric, p_lng numeric)
    RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  WITH c AS (
    SELECT l.id, l.nome,
           coalesce(trim(l.complemento), '') = '' AS sem_complemento,
           (p_endereco IS NOT NULL AND trim(l.endereco) <> ''
            AND lower(trim(p_endereco)) = lower(trim(l.endereco)
                  || CASE WHEN coalesce(trim(l.complemento), '') <> '' THEN ', ' || trim(l.complemento) ELSE '' END)) AS pelo_texto_completo,
           (p_endereco IS NOT NULL AND trim(l.endereco) <> ''
            AND (lower(trim(p_endereco)) = lower(trim(l.endereco))
                 OR left(lower(trim(p_endereco)), length(trim(l.endereco)) + 2) = lower(trim(l.endereco)) || ', ')) AS pelo_endereco,
           CASE WHEN p_lat IS NULL OR p_lng IS NULL OR (p_lat = 0 AND p_lng = 0)
                     OR l.latitude IS NULL OR l.longitude IS NULL THEN NULL
                ELSE 2 * 6371000 * asin(sqrt(
                       power(sin(radians((l.latitude - p_lat)::float8) / 2), 2)
                       + cos(radians(p_lat::float8)) * cos(radians(l.latitude::float8))
                         * power(sin(radians((l.longitude - p_lng)::float8) / 2), 2)))
           END AS metros
      FROM public.locais_salvos l
     WHERE l.situacao <> 'inativo'
  )
  SELECT id FROM c
   WHERE pelo_texto_completo OR pelo_endereco OR metros <= 100
   ORDER BY pelo_texto_completo DESC, pelo_endereco DESC, metros NULLS LAST, sem_complemento DESC, nome
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION lote_interno.local_do_endereco(text, numeric, numeric) FROM PUBLIC, anon, authenticated;

-- B. Quantas vezes um local é origem ou destino de escolta não cancelada. Só os lados que
-- podem bater com o local (texto começando pelo endereço ou coordenada numa caixa de ~110 m)
-- passam pela local_do_endereco, que decide o empate entre locais.
CREATE OR REPLACE FUNCTION lote_interno.contar_escoltas_do_local(p_local uuid) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  WITH l AS (
    SELECT lower(trim(endereco)) AS ender, latitude AS lat, longitude AS lng
      FROM public.locais_salvos WHERE id = p_local AND situacao <> 'inativo'
  ), lados AS (
    SELECT e.origem_endereco AS ender, e.origem_lat AS lat, e.origem_lng AS lng FROM public.escoltas e WHERE e.status <> 'cancelada'
    UNION ALL
    SELECT e.destino_endereco, e.destino_lat, e.destino_lng FROM public.escoltas e WHERE e.status <> 'cancelada'
  )
  SELECT count(*)::integer FROM lados s, l
   WHERE ((l.ender <> '' AND (lower(trim(s.ender)) = l.ender OR left(lower(trim(s.ender)), length(l.ender) + 2) = l.ender || ', '))
          OR (l.lat IS NOT NULL AND l.lng IS NOT NULL AND s.lat IS NOT NULL AND s.lng IS NOT NULL
              AND abs(s.lat - l.lat) <= 0.001 AND abs(s.lng - l.lng) <= 0.001 / cos(radians(l.lat::float8))))
     AND lote_interno.local_do_endereco(s.ender, s.lat, s.lng) = p_local
$$;
REVOKE ALL ON FUNCTION lote_interno.contar_escoltas_do_local(uuid) FROM PUBLIC, anon, authenticated;

-- C. Colunas novas.
DO $$
BEGIN
  ALTER TABLE public.locais_salvos ADD COLUMN IF NOT EXISTS vezes_usado integer NOT NULL DEFAULT 0;
  ALTER TABLE public.locais_salvos ADD COLUMN IF NOT EXISTS uf text;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'locais_salvos_uf_formato') THEN
    ALTER TABLE public.locais_salvos ADD CONSTRAINT locais_salvos_uf_formato CHECK (uf ~ '^[A-Z]{2}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'locais_salvos_vezes_usado_positivo') THEN
    ALTER TABLE public.locais_salvos ADD CONSTRAINT locais_salvos_vezes_usado_positivo CHECK (vezes_usado >= 0);
  END IF;
END $$;
COMMENT ON COLUMN public.locais_salvos.vezes_usado IS 'Lote 2026-10 (D2): quantas vezes o local é origem ou destino de escolta não cancelada (cada lado conta uma vez). Recalculado pelas triggers tr_contar_uso_local e tr_recontar_uso_locais; ordena os atalhos.';
COMMENT ON COLUMN public.locais_salvos.uf IS 'Lote 2026-10 (D2): UF do local; o atalho preenche a UF da escolta (onda K).';

-- D. Carga (e recálculo) do uso de todos os locais a partir das escoltas: só leitura de
-- escoltas. Local sem escolta (ou inativo) fica com 0. Devolve quantos locais mudaram.
CREATE OR REPLACE FUNCTION lote_interno.carregar_uso_locais() RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n integer;
BEGIN
  -- Trava os locais (sempre na ordem do id, como a trigger das escoltas) antes de contar,
  -- para a contagem ver as escoltas gravadas por quem segurava a linha.
  PERFORM 1 FROM public.locais_salvos ORDER BY id FOR UPDATE;
  WITH usos AS (
    SELECT lote_interno.local_do_endereco(e.origem_endereco, e.origem_lat, e.origem_lng) AS local_id FROM public.escoltas e WHERE e.status <> 'cancelada'
    UNION ALL
    SELECT lote_interno.local_do_endereco(e.destino_endereco, e.destino_lat, e.destino_lng) FROM public.escoltas e WHERE e.status <> 'cancelada'
  ), contagem AS (
    SELECT local_id, count(*)::integer AS n FROM usos WHERE local_id IS NOT NULL GROUP BY local_id
  ), novo AS (
    SELECT l.id, coalesce(c.n, 0) AS n FROM public.locais_salvos l LEFT JOIN contagem c ON c.local_id = l.id
  )
  UPDATE public.locais_salvos l SET vezes_usado = novo.n
    FROM novo WHERE novo.id = l.id AND l.vezes_usado IS DISTINCT FROM novo.n;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.carregar_uso_locais() FROM PUBLIC, anon, authenticated;

-- E. Privilégios por coluna: ninguém grava vezes_usado pela API (as policies da 205 continuam).
REVOKE INSERT, UPDATE ON public.locais_salvos FROM authenticated;
GRANT INSERT (nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, uf) ON public.locais_salvos TO authenticated;
GRANT UPDATE (nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, uf) ON public.locais_salvos TO authenticated;

-- F. Regras do local (205) com o UPDATE só de vezes_usado ignorado e a UF na reconferência.
CREATE OR REPLACE FUNCTION public.locais_salvos_regras() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_perfil text; v_eu uuid;
BEGIN
  -- Uso recalculado pelas triggers da 215: não é edição do local.
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'vezes_usado') = (to_jsonb(OLD) - 'vezes_usado') THEN
    RETURN NEW;
  END IF;
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;      -- SQL Editor e migrations
  SELECT public.get_meu_perfil() INTO v_perfil;
  v_eu := public.get_meu_usuario_id();
  IF TG_OP = 'INSERT' THEN
    NEW.criado_por := v_eu; NEW.criado_em := now();
    IF NEW.situacao = 'ativo' THEN NEW.situacao := 'aguardando_conferencia'; END IF;
    NEW.conferido_por := NULL; NEW.conferido_em := NULL;
    NEW.vezes_usado := 0;
  ELSE
    NEW.criado_por := OLD.criado_por; NEW.criado_em := OLD.criado_em;
    NEW.vezes_usado := OLD.vezes_usado;
    -- Local ativo que muda de coordenada, nome, endereço, complemento ou UF volta para
    -- conferência (o texto, o pino e a UF são o que a conferência atestou).
    IF OLD.situacao = 'ativo' AND NEW.situacao = 'ativo'
       AND (NEW.latitude IS DISTINCT FROM OLD.latitude OR NEW.longitude IS DISTINCT FROM OLD.longitude
            OR NEW.nome IS DISTINCT FROM OLD.nome OR NEW.endereco IS DISTINCT FROM OLD.endereco
            OR NEW.complemento IS DISTINCT FROM OLD.complemento OR NEW.uf IS DISTINCT FROM OLD.uf) THEN
      NEW.situacao := 'aguardando_conferencia';
    END IF;
    IF NEW.situacao = 'ativo' AND OLD.situacao IS DISTINCT FROM 'ativo' THEN
      IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor') THEN
        RAISE EXCEPTION 'Somente gestor ou administrador confere e ativa um local salvo.';
      END IF;
      NEW.conferido_por := v_eu; NEW.conferido_em := now();
    ELSIF NEW.situacao <> 'ativo' THEN
      NEW.conferido_por := CASE WHEN NEW.situacao = 'inativo' THEN OLD.conferido_por END;
      NEW.conferido_em := CASE WHEN NEW.situacao = 'inativo' THEN OLD.conferido_em END;
    ELSE
      NEW.conferido_por := OLD.conferido_por; NEW.conferido_em := OLD.conferido_em;
    END IF;
  END IF;
  NEW.atualizado_por := v_eu; NEW.atualizado_em := now();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.locais_salvos_regras() FROM PUBLIC, anon, authenticated;

-- G. Registro das falhas da contagem (sem GRANT; leitura só pelo resumo abaixo).
CREATE TABLE IF NOT EXISTS lote_interno.locais_uso_falhas (
  id bigserial PRIMARY KEY,
  quando timestamptz NOT NULL DEFAULT now(),
  origem text NOT NULL,              -- 'escoltas' (trigger por linha) ou 'locais_salvos' (por comando)
  escolta_id uuid,
  erro text,
  codigo text
);
ALTER TABLE lote_interno.locais_uso_falhas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON lote_interno.locais_uso_falhas FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE lote_interno.locais_uso_falhas_id_seq FROM PUBLIC, anon, authenticated;

-- Resumo para a tela de locais (gestor e administrador): total de falhas e a última.
CREATE OR REPLACE FUNCTION public.locais_uso_falhas_resumo()
    RETURNS TABLE (total integer, ultima text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF auth.uid() IS NULL OR coalesce(public.get_meu_perfil(), '') NOT IN ('administrador', 'gestor') THEN
    RAISE EXCEPTION 'Sem permissão para ver as falhas da contagem de uso.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT count(*)::integer, to_char(max(f.quando) AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
      FROM lote_interno.locais_uso_falhas f;
END;
$$;
REVOKE ALL ON FUNCTION public.locais_uso_falhas_resumo() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.locais_uso_falhas_resumo() TO authenticated;

-- H. Trigger das escoltas: recalcula o local antigo e o novo do lado que mudou (ou dos dois
-- lados, quando a escolta entra ou sai de 'cancelada'). Nunca recusa a gravação da escolta.
CREATE OR REPLACE FUNCTION lote_interno.contar_uso_local() RETURNS trigger
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    SET lock_timeout TO '500ms'
    AS $$
DECLARE v_ids uuid[] := ARRAY[]::uuid[]; v_id uuid; v_n integer; v_cancelada_mudou boolean;
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' THEN
      v_ids := ARRAY[lote_interno.local_do_endereco(NEW.origem_endereco, NEW.origem_lat, NEW.origem_lng),
                     lote_interno.local_do_endereco(NEW.destino_endereco, NEW.destino_lat, NEW.destino_lng)];
    ELSIF TG_OP = 'DELETE' THEN
      v_ids := ARRAY[lote_interno.local_do_endereco(OLD.origem_endereco, OLD.origem_lat, OLD.origem_lng),
                     lote_interno.local_do_endereco(OLD.destino_endereco, OLD.destino_lat, OLD.destino_lng)];
    ELSE
      v_cancelada_mudou := (OLD.status = 'cancelada') IS DISTINCT FROM (NEW.status = 'cancelada');
      IF v_cancelada_mudou OR NEW.origem_endereco IS DISTINCT FROM OLD.origem_endereco
         OR NEW.origem_lat IS DISTINCT FROM OLD.origem_lat OR NEW.origem_lng IS DISTINCT FROM OLD.origem_lng THEN
        v_ids := v_ids || lote_interno.local_do_endereco(NEW.origem_endereco, NEW.origem_lat, NEW.origem_lng)
                       || lote_interno.local_do_endereco(OLD.origem_endereco, OLD.origem_lat, OLD.origem_lng);
      END IF;
      IF v_cancelada_mudou OR NEW.destino_endereco IS DISTINCT FROM OLD.destino_endereco
         OR NEW.destino_lat IS DISTINCT FROM OLD.destino_lat OR NEW.destino_lng IS DISTINCT FROM OLD.destino_lng THEN
        v_ids := v_ids || lote_interno.local_do_endereco(NEW.destino_endereco, NEW.destino_lat, NEW.destino_lng)
                       || lote_interno.local_do_endereco(OLD.destino_endereco, OLD.destino_lat, OLD.destino_lng);
      END IF;
    END IF;
    SELECT array_agg(DISTINCT x ORDER BY x) INTO v_ids FROM unnest(v_ids) x WHERE x IS NOT NULL;
    IF v_ids IS NOT NULL THEN
      -- Trava os locais na ordem do id (duas escoltas com origem e destino cruzados não
      -- entram em impasse) e só depois conta, para ver o que quem segurava a linha gravou.
      PERFORM 1 FROM public.locais_salvos WHERE id = ANY (v_ids) ORDER BY id FOR UPDATE;
      FOREACH v_id IN ARRAY v_ids LOOP
        v_n := lote_interno.contar_escoltas_do_local(v_id);
        UPDATE public.locais_salvos SET vezes_usado = v_n WHERE id = v_id AND vezes_usado IS DISTINCT FROM v_n;
      END LOOP;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'contar_uso_local: % (%)', SQLERRM, SQLSTATE;
    BEGIN
      INSERT INTO lote_interno.locais_uso_falhas (origem, escolta_id, erro, codigo)
      VALUES ('escoltas', CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END, SQLERRM, SQLSTATE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.contar_uso_local() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_contar_uso_local ON public.escoltas;
CREATE TRIGGER tr_contar_uso_local
  AFTER INSERT OR DELETE OR UPDATE OF origem_endereco, destino_endereco, origem_lat, origem_lng, destino_lat, destino_lng, status
  ON public.escoltas FOR EACH ROW EXECUTE FUNCTION lote_interno.contar_uso_local();

-- I. Trigger por comando em locais_salvos: local novo, apagado ou com nome, texto, pino ou
-- situação mudados recalcula todos (o UPDATE só de vezes_usado não a dispara). Nunca recusa.
CREATE OR REPLACE FUNCTION lote_interno.recontar_uso_locais() RETURNS trigger
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    SET lock_timeout TO '500ms'
    AS $$
BEGIN
  BEGIN
    PERFORM lote_interno.carregar_uso_locais();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'recontar_uso_locais: % (%)', SQLERRM, SQLSTATE;
    BEGIN
      INSERT INTO lote_interno.locais_uso_falhas (origem, erro, codigo) VALUES ('locais_salvos', SQLERRM, SQLSTATE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.recontar_uso_locais() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_recontar_uso_locais ON public.locais_salvos;
CREATE TRIGGER tr_recontar_uso_locais
  AFTER INSERT OR DELETE OR UPDATE OF nome, endereco, complemento, latitude, longitude, situacao
  ON public.locais_salvos FOR EACH STATEMENT EXECUTE FUNCTION lote_interno.recontar_uso_locais();

-- J. UF dos 5 locais da carga da 205 (todos no Rio de Janeiro).
UPDATE public.locais_salvos SET uf = 'RJ'
 WHERE uf IS NULL AND nome IN ('JAMEF', 'Sede', 'Engenhão', 'Aeroporto do Galeão', 'Aeroporto Santos Dumont');

-- K. Carga do uso a partir das escoltas existentes (só leitura de escoltas).
SELECT lote_interno.carregar_uso_locais();

COMMIT;

-- Conferência do bloco 1 (somente leitura):
-- 196_identidade_e_higiene:
-- Conferência (esperado: 0 linhas em cada):
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE nspname='public' AND prosecdef AND has_function_privilege('anon', p.oid, 'EXECUTE');
-- SELECT proname FROM pg_proc WHERE proname IN ('perfil_usuario_atual','sou_do_efetivo')
--  AND pg_get_functiondef(oid) NOT LIKE '%status = ''ativo''%';
-- 197_escrita_do_operador:
-- (conferência: ver o cabeçalho da migration)
-- 198_fotos_leitura_por_escolta:
-- Conferência: SELECT policyname FROM pg_policies WHERE policyname IN
--   ('fotos_select_por_escolta','fotos_leitura_autenticada');   -- esperado: 2 linhas
-- 199_troca_senha_obrigatoria:
-- Conferência (esperado: as contas de Douglas e Bruno com troca = true):
-- SELECT u.nome_completo, p.codigo, u.troca_senha_obrigatoria FROM usuarios u
--   JOIN dom_perfis p ON p.id = u.perfil_id
--  WHERE u.id IN ('9b0c6047-d9eb-42a5-b980-d87ef7b5f611','130db52b-c966-44d9-aa35-622e24eb953c');
-- 201_checkin_desligado:
-- Conferência:
-- SELECT count(*) FROM escoltas WHERE status NOT IN ('finalizada','cancelada') AND periodicidade_checkin_min IS NOT NULL; -- 0
-- SELECT count(*) FROM backup_20261008.periodicidade_checkin;   -- 8 em 08/10/2026
-- 202_avisos_telegram:
-- Conferência:
-- SELECT extname FROM pg_extension WHERE extname IN ('pg_cron','pg_net');
-- SELECT envio_pelo_banco FROM configuracao_avisos;
-- SELECT public.avisos_pelo_banco_ativos();   -- true só depois dos segredos no Vault
-- SELECT situacao, count(*) FROM avisos_telegram GROUP BY 1;
-- 203_mural_travas_estrutura:
-- Conferência:
-- SELECT * FROM configuracoes_mural;                                   -- 60, 15, 6
-- SELECT count(*) FROM escoltas WHERE escala_fixa;                     -- 0
-- SELECT codigo FROM dom_tipos_evento WHERE codigo LIKE '%substituicao%';  -- 3
-- 205_locais_salvos:
-- Conferência:
-- SELECT nome, situacao, latitude, longitude FROM locais_salvos ORDER BY nome;   -- 5, todos aguardando_conferencia
-- 206_combustivel:
-- (conferência: ver o cabeçalho da migration)
-- 207_etapa_atomica:
-- (conferência: ver o cabeçalho da migration)
-- 208_avisos_pelo_servidor:
-- (conferência: ver o cabeçalho da migration)
-- 209_historico_sem_trigger:
-- (conferência: ver o cabeçalho da migration)
-- 215_locais_uso:
-- SELECT nome, uf, vezes_usado, situacao FROM locais_salvos ORDER BY vezes_usado DESC, nome;  -- 5 com uf RJ
-- SELECT count(*) FROM pg_trigger WHERE tgname IN ('tr_contar_uso_local', 'tr_recontar_uso_locais');  -- 2
-- SELECT count(*) FROM lote_interno.locais_uso_falhas;                                          -- 0
-- 211_central_avisos e 212_aviso_checkin_servidor: ver a consulta abaixo (central, lote_interno e cron).
SELECT 'funcoes novas' AS item, count(*)::text AS valor FROM pg_proc WHERE proname IN ('escolta_do_caminho','registrar_etapa_escolta','enfileirar_alerta_checkin','reservar_aviso_presenca','avisos_pelo_banco_ativos','locais_salvos_regras','impedir_combustivel_por_operador','proteger_escala_fixa','reservar_alertas_checkin') AND pronamespace = 'public'::regnamespace
UNION ALL SELECT 'tabelas novas', count(*)::text FROM pg_tables WHERE schemaname = 'public' AND tablename IN ('alertas_dispensados','avisos_telegram','configuracao_avisos','configuracoes_mural','mural_presencas','mural_pedidos','locais_salvos','avisos_reservados')
UNION ALL SELECT 'escoltas abertas com periodicidade', count(*)::text FROM public.escoltas WHERE status NOT IN ('finalizada','cancelada') AND periodicidade_checkin_min IS NOT NULL
UNION ALL SELECT 'locais salvos', string_agg(nome || '=' || situacao, ', ') FROM public.locais_salvos
UNION ALL SELECT 'troca de senha marcada (Douglas, Bruno)', string_agg(troca_senha_obrigatoria::text, ',') FROM public.usuarios WHERE id IN ('9b0c6047-d9eb-42a5-b980-d87ef7b5f611','130db52b-c966-44d9-aa35-622e24eb953c')
UNION ALL SELECT 'cron do lote', string_agg(jobname, ', ') FROM cron.job WHERE jobname LIKE 'lote2026%'
UNION ALL SELECT 'envio pelo banco ativo (true so depois dos segredos no Vault)', public.avisos_pelo_banco_ativos()::text
UNION ALL SELECT 'colunas da central em notificacoes (esperado 4)', count(*)::text FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'notificacoes' AND column_name IN ('lida_em','titulo','texto','evento_chave')
UNION ALL SELECT 'policies de notificacoes (esperado notificacoes_select)', string_agg(polname, ', ') FROM pg_policy WHERE polrelid = 'public.notificacoes'::regclass
UNION ALL SELECT 'funções do lote_interno executáveis por anon ou authenticated (esperado 0)', count(*)::text FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))
UNION ALL SELECT 'anon com acesso a notificacoes (esperado false)', (has_table_privilege('anon', 'public.notificacoes', 'SELECT') OR has_table_privilege('anon', 'public.notificacoes', 'TRUNCATE'))::text
UNION ALL SELECT 'Telegram do check-in pelo cron (esperado false até o bloco 2)', checkin_telegram_pelo_cron::text FROM public.configuracao_avisos WHERE id = 1
UNION ALL SELECT 'onda I: colunas de anulação nas 9 tabelas de campo (esperado 9)', count(*)::text FROM information_schema.columns WHERE table_schema = 'public' AND column_name = 'anulado_em' AND table_name <> 'escolta_conclusoes_antecipadas'
UNION ALL SELECT 'onda I: triggers de carimbo, trava e edição iniciada (esperado 9, 10, 3)', (SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_carimbar_etapa_%') || ', ' || (SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'tr_travar_colunas_gestao_%') || ', ' || (SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_impedir_edicao_escolta_iniciada')
UNION ALL SELECT 'onda I: policies novas (esperado 3)', count(*)::text FROM pg_policy WHERE polname IN ('escoltas_arquivada_so_admin', 'pontos_insert_autor', 'escoltas_delete_so_rascunho')
UNION ALL SELECT 'onda I: escoltas com versao_gestao ou arquivadas (esperado 0)', count(*)::text FROM public.escoltas WHERE versao_gestao <> 0 OR arquivada_em IS NOT NULL
UNION ALL SELECT 'onda I: travas de apagar registro anulado e viatura com registro (esperado 11)', count(*)::text FROM pg_trigger WHERE tgname LIKE 'tr_impedir_apagar_gestao_%'
UNION ALL SELECT 'onda I: central lê a conclusão antecipada (esperado true)', (pg_get_expr(polqual, polrelid) LIKE '%central%')::text FROM pg_policy WHERE polname = 'escolta_conclusoes_leitura'
UNION ALL SELECT 'onda D2: triggers de uso e authenticated sem UPDATE de vezes_usado (esperado 2, false)', (SELECT count(*) FROM pg_trigger WHERE tgname IN ('tr_contar_uso_local', 'tr_recontar_uso_locais')) || ', ' || has_column_privilege('authenticated', 'public.locais_salvos', 'vezes_usado', 'UPDATE')::text
UNION ALL SELECT 'onda D2: falhas da contagem de uso (esperado 0; repetir depois do deploy e no fim da homologação)', count(*)::text FROM lote_interno.locais_uso_falhas
UNION ALL SELECT 'onda D2: locais com UF RJ (esperado 5) e uso carregado das escoltas', (SELECT count(*) FROM public.locais_salvos WHERE uf = 'RJ') || '; ' || (SELECT string_agg(nome || '=' || vezes_usado, ', ' ORDER BY vezes_usado DESC, nome) FROM public.locais_salvos);
-- Esperado: 9 funções, 8 tabelas, 0 abertas com periodicidade, 5 locais aguardando_conferencia,
-- troca true,true, cron lote2026_avisos_telegram e lote2026_avisos_checkin; 4; notificacoes_select; 0; false; false;
-- onda I: 9; 9, 10, 3; 3; 0; 11; true; onda D2: 2, false; 0; 5 e o uso de cada local (escoltas não canceladas). ESC-2026-0001 e 0007: atualizado_em igual ao da consulta prévia
-- (a 213 não reescreve a linha; a carga da 215 só lê escoltas).
-- 'envio pelo banco ativo' falso: o Telegram do check-in sai pelo navegador (reserva no banco,
-- reservar_alertas_checkin), não pelo cron; anotar no relatório qual caminho valeu.

-- ════════════════════════════════════════════════════════════════════════════
-- BLOCO 2 (logo depois do deploy das ondas A, C, G, J e I)
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ──────── 204_mural_travas_rpcs.sql ────────
-- 204_mural_travas_rpcs.sql
-- Lote 2026-10, onda C (M5, travas do mural). Idempotente.
-- BLOCO 2: aplicar logo DEPOIS do deploy do código da onda C. Antes do deploy, o diálogo
-- antigo mandaria motivo de 5 caracteres e esperaria troca imediata.
-- Depende da 202 (fila de avisos) e da 203 (estrutura).
--
-- Regras (decisões de Peçanha de 08/10/2026), todas validadas aqui, no servidor:
--   T1 janela: escolta com equipe só pode ser pedida a partir de N min antes da hora prevista.
--   T2 presença: com presença na base confirmada pela equipe escalada, ninguém assume.
--   T3 aprovação: dentro da janela e sem presença, assumir escolta com equipe vira pedido;
--      supervisor ou acima aprova ou recusa; sem resposta em N min, o banco libera sozinho
--      (pg_cron a cada minuto e toda consulta de pedido).
--   T4 aviso: equipe substituída e supervisão avisadas no aplicativo; chat central do
--      Telegram pela fila (uma mensagem por evento). Não há chat por pessoa no sistema.
--   T5 sobreposição: ninguém fica comandante de duas escoltas agendadas a menos de N h.
--   T6 escala fixa: some do mural; só a gestão muda a equipe.
--   T7 auditoria: puxar, assumir, pedir, decidir, substituir, devolver, incluir e
--      confirmar presença ficam em logs_auditoria; pedidos ficam em mural_pedidos.
-- Concorrência: toda decisão trava primeiro a escolta e depois o pedido, e muda o status
-- do pedido com UPDATE ... WHERE status = 'pendente'; só segue se uma linha mudar.
-- Onda G (revisão adversarial, com os índices únicos da 210 aplicados logo depois desta):
-- assumir_escolta recusa a placa de outra viatura da mesma escolta; _executar_substituicao
-- invalida o pedido nesse caso e quando uma gravação esbarra num índice único;
-- processar_pedidos_vencidos isola cada pedido num bloco próprio (um pedido com erro vira
-- 'invalidado', com auditoria, e não trava os outros nem o cron).

-- ── Auxiliares internas (sem GRANT a ninguém) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public._hora_br(p timestamptz) RETURNS text
    LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT to_char(p AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
$$;

CREATE OR REPLACE FUNCTION public._equipe_atual(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('vigilante_id', ee.vigilante_id, 'vigilante', v.nome_completo,
                                               'papel', ee.papel_na_escolta)
                            ORDER BY (ee.papel_na_escolta <> 'comandante'), v.nome_completo), '[]'::jsonb)
  FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
  WHERE ee.escolta_id = p_escolta_id
$$;

CREATE OR REPLACE FUNCTION public._ids_da_equipe(p_equipe jsonb) RETURNS uuid[]
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(array_agg((e ->> 'vigilante_id')::uuid ORDER BY (e ->> 'vigilante_id')), '{}')
  FROM jsonb_array_elements(coalesce(p_equipe, '[]'::jsonb)) e
  WHERE e ? 'vigilante_id'
$$;

CREATE OR REPLACE FUNCTION public._nomes_da_equipe(p_equipe jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(string_agg(e ->> 'vigilante', ', '), 'sem equipe') FROM jsonb_array_elements(coalesce(p_equipe, '[]'::jsonb)) e
$$;

-- T5: código de outra escolta agendada em que o vigilante é comandante, a menos de N h.
CREATE OR REPLACE FUNCTION public._conflito_comandante(p_vigilante_id uuid, p_escolta_id uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT o.codigo_escolta
  FROM public.escoltas alvo
  CROSS JOIN public.configuracoes_mural cfg
  JOIN public.escolta_efetivo ee ON ee.vigilante_id = p_vigilante_id AND ee.papel_na_escolta = 'comandante'
  JOIN public.escoltas o ON o.id = ee.escolta_id
  WHERE alvo.id = p_escolta_id AND cfg.id = 1
    AND o.id <> p_escolta_id AND o.status = 'agendada'
    AND abs(extract(epoch FROM (o.data_hora_prevista - alvo.data_hora_prevista))) < cfg.intervalo_comandante_h * 3600
  LIMIT 1
$$;

-- T5 sob concorrência: serializa por vigilante (ordem de travas: escolta, vigilante, pedido).
CREATE OR REPLACE FUNCTION public._travar_vigilante(p_vigilante_id uuid) RETURNS void
    LANGUAGE sql VOLATILE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT pg_advisory_xact_lock(hashtextextended('lote2026_t5:' || p_vigilante_id::text, 0))
$$;

-- T2: alguém da equipe atual confirmou presença na base?
CREATE OR REPLACE FUNCTION public._presenca_da_equipe(p_escolta_id uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT string_agg(v.nome_completo, ', ')
  FROM public.mural_presencas mp
  JOIN public.escolta_efetivo ee ON ee.escolta_id = mp.escolta_id AND ee.vigilante_id = mp.vigilante_id
  JOIN public.vigilantes v ON v.id = mp.vigilante_id
  WHERE mp.escolta_id = p_escolta_id
$$;

CREATE OR REPLACE FUNCTION public._supervisao_ids() RETURNS uuid[]
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(array_agg(u.id), '{}') FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
  WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor')
$$;

CREATE OR REPLACE FUNCTION public._usuarios_dos_vigilantes(p_vigilantes uuid[]) RETURNS uuid[]
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(array_agg(DISTINCT v.usuario_id), '{}') FROM public.vigilantes v
  WHERE v.id = ANY (p_vigilantes) AND v.usuario_id IS NOT NULL
$$;

-- Aviso no aplicativo (tabela notificacoes, canal app).
CREATE OR REPLACE FUNCTION public._avisar_app(p_escolta_id uuid, p_tipo text, p_usuarios uuid[], p_titulo text, p_texto text, p_pedido_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF NOT coalesce((SELECT aviso_ligado FROM public.configuracoes_mural WHERE id = 1), true) THEN RETURN; END IF;
  INSERT INTO public.notificacoes (escolta_id, canal, tipo_evento_id, destino, payload, usuario_dest_id, status_envio)
  SELECT p_escolta_id, 'app', (SELECT id FROM public.dom_tipos_evento WHERE codigo = p_tipo), 'app',
         jsonb_build_object('titulo', p_titulo, 'texto', p_texto, 'pedido_id', p_pedido_id), u, 'enviada'
  FROM unnest(p_usuarios) AS u
  WHERE u IS NOT NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public._auditar_mural(p_acao text, p_escolta_id uuid, p_antes jsonb, p_depois jsonb) RETURNS void
    LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES ((SELECT id FROM public.usuarios WHERE auth_user_id = auth.uid()), p_acao, 'escoltas', p_escolta_id, p_antes, p_depois, now())
$$;

-- Texto de aviso ao chat central (HTML escapado, hora de Brasília).
CREATE OR REPLACE FUNCTION public._texto_aviso_mural(p_titulo text, p_escolta_id uuid, p_linhas text[]) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT '<b>' || public.escapar_html(p_titulo) || '</b>' || E'\n'
      || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(c.nome_cliente) || E'\n'
      || 'Prevista: ' || public._hora_br(e.data_hora_prevista) || E'\n'
      || coalesce((SELECT string_agg(public.escapar_html(l), E'\n') FROM unnest(p_linhas) l), '')
  FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id WHERE e.id = p_escolta_id
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['_hora_br(timestamptz)', '_equipe_atual(uuid)', '_ids_da_equipe(jsonb)', '_nomes_da_equipe(jsonb)',
                           '_conflito_comandante(uuid, uuid)', '_presenca_da_equipe(uuid)', '_supervisao_ids()', '_travar_vigilante(uuid)',
                           '_usuarios_dos_vigilantes(uuid[])', '_avisar_app(uuid, text, uuid[], text, text, uuid)',
                           '_auditar_mural(text, uuid, jsonb, jsonb)', '_texto_aviso_mural(text, uuid, text[])']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- ── Execução da substituição (interna) ───────────────────────────────────────────
-- Só é chamada depois que o pedido mudou de 'pendente' para 'aprovado' ou
-- 'liberado_por_tempo' sob trava (escolta e pedido). Confere tudo de novo.
CREATE OR REPLACE FUNCTION public._executar_substituicao(p_pedido_id uuid, p_via text) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  p public.mural_pedidos%ROWTYPE;
  e record; v_motivo text; v_ev uuid; v_acomp uuid; v_equipe_agora jsonb; v_presenca text; v_conflito text;
  v_nome text; v_aviso boolean;
BEGIN
  SELECT * INTO p FROM public.mural_pedidos WHERE id = p_pedido_id;
  IF p.id IS NULL OR p.status NOT IN ('aprovado', 'liberado_por_tempo') THEN
    RAISE EXCEPTION 'Pedido nao esta liberado para execucao.';
  END IF;
  SELECT id, status, escala_fixa, codigo_escolta, data_hora_prevista INTO e FROM public.escoltas WHERE id = p.escolta_id;
  PERFORM public._travar_vigilante(p.solicitante_vigilante_id);
  v_equipe_agora := public._equipe_atual(p.escolta_id);
  v_presenca := CASE WHEN (SELECT presenca_ligada FROM public.configuracoes_mural WHERE id = 1)
                     THEN public._presenca_da_equipe(p.escolta_id) END;
  v_conflito := public._conflito_comandante(p.solicitante_vigilante_id, p.escolta_id);

  v_motivo := CASE
    WHEN e.status IS DISTINCT FROM 'agendada' THEN 'a escolta ja comecou ou foi encerrada'
    WHEN e.escala_fixa THEN 'a escolta passou a ser de escala fixa'
    WHEN now() < e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1))
      THEN 'a escolta foi remarcada e saiu da janela de substituicao'
    WHEN v_presenca IS NOT NULL THEN 'a equipe confirmou presenca na base (' || v_presenca || ')'
    WHEN public._ids_da_equipe(v_equipe_agora) IS DISTINCT FROM public._ids_da_equipe(p.equipe_antes) THEN 'a equipe da escolta mudou depois do pedido'
    WHEN v_conflito IS NOT NULL THEN 'o solicitante passou a comandar a escolta ' || v_conflito || ' a menos do intervalo minimo'
    WHEN NOT EXISTS (SELECT 1 FROM public.vigilantes v JOIN public.usuarios u ON u.id = v.usuario_id
                     WHERE v.id = p.solicitante_vigilante_id AND v.status = 'ativo' AND u.status = 'ativo') THEN 'o solicitante nao esta mais ativo'
    WHEN EXISTS (SELECT 1 FROM unnest(p.acompanhantes) a WHERE NOT EXISTS
                 (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN 'um acompanhante nao esta mais ativo'
    WHEN p.veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p.veiculo_id AND status = 'ativo') THEN 'a viatura indicada nao esta mais ativa'
    -- Onda G (210): a placa escolhida não pode estar em outra viatura da mesma escolta.
    WHEN p.veiculo_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p.escolta_id AND ev.veiculo_id = p.veiculo_id
              AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1))
      THEN 'a viatura indicada já está em outra viatura da escolta'
  END;

  -- Onda G (210): os índices únicos do efetivo e das viaturas recusam repetição. Se uma
  -- gravação esbarrar neles, a troca inteira é desfeita e o pedido é invalidado com o
  -- motivo, em vez de o erro técnico subir para quem aprovou ou para o cron.
  IF v_motivo IS NULL THEN
    BEGIN
      SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1;
      IF p.veiculo_id IS NOT NULL THEN
        UPDATE public.escolta_veiculos SET veiculo_id = p.veiculo_id, atualizado_em = now(), atualizado_por = p.solicitante_usuario_id
         WHERE id = v_ev;
      END IF;
      DELETE FROM public.escolta_efetivo WHERE escolta_id = p.escolta_id;
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p.escolta_id, v_ev, p.solicitante_vigilante_id, 'comandante', true, p.solicitante_usuario_id);
      FOREACH v_acomp IN ARRAY p.acompanhantes LOOP
        IF v_acomp IS DISTINCT FROM p.solicitante_vigilante_id THEN
          INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
          VALUES (p.escolta_id, v_ev, v_acomp, 'operador', false, p.solicitante_usuario_id) ON CONFLICT DO NOTHING;
        END IF;
      END LOOP;
    EXCEPTION WHEN unique_violation THEN
      v_motivo := 'a viatura ou um vigilante indicado já está na escolta';
    END;
  END IF;

  IF v_motivo IS NOT NULL THEN
    UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = coalesce(decidido_em, now()),
           observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: ' || v_motivo || '.')
     WHERE id = p.id;
    INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
    VALUES (p.decidido_por, 'pedido_substituicao_invalidado', 'escoltas', p.escolta_id, jsonb_build_object('pedido_id', p.id),
            jsonb_build_object('pedido_id', p.id, 'via', p_via, 'motivo', v_motivo), now());
    PERFORM public._avisar_app(p.escolta_id, 'decisao_substituicao', ARRAY[p.solicitante_usuario_id],
      'Pedido de substituição invalidado', 'O pedido para a escolta ' || e.codigo_escolta || ' não foi executado: ' || v_motivo || '.', p.id);
    RETURN false;
  END IF;

  SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = p.solicitante_vigilante_id;
  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES (p.solicitante_usuario_id, 'substituicao_de_equipe', 'escoltas', p.escolta_id,
          jsonb_build_object('equipe', p.equipe_antes),
          jsonb_build_object('pedido_id', p.id, 'via', p_via, 'assumida_por', v_nome, 'motivo', p.motivo,
                             'acompanhantes', (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (p.acompanhantes)),
                             'trocou_viatura', p.veiculo_id IS NOT NULL,
                             'decidido_por', (SELECT nome_completo FROM public.usuarios WHERE id = p.decidido_por)),
          now());

  PERFORM public._avisar_app(p.escolta_id, 'substituicao_equipe',
    public._usuarios_dos_vigilantes(public._ids_da_equipe(p.equipe_antes)) || public._supervisao_ids() || ARRAY[p.solicitante_usuario_id],
    'Equipe substituída na escolta ' || e.codigo_escolta,
    v_nome || ' assumiu a escolta em ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo, sem resposta da supervisão)' ELSE ' (aprovado pela supervisão)' END
      || '. Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes) || '. Motivo: ' || p.motivo,
    p.id);
  v_aviso := public._enfileirar_aviso('substituicao:' || p.id, 'central', p.escolta_id,
    public._texto_aviso_mural('Equipe substituída', p.escolta_id, ARRAY[
      'Assumiu: ' || v_nome,
      'Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes),
      'Quando: ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo)' ELSE ' (aprovado)' END,
      'Motivo: ' || p.motivo]));
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public._executar_substituicao(uuid, text) FROM PUBLIC, anon, authenticated;

-- ── Liberação por tempo (interna; pg_cron e consultas) ─────────────────────────────
CREATE OR REPLACE FUNCTION public.processar_pedidos_vencidos() RETURNS integer
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE r record; n int := 0; v_estado text; v_erro text;
BEGIN
  FOR r IN SELECT id, escolta_id, solicitante_usuario_id FROM public.mural_pedidos
            WHERE status = 'pendente' AND expira_em < now() ORDER BY criado_em LOOP
    -- Onda G: cada pedido no próprio bloco. Um pedido com erro é desfeito sozinho, vira
    -- 'invalidado' com o motivo e a auditoria, e os demais (e o cron) seguem.
    BEGIN
      PERFORM 1 FROM public.escoltas WHERE id = r.escolta_id FOR UPDATE;
      UPDATE public.mural_pedidos SET status = 'liberado_por_tempo', decidido_em = now()
       WHERE id = r.id AND status = 'pendente' AND expira_em < now();
      IF FOUND THEN
        PERFORM public._executar_substituicao(r.id, 'liberado_por_tempo');
        n := n + 1;
      END IF;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_estado = RETURNED_SQLSTATE, v_erro = MESSAGE_TEXT;
      UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
             observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: erro na liberação automática (registrado na auditoria).')
       WHERE id = r.id AND status = 'pendente';
      INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
      VALUES (NULL, 'pedido_substituicao_erro_liberacao', 'escoltas', r.escolta_id, jsonb_build_object('pedido_id', r.id),
              jsonb_build_object('pedido_id', r.id, 'sqlstate', v_estado, 'erro', v_erro), now());
      PERFORM public._avisar_app(r.escolta_id, 'decisao_substituicao', ARRAY[r.solicitante_usuario_id],
        'Pedido de substituição invalidado',
        'O pedido para a escolta ' || coalesce((SELECT codigo_escolta FROM public.escoltas WHERE id = r.escolta_id), '') ||
        ' não pôde ser executado na liberação automática. Fale com o supervisor.', r.id);
    END;
  END LOOP;
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.processar_pedidos_vencidos() FROM PUBLIC, anon, authenticated;

-- ── RPCs do cliente ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[] DEFAULT '{}'::uuid[],
                                                 p_veiculo_id uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  v_perfil text; v_usuario uuid; v_vigilante uuid; e record; cfg record; v_qtd int; v_ev uuid; v_acomp uuid;
  v_conflito text; v_presenca text; v_ped record; v_equipe jsonb; v_nome text; v_aviso boolean; v_inicio timestamptz;
  v_acomp_limpo uuid[];
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo. Fale com o administrador.';
  END IF;

  -- Trava a linha: duas pessoas assumindo ao mesmo tempo produziriam duas equipes.
  SELECT id, status, escala_fixa, data_hora_prevista, codigo_escolta INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.status <> 'agendada' THEN
    RAISE EXCEPTION 'Esta escolta ja comecou e nao pode ter a equipe trocada. Fale com o supervisor.';
  END IF;
  IF e.escala_fixa THEN
    RAISE EXCEPTION 'Escolta de escala fixa: a equipe e definida pela supervisao.';
  END IF;
  PERFORM public._travar_vigilante(v_vigilante);

  v_acomp_limpo := ARRAY(SELECT DISTINCT a FROM unnest(coalesce(p_acompanhantes, '{}')) a WHERE a IS DISTINCT FROM v_vigilante);
  IF EXISTS (SELECT 1 FROM unnest(v_acomp_limpo) a WHERE NOT EXISTS
             (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN
    RAISE EXCEPTION 'Acompanhante invalido ou inativo.';
  END IF;
  IF p_veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p_veiculo_id AND status = 'ativo') THEN
    RAISE EXCEPTION 'Viatura invalida ou fora de operacao.';
  END IF;
  -- Onda G (210): a placa escolhida troca a primeira viatura; não pode ser a de outra
  -- viatura da mesma escolta.
  IF p_veiculo_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_escolta_id AND ev.veiculo_id = p_veiculo_id
          AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1)) THEN
    RAISE EXCEPTION 'Esta viatura já está em outra viatura desta escolta. Escolha outra placa ou mantenha a atual.';
  END IF;

  SELECT * INTO cfg FROM public.configuracoes_mural WHERE id = 1;
  SELECT count(*) INTO v_qtd FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = v_vigilante;

  -- Escolta sem equipe: assume na hora, como antes, com T5.
  IF v_qtd = 0 THEN
    v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
    IF v_conflito IS NOT NULL THEN
      RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
    END IF;
    SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
    IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
    BEGIN
      IF p_veiculo_id IS NOT NULL THEN
        UPDATE public.escolta_veiculos SET veiculo_id = p_veiculo_id, atualizado_em = now(), atualizado_por = v_usuario WHERE id = v_ev;
      END IF;
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
      FOREACH v_acomp IN ARRAY v_acomp_limpo LOOP
        INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
        VALUES (p_escolta_id, v_ev, v_acomp, 'operador', false, v_usuario) ON CONFLICT DO NOTHING;
      END LOOP;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'A viatura ou um vigilante escolhido já está nesta escolta. Revise a equipe e a viatura e tente de novo.';
    END;
    PERFORM public._auditar_mural('assumiu_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
      jsonb_build_object('assumida_por', v_nome, 'acompanhantes',
        (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (v_acomp_limpo)),
        'trocou_viatura', p_veiculo_id IS NOT NULL));
    RETURN jsonb_build_object('ok', true, 'status', 'assumida', 'substituiu_equipe', false);
  END IF;

  -- Escolta com equipe: vira pedido, dentro das travas.
  IF EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
    RAISE EXCEPTION 'Voce ja esta na equipe desta escolta.';
  END IF;
  IF p_motivo IS NULL OR length(trim(p_motivo)) < 20 THEN
    RAISE EXCEPTION 'Informe o motivo da substituicao com pelo menos 20 caracteres.';
  END IF;
  IF length(trim(p_motivo)) > 500 THEN
    RAISE EXCEPTION 'O motivo pode ter no maximo 500 caracteres.';
  END IF;
  v_inicio := e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min);
  IF now() < v_inicio THEN
    RAISE EXCEPTION 'Substituicao de equipe liberada a partir de % (horario de Brasilia).', public._hora_br(v_inicio);
  END IF;
  IF cfg.presenca_ligada THEN
    v_presenca := public._presenca_da_equipe(p_escolta_id);
    IF v_presenca IS NOT NULL THEN
      RAISE EXCEPTION 'A equipe escalada ja confirmou presenca na base. Fale com o supervisor.';
    END IF;
  END IF;
  v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
  IF v_conflito IS NOT NULL THEN
    RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
  END IF;

  SELECT id, solicitante_usuario_id, expira_em INTO v_ped FROM public.mural_pedidos
  WHERE escolta_id = p_escolta_id AND status = 'pendente' FOR UPDATE;
  IF v_ped.id IS NOT NULL THEN
    IF v_ped.solicitante_usuario_id = v_usuario THEN
      RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em, 'ja_existia', true);
    END IF;
    RAISE EXCEPTION 'Ja existe um pedido de substituicao em analise para esta escolta.';
  END IF;

  v_equipe := public._equipe_atual(p_escolta_id);
  INSERT INTO public.mural_pedidos (escolta_id, solicitante_usuario_id, solicitante_vigilante_id, acompanhantes, veiculo_id,
                                    motivo, equipe_antes, expira_em, antecedencia_min)
  VALUES (p_escolta_id, v_usuario, v_vigilante, v_acomp_limpo, p_veiculo_id, trim(p_motivo), v_equipe,
          now() + make_interval(mins => cfg.aprovacao_tempo_limite_min),
          round(extract(epoch FROM (e.data_hora_prevista - now())) / 60)::int)
  RETURNING id, expira_em INTO v_ped;

  PERFORM public._auditar_mural('pedido_substituicao', p_escolta_id, jsonb_build_object('equipe', v_equipe),
    jsonb_build_object('pedido_id', v_ped.id, 'solicitante', v_nome, 'motivo', trim(p_motivo), 'expira_em', v_ped.expira_em));
  PERFORM public._avisar_app(p_escolta_id, 'pedido_substituicao', public._supervisao_ids(),
    'Pedido de substituição na escolta ' || e.codigo_escolta,
    v_nome || ' pediu para assumir. Equipe atual: ' || public._nomes_da_equipe(v_equipe) || '. Motivo: ' || trim(p_motivo)
      || '. Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.', v_ped.id);
  v_aviso := public._enfileirar_aviso('pedido:' || v_ped.id, 'central', p_escolta_id,
    public._texto_aviso_mural('Pedido de substituição de equipe', p_escolta_id, ARRAY[
      'Solicitante: ' || v_nome,
      'Equipe atual: ' || public._nomes_da_equipe(v_equipe),
      'Motivo: ' || trim(p_motivo),
      'Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.']));
  RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em,
                            'aviso_pelo_banco', v_aviso, 'codigo', e.codigo_escolta, 'equipe_atual', public._nomes_da_equipe(v_equipe));
END;
$$;
COMMENT ON FUNCTION public.assumir_escolta(uuid, uuid[], uuid, text) IS
  'Lote 2026-10 (M5): escolta sem equipe é assumida na hora (T5, T6); com equipe, vira pedido à supervisão dentro das travas T1, T2, T5, T6, com motivo de 20 caracteres.';

CREATE OR REPLACE FUNCTION public.puxar_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_ev uuid; v_ja int; v_conflito text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo. Fale com o administrador.';
  END IF;
  -- Trava a linha: sem isto, dois operadores puxam a mesma escolta no mesmo instante.
  SELECT id, status, escala_fixa INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'Esta escolta nao esta mais disponivel: ela ja saiu do mural.'; END IF;
  IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: a equipe e definida pela supervisao.'; END IF;
  PERFORM public._travar_vigilante(v_vigilante);
  SELECT count(*) INTO v_ja FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  IF v_ja > 0 THEN RAISE EXCEPTION 'Esta escolta ja tem equipe designada.'; END IF;
  v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
  IF v_conflito IS NOT NULL THEN
    RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito,
      (SELECT intervalo_comandante_h FROM public.configuracoes_mural WHERE id = 1);
  END IF;
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
  INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
  PERFORM public._auditar_mural('puxou_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
    jsonb_build_object('assumida_por', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante)));
  RETURN jsonb_build_object('ok', true, 'escolta_veiculo_id', v_ev);
END;
$$;

CREATE OR REPLACE FUNCTION public.devolver_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_vigilante uuid; e record; v_sou_cmd int; v_equipe jsonb; v_gestao boolean;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_vigilante := public.get_meu_vigilante_id();
  v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
  SELECT id, status, escala_fixa INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  -- So devolve enquanto nao comecou. Depois de iniciada, sair da escolta e decisao de supervisor.
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta ja comecou. Fale com o supervisor para sair dela.'; END IF;
  IF NOT v_gestao THEN
    IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: so a supervisao altera a equipe.'; END IF;
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante devolve a escolta ao mural.'; END IF;
  END IF;
  v_equipe := public._equipe_atual(p_escolta_id);
  DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  DELETE FROM public.mural_presencas WHERE escolta_id = p_escolta_id;
  PERFORM public._auditar_mural('devolveu_escolta_ao_mural', p_escolta_id, jsonb_build_object('equipe', v_equipe), '{"equipe": []}'::jsonb);
  -- Quem saiu junto (acompanhantes) fica sabendo pelo aplicativo.
  PERFORM public._avisar_app(p_escolta_id, 'substituicao_equipe',
    ARRAY(SELECT u FROM unnest(public._usuarios_dos_vigilantes(public._ids_da_equipe(v_equipe))) u WHERE u IS DISTINCT FROM public.get_meu_usuario_id()),
    'Escolta devolvida ao mural', 'A escolta ' || (SELECT codigo_escolta FROM public.escoltas WHERE id = p_escolta_id)
      || ' foi devolvida ao mural em ' || public._hora_br(now()) || '. Você não está mais escalado nela.', NULL);
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.incluir_vigilante_na_minha_escolta(p_escolta_id uuid, p_vigilante_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_sou_cmd int; v_ev uuid; v_dup int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  SELECT id, status, escala_fixa INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta ja comecou. Alteracao de equipe passa pelo supervisor.'; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') THEN
    IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: so a supervisao altera a equipe.'; END IF;
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante inclui vigilante nesta escolta.'; END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vigilantes WHERE id = p_vigilante_id AND status = 'ativo') THEN
    RAISE EXCEPTION 'Vigilante invalido ou inativo.';
  END IF;
  SELECT count(*) INTO v_dup FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = p_vigilante_id;
  IF v_dup > 0 THEN RAISE EXCEPTION 'Este vigilante ja esta na escolta.'; END IF;
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada.'; END IF;
  BEGIN
    INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
    VALUES (p_escolta_id, v_ev, p_vigilante_id, 'operador', false, v_usuario);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Este vigilante ja esta na escolta.';
  END;
  PERFORM public._auditar_mural('incluiu_vigilante', p_escolta_id, '{}'::jsonb,
    jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = p_vigilante_id)));
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- T2: presença na base.
CREATE OR REPLACE FUNCTION public.confirmar_presenca_base(p_escolta_id uuid, p_lat numeric DEFAULT NULL, p_lng numeric DEFAULT NULL,
                                                         p_precisao numeric DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_inicio timestamptz; v_ped uuid;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo.'; END IF;
  SELECT id, status, data_hora_prevista, codigo_escolta INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A presenca na base so e confirmada antes do inicio da escolta.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
    RAISE EXCEPTION 'Voce nao esta na equipe desta escolta.';
  END IF;
  v_inicio := e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1));
  IF now() < v_inicio THEN
    RAISE EXCEPTION 'A confirmacao de presenca abre as % (horario de Brasilia).', public._hora_br(v_inicio);
  END IF;
  INSERT INTO public.mural_presencas (escolta_id, vigilante_id, usuario_id, latitude, longitude, precisao_metros, sem_gps)
  VALUES (p_escolta_id, v_vigilante, v_usuario, p_lat, p_lng, p_precisao, p_lat IS NULL OR p_lng IS NULL)
  ON CONFLICT (escolta_id, vigilante_id) DO NOTHING;
  PERFORM public._auditar_mural('presenca_na_base', p_escolta_id, '{}'::jsonb,
    jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante),
                       'latitude', p_lat, 'longitude', p_lng, 'precisao_metros', p_precisao));
  -- Pedido pendente perde o objeto: a equipe chegou.
  UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
         observacao_decisao = 'Invalidado: a equipe confirmou presenca na base.'
   WHERE escolta_id = p_escolta_id AND status = 'pendente'
  RETURNING id INTO v_ped;
  IF v_ped IS NOT NULL THEN
    PERFORM public._avisar_app(p_escolta_id, 'decisao_substituicao',
      ARRAY[(SELECT solicitante_usuario_id FROM public.mural_pedidos WHERE id = v_ped)],
      'Pedido de substituição invalidado', 'A equipe da escolta ' || e.codigo_escolta || ' confirmou presença na base.', v_ped);
  END IF;
  RETURN jsonb_build_object('ok', true, 'confirmado_em', now());
END;
$$;

-- T3: decisões.
CREATE OR REPLACE FUNCTION public.aprovar_pedido_mural(p_pedido_id uuid, p_observacao text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_esc uuid; v_sol uuid; v_ok boolean; v_status text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Apenas supervisor ou acima decide pedidos de substituicao.';
  END IF;
  v_usuario := public.get_meu_usuario_id();
  SELECT escolta_id, solicitante_usuario_id INTO v_esc, v_sol FROM public.mural_pedidos WHERE id = p_pedido_id;
  IF v_esc IS NULL THEN RAISE EXCEPTION 'Pedido nao encontrado.'; END IF;
  IF v_sol = v_usuario THEN RAISE EXCEPTION 'Voce nao pode decidir o proprio pedido.'; END IF;
  PERFORM 1 FROM public.escoltas WHERE id = v_esc FOR UPDATE;          -- ordem fixa: escolta, depois pedido
  UPDATE public.mural_pedidos SET status = 'aprovado', decidido_por = v_usuario, decidido_em = now(),
         observacao_decisao = nullif(trim(coalesce(p_observacao, '')), '')
   WHERE id = p_pedido_id AND status = 'pendente'
  RETURNING status INTO v_status;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Este pedido ja foi decidido.'; END IF;
  v_ok := public._executar_substituicao(p_pedido_id, 'aprovado');
  PERFORM public._avisar_app(v_esc, 'decisao_substituicao', ARRAY[v_sol],
    CASE WHEN v_ok THEN 'Pedido de substituição aprovado' ELSE 'Pedido de substituição não executado' END,
    CASE WHEN v_ok THEN 'Você assumiu a escolta.' ELSE 'O pedido foi aprovado, mas a escolta mudou antes da execução.' END, p_pedido_id);
  PERFORM public._auditar_mural('pedido_substituicao_aprovado', v_esc, '{}'::jsonb, jsonb_build_object('pedido_id', p_pedido_id, 'executado', v_ok));
  RETURN jsonb_build_object('ok', true, 'executado', v_ok, 'aviso_pelo_banco', public.avisos_pelo_banco_ativos());
END;
$$;

CREATE OR REPLACE FUNCTION public.recusar_pedido_mural(p_pedido_id uuid, p_motivo text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_esc uuid; v_sol uuid; v_status text; v_aviso boolean; v_nome text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Apenas supervisor ou acima decide pedidos de substituicao.';
  END IF;
  v_usuario := public.get_meu_usuario_id();
  SELECT escolta_id, solicitante_usuario_id INTO v_esc, v_sol FROM public.mural_pedidos WHERE id = p_pedido_id;
  IF v_esc IS NULL THEN RAISE EXCEPTION 'Pedido nao encontrado.'; END IF;
  IF v_sol = v_usuario THEN RAISE EXCEPTION 'Voce nao pode decidir o proprio pedido.'; END IF;
  PERFORM 1 FROM public.escoltas WHERE id = v_esc FOR UPDATE;
  UPDATE public.mural_pedidos SET status = 'recusado', decidido_por = v_usuario, decidido_em = now(),
         observacao_decisao = nullif(trim(coalesce(p_motivo, '')), '')
   WHERE id = p_pedido_id AND status = 'pendente'
  RETURNING status INTO v_status;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Este pedido ja foi decidido.'; END IF;
  SELECT nome_completo INTO v_nome FROM public.usuarios WHERE id = v_usuario;
  PERFORM public._avisar_app(v_esc, 'decisao_substituicao', ARRAY[v_sol], 'Pedido de substituição recusado',
    'Recusado por ' || v_nome || coalesce('. Motivo: ' || nullif(trim(coalesce(p_motivo, '')), ''), '') || '.', p_pedido_id);
  PERFORM public._auditar_mural('pedido_substituicao_recusado', v_esc, '{}'::jsonb,
    jsonb_build_object('pedido_id', p_pedido_id, 'motivo', p_motivo));
  v_aviso := public._enfileirar_aviso('decisao:' || p_pedido_id, 'central', v_esc,
    public._texto_aviso_mural('Pedido de substituição recusado', v_esc, ARRAY['Recusado por: ' || v_nome,
      'Motivo: ' || coalesce(nullif(trim(coalesce(p_motivo, '')), ''), 'não informado')]));
  RETURN jsonb_build_object('ok', true, 'aviso_pelo_banco', v_aviso);
END;
$$;

CREATE OR REPLACE FUNCTION public.cancelar_meu_pedido_mural(p_pedido_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_usuario uuid; v_esc uuid; v_status text;
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  SELECT escolta_id INTO v_esc FROM public.mural_pedidos WHERE id = p_pedido_id AND solicitante_usuario_id = v_usuario;
  IF v_esc IS NULL THEN RAISE EXCEPTION 'Pedido nao encontrado.'; END IF;
  PERFORM 1 FROM public.escoltas WHERE id = v_esc FOR UPDATE;
  UPDATE public.mural_pedidos SET status = 'cancelado', decidido_em = now()
   WHERE id = p_pedido_id AND status = 'pendente' RETURNING status INTO v_status;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Este pedido ja foi decidido.'; END IF;
  PERFORM public._auditar_mural('pedido_substituicao_cancelado', v_esc, '{}'::jsonb, jsonb_build_object('pedido_id', p_pedido_id));
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Leitura (VOLATILE: primeiro libera os pedidos vencidos).
CREATE OR REPLACE FUNCTION public.listar_pedidos_mural(p_desde timestamptz DEFAULT now() - interval '30 days') RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  PERFORM public.processar_pedidos_vencidos();
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'escolta_id', p.escolta_id, 'codigo', e.codigo_escolta, 'cliente', c.nome_cliente,
           'data_hora_prevista', e.data_hora_prevista, 'solicitante', sv.nome_completo, 'solicitante_usuario_id', p.solicitante_usuario_id,
           'equipe_antes', public._nomes_da_equipe(p.equipe_antes), 'motivo', p.motivo, 'status', p.status,
           'criado_em', p.criado_em, 'expira_em', p.expira_em, 'antecedencia_min', p.antecedencia_min,
           'decidido_por', du.nome_completo, 'decidido_em', p.decidido_em, 'observacao_decisao', p.observacao_decisao)
         ORDER BY p.criado_em DESC), '[]'::jsonb) INTO v
  FROM public.mural_pedidos p
  JOIN public.escoltas e ON e.id = p.escolta_id
  JOIN public.clientes c ON c.id = e.cliente_id
  JOIN public.vigilantes sv ON sv.id = p.solicitante_vigilante_id
  LEFT JOIN public.usuarios du ON du.id = p.decidido_por
  WHERE p.criado_em >= p_desde
    AND (v_perfil IN ('administrador', 'gestor', 'supervisor') OR p.solicitante_usuario_id = v_usuario);
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.consultar_pedido_mural(p_pedido_id uuid) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v jsonb;
BEGIN
  v := public.listar_pedidos_mural('-infinity');
  RETURN (SELECT x FROM jsonb_array_elements(v) x WHERE (x ->> 'id')::uuid = p_pedido_id);
END;
$$;

-- Estado do mural para a tela (janela, presença, escala fixa, pedido pendente, minha equipe).
CREATE OR REPLACE FUNCTION public.mural_info(p_escolta_ids uuid[]) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; v jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  PERFORM public.processar_pedidos_vencidos();
  SELECT coalesce(jsonb_object_agg(e.id, jsonb_build_object(
           'janela_inicio', e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min),
           'escala_fixa', e.escala_fixa,
           -- O operador não lê o efetivo dos colegas pela RLS; sem isto a tela via toda
           -- escolta agendada como "sem equipe".
           'tem_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id),
           -- Nomes só para a gestão e para a própria equipe (a RLS de mural_presencas é assim).
           'presenca', CASE WHEN public._presenca_da_equipe(e.id) IS NULL THEN NULL
                            WHEN v_perfil IN ('administrador', 'gestor', 'supervisor', 'central')
                              OR EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante)
                            THEN public._presenca_da_equipe(e.id) ELSE 'sim' END,
           'eu_confirmei', EXISTS (SELECT 1 FROM public.mural_presencas mp WHERE mp.escolta_id = e.id AND mp.vigilante_id = v_vigilante),
           'sou_da_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante),
           'pedido', (SELECT jsonb_build_object('id', p.id, 'expira_em', p.expira_em, 'meu', p.solicitante_usuario_id = v_usuario)
                      FROM public.mural_pedidos p WHERE p.escolta_id = e.id AND p.status = 'pendente'))), '{}'::jsonb)
    INTO v
  FROM public.escoltas e CROSS JOIN public.configuracoes_mural cfg
  WHERE e.id = ANY (p_escolta_ids) AND cfg.id = 1 AND e.status = 'agendada';
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.marcar_aviso_lido(p_notificacao_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  UPDATE public.notificacoes SET lida = true WHERE id = p_notificacao_id AND usuario_dest_id = public.get_meu_usuario_id();
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.meus_avisos_mural() RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v jsonb;
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'escolta_id', n.escolta_id, 'titulo', n.payload ->> 'titulo',
           'texto', n.payload ->> 'texto', 'criado_em', n.criado_em, 'tipo', t.codigo) ORDER BY n.criado_em DESC), '[]'::jsonb)
    INTO v
  FROM public.notificacoes n JOIN public.dom_tipos_evento t ON t.id = n.tipo_evento_id
  WHERE n.usuario_dest_id = public.get_meu_usuario_id() AND n.canal = 'app' AND NOT coalesce(n.lida, false)
    AND t.codigo IN ('pedido_substituicao', 'decisao_substituicao', 'substituicao_equipe')
    AND n.criado_em > now() - interval '7 days';
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.mural_travas_ativas() RETURNS boolean
    LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp' AS $$ SELECT true $$;

CREATE OR REPLACE FUNCTION public.avisos_telegram_resumo() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RAISE EXCEPTION 'Permissao negada.';
  END IF;
  RETURN jsonb_build_object(
    'envio_pelo_banco', public.avisos_pelo_banco_ativos(),
    'erro_24h', (SELECT count(*) FROM public.avisos_telegram WHERE situacao = 'erro' AND criado_em > now() - interval '24 hours'),
    'pendente', (SELECT count(*) FROM public.avisos_telegram WHERE situacao IN ('pendente', 'enviando')),
    'enviado_24h', (SELECT count(*) FROM public.avisos_telegram WHERE situacao = 'enviado' AND criado_em > now() - interval '24 hours'));
END;
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['assumir_escolta(uuid, uuid[], uuid, text)', 'puxar_escolta(uuid)', 'devolver_escolta(uuid)',
                           'incluir_vigilante_na_minha_escolta(uuid, uuid)', 'confirmar_presenca_base(uuid, numeric, numeric, numeric)',
                           'aprovar_pedido_mural(uuid, text)', 'recusar_pedido_mural(uuid, text)', 'cancelar_meu_pedido_mural(uuid)',
                           'listar_pedidos_mural(timestamptz)', 'consultar_pedido_mural(uuid)', 'mural_info(uuid[])',
                           'marcar_aviso_lido(uuid)', 'meus_avisos_mural()', 'mural_travas_ativas()', 'avisos_telegram_resumo()']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- Liberação por tempo pelo banco, a cada minuto (com pg_cron).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    EXECUTE $q$SELECT cron.schedule('lote2026_pedidos_vencidos', '* * * * *', 'SELECT public.processar_pedidos_vencidos();')$q$;
  END IF;
END $$;

-- Conferência:
-- SELECT public.mural_travas_ativas();                                         -- true
-- SELECT jobname, active FROM cron.job WHERE jobname LIKE 'lote2026%';          -- 2 linhas
-- SELECT has_function_privilege('authenticated', 'public._executar_substituicao(uuid, text)', 'EXECUTE'); -- false

-- ──────── 210_efetivo_unico.sql ────────
-- 210_efetivo_unico.sql
-- Lote 2026-10, onda G (escolta com dois vigilantes). Idempotente. BLOCO 2: aplicar logo
-- DEPOIS do deploy, em seguida à 204. Não vai no bloco 1: o formulário da master não
-- recusa vigilante nem placa repetidos e grava a escolta em várias requisições, sem
-- transação; com o índice antes do deploy, um engano desses deixaria a escolta pela
-- metade (revisão adversarial G, achado 2). O formulário novo recusa a repetição antes
-- de gravar, e as RPCs da 204 tratam o índice com mensagem (sem erro técnico).
--
-- Por quê (docs/14, seção 10; analise/onda-g.md): escolta_efetivo e escolta_veiculos não
-- tinham restrição única. A tela de criação aceitava o mesmo vigilante duas vezes na
-- escolta (na mesma viatura ou em viaturas diferentes) e a mesma placa em duas viaturas,
-- e o ON CONFLICT DO NOTHING de assumir_escolta não tinha índice em que se apoiar.
--
-- O que faz:
-- 1. Conferência embutida: se já houver vigilante repetido na mesma escolta ou veículo
--    repetido na mesma escolta, aborta sem mudar nada (no backup de 08/10: 0 e 0). A
--    correção desses dados é decisão da gestão, fora deste pacote.
-- 2. Duas travas de unicidade: índice único (escolta_id, vigilante_id) no efetivo e
--    restrição UNIQUE (escolta_id, veiculo_id) nas viaturas da escolta.
--    A das viaturas é DEFERRABLE INITIALLY IMMEDIATE (revisão adversarial da onda I, médio 1):
--    vale na hora para todos, como um índice único, mas a editar_escolta (218) adia a
--    conferência para o fim da própria transação (SET CONSTRAINTS ... DEFERRED) e assim duas
--    viaturas da mesma escolta trocam de placa entre si com UPDATE de veiculo_id, sem apagar
--    linha. Nenhuma função nem tela usa ON CONFLICT em escolta_veiculos (o ON CONFLICT da 204
--    é em escolta_efetivo, e por isso o efetivo continua índice: ON CONFLICT não aceita
--    restrição adiável como árbitro).
--
-- A auditoria de devolver_escolta não é desta migration: vai na 217 (bloco 2).
--
-- Conferência (esperado: 2 linhas, as duas com indisunique = true; a das viaturas com
-- indimmediate = true e a restrição com condeferrable = true):
-- SELECT c.relname, i.indisunique, i.indimmediate FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
--  WHERE c.relname IN ('escolta_efetivo_escolta_vigilante_uk', 'escolta_veiculos_escolta_veiculo_uk');
-- SELECT condeferrable, condeferred FROM pg_constraint WHERE conname = 'escolta_veiculos_escolta_veiculo_uk';   -- true, false

DO $$
DECLARE
  v_vig int;
  v_vei int;
BEGIN
  SELECT count(*) INTO v_vig FROM (
    SELECT 1 FROM public.escolta_efetivo GROUP BY escolta_id, vigilante_id HAVING count(*) > 1
  ) d;
  SELECT count(*) INTO v_vei FROM (
    SELECT 1 FROM public.escolta_veiculos GROUP BY escolta_id, veiculo_id HAVING count(*) > 1
  ) d;
  IF v_vig > 0 OR v_vei > 0 THEN
    RAISE EXCEPTION '210: abortada sem mudar nada. Vigilante repetido na mesma escolta: % caso(s); veículo repetido na mesma escolta: % caso(s). Corrija pela gestão e aplique de novo.', v_vig, v_vei;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS escolta_efetivo_escolta_vigilante_uk
  ON public.escolta_efetivo (escolta_id, vigilante_id);
-- Viaturas: restrição adiável. Quem aplicou a versão anterior desta migration tem um índice
-- único simples com o mesmo nome: ele sai e entra a restrição (mesmas colunas, mesmo nome).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'escolta_veiculos_escolta_veiculo_uk'
                  AND conrelid = 'public.escolta_veiculos'::regclass) THEN
    DROP INDEX IF EXISTS public.escolta_veiculos_escolta_veiculo_uk;
    ALTER TABLE public.escolta_veiculos ADD CONSTRAINT escolta_veiculos_escolta_veiculo_uk
      UNIQUE (escolta_id, veiculo_id) DEFERRABLE INITIALLY IMMEDIATE;
  END IF;
END $$;

COMMENT ON INDEX public.escolta_efetivo_escolta_vigilante_uk IS
  'Lote 2026-10, onda G (210): o mesmo vigilante entra uma vez só em cada escolta, em qualquer viatura.';
COMMENT ON CONSTRAINT escolta_veiculos_escolta_veiculo_uk ON public.escolta_veiculos IS
  'Lote 2026-10, onda G (210): a mesma viatura entra uma vez só em cada escolta. Adiável só dentro da editar_escolta (troca de placas entre viaturas, onda I).';

-- ──────── 200_fechar_bucket_fotos.sql ────────
-- 200_fechar_bucket_fotos.sql
-- Lote 2026-10, onda A (segurança). Idempotente.
-- APLICAR SÓ DEPOIS do deploy do código da onda A e do teste de produção das fotos:
-- antes disso, as telas ainda usam URL pública e todas as fotos sumiriam.
--
-- Por quê (docs/13, H7): o bucket fotos era público para leitura. Foto operacional com
-- GPS e horário ficava acessível por URL sem sessão, com caminho previsível. O código da
-- onda A passa a usar URL assinada em todas as telas e no Telegram, e a migration 198
-- deu leitura a quem tem direito à escolta.
--
-- O que faz:
-- Regra: depois da 200, a única policy de leitura do bucket fotos é fotos_leitura_autenticada.
-- 1. ABORTA sem mudar nada se houver policy FOR ALL em storage.objects que alcance o bucket
--    fotos (ela pode ser a que libera o upload) ou se nenhuma policy de INSERT o alcançar.
-- 2. Guarda em backup_20261008.policies_storage (schema não exposto pela API) toda outra
--    policy FOR SELECT que alcance o bucket, para a reversão recriá-la, e a apaga.
-- 3. Torna o bucket privado.

CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261008.policies_storage (
  policyname text PRIMARY KEY,
  definicao  text NOT NULL,
  guardada_em timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON backup_20261008.policies_storage FROM PUBLIC, anon, authenticated;

-- Uma policy "alcança fotos" quando o predicado menciona o bucket fotos ou não filtra
-- bucket_id nenhum (USING (true), só auth.role() etc.).
CREATE OR REPLACE FUNCTION backup_20261008.alcanca_fotos(p_qual text) RETURNS boolean
  LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce(p_qual, '') ILIKE '%''fotos''%' OR coalesce(p_qual, '') NOT ILIKE '%bucket_id%'
$f$;

DO $$
DECLARE v_amplas text; v_insert int; r record; v_def text; v_with text;
BEGIN
  -- (1) FOR ALL que alcança fotos: pode ser a que libera o upload. Aborta sem mudar nada.
  SELECT string_agg(policyname, ', ') INTO v_amplas
  FROM pg_policies
  WHERE schemaname = 'storage' AND tablename = 'objects' AND cmd = 'ALL'
    AND backup_20261008.alcanca_fotos(qual);
  IF v_amplas IS NOT NULL THEN
    RAISE EXCEPTION 'Policy FOR ALL que alcanca o bucket fotos (%): pode ser a que libera o upload. Nada foi alterado; decidir antes de fechar o bucket.', v_amplas;
  END IF;

  -- (1b) Sem policy de INSERT que alcance fotos, o upload já estaria quebrado: investigar antes.
  SELECT count(*) INTO v_insert
  FROM pg_policies
  WHERE schemaname = 'storage' AND tablename = 'objects' AND cmd = 'INSERT'
    AND (coalesce(with_check, '') ILIKE '%''fotos''%' OR coalesce(with_check, '') NOT ILIKE '%bucket_id%');
  IF v_insert = 0 THEN
    RAISE EXCEPTION 'Nenhuma policy de INSERT alcanca o bucket fotos. Nada foi alterado; conferir o upload antes de fechar o bucket.';
  END IF;

  -- (2) Toda outra SELECT que alcança fotos: guarda e apaga.
  FOR r IN
    SELECT policyname, permissive, roles, qual
    FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects' AND cmd = 'SELECT'
      AND permissive = 'PERMISSIVE'   -- restritiva só estreita o acesso; apagar ampliaria
      AND policyname <> 'fotos_leitura_autenticada'
      AND backup_20261008.alcanca_fotos(qual)
  LOOP
    v_def := format('CREATE POLICY %I ON storage.objects AS %s FOR SELECT TO %s USING (%s)',
                    r.policyname, r.permissive, array_to_string(r.roles, ', '), r.qual);
    INSERT INTO backup_20261008.policies_storage (policyname, definicao)
    VALUES (r.policyname, v_def) ON CONFLICT (policyname) DO NOTHING;
    EXECUTE format('DROP POLICY %I ON storage.objects', r.policyname);
    RAISE NOTICE 'Policy de leitura ampla removida (guardada): %', r.policyname;
  END LOOP;
END $$;

UPDATE storage.buckets SET public = false WHERE id = 'fotos' AND public;

-- Conferência:
-- SELECT id, public FROM storage.buckets WHERE id = 'fotos';            -- esperado: false
-- SELECT policyname, cmd, roles FROM pg_policies WHERE schemaname = 'storage';
-- Teste: abrir a URL pública antiga de uma foto em aba anônima deve dar erro.

-- ──────── 201_checkin_desligado.sql ────────
-- 201_checkin_desligado.sql
-- Lote 2026-10, onda B (M4). Idempotente. Bloco 1 (antes do deploy; compatível com o código atual)
-- e DE NOVO no bloco 2, depois do push da onda B: até o deploy, o formulário antigo ainda
-- grava 30 min em escolta nova ou editada. A segunda aplicação zera o que entrou nessa janela.
-- Não reaplicar depois disso sem conferir os clientes religados (metadados.checkin_periodico_min).
--
-- Por quê (decisão 3 de Peçanha, 08/10/2026): o check-in periódico fica desligado por
-- padrão; a coluna e a lógica de lib/checkin.ts continuam, para religar por cliente.
-- 1. Zera periodicidade_checkin_min das escoltas abertas (não finalizadas nem canceladas).
--    Inclui ESC-2026-0001 e ESC-2026-0007, só esse campo: desliga o alerta, não muda
--    status, histórico, equipe nem metadados. O valor anterior fica em
--    backup_20261008.periodicidade_checkin (schema não exposto pela API) para a reversão.
-- 2. alertas_dispensados: o X do aviso passa a valer por escolta até mudança real de
--    estado (novo check-in, novo status ou nova periodicidade), guardado no banco.
--    Antes o X só limpava a memória da aba e o aviso voltava a cada 5 minutos.

CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS backup_20261008.periodicidade_checkin (
  escolta_id uuid PRIMARY KEY,
  periodicidade_checkin_min integer NOT NULL,
  gravado_em timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON backup_20261008.periodicidade_checkin FROM PUBLIC, anon, authenticated;

INSERT INTO backup_20261008.periodicidade_checkin (escolta_id, periodicidade_checkin_min)
SELECT id, periodicidade_checkin_min FROM public.escoltas
WHERE status NOT IN ('finalizada', 'cancelada') AND periodicidade_checkin_min IS NOT NULL
ON CONFLICT (escolta_id) DO NOTHING;

UPDATE public.escoltas SET periodicidade_checkin_min = NULL
WHERE status NOT IN ('finalizada', 'cancelada') AND periodicidade_checkin_min IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.alertas_dispensados (
  usuario_id    uuid NOT NULL REFERENCES public.usuarios(id) ON DELETE CASCADE,
  escolta_id    uuid NOT NULL REFERENCES public.escoltas(id) ON DELETE CASCADE,
  tipo          text NOT NULL CHECK (tipo IN ('checkin')),
  assinatura    text NOT NULL,
  dispensado_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (usuario_id, escolta_id, tipo)
);
COMMENT ON TABLE public.alertas_dispensados IS
  'Lote 2026-10: aviso fechado pelo usuário. Vale enquanto a assinatura do estado da escolta (status | referência do prazo | periodicidade) for a mesma.';
ALTER TABLE public.alertas_dispensados ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.alertas_dispensados FROM anon;
REVOKE ALL ON public.alertas_dispensados FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.alertas_dispensados TO authenticated;
DROP POLICY IF EXISTS alertas_dispensados_proprio ON public.alertas_dispensados;
CREATE POLICY alertas_dispensados_proprio ON public.alertas_dispensados FOR ALL TO authenticated
  USING (usuario_id = (SELECT public.get_meu_usuario_id()))
  WITH CHECK (usuario_id = (SELECT public.get_meu_usuario_id()));

-- Conferência:
-- SELECT count(*) FROM escoltas WHERE status NOT IN ('finalizada','cancelada') AND periodicidade_checkin_min IS NOT NULL; -- 0
-- SELECT count(*) FROM backup_20261008.periodicidade_checkin;   -- 8 em 08/10/2026

-- ──────── 217_mural_central.sql ────────
-- 217_mural_central.sql
-- Lote 2026-10, onda J (ajuste da onda C). Idempotente. Bloco 2, depois da 204 (recria
-- funções dela), da 211 (usa lote_interno.notificar e as colunas da central) e da 212
-- (liga a coluna checkin_telegram_pelo_cron).
--
-- Por quê (docs/14, seções 11.3a e 17): os avisos do mural (pedido, decisão e
-- substituição) passam a cair na central de avisos e no sino, gravados uma vez por
-- destinatário e por evento, com título e texto nas colunas da central.
-- 1. _avisar_app chama lote_interno.notificar, com chave <tipo>:<pedido_id> (sem pedido,
--    sem chave, como antes) e o pedido_id no payload; aviso_ligado continua valendo.
-- 2. marcar_aviso_lido grava lida_em (o gatilho da 211 acerta lida); o nome do parâmetro
--    não muda (avisos-mural.tsx e a central chamam por ele).
-- 3. devolver_escolta: a auditoria pedida pela onda G ('devolveu_escolta_ao_mural', por
--    _auditar_mural) já está no corpo da 204 desta branch; nada a mudar aqui.
-- 4. Liga configuracao_avisos.checkin_telegram_pelo_cron (coluna da 212): a partir daqui,
--    com o envio pelo banco ativo, o Telegram do check-in vencido sai pelo cron. Antes
--    (bloco 1, master no ar), o navegador da master mandava, e o cron não podia mandar junto.
-- Reversão: 217_mural_central_reverter.sql recria os corpos da 204 e desliga a coluna.

CREATE OR REPLACE FUNCTION public._avisar_app(p_escolta_id uuid, p_tipo text, p_usuarios uuid[], p_titulo text, p_texto text, p_pedido_id uuid)
    RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF NOT coalesce((SELECT aviso_ligado FROM public.configuracoes_mural WHERE id = 1), true) THEN RETURN; END IF;
  PERFORM lote_interno.notificar(CASE WHEN p_pedido_id IS NOT NULL THEN p_tipo || ':' || p_pedido_id END,
                                 p_escolta_id, p_tipo, p_usuarios, p_titulo, p_texto,
                                 jsonb_build_object('pedido_id', p_pedido_id));
END;
$$;
REVOKE ALL ON FUNCTION public._avisar_app(uuid, text, uuid[], text, text, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.marcar_aviso_lido(p_notificacao_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  UPDATE public.notificacoes SET lida_em = coalesce(lida_em, now())
   WHERE id = p_notificacao_id AND usuario_dest_id = public.get_meu_usuario_id();
  RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.marcar_aviso_lido(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_aviso_lido(uuid) TO authenticated;

UPDATE public.configuracao_avisos SET checkin_telegram_pelo_cron = true WHERE id = 1;

-- Conferência:
-- SELECT prosrc LIKE '%lote_interno.notificar%' FROM pg_proc WHERE proname = '_avisar_app';     -- true
-- SELECT prosrc LIKE '%lida_em%' FROM pg_proc WHERE proname = 'marcar_aviso_lido';             -- true
-- SELECT checkin_telegram_pelo_cron FROM configuracao_avisos;                                -- true


-- ──────── 218_poder_total_rpcs.sql ────────
-- 218_poder_total_rpcs.sql
-- Lote 2026-10, onda I (adendo 01, item 4.3). Idempotente. BLOCO 2: aplicar logo depois do
-- deploy, depois da 204 e da 217 (recria funções delas) e da 213 e 214 (bloco 1).
--
-- Por quê (docs/14, seção 12.4; decisões S7, S8, S9 e S15; seção 17, ajustes em C, E e F):
-- as ações da gestão, cada uma numa transação, no servidor:
-- 1. editar_escolta: edição por diferença (viaturas e equipe pelo escolta_veiculo_id), sem
--    apagar e recriar; em rascunho e agendada com os poderes de hoje (campos para gestão,
--    supervisão e central; equipe e viaturas só até supervisor); nos demais status só
--    gestor e administrador, com motivo. Recusa remover viatura com registro de campo,
--    trocar a placa de viatura com registro (S9) e vigilante ou placa repetidos (G).
--    Troca de placa é UPDATE de veiculo_id na mesma linha (mantém id, confirmado, valor
--    pago, armamentos, ordem e combustível, E); duas viaturas trocam de placa entre si com a
--    restrição única da 210 adiada até o fim da RPC (SET CONSTRAINTS ... DEFERRED). Não muda
--    versao_gestao.
-- 2. pendencias_da_escolta: o que falta, por etapa e viatura (prévia da conclusão).
-- 3. concluir_escolta_antecipada: finaliza a qualquer momento; as pendências são calculadas
--    aqui (nunca vêm do cliente) e gravadas em escolta_conclusoes_antecipadas.
-- 4. voltar_etapa_escolta e zerar_escolta, com prévia (p_previa = true só devolve a lista
--    do que seria anulado). Destino da volta pela sequência do fluxo (S8), nunca pelo
--    histórico; da finalizada por conclusão antecipada, o status_no_momento gravado. Nada é
--    apagado: os registros ficam anulados (tabela da 12.4.4 em lote_interno.alvos_anulacao).
--    Toda volta que chega a agendada tem o tratamento do zerar (S8 e S15). A confirmação
--    manda o resumo que a prévia devolveu (versao_gestao, status, total e hash dos ids a
--    anular) e é recusada se a escolta mudou desde a prévia.
--    Concluir, voltar, zerar e arquivar são recusados com emergência aberta.
-- 5. arquivar_escolta (S7: só rascunho, agendada, finalizada ou cancelada) e
--    recuperar_escolta (só administrador). Não gravam linha de histórico (o status não muda):
--    ficam na auditoria (ARQUIVAR_ESCOLTA, RECUPERAR_ESCOLTA) e no aviso.
-- 6. Filtro de arquivada nas funções do mural (204, com o corpo da 217), no envio do
--    Telegram (202) e na registrar_etapa_escolta (214, que já filtra anulado e liga
--    escolta.historico_rpc); presença do mural anulada não vale (T2 depois do zerar) e não é
--    apagada ao devolver a escolta ao mural. Mensagens dos corpos recriados com acentuação.
-- Padrão das RPCs: SECURITY DEFINER, search_path fixo, guarda de perfil, motivo de pelo
-- menos 10 caracteres, SELECT ... FOR UPDATE na escolta, versao_gestao + 1 (menos na
-- edição), histórico com via_rpc, auditoria (lote_interno.auditar, a generalização de
-- _auditar_mural) e aviso (lote_interno.notificar à supervisão e à equipe; Telegram ao chat
-- central por _enfileirar_aviso) na mesma transação. As colunas travadas pela 213 só mudam
-- com a variável escolta.rpc_gestao ligada aqui E perfil de gestão.
-- Funções internas no schema lote_interno, com REVOKE explícito em cada uma (o default
-- privileges do schema não retira o EXECUTE de PUBLIC; ver docs/03, onda J).
-- Reversão: 218_poder_total_rpcs_reverter.sql (recria os corpos anteriores).

-- ── Presença do mural: a anulada (zerar) não impede confirmar de novo ─────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'mural_presencas_escolta_id_vigilante_id_key'
              AND conrelid = 'public.mural_presencas'::regclass) THEN
    ALTER TABLE public.mural_presencas DROP CONSTRAINT mural_presencas_escolta_id_vigilante_id_key;
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS mural_presencas_valida_uk
  ON public.mural_presencas (escolta_id, vigilante_id) WHERE anulado_em IS NULL;

-- ── Auxiliares internas ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lote_interno.rotulo_status(p text) RETURNS text
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT CASE p
    WHEN 'rascunho' THEN 'Rascunho' WHEN 'agendada' THEN 'Agendada' WHEN 'em_pre_inicio' THEN 'Pré-Início'
    WHEN 'em_andamento' THEN 'Em Andamento' WHEN 'na_origem' THEN 'Na Origem'
    WHEN 'em_transito_destino' THEN 'Trânsito p/ Destino' WHEN 'no_destino' THEN 'No Destino'
    WHEN 'em_transito_retorno' THEN 'Trânsito p/ Retorno' WHEN 'retornando' THEN 'Retornando'
    WHEN 'na_base' THEN 'Na Base' WHEN 'finalizada' THEN 'Finalizada' WHEN 'cancelada' THEN 'Cancelada'
    ELSE p END
$$;

-- Ordem linear das etapas (lib/fluxo-escolta.ts, SEQUENCIA_STATUS). Para o fluxo 1 vale a
-- mesma ordem: os saltos legados só servem para avançar (S8).
CREATE OR REPLACE FUNCTION lote_interno.sequencia_status() RETURNS text[]
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT ARRAY['rascunho', 'agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino',
               'no_destino', 'em_transito_retorno', 'retornando', 'na_base', 'finalizada']
$$;

-- Ponto que a entrada na etapa produz (TIPO_PONTO_POR_STATUS).
CREATE OR REPLACE FUNCTION lote_interno.tipo_ponto_da_etapa(p text) RETURNS text
    LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
  SELECT CASE p
    WHEN 'em_andamento' THEN 'base_saida' WHEN 'na_origem' THEN 'origem'
    WHEN 'em_transito_destino' THEN 'transito_destino' WHEN 'no_destino' THEN 'destino'
    WHEN 'em_transito_retorno' THEN 'transito_retorno' WHEN 'retornando' THEN 'retorno'
    WHEN 'na_base' THEN 'base_retorno' END
$$;

CREATE OR REPLACE FUNCTION lote_interno.auditar(p_acao text, p_escolta_id uuid, p_antes jsonb, p_depois jsonb) RETURNS void
    LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES (public.get_meu_usuario_id(), p_acao, 'escoltas', p_escolta_id, p_antes, p_depois, now())
$$;

-- Aviso de ação da gestão: central de avisos da supervisão e da equipe (menos quem fez) e
-- Telegram ao chat central (uma mensagem por chave).
CREATE OR REPLACE FUNCTION lote_interno.avisar_acao_gestao(p_escolta_id uuid, p_tipo text, p_chave text,
                                                          p_titulo text, p_linhas text[]) RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_eu uuid := public.get_meu_usuario_id(); v_dest uuid[]; v_ok boolean;
BEGIN
  v_dest := ARRAY(SELECT DISTINCT u FROM unnest(public._supervisao_ids()
                    || public._usuarios_dos_vigilantes(public._ids_da_equipe(public._equipe_atual(p_escolta_id)))) u
                  WHERE u IS DISTINCT FROM v_eu);
  PERFORM lote_interno.notificar(p_chave, p_escolta_id, p_tipo, v_dest, p_titulo, array_to_string(p_linhas, ' '));
  v_ok := public._enfileirar_aviso('gestao:' || p_chave, 'central', p_escolta_id,
            public._texto_aviso_mural(p_titulo, p_escolta_id, p_linhas));
END;
$$;

-- Registros de campo VÁLIDOS da escolta, numa forma só (para a anulação e a prévia).
CREATE OR REPLACE FUNCTION lote_interno.registros_validos(p_escolta_id uuid)
    RETURNS TABLE (tabela text, id uuid, quando timestamptz, carimbo text, sub text, via_rpc boolean, descricao text)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT 'pontos_controle', pc.id, pc.data_hora, pc.status_escolta_no_registro, tp.codigo, false,
         'Ponto ' || tp.nome_exibicao || ' (' || coalesce(ve.placa, 'sem placa') || ')'
    FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
    JOIN public.dom_tipos_ponto tp ON tp.id = pc.tipo_ponto_id LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
   WHERE ev.escolta_id = p_escolta_id AND pc.anulado_em IS NULL
  UNION ALL
  SELECT 'checklists', c.id, coalesce(c.data_inicio, c.criado_em), c.status_escolta_no_registro, c.tipo, false,
         'Checklist de ' || c.tipo || ' (' || coalesce(ve.placa, 'sem placa') || ')'
    FROM public.checklists c JOIN public.escolta_veiculos ev ON ev.id = c.escolta_veiculo_id
    LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
   WHERE ev.escolta_id = p_escolta_id AND c.anulado_em IS NULL
  UNION ALL
  SELECT 'ocorrencias', o.id, o.data_hora, o.status_escolta_no_registro, NULL, false, 'Ocorrência: ' || left(o.descricao, 80)
    FROM public.ocorrencias o WHERE o.escolta_id = p_escolta_id AND o.anulado_em IS NULL
  UNION ALL
  SELECT 'emergencias', em.id, em.data_hora, em.status_escolta_no_registro, em.status, false, 'Emergência (' || em.status || ')'
    FROM public.emergencias em WHERE em.escolta_id = p_escolta_id AND em.anulado_em IS NULL
  UNION ALL
  SELECT 'presencas', p.id, p.data_hora, p.status_escolta_no_registro, NULL, false, 'Presença de ' || coalesce(v.nome_completo, 'vigilante')
    FROM public.presencas p LEFT JOIN public.vigilantes v ON v.id = p.vigilante_id
   WHERE p.escolta_id = p_escolta_id AND p.anulado_em IS NULL
  UNION ALL
  SELECT 'mural_presencas', mp.id, mp.confirmado_em, mp.status_escolta_no_registro, NULL, false,
         'Presença na base (mural) de ' || coalesce(v.nome_completo, 'vigilante')
    FROM public.mural_presencas mp LEFT JOIN public.vigilantes v ON v.id = mp.vigilante_id
   WHERE mp.escolta_id = p_escolta_id AND mp.anulado_em IS NULL
  UNION ALL
  SELECT 'atualizacoes_status', a.id, a.data_hora, a.status_escolta_no_registro, NULL, false, 'Atualização: ' || left(a.descricao, 80)
    FROM public.atualizacoes_status a WHERE a.escolta_id = p_escolta_id AND a.anulado_em IS NULL
  UNION ALL
  SELECT 'rastreamento', r.id, r.data_hora, r.status_escolta_no_registro, NULL, false,
         'Posição de rastreamento (' || coalesce(ve.placa, 'sem placa') || ')'
    FROM public.rastreamento r JOIN public.escolta_veiculos ev ON ev.id = r.escolta_veiculo_id
    LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
   WHERE ev.escolta_id = p_escolta_id AND r.anulado_em IS NULL
  UNION ALL
  SELECT 'escolta_status_historico', h.id, h.data_hora, h.status_escolta_no_registro, h.status_novo, h.via_rpc,
         'Histórico: ' || lote_interno.rotulo_status(h.status_anterior) || ' para ' || lote_interno.rotulo_status(h.status_novo)
    FROM public.escolta_status_historico h WHERE h.escolta_id = p_escolta_id AND h.anulado_em IS NULL
$$;

-- Horário de referência da entrada na etapa, para os registros antigos sem carimbo: o
-- primeiro ponto válido que a produziu; sem ele, a última linha do histórico gravada por
-- RPC (via_rpc) que levou a ela. Nunca uma linha do histórico gravada pelo cliente.
CREATE OR REPLACE FUNCTION lote_interno.ancora_etapa(p_escolta_id uuid, p_etapa text) RETURNS timestamptz
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT coalesce(
    (SELECT min(r.quando) FROM lote_interno.registros_validos(p_escolta_id) r
      WHERE r.tabela = 'pontos_controle' AND r.sub = lote_interno.tipo_ponto_da_etapa(p_etapa)),
    (SELECT max(r.quando) FROM lote_interno.registros_validos(p_escolta_id) r
      WHERE r.tabela = 'escolta_status_historico' AND r.sub = p_etapa AND r.via_rpc))
$$;

-- O que é anulado ao desfazer a entrada na etapa p_etapa (docs/14, 12.4.4), ou tudo
-- (zerar). Critério: 'etapa' (o que a entrada produziu, pela tabela), 'historico' (linhas
-- que levaram à etapa), 'carimbo' (gravado enquanto a escolta estava na etapa), 'janela'
-- (registro antigo, sem carimbo, a partir do horário de referência), 'zerar'.
CREATE OR REPLACE FUNCTION lote_interno.alvos_anulacao(p_escolta_id uuid, p_etapa text, p_zerar boolean)
    RETURNS TABLE (tabela text, id uuid, quando timestamptz, descricao text, criterio text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_tipo text; v_ancora timestamptz; v_ancora_nb timestamptz;
BEGIN
  IF p_zerar THEN
    -- Tudo o que é de campo; do histórico, só o que passou de agendada (o planejamento fica).
    RETURN QUERY
      SELECT r.tabela, r.id, r.quando, r.descricao, 'zerar'::text
        FROM lote_interno.registros_validos(p_escolta_id) r
       WHERE NOT (r.tabela = 'escolta_status_historico' AND r.sub IN ('rascunho', 'agendada'));
    RETURN;
  END IF;
  v_tipo := lote_interno.tipo_ponto_da_etapa(p_etapa);
  v_ancora := lote_interno.ancora_etapa(p_escolta_id, p_etapa);
  IF p_etapa = 'finalizada' THEN
    v_ancora_nb := lote_interno.ancora_etapa(p_escolta_id, 'na_base');
  END IF;
  RETURN QUERY
    SELECT r.tabela, r.id, r.quando, r.descricao, x.criterio
      FROM lote_interno.registros_validos(p_escolta_id) r
      CROSS JOIN LATERAL (SELECT CASE
        WHEN r.tabela = 'pontos_controle' AND r.sub = v_tipo THEN 'etapa'
        -- Entrada em em_andamento: checklists do pré-início (a escolta ainda não tem o de entrega).
        WHEN p_etapa = 'em_andamento' AND r.tabela = 'checklists'
             AND (r.carimbo = 'em_pre_inicio' OR r.carimbo IS NULL) THEN 'etapa'
        -- Entrada em finalizada: o checklist de entrega (tipo viatura, gravado na base): pelo
        -- carimbo na_base ou, nos antigos, depois da entrada em na_base. Nunca pelo tipo só.
        WHEN p_etapa = 'finalizada' AND r.tabela = 'checklists' AND r.sub = 'viatura'
             AND (r.carimbo = 'na_base' OR (r.carimbo IS NULL AND v_ancora_nb IS NOT NULL AND r.quando >= v_ancora_nb)) THEN 'etapa'
        WHEN r.tabela = 'escolta_status_historico' AND r.sub = p_etapa THEN 'historico'
        WHEN r.carimbo = p_etapa THEN 'carimbo'
        WHEN r.carimbo IS NULL AND v_ancora IS NOT NULL AND r.quando >= v_ancora
             AND r.tabela <> 'checklists' THEN 'janela'
      END AS criterio) x
     WHERE x.criterio IS NOT NULL;
END;
$$;

-- Destino da volta (S8): o antecessor na sequência; da finalizada por conclusão antecipada,
-- o status em que ela estava. Nunca pelo histórico.
CREATE OR REPLACE FUNCTION lote_interno.destino_voltar(p_escolta_id uuid, p_status text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT CASE
    WHEN p_status = 'finalizada' AND EXISTS (SELECT 1 FROM public.escolta_conclusoes_antecipadas c
                                             WHERE c.escolta_id = p_escolta_id AND c.anulado_em IS NULL)
      THEN (SELECT c.status_no_momento FROM public.escolta_conclusoes_antecipadas c
             WHERE c.escolta_id = p_escolta_id AND c.anulado_em IS NULL)
    ELSE (lote_interno.sequencia_status())[array_position(lote_interno.sequencia_status(), p_status) - 1]
  END
$$;

-- Pendências, por etapa (pré-início até na base) e por viatura, só com registros válidos.
CREATE OR REPLACE FUNCTION lote_interno.pendencias(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_etapa text; v_tipo text; v_nome_tipo text; v_vts jsonb; v_saida jsonb := '[]'::jsonb;
BEGIN
  FOREACH v_etapa IN ARRAY ARRAY['em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino', 'no_destino',
                                 'em_transito_retorno', 'retornando', 'na_base'] LOOP
    v_tipo := lote_interno.tipo_ponto_da_etapa(v_etapa);
    SELECT nome_exibicao INTO v_nome_tipo FROM public.dom_tipos_ponto WHERE codigo = v_tipo;
    SELECT coalesce(jsonb_agg(jsonb_build_object('escolta_veiculo_id', x.id, 'placa', x.placa, 'faltando', to_jsonb(x.faltando))
                              ORDER BY x.criado_em), '[]'::jsonb)
      INTO v_vts
      FROM (
        SELECT ev.id, ev.criado_em, coalesce(ve.placa, 'sem placa') AS placa,
               array_remove(ARRAY[
                 CASE WHEN v_etapa = 'em_pre_inicio' AND NOT EXISTS (
                        SELECT 1 FROM public.checklists c WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'viatura'
                           AND c.concluido AND c.anulado_em IS NULL
                           AND coalesce(c.status_escolta_no_registro, 'em_pre_inicio') NOT IN ('na_base', 'finalizada'))
                      THEN 'Checklist da viatura' END,
                 CASE WHEN v_etapa = 'em_pre_inicio' AND NOT EXISTS (
                        SELECT 1 FROM public.checklists c WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'material'
                           AND c.concluido AND c.anulado_em IS NULL)
                      THEN 'Checklist de material' END,
                 CASE WHEN v_etapa = 'em_pre_inicio' AND ev.quilometragem_saida IS NULL THEN 'KM de saída' END,
                 CASE WHEN v_tipo IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM public.pontos_controle pc JOIN public.dom_tipos_ponto tp ON tp.id = pc.tipo_ponto_id
                         WHERE pc.escolta_veiculo_id = ev.id AND tp.codigo = v_tipo AND pc.anulado_em IS NULL)
                      THEN 'Ponto: ' || v_nome_tipo END,
                 CASE WHEN v_etapa = 'na_base' AND ev.quilometragem_retorno IS NULL THEN 'KM de retorno' END
               ], NULL) AS faltando
          FROM public.escolta_veiculos ev LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
         WHERE ev.escolta_id = p_escolta_id) x
     WHERE cardinality(x.faltando) > 0;
    IF jsonb_array_length(v_vts) > 0 THEN
      v_saida := v_saida || jsonb_build_array(jsonb_build_object('etapa', v_etapa, 'rotulo', lote_interno.rotulo_status(v_etapa),
                                                                 'viaturas', v_vts));
    END IF;
  END LOOP;
  RETURN v_saida;
END;
$$;

-- Guardas comuns.
CREATE OR REPLACE FUNCTION lote_interno.exigir_gestao(p_so_admin boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_perfil text := public.get_meu_perfil();
BEGIN
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.' USING ERRCODE = '42501'; END IF;
  IF p_so_admin AND v_perfil <> 'administrador' THEN
    RAISE EXCEPTION 'Só o administrador faz esta ação.' USING ERRCODE = '42501';
  END IF;
  IF v_perfil NOT IN ('administrador', 'gestor') THEN
    RAISE EXCEPTION 'Só o gestor ou o administrador faz esta ação.' USING ERRCODE = '42501';
  END IF;
  RETURN v_perfil;
END;
$$;

CREATE OR REPLACE FUNCTION lote_interno.exigir_motivo(p_motivo text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF p_motivo IS NULL OR length(trim(p_motivo)) < 10 THEN
    RAISE EXCEPTION 'Informe o motivo com pelo menos 10 caracteres.';
  END IF;
  IF length(trim(p_motivo)) > 1000 THEN RAISE EXCEPTION 'O motivo pode ter no máximo 1000 caracteres.'; END IF;
  RETURN trim(p_motivo);
END;
$$;

-- Liga e desliga as variáveis de transação das RPCs da gestão.
CREATE OR REPLACE FUNCTION lote_interno.modo_gestao(p_ligar boolean) RETURNS void
    LANGUAGE plpgsql VOLATILE SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  PERFORM set_config('escolta.rpc_gestao', CASE WHEN p_ligar THEN 'on' ELSE 'off' END, true);
  PERFORM set_config('escolta.historico_rpc', CASE WHEN p_ligar THEN 'on' ELSE 'off' END, true);
  IF NOT p_ligar THEN
    PERFORM set_config('escolta.transicao_especial', '', true);
    PERFORM set_config('escolta.transicao_destino', '', true);
  END IF;
END;
$$;

-- Volta de etapa e zerar (o núcleo das duas RPCs). Chamada só depois das guardas.
-- Assinatura antiga (sem o resumo da prévia), de quem aplicou a versão anterior desta migration.
DROP FUNCTION IF EXISTS lote_interno.executar_reset(uuid, text, text, boolean);
DROP FUNCTION IF EXISTS public.voltar_etapa_escolta(uuid, text, boolean);
DROP FUNCTION IF EXISTS public.zerar_escolta(uuid, text, boolean);
CREATE OR REPLACE FUNCTION lote_interno.executar_reset(p_escolta_id uuid, p_tipo text, p_motivo text, p_previa boolean,
                                                       p_resumo jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  e record; v_eu uuid := public.get_meu_usuario_id(); v_zerar boolean; v_destino text; v_itens jsonb; v_avisos jsonb := '[]'::jsonb;
  v_km jsonb; v_valores jsonb; v_anul uuid := gen_random_uuid(); v_contagem jsonb := '{}'::jsonb; v_n int; t text;
  v_conc uuid; v_reset uuid; v_ancora timestamptz; v_titulo text; v_total int; v_resumo jsonb;
BEGIN
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;
  IF e.status IN ('rascunho', 'agendada', 'cancelada') THEN
    RAISE EXCEPTION 'Escolta em %: não há etapa de campo para desfazer.', lote_interno.rotulo_status(e.status);
  END IF;
  IF EXISTS (SELECT 1 FROM public.emergencias em WHERE em.escolta_id = p_escolta_id AND em.status <> 'encerrada' AND em.anulado_em IS NULL) THEN
    RAISE EXCEPTION 'Há emergência aberta nesta escolta: encerre a emergência antes.';
  END IF;

  -- S8 e S15: toda volta que chega a agendada tem o tratamento do zerar (de em_pre_inicio, ou
  -- de uma finalizada que foi concluída antecipadamente ainda em agendada).
  v_destino := CASE WHEN p_tipo = 'zerar' THEN 'agendada' ELSE lote_interno.destino_voltar(p_escolta_id, e.status) END;
  v_zerar := p_tipo = 'zerar' OR v_destino = 'agendada';
  SELECT id INTO v_conc FROM public.escolta_conclusoes_antecipadas WHERE escolta_id = p_escolta_id AND anulado_em IS NULL;

  SELECT coalesce(jsonb_agg(jsonb_build_object('tabela', a.tabela, 'id', a.id, 'quando', a.quando,
                                               'quando_br', public._hora_br(a.quando), 'descricao', a.descricao,
                                               'criterio', a.criterio) ORDER BY a.quando, a.tabela), '[]'::jsonb)
    INTO v_itens
    FROM lote_interno.alvos_anulacao(p_escolta_id, e.status, v_zerar) a;

  -- Resumo da prévia: a confirmação só vale para a mesma escolta que a gestão viu.
  v_resumo := jsonb_build_object('versao_gestao', e.versao_gestao, 'status', e.status, 'total', jsonb_array_length(v_itens),
    'hash', md5(coalesce((SELECT string_agg((x ->> 'tabela') || ':' || (x ->> 'id'), ',' ORDER BY x ->> 'tabela', x ->> 'id')
                            FROM jsonb_array_elements(v_itens) x), '')));

  SELECT coalesce(jsonb_agg(jsonb_build_object('escolta_veiculo_id', ev.id, 'placa', coalesce(ve.placa, 'sem placa'),
                                               'quilometragem_saida', ev.quilometragem_saida,
                                               'quilometragem_retorno', ev.quilometragem_retorno) ORDER BY ev.criado_em), '[]'::jsonb)
    INTO v_km
    FROM public.escolta_veiculos ev LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id WHERE ev.escolta_id = p_escolta_id;
  v_valores := jsonb_build_object('km', v_km, 'checklist_pendente_no_inicio', e.checklist_pendente_no_inicio,
                                  'data_finalizacao', e.data_finalizacao, 'observacao_fechamento', e.observacao_fechamento,
                                  'conclusao_antecipada_id', v_conc);

  -- Avisos da prévia: registro antigo (sem carimbo) sem horário de referência não é anulado.
  IF NOT v_zerar THEN
    v_ancora := lote_interno.ancora_etapa(p_escolta_id, e.status);
    IF v_ancora IS NULL AND EXISTS (SELECT 1 FROM lote_interno.registros_validos(p_escolta_id) r
                                     WHERE r.carimbo IS NULL AND r.tabela NOT IN ('escolta_status_historico', 'checklists')) THEN
      v_avisos := v_avisos || to_jsonb('Há registros anteriores à atualização (sem carimbo de etapa) e não há horário de referência para a entrada em '
                                       || lote_interno.rotulo_status(e.status) || ': nenhum deles será anulado por horário.'::text);
    ELSIF v_ancora IS NOT NULL THEN
      v_avisos := v_avisos || to_jsonb('Registros antigos (sem carimbo de etapa) contam a partir de ' || public._hora_br(v_ancora) || ' (Brasília).'::text);
    END IF;
  END IF;
  IF (v_zerar OR e.status = 'finalizada') AND v_conc IS NOT NULL THEN
    v_avisos := v_avisos || to_jsonb('A lista de pendências da conclusão antecipada será anulada.'::text);
  END IF;

  IF p_previa THEN
    RETURN jsonb_build_object('previa', true, 'status_atual', e.status, 'rotulo_atual', lote_interno.rotulo_status(e.status),
                              'destino', v_destino, 'rotulo_destino', lote_interno.rotulo_status(v_destino),
                              'tipo', CASE WHEN v_zerar THEN 'zerar' ELSE 'voltar_etapa' END,
                              'itens', v_itens, 'total', jsonb_array_length(v_itens), 'valores', v_valores, 'avisos', v_avisos,
                              'resumo', v_resumo);
  END IF;
  IF p_resumo IS NULL OR jsonb_typeof(p_resumo) <> 'object' THEN
    RAISE EXCEPTION 'Confirme pela prévia: a confirmação precisa do resumo que a prévia devolve.';
  END IF;
  IF (p_resumo ->> 'versao_gestao') IS DISTINCT FROM (v_resumo ->> 'versao_gestao')
     OR (p_resumo ->> 'status') IS DISTINCT FROM (v_resumo ->> 'status')
     OR (p_resumo ->> 'total') IS DISTINCT FROM (v_resumo ->> 'total')
     OR (p_resumo ->> 'hash') IS DISTINCT FROM (v_resumo ->> 'hash') THEN
    RAISE EXCEPTION 'A escolta mudou desde a prévia: confira a lista de novo antes de confirmar.';
  END IF;

  PERFORM lote_interno.modo_gestao(true);

  -- Anula, tabela a tabela, com o mesmo anulacao_id.
  FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
                           'atualizacoes_status', 'rastreamento', 'escolta_status_historico'] LOOP
    EXECUTE format('UPDATE public.%I SET anulado_em = now(), anulado_por = $1, motivo_anulacao = $2, anulacao_id = $3
                     WHERE anulado_em IS NULL AND id IN (SELECT (x ->> ''id'')::uuid FROM jsonb_array_elements($4) x
                                                          WHERE x ->> ''tabela'' = $5)', t)
      USING v_eu, p_motivo, v_anul, v_itens, t;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_contagem := v_contagem || jsonb_build_object(t, v_n); END IF;
  END LOOP;
  SELECT coalesce(sum(value::int), 0) INTO v_total FROM jsonb_each_text(v_contagem);

  -- Valores que a entrada na etapa produziu (guardados em valores_anteriores).
  IF v_zerar OR e.status = 'em_andamento' THEN
    UPDATE public.escolta_veiculos SET quilometragem_saida = NULL WHERE escolta_id = p_escolta_id AND quilometragem_saida IS NOT NULL;
  END IF;
  IF v_zerar OR e.status = 'na_base' THEN
    UPDATE public.escolta_veiculos SET quilometragem_retorno = NULL WHERE escolta_id = p_escolta_id AND quilometragem_retorno IS NOT NULL;
  END IF;
  IF (v_zerar OR e.status = 'finalizada') AND v_conc IS NOT NULL THEN
    UPDATE public.escolta_conclusoes_antecipadas SET anulado_em = now(), anulado_por = v_eu, motivo_anulacao = p_motivo, anulacao_id = v_anul
     WHERE id = v_conc;
    v_contagem := v_contagem || jsonb_build_object('escolta_conclusoes_antecipadas', 1);
  END IF;

  -- Status (a trigger aceita só com a variável e o perfil) e versão.
  PERFORM set_config('escolta.transicao_especial', 'reset', true);
  PERFORM set_config('escolta.transicao_destino', v_destino, true);
  UPDATE public.escoltas SET
         status = v_destino,
         versao_gestao = versao_gestao + 1,
         -- A Nova cria com true: sem os checklists (anulados), o pré-início volta a estar pendente.
         checklist_pendente_no_inicio = CASE WHEN v_zerar OR e.status = 'em_andamento' THEN true ELSE checklist_pendente_no_inicio END,
         data_finalizacao = CASE WHEN v_zerar OR e.status = 'finalizada' THEN NULL ELSE data_finalizacao END,
         observacao_fechamento = CASE WHEN v_zerar OR e.status = 'finalizada' THEN NULL ELSE observacao_fechamento END,
         reiniciada_em = CASE WHEN v_zerar THEN now() ELSE reiniciada_em END
   WHERE id = p_escolta_id;

  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora, observacao)
  VALUES (p_escolta_id, e.status, v_destino, v_eu, now(),
          CASE WHEN v_zerar THEN 'Zerada pela gestão: ' ELSE 'Reset: ' END || p_motivo);

  INSERT INTO public.escolta_resets (escolta_id, status_de, status_para, tipo, motivo, feito_por, anulacao_id, valores_anteriores, contagem)
  VALUES (p_escolta_id, e.status, v_destino, CASE WHEN p_tipo = 'zerar' THEN 'zerar' ELSE 'voltar_etapa' END, p_motivo, v_eu, v_anul,
          v_valores, v_contagem)
  RETURNING id INTO v_reset;

  PERFORM lote_interno.auditar(CASE WHEN p_tipo = 'zerar' THEN 'ZERAR_ESCOLTA' ELSE 'VOLTAR_ETAPA' END, p_escolta_id,
    jsonb_build_object('status', e.status, 'valores', v_valores, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', v_destino, 'motivo', p_motivo, 'anulacao_id', v_anul, 'reset_id', v_reset,
                       'anulados', v_contagem, 'versao_gestao', e.versao_gestao + 1));

  v_titulo := CASE WHEN p_tipo = 'zerar' THEN 'Escolta zerada pela gestão: ' ELSE 'Etapa desfeita pela gestão: ' END || e.codigo_escolta;
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'reset_escolta', 'reset:' || v_reset, v_titulo, ARRAY[
    'Voltou de ' || lote_interno.rotulo_status(e.status) || ' para ' || lote_interno.rotulo_status(v_destino) || '.',
    v_total || ' registro(s) anulado(s), nada apagado.',
    'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
    'Motivo: ' || p_motivo]);

  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'de', e.status, 'para', v_destino, 'anulados', v_total, 'contagem', v_contagem,
                            'reset_id', v_reset, 'anulacao_id', v_anul);
END;
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['rotulo_status(text)', 'sequencia_status()', 'tipo_ponto_da_etapa(text)',
                           'auditar(text, uuid, jsonb, jsonb)', 'avisar_acao_gestao(uuid, text, text, text, text[])',
                           'registros_validos(uuid)', 'ancora_etapa(uuid, text)', 'alvos_anulacao(uuid, text, boolean)',
                           'destino_voltar(uuid, text)', 'pendencias(uuid)', 'exigir_gestao(boolean)', 'exigir_motivo(text)',
                           'modo_gestao(boolean)', 'executar_reset(uuid, text, text, boolean, jsonb)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION lote_interno.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- ── RPCs do cliente ──────────────────────────────────────────────────────────────────

-- 1. Edição.
CREATE OR REPLACE FUNCTION public.editar_escolta(p_escolta_id uuid, p_campos jsonb, p_viaturas jsonb DEFAULT NULL, p_motivo text DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  v_perfil text; v_eu uuid; e record; v_iniciada boolean; v_motivo text; v_campos jsonb := coalesce(p_campos, '{}'::jsonb);
  v_permitidos text[] := ARRAY['cliente_id', 'data_hora_prevista', 'origem_endereco', 'origem_lat', 'origem_lng',
                               'destino_endereco', 'destino_lat', 'destino_lng', 'metadados', 'periodicidade_checkin_min',
                               'valor_cobrado', 'outros_custos', 'observacao_financeira', 'escala_fixa',
                               'origem_uf', 'destino_uf', 'uf_estimada'];
  v_financeiro text[] := ARRAY['valor_cobrado', 'outros_custos', 'observacao_financeira'];
  v_sets text; v_k text; v_antes jsonb; v_depois jsonb; v_equipe_antes jsonb; v_equipe_depois jsonb;
  vt jsonb; m jsonb; v_ev uuid; v_ev_atual record; v_mudou_estrutura boolean := false; v_ids_mantidos uuid[] := '{}';
  v_vigs uuid[] := '{}'; v_veics uuid[] := '{}'; r record; v_n int; v_alterados text[] := '{}';
BEGIN
  v_perfil := public.get_meu_perfil();
  IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') THEN
    RAISE EXCEPTION 'Sem permissão para editar escolta.' USING ERRCODE = '42501';
  END IF;
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;
  v_iniciada := e.status NOT IN ('rascunho', 'agendada');
  IF v_iniciada AND v_perfil NOT IN ('administrador', 'gestor') THEN
    RAISE EXCEPTION 'Escolta já iniciada: só o gestor ou o administrador altera os dados dela.' USING ERRCODE = '42501';
  END IF;
  IF v_iniciada THEN v_motivo := lote_interno.exigir_motivo(p_motivo);
  ELSE v_motivo := nullif(trim(coalesce(p_motivo, '')), '');
  END IF;

  -- Só a lista fechada de campos; financeiro só para quem vê financeiro (a central não grava).
  FOR v_k IN SELECT jsonb_object_keys(v_campos) LOOP
    IF NOT v_k = ANY (v_permitidos) THEN RAISE EXCEPTION 'Campo não editável: %', v_k; END IF;
  END LOOP;
  IF v_perfil = 'central' THEN v_campos := v_campos - v_financeiro; END IF;
  -- Colunas que ainda não existem (UF da onda K) ficam de fora sem erro.
  SELECT string_agg(CASE WHEN a.attname = 'metadados'
                           THEN 'metadados = nullif(jsonb_strip_nulls(coalesce(e.metadados, ''{}''::jsonb) || coalesce(r.metadados, ''{}''::jsonb)), ''{}''::jsonb)'
                         ELSE format('%I = r.%I', a.attname, a.attname) END, ', ')
    INTO v_sets
    FROM pg_attribute a
   WHERE a.attrelid = 'public.escoltas'::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
     AND a.attname::text = ANY (v_permitidos) AND v_campos ? a.attname::text;

  v_antes := to_jsonb(e);
  v_equipe_antes := (SELECT coalesce(jsonb_agg(jsonb_build_object('escolta_veiculo_id', ev.id, 'veiculo_id', ev.veiculo_id,
                       'equipe', (SELECT coalesce(jsonb_agg(jsonb_build_object('vigilante_id', ef.vigilante_id, 'papel', ef.papel_na_escolta)
                                   ORDER BY ef.vigilante_id), '[]'::jsonb) FROM public.escolta_efetivo ef WHERE ef.escolta_veiculo_id = ev.id))
                       ORDER BY ev.criado_em), '[]'::jsonb)
                     FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_escolta_id);

  IF v_sets IS NOT NULL THEN
    EXECUTE format('UPDATE public.escoltas e SET %s FROM jsonb_populate_record(NULL::public.escoltas, $1) r WHERE e.id = $2', v_sets)
      USING v_campos, p_escolta_id;
  END IF;

  -- Viaturas e equipe por diferença (nunca apaga e recria).
  IF p_viaturas IS NOT NULL THEN
    IF jsonb_typeof(p_viaturas) <> 'array' OR jsonb_array_length(p_viaturas) = 0 THEN
      RAISE EXCEPTION 'A escolta precisa de ao menos uma viatura.';
    END IF;
    FOR vt IN SELECT * FROM jsonb_array_elements(p_viaturas) LOOP
      IF (vt ->> 'veiculo_id') IS NULL THEN RAISE EXCEPTION 'Viatura sem veículo selecionado.'; END IF;
      IF (vt ->> 'veiculo_id')::uuid = ANY (v_veics) THEN
        RAISE EXCEPTION 'O veículo % está em duas viaturas. Cada placa entra uma vez só na escolta.',
          coalesce((SELECT placa FROM public.veiculos WHERE id = (vt ->> 'veiculo_id')::uuid), 'selecionado');
      END IF;
      v_veics := v_veics || (vt ->> 'veiculo_id')::uuid;
      FOR m IN SELECT * FROM jsonb_array_elements(coalesce(vt -> 'membros', '[]'::jsonb)) LOOP
        IF (m ->> 'vigilante_id')::uuid = ANY (v_vigs) THEN
          RAISE EXCEPTION 'O vigilante % está escalado duas vezes. Cada vigilante entra uma vez só na escolta.',
            coalesce((SELECT nome_completo FROM public.vigilantes WHERE id = (m ->> 'vigilante_id')::uuid), 'selecionado');
        END IF;
        v_vigs := v_vigs || (m ->> 'vigilante_id')::uuid;
      END LOOP;
      IF (vt ->> 'escolta_veiculo_id') IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.escolta_veiculos WHERE id = (vt ->> 'escolta_veiculo_id')::uuid AND escolta_id = p_escolta_id) THEN
          RAISE EXCEPTION 'Viatura que não pertence a esta escolta.';
        END IF;
        v_ids_mantidos := v_ids_mantidos || (vt ->> 'escolta_veiculo_id')::uuid;
      END IF;
    END LOOP;

    -- Viaturas removidas: só sem registro de campo (S9).
    FOR r IN SELECT ev.id, coalesce(ve.placa, 'sem placa') AS placa FROM public.escolta_veiculos ev
               LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
              WHERE ev.escolta_id = p_escolta_id AND NOT ev.id = ANY (v_ids_mantidos) LOOP
      IF lote_interno.viatura_tem_registro(r.id) THEN
        RAISE EXCEPTION 'A viatura % já tem registro de campo e não pode sair da escolta.', r.placa;
      END IF;
    END LOOP;

    -- Equipe: quem saiu.
    FOR r IN SELECT ef.id FROM public.escolta_efetivo ef WHERE ef.escolta_id = p_escolta_id AND NOT ef.vigilante_id = ANY (v_vigs) LOOP
      DELETE FROM public.escolta_efetivo WHERE id = r.id;
      v_mudou_estrutura := true;
    END LOOP;
    DELETE FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id AND NOT id = ANY (v_ids_mantidos);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_mudou_estrutura := true; END IF;

    -- Troca de placa (só em viatura sem registro, S9): UPDATE de veiculo_id na mesma linha,
    -- que mantém id, equipe (confirmado, valor pago), armamentos, observações, ordem
    -- (criado_em) e combustível. Duas viaturas desta escolta podem trocar de placa entre si:
    -- a restrição única (escolta, veículo) da 210 fica adiada até o fim do laço abaixo.
    SET CONSTRAINTS public.escolta_veiculos_escolta_veiculo_uk DEFERRED;

    BEGIN
      FOR vt IN SELECT * FROM jsonb_array_elements(p_viaturas) LOOP
        IF (vt ->> 'escolta_veiculo_id') IS NOT NULL THEN
          v_ev := (vt ->> 'escolta_veiculo_id')::uuid;
          SELECT ev.veiculo_id, coalesce(ve.placa, 'sem placa') AS placa INTO v_ev_atual
            FROM public.escolta_veiculos ev LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id WHERE ev.id = v_ev;
          IF v_ev_atual.veiculo_id IS DISTINCT FROM (vt ->> 'veiculo_id')::uuid THEN
            IF lote_interno.viatura_tem_registro(v_ev) THEN
              RAISE EXCEPTION 'A viatura % já tem registro de campo: a placa não pode ser trocada (a foto mostra a placa original).', v_ev_atual.placa;
            END IF;
            UPDATE public.escolta_veiculos SET veiculo_id = (vt ->> 'veiculo_id')::uuid, atualizado_por = v_eu WHERE id = v_ev;
            v_mudou_estrutura := true;
          END IF;
        ELSE
          INSERT INTO public.escolta_veiculos (escolta_id, veiculo_id, criado_por)
          VALUES (p_escolta_id, (vt ->> 'veiculo_id')::uuid, v_eu) RETURNING id INTO v_ev;
          v_mudou_estrutura := true;
        END IF;
        FOR m IN SELECT * FROM jsonb_array_elements(coalesce(vt -> 'membros', '[]'::jsonb)) LOOP
          SELECT ef.id, ef.escolta_veiculo_id, ef.papel_na_escolta, ef.valor_pago_vigilante INTO r
            FROM public.escolta_efetivo ef WHERE ef.escolta_id = p_escolta_id AND ef.vigilante_id = (m ->> 'vigilante_id')::uuid;
          IF r.id IS NULL THEN
            INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado,
                                                valor_pago_vigilante, criado_por)
            VALUES (p_escolta_id, v_ev, (m ->> 'vigilante_id')::uuid, coalesce(m ->> 'papel_na_escolta', 'operador'), false,
                    CASE WHEN v_perfil <> 'central' THEN (m ->> 'valor_pago_vigilante')::numeric END, v_eu);
            v_mudou_estrutura := true;
          ELSIF r.escolta_veiculo_id IS DISTINCT FROM v_ev OR r.papel_na_escolta IS DISTINCT FROM coalesce(m ->> 'papel_na_escolta', 'operador') THEN
            UPDATE public.escolta_efetivo SET escolta_veiculo_id = v_ev, papel_na_escolta = coalesce(m ->> 'papel_na_escolta', 'operador'),
                   atualizado_por = v_eu,
                   valor_pago_vigilante = CASE WHEN v_perfil <> 'central' AND m ? 'valor_pago_vigilante'
                                               THEN (m ->> 'valor_pago_vigilante')::numeric ELSE valor_pago_vigilante END
             WHERE id = r.id;
            v_mudou_estrutura := true;
          ELSIF v_perfil <> 'central' AND m ? 'valor_pago_vigilante'
                AND r.valor_pago_vigilante IS DISTINCT FROM (m ->> 'valor_pago_vigilante')::numeric THEN
            UPDATE public.escolta_efetivo SET valor_pago_vigilante = (m ->> 'valor_pago_vigilante')::numeric, atualizado_por = v_eu WHERE id = r.id;
          END IF;
        END LOOP;
      END LOOP;
      -- Fim das trocas: a restrição volta a valer na hora e confere o resultado aqui dentro.
      SET CONSTRAINTS public.escolta_veiculos_escolta_veiculo_uk IMMEDIATE;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'A viatura ou um vigilante já está nesta escolta. Revise a equipe e as viaturas.';
    END;
    -- A central edita os dados, mas não a equipe nem as viaturas (como hoje, escolta_efetivo_escrita).
    IF v_mudou_estrutura AND v_perfil = 'central' THEN
      RAISE EXCEPTION 'A central edita os dados da escolta, mas não a equipe nem as viaturas. Fale com o supervisor.' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT to_jsonb(x) INTO v_depois FROM public.escoltas x WHERE x.id = p_escolta_id;
  v_equipe_depois := (SELECT coalesce(jsonb_agg(jsonb_build_object('escolta_veiculo_id', ev.id, 'veiculo_id', ev.veiculo_id,
                       'equipe', (SELECT coalesce(jsonb_agg(jsonb_build_object('vigilante_id', ef.vigilante_id, 'papel', ef.papel_na_escolta)
                                   ORDER BY ef.vigilante_id), '[]'::jsonb) FROM public.escolta_efetivo ef WHERE ef.escolta_veiculo_id = ev.id))
                       ORDER BY ev.criado_em), '[]'::jsonb)
                     FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_escolta_id);
  SELECT coalesce(array_agg(k ORDER BY k), '{}') INTO v_alterados
    FROM jsonb_object_keys(v_depois) k
   WHERE k NOT IN ('atualizado_em', 'atualizado_por') AND (v_depois -> k) IS DISTINCT FROM (v_antes -> k);
  IF v_equipe_antes IS DISTINCT FROM v_equipe_depois THEN v_alterados := v_alterados || 'viaturas_e_equipe'::text; END IF;

  PERFORM lote_interno.auditar('EDITAR_ESCOLTA', p_escolta_id,
    coalesce((SELECT jsonb_object_agg(k, v_antes -> k) FROM unnest(v_alterados) k WHERE v_antes ? k), '{}'::jsonb)
      || jsonb_build_object('status', e.status, 'viaturas', v_equipe_antes),
    coalesce((SELECT jsonb_object_agg(k, v_depois -> k) FROM unnest(v_alterados) k WHERE v_depois ? k), '{}'::jsonb)
      || jsonb_build_object('viaturas', v_equipe_depois, 'motivo', v_motivo, 'campos_alterados', to_jsonb(v_alterados)));

  -- Fora do fluxo normal (escolta iniciada): aviso à supervisão e à equipe.
  IF v_iniciada AND cardinality(v_alterados) > 0 THEN
    PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'edicao_escolta',
      'edicao:' || p_escolta_id || ':' || extract(epoch FROM clock_timestamp())::bigint,
      'Escolta editada pela gestão: ' || e.codigo_escolta, ARRAY[
        'Alterado em ' || lote_interno.rotulo_status(e.status) || ': ' || array_to_string(v_alterados, ', ') || '.',
        'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
        'Motivo: ' || v_motivo]);
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_escolta_id, 'alterados', to_jsonb(v_alterados));
END;
$$;

-- Viatura com registro de campo (S9): ponto, checklist, rastreamento, emergência ou ocorrência.
CREATE OR REPLACE FUNCTION lote_interno.viatura_tem_registro(p_escolta_veiculo_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT EXISTS (SELECT 1 FROM public.pontos_controle WHERE escolta_veiculo_id = p_escolta_veiculo_id)
      OR EXISTS (SELECT 1 FROM public.checklists WHERE escolta_veiculo_id = p_escolta_veiculo_id)
      OR EXISTS (SELECT 1 FROM public.rastreamento WHERE escolta_veiculo_id = p_escolta_veiculo_id)
      OR EXISTS (SELECT 1 FROM public.emergencias WHERE escolta_veiculo_id = p_escolta_veiculo_id)
      OR EXISTS (SELECT 1 FROM public.ocorrencias WHERE escolta_veiculo_id = p_escolta_veiculo_id)
$$;
REVOKE ALL ON FUNCTION lote_interno.viatura_tem_registro(uuid) FROM PUBLIC, anon, authenticated;

-- 2. Pendências (prévia da conclusão).
CREATE OR REPLACE FUNCTION public.pendencias_da_escolta(p_escolta_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  IF NOT EXISTS (SELECT 1 FROM public.escoltas WHERE id = p_escolta_id) THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  RETURN lote_interno.pendencias(p_escolta_id);
END;
$$;

-- 3. Conclusão antecipada.
CREATE OR REPLACE FUNCTION public.concluir_escolta_antecipada(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text; v_pend jsonb; v_conc uuid; v_itens int;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;
  IF e.status IN ('rascunho', 'finalizada', 'cancelada') THEN
    RAISE EXCEPTION 'Escolta em %: não pode ser concluída.', lote_interno.rotulo_status(e.status);
  END IF;
  -- Concluída, a emergência aberta sairia do Painel junto com a escolta: encerrar antes.
  IF EXISTS (SELECT 1 FROM public.emergencias em WHERE em.escolta_id = p_escolta_id AND em.status <> 'encerrada' AND em.anulado_em IS NULL) THEN
    RAISE EXCEPTION 'Há emergência aberta nesta escolta: encerre a emergência antes.';
  END IF;
  v_pend := lote_interno.pendencias(p_escolta_id);      -- calculada aqui, nunca do cliente
  SELECT count(*) INTO v_itens FROM jsonb_array_elements(v_pend) et, jsonb_array_elements(et -> 'viaturas') vt,
                                    jsonb_array_elements(vt -> 'faltando') it;

  PERFORM lote_interno.modo_gestao(true);
  PERFORM set_config('escolta.transicao_especial', 'conclusao_antecipada', true);
  UPDATE public.escoltas SET status = 'finalizada', data_finalizacao = now(), observacao_fechamento = v_motivo,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora, observacao)
  VALUES (p_escolta_id, e.status, 'finalizada', v_eu, now(),
          CASE WHEN v_itens > 0 THEN 'Conclusão antecipada pela gestão: ' ELSE 'Concluída pela gestão: ' END || v_motivo);
  -- Sem pendência, conclui normalmente, sem a linha.
  IF v_itens > 0 THEN
    INSERT INTO public.escolta_conclusoes_antecipadas (escolta_id, status_no_momento, motivo, concluida_por, pendencias)
    VALUES (p_escolta_id, e.status, v_motivo, v_eu, v_pend) RETURNING id INTO v_conc;
  END IF;
  PERFORM lote_interno.auditar('CONCLUSAO_ANTECIPADA', p_escolta_id,
    jsonb_build_object('status', e.status, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', 'finalizada', 'motivo', v_motivo, 'pendencias', v_pend, 'itens_pendentes', v_itens,
                       'conclusao_id', v_conc, 'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'conclusao_antecipada', 'conclusao:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    CASE WHEN v_itens > 0 THEN 'Concluída com pendências: ' ELSE 'Concluída pela gestão: ' END || e.codigo_escolta, ARRAY[
      'Concluída em ' || lote_interno.rotulo_status(e.status) || CASE WHEN v_itens > 0 THEN ', com ' || v_itens || ' item(ns) pendente(s).' ELSE ', sem pendências.' END,
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Observação: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'pendencias', v_pend, 'itens', v_itens, 'conclusao_id', v_conc);
END;
$$;

-- 4. Voltar uma etapa e zerar.
-- p_previa = true devolve a lista e o resumo; a confirmação (p_previa = false) manda o
-- resumo de volta em p_resumo e é recusada se a escolta mudou desde a prévia.
CREATE OR REPLACE FUNCTION public.voltar_etapa_escolta(p_escolta_id uuid, p_motivo text DEFAULT NULL, p_previa boolean DEFAULT false,
                                                       p_resumo jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_motivo text;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  IF NOT coalesce(p_previa, false) THEN v_motivo := lote_interno.exigir_motivo(p_motivo); END IF;
  RETURN lote_interno.executar_reset(p_escolta_id, 'voltar_etapa', v_motivo, coalesce(p_previa, false), p_resumo);
END;
$$;

CREATE OR REPLACE FUNCTION public.zerar_escolta(p_escolta_id uuid, p_motivo text DEFAULT NULL, p_previa boolean DEFAULT false,
                                                p_resumo jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_motivo text;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  IF NOT coalesce(p_previa, false) THEN v_motivo := lote_interno.exigir_motivo(p_motivo); END IF;
  RETURN lote_interno.executar_reset(p_escolta_id, 'zerar', v_motivo, coalesce(p_previa, false), p_resumo);
END;
$$;

-- 5. Arquivar (S7) e recuperar.
CREATE OR REPLACE FUNCTION public.arquivar_escolta(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text; v_ped int;
BEGIN
  PERFORM lote_interno.exigir_gestao(false);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Esta escolta já está arquivada.'; END IF;
  IF e.status NOT IN ('rascunho', 'agendada', 'finalizada', 'cancelada') THEN
    RAISE EXCEPTION 'Escolta em andamento não pode ser arquivada: conclua (inclusive com pendências) ou cancele antes.';
  END IF;
  -- Arquivada some de todos, menos do administrador: a emergência aberta sumiria da central.
  IF EXISTS (SELECT 1 FROM public.emergencias em WHERE em.escolta_id = p_escolta_id AND em.status <> 'encerrada' AND em.anulado_em IS NULL) THEN
    RAISE EXCEPTION 'Há emergência aberta nesta escolta: encerre a emergência antes.';
  END IF;
  PERFORM lote_interno.modo_gestao(true);
  UPDATE public.escoltas SET arquivada_em = now(), arquivada_por = v_eu, motivo_arquivamento = v_motivo,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  -- Pedido de substituição em análise perde o objeto.
  UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
         observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: a escolta foi arquivada.')
   WHERE escolta_id = p_escolta_id AND status = 'pendente';
  GET DIAGNOSTICS v_ped = ROW_COUNT;
  -- Sem linha de histórico (o status não muda): o arquivamento fica na auditoria.
  PERFORM lote_interno.auditar('ARQUIVAR_ESCOLTA', p_escolta_id,
    jsonb_build_object('status', e.status, 'arquivada_em', NULL, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', e.status, 'arquivada_em', now(), 'motivo', v_motivo, 'pedidos_invalidados', v_ped,
                       'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'arquivamento_escolta', 'arquivamento:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    'Escolta arquivada: ' || e.codigo_escolta, ARRAY[
      'Arquivada em ' || lote_interno.rotulo_status(e.status) || '; some das listas, do mural e dos indicadores.',
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'gestão') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Motivo: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'status', e.status, 'pedidos_invalidados', v_ped);
END;
$$;

CREATE OR REPLACE FUNCTION public.recuperar_escolta(p_escolta_id uuid, p_motivo text) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE e record; v_eu uuid; v_motivo text;
BEGIN
  PERFORM lote_interno.exigir_gestao(true);
  v_motivo := lote_interno.exigir_motivo(p_motivo);
  v_eu := public.get_meu_usuario_id();
  SELECT * INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NULL THEN RAISE EXCEPTION 'Esta escolta não está arquivada.'; END IF;
  PERFORM lote_interno.modo_gestao(true);
  UPDATE public.escoltas SET arquivada_em = NULL, arquivada_por = NULL, motivo_arquivamento = NULL,
         versao_gestao = versao_gestao + 1
   WHERE id = p_escolta_id;
  -- Sem linha de histórico (o status não muda): a recuperação fica na auditoria.
  PERFORM lote_interno.auditar('RECUPERAR_ESCOLTA', p_escolta_id,
    jsonb_build_object('status', e.status, 'arquivada_em', e.arquivada_em, 'arquivada_por', e.arquivada_por,
                       'motivo_arquivamento', e.motivo_arquivamento, 'versao_gestao', e.versao_gestao),
    jsonb_build_object('status', e.status, 'arquivada_em', NULL, 'motivo', v_motivo, 'versao_gestao', e.versao_gestao + 1));
  PERFORM lote_interno.avisar_acao_gestao(p_escolta_id, 'recuperacao_escolta', 'recuperacao:' || p_escolta_id || ':' || (e.versao_gestao + 1),
    'Escolta recuperada do arquivo: ' || e.codigo_escolta, ARRAY[
      'Volta em ' || lote_interno.rotulo_status(e.status) || ', no status em que estava.',
      'Por: ' || coalesce((SELECT nome_completo FROM public.usuarios WHERE id = v_eu), 'administrador') || ' em ' || public._hora_br(now()) || ' (Brasília).',
      'Motivo: ' || v_motivo]);
  PERFORM lote_interno.modo_gestao(false);
  RETURN jsonb_build_object('ok', true, 'status', e.status);
END;
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['editar_escolta(uuid, jsonb, jsonb, text)', 'pendencias_da_escolta(uuid)',
                           'concluir_escolta_antecipada(uuid, text)', 'voltar_etapa_escolta(uuid, text, boolean, jsonb)',
                           'zerar_escolta(uuid, text, boolean, jsonb)', 'arquivar_escolta(uuid, text)', 'recuperar_escolta(uuid, text)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- ── Funções da 204 (corpo da 217), da 202 e da 214, recriadas com os filtros ───────────
CREATE OR REPLACE FUNCTION public._conflito_comandante(p_vigilante_id uuid, p_escolta_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT o.codigo_escolta
  FROM public.escoltas alvo
  CROSS JOIN public.configuracoes_mural cfg
  JOIN public.escolta_efetivo ee ON ee.vigilante_id = p_vigilante_id AND ee.papel_na_escolta = 'comandante'
  JOIN public.escoltas o ON o.id = ee.escolta_id
  WHERE alvo.id = p_escolta_id AND cfg.id = 1
    AND o.id <> p_escolta_id AND o.status = 'agendada'
    AND o.arquivada_em IS NULL   -- onda I: escolta arquivada não conta
    AND abs(extract(epoch FROM (o.data_hora_prevista - alvo.data_hora_prevista))) < cfg.intervalo_comandante_h * 3600
  LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public._presenca_da_equipe(p_escolta_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT string_agg(v.nome_completo, ', ')
  FROM public.mural_presencas mp
  JOIN public.escolta_efetivo ee ON ee.escolta_id = mp.escolta_id AND ee.vigilante_id = mp.vigilante_id
  JOIN public.vigilantes v ON v.id = mp.vigilante_id
  WHERE mp.escolta_id = p_escolta_id
    AND mp.anulado_em IS NULL   -- onda I: presença anulada (zerar) não vale
$function$;

CREATE OR REPLACE FUNCTION public._executar_substituicao(p_pedido_id uuid, p_via text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  p public.mural_pedidos%ROWTYPE;
  e record; v_motivo text; v_ev uuid; v_acomp uuid; v_equipe_agora jsonb; v_presenca text; v_conflito text;
  v_nome text; v_aviso boolean;
BEGIN
  SELECT * INTO p FROM public.mural_pedidos WHERE id = p_pedido_id;
  IF p.id IS NULL OR p.status NOT IN ('aprovado', 'liberado_por_tempo') THEN
    RAISE EXCEPTION 'Pedido não está liberado para execução.';
  END IF;
  SELECT id, status, escala_fixa, codigo_escolta, data_hora_prevista, arquivada_em INTO e FROM public.escoltas WHERE id = p.escolta_id;
  PERFORM public._travar_vigilante(p.solicitante_vigilante_id);
  v_equipe_agora := public._equipe_atual(p.escolta_id);
  v_presenca := CASE WHEN (SELECT presenca_ligada FROM public.configuracoes_mural WHERE id = 1)
                     THEN public._presenca_da_equipe(p.escolta_id) END;
  v_conflito := public._conflito_comandante(p.solicitante_vigilante_id, p.escolta_id);

  v_motivo := CASE
    WHEN e.arquivada_em IS NOT NULL THEN 'a escolta foi arquivada'   -- onda I
    WHEN e.status IS DISTINCT FROM 'agendada' THEN 'a escolta já começou ou foi encerrada'
    WHEN e.escala_fixa THEN 'a escolta passou a ser de escala fixa'
    WHEN now() < e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1))
      THEN 'a escolta foi remarcada e saiu da janela de substituição'
    WHEN v_presenca IS NOT NULL THEN 'a equipe confirmou presença na base (' || v_presenca || ')'
    WHEN public._ids_da_equipe(v_equipe_agora) IS DISTINCT FROM public._ids_da_equipe(p.equipe_antes) THEN 'a equipe da escolta mudou depois do pedido'
    WHEN v_conflito IS NOT NULL THEN 'o solicitante passou a comandar a escolta ' || v_conflito || ' a menos do intervalo mínimo'
    WHEN NOT EXISTS (SELECT 1 FROM public.vigilantes v JOIN public.usuarios u ON u.id = v.usuario_id
                     WHERE v.id = p.solicitante_vigilante_id AND v.status = 'ativo' AND u.status = 'ativo') THEN 'o solicitante não está mais ativo'
    WHEN EXISTS (SELECT 1 FROM unnest(p.acompanhantes) a WHERE NOT EXISTS
                 (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN 'um acompanhante não está mais ativo'
    WHEN p.veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p.veiculo_id AND status = 'ativo') THEN 'a viatura indicada não está mais ativa'
    -- Onda G (210): a placa escolhida não pode estar em outra viatura da mesma escolta.
    WHEN p.veiculo_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p.escolta_id AND ev.veiculo_id = p.veiculo_id
              AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1))
      THEN 'a viatura indicada já está em outra viatura da escolta'
  END;

  -- Onda G (210): os índices únicos do efetivo e das viaturas recusam repetição. Se uma
  -- gravação esbarrar neles, a troca inteira é desfeita e o pedido é invalidado com o
  -- motivo, em vez de o erro técnico subir para quem aprovou ou para o cron.
  IF v_motivo IS NULL THEN
    BEGIN
      SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1;
      IF p.veiculo_id IS NOT NULL THEN
        UPDATE public.escolta_veiculos SET veiculo_id = p.veiculo_id, atualizado_em = now(), atualizado_por = p.solicitante_usuario_id
         WHERE id = v_ev;
      END IF;
      DELETE FROM public.escolta_efetivo WHERE escolta_id = p.escolta_id;
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p.escolta_id, v_ev, p.solicitante_vigilante_id, 'comandante', true, p.solicitante_usuario_id);
      FOREACH v_acomp IN ARRAY p.acompanhantes LOOP
        IF v_acomp IS DISTINCT FROM p.solicitante_vigilante_id THEN
          INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
          VALUES (p.escolta_id, v_ev, v_acomp, 'operador', false, p.solicitante_usuario_id) ON CONFLICT DO NOTHING;
        END IF;
      END LOOP;
    EXCEPTION WHEN unique_violation THEN
      v_motivo := 'a viatura ou um vigilante indicado já está na escolta';
    END;
  END IF;

  IF v_motivo IS NOT NULL THEN
    UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = coalesce(decidido_em, now()),
           observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: ' || v_motivo || '.')
     WHERE id = p.id;
    INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
    VALUES (p.decidido_por, 'pedido_substituicao_invalidado', 'escoltas', p.escolta_id, jsonb_build_object('pedido_id', p.id),
            jsonb_build_object('pedido_id', p.id, 'via', p_via, 'motivo', v_motivo), now());
    PERFORM public._avisar_app(p.escolta_id, 'decisao_substituicao', ARRAY[p.solicitante_usuario_id],
      'Pedido de substituição invalidado', 'O pedido para a escolta ' || e.codigo_escolta || ' não foi executado: ' || v_motivo || '.', p.id);
    RETURN false;
  END IF;

  SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = p.solicitante_vigilante_id;
  INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
  VALUES (p.solicitante_usuario_id, 'substituicao_de_equipe', 'escoltas', p.escolta_id,
          jsonb_build_object('equipe', p.equipe_antes),
          jsonb_build_object('pedido_id', p.id, 'via', p_via, 'assumida_por', v_nome, 'motivo', p.motivo,
                             'acompanhantes', (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (p.acompanhantes)),
                             'trocou_viatura', p.veiculo_id IS NOT NULL,
                             'decidido_por', (SELECT nome_completo FROM public.usuarios WHERE id = p.decidido_por)),
          now());

  PERFORM public._avisar_app(p.escolta_id, 'substituicao_equipe',
    public._usuarios_dos_vigilantes(public._ids_da_equipe(p.equipe_antes)) || public._supervisao_ids() || ARRAY[p.solicitante_usuario_id],
    'Equipe substituída na escolta ' || e.codigo_escolta,
    v_nome || ' assumiu a escolta em ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo, sem resposta da supervisão)' ELSE ' (aprovado pela supervisão)' END
      || '. Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes) || '. Motivo: ' || p.motivo,
    p.id);
  v_aviso := public._enfileirar_aviso('substituicao:' || p.id, 'central', p.escolta_id,
    public._texto_aviso_mural('Equipe substituída', p.escolta_id, ARRAY[
      'Assumiu: ' || v_nome,
      'Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes),
      'Quando: ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo)' ELSE ' (aprovado)' END,
      'Motivo: ' || p.motivo]));
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[] DEFAULT '{}'::uuid[], p_veiculo_id uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_perfil text; v_usuario uuid; v_vigilante uuid; e record; cfg record; v_qtd int; v_ev uuid; v_acomp uuid;
  v_conflito text; v_presenca text; v_ped record; v_equipe jsonb; v_nome text; v_aviso boolean; v_inicio timestamptz;
  v_acomp_limpo uuid[];
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta não está vinculada a um vigilante ativo. Fale com o administrador.';
  END IF;

  -- Trava a linha: duas pessoas assumindo ao mesmo tempo produziriam duas equipes.
  SELECT id, status, escala_fixa, data_hora_prevista, codigo_escolta, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  IF e.status <> 'agendada' THEN
    RAISE EXCEPTION 'Esta escolta já começou e não pode ter a equipe trocada. Fale com o supervisor.';
  END IF;
  IF e.escala_fixa THEN
    RAISE EXCEPTION 'Escolta de escala fixa: a equipe é definida pela supervisão.';
  END IF;
  PERFORM public._travar_vigilante(v_vigilante);

  v_acomp_limpo := ARRAY(SELECT DISTINCT a FROM unnest(coalesce(p_acompanhantes, '{}')) a WHERE a IS DISTINCT FROM v_vigilante);
  IF EXISTS (SELECT 1 FROM unnest(v_acomp_limpo) a WHERE NOT EXISTS
             (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN
    RAISE EXCEPTION 'Acompanhante inválido ou inativo.';
  END IF;
  IF p_veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p_veiculo_id AND status = 'ativo') THEN
    RAISE EXCEPTION 'Viatura inválida ou fora de operação.';
  END IF;
  -- Onda G (210): a placa escolhida troca a primeira viatura; não pode ser a de outra
  -- viatura da mesma escolta.
  IF p_veiculo_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_escolta_id AND ev.veiculo_id = p_veiculo_id
          AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1)) THEN
    RAISE EXCEPTION 'Esta viatura já está em outra viatura desta escolta. Escolha outra placa ou mantenha a atual.';
  END IF;

  SELECT * INTO cfg FROM public.configuracoes_mural WHERE id = 1;
  SELECT count(*) INTO v_qtd FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = v_vigilante;

  -- Escolta sem equipe: assume na hora, como antes, com T5.
  IF v_qtd = 0 THEN
    v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
    IF v_conflito IS NOT NULL THEN
      RAISE EXCEPTION 'Você já é comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
    END IF;
    SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
    IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
    BEGIN
      IF p_veiculo_id IS NOT NULL THEN
        UPDATE public.escolta_veiculos SET veiculo_id = p_veiculo_id, atualizado_em = now(), atualizado_por = v_usuario WHERE id = v_ev;
      END IF;
      INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
      VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
      FOREACH v_acomp IN ARRAY v_acomp_limpo LOOP
        INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
        VALUES (p_escolta_id, v_ev, v_acomp, 'operador', false, v_usuario) ON CONFLICT DO NOTHING;
      END LOOP;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'A viatura ou um vigilante escolhido já está nesta escolta. Revise a equipe e a viatura e tente de novo.';
    END;
    PERFORM public._auditar_mural('assumiu_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
      jsonb_build_object('assumida_por', v_nome, 'acompanhantes',
        (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (v_acomp_limpo)),
        'trocou_viatura', p_veiculo_id IS NOT NULL));
    RETURN jsonb_build_object('ok', true, 'status', 'assumida', 'substituiu_equipe', false);
  END IF;

  -- Escolta com equipe: vira pedido, dentro das travas.
  IF EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
    RAISE EXCEPTION 'Você já está na equipe desta escolta.';
  END IF;
  IF p_motivo IS NULL OR length(trim(p_motivo)) < 20 THEN
    RAISE EXCEPTION 'Informe o motivo da substituição com pelo menos 20 caracteres.';
  END IF;
  IF length(trim(p_motivo)) > 500 THEN
    RAISE EXCEPTION 'O motivo pode ter no máximo 500 caracteres.';
  END IF;
  v_inicio := e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min);
  IF now() < v_inicio THEN
    RAISE EXCEPTION 'Substituição de equipe liberada a partir de % (horário de Brasília).', public._hora_br(v_inicio);
  END IF;
  IF cfg.presenca_ligada THEN
    v_presenca := public._presenca_da_equipe(p_escolta_id);
    IF v_presenca IS NOT NULL THEN
      RAISE EXCEPTION 'A equipe escalada já confirmou presença na base. Fale com o supervisor.';
    END IF;
  END IF;
  v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
  IF v_conflito IS NOT NULL THEN
    RAISE EXCEPTION 'Você já é comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
  END IF;

  SELECT id, solicitante_usuario_id, expira_em INTO v_ped FROM public.mural_pedidos
  WHERE escolta_id = p_escolta_id AND status = 'pendente' FOR UPDATE;
  IF v_ped.id IS NOT NULL THEN
    IF v_ped.solicitante_usuario_id = v_usuario THEN
      RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em, 'ja_existia', true);
    END IF;
    RAISE EXCEPTION 'Já existe um pedido de substituição em análise para esta escolta.';
  END IF;

  v_equipe := public._equipe_atual(p_escolta_id);
  INSERT INTO public.mural_pedidos (escolta_id, solicitante_usuario_id, solicitante_vigilante_id, acompanhantes, veiculo_id,
                                    motivo, equipe_antes, expira_em, antecedencia_min)
  VALUES (p_escolta_id, v_usuario, v_vigilante, v_acomp_limpo, p_veiculo_id, trim(p_motivo), v_equipe,
          now() + make_interval(mins => cfg.aprovacao_tempo_limite_min),
          round(extract(epoch FROM (e.data_hora_prevista - now())) / 60)::int)
  RETURNING id, expira_em INTO v_ped;

  PERFORM public._auditar_mural('pedido_substituicao', p_escolta_id, jsonb_build_object('equipe', v_equipe),
    jsonb_build_object('pedido_id', v_ped.id, 'solicitante', v_nome, 'motivo', trim(p_motivo), 'expira_em', v_ped.expira_em));
  PERFORM public._avisar_app(p_escolta_id, 'pedido_substituicao', public._supervisao_ids(),
    'Pedido de substituição na escolta ' || e.codigo_escolta,
    v_nome || ' pediu para assumir. Equipe atual: ' || public._nomes_da_equipe(v_equipe) || '. Motivo: ' || trim(p_motivo)
      || '. Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.', v_ped.id);
  v_aviso := public._enfileirar_aviso('pedido:' || v_ped.id, 'central', p_escolta_id,
    public._texto_aviso_mural('Pedido de substituição de equipe', p_escolta_id, ARRAY[
      'Solicitante: ' || v_nome,
      'Equipe atual: ' || public._nomes_da_equipe(v_equipe),
      'Motivo: ' || trim(p_motivo),
      'Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.']));
  RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em,
                            'aviso_pelo_banco', v_aviso, 'codigo', e.codigo_escolta, 'equipe_atual', public._nomes_da_equipe(v_equipe));
END;
$function$;

CREATE OR REPLACE FUNCTION public.puxar_escolta(p_escolta_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_ev uuid; v_ja int; v_conflito text;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN
    RAISE EXCEPTION 'Sua conta não está vinculada a um vigilante ativo. Fale com o administrador.';
  END IF;
  -- Trava a linha: sem isto, dois operadores puxam a mesma escolta no mesmo instante.
  SELECT id, status, escala_fixa, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'Esta escolta não está mais disponível: ela já saiu do mural.'; END IF;
  IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: a equipe é definida pela supervisão.'; END IF;
  PERFORM public._travar_vigilante(v_vigilante);
  SELECT count(*) INTO v_ja FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  IF v_ja > 0 THEN RAISE EXCEPTION 'Esta escolta já tem equipe designada.'; END IF;
  v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
  IF v_conflito IS NOT NULL THEN
    RAISE EXCEPTION 'Você já é comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito,
      (SELECT intervalo_comandante_h FROM public.configuracoes_mural WHERE id = 1);
  END IF;
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
  INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
  VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
  PERFORM public._auditar_mural('puxou_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
    jsonb_build_object('assumida_por', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante)));
  RETURN jsonb_build_object('ok', true, 'escolta_veiculo_id', v_ev);
END;
$function$;

CREATE OR REPLACE FUNCTION public.devolver_escolta(p_escolta_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_vigilante uuid; e record; v_sou_cmd int; v_equipe jsonb; v_gestao boolean;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  v_vigilante := public.get_meu_vigilante_id();
  v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
  SELECT id, status, escala_fixa, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  -- So devolve enquanto nao comecou. Depois de iniciada, sair da escolta e decisao de supervisor.
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta já começou. Fale com o supervisor para sair dela.'; END IF;
  IF NOT v_gestao THEN
    IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: só a supervisão altera a equipe.'; END IF;
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante devolve a escolta ao mural.'; END IF;
  END IF;
  v_equipe := public._equipe_atual(p_escolta_id);
  DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
  -- Onda I: a presença anulada (zerar) fica como prova; só as válidas saem com a equipe.
  DELETE FROM public.mural_presencas WHERE escolta_id = p_escolta_id AND anulado_em IS NULL;
  PERFORM public._auditar_mural('devolveu_escolta_ao_mural', p_escolta_id, jsonb_build_object('equipe', v_equipe), '{"equipe": []}'::jsonb);
  -- Quem saiu junto (acompanhantes) fica sabendo pelo aplicativo.
  PERFORM public._avisar_app(p_escolta_id, 'substituicao_equipe',
    ARRAY(SELECT u FROM unnest(public._usuarios_dos_vigilantes(public._ids_da_equipe(v_equipe))) u WHERE u IS DISTINCT FROM public.get_meu_usuario_id()),
    'Escolta devolvida ao mural', 'A escolta ' || (SELECT codigo_escolta FROM public.escoltas WHERE id = p_escolta_id)
      || ' foi devolvida ao mural em ' || public._hora_br(now()) || '. Você não está mais escalado nela.', NULL);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.incluir_vigilante_na_minha_escolta(p_escolta_id uuid, p_vigilante_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_sou_cmd int; v_ev uuid; v_dup int;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  SELECT id, status, escala_fixa, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta já começou. Alteração de equipe passa pelo supervisor.'; END IF;
  IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') THEN
    IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: só a supervisão altera a equipe.'; END IF;
    SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
    WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
    IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante inclui vigilante nesta escolta.'; END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vigilantes WHERE id = p_vigilante_id AND status = 'ativo') THEN
    RAISE EXCEPTION 'Vigilante inválido ou inativo.';
  END IF;
  SELECT count(*) INTO v_dup FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = p_vigilante_id;
  IF v_dup > 0 THEN RAISE EXCEPTION 'Este vigilante já está na escolta.'; END IF;
  SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
  IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada.'; END IF;
  BEGIN
    INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
    VALUES (p_escolta_id, v_ev, p_vigilante_id, 'operador', false, v_usuario);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Este vigilante já está na escolta.';
  END;
  PERFORM public._auditar_mural('incluiu_vigilante', p_escolta_id, '{}'::jsonb,
    jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = p_vigilante_id)));
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.confirmar_presenca_base(p_escolta_id uuid, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_precisao numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_inicio timestamptz; v_ped uuid;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  IF v_vigilante IS NULL THEN RAISE EXCEPTION 'Sua conta não está vinculada a um vigilante ativo.'; END IF;
  SELECT id, status, data_hora_prevista, codigo_escolta, arquivada_em INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  IF e.arquivada_em IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;   -- onda I
  IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A presença na base só é confirmada antes do início da escolta.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
    RAISE EXCEPTION 'Você não está na equipe desta escolta.';
  END IF;
  v_inicio := e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1));
  IF now() < v_inicio THEN
    RAISE EXCEPTION 'A confirmação de presença abre às % (horário de Brasília).', public._hora_br(v_inicio);
  END IF;
  INSERT INTO public.mural_presencas (escolta_id, vigilante_id, usuario_id, latitude, longitude, precisao_metros, sem_gps)
  VALUES (p_escolta_id, v_vigilante, v_usuario, p_lat, p_lng, p_precisao, p_lat IS NULL OR p_lng IS NULL)
  ON CONFLICT (escolta_id, vigilante_id) WHERE anulado_em IS NULL DO NOTHING;   -- onda I: a anulada não impede confirmar de novo
  PERFORM public._auditar_mural('presenca_na_base', p_escolta_id, '{}'::jsonb,
    jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante),
                       'latitude', p_lat, 'longitude', p_lng, 'precisao_metros', p_precisao));
  -- Pedido pendente perde o objeto: a equipe chegou.
  UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
         observacao_decisao = 'Invalidado: a equipe confirmou presença na base.'
   WHERE escolta_id = p_escolta_id AND status = 'pendente'
  RETURNING id INTO v_ped;
  IF v_ped IS NOT NULL THEN
    PERFORM public._avisar_app(p_escolta_id, 'decisao_substituicao',
      ARRAY[(SELECT solicitante_usuario_id FROM public.mural_pedidos WHERE id = v_ped)],
      'Pedido de substituição invalidado', 'A equipe da escolta ' || e.codigo_escolta || ' confirmou presença na base.', v_ped);
  END IF;
  RETURN jsonb_build_object('ok', true, 'confirmado_em', now());
END;
$function$;

CREATE OR REPLACE FUNCTION public.listar_pedidos_mural(p_desde timestamp with time zone DEFAULT (now() - '30 days'::interval))
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  PERFORM public.processar_pedidos_vencidos();
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'escolta_id', p.escolta_id, 'codigo', e.codigo_escolta, 'cliente', c.nome_cliente,
           'data_hora_prevista', e.data_hora_prevista, 'solicitante', sv.nome_completo, 'solicitante_usuario_id', p.solicitante_usuario_id,
           'equipe_antes', public._nomes_da_equipe(p.equipe_antes), 'motivo', p.motivo, 'status', p.status,
           'criado_em', p.criado_em, 'expira_em', p.expira_em, 'antecedencia_min', p.antecedencia_min,
           'decidido_por', du.nome_completo, 'decidido_em', p.decidido_em, 'observacao_decisao', p.observacao_decisao)
         ORDER BY p.criado_em DESC), '[]'::jsonb) INTO v
  FROM public.mural_pedidos p
  JOIN public.escoltas e ON e.id = p.escolta_id
  JOIN public.clientes c ON c.id = e.cliente_id
  JOIN public.vigilantes sv ON sv.id = p.solicitante_vigilante_id
  LEFT JOIN public.usuarios du ON du.id = p.decidido_por
  WHERE p.criado_em >= p_desde
    AND e.arquivada_em IS NULL   -- onda I
    AND (v_perfil IN ('administrador', 'gestor', 'supervisor') OR p.solicitante_usuario_id = v_usuario);
  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mural_info(p_escolta_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; v jsonb;
BEGIN
  SELECT public.get_meu_perfil() INTO v_perfil;
  IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
  v_usuario := public.get_meu_usuario_id();
  v_vigilante := public.get_meu_vigilante_id();
  PERFORM public.processar_pedidos_vencidos();
  SELECT coalesce(jsonb_object_agg(e.id, jsonb_build_object(
           'janela_inicio', e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min),
           'escala_fixa', e.escala_fixa,
           -- O operador não lê o efetivo dos colegas pela RLS; sem isto a tela via toda
           -- escolta agendada como "sem equipe".
           'tem_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id),
           -- Nomes só para a gestão e para a própria equipe (a RLS de mural_presencas é assim).
           'presenca', CASE WHEN public._presenca_da_equipe(e.id) IS NULL THEN NULL
                            WHEN v_perfil IN ('administrador', 'gestor', 'supervisor', 'central')
                              OR EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante)
                            THEN public._presenca_da_equipe(e.id) ELSE 'sim' END,
           'eu_confirmei', EXISTS (SELECT 1 FROM public.mural_presencas mp WHERE mp.escolta_id = e.id AND mp.vigilante_id = v_vigilante AND mp.anulado_em IS NULL),
           'sou_da_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante),
           'pedido', (SELECT jsonb_build_object('id', p.id, 'expira_em', p.expira_em, 'meu', p.solicitante_usuario_id = v_usuario)
                      FROM public.mural_pedidos p WHERE p.escolta_id = e.id AND p.status = 'pendente'))), '{}'::jsonb)
    INTO v
  FROM public.escoltas e CROSS JOIN public.configuracoes_mural cfg
  WHERE e.id = ANY (p_escolta_ids) AND cfg.id = 1 AND e.status = 'agendada' AND e.arquivada_em IS NULL;
  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enviar_avisos_telegram()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r record; v_token text; v_central text; v_base text; v_chat text; v_req bigint; n int := 0;
BEGIN
  IF NOT public.avisos_pelo_banco_ativos() THEN RETURN 0; END IF;
  -- Onda I: aviso pendente de escolta arquivada, gravado antes do arquivamento, não sai
  -- (o aviso do próprio arquivamento nasce na mesma transação e sai).
  UPDATE public.avisos_telegram a SET situacao = 'erro', erro = 'Não enviado: escolta arquivada.'
    FROM public.escoltas e
   WHERE e.id = a.escolta_id AND a.situacao = 'pendente' AND e.arquivada_em IS NOT NULL AND a.criado_em < e.arquivada_em;
  EXECUTE $q$SELECT max(decrypted_secret) FILTER (WHERE name = 'telegram_bot_token'),
                    max(decrypted_secret) FILTER (WHERE name = 'telegram_chat_central')
             FROM vault.decrypted_secrets$q$ INTO v_token, v_central;
  SELECT telegram_api_base INTO v_base FROM public.configuracao_avisos WHERE id = 1;
  FOR r IN
    SELECT a.id, a.destino, a.texto, c.telegram_chat_id AS chat_cliente
    FROM public.avisos_telegram a
    LEFT JOIN public.escoltas e ON e.id = a.escolta_id
    LEFT JOIN public.clientes c ON c.id = e.cliente_id
    WHERE a.situacao = 'pendente'
    ORDER BY a.criado_em
    LIMIT 20
    FOR UPDATE OF a SKIP LOCKED
  LOOP
    v_chat := CASE WHEN r.destino = 'cliente' THEN coalesce(nullif(r.chat_cliente, ''), v_central) ELSE v_central END;
    UPDATE public.avisos_telegram SET situacao = 'enviando', enviado_em = now() WHERE id = r.id;
    EXECUTE $q$SELECT net.http_post(url := $1, body := $2, headers := '{"Content-Type": "application/json"}'::jsonb)$q$
      INTO v_req
      USING v_base || '/bot' || v_token || '/sendMessage',
            jsonb_build_object('chat_id', v_chat, 'text', r.texto, 'parse_mode', 'HTML', 'disable_web_page_preview', true);
    UPDATE public.avisos_telegram SET pg_net_id = v_req WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_etapa_escolta(p_escolta_id uuid, p_pontos jsonb DEFAULT '[]'::jsonb, p_status_atual text DEFAULT NULL::text, p_status_novo text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text, p_latitude numeric DEFAULT NULL::numeric, p_longitude numeric DEFAULT NULL::numeric, p_observacao_fechamento text DEFAULT NULL::text, p_data_hora_prevista timestamp with time zone DEFAULT NULL::timestamp with time zone, p_tipo_ponto_todas uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int; v_faltando text[]; v_status text; v_arquivada timestamptz;
BEGIN
  -- 0. Trava a escolta e confere a etapa ANTES de gravar qualquer coisa. Serializa duas
  --    viaturas do comboio registrando ao mesmo tempo (a segunda vê o ponto da primeira)
  --    e impede ponto de uma etapa que já passou.
  SELECT status, arquivada_em INTO v_status, v_arquivada FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
  -- Onda I (218): escolta arquivada não recebe registro (só o administrador a enxerga).
  IF v_arquivada IS NOT NULL THEN RAISE EXCEPTION 'Escolta arquivada: o administrador precisa recuperá-la antes.'; END IF;
  IF p_status_atual IS NOT NULL AND v_status IS DISTINCT FROM p_status_atual THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 1. Pontos de controle (todas as viaturas num statement só). Onda I: o autor é sempre
  --    quem está na sessão (em nome de quem fez); sem sessão (SQL), vale o informado.
  IF jsonb_array_length(coalesce(p_pontos, '[]'::jsonb)) > 0 THEN
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid)
               WHERE NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
                                 WHERE ev.id = x.escolta_veiculo_id AND ev.escolta_id = p_escolta_id)) THEN
      RAISE EXCEPTION 'Ponto de controle de viatura que não pertence a esta escolta.';
    END IF;
    INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude,
                                        precisao_metros, sem_sinal_gps, foto_id, lancado_por, observacoes,
                                        sincronizado, criado_offline)
    SELECT x.escolta_veiculo_id, x.tipo_ponto_id, coalesce(x.data_hora, now()), x.latitude, x.longitude,
           x.precisao_metros, coalesce(x.sem_sinal_gps, false), x.foto_id,
           coalesce(public.get_meu_usuario_id(), x.lancado_por), x.observacoes,
           coalesce(x.sincronizado, true), coalesce(x.criado_offline, false)
    FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid, tipo_ponto_id uuid, data_hora timestamptz,
                                           latitude numeric, longitude numeric, precisao_metros numeric,
                                           sem_sinal_gps boolean, foto_id uuid, lancado_por uuid, observacoes text,
                                           sincronizado boolean, criado_offline boolean);
  END IF;

  IF p_status_novo IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'avancou', false);
  END IF;

  -- 2. Comboio: a etapa só avança quando todas as viaturas registraram o ponto dela.
  --    Onda I: ponto anulado (etapa desfeita pela gestão) não conta.
  IF p_tipo_ponto_todas IS NOT NULL THEN
    SELECT array_agg(coalesce(ve.placa, 'sem placa') ORDER BY ev.criado_em) INTO v_faltando
    FROM public.escolta_veiculos ev
    LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
    WHERE ev.escolta_id = p_escolta_id
      AND NOT EXISTS (SELECT 1 FROM public.pontos_controle pc
                      WHERE pc.escolta_veiculo_id = ev.id AND pc.tipo_ponto_id = p_tipo_ponto_todas
                        AND pc.anulado_em IS NULL);
    IF v_faltando IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'avancou', false, 'faltando', to_jsonb(v_faltando));
    END IF;
  END IF;

  -- 3. Status, com a guarda do status atual (a trigger valida a transição).
  UPDATE public.escoltas SET
         status = p_status_novo,
         observacao_fechamento = CASE
           WHEN p_status_novo IN ('finalizada', 'cancelada') THEN p_observacao_fechamento
           WHEN p_data_hora_prevista IS NOT NULL THEN NULL
           ELSE observacao_fechamento END,
         data_finalizacao = CASE WHEN p_status_novo = 'finalizada' THEN now() ELSE data_finalizacao END,
         data_hora_prevista = coalesce(p_data_hora_prevista, data_hora_prevista)
   WHERE id = p_escolta_id AND status = p_status_atual;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
  END IF;

  -- 4. Histórico, com autor, na mesma transação. Onda I: via_rpc = true (escolta.historico_rpc).
  PERFORM set_config('escolta.historico_rpc', 'on', true);
  INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora,
                                               latitude, longitude, observacao)
  VALUES (p_escolta_id, p_status_atual, p_status_novo, public.get_meu_usuario_id(), now(),
          p_latitude, p_longitude, p_observacao);
  PERFORM set_config('escolta.historico_rpc', 'off', true);

  RETURN jsonb_build_object('ok', true, 'avancou', true);
END;
$function$;

-- Privilégios das recriadas (CREATE OR REPLACE mantém os anteriores; repetidos por clareza).
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['_conflito_comandante(uuid, uuid)', '_presenca_da_equipe(uuid)', '_executar_substituicao(uuid, text)',
                           'enviar_avisos_telegram()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['assumir_escolta(uuid, uuid[], uuid, text)', 'puxar_escolta(uuid)', 'devolver_escolta(uuid)',
                           'incluir_vigilante_na_minha_escolta(uuid, uuid)', 'confirmar_presenca_base(uuid, numeric, numeric, numeric)',
                           'listar_pedidos_mural(timestamptz)', 'mural_info(uuid[])',
                           'registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- Conferência (funções reescritas em cadeia, docs/14 18.4):
-- SELECT prosrc LIKE '%anulado_em IS NULL%' AND prosrc LIKE '%arquivada%' AND prosrc LIKE '%historico_rpc%'
--   FROM pg_proc WHERE proname = 'registrar_etapa_escolta';                                   -- true
-- SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('editar_escolta',
--   'pendencias_da_escolta','concluir_escolta_antecipada','voltar_etapa_escolta','zerar_escolta','arquivar_escolta','recuperar_escolta');  -- 7
-- SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace
--   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));   -- 0

COMMIT;

-- Conferência do bloco 2 (somente leitura):
SELECT 'mural_travas_ativas' AS item, public.mural_travas_ativas()::text AS valor
UNION ALL SELECT 'cron do lote', string_agg(jobname, ', ') FROM cron.job WHERE jobname LIKE 'lote2026%'
UNION ALL SELECT 'bucket fotos publico (esperado false)', public::text FROM storage.buckets WHERE id = 'fotos'
UNION ALL SELECT 'policies de leitura do storage', string_agg(policyname, ', ') FROM pg_policies WHERE schemaname = 'storage' AND cmd = 'SELECT'
UNION ALL SELECT 'escoltas abertas com periodicidade (esperado 0)', count(*)::text FROM public.escoltas WHERE status NOT IN ('finalizada','cancelada') AND periodicidade_checkin_min IS NOT NULL
UNION ALL SELECT 'índices únicos do efetivo (esperado 2)', count(*)::text FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
  WHERE c.relname IN ('escolta_efetivo_escolta_vigilante_uk', 'escolta_veiculos_escolta_veiculo_uk') AND i.indisunique
UNION ALL SELECT 'avisos do mural pela central (esperado true)', (prosrc LIKE '%lote_interno.notificar%')::text FROM pg_proc WHERE oid = 'public._avisar_app(uuid, text, uuid[], text, text, uuid)'::regprocedure
UNION ALL SELECT 'Telegram do check-in pelo cron (esperado true)', checkin_telegram_pelo_cron::text FROM public.configuracao_avisos WHERE id = 1
UNION ALL SELECT 'onda I: RPCs da gestão (esperado 7)', count(*)::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('editar_escolta','pendencias_da_escolta','concluir_escolta_antecipada','voltar_etapa_escolta','zerar_escolta','arquivar_escolta','recuperar_escolta')
UNION ALL SELECT 'onda I: registrar_etapa_escolta com anulado, arquivada e via_rpc (esperado true)', (prosrc LIKE '%pc.anulado_em IS NULL%' AND prosrc LIKE '%v_arquivada%' AND prosrc LIKE '%historico_rpc%')::text FROM pg_proc WHERE proname = 'registrar_etapa_escolta'
UNION ALL SELECT 'onda I: funções do lote_interno executáveis por anon ou authenticated (esperado 0)', count(*)::text FROM pg_proc p WHERE p.pronamespace = 'lote_interno'::regnamespace AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))
UNION ALL SELECT 'onda I: restrição das viaturas adiável e imediata (esperado true)', (condeferrable AND NOT condeferred)::text FROM pg_constraint WHERE conname = 'escolta_veiculos_escolta_veiculo_uk';
-- Esperado: true; lote2026_avisos_telegram, lote2026_pedidos_vencidos, lote2026_avisos_checkin; false; fotos_leitura_autenticada; 0; 2; true; true; onda I: 7; true; 0; true.
-- Com 'envio pelo banco ativo' falso (conferência do bloco 1), o Telegram do check-in continua
-- saindo pelo navegador, com reserva no banco (reservar_alertas_checkin); registrar no relatório.
-- Teste rápido sem escrever dado: abrir em aba anônima a URL pública antiga de uma foto (deve falhar).

-- ════════════════════════════════════════════════════════════════════════════
-- REVERSÃO (só se o teste de produção de uma onda falhar; na ordem abaixo)
-- Cada bloco vem do arquivo NNN_..._reverter.sql, testado na homologação.
-- Onda I: a 213_reverter guarda anulações, arquivamentos, carimbos, resets e conclusões em
-- backup_20261008 (uma linha por registro; rodar de novo não duplica). Ao reaplicar a 213, a
-- 214 e a 218, rodar database/migrations/213_poder_total_estrutura_restaurar.sql para devolver.
-- ════════════════════════════════════════════════════════════════════════════

-- ──────── reverter 218_poder_total_rpcs ────────
-- -- 218_poder_total_rpcs_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda I e o deploy; depois este arquivo; a 214 e
-- -- a 213 só depois dele. Tira as RPCs da gestão e as auxiliares do lote_interno, devolve os
-- -- corpos anteriores (204 com a 217, 202 e 214) e a restrição única de mural_presencas.
-- -- Presenças do mural anuladas que repetem uma válida vão para backup_20261008 antes (senão
-- -- a restrição única não volta); voltam pelo 213_poder_total_estrutura_restaurar.sql.
-- DROP FUNCTION IF EXISTS public.editar_escolta(uuid, jsonb, jsonb, text);
-- DROP FUNCTION IF EXISTS public.pendencias_da_escolta(uuid);
-- DROP FUNCTION IF EXISTS public.concluir_escolta_antecipada(uuid, text);
-- DROP FUNCTION IF EXISTS public.voltar_etapa_escolta(uuid, text, boolean, jsonb);
-- DROP FUNCTION IF EXISTS public.zerar_escolta(uuid, text, boolean, jsonb);
-- DROP FUNCTION IF EXISTS public.voltar_etapa_escolta(uuid, text, boolean);
-- DROP FUNCTION IF EXISTS public.zerar_escolta(uuid, text, boolean);
-- DROP FUNCTION IF EXISTS public.arquivar_escolta(uuid, text);
-- DROP FUNCTION IF EXISTS public.recuperar_escolta(uuid, text);
-- DROP FUNCTION IF EXISTS lote_interno.executar_reset(uuid, text, text, boolean, jsonb);
-- DROP FUNCTION IF EXISTS lote_interno.executar_reset(uuid, text, text, boolean);
-- DROP FUNCTION IF EXISTS lote_interno.viatura_tem_registro(uuid);
-- DROP FUNCTION IF EXISTS lote_interno.modo_gestao(boolean);
-- DROP FUNCTION IF EXISTS lote_interno.exigir_motivo(text);
-- DROP FUNCTION IF EXISTS lote_interno.exigir_gestao(boolean);
-- DROP FUNCTION IF EXISTS lote_interno.pendencias(uuid);
-- DROP FUNCTION IF EXISTS lote_interno.destino_voltar(uuid, text);
-- DROP FUNCTION IF EXISTS lote_interno.alvos_anulacao(uuid, text, boolean);
-- DROP FUNCTION IF EXISTS lote_interno.ancora_etapa(uuid, text);
-- DROP FUNCTION IF EXISTS lote_interno.registros_validos(uuid);
-- DROP FUNCTION IF EXISTS lote_interno.avisar_acao_gestao(uuid, text, text, text, text[]);
-- DROP FUNCTION IF EXISTS lote_interno.auditar(text, uuid, jsonb, jsonb);
-- DROP FUNCTION IF EXISTS lote_interno.tipo_ponto_da_etapa(text);
-- DROP FUNCTION IF EXISTS lote_interno.sequencia_status();
-- DROP FUNCTION IF EXISTS lote_interno.rotulo_status(text);
--
-- CREATE SCHEMA IF NOT EXISTS backup_20261008;
-- REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
-- CREATE TABLE IF NOT EXISTS backup_20261008.mural_presencas_anuladas (linha jsonb NOT NULL, gravado_em timestamptz NOT NULL DEFAULT now());
-- REVOKE ALL ON backup_20261008.mural_presencas_anuladas FROM PUBLIC, anon, authenticated;
-- -- Uma linha por presença (rodar de novo, ou reverter outra vez depois de reaplicar, não duplica).
-- DELETE FROM backup_20261008.mural_presencas_anuladas a USING backup_20261008.mural_presencas_anuladas b
--  WHERE a.linha ->> 'id' = b.linha ->> 'id' AND (a.gravado_em, a.ctid) < (b.gravado_em, b.ctid);
-- CREATE UNIQUE INDEX IF NOT EXISTS mural_presencas_anuladas_uk ON backup_20261008.mural_presencas_anuladas ((linha ->> 'id'));
-- DO $$
-- BEGIN
--   IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'mural_presencas_escolta_id_vigilante_id_key'
--                   AND conrelid = 'public.mural_presencas'::regclass) THEN
--     INSERT INTO backup_20261008.mural_presencas_anuladas (linha)
--     SELECT to_jsonb(m) FROM public.mural_presencas m
--      WHERE m.anulado_em IS NOT NULL
--        AND EXISTS (SELECT 1 FROM public.mural_presencas o WHERE o.escolta_id = m.escolta_id AND o.vigilante_id = m.vigilante_id AND o.id <> m.id)
--     ON CONFLICT ((linha ->> 'id')) DO UPDATE SET linha = EXCLUDED.linha, gravado_em = now();
--     DELETE FROM public.mural_presencas m
--      WHERE m.anulado_em IS NOT NULL
--        AND EXISTS (SELECT 1 FROM public.mural_presencas o WHERE o.escolta_id = m.escolta_id AND o.vigilante_id = m.vigilante_id AND o.id <> m.id);
--     DROP INDEX IF EXISTS public.mural_presencas_valida_uk;
--     ALTER TABLE public.mural_presencas ADD CONSTRAINT mural_presencas_escolta_id_vigilante_id_key UNIQUE (escolta_id, vigilante_id);
--   END IF;
-- END $$;
-- DROP INDEX IF EXISTS public.mural_presencas_valida_uk;
--
-- -- Corpos anteriores (copiados do banco montado na ordem dos blocos, antes da 218).
-- CREATE OR REPLACE FUNCTION public._conflito_comandante(p_vigilante_id uuid, p_escolta_id uuid)
--  RETURNS text
--  LANGUAGE sql
--  STABLE SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
--   SELECT o.codigo_escolta
--   FROM public.escoltas alvo
--   CROSS JOIN public.configuracoes_mural cfg
--   JOIN public.escolta_efetivo ee ON ee.vigilante_id = p_vigilante_id AND ee.papel_na_escolta = 'comandante'
--   JOIN public.escoltas o ON o.id = ee.escolta_id
--   WHERE alvo.id = p_escolta_id AND cfg.id = 1
--     AND o.id <> p_escolta_id AND o.status = 'agendada'
--     AND abs(extract(epoch FROM (o.data_hora_prevista - alvo.data_hora_prevista))) < cfg.intervalo_comandante_h * 3600
--   LIMIT 1
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public._presenca_da_equipe(p_escolta_id uuid)
--  RETURNS text
--  LANGUAGE sql
--  STABLE SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
--   SELECT string_agg(v.nome_completo, ', ')
--   FROM public.mural_presencas mp
--   JOIN public.escolta_efetivo ee ON ee.escolta_id = mp.escolta_id AND ee.vigilante_id = mp.vigilante_id
--   JOIN public.vigilantes v ON v.id = mp.vigilante_id
--   WHERE mp.escolta_id = p_escolta_id
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public._executar_substituicao(p_pedido_id uuid, p_via text)
--  RETURNS boolean
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE
--   p public.mural_pedidos%ROWTYPE;
--   e record; v_motivo text; v_ev uuid; v_acomp uuid; v_equipe_agora jsonb; v_presenca text; v_conflito text;
--   v_nome text; v_aviso boolean;
-- BEGIN
--   SELECT * INTO p FROM public.mural_pedidos WHERE id = p_pedido_id;
--   IF p.id IS NULL OR p.status NOT IN ('aprovado', 'liberado_por_tempo') THEN
--     RAISE EXCEPTION 'Pedido nao esta liberado para execucao.';
--   END IF;
--   SELECT id, status, escala_fixa, codigo_escolta, data_hora_prevista INTO e FROM public.escoltas WHERE id = p.escolta_id;
--   PERFORM public._travar_vigilante(p.solicitante_vigilante_id);
--   v_equipe_agora := public._equipe_atual(p.escolta_id);
--   v_presenca := CASE WHEN (SELECT presenca_ligada FROM public.configuracoes_mural WHERE id = 1)
--                      THEN public._presenca_da_equipe(p.escolta_id) END;
--   v_conflito := public._conflito_comandante(p.solicitante_vigilante_id, p.escolta_id);
--
--   v_motivo := CASE
--     WHEN e.status IS DISTINCT FROM 'agendada' THEN 'a escolta ja comecou ou foi encerrada'
--     WHEN e.escala_fixa THEN 'a escolta passou a ser de escala fixa'
--     WHEN now() < e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1))
--       THEN 'a escolta foi remarcada e saiu da janela de substituicao'
--     WHEN v_presenca IS NOT NULL THEN 'a equipe confirmou presenca na base (' || v_presenca || ')'
--     WHEN public._ids_da_equipe(v_equipe_agora) IS DISTINCT FROM public._ids_da_equipe(p.equipe_antes) THEN 'a equipe da escolta mudou depois do pedido'
--     WHEN v_conflito IS NOT NULL THEN 'o solicitante passou a comandar a escolta ' || v_conflito || ' a menos do intervalo minimo'
--     WHEN NOT EXISTS (SELECT 1 FROM public.vigilantes v JOIN public.usuarios u ON u.id = v.usuario_id
--                      WHERE v.id = p.solicitante_vigilante_id AND v.status = 'ativo' AND u.status = 'ativo') THEN 'o solicitante nao esta mais ativo'
--     WHEN EXISTS (SELECT 1 FROM unnest(p.acompanhantes) a WHERE NOT EXISTS
--                  (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN 'um acompanhante nao esta mais ativo'
--     WHEN p.veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p.veiculo_id AND status = 'ativo') THEN 'a viatura indicada nao esta mais ativa'
--     -- Onda G (210): a placa escolhida não pode estar em outra viatura da mesma escolta.
--     WHEN p.veiculo_id IS NOT NULL AND EXISTS (
--            SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p.escolta_id AND ev.veiculo_id = p.veiculo_id
--               AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1))
--       THEN 'a viatura indicada já está em outra viatura da escolta'
--   END;
--
--   -- Onda G (210): os índices únicos do efetivo e das viaturas recusam repetição. Se uma
--   -- gravação esbarrar neles, a troca inteira é desfeita e o pedido é invalidado com o
--   -- motivo, em vez de o erro técnico subir para quem aprovou ou para o cron.
--   IF v_motivo IS NULL THEN
--     BEGIN
--       SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p.escolta_id ORDER BY criado_em LIMIT 1;
--       IF p.veiculo_id IS NOT NULL THEN
--         UPDATE public.escolta_veiculos SET veiculo_id = p.veiculo_id, atualizado_em = now(), atualizado_por = p.solicitante_usuario_id
--          WHERE id = v_ev;
--       END IF;
--       DELETE FROM public.escolta_efetivo WHERE escolta_id = p.escolta_id;
--       INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--       VALUES (p.escolta_id, v_ev, p.solicitante_vigilante_id, 'comandante', true, p.solicitante_usuario_id);
--       FOREACH v_acomp IN ARRAY p.acompanhantes LOOP
--         IF v_acomp IS DISTINCT FROM p.solicitante_vigilante_id THEN
--           INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--           VALUES (p.escolta_id, v_ev, v_acomp, 'operador', false, p.solicitante_usuario_id) ON CONFLICT DO NOTHING;
--         END IF;
--       END LOOP;
--     EXCEPTION WHEN unique_violation THEN
--       v_motivo := 'a viatura ou um vigilante indicado já está na escolta';
--     END;
--   END IF;
--
--   IF v_motivo IS NOT NULL THEN
--     UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = coalesce(decidido_em, now()),
--            observacao_decisao = trim(coalesce(observacao_decisao, '') || ' Invalidado: ' || v_motivo || '.')
--      WHERE id = p.id;
--     INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
--     VALUES (p.decidido_por, 'pedido_substituicao_invalidado', 'escoltas', p.escolta_id, jsonb_build_object('pedido_id', p.id),
--             jsonb_build_object('pedido_id', p.id, 'via', p_via, 'motivo', v_motivo), now());
--     PERFORM public._avisar_app(p.escolta_id, 'decisao_substituicao', ARRAY[p.solicitante_usuario_id],
--       'Pedido de substituição invalidado', 'O pedido para a escolta ' || e.codigo_escolta || ' não foi executado: ' || v_motivo || '.', p.id);
--     RETURN false;
--   END IF;
--
--   SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = p.solicitante_vigilante_id;
--   INSERT INTO public.logs_auditoria (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
--   VALUES (p.solicitante_usuario_id, 'substituicao_de_equipe', 'escoltas', p.escolta_id,
--           jsonb_build_object('equipe', p.equipe_antes),
--           jsonb_build_object('pedido_id', p.id, 'via', p_via, 'assumida_por', v_nome, 'motivo', p.motivo,
--                              'acompanhantes', (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (p.acompanhantes)),
--                              'trocou_viatura', p.veiculo_id IS NOT NULL,
--                              'decidido_por', (SELECT nome_completo FROM public.usuarios WHERE id = p.decidido_por)),
--           now());
--
--   PERFORM public._avisar_app(p.escolta_id, 'substituicao_equipe',
--     public._usuarios_dos_vigilantes(public._ids_da_equipe(p.equipe_antes)) || public._supervisao_ids() || ARRAY[p.solicitante_usuario_id],
--     'Equipe substituída na escolta ' || e.codigo_escolta,
--     v_nome || ' assumiu a escolta em ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo, sem resposta da supervisão)' ELSE ' (aprovado pela supervisão)' END
--       || '. Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes) || '. Motivo: ' || p.motivo,
--     p.id);
--   v_aviso := public._enfileirar_aviso('substituicao:' || p.id, 'central', p.escolta_id,
--     public._texto_aviso_mural('Equipe substituída', p.escolta_id, ARRAY[
--       'Assumiu: ' || v_nome,
--       'Equipe anterior: ' || public._nomes_da_equipe(p.equipe_antes),
--       'Quando: ' || public._hora_br(now()) || CASE WHEN p_via = 'liberado_por_tempo' THEN ' (liberado por tempo)' ELSE ' (aprovado)' END,
--       'Motivo: ' || p.motivo]));
--   RETURN true;
-- END;
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[] DEFAULT '{}'::uuid[], p_veiculo_id uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text)
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE
--   v_perfil text; v_usuario uuid; v_vigilante uuid; e record; cfg record; v_qtd int; v_ev uuid; v_acomp uuid;
--   v_conflito text; v_presenca text; v_ped record; v_equipe jsonb; v_nome text; v_aviso boolean; v_inicio timestamptz;
--   v_acomp_limpo uuid[];
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   v_usuario := public.get_meu_usuario_id();
--   v_vigilante := public.get_meu_vigilante_id();
--   IF v_vigilante IS NULL THEN
--     RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo. Fale com o administrador.';
--   END IF;
--
--   -- Trava a linha: duas pessoas assumindo ao mesmo tempo produziriam duas equipes.
--   SELECT id, status, escala_fixa, data_hora_prevista, codigo_escolta INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
--   IF e.status <> 'agendada' THEN
--     RAISE EXCEPTION 'Esta escolta ja comecou e nao pode ter a equipe trocada. Fale com o supervisor.';
--   END IF;
--   IF e.escala_fixa THEN
--     RAISE EXCEPTION 'Escolta de escala fixa: a equipe e definida pela supervisao.';
--   END IF;
--   PERFORM public._travar_vigilante(v_vigilante);
--
--   v_acomp_limpo := ARRAY(SELECT DISTINCT a FROM unnest(coalesce(p_acompanhantes, '{}')) a WHERE a IS DISTINCT FROM v_vigilante);
--   IF EXISTS (SELECT 1 FROM unnest(v_acomp_limpo) a WHERE NOT EXISTS
--              (SELECT 1 FROM public.vigilantes v WHERE v.id = a AND v.status = 'ativo')) THEN
--     RAISE EXCEPTION 'Acompanhante invalido ou inativo.';
--   END IF;
--   IF p_veiculo_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.veiculos WHERE id = p_veiculo_id AND status = 'ativo') THEN
--     RAISE EXCEPTION 'Viatura invalida ou fora de operacao.';
--   END IF;
--   -- Onda G (210): a placa escolhida troca a primeira viatura; não pode ser a de outra
--   -- viatura da mesma escolta.
--   IF p_veiculo_id IS NOT NULL AND EXISTS (
--        SELECT 1 FROM public.escolta_veiculos ev WHERE ev.escolta_id = p_escolta_id AND ev.veiculo_id = p_veiculo_id
--           AND ev.id IS DISTINCT FROM (SELECT id FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1)) THEN
--     RAISE EXCEPTION 'Esta viatura já está em outra viatura desta escolta. Escolha outra placa ou mantenha a atual.';
--   END IF;
--
--   SELECT * INTO cfg FROM public.configuracoes_mural WHERE id = 1;
--   SELECT count(*) INTO v_qtd FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
--   SELECT nome_completo INTO v_nome FROM public.vigilantes WHERE id = v_vigilante;
--
--   -- Escolta sem equipe: assume na hora, como antes, com T5.
--   IF v_qtd = 0 THEN
--     v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
--     IF v_conflito IS NOT NULL THEN
--       RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
--     END IF;
--     SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
--     IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
--     BEGIN
--       IF p_veiculo_id IS NOT NULL THEN
--         UPDATE public.escolta_veiculos SET veiculo_id = p_veiculo_id, atualizado_em = now(), atualizado_por = v_usuario WHERE id = v_ev;
--       END IF;
--       INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--       VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
--       FOREACH v_acomp IN ARRAY v_acomp_limpo LOOP
--         INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--         VALUES (p_escolta_id, v_ev, v_acomp, 'operador', false, v_usuario) ON CONFLICT DO NOTHING;
--       END LOOP;
--     EXCEPTION WHEN unique_violation THEN
--       RAISE EXCEPTION 'A viatura ou um vigilante escolhido já está nesta escolta. Revise a equipe e a viatura e tente de novo.';
--     END;
--     PERFORM public._auditar_mural('assumiu_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
--       jsonb_build_object('assumida_por', v_nome, 'acompanhantes',
--         (SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb) FROM public.vigilantes WHERE id = ANY (v_acomp_limpo)),
--         'trocou_viatura', p_veiculo_id IS NOT NULL));
--     RETURN jsonb_build_object('ok', true, 'status', 'assumida', 'substituiu_equipe', false);
--   END IF;
--
--   -- Escolta com equipe: vira pedido, dentro das travas.
--   IF EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
--     RAISE EXCEPTION 'Voce ja esta na equipe desta escolta.';
--   END IF;
--   IF p_motivo IS NULL OR length(trim(p_motivo)) < 20 THEN
--     RAISE EXCEPTION 'Informe o motivo da substituicao com pelo menos 20 caracteres.';
--   END IF;
--   IF length(trim(p_motivo)) > 500 THEN
--     RAISE EXCEPTION 'O motivo pode ter no maximo 500 caracteres.';
--   END IF;
--   v_inicio := e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min);
--   IF now() < v_inicio THEN
--     RAISE EXCEPTION 'Substituicao de equipe liberada a partir de % (horario de Brasilia).', public._hora_br(v_inicio);
--   END IF;
--   IF cfg.presenca_ligada THEN
--     v_presenca := public._presenca_da_equipe(p_escolta_id);
--     IF v_presenca IS NOT NULL THEN
--       RAISE EXCEPTION 'A equipe escalada ja confirmou presenca na base. Fale com o supervisor.';
--     END IF;
--   END IF;
--   v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
--   IF v_conflito IS NOT NULL THEN
--     RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito, cfg.intervalo_comandante_h;
--   END IF;
--
--   SELECT id, solicitante_usuario_id, expira_em INTO v_ped FROM public.mural_pedidos
--   WHERE escolta_id = p_escolta_id AND status = 'pendente' FOR UPDATE;
--   IF v_ped.id IS NOT NULL THEN
--     IF v_ped.solicitante_usuario_id = v_usuario THEN
--       RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em, 'ja_existia', true);
--     END IF;
--     RAISE EXCEPTION 'Ja existe um pedido de substituicao em analise para esta escolta.';
--   END IF;
--
--   v_equipe := public._equipe_atual(p_escolta_id);
--   INSERT INTO public.mural_pedidos (escolta_id, solicitante_usuario_id, solicitante_vigilante_id, acompanhantes, veiculo_id,
--                                     motivo, equipe_antes, expira_em, antecedencia_min)
--   VALUES (p_escolta_id, v_usuario, v_vigilante, v_acomp_limpo, p_veiculo_id, trim(p_motivo), v_equipe,
--           now() + make_interval(mins => cfg.aprovacao_tempo_limite_min),
--           round(extract(epoch FROM (e.data_hora_prevista - now())) / 60)::int)
--   RETURNING id, expira_em INTO v_ped;
--
--   PERFORM public._auditar_mural('pedido_substituicao', p_escolta_id, jsonb_build_object('equipe', v_equipe),
--     jsonb_build_object('pedido_id', v_ped.id, 'solicitante', v_nome, 'motivo', trim(p_motivo), 'expira_em', v_ped.expira_em));
--   PERFORM public._avisar_app(p_escolta_id, 'pedido_substituicao', public._supervisao_ids(),
--     'Pedido de substituição na escolta ' || e.codigo_escolta,
--     v_nome || ' pediu para assumir. Equipe atual: ' || public._nomes_da_equipe(v_equipe) || '. Motivo: ' || trim(p_motivo)
--       || '. Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.', v_ped.id);
--   v_aviso := public._enfileirar_aviso('pedido:' || v_ped.id, 'central', p_escolta_id,
--     public._texto_aviso_mural('Pedido de substituição de equipe', p_escolta_id, ARRAY[
--       'Solicitante: ' || v_nome,
--       'Equipe atual: ' || public._nomes_da_equipe(v_equipe),
--       'Motivo: ' || trim(p_motivo),
--       'Sem resposta até ' || public._hora_br(v_ped.expira_em) || ', o pedido é liberado automaticamente.']));
--   RETURN jsonb_build_object('ok', true, 'status', 'pendente', 'pedido_id', v_ped.id, 'expira_em', v_ped.expira_em,
--                             'aviso_pelo_banco', v_aviso, 'codigo', e.codigo_escolta, 'equipe_atual', public._nomes_da_equipe(v_equipe));
-- END;
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public.puxar_escolta(p_escolta_id uuid)
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_ev uuid; v_ja int; v_conflito text;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   v_usuario := public.get_meu_usuario_id();
--   v_vigilante := public.get_meu_vigilante_id();
--   IF v_vigilante IS NULL THEN
--     RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo. Fale com o administrador.';
--   END IF;
--   -- Trava a linha: sem isto, dois operadores puxam a mesma escolta no mesmo instante.
--   SELECT id, status, escala_fixa INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
--   IF e.status <> 'agendada' THEN RAISE EXCEPTION 'Esta escolta nao esta mais disponivel: ela ja saiu do mural.'; END IF;
--   IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: a equipe e definida pela supervisao.'; END IF;
--   PERFORM public._travar_vigilante(v_vigilante);
--   SELECT count(*) INTO v_ja FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
--   IF v_ja > 0 THEN RAISE EXCEPTION 'Esta escolta ja tem equipe designada.'; END IF;
--   v_conflito := public._conflito_comandante(v_vigilante, p_escolta_id);
--   IF v_conflito IS NOT NULL THEN
--     RAISE EXCEPTION 'Voce ja e comandante da escolta % a menos de % h desta. Fale com o supervisor.', v_conflito,
--       (SELECT intervalo_comandante_h FROM public.configuracoes_mural WHERE id = 1);
--   END IF;
--   SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
--   IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.'; END IF;
--   INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--   VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
--   PERFORM public._auditar_mural('puxou_escolta_do_mural', p_escolta_id, '{"equipe": []}'::jsonb,
--     jsonb_build_object('assumida_por', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante)));
--   RETURN jsonb_build_object('ok', true, 'escolta_veiculo_id', v_ev);
-- END;
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public.devolver_escolta(p_escolta_id uuid)
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE v_perfil text; v_vigilante uuid; e record; v_sou_cmd int; v_equipe jsonb; v_gestao boolean;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   v_vigilante := public.get_meu_vigilante_id();
--   v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
--   SELECT id, status, escala_fixa INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
--   -- So devolve enquanto nao comecou. Depois de iniciada, sair da escolta e decisao de supervisor.
--   IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta ja comecou. Fale com o supervisor para sair dela.'; END IF;
--   IF NOT v_gestao THEN
--     IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: so a supervisao altera a equipe.'; END IF;
--     SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
--     WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
--     IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante devolve a escolta ao mural.'; END IF;
--   END IF;
--   v_equipe := public._equipe_atual(p_escolta_id);
--   DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
--   DELETE FROM public.mural_presencas WHERE escolta_id = p_escolta_id;
--   PERFORM public._auditar_mural('devolveu_escolta_ao_mural', p_escolta_id, jsonb_build_object('equipe', v_equipe), '{"equipe": []}'::jsonb);
--   -- Quem saiu junto (acompanhantes) fica sabendo pelo aplicativo.
--   PERFORM public._avisar_app(p_escolta_id, 'substituicao_equipe',
--     ARRAY(SELECT u FROM unnest(public._usuarios_dos_vigilantes(public._ids_da_equipe(v_equipe))) u WHERE u IS DISTINCT FROM public.get_meu_usuario_id()),
--     'Escolta devolvida ao mural', 'A escolta ' || (SELECT codigo_escolta FROM public.escoltas WHERE id = p_escolta_id)
--       || ' foi devolvida ao mural em ' || public._hora_br(now()) || '. Você não está mais escalado nela.', NULL);
--   RETURN jsonb_build_object('ok', true);
-- END;
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public.incluir_vigilante_na_minha_escolta(p_escolta_id uuid, p_vigilante_id uuid)
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_sou_cmd int; v_ev uuid; v_dup int;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   v_usuario := public.get_meu_usuario_id();
--   v_vigilante := public.get_meu_vigilante_id();
--   SELECT id, status, escala_fixa INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
--   IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A escolta ja comecou. Alteracao de equipe passa pelo supervisor.'; END IF;
--   IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') THEN
--     IF e.escala_fixa THEN RAISE EXCEPTION 'Escolta de escala fixa: so a supervisao altera a equipe.'; END IF;
--     SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
--     WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante AND papel_na_escolta = 'comandante';
--     IF v_sou_cmd = 0 THEN RAISE EXCEPTION 'Apenas o comandante inclui vigilante nesta escolta.'; END IF;
--   END IF;
--   IF NOT EXISTS (SELECT 1 FROM public.vigilantes WHERE id = p_vigilante_id AND status = 'ativo') THEN
--     RAISE EXCEPTION 'Vigilante invalido ou inativo.';
--   END IF;
--   SELECT count(*) INTO v_dup FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = p_vigilante_id;
--   IF v_dup > 0 THEN RAISE EXCEPTION 'Este vigilante ja esta na escolta.'; END IF;
--   SELECT id INTO v_ev FROM public.escolta_veiculos WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
--   IF v_ev IS NULL THEN RAISE EXCEPTION 'Escolta sem viatura vinculada.'; END IF;
--   BEGIN
--     INSERT INTO public.escolta_efetivo (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--     VALUES (p_escolta_id, v_ev, p_vigilante_id, 'operador', false, v_usuario);
--   EXCEPTION WHEN unique_violation THEN
--     RAISE EXCEPTION 'Este vigilante ja esta na escolta.';
--   END;
--   PERFORM public._auditar_mural('incluiu_vigilante', p_escolta_id, '{}'::jsonb,
--     jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = p_vigilante_id)));
--   RETURN jsonb_build_object('ok', true);
-- END;
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public.confirmar_presenca_base(p_escolta_id uuid, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_precisao numeric DEFAULT NULL::numeric)
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; e record; v_inicio timestamptz; v_ped uuid;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   v_usuario := public.get_meu_usuario_id();
--   v_vigilante := public.get_meu_vigilante_id();
--   IF v_vigilante IS NULL THEN RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante ativo.'; END IF;
--   SELECT id, status, data_hora_prevista, codigo_escolta INTO e FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF e.id IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
--   IF e.status <> 'agendada' THEN RAISE EXCEPTION 'A presenca na base so e confirmada antes do inicio da escolta.'; END IF;
--   IF NOT EXISTS (SELECT 1 FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante) THEN
--     RAISE EXCEPTION 'Voce nao esta na equipe desta escolta.';
--   END IF;
--   v_inicio := e.data_hora_prevista - make_interval(mins => (SELECT janela_substituicao_min FROM public.configuracoes_mural WHERE id = 1));
--   IF now() < v_inicio THEN
--     RAISE EXCEPTION 'A confirmacao de presenca abre as % (horario de Brasilia).', public._hora_br(v_inicio);
--   END IF;
--   INSERT INTO public.mural_presencas (escolta_id, vigilante_id, usuario_id, latitude, longitude, precisao_metros, sem_gps)
--   VALUES (p_escolta_id, v_vigilante, v_usuario, p_lat, p_lng, p_precisao, p_lat IS NULL OR p_lng IS NULL)
--   ON CONFLICT (escolta_id, vigilante_id) DO NOTHING;
--   PERFORM public._auditar_mural('presenca_na_base', p_escolta_id, '{}'::jsonb,
--     jsonb_build_object('vigilante', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante),
--                        'latitude', p_lat, 'longitude', p_lng, 'precisao_metros', p_precisao));
--   -- Pedido pendente perde o objeto: a equipe chegou.
--   UPDATE public.mural_pedidos SET status = 'invalidado', decidido_em = now(),
--          observacao_decisao = 'Invalidado: a equipe confirmou presenca na base.'
--    WHERE escolta_id = p_escolta_id AND status = 'pendente'
--   RETURNING id INTO v_ped;
--   IF v_ped IS NOT NULL THEN
--     PERFORM public._avisar_app(p_escolta_id, 'decisao_substituicao',
--       ARRAY[(SELECT solicitante_usuario_id FROM public.mural_pedidos WHERE id = v_ped)],
--       'Pedido de substituição invalidado', 'A equipe da escolta ' || e.codigo_escolta || ' confirmou presença na base.', v_ped);
--   END IF;
--   RETURN jsonb_build_object('ok', true, 'confirmado_em', now());
-- END;
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public.listar_pedidos_mural(p_desde timestamp with time zone DEFAULT (now() - '30 days'::interval))
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE v_perfil text; v_usuario uuid; v jsonb;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   v_usuario := public.get_meu_usuario_id();
--   PERFORM public.processar_pedidos_vencidos();
--   SELECT coalesce(jsonb_agg(jsonb_build_object(
--            'id', p.id, 'escolta_id', p.escolta_id, 'codigo', e.codigo_escolta, 'cliente', c.nome_cliente,
--            'data_hora_prevista', e.data_hora_prevista, 'solicitante', sv.nome_completo, 'solicitante_usuario_id', p.solicitante_usuario_id,
--            'equipe_antes', public._nomes_da_equipe(p.equipe_antes), 'motivo', p.motivo, 'status', p.status,
--            'criado_em', p.criado_em, 'expira_em', p.expira_em, 'antecedencia_min', p.antecedencia_min,
--            'decidido_por', du.nome_completo, 'decidido_em', p.decidido_em, 'observacao_decisao', p.observacao_decisao)
--          ORDER BY p.criado_em DESC), '[]'::jsonb) INTO v
--   FROM public.mural_pedidos p
--   JOIN public.escoltas e ON e.id = p.escolta_id
--   JOIN public.clientes c ON c.id = e.cliente_id
--   JOIN public.vigilantes sv ON sv.id = p.solicitante_vigilante_id
--   LEFT JOIN public.usuarios du ON du.id = p.decidido_por
--   WHERE p.criado_em >= p_desde
--     AND (v_perfil IN ('administrador', 'gestor', 'supervisor') OR p.solicitante_usuario_id = v_usuario);
--   RETURN v;
-- END;
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public.mural_info(p_escolta_ids uuid[])
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE v_perfil text; v_usuario uuid; v_vigilante uuid; v jsonb;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   v_usuario := public.get_meu_usuario_id();
--   v_vigilante := public.get_meu_vigilante_id();
--   PERFORM public.processar_pedidos_vencidos();
--   SELECT coalesce(jsonb_object_agg(e.id, jsonb_build_object(
--            'janela_inicio', e.data_hora_prevista - make_interval(mins => cfg.janela_substituicao_min),
--            'escala_fixa', e.escala_fixa,
--            -- O operador não lê o efetivo dos colegas pela RLS; sem isto a tela via toda
--            -- escolta agendada como "sem equipe".
--            'tem_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id),
--            -- Nomes só para a gestão e para a própria equipe (a RLS de mural_presencas é assim).
--            'presenca', CASE WHEN public._presenca_da_equipe(e.id) IS NULL THEN NULL
--                             WHEN v_perfil IN ('administrador', 'gestor', 'supervisor', 'central')
--                               OR EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante)
--                             THEN public._presenca_da_equipe(e.id) ELSE 'sim' END,
--            'eu_confirmei', EXISTS (SELECT 1 FROM public.mural_presencas mp WHERE mp.escolta_id = e.id AND mp.vigilante_id = v_vigilante),
--            'sou_da_equipe', EXISTS (SELECT 1 FROM public.escolta_efetivo ee WHERE ee.escolta_id = e.id AND ee.vigilante_id = v_vigilante),
--            'pedido', (SELECT jsonb_build_object('id', p.id, 'expira_em', p.expira_em, 'meu', p.solicitante_usuario_id = v_usuario)
--                       FROM public.mural_pedidos p WHERE p.escolta_id = e.id AND p.status = 'pendente'))), '{}'::jsonb)
--     INTO v
--   FROM public.escoltas e CROSS JOIN public.configuracoes_mural cfg
--   WHERE e.id = ANY (p_escolta_ids) AND cfg.id = 1 AND e.status = 'agendada';
--   RETURN v;
-- END;
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public.enviar_avisos_telegram()
--  RETURNS integer
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE
--   r record; v_token text; v_central text; v_base text; v_chat text; v_req bigint; n int := 0;
-- BEGIN
--   IF NOT public.avisos_pelo_banco_ativos() THEN RETURN 0; END IF;
--   EXECUTE $q$SELECT max(decrypted_secret) FILTER (WHERE name = 'telegram_bot_token'),
--                     max(decrypted_secret) FILTER (WHERE name = 'telegram_chat_central')
--              FROM vault.decrypted_secrets$q$ INTO v_token, v_central;
--   SELECT telegram_api_base INTO v_base FROM public.configuracao_avisos WHERE id = 1;
--   FOR r IN
--     SELECT a.id, a.destino, a.texto, c.telegram_chat_id AS chat_cliente
--     FROM public.avisos_telegram a
--     LEFT JOIN public.escoltas e ON e.id = a.escolta_id
--     LEFT JOIN public.clientes c ON c.id = e.cliente_id
--     WHERE a.situacao = 'pendente'
--     ORDER BY a.criado_em
--     LIMIT 20
--     FOR UPDATE OF a SKIP LOCKED
--   LOOP
--     v_chat := CASE WHEN r.destino = 'cliente' THEN coalesce(nullif(r.chat_cliente, ''), v_central) ELSE v_central END;
--     UPDATE public.avisos_telegram SET situacao = 'enviando', enviado_em = now() WHERE id = r.id;
--     EXECUTE $q$SELECT net.http_post(url := $1, body := $2, headers := '{"Content-Type": "application/json"}'::jsonb)$q$
--       INTO v_req
--       USING v_base || '/bot' || v_token || '/sendMessage',
--             jsonb_build_object('chat_id', v_chat, 'text', r.texto, 'parse_mode', 'HTML', 'disable_web_page_preview', true);
--     UPDATE public.avisos_telegram SET pg_net_id = v_req WHERE id = r.id;
--     n := n + 1;
--   END LOOP;
--   RETURN n;
-- END;
-- $function$;
--
-- CREATE OR REPLACE FUNCTION public.registrar_etapa_escolta(p_escolta_id uuid, p_pontos jsonb DEFAULT '[]'::jsonb, p_status_atual text DEFAULT NULL::text, p_status_novo text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text, p_latitude numeric DEFAULT NULL::numeric, p_longitude numeric DEFAULT NULL::numeric, p_observacao_fechamento text DEFAULT NULL::text, p_data_hora_prevista timestamp with time zone DEFAULT NULL::timestamp with time zone, p_tipo_ponto_todas uuid DEFAULT NULL::uuid)
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE v_n int; v_faltando text[]; v_status text;
-- BEGIN
--   -- 0. Trava a escolta e confere a etapa ANTES de gravar qualquer coisa. Serializa duas
--   --    viaturas do comboio registrando ao mesmo tempo (a segunda vê o ponto da primeira)
--   --    e impede ponto de uma etapa que já passou.
--   SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF v_status IS NULL THEN RAISE EXCEPTION 'Escolta não encontrada.'; END IF;
--   IF p_status_atual IS NOT NULL AND v_status IS DISTINCT FROM p_status_atual THEN
--     RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
--   END IF;
--
--   -- 1. Pontos de controle (todas as viaturas num statement só). Onda I: o autor é sempre
--   --    quem está na sessão (em nome de quem fez); sem sessão (SQL), vale o informado.
--   IF jsonb_array_length(coalesce(p_pontos, '[]'::jsonb)) > 0 THEN
--     IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid)
--                WHERE NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
--                                  WHERE ev.id = x.escolta_veiculo_id AND ev.escolta_id = p_escolta_id)) THEN
--       RAISE EXCEPTION 'Ponto de controle de viatura que não pertence a esta escolta.';
--     END IF;
--     INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude,
--                                         precisao_metros, sem_sinal_gps, foto_id, lancado_por, observacoes,
--                                         sincronizado, criado_offline)
--     SELECT x.escolta_veiculo_id, x.tipo_ponto_id, coalesce(x.data_hora, now()), x.latitude, x.longitude,
--            x.precisao_metros, coalesce(x.sem_sinal_gps, false), x.foto_id,
--            coalesce(public.get_meu_usuario_id(), x.lancado_por), x.observacoes,
--            coalesce(x.sincronizado, true), coalesce(x.criado_offline, false)
--     FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid, tipo_ponto_id uuid, data_hora timestamptz,
--                                            latitude numeric, longitude numeric, precisao_metros numeric,
--                                            sem_sinal_gps boolean, foto_id uuid, lancado_por uuid, observacoes text,
--                                            sincronizado boolean, criado_offline boolean);
--   END IF;
--
--   IF p_status_novo IS NULL THEN
--     RETURN jsonb_build_object('ok', true, 'avancou', false);
--   END IF;
--
--   -- 2. Comboio: a etapa só avança quando todas as viaturas registraram o ponto dela.
--   --    Onda I: ponto anulado (etapa desfeita pela gestão) não conta.
--   IF p_tipo_ponto_todas IS NOT NULL THEN
--     SELECT array_agg(coalesce(ve.placa, 'sem placa') ORDER BY ev.criado_em) INTO v_faltando
--     FROM public.escolta_veiculos ev
--     LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
--     WHERE ev.escolta_id = p_escolta_id
--       AND NOT EXISTS (SELECT 1 FROM public.pontos_controle pc
--                       WHERE pc.escolta_veiculo_id = ev.id AND pc.tipo_ponto_id = p_tipo_ponto_todas
--                         AND pc.anulado_em IS NULL);
--     IF v_faltando IS NOT NULL THEN
--       RETURN jsonb_build_object('ok', true, 'avancou', false, 'faltando', to_jsonb(v_faltando));
--     END IF;
--   END IF;
--
--   -- 3. Status, com a guarda do status atual (a trigger valida a transição).
--   UPDATE public.escoltas SET
--          status = p_status_novo,
--          observacao_fechamento = CASE
--            WHEN p_status_novo IN ('finalizada', 'cancelada') THEN p_observacao_fechamento
--            WHEN p_data_hora_prevista IS NOT NULL THEN NULL
--            ELSE observacao_fechamento END,
--          data_finalizacao = CASE WHEN p_status_novo = 'finalizada' THEN now() ELSE data_finalizacao END,
--          data_hora_prevista = coalesce(p_data_hora_prevista, data_hora_prevista)
--    WHERE id = p_escolta_id AND status = p_status_atual;
--   GET DIAGNOSTICS v_n = ROW_COUNT;
--   IF v_n = 0 THEN
--     RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
--   END IF;
--
--   -- 4. Histórico, com autor, na mesma transação. Onda I: via_rpc = true (escolta.historico_rpc).
--   PERFORM set_config('escolta.historico_rpc', 'on', true);
--   INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora,
--                                                latitude, longitude, observacao)
--   VALUES (p_escolta_id, p_status_atual, p_status_novo, public.get_meu_usuario_id(), now(),
--           p_latitude, p_longitude, p_observacao);
--   PERFORM set_config('escolta.historico_rpc', 'off', true);
--
--   RETURN jsonb_build_object('ok', true, 'avancou', true);
-- END;
-- $function$;
--
-- -- Privilégios das recriadas (CREATE OR REPLACE mantém os anteriores; repetidos por clareza).
-- DO $$
-- DECLARE f text;
-- BEGIN
--   FOREACH f IN ARRAY ARRAY['_conflito_comandante(uuid, uuid)', '_presenca_da_equipe(uuid)', '_executar_substituicao(uuid, text)',
--                            'enviar_avisos_telegram()'] LOOP
--     EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
--   END LOOP;
--   FOREACH f IN ARRAY ARRAY['assumir_escolta(uuid, uuid[], uuid, text)', 'puxar_escolta(uuid)', 'devolver_escolta(uuid)',
--                            'incluir_vigilante_na_minha_escolta(uuid, uuid)', 'confirmar_presenca_base(uuid, numeric, numeric, numeric)',
--                            'listar_pedidos_mural(timestamptz)', 'mural_info(uuid[])',
--                            'registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid)'] LOOP
--     EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
--     EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
--   END LOOP;
-- END $$;

-- ──────── reverter 217_mural_central ────────
-- -- 217_mural_central_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda J e o deploy; depois este arquivo; a 211
-- -- só depois dele. Recria os corpos da 204 (_avisar_app grava direto em notificacoes, só
-- -- com o payload; marcar_aviso_lido faz SET lida = true) e desliga o Telegram do check-in
-- -- pelo cron (configuracao_avisos.checkin_telegram_pelo_cron = false).
-- -- Aviso no aplicativo (tabela notificacoes, canal app).
-- CREATE OR REPLACE FUNCTION public._avisar_app(p_escolta_id uuid, p_tipo text, p_usuarios uuid[], p_titulo text, p_texto text, p_pedido_id uuid)
--     RETURNS void
--     LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
-- BEGIN
--   IF NOT coalesce((SELECT aviso_ligado FROM public.configuracoes_mural WHERE id = 1), true) THEN RETURN; END IF;
--   INSERT INTO public.notificacoes (escolta_id, canal, tipo_evento_id, destino, payload, usuario_dest_id, status_envio)
--   SELECT p_escolta_id, 'app', (SELECT id FROM public.dom_tipos_evento WHERE codigo = p_tipo), 'app',
--          jsonb_build_object('titulo', p_titulo, 'texto', p_texto, 'pedido_id', p_pedido_id), u, 'enviada'
--   FROM unnest(p_usuarios) AS u
--   WHERE u IS NOT NULL;
-- END;
-- $$;
-- REVOKE ALL ON FUNCTION public._avisar_app(uuid, text, uuid[], text, text, uuid) FROM PUBLIC, anon, authenticated;
--
-- CREATE OR REPLACE FUNCTION public.marcar_aviso_lido(p_notificacao_id uuid) RETURNS boolean
--     LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
-- BEGIN
--   IF public.get_meu_perfil() IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   UPDATE public.notificacoes SET lida = true WHERE id = p_notificacao_id AND usuario_dest_id = public.get_meu_usuario_id();
--   RETURN FOUND;
-- END;
-- $$;
-- REVOKE ALL ON FUNCTION public.marcar_aviso_lido(uuid) FROM PUBLIC, anon;
-- GRANT EXECUTE ON FUNCTION public.marcar_aviso_lido(uuid) TO authenticated;
--
-- -- O Telegram do check-in volta a ser do navegador (reservar_alertas_checkin) até a 217 voltar.
-- DO $$
-- BEGIN
--   IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
--               AND table_name = 'configuracao_avisos' AND column_name = 'checkin_telegram_pelo_cron') THEN
--     UPDATE public.configuracao_avisos SET checkin_telegram_pelo_cron = false WHERE id = 1;
--   END IF;
-- END $$;

-- ──────── reverter 200_fechar_bucket_fotos ────────
-- -- 200_fechar_bucket_fotos_reverter.sql
-- -- Reabre o bucket e recria as policies guardadas pela 200.
-- UPDATE storage.buckets SET public = true WHERE id = 'fotos';
-- DO $$
-- DECLARE r record;
-- BEGIN
--   IF to_regclass('backup_20261008.policies_storage') IS NULL THEN RETURN; END IF;
--   FOR r IN SELECT policyname, definicao FROM backup_20261008.policies_storage LOOP
--     IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = r.policyname) THEN
--       EXECUTE r.definicao;
--     END IF;
--   END LOOP;
-- END $$;
-- DROP TABLE IF EXISTS backup_20261008.policies_storage;
-- DROP FUNCTION IF EXISTS backup_20261008.alcanca_fotos(text);
-- -- O schema backup_20261008 fica: outras migrations do lote também guardam backup nele.

-- ──────── reverter 210_efetivo_unico ────────
-- -- 210_efetivo_unico_reverter.sql
-- -- Tira as duas travas de unicidade da 210 (o índice do efetivo e a restrição das viaturas).
-- -- Nenhum dado muda. Depois da 218_reverter (a editar_escolta usa a restrição das viaturas).
-- DROP INDEX IF EXISTS public.escolta_efetivo_escolta_vigilante_uk;
-- ALTER TABLE public.escolta_veiculos DROP CONSTRAINT IF EXISTS escolta_veiculos_escolta_veiculo_uk;
-- DROP INDEX IF EXISTS public.escolta_veiculos_escolta_veiculo_uk;

-- ──────── reverter 204_mural_travas_rpcs ────────
-- -- 204_mural_travas_rpcs_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda C e o deploy; depois este arquivo; a 203
-- -- só depois deste. Devolve as RPCs do mural ao corpo de produção de 08/10/2026 (migration
-- -- 195) e remove as funções novas e o agendamento.
-- DO $$
-- BEGIN
--   IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
--     PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lote2026_pedidos_vencidos';
--   END IF;
-- END $$;
-- -- Pedidos pendentes não ficam sem desfecho.
-- DO $$
-- BEGIN
--   IF to_regclass('public.mural_pedidos') IS NOT NULL THEN
--     UPDATE public.mural_pedidos SET status = 'cancelado', decidido_em = now(),
--            observacao_decisao = 'Cancelado: as travas do mural foram revertidas.'
--      WHERE status = 'pendente';
--   END IF;
-- END $$;
--
-- CREATE OR REPLACE FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[] DEFAULT '{}'::uuid[], p_veiculo_id uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text) RETURNS jsonb
--     LANGUAGE plpgsql SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
-- DECLARE
--   v_perfil       text;
--   v_usuario      uuid;
--   v_vigilante    uuid;
--   v_status       text;
--   v_ev           uuid;
--   v_equipe_antes jsonb;
--   v_veic_antes   jsonb;
--   v_acomp        uuid;
--   v_qtd_antes    int;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN
--     RAISE EXCEPTION 'Sessao invalida.';
--   END IF;
--
--   SELECT id INTO v_usuario   FROM public.usuarios   WHERE auth_user_id = auth.uid();
--   SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;
--   IF v_vigilante IS NULL THEN
--     RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante. Fale com o administrador.';
--   END IF;
--
--   -- Trava a linha: duas pessoas assumindo ao mesmo tempo produziriam duas equipes.
--   SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF v_status IS NULL THEN
--     RAISE EXCEPTION 'Escolta nao encontrada.';
--   END IF;
--   IF v_status <> 'agendada' THEN
--     RAISE EXCEPTION 'Esta escolta ja comecou e nao pode ter a equipe trocada. Fale com o supervisor.';
--   END IF;
--
--   SELECT count(*) INTO v_qtd_antes FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
--
--   -- Substituir equipe de colega exige justificativa escrita. Assumir escolta vazia, nao.
--   IF v_qtd_antes > 0 AND (p_motivo IS NULL OR length(trim(p_motivo)) < 5) THEN
--     RAISE EXCEPTION 'Informe o motivo da substituicao da equipe.';
--   END IF;
--
--   -- Fotografa o estado anterior ANTES de apagar. Este e o registro que permite
--   -- reconstruir depois quem estava escalado, quem assumiu e por que.
--   SELECT coalesce(jsonb_agg(jsonb_build_object(
--            'vigilante', v.nome_completo,
--            'papel', ee.papel_na_escolta
--          ) ORDER BY ee.papel_na_escolta), '[]'::jsonb)
--     INTO v_equipe_antes
--   FROM public.escolta_efetivo ee
--   JOIN public.vigilantes v ON v.id = ee.vigilante_id
--   WHERE ee.escolta_id = p_escolta_id;
--
--   SELECT coalesce(jsonb_agg(jsonb_build_object('placa', ve.placa, 'modelo', ve.modelo)), '[]'::jsonb)
--     INTO v_veic_antes
--   FROM public.escolta_veiculos ev
--   JOIN public.veiculos ve ON ve.id = ev.veiculo_id
--   WHERE ev.escolta_id = p_escolta_id;
--
--   SELECT id INTO v_ev FROM public.escolta_veiculos
--   WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
--   IF v_ev IS NULL THEN
--     RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.';
--   END IF;
--
--   -- Troca de viatura, quando pedida. A escolta ainda nao comecou, entao nao ha ponto de
--   -- controle apontando para o vinculo antigo.
--   IF p_veiculo_id IS NOT NULL THEN
--     UPDATE public.escolta_veiculos
--        SET veiculo_id = p_veiculo_id, atualizado_em = now(), atualizado_por = v_usuario
--      WHERE id = v_ev;
--   END IF;
--
--   DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
--
--   INSERT INTO public.escolta_efetivo
--     (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--   VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
--
--   FOREACH v_acomp IN ARRAY coalesce(p_acompanhantes, '{}')
--   LOOP
--     IF v_acomp IS DISTINCT FROM v_vigilante THEN
--       INSERT INTO public.escolta_efetivo
--         (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--       VALUES (p_escolta_id, v_ev, v_acomp, 'operador', false, v_usuario)
--       ON CONFLICT DO NOTHING;
--     END IF;
--   END LOOP;
--
--   INSERT INTO public.logs_auditoria
--     (usuario_id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora)
--   VALUES (
--     v_usuario,
--     CASE WHEN v_qtd_antes > 0 THEN 'substituicao_de_equipe' ELSE 'assumiu_escolta_do_mural' END,
--     'escoltas',
--     p_escolta_id,
--     jsonb_build_object('equipe', v_equipe_antes, 'viaturas', v_veic_antes),
--     jsonb_build_object(
--       'assumida_por', (SELECT nome_completo FROM public.vigilantes WHERE id = v_vigilante),
--       'acompanhantes', (
--         SELECT coalesce(jsonb_agg(nome_completo), '[]'::jsonb)
--         FROM public.vigilantes WHERE id = ANY(coalesce(p_acompanhantes, '{}'))
--       ),
--       'motivo', nullif(trim(coalesce(p_motivo, '')), ''),
--       'trocou_viatura', p_veiculo_id IS NOT NULL
--     ),
--     now()
--   );
--
--   RETURN jsonb_build_object(
--     'ok', true,
--     'substituiu_equipe', v_qtd_antes > 0,
--     'equipe_anterior', v_equipe_antes
--   );
-- END;
-- $$;
--
-- CREATE OR REPLACE FUNCTION public.puxar_escolta(p_escolta_id uuid) RETURNS jsonb
--     LANGUAGE plpgsql SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
-- DECLARE
--   v_perfil    text;
--   v_usuario   uuid;
--   v_vigilante uuid;
--   v_status    text;
--   v_ev        uuid;
--   v_ja        int;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN
--     RAISE EXCEPTION 'Sessao invalida.';
--   END IF;
--
--   SELECT id INTO v_usuario FROM public.usuarios WHERE auth_user_id = auth.uid();
--   SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;
--   IF v_vigilante IS NULL THEN
--     RAISE EXCEPTION 'Sua conta nao esta vinculada a um vigilante. Fale com o administrador.';
--   END IF;
--
--   -- Trava a linha: sem isto, dois operadores puxam a mesma escolta no mesmo instante e
--   -- os dois viram comandante.
--   SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF v_status IS NULL THEN
--     RAISE EXCEPTION 'Escolta nao encontrada.';
--   END IF;
--   IF v_status <> 'agendada' THEN
--     RAISE EXCEPTION 'Esta escolta nao esta mais disponivel: ela ja saiu do mural.';
--   END IF;
--
--   SELECT count(*) INTO v_ja FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
--   IF v_ja > 0 THEN
--     RAISE EXCEPTION 'Esta escolta ja tem equipe designada.';
--   END IF;
--
--   SELECT id INTO v_ev FROM public.escolta_veiculos
--   WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
--   IF v_ev IS NULL THEN
--     RAISE EXCEPTION 'Escolta sem viatura vinculada. Fale com o supervisor.';
--   END IF;
--
--   INSERT INTO public.escolta_efetivo
--     (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--   VALUES (p_escolta_id, v_ev, v_vigilante, 'comandante', true, v_usuario);
--
--   RETURN jsonb_build_object('ok', true, 'escolta_veiculo_id', v_ev);
-- END;
-- $$;
--
-- CREATE OR REPLACE FUNCTION public.devolver_escolta(p_escolta_id uuid) RETURNS jsonb
--     LANGUAGE plpgsql SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
-- DECLARE
--   v_perfil    text;
--   v_usuario   uuid;
--   v_vigilante uuid;
--   v_status    text;
--   v_sou_cmd   int;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   SELECT id INTO v_usuario FROM public.usuarios WHERE auth_user_id = auth.uid();
--   SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;
--
--   SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF v_status IS NULL THEN
--     RAISE EXCEPTION 'Escolta nao encontrada.';
--   END IF;
--
--   -- So devolve enquanto nao comecou. Depois de iniciada, sair da escolta e decisao de
--   -- supervisor, nao do proprio operador: ja existe registro de ponto no nome dele.
--   IF v_status <> 'agendada' THEN
--     RAISE EXCEPTION 'A escolta ja comecou. Fale com o supervisor para sair dela.';
--   END IF;
--
--   IF v_perfil IS NULL OR v_perfil NOT IN ('administrador','gestor','supervisor','central') THEN
--     SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
--     WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante
--       AND papel_na_escolta = 'comandante';
--     IF v_sou_cmd = 0 THEN
--       RAISE EXCEPTION 'Apenas o comandante devolve a escolta ao mural.';
--     END IF;
--   END IF;
--
--   DELETE FROM public.escolta_efetivo WHERE escolta_id = p_escolta_id;
--   RETURN jsonb_build_object('ok', true);
-- END;
-- $$;
--
-- CREATE OR REPLACE FUNCTION public.incluir_vigilante_na_minha_escolta(p_escolta_id uuid, p_vigilante_id uuid) RETURNS jsonb
--     LANGUAGE plpgsql SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
-- DECLARE
--   v_perfil    text;
--   v_usuario   uuid;
--   v_vigilante uuid;
--   v_status    text;
--   v_sou_cmd   int;
--   v_ev        uuid;
--   v_dup       int;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   SELECT id INTO v_usuario FROM public.usuarios WHERE auth_user_id = auth.uid();
--   SELECT id INTO v_vigilante FROM public.vigilantes WHERE usuario_id = v_usuario;
--
--   SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF v_status IS NULL THEN
--     RAISE EXCEPTION 'Escolta nao encontrada.';
--   END IF;
--   IF v_status <> 'agendada' THEN
--     RAISE EXCEPTION 'A escolta ja comecou. Alteracao de equipe passa pelo supervisor.';
--   END IF;
--
--   IF v_perfil IS NULL OR v_perfil NOT IN ('administrador','gestor','supervisor','central') THEN
--     SELECT count(*) INTO v_sou_cmd FROM public.escolta_efetivo
--     WHERE escolta_id = p_escolta_id AND vigilante_id = v_vigilante
--       AND papel_na_escolta = 'comandante';
--     IF v_sou_cmd = 0 THEN
--       RAISE EXCEPTION 'Apenas o comandante inclui vigilante nesta escolta.';
--     END IF;
--   END IF;
--
--   SELECT count(*) INTO v_dup FROM public.escolta_efetivo
--   WHERE escolta_id = p_escolta_id AND vigilante_id = p_vigilante_id;
--   IF v_dup > 0 THEN
--     RAISE EXCEPTION 'Este vigilante ja esta na escolta.';
--   END IF;
--
--   SELECT id INTO v_ev FROM public.escolta_veiculos
--   WHERE escolta_id = p_escolta_id ORDER BY criado_em LIMIT 1;
--   IF v_ev IS NULL THEN
--     RAISE EXCEPTION 'Escolta sem viatura vinculada.';
--   END IF;
--
--   INSERT INTO public.escolta_efetivo
--     (escolta_id, escolta_veiculo_id, vigilante_id, papel_na_escolta, confirmado, criado_por)
--   VALUES (p_escolta_id, v_ev, p_vigilante_id, 'operador', false, v_usuario);
--
--   RETURN jsonb_build_object('ok', true);
-- END;
-- $$;
--
-- COMMENT ON FUNCTION public.assumir_escolta(p_escolta_id uuid, p_acompanhantes uuid[], p_veiculo_id uuid, p_motivo text) IS 'Operador assume escolta agendada, inclusive quando ja ha equipe escalada. Grava a equipe e a viatura anteriores em logs_auditoria antes de substituir, e exige motivo quando ha equipe a substituir. So funciona enquanto a escolta nao comecou.';
--
-- DROP FUNCTION IF EXISTS public.avisos_telegram_resumo();
-- DROP FUNCTION IF EXISTS public.mural_travas_ativas();
-- DROP FUNCTION IF EXISTS public.meus_avisos_mural();
-- DROP FUNCTION IF EXISTS public.marcar_aviso_lido(uuid);
-- DROP FUNCTION IF EXISTS public.mural_info(uuid[]);
-- DROP FUNCTION IF EXISTS public.consultar_pedido_mural(uuid);
-- DROP FUNCTION IF EXISTS public.listar_pedidos_mural(timestamptz);
-- DROP FUNCTION IF EXISTS public.cancelar_meu_pedido_mural(uuid);
-- DROP FUNCTION IF EXISTS public.recusar_pedido_mural(uuid, text);
-- DROP FUNCTION IF EXISTS public.aprovar_pedido_mural(uuid, text);
-- DROP FUNCTION IF EXISTS public.confirmar_presenca_base(uuid, numeric, numeric, numeric);
-- DROP FUNCTION IF EXISTS public.processar_pedidos_vencidos();
-- DROP FUNCTION IF EXISTS public._executar_substituicao(uuid, text);
-- DROP FUNCTION IF EXISTS public._texto_aviso_mural(text, uuid, text[]);
-- DROP FUNCTION IF EXISTS public._auditar_mural(text, uuid, jsonb, jsonb);
-- DROP FUNCTION IF EXISTS public._avisar_app(uuid, text, uuid[], text, text, uuid);
-- DROP FUNCTION IF EXISTS public._usuarios_dos_vigilantes(uuid[]);
-- DROP FUNCTION IF EXISTS public._supervisao_ids();
-- DROP FUNCTION IF EXISTS public._presenca_da_equipe(uuid);
-- DROP FUNCTION IF EXISTS public._conflito_comandante(uuid, uuid);
-- DROP FUNCTION IF EXISTS public._nomes_da_equipe(jsonb);
-- DROP FUNCTION IF EXISTS public._ids_da_equipe(jsonb);
-- DROP FUNCTION IF EXISTS public._equipe_atual(uuid);
-- DROP FUNCTION IF EXISTS public._hora_br(timestamptz);
-- DROP FUNCTION IF EXISTS public._travar_vigilante(uuid);

-- ──────── reverter 215_locais_uso ────────
-- -- 215_locais_uso_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda D2 e o deploy; depois este arquivo (antes
-- -- da 214_reverter e da 205_reverter). Guarda vezes_usado e uf em backup_20261008.locais_uso
-- -- (uma linha por local; rodar de novo não apaga o que já foi guardado), tira as triggers de
-- -- uso, as funções internas, o registro de falhas, o resumo das falhas e as colunas, devolve o corpo da 205 de locais_salvos_regras e
-- -- os privilégios de tabela da 205 (INSERT e UPDATE sem lista de colunas).
-- CREATE SCHEMA IF NOT EXISTS backup_20261008;
-- REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
-- DO $$
-- BEGIN
--   IF EXISTS (SELECT 1 FROM information_schema.columns
--               WHERE table_schema = 'public' AND table_name = 'locais_salvos' AND column_name = 'vezes_usado') THEN
--     CREATE TABLE IF NOT EXISTS backup_20261008.locais_uso (local_id uuid PRIMARY KEY, nome text, vezes_usado integer, uf text, guardado_em timestamptz NOT NULL DEFAULT now());
--     REVOKE ALL ON backup_20261008.locais_uso FROM PUBLIC, anon, authenticated;
--     INSERT INTO backup_20261008.locais_uso (local_id, nome, vezes_usado, uf)
--     SELECT id, nome, vezes_usado, uf FROM public.locais_salvos
--     ON CONFLICT (local_id) DO UPDATE SET nome = EXCLUDED.nome, vezes_usado = EXCLUDED.vezes_usado, uf = EXCLUDED.uf, guardado_em = now();
--   END IF;
-- END $$;
--
-- DROP TRIGGER IF EXISTS tr_contar_uso_local ON public.escoltas;
-- DROP TRIGGER IF EXISTS tr_recontar_uso_locais ON public.locais_salvos;
-- DROP FUNCTION IF EXISTS lote_interno.contar_uso_local();
-- DROP FUNCTION IF EXISTS lote_interno.recontar_uso_locais();
-- DROP FUNCTION IF EXISTS lote_interno.carregar_uso_locais();
-- DROP FUNCTION IF EXISTS lote_interno.contar_escoltas_do_local(uuid);
-- DROP FUNCTION IF EXISTS lote_interno.local_do_endereco(text, numeric, numeric);
-- DROP FUNCTION IF EXISTS public.locais_uso_falhas_resumo();
-- -- O registro de falhas da contagem é diagnóstico: some com a contagem.
-- DROP TABLE IF EXISTS lote_interno.locais_uso_falhas;
--
-- -- Privilégios da 205 (o REVOKE de tabela também tira os de coluna).
-- REVOKE INSERT, UPDATE ON public.locais_salvos FROM authenticated;
-- GRANT INSERT, UPDATE ON public.locais_salvos TO authenticated;
--
-- ALTER TABLE public.locais_salvos DROP CONSTRAINT IF EXISTS locais_salvos_uf_formato;
-- ALTER TABLE public.locais_salvos DROP CONSTRAINT IF EXISTS locais_salvos_vezes_usado_positivo;
-- ALTER TABLE public.locais_salvos DROP COLUMN IF EXISTS vezes_usado;
-- ALTER TABLE public.locais_salvos DROP COLUMN IF EXISTS uf;
--
-- -- Corpo da 205.
-- CREATE OR REPLACE FUNCTION public.locais_salvos_regras() RETURNS trigger
--     LANGUAGE plpgsql SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
-- DECLARE v_perfil text; v_eu uuid;
-- BEGIN
--   IF auth.uid() IS NULL THEN RETURN NEW; END IF;      -- SQL Editor e migrations
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   v_eu := public.get_meu_usuario_id();
--   IF TG_OP = 'INSERT' THEN
--     NEW.criado_por := v_eu; NEW.criado_em := now();
--     IF NEW.situacao = 'ativo' THEN NEW.situacao := 'aguardando_conferencia'; END IF;
--     NEW.conferido_por := NULL; NEW.conferido_em := NULL;
--   ELSE
--     NEW.criado_por := OLD.criado_por; NEW.criado_em := OLD.criado_em;
--     -- Local ativo que muda de coordenada, nome, endereço ou complemento volta para
--     -- conferência (o texto e o pino são o que a conferência atestou).
--     IF OLD.situacao = 'ativo' AND NEW.situacao = 'ativo'
--        AND (NEW.latitude IS DISTINCT FROM OLD.latitude OR NEW.longitude IS DISTINCT FROM OLD.longitude
--             OR NEW.nome IS DISTINCT FROM OLD.nome OR NEW.endereco IS DISTINCT FROM OLD.endereco
--             OR NEW.complemento IS DISTINCT FROM OLD.complemento) THEN
--       NEW.situacao := 'aguardando_conferencia';
--     END IF;
--     IF NEW.situacao = 'ativo' AND OLD.situacao IS DISTINCT FROM 'ativo' THEN
--       IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor') THEN
--         RAISE EXCEPTION 'Somente gestor ou administrador confere e ativa um local salvo.';
--       END IF;
--       NEW.conferido_por := v_eu; NEW.conferido_em := now();
--     ELSIF NEW.situacao <> 'ativo' THEN
--       NEW.conferido_por := CASE WHEN NEW.situacao = 'inativo' THEN OLD.conferido_por END;
--       NEW.conferido_em := CASE WHEN NEW.situacao = 'inativo' THEN OLD.conferido_em END;
--     ELSE
--       NEW.conferido_por := OLD.conferido_por; NEW.conferido_em := OLD.conferido_em;
--     END IF;
--   END IF;
--   NEW.atualizado_por := v_eu; NEW.atualizado_em := now();
--   RETURN NEW;
-- END;
-- $$;
-- REVOKE ALL ON FUNCTION public.locais_salvos_regras() FROM PUBLIC, anon, authenticated;

-- ──────── reverter 214_poder_total_travas ────────
-- -- 214_poder_total_travas_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda I e o deploy; depois 218_reverter (bloco 2);
-- -- então este arquivo; a 213 só depois dele. Aborta se a 218 ainda estiver aplicada.
-- -- Recria os corpos anteriores (207, 208, 212 e o da produção para as triggers de status),
-- -- tira as três triggers tr_impedir_edicao_escolta_iniciada, as onze tr_impedir_apagar_gestao_*
-- -- e as três policies novas.
-- DO $$
-- BEGIN
--   IF to_regprocedure('public.editar_escolta(uuid, jsonb, jsonb, text)') IS NOT NULL THEN
--     RAISE EXCEPTION 'Reverta a 218 antes da 214.';
--   END IF;
-- END $$;
--
-- DROP POLICY IF EXISTS escoltas_arquivada_so_admin ON public.escoltas;
-- DROP POLICY IF EXISTS pontos_insert_autor ON public.pontos_controle;
-- DROP POLICY IF EXISTS escoltas_delete_so_rascunho ON public.escoltas;
-- DROP TRIGGER IF EXISTS tr_impedir_edicao_escolta_iniciada ON public.escoltas;
-- DROP TRIGGER IF EXISTS tr_impedir_edicao_escolta_iniciada ON public.escolta_veiculos;
-- DROP TRIGGER IF EXISTS tr_impedir_edicao_escolta_iniciada ON public.escolta_efetivo;
-- DROP FUNCTION IF EXISTS lote_interno.impedir_edicao_escolta_iniciada();
-- DO $$
-- DECLARE t text;
-- BEGIN
--   FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
--                            'atualizacoes_status', 'rastreamento', 'escolta_status_historico',
--                            'escolta_conclusoes_antecipadas', 'escolta_veiculos']
--   LOOP
--     IF to_regclass('public.' || t) IS NOT NULL THEN
--       EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_impedir_apagar_gestao_' || t, t);
--     END IF;
--   END LOOP;
-- END $$;
-- DROP FUNCTION IF EXISTS lote_interno.impedir_apagar_registro();
--
-- -- Corpos anteriores (copiados do banco montado na ordem dos blocos, antes da 214).
-- CREATE OR REPLACE FUNCTION public.validar_transicao_status_escolta()
--  RETURNS trigger
--  LANGUAGE plpgsql
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE
--   v_ok boolean := false;
-- BEGIN
--   IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
--     RETURN NEW;
--   END IF;
--
--   IF NEW.status = 'cancelada' AND OLD.status NOT IN ('finalizada','cancelada') THEN
--     RETURN NEW;
--   END IF;
--
--   v_ok := (
--     (OLD.status = 'rascunho'            AND NEW.status = 'agendada') OR
--     (OLD.status = 'agendada'            AND NEW.status = 'em_pre_inicio') OR
--     (OLD.status = 'em_pre_inicio'       AND NEW.status = 'em_andamento') OR
--     (OLD.status = 'em_andamento'        AND NEW.status = 'na_origem') OR
--     (OLD.status = 'na_origem'           AND NEW.status = 'em_transito_destino') OR
--     (OLD.status = 'em_transito_destino' AND NEW.status = 'no_destino') OR
--     (OLD.status = 'no_destino'          AND NEW.status = 'em_transito_retorno') OR
--     (OLD.status = 'em_transito_retorno' AND NEW.status = 'retornando') OR
--     (OLD.status = 'retornando'          AND NEW.status = 'na_base') OR
--     (OLD.status = 'na_base'             AND NEW.status = 'finalizada')
--   );
--
--   IF NOT v_ok AND COALESCE(NEW.fluxo_versao, 1) = 1 THEN
--     v_ok := (
--       (OLD.status = 'na_origem'  AND NEW.status = 'no_destino') OR
--       (OLD.status = 'no_destino' AND NEW.status = 'retornando')
--     );
--   END IF;
--
--   IF NOT v_ok THEN
--     RAISE EXCEPTION 'Transicao de status invalida: % para %', OLD.status, NEW.status
--       USING ERRCODE = 'P0001';
--   END IF;
--
--   RETURN NEW;
-- END;
-- $function$
-- ;
--
-- CREATE OR REPLACE FUNCTION public.exigir_ponto_transito_retorno()
--  RETURNS trigger
--  LANGUAGE plpgsql
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE
--   v_tem boolean;
-- BEGIN
--   IF NEW.status = 'na_base' AND OLD.status = 'retornando'
--      AND COALESCE(NEW.fluxo_versao, 1) = 2 THEN
--     SELECT EXISTS (
--       SELECT 1
--       FROM public.pontos_controle pc
--       JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
--       JOIN public.dom_tipos_ponto tp ON tp.id = pc.tipo_ponto_id
--       WHERE ev.escolta_id = NEW.id
--         AND tp.codigo = 'transito_retorno'
--     ) INTO v_tem;
--
--     IF NOT v_tem THEN
--       RAISE EXCEPTION 'Nao e possivel concluir o retorno sem registrar o ponto de Transito para o Retorno.'
--         USING ERRCODE = 'P0001';
--     END IF;
--   END IF;
--
--   RETURN NEW;
-- END;
-- $function$
-- ;
--
-- CREATE OR REPLACE FUNCTION public.verificar_checklist_pendente()
--  RETURNS trigger
--  LANGUAGE plpgsql
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE
--   v_total_veiculos INTEGER;
--   v_veiculos_ok INTEGER;
-- BEGIN
--   IF OLD.status = 'em_pre_inicio' AND NEW.status = 'em_andamento' THEN
--     SELECT COUNT(*) INTO v_total_veiculos
--     FROM escolta_veiculos WHERE escolta_id = NEW.id;
--
--     SELECT COUNT(DISTINCT ev.id) INTO v_veiculos_ok
--     FROM escolta_veiculos ev
--     WHERE ev.escolta_id = NEW.id
--       AND EXISTS (
--         SELECT 1 FROM checklists c
--         WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'viatura' AND c.concluido = true
--       )
--       AND EXISTS (
--         SELECT 1 FROM checklists c
--         WHERE c.escolta_veiculo_id = ev.id AND c.tipo = 'material' AND c.concluido = true
--       );
--
--     IF v_veiculos_ok < v_total_veiculos THEN
--       NEW.checklist_pendente_no_inicio := true;
--     END IF;
--   END IF;
--   RETURN NEW;
-- END;
-- $function$
-- ;
--
-- CREATE OR REPLACE FUNCTION public.registrar_etapa_escolta(p_escolta_id uuid, p_pontos jsonb DEFAULT '[]'::jsonb, p_status_atual text DEFAULT NULL::text, p_status_novo text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text, p_latitude numeric DEFAULT NULL::numeric, p_longitude numeric DEFAULT NULL::numeric, p_observacao_fechamento text DEFAULT NULL::text, p_data_hora_prevista timestamp with time zone DEFAULT NULL::timestamp with time zone, p_tipo_ponto_todas uuid DEFAULT NULL::uuid)
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE v_n int; v_faltando text[]; v_status text;
-- BEGIN
--   -- 0. Trava a escolta e confere a etapa ANTES de gravar qualquer coisa. Serializa duas
--   --    viaturas do comboio registrando ao mesmo tempo (a segunda vê o ponto da primeira)
--   --    e impede ponto de uma etapa que já passou.
--   SELECT status INTO v_status FROM public.escoltas WHERE id = p_escolta_id FOR UPDATE;
--   IF v_status IS NULL THEN RAISE EXCEPTION 'Escolta nao encontrada.'; END IF;
--   IF p_status_atual IS NOT NULL AND v_status IS DISTINCT FROM p_status_atual THEN
--     RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
--   END IF;
--
--   -- 1. Pontos de controle (todas as viaturas num statement só).
--   IF jsonb_array_length(coalesce(p_pontos, '[]'::jsonb)) > 0 THEN
--     IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid)
--                WHERE NOT EXISTS (SELECT 1 FROM public.escolta_veiculos ev
--                                  WHERE ev.id = x.escolta_veiculo_id AND ev.escolta_id = p_escolta_id)) THEN
--       RAISE EXCEPTION 'Ponto de controle de viatura que nao pertence a esta escolta.';
--     END IF;
--     INSERT INTO public.pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude,
--                                         precisao_metros, sem_sinal_gps, foto_id, lancado_por, observacoes,
--                                         sincronizado, criado_offline)
--     SELECT x.escolta_veiculo_id, x.tipo_ponto_id, coalesce(x.data_hora, now()), x.latitude, x.longitude,
--            x.precisao_metros, coalesce(x.sem_sinal_gps, false), x.foto_id, x.lancado_por, x.observacoes,
--            coalesce(x.sincronizado, true), coalesce(x.criado_offline, false)
--     FROM jsonb_to_recordset(p_pontos) AS x(escolta_veiculo_id uuid, tipo_ponto_id uuid, data_hora timestamptz,
--                                            latitude numeric, longitude numeric, precisao_metros numeric,
--                                            sem_sinal_gps boolean, foto_id uuid, lancado_por uuid, observacoes text,
--                                            sincronizado boolean, criado_offline boolean);
--   END IF;
--
--   IF p_status_novo IS NULL THEN
--     RETURN jsonb_build_object('ok', true, 'avancou', false);
--   END IF;
--
--   -- 2. Comboio: a etapa só avança quando todas as viaturas registraram o ponto dela.
--   IF p_tipo_ponto_todas IS NOT NULL THEN
--     SELECT array_agg(coalesce(ve.placa, 'sem placa') ORDER BY ev.criado_em) INTO v_faltando
--     FROM public.escolta_veiculos ev
--     LEFT JOIN public.veiculos ve ON ve.id = ev.veiculo_id
--     WHERE ev.escolta_id = p_escolta_id
--       AND NOT EXISTS (SELECT 1 FROM public.pontos_controle pc
--                       WHERE pc.escolta_veiculo_id = ev.id AND pc.tipo_ponto_id = p_tipo_ponto_todas);
--     IF v_faltando IS NOT NULL THEN
--       RETURN jsonb_build_object('ok', true, 'avancou', false, 'faltando', to_jsonb(v_faltando));
--     END IF;
--   END IF;
--
--   -- 3. Status, com a guarda do status atual (a trigger valida a transição).
--   UPDATE public.escoltas SET
--          status = p_status_novo,
--          observacao_fechamento = CASE
--            WHEN p_status_novo IN ('finalizada', 'cancelada') THEN p_observacao_fechamento
--            WHEN p_data_hora_prevista IS NOT NULL THEN NULL
--            ELSE observacao_fechamento END,
--          data_finalizacao = CASE WHEN p_status_novo = 'finalizada' THEN now() ELSE data_finalizacao END,
--          data_hora_prevista = coalesce(p_data_hora_prevista, data_hora_prevista)
--    WHERE id = p_escolta_id AND status = p_status_atual;
--   GET DIAGNOSTICS v_n = ROW_COUNT;
--   IF v_n = 0 THEN
--     RAISE EXCEPTION 'ERRO_SEM_TRANSICAO';
--   END IF;
--
--   -- 4. Histórico, com autor, na mesma transação.
--   INSERT INTO public.escolta_status_historico (escolta_id, status_anterior, status_novo, alterado_por, data_hora,
--                                                latitude, longitude, observacao)
--   VALUES (p_escolta_id, p_status_atual, p_status_novo, public.get_meu_usuario_id(), now(),
--           p_latitude, p_longitude, p_observacao);
--
--   RETURN jsonb_build_object('ok', true, 'avancou', true);
-- END;
-- $function$
-- ;
--
-- CREATE OR REPLACE FUNCTION lote_interno.enfileirar_alerta_checkin(p_escolta_id uuid)
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE e record; v_ultima timestamptz; v_atraso int; v_ok boolean; v_chave text;
-- BEGIN
--   SELECT es.id, es.codigo_escolta, es.status, es.periodicidade_checkin_min, c.nome_cliente INTO e
--   FROM public.escoltas es JOIN public.clientes c ON c.id = es.cliente_id WHERE es.id = p_escolta_id;
--   IF e.id IS NULL OR e.periodicidade_checkin_min IS NULL
--      OR e.status NOT IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando') THEN
--     RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem check-in periodico');
--   END IF;
--   -- Regra antiga (pendência 0.3 de docs/12): qualquer PARADA zera o prazo; sem nenhuma, não notifica.
--   SELECT max(pc.data_hora) INTO v_ultima
--   FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
--   WHERE ev.escolta_id = p_escolta_id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760';
--   IF v_ultima IS NULL THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem parada'); END IF;
--   v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - e.periodicidade_checkin_min;
--   IF v_atraso < 1 THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'em dia'); END IF;
--   -- Uma mensagem por período vencido sem check-in (chave: escolta, última parada e
--   -- número do período).
--   v_chave := 'checkin:' || p_escolta_id || ':' || extract(epoch FROM v_ultima)::bigint
--              || ':' || floor(v_atraso::numeric / e.periodicidade_checkin_min)::int;
--   -- Já mandada por um navegador (reservar_alertas_checkin): não manda de novo.
--   IF EXISTS (SELECT 1 FROM public.avisos_reservados WHERE chave = v_chave) THEN
--     RETURN jsonb_build_object('enfileirado', false, 'motivo', 'enviado pelo navegador');
--   END IF;
--   v_ok := public._enfileirar_aviso(v_chave, 'cliente', p_escolta_id,
--     '<b>Alerta: check-in em atraso</b>' || E'\n'
--     || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(e.nome_cliente) || E'\n'
--     || 'Sem check-in há ' || (v_atraso + e.periodicidade_checkin_min) || ' minutos (periodicidade de '
--     || e.periodicidade_checkin_min || ' min).' || E'\n'
--     || 'Registrado em ' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (Brasília)');
--   RETURN jsonb_build_object('enfileirado', v_ok);
-- END;
-- $function$
-- ;
--
-- CREATE OR REPLACE FUNCTION lote_interno.gerar_avisos_checkin(p_agora timestamp with time zone DEFAULT now())
--  RETURNS integer
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE
--   r record; v_gestao uuid[]; v_n int := 0; v_decorrido numeric; v_atraso int; v_periodo int; v_telegram boolean;
-- BEGIN
--   SELECT coalesce(array_agg(u.id), '{}') INTO v_gestao
--   FROM public.usuarios u JOIN public.dom_perfis p ON p.id = u.perfil_id
--   WHERE u.status = 'ativo' AND p.codigo IN ('administrador', 'gestor', 'supervisor', 'central');
--   v_telegram := public.avisos_pelo_banco_ativos()
--                 AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false);
--
--   FOR r IN
--     SELECT e.id, e.codigo_escolta, e.periodicidade_checkin_min AS per, c.nome_cliente,
--            coalesce(
--              (SELECT max(pc.data_hora) FROM public.pontos_controle pc
--                 JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
--                WHERE ev.escolta_id = e.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760'
--                  AND lote_interno.tipo_da_observacao(pc.observacoes) = 'reporte_periodico'),
--              (SELECT min(pc.data_hora) FROM public.pontos_controle pc
--                 JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
--                WHERE ev.escolta_id = e.id),
--              e.data_hora_prevista) AS referencia
--     FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
--     WHERE e.periodicidade_checkin_min > 0
--       AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
--   LOOP
--     -- Aviso na central: erro numa escolta (usuário apagado entre a leitura e o INSERT, tipo
--     -- ausente) fica nela e vira WARNING; o ciclo segue.
--     BEGIN
--       IF r.referencia IS NOT NULL THEN
--         v_decorrido := extract(epoch FROM (p_agora - r.referencia));
--         -- Mesmo arredondamento de minutosAteCheckin: atraso = -floor((per*60 - decorrido) / 60).
--         v_atraso := -floor((r.per * 60 - v_decorrido) / 60)::int;
--         IF v_atraso >= 1 THEN
--           -- Período n: de n a n+1 periodicidades decorridas (o 1º vence com a periodicidade).
--           v_periodo := ceil(v_decorrido / (r.per * 60))::int - 1;
--           v_n := v_n + lote_interno.notificar(
--             'checkin:' || r.id || ':' || floor(extract(epoch FROM r.referencia))::bigint || ':' || v_periodo,
--             r.id, 'checkin_vencido',
--             ARRAY(SELECT v.usuario_id FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
--                    WHERE ee.escolta_id = r.id AND v.usuario_id IS NOT NULL) || v_gestao,
--             'Check-in atrasado: ' || r.codigo_escolta,
--             'Escolta ' || r.codigo_escolta || ' · ' || r.nome_cliente || ': sem check-in há ' || (v_atraso + r.per)
--               || ' min (periodicidade de ' || r.per || ' min, ' || v_atraso || ' min de atraso). Prazo vencido em '
--               || to_char((r.referencia + make_interval(mins => r.per * v_periodo)) AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
--               || ' (Brasília).',
--             jsonb_build_object('referencia', r.referencia, 'periodo', v_periodo, 'periodicidade_min', r.per));
--         END IF;
--       END IF;
--     EXCEPTION WHEN others THEN
--       RAISE WARNING 'gerar_avisos_checkin: aviso da escolta % falhou: %', r.id, SQLERRM;
--     END;
--     -- Telegram pela regra antiga (a função decide); erro numa escolta não para o ciclo.
--     IF v_telegram THEN
--       BEGIN
--         PERFORM lote_interno.enfileirar_alerta_checkin(r.id);
--       EXCEPTION WHEN others THEN
--         RAISE WARNING 'gerar_avisos_checkin: Telegram da escolta % falhou: %', r.id, SQLERRM;
--       END;
--     END IF;
--   END LOOP;
--
--   DELETE FROM public.notificacoes WHERE lida AND lida_em < p_agora - interval '90 days';
--   RETURN v_n;
-- END;
-- $function$
-- ;
--
-- CREATE OR REPLACE FUNCTION public.reservar_alertas_checkin()
--  RETURNS jsonb
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE
--   v_perfil text; v_eu uuid; v_gestao boolean; r record; v_ultima timestamptz; v_atraso int;
--   v_chave text; v_n int; v_saida jsonb := '[]'::jsonb;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessão inválida.'; END IF;
--   -- O cron manda: nada para o navegador.
--   IF public.avisos_pelo_banco_ativos()
--      AND coalesce((SELECT checkin_telegram_pelo_cron FROM public.configuracao_avisos WHERE id = 1), false) THEN
--     RETURN v_saida;
--   END IF;
--   v_eu := public.get_meu_usuario_id();
--   v_gestao := v_perfil IN ('administrador', 'gestor', 'supervisor', 'central');
--   FOR r IN
--     SELECT e.id, e.codigo_escolta, e.status, e.periodicidade_checkin_min AS per, c.nome_cliente
--     FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
--     WHERE e.periodicidade_checkin_min > 0
--       AND e.status IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando')
--       AND (v_gestao OR public.sou_do_efetivo(e.id))
--   LOOP
--     -- Regra antiga (pendência 0.3), a mesma de lote_interno.enfileirar_alerta_checkin.
--     SELECT max(pc.data_hora) INTO v_ultima
--     FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
--     WHERE ev.escolta_id = r.id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760';
--     CONTINUE WHEN v_ultima IS NULL;
--     v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - r.per;
--     CONTINUE WHEN v_atraso < 1;
--     v_chave := 'checkin:' || r.id || ':' || extract(epoch FROM v_ultima)::bigint || ':' || floor(v_atraso::numeric / r.per)::int;
--     -- Já enfileirada pelo cron (envio pelo banco ligado há pouco): não manda de novo.
--     CONTINUE WHEN EXISTS (SELECT 1 FROM public.avisos_telegram WHERE evento_chave = v_chave);
--     INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES (v_chave, v_eu) ON CONFLICT (chave) DO NOTHING;
--     GET DIAGNOSTICS v_n = ROW_COUNT;
--     CONTINUE WHEN v_n = 0;
--     v_saida := v_saida || jsonb_build_object(
--       'escolta_id', r.id, 'codigo', r.codigo_escolta, 'cliente', r.nome_cliente, 'status', r.status,
--       'atraso_min', v_atraso, 'periodicidade_min', r.per,
--       'efetivos', coalesce((SELECT jsonb_agg(v.nome_completo || coalesce(' (' || ee.papel_na_escolta || ')', '') ORDER BY ee.papel_na_escolta, v.nome_completo)
--                             FROM public.escolta_efetivo ee JOIN public.vigilantes v ON v.id = ee.vigilante_id
--                             WHERE ee.escolta_id = r.id), '[]'::jsonb));
--   END LOOP;
--   RETURN v_saida;
-- END;
-- $function$
-- ;
--
-- CREATE OR REPLACE FUNCTION public.reservar_aviso_presenca(p_presenca_id uuid)
--  RETURNS boolean
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'public', 'pg_temp'
-- AS $function$
-- DECLARE v_perfil text; v_esc uuid; v_n int;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   SELECT escolta_id INTO v_esc FROM public.presencas WHERE id = p_presenca_id;
--   IF v_esc IS NULL THEN RETURN false; END IF;
--   IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(v_esc) THEN
--     RETURN false;
--   END IF;
--   INSERT INTO public.avisos_reservados (chave, usuario_id) VALUES ('presenca:' || p_presenca_id, public.get_meu_usuario_id())
--   ON CONFLICT (chave) DO NOTHING;
--   GET DIAGNOSTICS v_n = ROW_COUNT;
--   RETURN v_n = 1;
-- END;
-- $function$
-- ;
--
-- REVOKE ALL ON FUNCTION public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid) FROM PUBLIC, anon;
-- GRANT EXECUTE ON FUNCTION public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid) TO authenticated;
-- REVOKE ALL ON FUNCTION lote_interno.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon, authenticated;
-- REVOKE ALL ON FUNCTION lote_interno.gerar_avisos_checkin(timestamptz) FROM PUBLIC, anon, authenticated;
-- REVOKE ALL ON FUNCTION public.reservar_alertas_checkin() FROM PUBLIC, anon;
-- GRANT EXECUTE ON FUNCTION public.reservar_alertas_checkin() TO authenticated;
-- REVOKE ALL ON FUNCTION public.reservar_aviso_presenca(uuid) FROM PUBLIC, anon;
-- GRANT EXECUTE ON FUNCTION public.reservar_aviso_presenca(uuid) TO authenticated;

-- ──────── reverter 213_poder_total_estrutura ────────
-- -- 213_poder_total_estrutura_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda I e o deploy; depois 218_reverter (bloco 2)
-- -- e 214_reverter; só então este arquivo. Aborta se a 214 ainda estiver aplicada.
-- -- Guarda em backup_20261008 as colunas novas que tiverem valor (arquivamento, versão, anulação,
-- -- carimbo e via_rpc) e as linhas inteiras de escolta_resets e escolta_conclusoes_antecipadas;
-- -- depois remove a estrutura da 213. Nenhum registro de campo é apagado.
-- -- Efeito enquanto a 213 estiver revertida: anulados voltam a contar como válidos e as
-- -- arquivadas reaparecem nas listas (as colunas que as marcavam saíram). A volta é pelo
-- -- 213_poder_total_estrutura_restaurar.sql, depois de reaplicar a 213, a 214 e a 218.
-- DO $$
-- BEGIN
--   IF to_regprocedure('lote_interno.impedir_edicao_escolta_iniciada()') IS NOT NULL THEN
--     RAISE EXCEPTION 'Reverta a 214 antes da 213.';
--   END IF;
-- END $$;
--
-- CREATE SCHEMA IF NOT EXISTS backup_20261008;
-- REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
-- CREATE TABLE IF NOT EXISTS backup_20261008.poder_total_colunas (
--   tabela     text NOT NULL,
--   id         uuid NOT NULL,
--   dados      jsonb NOT NULL,
--   gravado_em timestamptz NOT NULL DEFAULT now()
-- );
-- CREATE TABLE IF NOT EXISTS backup_20261008.poder_total_linhas (
--   tabela     text NOT NULL,
--   linha      jsonb NOT NULL,
--   gravado_em timestamptz NOT NULL DEFAULT now()
-- );
-- REVOKE ALL ON backup_20261008.poder_total_colunas FROM PUBLIC, anon, authenticated;
-- REVOKE ALL ON backup_20261008.poder_total_linhas FROM PUBLIC, anon, authenticated;
-- -- Idempotente (revisão adversarial I, menor 16): uma linha por registro. Rodar de novo (ou
-- -- reverter, reaplicar e reverter outra vez) atualiza a linha guardada, nunca a duplica.
-- -- Cópias repetidas de uma versão anterior deste arquivo ficam só com a mais recente.
-- DELETE FROM backup_20261008.poder_total_colunas a USING backup_20261008.poder_total_colunas b
--  WHERE a.tabela = b.tabela AND a.id = b.id AND (a.gravado_em, a.ctid) < (b.gravado_em, b.ctid);
-- DELETE FROM backup_20261008.poder_total_linhas a USING backup_20261008.poder_total_linhas b
--  WHERE a.tabela = b.tabela AND a.linha ->> 'id' = b.linha ->> 'id' AND (a.gravado_em, a.ctid) < (b.gravado_em, b.ctid);
-- CREATE UNIQUE INDEX IF NOT EXISTS poder_total_colunas_uk ON backup_20261008.poder_total_colunas (tabela, id);
-- CREATE UNIQUE INDEX IF NOT EXISTS poder_total_linhas_uk ON backup_20261008.poder_total_linhas (tabela, (linha ->> 'id'));
--
-- DO $$
-- DECLARE t text;
-- BEGIN
--   IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'escoltas' AND column_name = 'versao_gestao') THEN
--     EXECUTE $q$
--       INSERT INTO backup_20261008.poder_total_colunas (tabela, id, dados)
--       SELECT 'escoltas', id, jsonb_build_object('arquivada_em', arquivada_em, 'arquivada_por', arquivada_por,
--              'motivo_arquivamento', motivo_arquivamento, 'reiniciada_em', reiniciada_em, 'versao_gestao', versao_gestao)
--       FROM public.escoltas
--       WHERE arquivada_em IS NOT NULL OR reiniciada_em IS NOT NULL OR versao_gestao <> 0 OR motivo_arquivamento IS NOT NULL
--       ON CONFLICT (tabela, id) DO UPDATE SET dados = EXCLUDED.dados, gravado_em = now()$q$;
--   END IF;
--   FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
--                            'atualizacoes_status', 'rastreamento', 'escolta_status_historico']
--   LOOP
--     IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = t AND column_name = 'anulado_em') THEN
--       EXECUTE format($q$
--         INSERT INTO backup_20261008.poder_total_colunas (tabela, id, dados)
--         SELECT %L, id, jsonb_build_object('anulado_em', anulado_em, 'anulado_por', anulado_por, 'motivo_anulacao', motivo_anulacao,
--                'anulacao_id', anulacao_id, 'status_escolta_no_registro', status_escolta_no_registro)
--                || CASE WHEN %L = 'escolta_status_historico' THEN jsonb_build_object('via_rpc', to_jsonb(x) -> 'via_rpc') ELSE '{}'::jsonb END
--         FROM public.%I x
--         WHERE anulado_em IS NOT NULL OR status_escolta_no_registro IS NOT NULL
--         ON CONFLICT (tabela, id) DO UPDATE SET dados = EXCLUDED.dados, gravado_em = now()$q$, t, t, t);
--     END IF;
--   END LOOP;
--   IF to_regclass('public.escolta_resets') IS NOT NULL THEN
--     INSERT INTO backup_20261008.poder_total_linhas (tabela, linha) SELECT 'escolta_resets', to_jsonb(r) FROM public.escolta_resets r
--     ON CONFLICT (tabela, (linha ->> 'id')) DO UPDATE SET linha = EXCLUDED.linha, gravado_em = now();
--   END IF;
--   IF to_regclass('public.escolta_conclusoes_antecipadas') IS NOT NULL THEN
--     INSERT INTO backup_20261008.poder_total_linhas (tabela, linha)
--     SELECT 'escolta_conclusoes_antecipadas', to_jsonb(c) FROM public.escolta_conclusoes_antecipadas c
--     ON CONFLICT (tabela, (linha ->> 'id')) DO UPDATE SET linha = EXCLUDED.linha, gravado_em = now();
--   END IF;
-- END $$;
--
-- DROP VIEW IF EXISTS public.vw_pendencias_conclusao;
-- DROP TABLE IF EXISTS public.escolta_conclusoes_antecipadas;
-- DROP TABLE IF EXISTS public.escolta_resets;
--
-- DROP TRIGGER IF EXISTS tr_preencher_lancado_por ON public.pontos_controle;
-- DROP TRIGGER IF EXISTS tr_travar_colunas_gestao_escoltas ON public.escoltas;
-- DO $$
-- DECLARE t text;
-- BEGIN
--   FOREACH t IN ARRAY ARRAY['pontos_controle', 'checklists', 'ocorrencias', 'emergencias', 'presencas', 'mural_presencas',
--                            'atualizacoes_status', 'rastreamento', 'escolta_status_historico']
--   LOOP
--     EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_carimbar_etapa_' || t, t);
--     EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tr_travar_colunas_gestao_' || t, t);
--     EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS anulado_em, DROP COLUMN IF EXISTS anulado_por,
--                     DROP COLUMN IF EXISTS motivo_anulacao, DROP COLUMN IF EXISTS anulacao_id,
--                     DROP COLUMN IF EXISTS status_escolta_no_registro', t);
--   END LOOP;
-- END $$;
-- DROP INDEX IF EXISTS public.idx_anulacao_pontos;
-- ALTER TABLE public.escolta_status_historico DROP COLUMN IF EXISTS via_rpc;
-- DROP FUNCTION IF EXISTS lote_interno.carimbar_etapa();
-- DROP FUNCTION IF EXISTS lote_interno.travar_colunas_gestao();
-- DROP FUNCTION IF EXISTS lote_interno.preencher_lancado_por();
--
-- DROP INDEX IF EXISTS public.idx_escoltas_nao_arquivadas;
-- ALTER TABLE public.escoltas
--   DROP COLUMN IF EXISTS arquivada_em,
--   DROP COLUMN IF EXISTS arquivada_por,
--   DROP COLUMN IF EXISTS motivo_arquivamento,
--   DROP COLUMN IF EXISTS reiniciada_em,
--   DROP COLUMN IF EXISTS versao_gestao;

-- ──────── reverter 212_aviso_checkin_servidor ────────
-- -- 212_aviso_checkin_servidor_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda J e o deploy (o alerta volta a ser
-- -- calculado no navegador); depois este arquivo; a 211 só depois dele.
-- -- Desagenda o cron, remove as funções internas e a reservar_alertas_checkin, devolve
-- -- enfileirar_alerta_checkin ao corpo da 208 e tira a coluna checkin_telegram_pelo_cron.
-- -- Os avisos de check-in já gravados ficam (a reversão da 211 os guarda). As reservas do
-- -- navegador (avisos_reservados, chave checkin:...) ficam: a tabela é da 208.
-- DO $$
-- BEGIN
--   IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
--     PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lote2026_avisos_checkin';
--   END IF;
-- END $$;
--
-- CREATE OR REPLACE FUNCTION public.enfileirar_alerta_checkin(p_escolta_id uuid) RETURNS jsonb
--     LANGUAGE plpgsql VOLATILE SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
-- DECLARE v_perfil text; e record; v_ultima timestamptz; v_atraso int; v_ok boolean;
-- BEGIN
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil IS NULL THEN RAISE EXCEPTION 'Sessao invalida.'; END IF;
--   IF v_perfil NOT IN ('administrador', 'gestor', 'supervisor', 'central') AND NOT public.sou_do_efetivo(p_escolta_id) THEN
--     RAISE EXCEPTION 'Sem permissao para esta escolta.';
--   END IF;
--   SELECT es.id, es.codigo_escolta, es.status, es.periodicidade_checkin_min, c.nome_cliente INTO e
--   FROM public.escoltas es JOIN public.clientes c ON c.id = es.cliente_id WHERE es.id = p_escolta_id;
--   IF e.id IS NULL OR e.periodicidade_checkin_min IS NULL
--      OR e.status NOT IN ('em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando') THEN
--     RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem check-in periodico');
--   END IF;
--   -- Regra antiga (pendência 0.3 de docs/12): qualquer PARADA zera o prazo; sem nenhuma, não notifica.
--   SELECT max(pc.data_hora) INTO v_ultima
--   FROM public.pontos_controle pc JOIN public.escolta_veiculos ev ON ev.id = pc.escolta_veiculo_id
--   WHERE ev.escolta_id = p_escolta_id AND pc.tipo_ponto_id = 'e1601f15-5ef9-44e8-abd0-17f65b3aa760';
--   IF v_ultima IS NULL THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'sem parada'); END IF;
--   v_atraso := floor(extract(epoch FROM (now() - v_ultima)) / 60) - e.periodicidade_checkin_min;
--   IF v_atraso < 1 THEN RETURN jsonb_build_object('enfileirado', false, 'motivo', 'em dia'); END IF;
--   -- Uma mensagem por período vencido sem check-in (chave: escolta, última parada e
--   -- número do período). Antes saía uma a cada 5 min por navegador aberto.
--   v_ok := public._enfileirar_aviso('checkin:' || p_escolta_id || ':' || extract(epoch FROM v_ultima)::bigint
--                                    || ':' || floor(v_atraso::numeric / e.periodicidade_checkin_min)::int, 'cliente', p_escolta_id,
--     '<b>Alerta: check-in em atraso</b>' || E'\n'
--     || 'Escolta: <code>' || public.escapar_html(e.codigo_escolta) || '</code> · ' || public.escapar_html(e.nome_cliente) || E'\n'
--     || 'Sem check-in há ' || (v_atraso + e.periodicidade_checkin_min) || ' minutos (periodicidade de '
--     || e.periodicidade_checkin_min || ' min).' || E'\n'
--     || 'Registrado em ' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (Brasília)');
--   RETURN jsonb_build_object('enfileirado', v_ok);
-- END;
-- $$;
-- REVOKE ALL ON FUNCTION public.enfileirar_alerta_checkin(uuid) FROM PUBLIC, anon;
-- GRANT EXECUTE ON FUNCTION public.enfileirar_alerta_checkin(uuid) TO authenticated;
--
-- DROP FUNCTION IF EXISTS public.reservar_alertas_checkin();
-- DROP FUNCTION IF EXISTS lote_interno.gerar_avisos_checkin(timestamptz);
-- DROP FUNCTION IF EXISTS lote_interno.enfileirar_alerta_checkin(uuid);
-- DROP FUNCTION IF EXISTS lote_interno.tipo_da_observacao(text);
-- ALTER TABLE public.configuracao_avisos DROP COLUMN IF EXISTS checkin_telegram_pelo_cron;

-- ──────── reverter 211_central_avisos ────────
-- -- 211_central_avisos_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda J e o deploy; depois 217_reverter (bloco 2)
-- -- e 212_reverter; só então este arquivo. Aborta se a 212 ou a 217 ainda estiverem aplicadas
-- -- (elas chamam lote_interno.notificar).
-- -- Guarda as colunas novas em backup_20261008.notificacoes_central (e as linhas inteiras dos
-- -- tipos novos, que somem com os tipos), devolve as policies e os grants da 195 e recria as
-- -- restritivas da 197 (para o M3 não reabrir).
-- DO $$
-- BEGIN
--   IF to_regprocedure('lote_interno.gerar_avisos_checkin(timestamptz)') IS NOT NULL THEN
--     RAISE EXCEPTION 'Reverta a 212 antes da 211: o cron do check-in usa lote_interno.notificar.';
--   END IF;
--   IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--               WHERE n.nspname = 'public' AND p.proname = '_avisar_app' AND p.prosrc LIKE '%lote_interno.notificar%') THEN
--     RAISE EXCEPTION 'Reverta a 217 antes da 211: _avisar_app chama lote_interno.notificar.';
--   END IF;
-- END $$;
--
-- CREATE SCHEMA IF NOT EXISTS backup_20261008;
-- REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
-- CREATE TABLE IF NOT EXISTS backup_20261008.notificacoes_central (
--   id           uuid PRIMARY KEY,
--   lida_em      timestamptz,
--   titulo       text,
--   texto        text,
--   evento_chave text,
--   linha        jsonb,          -- linha inteira, só para os tipos novos (apagados abaixo)
--   gravado_em   timestamptz NOT NULL DEFAULT now()
-- );
-- REVOKE ALL ON backup_20261008.notificacoes_central FROM PUBLIC, anon, authenticated;
--
-- DO $$
-- BEGIN
--   IF EXISTS (SELECT 1 FROM information_schema.columns
--               WHERE table_schema = 'public' AND table_name = 'notificacoes' AND column_name = 'evento_chave') THEN
--     EXECUTE $q$
--       INSERT INTO backup_20261008.notificacoes_central (id, lida_em, titulo, texto, evento_chave, linha)
--       SELECT n.id, n.lida_em, n.titulo, n.texto, n.evento_chave,
--              CASE WHEN t.codigo IN ('checkin_vencido', 'edicao_escolta', 'reset_escolta', 'conclusao_antecipada',
--                                     'arquivamento_escolta', 'recuperacao_escolta', 'conflito_offline')
--                   THEN to_jsonb(n) END
--       FROM public.notificacoes n JOIN public.dom_tipos_evento t ON t.id = n.tipo_evento_id
--       WHERE n.lida_em IS NOT NULL OR n.titulo IS NOT NULL OR n.texto IS NOT NULL OR n.evento_chave IS NOT NULL
--       ON CONFLICT (id) DO UPDATE SET lida_em = EXCLUDED.lida_em, titulo = EXCLUDED.titulo, texto = EXCLUDED.texto,
--         evento_chave = EXCLUDED.evento_chave, linha = EXCLUDED.linha, gravado_em = now()$q$;
--   END IF;
-- END $$;
--
-- DELETE FROM public.notificacoes WHERE tipo_evento_id IN
--   (SELECT id FROM public.dom_tipos_evento WHERE codigo IN ('checkin_vencido', 'edicao_escolta', 'reset_escolta',
--      'conclusao_antecipada', 'arquivamento_escolta', 'recuperacao_escolta', 'conflito_offline'));
-- DELETE FROM public.dom_tipos_evento WHERE codigo IN ('checkin_vencido', 'edicao_escolta', 'reset_escolta',
--   'conclusao_antecipada', 'arquivamento_escolta', 'recuperacao_escolta', 'conflito_offline');
--
-- DROP FUNCTION IF EXISTS public.meus_avisos(text, uuid, boolean, integer, timestamptz, uuid);
-- DROP FUNCTION IF EXISTS public.meus_avisos(text, uuid, boolean, integer, timestamptz);
-- DROP FUNCTION IF EXISTS public.contar_avisos_nao_lidos();
-- DROP FUNCTION IF EXISTS public.marcar_todos_lidos(text, uuid);
-- DROP FUNCTION IF EXISTS public.marcar_todos_lidos(text);
--
-- DROP TRIGGER IF EXISTS tr_notificacoes_sincronizar_lida ON public.notificacoes;
-- DROP INDEX IF EXISTS public.notificacoes_evento_destinatario_uk;
-- DROP INDEX IF EXISTS public.idx_notificacoes_caixa;
-- ALTER TABLE public.notificacoes
--   DROP COLUMN IF EXISTS lida_em,
--   DROP COLUMN IF EXISTS titulo,
--   DROP COLUMN IF EXISTS texto,
--   DROP COLUMN IF EXISTS evento_chave;
--
-- -- Policies da 195 e restritivas da 197.
-- DROP POLICY IF EXISTS notificacoes_select ON public.notificacoes;
-- CREATE POLICY notificacoes_select ON public.notificacoes FOR SELECT TO authenticated USING (((usuario_dest_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)) OR (( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text]))));
-- DROP POLICY IF EXISTS notificacoes_escrita ON public.notificacoes;
-- CREATE POLICY notificacoes_escrita ON public.notificacoes TO authenticated USING (((usuario_dest_id = ( SELECT public.get_meu_usuario_id() AS get_meu_usuario_id)) OR (( SELECT public.get_meu_perfil() AS get_meu_perfil) = ANY (ARRAY['administrador'::text, 'gestor'::text, 'supervisor'::text, 'central'::text])))) WITH CHECK (true);
-- DROP POLICY IF EXISTS notificacoes_insert_so_gestao ON public.notificacoes;
-- CREATE POLICY notificacoes_insert_so_gestao ON public.notificacoes AS RESTRICTIVE FOR INSERT TO authenticated
--   WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central']));
-- DROP POLICY IF EXISTS notificacoes_update_restrita ON public.notificacoes;
-- CREATE POLICY notificacoes_update_restrita ON public.notificacoes AS RESTRICTIVE FOR UPDATE TO authenticated
--   USING ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central'])
--          OR usuario_dest_id = (SELECT public.get_meu_usuario_id()))
--   WITH CHECK ((SELECT public.get_meu_perfil()) = ANY (ARRAY['administrador','gestor','supervisor','central'])
--          OR usuario_dest_id = (SELECT public.get_meu_usuario_id()));
-- GRANT ALL ON public.notificacoes TO anon;
-- GRANT INSERT, UPDATE, DELETE, TRUNCATE ON public.notificacoes TO authenticated;
--
-- -- Schema interno: só cai vazio (as ondas I e L também criam funções nele e revertem antes).
-- DROP FUNCTION IF EXISTS lote_interno.notificar(text, uuid, text, uuid[], text, text, jsonb);
-- DROP FUNCTION IF EXISTS lote_interno.sincronizar_lida();
-- DO $$
-- BEGIN
--   IF to_regnamespace('lote_interno') IS NOT NULL
--      AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'lote_interno'::regnamespace)
--      AND NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = 'lote_interno'::regnamespace) THEN
--     ALTER DEFAULT PRIVILEGES IN SCHEMA lote_interno GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
--     DROP SCHEMA lote_interno;
--   END IF;
-- END $$;

-- ──────── reverter 209_historico_sem_trigger ────────
-- -- 209_historico_sem_trigger_reverter.sql
-- -- A trigger não existia em produção antes da 209; a reversão só devolve o comentário.
-- COMMENT ON FUNCTION public.registrar_historico_status_escolta() IS 'OBSOLETA. A trigger foi removida porque duplicava o registro que o app ja faz com autor, observacao e GPS. Mantida apenas como referencia. Escrita direta em escoltas fora do app fica sem historico: e detectada pela reconciliacao descrita em docs/07 - Runbook.md.';

-- ──────── reverter 208_avisos_pelo_servidor ────────
-- -- 208_avisos_pelo_servidor_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda F e o deploy; depois este arquivo.
-- DROP FUNCTION IF EXISTS public.enfileirar_alerta_checkin(uuid);
-- DROP FUNCTION IF EXISTS public.reservar_aviso_presenca(uuid);
-- DROP TABLE IF EXISTS public.avisos_reservados;

-- ──────── reverter 207_etapa_atomica ────────
-- -- 207_etapa_atomica_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda F e o deploy; depois este arquivo.
-- DROP FUNCTION IF EXISTS public.registrar_etapa_escolta(uuid, jsonb, text, text, text, numeric, numeric, text, timestamptz, uuid);

-- ──────── reverter 206_combustivel ────────
-- -- 206_combustivel_reverter.sql
-- DROP TRIGGER IF EXISTS tr_impedir_combustivel_por_operador ON public.escolta_veiculos;
-- DROP FUNCTION IF EXISTS public.impedir_combustivel_por_operador();

-- ──────── reverter 205_locais_salvos ────────
-- -- 205_locais_salvos_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda D e o deploy; depois este arquivo.
-- -- Guarda os locais (com quem conferiu) em backup_20261008 antes de remover a tabela.
-- CREATE SCHEMA IF NOT EXISTS backup_20261008;
-- REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
-- DO $$
-- BEGIN
--   IF to_regclass('public.locais_salvos') IS NOT NULL THEN
--     DROP TABLE IF EXISTS backup_20261008.locais_salvos;
--     CREATE TABLE backup_20261008.locais_salvos AS SELECT * FROM public.locais_salvos;
--     REVOKE ALL ON backup_20261008.locais_salvos FROM PUBLIC, anon, authenticated;
--   END IF;
-- END $$;
-- DROP TABLE IF EXISTS public.locais_salvos;
-- DROP FUNCTION IF EXISTS public.locais_salvos_regras();

-- ──────── reverter 203_mural_travas_estrutura ────────
-- -- 203_mural_travas_estrutura_reverter.sql
-- -- Guarda pedidos e presenças em backup_20261008 (se houver linhas) e remove a estrutura.
-- -- Reverta antes a 204, que depende destas tabelas.
-- CREATE SCHEMA IF NOT EXISTS backup_20261008;
-- REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
-- DO $$
-- BEGIN
--   IF to_regclass('public.mural_pedidos') IS NOT NULL AND EXISTS (SELECT 1 FROM public.mural_pedidos) THEN
--     EXECUTE 'CREATE TABLE IF NOT EXISTS backup_20261008.mural_pedidos AS SELECT * FROM public.mural_pedidos WITH NO DATA';
--     EXECUTE 'INSERT INTO backup_20261008.mural_pedidos SELECT * FROM public.mural_pedidos';
--   END IF;
--   IF to_regclass('public.mural_presencas') IS NOT NULL AND EXISTS (SELECT 1 FROM public.mural_presencas) THEN
--     EXECUTE 'CREATE TABLE IF NOT EXISTS backup_20261008.mural_presencas AS SELECT * FROM public.mural_presencas WITH NO DATA';
--     EXECUTE 'INSERT INTO backup_20261008.mural_presencas SELECT * FROM public.mural_presencas';
--   END IF;
-- END $$;
-- DROP TABLE IF EXISTS public.mural_pedidos;
-- DROP TABLE IF EXISTS public.mural_presencas;
-- DROP TABLE IF EXISTS public.configuracoes_mural;
-- DROP TRIGGER IF EXISTS tr_proteger_escala_fixa ON public.escoltas;
-- DROP FUNCTION IF EXISTS public.proteger_escala_fixa();
-- ALTER TABLE public.escoltas DROP COLUMN IF EXISTS escala_fixa;
-- DELETE FROM public.notificacoes WHERE tipo_evento_id IN
--   (SELECT id FROM public.dom_tipos_evento WHERE codigo IN ('pedido_substituicao', 'decisao_substituicao', 'substituicao_equipe'));
-- DELETE FROM public.dom_tipos_evento WHERE codigo IN ('pedido_substituicao', 'decisao_substituicao', 'substituicao_equipe');

-- ──────── reverter 202_avisos_telegram ────────
-- -- 202_avisos_telegram_reverter.sql
-- -- ORDEM: reverter antes a 204 (as RPCs do mural chamam a fila) e o código das ondas C e F.
-- -- Este arquivo aborta se a 204 ainda estiver aplicada. Desagenda só os jobs do lote e não
-- -- remove pg_cron nem pg_net (removê-las apagaria qualquer outro agendamento do projeto).
-- DO $$
-- BEGIN
--   IF to_regprocedure('public.mural_travas_ativas()') IS NOT NULL THEN
--     RAISE EXCEPTION 'Reverta a 204 antes da 202: as RPCs do mural usam a fila de avisos.';
--   END IF;
--   IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
--     PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lote2026_avisos_telegram';
--   END IF;
-- END $$;
-- DROP FUNCTION IF EXISTS public.conferir_avisos_telegram();
-- DROP FUNCTION IF EXISTS public.enviar_avisos_telegram();
-- DROP FUNCTION IF EXISTS public._enfileirar_aviso(text, text, uuid, text);
-- DROP FUNCTION IF EXISTS public.avisos_pelo_banco_ativos();
-- DROP FUNCTION IF EXISTS public.escapar_html(text);
-- DROP TABLE IF EXISTS public.avisos_telegram;
-- DROP TABLE IF EXISTS public.configuracao_avisos;
-- DROP TABLE IF EXISTS backup_20261008.extensoes_antes_202;

-- ──────── reverter 201_checkin_desligado ────────
-- -- 201_checkin_desligado_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda B e o deploy; depois este arquivo.
-- -- Com o código novo no ar e sem a tabela, o X do aviso deixa de valer.
-- -- Devolve a periodicidade guardada e remove alertas_dispensados.
-- DO $$
-- BEGIN
--   IF to_regclass('backup_20261008.periodicidade_checkin') IS NOT NULL THEN
--     UPDATE public.escoltas e SET periodicidade_checkin_min = b.periodicidade_checkin_min
--     FROM backup_20261008.periodicidade_checkin b
--     WHERE b.escolta_id = e.id AND e.periodicidade_checkin_min IS NULL;
--   END IF;
-- END $$;
-- DROP TABLE IF EXISTS backup_20261008.periodicidade_checkin;
-- DROP TABLE IF EXISTS public.alertas_dispensados;

-- ──────── reverter 199_troca_senha_obrigatoria ────────
-- -- 199_troca_senha_obrigatoria_reverter.sql
-- -- Desmarca só as contas que a 199 marcou (registro em logs_auditoria) e apaga esse registro.
-- UPDATE public.usuarios SET troca_senha_obrigatoria = false, atualizado_em = now()
-- WHERE id IN (SELECT registro_id FROM public.logs_auditoria WHERE acao = 'lote_2026_10_troca_senha');
-- DELETE FROM public.logs_auditoria WHERE acao = 'lote_2026_10_troca_senha';

-- ──────── reverter 198_fotos_leitura_por_escolta ────────
-- -- 198_fotos_leitura_por_escolta_reverter.sql
-- -- Antes de reverter com o bucket fechado, reverta a 200 (senão as fotos somem das telas).
-- DROP POLICY IF EXISTS fotos_leitura_autenticada ON storage.objects;
-- DROP POLICY IF EXISTS fotos_select_por_escolta ON public.fotos;
-- DROP FUNCTION IF EXISTS public.escolta_do_caminho(text);

-- ──────── reverter 197_escrita_do_operador ────────
-- -- 197_escrita_do_operador_reverter.sql
-- -- Reverte a 197: corpos de produção de 08/10/2026 (migration 195) e policies originais.
-- -- Não mexe em ACL de função (a 196 cuida disso).
--
-- CREATE OR REPLACE FUNCTION public.impedir_edicao_por_operador() RETURNS trigger
--     LANGUAGE plpgsql SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
-- DECLARE
--   v_perfil text;
-- BEGIN
--   -- Sem sessao de usuario final: SQL direto, migration ou service role. Passa, como nas
--   -- demais funcoes deste banco, por ser a via de reparo.
--   IF auth.uid() IS NULL THEN
--     RETURN NEW;
--   END IF;
--
--   SELECT public.get_meu_perfil() INTO v_perfil;
--   IF v_perfil = ANY (ARRAY['administrador','gestor','supervisor','central']) THEN
--     RETURN NEW;
--   END IF;
--
--   -- Daqui para baixo e operador ou vigilante. Ele so pode mover a escolta pelo fluxo:
--   -- status, e os carimbos que o proprio avanco preenche.
--   IF NEW.cliente_id          IS DISTINCT FROM OLD.cliente_id
--      OR NEW.data_hora_prevista IS DISTINCT FROM OLD.data_hora_prevista
--      OR NEW.origem_endereco  IS DISTINCT FROM OLD.origem_endereco
--      OR NEW.origem_lat       IS DISTINCT FROM OLD.origem_lat
--      OR NEW.origem_lng       IS DISTINCT FROM OLD.origem_lng
--      OR NEW.destino_endereco IS DISTINCT FROM OLD.destino_endereco
--      OR NEW.destino_lat      IS DISTINCT FROM OLD.destino_lat
--      OR NEW.destino_lng      IS DISTINCT FROM OLD.destino_lng
--   THEN
--     RAISE EXCEPTION 'Operador nao edita dados da escolta. Fale com o supervisor para alterar cliente, data ou local.';
--   END IF;
--
--   RETURN NEW;
-- END;
-- $$;
--
-- CREATE OR REPLACE FUNCTION public.impedir_autopromocao() RETURNS trigger
--     LANGUAGE plpgsql SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
-- DECLARE
--   v_perfil      text;
--   v_eu          uuid;
--   v_cod_novo    text;
--   v_cod_antigo  text;
-- BEGIN
--   v_eu := auth.uid();
--
--   -- Sem sessao de usuario final: SQL direto, migration ou service role.
--   -- Passa de proposito, e o unico caminho de reparo do banco. O controle
--   -- desse caminho e a reconciliacao detectiva, nao esta trigger.
--   IF v_eu IS NULL THEN
--     RETURN NEW;
--   END IF;
--
--   SELECT public.get_meu_perfil() INTO v_perfil;
--
--   -- O vinculo com auth.users nunca muda pela API: trocar auth_user_id
--   -- e sequestro de conta, nao edicao de cadastro.
--   IF NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
--     RAISE EXCEPTION 'O vinculo de autenticacao nao pode ser alterado pela aplicacao.';
--   END IF;
--
--   -- 1. Ninguem mexe no proprio perfil nem no proprio status, nem administrador.
--   --    Confere OLD e NEW para o caso de a linha ser reapontada na mesma instrucao.
--   IF OLD.auth_user_id = v_eu OR NEW.auth_user_id = v_eu THEN
--     IF NEW.perfil_id IS DISTINCT FROM OLD.perfil_id THEN
--       RAISE EXCEPTION 'Voce nao pode alterar o proprio perfil de acesso.';
--     END IF;
--     IF NEW.status IS DISTINCT FROM OLD.status THEN
--       RAISE EXCEPTION 'Voce nao pode alterar o proprio status.';
--     END IF;
--     RETURN NEW;
--   END IF;
--
--   -- 2. Mexer no perfil de terceiro exige perfil de gestao.
--   IF NEW.perfil_id IS DISTINCT FROM OLD.perfil_id THEN
--     IF v_perfil IS NULL OR v_perfil NOT IN ('administrador', 'gestor') THEN
--       RAISE EXCEPTION 'Permissao negada para alterar perfil de acesso.';
--     END IF;
--
--     SELECT codigo INTO v_cod_novo   FROM public.dom_perfis WHERE id = NEW.perfil_id;
--     SELECT codigo INTO v_cod_antigo FROM public.dom_perfis WHERE id = OLD.perfil_id;
--
--     -- 3. Conceder ou retirar 'administrador' e privativo de administrador.
--     --    Sem isto, o gestor promove um comparsa em vez de a si mesmo.
--     IF v_perfil <> 'administrador'
--        AND 'administrador' IN (coalesce(v_cod_novo, ''), coalesce(v_cod_antigo, '')) THEN
--       RAISE EXCEPTION 'Somente um administrador concede ou remove o perfil administrador.';
--     END IF;
--   END IF;
--
--   RETURN NEW;
-- END;
-- $$;
--
-- CREATE OR REPLACE FUNCTION public.redefinir_senha_usuario(p_usuario_id uuid, p_nova_senha text) RETURNS void
--     LANGUAGE plpgsql SECURITY DEFINER
--     SET search_path TO 'public', 'auth', 'extensions', 'pg_temp'
--     AS $$
-- DECLARE
--   v_caller_perfil TEXT;
--   v_alvo_perfil   TEXT;
-- BEGIN
--   -- Perfil de quem chama
--   SELECT p.codigo INTO v_caller_perfil
--   FROM public.usuarios u
--   INNER JOIN public.dom_perfis p ON p.id = u.perfil_id
--   WHERE u.auth_user_id = auth.uid()
--     AND u.status = 'ativo';
--
--   IF v_caller_perfil IS NULL OR v_caller_perfil NOT IN ('administrador', 'gestor') THEN
--     RAISE EXCEPTION 'Permissão negada. Apenas administradores e gestores podem redefinir senhas.';
--   END IF;
--
--   -- Perfil do alvo. p_usuario_id e o auth_user_id do alvo.
--   SELECT p.codigo INTO v_alvo_perfil
--   FROM public.usuarios u
--   INNER JOIN public.dom_perfis p ON p.id = u.perfil_id
--   WHERE u.auth_user_id = p_usuario_id;
--
--   IF v_alvo_perfil IS NULL THEN
--     RAISE EXCEPTION 'Usuário alvo não encontrado.';
--   END IF;
--
--   -- Somente administrador redefine a senha de um administrador.
--   IF v_alvo_perfil = 'administrador' AND v_caller_perfil <> 'administrador' THEN
--     RAISE EXCEPTION 'Permissão negada. Apenas um administrador pode redefinir a senha de outro administrador.';
--   END IF;
--
--   IF length(p_nova_senha) < 6 THEN
--     RAISE EXCEPTION 'A senha deve ter pelo menos 6 caracteres.';
--   END IF;
--
--   UPDATE auth.users
--   SET encrypted_password = crypt(p_nova_senha, gen_salt('bf')),
--       updated_at = now()
--   WHERE id = p_usuario_id;
--
--   IF NOT FOUND THEN
--     RAISE EXCEPTION 'Usuário não encontrado na autenticação.';
--   END IF;
--
--   UPDATE public.usuarios
--   SET troca_senha_obrigatoria = true,
--       atualizado_em = now()
--   WHERE auth_user_id = p_usuario_id;
-- END;
-- $$;
--
-- DO $$
-- DECLARE t text;
-- BEGIN
--   FOREACH t IN ARRAY ARRAY['emergencias','presencas','rastreamento','atualizacoes_status',
--                            'checklists','checklist_respostas','escolta_veiculos']
--   LOOP
--     EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_delete_so_gestao', t);
--   END LOOP;
-- END $$;
-- DROP POLICY IF EXISTS notificacoes_insert_so_gestao ON public.notificacoes;
-- DROP POLICY IF EXISTS notificacoes_update_restrita ON public.notificacoes;
-- DROP POLICY IF EXISTS logs_auditoria_insert ON public.logs_auditoria;
-- CREATE POLICY logs_auditoria_insert ON public.logs_auditoria FOR INSERT TO authenticated WITH CHECK (true);

-- ──────── reverter 196_identidade_e_higiene ────────
-- -- 196_identidade_e_higiene_reverter.sql
-- -- Reverte a 196 para o estado de produção de 08/10/2026 (corpos da 195 e ACLs do dump).
--
-- CREATE OR REPLACE FUNCTION public.perfil_usuario_atual() RETURNS text
--     LANGUAGE sql STABLE SECURITY DEFINER
--     SET search_path TO 'public'
--     AS $$
--   SELECT p.codigo
--   FROM public.usuarios u
--   JOIN public.dom_perfis p ON p.id = u.perfil_id
--   WHERE u.auth_user_id = auth.uid()
--   LIMIT 1
-- $$;
--
-- CREATE OR REPLACE FUNCTION public.sou_do_efetivo(p_escolta_id uuid) RETURNS boolean
--     LANGUAGE sql STABLE SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
--   SELECT EXISTS (
--     SELECT 1
--     FROM public.escolta_efetivo ee
--     JOIN public.vigilantes v ON v.id = ee.vigilante_id
--     JOIN public.usuarios u   ON u.id = v.usuario_id
--     WHERE ee.escolta_id = p_escolta_id
--       AND u.auth_user_id = auth.uid()
--   );
-- $$;
--
-- ALTER FUNCTION public.cadastrar_operador(text, text, text, text, text, uuid, text, text, numeric, text)
--   SET search_path TO 'public', 'auth', 'extensions';
-- ALTER FUNCTION public.criar_usuario_completo(text, text, text, uuid, text, text)
--   SET search_path TO 'public', 'auth', 'extensions';
-- ALTER FUNCTION public.excluir_auth_usuario(uuid)
--   SET search_path TO 'public';
--
-- -- ACLs das funções de trigger e da view, como estavam no dump de produção.
-- REVOKE ALL ON FUNCTION public.exigir_ponto_transito_retorno() FROM PUBLIC;
-- GRANT ALL ON FUNCTION public.exigir_ponto_transito_retorno() TO service_role;
-- REVOKE ALL ON FUNCTION public.garantir_vinculo_operador() FROM PUBLIC;
-- GRANT ALL ON FUNCTION public.garantir_vinculo_operador() TO authenticated;
-- GRANT ALL ON FUNCTION public.garantir_vinculo_operador() TO service_role;
-- GRANT ALL ON FUNCTION public.gerar_codigo_escolta() TO anon;
-- GRANT ALL ON FUNCTION public.gerar_codigo_escolta() TO authenticated;
-- GRANT ALL ON FUNCTION public.gerar_codigo_escolta() TO service_role;
-- REVOKE ALL ON FUNCTION public.impedir_autopromocao() FROM PUBLIC;
-- GRANT ALL ON FUNCTION public.impedir_autopromocao() TO service_role;
-- REVOKE ALL ON FUNCTION public.impedir_criacao_perfil_superior() FROM PUBLIC;
-- GRANT ALL ON FUNCTION public.impedir_criacao_perfil_superior() TO service_role;
-- GRANT ALL ON FUNCTION public.impedir_edicao_por_operador() TO anon;
-- GRANT ALL ON FUNCTION public.impedir_edicao_por_operador() TO authenticated;
-- GRANT ALL ON FUNCTION public.impedir_edicao_por_operador() TO service_role;
-- REVOKE ALL ON FUNCTION public.registrar_historico_status_escolta() FROM PUBLIC;
-- GRANT ALL ON FUNCTION public.registrar_historico_status_escolta() TO service_role;
-- GRANT ALL ON FUNCTION public.sync_auth_user_on_usuarios() TO anon;
-- GRANT ALL ON FUNCTION public.sync_auth_user_on_usuarios() TO authenticated;
-- GRANT ALL ON FUNCTION public.sync_auth_user_on_usuarios() TO service_role;
-- GRANT ALL ON FUNCTION public.update_atualizado_em() TO anon;
-- GRANT ALL ON FUNCTION public.update_atualizado_em() TO authenticated;
-- GRANT ALL ON FUNCTION public.update_atualizado_em() TO service_role;
-- GRANT ALL ON FUNCTION public.validar_transicao_status_escolta() TO anon;
-- GRANT ALL ON FUNCTION public.validar_transicao_status_escolta() TO authenticated;
-- GRANT ALL ON FUNCTION public.validar_transicao_status_escolta() TO service_role;
-- GRANT ALL ON FUNCTION public.verificar_checklist_pendente() TO anon;
-- GRANT ALL ON FUNCTION public.verificar_checklist_pendente() TO authenticated;
-- GRANT ALL ON FUNCTION public.verificar_checklist_pendente() TO service_role;
-- REVOKE ALL ON FUNCTION public.vincular_vigilante_a_usuario() FROM PUBLIC;
-- GRANT ALL ON FUNCTION public.vincular_vigilante_a_usuario() TO authenticated;
-- GRANT ALL ON FUNCTION public.vincular_vigilante_a_usuario() TO service_role;
-- GRANT EXECUTE ON FUNCTION public.gerar_codigo_escolta() TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION public.sync_auth_user_on_usuarios() TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION public.update_atualizado_em() TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION public.validar_transicao_status_escolta() TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION public.verificar_checklist_pendente() TO PUBLIC;
-- GRANT ALL ON TABLE public.vw_operador_sem_vinculo TO anon;
-- GRANT ALL ON TABLE public.vw_operador_sem_vinculo TO authenticated;
-- GRANT ALL ON TABLE public.vw_operador_sem_vinculo TO service_role;
-- GRANT EXECUTE ON FUNCTION public.impedir_edicao_por_operador() TO PUBLIC;
