-- PACOTE_2026-10-08.sql
-- Lote 2026-10 do Escolta Armada: pacote de publicação no banco de produção
-- (projeto qthoyxujyzskydulvcfy). Gerado a partir das migrations 196 a 217 (as do lote que existem) testadas na
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
--   3. BLOCO 2, logo depois do deploy das ondas A, C, G e J. Responder "aplicado 2".
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
UNION ALL SELECT 'Telegram do check-in pelo cron (esperado false até o bloco 2)', checkin_telegram_pelo_cron::text FROM public.configuracao_avisos WHERE id = 1;
-- Esperado: 9 funções, 8 tabelas, 0 abertas com periodicidade, 5 locais aguardando_conferencia,
-- troca true,true, cron lote2026_avisos_telegram e lote2026_avisos_checkin; 4; notificacoes_select; 0; false; false.
-- 'envio pelo banco ativo' falso: o Telegram do check-in sai pelo navegador (reserva no banco,
-- reservar_alertas_checkin), não pelo cron; anotar no relatório qual caminho valeu.

-- ════════════════════════════════════════════════════════════════════════════
-- BLOCO 2 (logo depois do deploy das ondas A, C, G e J)
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
-- 2. Dois índices únicos: (escolta_id, vigilante_id) no efetivo e (escolta_id, veiculo_id)
--    nas viaturas da escolta.
--
-- A auditoria de devolver_escolta não é desta migration: vai na 217 (bloco 2).
--
-- Conferência (esperado: 2 linhas, as duas com indisunique = true):
-- SELECT c.relname, i.indisunique FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
--  WHERE c.relname IN ('escolta_efetivo_escolta_vigilante_uk', 'escolta_veiculos_escolta_veiculo_uk');

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
CREATE UNIQUE INDEX IF NOT EXISTS escolta_veiculos_escolta_veiculo_uk
  ON public.escolta_veiculos (escolta_id, veiculo_id);

COMMENT ON INDEX public.escolta_efetivo_escolta_vigilante_uk IS
  'Lote 2026-10, onda G (210): o mesmo vigilante entra uma vez só em cada escolta, em qualquer viatura.';
COMMENT ON INDEX public.escolta_veiculos_escolta_veiculo_uk IS
  'Lote 2026-10, onda G (210): a mesma viatura entra uma vez só em cada escolta.';

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
UNION ALL SELECT 'Telegram do check-in pelo cron (esperado true)', checkin_telegram_pelo_cron::text FROM public.configuracao_avisos WHERE id = 1;
-- Esperado: true; lote2026_avisos_telegram, lote2026_pedidos_vencidos, lote2026_avisos_checkin; false; fotos_leitura_autenticada; 0; 2; true; true.
-- Com 'envio pelo banco ativo' falso (conferência do bloco 1), o Telegram do check-in continua
-- saindo pelo navegador, com reserva no banco (reservar_alertas_checkin); registrar no relatório.
-- Teste rápido sem escrever dado: abrir em aba anônima a URL pública antiga de uma foto (deve falhar).

-- ════════════════════════════════════════════════════════════════════════════
-- REVERSÃO (só se o teste de produção de uma onda falhar; na ordem abaixo)
-- Cada bloco vem do arquivo NNN_..._reverter.sql, testado na homologação.
-- ════════════════════════════════════════════════════════════════════════════

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
-- -- Tira os dois índices únicos da 210. Nenhum dado muda.
-- DROP INDEX IF EXISTS public.escolta_efetivo_escolta_vigilante_uk;
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
