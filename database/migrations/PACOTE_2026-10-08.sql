-- PACOTE_2026-10-08.sql
-- Lote 2026-10 do Escolta Armada: pacote de publicação no banco de produção
-- (projeto qthoyxujyzskydulvcfy). Gerado a partir das migrations 196 a 218 (as do lote que existem, 215 e 216 incluídas) testadas na
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
UNION ALL SELECT 'onda K: escoltas com coordenada (carga de UF da 216) e clientes ativos (paleta)', (SELECT count(*) FROM public.escoltas WHERE coalesce(origem_lat, 0) <> 0 OR coalesce(destino_lat, 0) <> 0) || '; ' || (SELECT count(*) FROM public.clientes WHERE status = 'ativo')
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

-- ──────── 216_uf_e_paleta.sql ────────
-- 216_uf_e_paleta.sql
-- Lote 2026-10, onda K (adendo 01, item 4.5; docs/14, seção 15). Idempotente. Bloco 1, depois
-- da 215. Compatível com a master 2b3fff9: a master não lê nem grava as colunas novas de
-- escoltas (o INSERT e o UPDATE dela continuam iguais; a coluna gerada não recusa nada) e grava
-- cor livre em clientes.cor_destaque (cadastros/page.tsx:689, clientes/page.tsx:52): a trigger
-- nova normaliza para a paleta e nunca dá erro.
--
-- Por quê:
-- 1. Etiqueta "Interestadual": escoltas.origem_uf e destino_uf (duas letras maiúsculas, CHECK),
--    uf_estimada (a UF veio da coordenada, não da Mapbox nem de local salvo) e a coluna gerada
--    interestadual = origem_uf <> 'RJ' OR destino_uf <> 'RJ' (nula quando não dá para saber:
--    as duas UFs desconhecidas, ou uma RJ e a outra desconhecida). Índice para o filtro.
-- 2. UF pela coordenada sem serviço externo: malha das 27 UFs do IBGE em lote_interno.malha_uf
--    (uf, poligonos jsonb no formato GeoJSON MultiPolygon) e lote_interno.malha_uf_aneis (cada
--    anel em vetores de latitude e longitude, com a caixa), baixada UMA vez da API de malhas do
--    IBGE, nunca desenhada à mão:
--      URL:  https://servicodados.ibge.gov.br/api/v3/malhas/paises/BR?formato=application/vnd.geo+json&qualidade=minima&intrarregiao=UF
--            (a mesma malha da rota por estado, /api/v3/malhas/estados/<código>, numa chamada só)
--      Data: 09/10/2026 11:09 (Brasília)
--      Cópia no repositório: database/dados/malha-uf-ibge-2026-10-09.json
--      sha256 07c671aa87aa1ab296c446de6294df9827112782537b996c0a160284907e7c0f (o JSON abaixo é
--      o conteúdo do arquivo, sem mudança)
--    lote_interno.uf_do_ponto(lat, lng): teste de raio (PL/pgSQL puro, sem PostGIS) nos anéis
--    cuja caixa contém o ponto, com paridade por polígono (buracos); dentro de mais de um
--    polígono, vence o de menor caixa. Devolve a UF, a distância aproximada até a divisa (até o
--    polígono de outra UF mais próximo, em km, projeção equirretangular na latitude do ponto;
--    o litoral não conta como divisa) e fora_da_malha. Ponto fora de todos os polígonos (baía,
--    ilha, litoral na malha mínima) recebe a UF do polígono mais próximo.
--    public.uf_da_coordenada(lat, lng): RPC para a Nova (pino movido, sugestão sem região),
--    STABLE, SECURITY DEFINER (lê lote_interno), qualquer perfil autenticado; zero linhas para
--    coordenada nula ou 0,0. As funções internas ficam no lote_interno, sem GRANT.
-- 3. Carga das escoltas existentes (lote_interno.carregar_uf_escoltas): UF pela coordenada, com
--    uf_estimada = true, só nas escoltas sem nenhuma UF gravada e com coordenada. ESC-2026-0001 e
--    ESC-2026-0007 ficam de fora (regra 1.11 e seção 0.8: nenhuma mudança nelas) e vão listadas
--    no relatório. Lado a menos de 5 km da divisa, ou fora da malha, vai para
--    backup_20261008.uf_a_conferir e para a lista do relatório. A carga não aciona a trigger da
--    215 (ela só olha endereço, coordenada e status) e muda atualizado_em das escoltas
--    atualizadas pela trigger existente, sem efeito de negócio. Roda a cada aplicação (só pega
--    quem continua sem UF; escolta criada pela master na janela entre o bloco 1 e o deploy
--    ganha a UF se a 216 for reaplicada).
-- 4. Paleta fechada de 12 cores para o cliente (decisão 6 e S6: não exclusiva), em
--    public.paleta_clientes (RLS ligada, sem policy e sem GRANT: só a trigger lê; o app tem a
--    mesma lista em lib/paleta-clientes.ts), com contraste de texto branco de pelo menos 4,5:1.
--    Trigger BEFORE INSERT OR UPDATE OF cor_destaque em clientes: cor #rrggbb (sem diferenciar
--    maiúscula) vira a mais próxima da paleta pela distância CIE76 no espaço Lab; texto que não
--    é #rrggbb (ou nulo) vira a cor padrão. Nunca erro, sem CHECK. DEFAULT da coluna trocado
--    para a cor padrão. Carga, só na primeira aplicação (quando a paleta nasce): clientes ativos,
--    na ordem de criação, cada um na cor da paleta mais próxima ainda livre (sem repetir
--    enquanto houver cor livre); os demais na mais próxima. A cor antiga fica em
--    backup_20261008.cores_clientes e as trocas saem em NOTICE e na conferência.
-- 5. Cor do cliente no mural do operador: public.cores_clientes_das_escoltas(ids) devolve só a
--    cor (nunca o nome) das escoltas que a pessoa já enxerga; a RLS de clientes esconde do
--    operador o cliente das agendadas de outra equipe, e o mural sairia todo na mesma cor.
-- 6. impedir_edicao_por_operador (197) recriada com origem_uf, destino_uf e uf_estimada na lista
--    de colunas que o operador não altera. A trava de escolta iniciada (214) já pega as colunas
--    novas por to_jsonb e ignora a coluna gerada.
--
-- Conferência:
-- SELECT count(*) FROM lote_interno.malha_uf;                                              -- 27
-- SELECT count(*), count(*) FILTER (WHERE padrao) FROM public.paleta_clientes;             -- 12, 1
-- SELECT codigo_escolta, origem_uf, destino_uf, uf_estimada FROM escoltas
--  WHERE codigo_escolta IN ('ESC-2026-0001', 'ESC-2026-0007');                             -- sem UF, false
-- SELECT count(*) FILTER (WHERE origem_uf IS NOT NULL OR destino_uf IS NOT NULL), count(*) FILTER (WHERE interestadual) FROM escoltas;
-- SELECT * FROM backup_20261008.uf_a_conferir ORDER BY codigo_escolta, lado;               -- lista do relatório
-- SELECT nome_cliente, cor_antiga, cor_nova FROM backup_20261008.cores_clientes ORDER BY nome_cliente;  -- trocas
-- SELECT has_function_privilege('authenticated', 'public.uf_da_coordenada(double precision, double precision)', 'EXECUTE');  -- true
-- Reversão: 216_uf_e_paleta_reverter.sql (guarda as UFs em backup_20261008.escoltas_uf, devolve
-- as cores do backup, tira colunas, triggers, funções, paleta e malha).

CREATE SCHEMA IF NOT EXISTS lote_interno;
REVOKE ALL ON SCHEMA lote_interno FROM PUBLIC, anon, authenticated;
CREATE SCHEMA IF NOT EXISTS backup_20261008;
REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;

-- A carga de cores só roda quando a paleta nasce (primeira aplicação, ou depois de uma reversão).
SELECT set_config('lote216.carregar_cores', CASE WHEN to_regclass('public.paleta_clientes') IS NULL THEN 'on' ELSE 'off' END, false);

-- ════════ 1. UF de origem e destino ════════
ALTER TABLE public.escoltas ADD COLUMN IF NOT EXISTS origem_uf text;
ALTER TABLE public.escoltas ADD COLUMN IF NOT EXISTS destino_uf text;
ALTER TABLE public.escoltas ADD COLUMN IF NOT EXISTS uf_estimada boolean NOT NULL DEFAULT false;
ALTER TABLE public.escoltas ADD COLUMN IF NOT EXISTS interestadual boolean
  GENERATED ALWAYS AS (origem_uf <> 'RJ' OR destino_uf <> 'RJ') STORED;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'escoltas_origem_uf_formato' AND conrelid = 'public.escoltas'::regclass) THEN
    ALTER TABLE public.escoltas ADD CONSTRAINT escoltas_origem_uf_formato CHECK (origem_uf ~ '^[A-Z]{2}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'escoltas_destino_uf_formato' AND conrelid = 'public.escoltas'::regclass) THEN
    ALTER TABLE public.escoltas ADD CONSTRAINT escoltas_destino_uf_formato CHECK (destino_uf ~ '^[A-Z]{2}$');
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_escoltas_interestadual ON public.escoltas (interestadual);
COMMENT ON COLUMN public.escoltas.uf_estimada IS 'Onda K: alguma das UFs veio da coordenada (malha do IBGE), não da Mapbox nem de local salvo. Na tela, só a etiqueta Interestadual, sem a UF por extenso.';
COMMENT ON COLUMN public.escoltas.interestadual IS 'Onda K: origem ou destino fora do RJ. Nula quando não dá para saber.';

-- ════════ 2. Malha das UFs (IBGE) ════════
CREATE TABLE IF NOT EXISTS lote_interno.malha_uf (
  uf          text PRIMARY KEY CHECK (uf ~ '^[A-Z]{2}$'),
  codigo_ibge text NOT NULL UNIQUE,
  poligonos   jsonb NOT NULL,
  min_lat double precision, max_lat double precision, min_lng double precision, max_lng double precision,
  area_caixa  double precision
);
CREATE TABLE IF NOT EXISTS lote_interno.malha_uf_aneis (
  uf       text NOT NULL REFERENCES lote_interno.malha_uf (uf) ON DELETE CASCADE,
  poligono integer NOT NULL,
  anel     integer NOT NULL,
  lats     double precision[] NOT NULL,
  lngs     double precision[] NOT NULL,
  min_lat double precision NOT NULL, max_lat double precision NOT NULL,
  min_lng double precision NOT NULL, max_lng double precision NOT NULL,
  PRIMARY KEY (uf, poligono, anel)
);
REVOKE ALL ON lote_interno.malha_uf, lote_interno.malha_uf_aneis FROM PUBLIC, anon, authenticated;

WITH dados AS (SELECT $malha${"type":"FeatureCollection", "features": [
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-62.4177,-13.1189],[-62.2785,-13.1555],[-62.2148,-13.1113],[-62.1152,-13.1637],[-62.1157,-13.2585],[-61.8874,-13.4408],[-61.8171,-13.5274],[-61.5789,-13.5099],[-61.4699,-13.5553],[-61.2483,-13.4963],[-61.1943,-13.5364],[-61.009,-13.5064],[-60.919,-13.5483],[-60.8798,-13.6175],[-60.7093,-13.693],[-60.6322,-13.5717],[-60.3879,-13.4547],[-60.3716,-13.3186],[-60.3332,-13.258],[-60.2676,-13.0773],[-60.1833,-12.9676],[-60.1172,-12.9596],[-60.0289,-12.6186],[-59.9477,-12.5993],[-59.7794,-12.3415],[-59.8868,-12.2451],[-59.8998,-12.1172],[-59.9794,-12.0295],[-59.9842,-11.9148],[-60.0989,-11.8456],[-60.1109,-11.5825],[-59.9344,-11.4237],[-59.9172,-11.3384],[-59.9797,-11.2395],[-59.9768,-11.1224],[-60.3916,-11.0938],[-60.4601,-10.9899],[-61.0006,-10.9922],[-61.429,-10.9875],[-61.5503,-10.9861],[-61.4766,-10.7666],[-61.4618,-10.4199],[-61.5533,-10.307],[-61.5849,-10.0616],[-61.5402,-10.0002],[-61.5079,-9.8611],[-61.5746,-9.7178],[-61.477,-9.6299],[-61.5817,-9.4591],[-61.6162,-9.3268],[-61.6283,-9.2571],[-61.5293,-9.2487],[-61.5558,-9.0924],[-61.4692,-8.9201],[-61.5831,-8.7987],[-61.7133,-8.6879],[-61.8365,-8.7327],[-61.903,-8.8629],[-61.9902,-8.8727],[-62.0311,-8.7997],[-62.125,-8.8017],[-62.1884,-8.5906],[-62.2689,-8.5758],[-62.2895,-8.6391],[-62.3661,-8.4936],[-62.3608,-8.3985],[-62.4655,-8.3397],[-62.5185,-8.3847],[-62.5619,-8.284],[-62.655,-8.2291],[-62.6923,-8.0929],[-62.8666,-7.9759],[-63.6212,-7.9765],[-63.6218,-8.0296],[-63.7486,-8.2079],[-63.7912,-8.3332],[-63.8708,-8.2888],[-63.9441,-8.3312],[-63.9732,-8.4784],[-63.9232,-8.5593],[-64.0355,-8.6936],[-64.1431,-8.743],[-64.1418,-8.9451],[-64.3113,-8.9965],[-64.3234,-8.9289],[-64.5789,-8.9884],[-64.6111,-9.0165],[-64.8078,-8.9856],[-64.9399,-9.1246],[-64.9197,-9.2203],[-65.0535,-9.4021],[-65.1429,-9.4468],[-65.2118,-9.279],[-65.2704,-9.2636],[-65.3935,-9.3396],[-65.4402,-9.3117],[-65.4321,-9.4586],[-65.5881,-9.4138],[-65.6794,-9.4514],[-65.73,-9.5631],[-65.8251,-9.5301],[-65.9703,-9.4132],[-66.1736,-9.4344],[-66.4089,-9.4069],[-66.3924,-9.5005],[-66.5006,-9.6336],[-66.6094,-9.6649],[-66.8103,-9.818],[-66.6269,-9.898],[-66.2133,-9.8343],[-66.152,-9.7856],[-65.9821,-9.8088],[-65.8859,-9.7525],[-65.7042,-9.7638],[-65.5541,-9.832],[-65.4434,-9.6693],[-65.3569,-9.7202],[-65.2887,-9.8657],[-65.333,-9.9443],[-65.2888,-10.2199],[-65.3918,-10.3744],[-65.3815,-10.4291],[-65.4297,-10.4809],[-65.4051,-10.6406],[-65.3436,-10.6996],[-65.3625,-10.8016],[-65.2756,-10.8712],[-65.2509,-10.9845],[-65.3635,-11.1473],[-65.3049,-11.5016],[-65.2119,-11.5305],[-65.2048,-11.7495],[-65.0905,-11.7078],[-65.0289,-11.9976],[-64.8396,-12.0107],[-64.6984,-12.1036],[-64.7129,-12.1736],[-64.5946,-12.2157],[-64.5128,-12.2229],[-64.5131,-12.3438],[-64.4062,-12.447],[-64.2345,-12.4555],[-63.9634,-12.5297],[-63.8873,-12.4473],[-63.6848,-12.4531],[-63.4372,-12.5644],[-63.2994,-12.6818],[-63.0906,-12.636],[-63.0071,-12.8396],[-62.8922,-12.8588],[-62.7944,-12.9952],[-62.6607,-12.9695],[-62.6126,-13.0413],[-62.4177,-13.1189]]]},"properties":{"codarea":"11"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-67.135,-9.6759],[-67.3255,-9.5925],[-67.326,-9.5923],[-67.5169,-9.5609],[-67.9768,-9.3527],[-68.2199,-9.2428],[-68.6472,-9.0494],[-68.9213,-8.8143],[-69.213,-8.5644],[-69.4443,-8.3665],[-69.8017,-8.0611],[-70.055,-7.8451],[-70.5152,-7.7924],[-71.0885,-7.7263],[-71.3817,-7.6923],[-71.9454,-7.6268],[-72.1695,-7.6006],[-72.5848,-7.552],[-72.9003,-7.4377],[-73.7382,-7.1347],[-73.8016,-7.1118],[-73.6989,-7.2957],[-73.8765,-7.3823],[-73.9671,-7.3598],[-73.9193,-7.4653],[-73.9833,-7.5662],[-73.8217,-7.7175],[-73.6935,-7.7709],[-73.704,-7.8726],[-73.7672,-7.8609],[-73.7288,-7.9691],[-73.6322,-8.059],[-73.537,-8.3455],[-73.3321,-8.4754],[-73.344,-8.6021],[-73.128,-8.7712],[-73.0562,-8.9069],[-72.9948,-8.9198],[-72.9402,-9.069],[-73.1008,-9.3042],[-73.2119,-9.4117],[-72.7197,-9.4117],[-72.518,-9.4916],[-72.3404,-9.5087],[-72.2529,-9.6228],[-72.2709,-9.7448],[-72.1529,-9.7968],[-72.1805,-10],[-71.3774,-10],[-71.2108,-9.9664],[-71.0777,-9.8277],[-70.9977,-9.8184],[-70.8688,-9.6646],[-70.7996,-9.6425],[-70.5698,-9.4322],[-70.5056,-9.4222],[-70.598,-9.6065],[-70.5247,-9.7153],[-70.6206,-9.8323],[-70.6206,-10.0793],[-70.6205,-10.425],[-70.6209,-10.7055],[-70.621,-10.9996],[-70.5301,-10.9348],[-70.4247,-11.0378],[-70.3022,-11.0688],[-70.161,-11.0426],[-69.9339,-10.9212],[-69.7357,-10.9745],[-69.4235,-10.9266],[-69.2326,-10.94],[-68.9121,-11.0217],[-68.7486,-11.0187],[-68.7161,-11.1456],[-68.543,-11.1114],[-68.3882,-11.0406],[-68.2394,-10.9578],[-68.0022,-10.6484],[-67.8641,-10.6408],[-67.7046,-10.7004],[-67.5673,-10.5095],[-67.3108,-10.3774],[-67.316,-10.3187],[-67.1778,-10.3394],[-67.0023,-10.2297],[-66.8986,-10.1114],[-66.6269,-9.898],[-66.8103,-9.818],[-67.135,-9.6759]]]},"properties":{"codarea":"12"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-58.1474,-7.3432],[-58.181,-7.1817],[-58.3354,-6.9864],[-58.4346,-6.9088],[-58.4818,-6.7814],[-58.4273,-6.6162],[-58.2667,-6.4756],[-57.8606,-5.6007],[-57.3502,-4.5018],[-56.9561,-3.6586],[-56.9138,-3.5623],[-56.8101,-3.333],[-56.7679,-3.2429],[-56.4021,-2.4565],[-56.4645,-2.4316],[-56.3892,-2.2785],[-56.2038,-2.1831],[-56.0987,-2.0269],[-56.2284,-2.0562],[-56.4139,-2.1759],[-56.5271,-2.1392],[-56.5856,-2.1765],[-56.6791,-2.2126],[-56.761,-2.1741],[-56.7479,-2.0115],[-56.859,-2.0159],[-57.0284,-1.918],[-57.0825,-1.7824],[-57.2586,-1.6969],[-57.3534,-1.7368],[-57.5881,-1.5806],[-57.6746,-1.595],[-57.7121,-1.5033],[-57.9597,-1.3969],[-57.9987,-1.3313],[-57.9658,-1.171],[-58.0333,-1.098],[-58.1561,-1.2328],[-58.2576,-1.1308],[-58.3167,-1.1477],[-58.4289,-1.0286],[-58.4342,-0.8922],[-58.6637,-0.7176],[-58.7351,-0.6128],[-58.7245,-0.4419],[-58.8695,-0.3475],[-58.8639,-0.078],[-58.895,-0.011],[-58.8955,0.2635],[-59.2634,0.2635],[-59.4336,0.2635],[-60.038,0.2635],[-60.2276,-0.1217],[-60.3943,-0.5508],[-60.3115,-0.7185],[-60.4978,-0.7807],[-60.5362,-0.8695],[-60.6691,-0.8879],[-60.762,-0.8486],[-60.8152,-0.6903],[-60.9336,-0.5479],[-61.2231,-0.4999],[-61.234,-0.5619],[-61.4581,-0.6547],[-61.5356,-0.7544],[-61.5808,-0.978],[-61.5429,-1.0622],[-61.6288,-1.3015],[-61.6191,-1.3948],[-61.5383,-1.4334],[-61.4747,-1.579],[-61.605,-1.4481],[-61.798,-1.3806],[-61.8399,-1.4011],[-61.8966,-1.3954],[-62.0175,-1.1417],[-62.1255,-1.0373],[-62.2591,-0.9759],[-62.3958,-0.8204],[-62.5102,-0.759],[-62.4866,-0.6815],[-62.357,-0.7024],[-62.2867,-0.6324],[-62.3184,-0.5446],[-62.1886,-0.3223],[-62.2481,-0.2963],[-62.2416,-0.1705],[-62.3198,-0.0963],[-62.3259,-0.0029],[-62.4093,0.0751],[-62.4527,0.2074],[-62.4464,0.3791],[-62.5187,0.4437],[-62.5383,0.6752],[-62.463,0.7769],[-62.4427,0.9585],[-62.4716,1.0863],[-62.5211,1.0838],[-62.64,1.4382],[-62.7363,1.5296],[-62.8053,1.5913],[-62.7286,1.7],[-62.7033,1.9338],[-62.8386,2.0164],[-63.0238,2.0147],[-63.1376,2.1611],[-63.2764,2.1544],[-63.3721,2.2119],[-63.3977,2.1469],[-63.5619,2.1324],[-63.8297,1.9682],[-63.9755,1.9913],[-64.0619,1.9307],[-64.0652,1.676],[-64.3261,1.436],[-64.4,1.3949],[-64.3975,1.5268],[-64.5533,1.4168],[-64.5908,1.3374],[-64.7639,1.2308],[-64.823,1.2785],[-64.9516,1.2315],[-65.0222,1.1149],[-65.1551,1.125],[-65.165,0.9505],[-65.3291,0.9316],[-65.443,0.6899],[-65.5405,0.6488],[-65.5914,0.7216],[-65.5003,0.8424],[-65.5856,1.0089],[-65.7394,0.9996],[-65.9254,0.8913],[-65.9644,0.8095],[-66.1511,0.7445],[-66.213,0.7806],[-66.3165,0.7361],[-66.3185,0.755],[-66.8569,1.2302],[-67.0882,1.1669],[-67.0723,1.4426],[-67.0974,1.7326],[-67.1571,1.8488],[-67.2781,1.8757],[-67.3893,2.244],[-67.5219,2.1703],[-67.6198,2.0237],[-67.7794,2.0311],[-67.9413,1.8307],[-68.0875,1.9013],[-68.1407,1.9848],[-68.2433,1.9267],[-68.2669,1.8273],[-68.1568,1.7316],[-69.3913,1.7296],[-69.5344,1.777],[-69.6538,1.7181],[-69.8458,1.7077],[-69.8466,1.0779],[-69.7026,1.1183],[-69.7035,1.075],[-69.3219,1.0884],[-69.2457,1.0465],[-69.1401,0.8838],[-69.1876,0.7469],[-69.1157,0.644],[-69.3498,0.6141],[-69.481,0.735],[-69.6281,0.6275],[-69.687,0.6632],[-69.8235,0.5911],[-70.0465,0.5621],[-70.0464,0.0683],[-70.0574,-0.1868],[-69.9232,-0.3315],[-69.8449,-0.3458],[-69.6111,-0.5135],[-69.5643,-0.6398],[-69.6264,-0.7497],[-69.5274,-0.922],[-69.4217,-1.0004],[-69.3984,-1.1444],[-69.4297,-1.3873],[-69.6134,-2.4402],[-69.8376,-3.6866],[-69.9507,-4.2693],[-70.0454,-4.3738],[-70.1328,-4.282],[-70.2004,-4.356],[-70.3079,-4.2468],[-70.2932,-4.1599],[-70.5221,-4.1373],[-70.6163,-4.1934],[-70.759,-4.1587],[-70.865,-4.2533],[-70.938,-4.3832],[-71.2665,-4.3845],[-71.2617,-4.4247],[-71.5023,-4.4386],[-71.6169,-4.5289],[-71.7788,-4.4847],[-71.9151,-4.5307],[-71.9476,-4.609],[-72.2421,-4.7804],[-72.3722,-4.8077],[-72.4146,-4.9009],[-72.5971,-4.9827],[-72.8871,-5.1616],[-72.8701,-5.2994],[-72.9638,-5.4981],[-72.9618,-5.6546],[-73.151,-5.8634],[-73.2502,-6.1449],[-73.1089,-6.41],[-73.213,-6.5778],[-73.3545,-6.5949],[-73.6428,-6.7621],[-73.7546,-6.9419],[-73.7268,-7.0225],[-73.8016,-7.1118],[-73.7382,-7.1347],[-72.9003,-7.4377],[-72.5848,-7.552],[-72.1695,-7.6006],[-71.9454,-7.6268],[-71.3817,-7.6923],[-71.0885,-7.7263],[-70.5152,-7.7924],[-70.055,-7.8451],[-69.8017,-8.0611],[-69.4443,-8.3665],[-69.213,-8.5644],[-68.9213,-8.8143],[-68.6472,-9.0494],[-68.2199,-9.2428],[-67.9768,-9.3527],[-67.5169,-9.5609],[-67.326,-9.5923],[-67.3255,-9.5925],[-67.135,-9.6759],[-66.8103,-9.818],[-66.6094,-9.6649],[-66.5006,-9.6336],[-66.3924,-9.5005],[-66.4089,-9.4069],[-66.1736,-9.4344],[-65.9703,-9.4132],[-65.8251,-9.5301],[-65.73,-9.5631],[-65.6794,-9.4514],[-65.5881,-9.4138],[-65.4321,-9.4586],[-65.4402,-9.3117],[-65.3935,-9.3396],[-65.2704,-9.2636],[-65.2118,-9.279],[-65.1429,-9.4468],[-65.0535,-9.4021],[-64.9197,-9.2203],[-64.9399,-9.1246],[-64.8078,-8.9856],[-64.6111,-9.0165],[-64.5789,-8.9884],[-64.3234,-8.9289],[-64.3113,-8.9965],[-64.1418,-8.9451],[-64.1431,-8.743],[-64.0355,-8.6936],[-63.9232,-8.5593],[-63.9732,-8.4784],[-63.9441,-8.3312],[-63.8708,-8.2888],[-63.7912,-8.3332],[-63.7486,-8.2079],[-63.6218,-8.0296],[-63.6212,-7.9765],[-62.8666,-7.9759],[-62.6923,-8.0929],[-62.655,-8.2291],[-62.5619,-8.284],[-62.5185,-8.3847],[-62.4655,-8.3397],[-62.3608,-8.3985],[-62.3661,-8.4936],[-62.2895,-8.6391],[-62.2689,-8.5758],[-62.1884,-8.5906],[-62.125,-8.8017],[-62.0311,-8.7997],[-61.9902,-8.8727],[-61.903,-8.8629],[-61.8365,-8.7327],[-61.7133,-8.6879],[-61.5831,-8.7987],[-60.4202,-8.7966],[-59.1274,-8.8033],[-58.4419,-8.7987],[-58.3284,-8.7122],[-58.4373,-8.7034],[-58.3895,-8.5948],[-58.4178,-8.4895],[-58.3149,-8.3231],[-58.2864,-8.0885],[-58.3782,-7.8274],[-58.2941,-7.7715],[-58.2022,-7.6209],[-58.2131,-7.4585],[-58.1371,-7.3561],[-58.1474,-7.3432]]]},"properties":{"codarea":"13"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-64.1844,3.4893],[-64.1179,3.3374],[-64.2187,3.0906],[-64.1446,3.0257],[-64.0147,2.8122],[-63.9862,2.6487],[-64.0617,2.5044],[-63.9601,2.4731],[-63.8458,2.4965],[-63.7619,2.4439],[-63.6036,2.4572],[-63.4657,2.4017],[-63.4147,2.4542],[-63.3554,2.3823],[-63.3721,2.2119],[-63.2764,2.1544],[-63.1376,2.1611],[-63.0238,2.0147],[-62.8386,2.0164],[-62.7033,1.9338],[-62.7286,1.7],[-62.8053,1.5913],[-62.7363,1.5296],[-62.64,1.4382],[-62.5211,1.0838],[-62.4716,1.0863],[-62.4427,0.9585],[-62.463,0.7769],[-62.5383,0.6752],[-62.5187,0.4437],[-62.4464,0.3791],[-62.4527,0.2074],[-62.4093,0.0751],[-62.3259,-0.0029],[-62.3198,-0.0963],[-62.2416,-0.1705],[-62.2481,-0.2963],[-62.1886,-0.3223],[-62.3184,-0.5446],[-62.2867,-0.6324],[-62.357,-0.7024],[-62.4866,-0.6815],[-62.5102,-0.759],[-62.3958,-0.8204],[-62.2591,-0.9759],[-62.1255,-1.0373],[-62.0175,-1.1417],[-61.8966,-1.3954],[-61.8399,-1.4011],[-61.798,-1.3806],[-61.605,-1.4481],[-61.4747,-1.579],[-61.5383,-1.4334],[-61.6191,-1.3948],[-61.6288,-1.3015],[-61.5429,-1.0622],[-61.5808,-0.978],[-61.5356,-0.7544],[-61.4581,-0.6547],[-61.234,-0.5619],[-61.2231,-0.4999],[-60.9336,-0.5479],[-60.8152,-0.6903],[-60.762,-0.8486],[-60.6691,-0.8879],[-60.5362,-0.8695],[-60.4978,-0.7807],[-60.3115,-0.7185],[-60.3943,-0.5508],[-60.2276,-0.1217],[-60.038,0.2635],[-59.4336,0.2635],[-59.2634,0.2635],[-58.8955,0.2635],[-58.8955,1.2277],[-58.9236,1.318],[-59.0486,1.3227],[-59.2533,1.3882],[-59.3299,1.5138],[-59.4127,1.5516],[-59.5336,1.7163],[-59.6902,1.7563],[-59.6624,1.8619],[-59.7461,1.8519],[-59.7344,1.9996],[-59.7404,2.2929],[-59.8444,2.321],[-59.9884,2.6798],[-59.9844,2.9288],[-59.9083,3.2119],[-59.8064,3.3539],[-59.8052,3.5098],[-59.8727,3.5638],[-59.6626,3.715],[-59.5265,3.9246],[-59.709,4.1619],[-59.7319,4.2865],[-59.6762,4.3469],[-59.7359,4.4237],[-59.972,4.5093],[-60.1615,4.5178],[-60.0259,4.7057],[-59.972,5.0749],[-60.0958,5.1407],[-60.1352,5.2482],[-60.2125,5.2718],[-60.3283,5.2055],[-60.5772,5.198],[-60.6972,5.2288],[-60.5841,4.9557],[-60.6524,4.8846],[-60.7509,4.7537],[-60.9476,4.6555],[-60.9979,4.5156],[-61.1493,4.4832],[-61.2698,4.5397],[-61.3516,4.4188],[-61.4483,4.4391],[-61.5083,4.3218],[-61.5619,4.251],[-61.7377,4.2568],[-61.8189,4.1677],[-61.9933,4.1749],[-62.1436,4.0752],[-62.3897,4.178],[-62.5527,4.1088],[-62.533,4.0474],[-62.7361,4.0399],[-62.7889,3.8932],[-62.7291,3.8046],[-62.7486,3.6727],[-62.8102,3.7327],[-62.9861,3.6099],[-63.0814,3.6932],[-63.0608,3.7518],[-63.2044,3.8116],[-63.205,3.9513],[-63.4522,3.9555],[-63.4119,3.9118],[-63.5111,3.8471],[-63.6769,4.0191],[-63.7141,3.9038],[-63.7569,3.9405],[-63.9261,3.926],[-63.9658,3.8682],[-64.1089,4.0855],[-64.1719,4.1288],[-64.4316,4.1346],[-64.5605,4.1016],[-64.7805,4.2866],[-64.8105,4.1746],[-64.4786,3.7832],[-64.2891,3.6996],[-64.1963,3.5789],[-64.1844,3.4893]]]},"properties":{"codarea":"14"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-48.1946,-4.911],[-48.0584,-4.8042],[-48.0254,-4.7783],[-47.8162,-4.6147],[-47.68,-4.6086],[-47.6152,-4.56],[-47.442,-4.2874],[-47.3718,-4.2456],[-47.3472,-4.1087],[-47.0887,-3.8616],[-47.0306,-3.6046],[-47.0383,-3.5643],[-46.9485,-3.4768],[-46.9443,-3.3772],[-46.8122,-3.3021],[-46.7689,-3.1765],[-46.6765,-3.0941],[-46.6811,-2.8936],[-46.5896,-2.8458],[-46.6696,-2.7346],[-46.6061,-2.6395],[-46.5068,-2.6169],[-46.4358,-2.4709],[-46.4394,-2.4132],[-46.4163,-2.2738],[-46.2833,-2.1544],[-46.2632,-2.0493],[-46.2234,-1.9149],[-46.211,-1.8311],[-46.31,-1.8063],[-46.3152,-1.7416],[-46.2112,-1.7272],[-46.1613,-1.6228],[-46.1761,-1.4774],[-46.1037,-1.3373],[-46.1616,-1.2819],[-46.1041,-1.202],[-46.0634,-1.1062],[-46.0946,-1.0206],[-46.1935,-1.0796],[-46.2076,-0.8856],[-46.3374,-1.0215],[-46.4691,-1.0253],[-46.4958,-0.8722],[-46.5313,-0.953],[-46.6364,-0.9691],[-46.6293,-0.8008],[-46.796,-0.8705],[-46.836,-0.7467],[-46.9426,-0.8593],[-46.9907,-0.7119],[-47.0637,-0.7946],[-47.092,-0.6741],[-47.1605,-0.7623],[-47.1747,-0.6729],[-47.2619,-0.6478],[-47.3863,-0.6047],[-47.426,-0.6573],[-47.4744,-0.5923],[-47.4816,-0.7391],[-47.5898,-0.5761],[-47.6081,-0.6978],[-47.6315,-0.7063],[-47.6327,-0.6021],[-47.7562,-0.6063],[-47.9171,-0.5664],[-47.977,-0.6862],[-48.0514,-0.6595],[-48.1416,-0.7542],[-48.1716,-0.8164],[-48.2938,-0.9197],[-48.4096,-0.9058],[-48.4747,-0.8739],[-48.5061,-0.7509],[-48.4411,-0.4122],[-48.3746,-0.3031],[-48.4288,-0.2272],[-48.7437,-0.2499],[-48.9179,-0.2296],[-49.1646,-0.1303],[-49.3826,-0.1915],[-49.4386,-0.1265],[-49.3589,-0.0259],[-49.397,0.0622],[-49.6322,0.0749],[-49.6996,0.1505],[-49.6333,0.2414],[-49.4886,0.3342],[-49.5732,0.4166],[-49.8892,0.3225],[-50.1678,0.3403],[-50.1727,0.3976],[-50.0364,0.5342],[-50.0726,0.6358],[-50.2261,0.6962],[-50.4099,0.6233],[-50.5997,0.2494],[-50.6448,0.2087],[-50.7435,0.1305],[-50.9748,0.0418],[-51.1184,-0.0975],[-51.2081,-0.117],[-51.3478,-0.2996],[-51.4325,-0.4733],[-51.5955,-0.6504],[-51.6835,-0.7955],[-51.7004,-1.0632],[-51.7784,-1.1404],[-51.8873,-1.1664],[-51.9656,-1.1258],[-52.111,-1.215],[-52.1203,-1.1462],[-52.333,-1.1159],[-52.4201,-1.0527],[-52.4555,-0.8303],[-52.5111,-0.8567],[-52.4974,-0.7113],[-52.5352,-0.5741],[-52.64,-0.5849],[-52.6954,-0.4964],[-52.6842,-0.3143],[-52.9327,-0.1423],[-52.9834,0.0334],[-53.0943,0.1953],[-53.1753,0.3817],[-53.1473,0.6003],[-53.1057,0.6795],[-53.4115,0.9293],[-53.4592,1.1337],[-53.4337,1.2345],[-53.5252,1.2117],[-53.5334,1.3224],[-53.8878,1.4078],[-53.896,1.4551],[-54.0887,1.492],[-54.1231,1.6074],[-54.3777,1.7637],[-54.4959,1.7469],[-54.6019,1.7846],[-54.7448,1.7758],[-54.756,1.9742],[-54.8113,2.0394],[-54.7631,2.2023],[-54.8723,2.4337],[-54.9543,2.5837],[-55.1031,2.5257],[-55.1729,2.5594],[-55.3203,2.5155],[-55.3854,2.4185],[-55.4998,2.4433],[-55.7077,2.4032],[-55.718,2.4021],[-55.9347,2.5335],[-56.0507,2.3351],[-56.139,2.2658],[-56.043,2.2279],[-55.9669,2.0885],[-55.9039,1.8881],[-55.999,1.8314],[-56.1527,1.8908],[-56.2415,1.8797],[-56.4371,1.9518],[-56.5798,1.906],[-56.721,1.9259],[-56.7881,1.8544],[-56.9198,1.9304],[-57.0008,1.9074],[-57.0868,2.0265],[-57.253,1.9485],[-57.3044,1.9975],[-57.4335,1.906],[-57.451,1.8064],[-57.5772,1.6904],[-57.7924,1.7267],[-57.7977,1.6873],[-57.9902,1.6585],[-58.0043,1.5031],[-58.1295,1.499],[-58.1607,1.5602],[-58.3172,1.5685],[-58.3719,1.4816],[-58.5088,1.463],[-58.458,1.3715],[-58.4963,1.268],[-58.7105,1.2899],[-58.7252,1.2188],[-58.8252,1.1713],[-58.8955,1.2277],[-58.8955,0.2635],[-58.895,-0.011],[-58.8639,-0.078],[-58.8695,-0.3475],[-58.7245,-0.4419],[-58.7351,-0.6128],[-58.6637,-0.7176],[-58.4342,-0.8922],[-58.4289,-1.0286],[-58.3167,-1.1477],[-58.2576,-1.1308],[-58.1561,-1.2328],[-58.0333,-1.098],[-57.9658,-1.171],[-57.9987,-1.3313],[-57.9597,-1.3969],[-57.7121,-1.5033],[-57.6746,-1.595],[-57.5881,-1.5806],[-57.3534,-1.7368],[-57.2586,-1.6969],[-57.0825,-1.7824],[-57.0284,-1.918],[-56.859,-2.0159],[-56.7479,-2.0115],[-56.761,-2.1741],[-56.6791,-2.2126],[-56.5856,-2.1765],[-56.5271,-2.1392],[-56.4139,-2.1759],[-56.2284,-2.0562],[-56.0987,-2.0269],[-56.2038,-2.1831],[-56.3892,-2.2785],[-56.4645,-2.4316],[-56.4021,-2.4565],[-56.7679,-3.2429],[-56.8101,-3.333],[-56.9138,-3.5623],[-56.9561,-3.6586],[-57.3502,-4.5018],[-57.8606,-5.6007],[-58.2667,-6.4756],[-58.4273,-6.6162],[-58.4818,-6.7814],[-58.4346,-6.9088],[-58.3354,-6.9864],[-58.181,-7.1817],[-58.1474,-7.3432],[-58.1371,-7.3561],[-58.0614,-7.3952],[-57.8967,-7.6779],[-57.8319,-7.9615],[-57.6417,-8.2199],[-57.6866,-8.407],[-57.6334,-8.5268],[-57.5929,-8.7565],[-57.4175,-8.7926],[-57.4162,-8.859],[-57.2038,-8.9208],[-57.0392,-9.0983],[-57.0598,-9.1824],[-56.9955,-9.2338],[-56.8201,-9.2463],[-56.7543,-9.4064],[-56.6719,-9.3674],[-56.2723,-9.4008],[-56.1565,-9.4104],[-55.8672,-9.4343],[-54.9956,-9.5053],[-54.6135,-9.5358],[-54.1068,-9.5719],[-53.5891,-9.611],[-53.1334,-9.6452],[-52.6193,-9.6823],[-52.2567,-9.7077],[-51.3043,-9.7729],[-50.846,-9.8006],[-50.2248,-9.8412],[-50.0909,-9.5328],[-50.0378,-9.2894],[-49.9669,-9.2311],[-49.8626,-9.0815],[-49.8514,-9.0637],[-49.6844,-8.8565],[-49.5924,-8.8395],[-49.4818,-8.6737],[-49.3996,-8.5451],[-49.3494,-8.4184],[-49.2833,-8.3796],[-49.221,-8.2038],[-49.1756,-8.0094],[-49.1673,-7.8564],[-49.1607,-7.7914],[-49.3423,-7.6558],[-49.361,-7.6149],[-49.378,-7.4964],[-49.264,-7.3642],[-49.1864,-7.1967],[-49.1938,-7.1298],[-49.1935,-7.0407],[-49.2095,-6.9254],[-49.0834,-6.8433],[-49.0376,-6.8093],[-48.8532,-6.7491],[-48.6663,-6.6642],[-48.6337,-6.4914],[-48.6261,-6.4785],[-48.5002,-6.3509],[-48.3757,-6.345],[-48.4361,-6.2014],[-48.3913,-6.1467],[-48.288,-6.0976],[-48.3347,-6.0043],[-48.2329,-5.9476],[-48.292,-5.8368],[-48.2757,-5.7265],[-48.1723,-5.7086],[-48.1382,-5.6027],[-48.3281,-5.4966],[-48.3735,-5.4027],[-48.4415,-5.408],[-48.5967,-5.4225],[-48.7552,-5.3492],[-48.4519,-5.1122],[-48.2124,-4.9249],[-48.1946,-4.911]]]},"properties":{"codarea":"15"}},
{"type":"Feature","geometry":{"type":"MultiPolygon","coordinates":[[[[-50.684,2.1437],[-50.7942,2.4985],[-50.827,2.5128],[-50.8873,2.7462],[-50.9542,2.8372],[-51.0328,3.2137],[-51.1093,3.4506],[-51.0818,3.5595],[-51.0807,3.8848],[-51.1508,3.9138],[-51.2164,4.15],[-51.2834,4.2503],[-51.4859,4.4372],[-51.6376,4.5088],[-51.6768,4.3327],[-51.6231,4.2256],[-51.6561,4.0539],[-51.7823,3.9641],[-51.7986,3.887],[-51.9726,3.7055],[-51.9888,3.6269],[-52.2336,3.2407],[-52.3529,3.1265],[-52.3269,3.0805],[-52.4778,2.7818],[-52.5521,2.52],[-52.6606,2.374],[-52.8422,2.2912],[-52.9043,2.1885],[-53.0845,2.2127],[-53.2792,2.186],[-53.2295,2.2624],[-53.3233,2.3471],[-53.4731,2.2567],[-53.7488,2.3128],[-53.7672,2.3789],[-53.9424,2.2424],[-54.1891,2.1788],[-54.4366,2.2099],[-54.6017,2.3372],[-54.6921,2.3614],[-54.744,2.4715],[-54.8723,2.4337],[-54.7631,2.2023],[-54.8113,2.0394],[-54.756,1.9742],[-54.7448,1.7758],[-54.6019,1.7846],[-54.4959,1.7469],[-54.3777,1.7637],[-54.1231,1.6074],[-54.0887,1.492],[-53.896,1.4551],[-53.8878,1.4078],[-53.5334,1.3224],[-53.5252,1.2117],[-53.4337,1.2345],[-53.4592,1.1337],[-53.4115,0.9293],[-53.1057,0.6795],[-53.1473,0.6003],[-53.1753,0.3817],[-53.0943,0.1953],[-52.9834,0.0334],[-52.9327,-0.1423],[-52.6842,-0.3143],[-52.6954,-0.4964],[-52.64,-0.5849],[-52.5352,-0.5741],[-52.4974,-0.7113],[-52.5111,-0.8567],[-52.4555,-0.8303],[-52.4201,-1.0527],[-52.333,-1.1159],[-52.1203,-1.1462],[-52.111,-1.215],[-51.9656,-1.1258],[-51.8873,-1.1664],[-51.7784,-1.1404],[-51.7004,-1.0632],[-51.6835,-0.7955],[-51.5955,-0.6504],[-51.4325,-0.4733],[-51.3478,-0.2996],[-51.2081,-0.117],[-51.1184,-0.0975],[-50.9748,0.0418],[-50.7435,0.1305],[-50.6448,0.2087],[-50.5997,0.2494],[-50.4099,0.6233],[-50.2261,0.6962],[-49.9884,0.8748],[-49.989,0.9395],[-49.8898,1.0136],[-49.9016,1.2403],[-49.8817,1.5001],[-49.9206,1.6879],[-50.1587,1.8112],[-50.4237,1.8045],[-50.684,2.1437]]],[[[-50.5088,2.1852],[-50.5077,2.0999],[-50.4226,2.1185],[-50.5088,2.1852]]],[[[-50.4501,2.1092],[-50.5212,2.0054],[-50.4549,1.8885],[-50.3174,1.9475],[-50.3608,2.0574],[-50.4501,2.1092]]]]},"properties":{"codarea":"16"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-47.4303,-6.4226],[-47.3807,-6.25],[-47.4302,-6.0684],[-47.4394,-6.0118],[-47.4379,-5.8571],[-47.4423,-5.8308],[-47.4769,-5.6373],[-47.4797,-5.6217],[-47.5603,-5.4632],[-47.6804,-5.4154],[-47.8275,-5.3866],[-47.8667,-5.3053],[-47.9373,-5.2396],[-48.0147,-5.238],[-48.0691,-5.2715],[-48.1849,-5.257],[-48.225,-5.2355],[-48.3639,-5.1684],[-48.4872,-5.1939],[-48.5611,-5.2302],[-48.6061,-5.3365],[-48.7552,-5.3492],[-48.5967,-5.4225],[-48.4415,-5.408],[-48.3735,-5.4027],[-48.3281,-5.4966],[-48.1382,-5.6027],[-48.1723,-5.7086],[-48.2757,-5.7265],[-48.292,-5.8368],[-48.2329,-5.9476],[-48.3347,-6.0043],[-48.288,-6.0976],[-48.3913,-6.1467],[-48.4361,-6.2014],[-48.3757,-6.345],[-48.5002,-6.3509],[-48.6261,-6.4785],[-48.6337,-6.4914],[-48.6663,-6.6642],[-48.8532,-6.7491],[-49.0376,-6.8093],[-49.0834,-6.8433],[-49.2095,-6.9254],[-49.1935,-7.0407],[-49.1938,-7.1298],[-49.1864,-7.1967],[-49.264,-7.3642],[-49.378,-7.4964],[-49.361,-7.6149],[-49.3423,-7.6558],[-49.1607,-7.7914],[-49.1673,-7.8564],[-49.1756,-8.0094],[-49.221,-8.2038],[-49.2833,-8.3796],[-49.3494,-8.4184],[-49.3996,-8.5451],[-49.4818,-8.6737],[-49.5924,-8.8395],[-49.6844,-8.8565],[-49.8514,-9.0637],[-49.8626,-9.0815],[-49.9669,-9.2311],[-50.0378,-9.2894],[-50.0909,-9.5328],[-50.2248,-9.8412],[-50.3026,-10.0354],[-50.3983,-10.1555],[-50.4181,-10.3546],[-50.4737,-10.4049],[-50.5414,-10.6093],[-50.6033,-10.6598],[-50.6035,-10.6609],[-50.5706,-10.7525],[-50.6326,-10.9319],[-50.6095,-11.0674],[-50.6999,-11.3131],[-50.7389,-11.5445],[-50.6701,-11.5816],[-50.7173,-11.7274],[-50.6393,-11.8846],[-50.6822,-11.9909],[-50.6814,-12.2169],[-50.6437,-12.223],[-50.6236,-12.4553],[-50.6839,-12.6481],[-50.6227,-12.8197],[-50.511,-12.8609],[-50.4342,-12.6494],[-50.3055,-12.4924],[-50.1418,-12.3954],[-50.2152,-12.482],[-50.1934,-12.5638],[-50.2448,-12.5975],[-50.3108,-12.7916],[-50.1852,-12.8936],[-49.9088,-12.9751],[-49.3683,-13.2723],[-49.3556,-13.1561],[-49.2377,-12.8838],[-49.1177,-12.7901],[-48.9762,-12.9579],[-48.8798,-12.8171],[-48.8703,-12.8033],[-48.6447,-13.011],[-48.5759,-13.1242],[-48.5801,-13.3133],[-48.5161,-13.1391],[-48.4589,-13.2804],[-48.1437,-13.1525],[-48.1699,-13.3003],[-48.0745,-13.239],[-47.9668,-13.315],[-47.7982,-13.329],[-47.6797,-13.4682],[-47.6223,-13.3687],[-47.6651,-13.2184],[-47.5687,-13.1169],[-47.3929,-13.2624],[-46.8548,-13.0676],[-46.7506,-12.9692],[-46.6354,-12.9699],[-46.4546,-12.9712],[-46.4459,-12.9358],[-46.418,-12.8224],[-46.3644,-12.9907],[-46.113,-12.918],[-46.328,-12.9547],[-46.2824,-12.7639],[-46.2967,-12.5757],[-46.1983,-12.5041],[-46.1982,-12.504],[-46.2666,-12.5067],[-46.29,-12.377],[-46.3716,-12.3498],[-46.3712,-12.0997],[-46.3889,-12.0488],[-46.3128,-11.9411],[-46.381,-11.8631],[-46.3376,-11.8131],[-46.3786,-11.7486],[-46.3078,-11.6866],[-46.3617,-11.631],[-46.1445,-11.6243],[-46.0809,-11.624],[-46.1128,-11.606],[-46.3504,-11.5062],[-46.4393,-11.521],[-46.5599,-11.3716],[-46.553,-11.2654],[-46.3416,-10.939],[-46.2673,-10.9348],[-46.2605,-10.812],[-46.2062,-10.8005],[-46.1276,-10.6206],[-45.8202,-10.4561],[-45.7982,-10.3232],[-45.6993,-10.2586],[-45.7235,-10.1554],[-45.744,-10.24],[-45.8967,-10.2643],[-45.9109,-10.3711],[-46.0124,-10.2507],[-46.0232,-10.1834],[-46.1949,-10.183],[-46.3248,-10.1832],[-46.4452,-10.0774],[-46.4751,-9.9045],[-46.5129,-9.7975],[-46.6444,-9.7403],[-46.5924,-9.5872],[-46.5392,-9.5601],[-46.6328,-9.4116],[-46.7543,-9.4138],[-46.8471,-9.2924],[-46.8196,-9.2116],[-46.9263,-9.1349],[-46.9403,-9.0637],[-47.0687,-9.0639],[-47.0383,-9.0006],[-46.9181,-8.857],[-46.9032,-8.5932],[-46.8461,-8.534],[-46.7824,-8.3681],[-46.7267,-8.3831],[-46.544,-8.3174],[-46.4657,-8.0727],[-46.5012,-7.9732],[-46.6086,-7.893],[-46.8066,-7.951],[-47.0148,-8.0588],[-47.1902,-7.8421],[-47.2467,-7.8086],[-47.4298,-7.5472],[-47.5028,-7.4391],[-47.5916,-7.4401],[-47.4782,-7.3368],[-47.5429,-7.2654],[-47.6507,-7.3023],[-47.684,-7.2454],[-47.7451,-7.1625],[-47.6604,-7.1514],[-47.5471,-7.0167],[-47.5205,-6.8405],[-47.4962,-6.6972],[-47.4651,-6.5815],[-47.4252,-6.4974],[-47.4303,-6.4226]]]},"properties":{"codarea":"17"}},
{"type":"Feature","geometry":{"type":"MultiPolygon","coordinates":[[[[-48.0254,-4.7783],[-48.0584,-4.8042],[-48.1946,-4.911],[-48.2124,-4.9249],[-48.4519,-5.1122],[-48.7552,-5.3492],[-48.6061,-5.3365],[-48.5611,-5.2302],[-48.4872,-5.1939],[-48.3639,-5.1684],[-48.225,-5.2355],[-48.1849,-5.257],[-48.0691,-5.2715],[-48.0147,-5.238],[-47.9373,-5.2396],[-47.8667,-5.3053],[-47.8275,-5.3866],[-47.6804,-5.4154],[-47.5603,-5.4632],[-47.4797,-5.6217],[-47.4769,-5.6373],[-47.4423,-5.8308],[-47.4379,-5.8571],[-47.4394,-6.0118],[-47.4302,-6.0684],[-47.3807,-6.25],[-47.4303,-6.4226],[-47.4252,-6.4974],[-47.4651,-6.5815],[-47.4962,-6.6972],[-47.5205,-6.8405],[-47.5471,-7.0167],[-47.6604,-7.1514],[-47.7451,-7.1625],[-47.684,-7.2454],[-47.6507,-7.3023],[-47.5429,-7.2654],[-47.4782,-7.3368],[-47.5916,-7.4401],[-47.5028,-7.4391],[-47.4298,-7.5472],[-47.2467,-7.8086],[-47.1902,-7.8421],[-47.0148,-8.0588],[-46.8066,-7.951],[-46.6086,-7.893],[-46.5012,-7.9732],[-46.4657,-8.0727],[-46.544,-8.3174],[-46.7267,-8.3831],[-46.7824,-8.3681],[-46.8461,-8.534],[-46.9032,-8.5932],[-46.9181,-8.857],[-47.0383,-9.0006],[-47.0687,-9.0639],[-46.9403,-9.0637],[-46.9263,-9.1349],[-46.8196,-9.2116],[-46.8471,-9.2924],[-46.7543,-9.4138],[-46.6328,-9.4116],[-46.5392,-9.5601],[-46.5924,-9.5872],[-46.6444,-9.7403],[-46.5129,-9.7975],[-46.4751,-9.9045],[-46.4452,-10.0774],[-46.3248,-10.1832],[-46.1949,-10.183],[-46.0232,-10.1834],[-46.0124,-10.2507],[-45.9463,-10.2585],[-45.8425,-9.9395],[-45.866,-9.8716],[-45.8297,-9.6799],[-45.8419,-9.5629],[-45.7911,-9.4828],[-45.8937,-9.3426],[-45.9362,-9.0383],[-45.9951,-8.927],[-45.9384,-8.7868],[-45.8408,-8.7158],[-45.7064,-8.3876],[-45.6636,-8.2505],[-45.5837,-8.1569],[-45.5208,-7.8873],[-45.5383,-7.8616],[-45.4558,-7.67],[-45.3407,-7.5818],[-45.0856,-7.5023],[-44.9893,-7.4824],[-44.9853,-7.481],[-44.8173,-7.3615],[-44.6904,-7.3958],[-44.5653,-7.2287],[-44.3861,-7.1209],[-44.3129,-7.1186],[-44.276,-7.0581],[-44.2493,-7.0005],[-44.1163,-6.8058],[-43.9305,-6.7711],[-43.7538,-6.7035],[-43.6375,-6.7196],[-43.4886,-6.8215],[-43.4546,-6.846],[-43.3912,-6.8342],[-43.2479,-6.7677],[-42.9928,-6.7487],[-42.9151,-6.648],[-42.8864,-6.5046],[-42.8473,-6.2782],[-42.9784,-6.1385],[-43.0491,-6.1016],[-43.0964,-5.9097],[-43.0751,-5.865],[-43.0949,-5.6149],[-43.0042,-5.5427],[-42.9684,-5.4535],[-42.8158,-5.318],[-42.799,-5.1897],[-42.8898,-4.8947],[-42.8927,-4.888],[-42.9531,-4.6874],[-42.8501,-4.498],[-42.9486,-4.3855],[-42.9643,-4.3607],[-42.9864,-4.2205],[-42.9428,-4.1673],[-42.856,-4.0794],[-42.7906,-3.9791],[-42.7217,-3.8844],[-42.6715,-3.7916],[-42.6835,-3.6945],[-42.6331,-3.6321],[-42.6167,-3.6107],[-42.5627,-3.5594],[-42.4964,-3.4459],[-42.4703,-3.4838],[-42.3999,-3.4748],[-42.2727,-3.4447],[-42.2017,-3.4313],[-42.1258,-3.3464],[-42.1236,-3.2668],[-41.9856,-3.2225],[-41.9798,-3.216],[-41.8691,-3.0603],[-41.7967,-2.9606],[-41.8344,-2.9156],[-41.826,-2.7573],[-41.8072,-2.73],[-42.043,-2.7296],[-42.0713,-2.687],[-42.2226,-2.6922],[-42.2636,-2.7579],[-42.4876,-2.7033],[-42.6415,-2.6253],[-43.0148,-2.4567],[-43.2374,-2.3587],[-43.3116,-2.3387],[-43.3781,-2.3422],[-43.4833,-2.3853],[-43.4617,-2.4864],[-43.5374,-2.4219],[-43.5786,-2.5061],[-43.6968,-2.5149],[-43.7412,-2.4351],[-43.6446,-2.4013],[-43.5943,-2.2827],[-43.7204,-2.2914],[-43.7619,-2.4187],[-43.8381,-2.4167],[-43.8502,-2.51],[-43.9312,-2.5616],[-44.0788,-2.7438],[-44.1484,-2.7681],[-44.2658,-2.7604],[-44.1757,-2.7021],[-44.0928,-2.5747],[-44.0362,-2.5567],[-44.0523,-2.4661],[-44.0318,-2.4063],[-44.1738,-2.458],[-44.1837,-2.461],[-44.2208,-2.4739],[-44.3046,-2.4875],[-44.41,-2.7992],[-44.4248,-2.9439],[-44.4955,-3.026],[-44.5481,-3.0451],[-44.5916,-3.0409],[-44.6625,-3.0129],[-44.652,-2.893],[-44.6501,-2.805],[-44.5553,-2.5965],[-44.358,-2.3405],[-44.4626,-2.145],[-44.6444,-2.2963],[-44.6777,-2.2805],[-44.4973,-2.0253],[-44.5777,-2.0292],[-44.4821,-1.9883],[-44.5517,-1.8885],[-44.5341,-1.8222],[-44.6153,-1.7633],[-44.7594,-1.783],[-44.7016,-1.725],[-44.7998,-1.7043],[-44.6363,-1.6166],[-44.7234,-1.5567],[-44.8537,-1.6175],[-44.8899,-1.6036],[-44.8604,-1.4113],[-44.9531,-1.56],[-45.0082,-1.4856],[-45.196,-1.4881],[-45.2682,-1.5986],[-45.3238,-1.597],[-45.3086,-1.3329],[-45.4755,-1.4798],[-45.5144,-1.3081],[-45.6108,-1.2746],[-45.6899,-1.2736],[-45.7813,-1.1926],[-45.7891,-1.1873],[-45.7965,-1.1826],[-45.8467,-1.213],[-45.8539,-1.0528],[-45.954,-1.2022],[-45.9946,-1.053],[-46.1041,-1.202],[-46.1616,-1.2819],[-46.1037,-1.3373],[-46.1761,-1.4774],[-46.1613,-1.6228],[-46.2112,-1.7272],[-46.3152,-1.7416],[-46.31,-1.8063],[-46.211,-1.8311],[-46.2234,-1.9149],[-46.2632,-2.0493],[-46.2833,-2.1544],[-46.4163,-2.2738],[-46.4394,-2.4132],[-46.4358,-2.4709],[-46.5068,-2.6169],[-46.6061,-2.6395],[-46.6696,-2.7346],[-46.5896,-2.8458],[-46.6811,-2.8936],[-46.6765,-3.0941],[-46.7689,-3.1765],[-46.8122,-3.3021],[-46.9443,-3.3772],[-46.9485,-3.4768],[-47.0383,-3.5643],[-47.0306,-3.6046],[-47.0887,-3.8616],[-47.3472,-4.1087],[-47.3718,-4.2456],[-47.442,-4.2874],[-47.6152,-4.56],[-47.68,-4.6086],[-47.8162,-4.6147],[-48.0254,-4.7783]]],[[[-44.4815,-2.7266],[-44.5862,-2.8147],[-44.6381,-2.981],[-44.5609,-3.0225],[-44.479,-2.9579],[-44.4815,-2.7266]]],[[[-44.9662,-1.2711],[-45.0288,-1.318],[-44.9891,-1.4016],[-44.8669,-1.3287],[-44.9662,-1.2711]]]]},"properties":{"codarea":"21"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-40.7643,-8.244],[-40.6039,-8.1037],[-40.5757,-8.0305],[-40.5757,-8.0304],[-40.5607,-7.9973],[-40.5439,-7.9616],[-40.5549,-7.8184],[-40.6736,-7.7617],[-40.6218,-7.6583],[-40.7149,-7.4806],[-40.6523,-7.4333],[-40.5485,-7.3927],[-40.5237,-7.3185],[-40.5061,-7.2109],[-40.4594,-7.0785],[-40.425,-6.9353],[-40.3705,-6.8032],[-40.4769,-6.7328],[-40.7102,-6.6761],[-40.7364,-6.6003],[-40.7899,-6.5006],[-40.7791,-6.3413],[-40.8522,-6.2242],[-40.8577,-6.1054],[-40.9063,-6.0465],[-40.8736,-5.9731],[-40.9098,-5.7657],[-40.9078,-5.6423],[-40.9293,-5.4931],[-40.937,-5.4387],[-40.929,-5.1717],[-41.0801,-5.0911],[-41.1212,-5.0239],[-41.2496,-4.8697],[-41.2332,-4.8101],[-41.175,-4.6653],[-41.2398,-4.5736],[-41.1776,-4.4677],[-41.1491,-4.3672],[-41.1194,-4.3243],[-41.0991,-4.1818],[-41.0981,-4.1805],[-41.1394,-4.121],[-41.1829,-4.018],[-41.2289,-3.9681],[-41.2457,-3.8964],[-41.2393,-3.7128],[-41.3342,-3.684],[-41.3672,-3.5617],[-41.303,-3.4922],[-41.324,-3.3859],[-41.4144,-3.3499],[-41.3225,-3.1798],[-41.2609,-3.0538],[-41.2715,-2.9707],[-41.3227,-2.9213],[-41.4362,-2.906],[-41.6496,-2.8644],[-41.7818,-2.7583],[-41.826,-2.7573],[-41.8344,-2.9156],[-41.7967,-2.9606],[-41.8691,-3.0603],[-41.9798,-3.216],[-41.9856,-3.2225],[-42.1236,-3.2668],[-42.1258,-3.3464],[-42.2017,-3.4313],[-42.2727,-3.4447],[-42.3999,-3.4748],[-42.4703,-3.4838],[-42.4964,-3.4459],[-42.5627,-3.5594],[-42.6167,-3.6107],[-42.6331,-3.6321],[-42.6835,-3.6945],[-42.6715,-3.7916],[-42.7217,-3.8844],[-42.7906,-3.9791],[-42.856,-4.0794],[-42.9428,-4.1673],[-42.9864,-4.2205],[-42.9643,-4.3607],[-42.9486,-4.3855],[-42.8501,-4.498],[-42.9531,-4.6874],[-42.8927,-4.888],[-42.8898,-4.8947],[-42.799,-5.1897],[-42.8158,-5.318],[-42.9684,-5.4535],[-43.0042,-5.5427],[-43.0949,-5.6149],[-43.0751,-5.865],[-43.0964,-5.9097],[-43.0491,-6.1016],[-42.9784,-6.1385],[-42.8473,-6.2782],[-42.8864,-6.5046],[-42.9151,-6.648],[-42.9928,-6.7487],[-43.2479,-6.7677],[-43.3912,-6.8342],[-43.4546,-6.846],[-43.4886,-6.8215],[-43.6375,-6.7196],[-43.7538,-6.7035],[-43.9305,-6.7711],[-44.1163,-6.8058],[-44.2493,-7.0005],[-44.276,-7.0581],[-44.3129,-7.1186],[-44.3861,-7.1209],[-44.5653,-7.2287],[-44.6904,-7.3958],[-44.8173,-7.3615],[-44.9853,-7.481],[-44.9893,-7.4824],[-45.0856,-7.5023],[-45.3407,-7.5818],[-45.4558,-7.67],[-45.5383,-7.8616],[-45.5208,-7.8873],[-45.5837,-8.1569],[-45.6636,-8.2505],[-45.7064,-8.3876],[-45.8408,-8.7158],[-45.9384,-8.7868],[-45.9951,-8.927],[-45.9362,-9.0383],[-45.8937,-9.3426],[-45.7911,-9.4828],[-45.8419,-9.5629],[-45.8297,-9.6799],[-45.866,-9.8716],[-45.8425,-9.9395],[-45.9463,-10.2585],[-46.0124,-10.2507],[-45.9109,-10.3711],[-45.8967,-10.2643],[-45.744,-10.24],[-45.7235,-10.1554],[-45.6032,-10.108],[-45.5566,-10.2169],[-45.4907,-10.301],[-45.396,-10.445],[-45.4474,-10.5094],[-45.4145,-10.6451],[-45.246,-10.8225],[-45.0821,-10.8395],[-44.9447,-10.919],[-44.8638,-10.8852],[-44.6668,-10.7589],[-44.6688,-10.6871],[-44.5778,-10.6268],[-44.5005,-10.6497],[-44.3444,-10.5497],[-44.1655,-10.6429],[-44.0834,-10.5891],[-43.9902,-10.418],[-43.9159,-10.3931],[-43.8369,-10.3022],[-43.7592,-10.0746],[-43.6927,-10.0594],[-43.7082,-9.9198],[-43.6525,-9.8436],[-43.7849,-9.7624],[-43.8497,-9.5481],[-43.7862,-9.4576],[-43.7822,-9.4527],[-43.606,-9.3516],[-43.5409,-9.3082],[-43.4381,-9.2661],[-43.2851,-9.42],[-43.2186,-9.4006],[-43.0745,-9.4],[-43.0593,-9.397],[-42.9587,-9.4284],[-42.9514,-9.5104],[-42.77,-9.6192],[-42.6901,-9.5459],[-42.6029,-9.5168],[-42.4931,-9.4949],[-42.3161,-9.3166],[-42.2261,-9.2833],[-42.0692,-9.2575],[-41.9139,-9.2771],[-41.8547,-9.2407],[-41.7327,-9.0877],[-41.7236,-9.0135],[-41.5456,-8.9417],[-41.4114,-8.7744],[-41.3813,-8.7073],[-41.3583,-8.7076],[-41.2065,-8.6333],[-41.1495,-8.5339],[-40.9785,-8.3987],[-40.9269,-8.4463],[-40.8618,-8.3707],[-40.7801,-8.2963],[-40.7643,-8.244]]]},"properties":{"codarea":"22"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-40.3719,-2.8124],[-40.455,-2.8034],[-40.5901,-2.8464],[-40.7604,-2.8488],[-41.1017,-2.9009],[-41.2712,-2.8872],[-41.3227,-2.9213],[-41.2715,-2.9707],[-41.2609,-3.0538],[-41.3225,-3.1798],[-41.4144,-3.3499],[-41.324,-3.3859],[-41.303,-3.4922],[-41.3672,-3.5617],[-41.3342,-3.684],[-41.2393,-3.7128],[-41.2457,-3.8964],[-41.2289,-3.9681],[-41.1829,-4.018],[-41.1394,-4.121],[-41.0981,-4.1805],[-41.0991,-4.1818],[-41.1194,-4.3243],[-41.1491,-4.3672],[-41.1776,-4.4677],[-41.2398,-4.5736],[-41.175,-4.6653],[-41.2332,-4.8101],[-41.2496,-4.8697],[-41.1212,-5.0239],[-41.0801,-5.0911],[-40.929,-5.1717],[-40.937,-5.4387],[-40.9293,-5.4931],[-40.9078,-5.6423],[-40.9098,-5.7657],[-40.8736,-5.9731],[-40.9063,-6.0465],[-40.8577,-6.1054],[-40.8522,-6.2242],[-40.7791,-6.3413],[-40.7899,-6.5006],[-40.7364,-6.6003],[-40.7102,-6.6761],[-40.4769,-6.7328],[-40.3705,-6.8032],[-40.425,-6.9353],[-40.4594,-7.0785],[-40.5061,-7.2109],[-40.5237,-7.3185],[-40.4336,-7.3672],[-40.3454,-7.3292],[-40.242,-7.318],[-40.1571,-7.3715],[-39.9046,-7.3383],[-39.8901,-7.3398],[-39.7413,-7.3268],[-39.5992,-7.4287],[-39.5459,-7.4839],[-39.4607,-7.4712],[-39.4476,-7.5722],[-39.3919,-7.6082],[-39.3696,-7.6193],[-39.2664,-7.6648],[-39.1466,-7.7182],[-39.1026,-7.771],[-39.093,-7.8576],[-39.018,-7.8127],[-38.966,-7.8456],[-38.9621,-7.8442],[-38.8948,-7.7505],[-38.7176,-7.6269],[-38.7151,-7.6219],[-38.683,-7.5787],[-38.5494,-7.335],[-38.5544,-7.2519],[-38.62,-7.2201],[-38.6442,-7.1838],[-38.6698,-7.0477],[-38.6738,-7.0462],[-38.765,-6.9939],[-38.7652,-6.9109],[-38.6717,-6.8471],[-38.6139,-6.7824],[-38.6524,-6.7571],[-38.6725,-6.7062],[-38.6491,-6.6276],[-38.6071,-6.5295],[-38.6105,-6.5323],[-38.5384,-6.4213],[-38.5625,-6.3557],[-38.5704,-6.293],[-38.5197,-6.223],[-38.466,-6.1214],[-38.4048,-6.0573],[-38.3396,-6.0777],[-38.2749,-6.0658],[-38.2522,-6.0102],[-38.1635,-5.9389],[-38.1593,-5.9246],[-38.0586,-5.7549],[-38.0828,-5.6724],[-38.0281,-5.6233],[-37.9022,-5.5007],[-37.8128,-5.3166],[-37.7869,-5.2972],[-37.7848,-5.2402],[-37.7882,-5.2192],[-37.6771,-5.0523],[-37.6403,-4.9264],[-37.4671,-4.8859],[-37.4464,-4.881],[-37.3569,-4.8581],[-37.2527,-4.8314],[-37.3259,-4.7003],[-37.5404,-4.6447],[-37.6031,-4.6173],[-37.7695,-4.4264],[-37.8451,-4.3817],[-38.1477,-4.1021],[-38.2233,-4.0072],[-38.4018,-3.8238],[-38.4638,-3.7072],[-38.5876,-3.6964],[-38.6524,-3.6822],[-38.8066,-3.5485],[-38.9321,-3.4654],[-39.0646,-3.4067],[-39.1648,-3.3262],[-39.257,-3.2195],[-39.3793,-3.1833],[-39.5506,-3.0792],[-39.721,-2.9969],[-39.9424,-2.8664],[-40.1853,-2.8117],[-40.3719,-2.8124]]]},"properties":{"codarea":"23"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-36.5044,-6.3865],[-36.344,-6.3025],[-36.295,-6.2921],[-36.2791,-6.3176],[-36.2963,-6.3704],[-36.2265,-6.434],[-36.1745,-6.4308],[-36.0965,-6.4203],[-36.0961,-6.4202],[-35.9652,-6.4844],[-35.8704,-6.4886],[-35.7799,-6.4833],[-35.7733,-6.4828],[-35.6636,-6.4468],[-35.6368,-6.4544],[-35.5814,-6.4841],[-35.4421,-6.4866],[-35.4078,-6.4896],[-35.3645,-6.512],[-35.3413,-6.5386],[-35.2244,-6.5216],[-35.194,-6.5503],[-35.1458,-6.5528],[-35.1125,-6.5051],[-34.9685,-6.4872],[-35.0319,-6.3108],[-35.0334,-6.2864],[-35.0939,-6.1834],[-35.0978,-6.1398],[-35.121,-5.9817],[-35.1541,-5.8978],[-35.2036,-5.7432],[-35.2271,-5.6121],[-35.2558,-5.5169],[-35.326,-5.3813],[-35.3824,-5.27],[-35.4895,-5.157],[-35.6171,-5.114],[-35.7909,-5.0774],[-35.9083,-5.0595],[-36.0375,-5.0515],[-36.0995,-5.0772],[-36.3083,-5.1021],[-36.4068,-5.0807],[-36.7156,-5.0809],[-36.8557,-4.9723],[-36.96,-4.9186],[-37.1386,-4.9479],[-37.221,-4.8814],[-37.2527,-4.8314],[-37.3569,-4.8581],[-37.4464,-4.881],[-37.4671,-4.8859],[-37.6403,-4.9264],[-37.6771,-5.0523],[-37.7882,-5.2192],[-37.7848,-5.2402],[-37.7869,-5.2972],[-37.8128,-5.3166],[-37.9022,-5.5007],[-38.0281,-5.6233],[-38.0828,-5.6724],[-38.0586,-5.7549],[-38.1593,-5.9246],[-38.1635,-5.9389],[-38.2522,-6.0102],[-38.2749,-6.0658],[-38.3396,-6.0777],[-38.4048,-6.0573],[-38.466,-6.1214],[-38.5197,-6.223],[-38.5704,-6.293],[-38.5625,-6.3557],[-38.4584,-6.3302],[-38.448,-6.4034],[-38.3438,-6.4567],[-38.2887,-6.5056],[-38.229,-6.4833],[-38.1202,-6.5224],[-38.0709,-6.4639],[-38.0268,-6.4748],[-37.9194,-6.4116],[-37.8432,-6.3331],[-37.7766,-6.2459],[-37.709,-6.177],[-37.6162,-6.1762],[-37.5219,-6.1518],[-37.3788,-6.0851],[-37.2565,-6.0285],[-37.1739,-6.048],[-37.1569,-6.1525],[-37.2336,-6.2131],[-37.334,-6.3083],[-37.3888,-6.391],[-37.3812,-6.4371],[-37.4647,-6.5327],[-37.4847,-6.71],[-37.3143,-6.689],[-37.2639,-6.7322],[-37.2346,-6.8246],[-37.1522,-6.7984],[-37.0754,-6.7541],[-37.0353,-6.7342],[-37.0036,-6.7096],[-36.9591,-6.7833],[-36.9102,-6.7569],[-36.835,-6.7311],[-36.7302,-6.8364],[-36.76,-6.9145],[-36.6549,-6.9282],[-36.5679,-6.8748],[-36.5602,-6.8408],[-36.5437,-6.8421],[-36.5335,-6.7335],[-36.5207,-6.6106],[-36.4382,-6.6293],[-36.4815,-6.5206],[-36.5282,-6.4793],[-36.5044,-6.3865]]]},"properties":{"codarea":"24"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-37.5718,-7.4891],[-37.5217,-7.4395],[-37.4318,-7.3567],[-37.3857,-7.3567],[-37.314,-7.2894],[-37.2607,-7.2742],[-37.1769,-7.3096],[-37.0532,-7.3795],[-37.0137,-7.4038],[-36.9854,-7.4756],[-37.0252,-7.4967],[-37.0257,-7.497],[-37.0793,-7.5166],[-37.1979,-7.6353],[-37.161,-7.698],[-37.1502,-7.7169],[-37.152,-7.7798],[-37.1707,-7.8002],[-37.3502,-7.9486],[-37.1496,-8.0237],[-37.1442,-8.125],[-37.1602,-8.1704],[-37.0206,-8.2897],[-36.9545,-8.2992],[-36.9083,-8.2531],[-36.7878,-8.1898],[-36.687,-8.1557],[-36.6286,-8.1111],[-36.5726,-7.936],[-36.5365,-7.9016],[-36.4463,-7.9164],[-36.3994,-7.8104],[-36.2635,-7.8317],[-36.2166,-7.7641],[-36.1268,-7.7842],[-36.0216,-7.8102],[-36.0033,-7.8128],[-35.9434,-7.79],[-35.881,-7.7663],[-35.8253,-7.7496],[-35.7899,-7.7404],[-35.6799,-7.7036],[-35.6195,-7.6625],[-35.527,-7.6451],[-35.5019,-7.5125],[-35.4949,-7.4839],[-35.4344,-7.4708],[-35.3629,-7.4428],[-35.3426,-7.422],[-35.3329,-7.4153],[-35.2802,-7.3877],[-35.1538,-7.3925],[-34.9854,-7.462],[-34.9851,-7.5],[-34.8538,-7.5396],[-34.8339,-7.5486],[-34.8027,-7.3879],[-34.8058,-7.2445],[-34.8424,-7.056],[-34.859,-7.0297],[-34.8691,-6.9781],[-34.8987,-6.8659],[-34.9248,-6.7676],[-34.9315,-6.7211],[-34.965,-6.6029],[-34.9685,-6.4872],[-35.1125,-6.5051],[-35.1458,-6.5528],[-35.194,-6.5503],[-35.2244,-6.5216],[-35.3413,-6.5386],[-35.3645,-6.512],[-35.4078,-6.4896],[-35.4421,-6.4866],[-35.5814,-6.4841],[-35.6368,-6.4544],[-35.6636,-6.4468],[-35.7733,-6.4828],[-35.7799,-6.4833],[-35.8704,-6.4886],[-35.9652,-6.4844],[-36.0961,-6.4202],[-36.0965,-6.4203],[-36.1745,-6.4308],[-36.2265,-6.434],[-36.2963,-6.3704],[-36.2791,-6.3176],[-36.295,-6.2921],[-36.344,-6.3025],[-36.5044,-6.3865],[-36.5282,-6.4793],[-36.4815,-6.5206],[-36.4382,-6.6293],[-36.5207,-6.6106],[-36.5335,-6.7335],[-36.5437,-6.8421],[-36.5602,-6.8408],[-36.5679,-6.8748],[-36.6549,-6.9282],[-36.76,-6.9145],[-36.7302,-6.8364],[-36.835,-6.7311],[-36.9102,-6.7569],[-36.9591,-6.7833],[-37.0036,-6.7096],[-37.0353,-6.7342],[-37.0754,-6.7541],[-37.1522,-6.7984],[-37.2346,-6.8246],[-37.2639,-6.7322],[-37.3143,-6.689],[-37.4847,-6.71],[-37.4647,-6.5327],[-37.3812,-6.4371],[-37.3888,-6.391],[-37.334,-6.3083],[-37.2336,-6.2131],[-37.1569,-6.1525],[-37.1739,-6.048],[-37.2565,-6.0285],[-37.3788,-6.0851],[-37.5219,-6.1518],[-37.6162,-6.1762],[-37.709,-6.177],[-37.7766,-6.2459],[-37.8432,-6.3331],[-37.9194,-6.4116],[-38.0268,-6.4748],[-38.0709,-6.4639],[-38.1202,-6.5224],[-38.229,-6.4833],[-38.2887,-6.5056],[-38.3438,-6.4567],[-38.448,-6.4034],[-38.4584,-6.3302],[-38.5625,-6.3557],[-38.5384,-6.4213],[-38.6105,-6.5323],[-38.6071,-6.5295],[-38.6491,-6.6276],[-38.6725,-6.7062],[-38.6524,-6.7571],[-38.6139,-6.7824],[-38.6717,-6.8471],[-38.7652,-6.9109],[-38.765,-6.9939],[-38.6738,-7.0462],[-38.6698,-7.0477],[-38.6442,-7.1838],[-38.62,-7.2201],[-38.5544,-7.2519],[-38.5494,-7.335],[-38.683,-7.5787],[-38.7151,-7.6219],[-38.5936,-7.7543],[-38.4571,-7.7181],[-38.4342,-7.7205],[-38.355,-7.6784],[-38.3109,-7.7391],[-38.2219,-7.8204],[-38.1314,-7.7958],[-38.1201,-7.819],[-38.0695,-7.7723],[-38.0007,-7.779],[-37.9578,-7.7662],[-37.9033,-7.6981],[-37.7672,-7.6572],[-37.7533,-7.6258],[-37.7457,-7.6093],[-37.7349,-7.5972],[-37.6199,-7.5259],[-37.5718,-7.4891]]]},"properties":{"codarea":"25"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-41.3583,-8.7076],[-41.2783,-8.7353],[-41.1137,-8.7038],[-41.1034,-8.7804],[-40.959,-8.842],[-40.851,-8.9542],[-40.821,-9.0799],[-40.6699,-9.1861],[-40.7672,-9.4454],[-40.7152,-9.4488],[-40.6232,-9.4829],[-40.4181,-9.3521],[-40.3564,-9.377],[-40.2732,-9.0824],[-40.2088,-9.0638],[-40.1299,-9.1103],[-40.0049,-9.0598],[-39.9784,-9.0549],[-39.8744,-8.9367],[-39.893,-8.8288],[-39.6733,-8.7849],[-39.646,-8.6597],[-39.4761,-8.5928],[-39.3568,-8.5475],[-39.2726,-8.5838],[-39.2285,-8.7103],[-39.0645,-8.7316],[-38.9524,-8.8045],[-38.8549,-8.7845],[-38.7065,-8.8623],[-38.6936,-8.9187],[-38.6103,-8.9573],[-38.5704,-8.8304],[-38.4698,-8.8657],[-38.514,-8.96],[-38.4035,-9.0372],[-38.3235,-8.99],[-38.3129,-9.1484],[-38.2376,-9.3298],[-38.1564,-9.2501],[-38.0923,-9.1727],[-38.0121,-9.156],[-37.9516,-9.0974],[-37.8262,-8.9327],[-37.7554,-8.8464],[-37.6991,-8.9359],[-37.6384,-9.0038],[-37.5253,-8.9634],[-37.5191,-8.9683],[-37.3956,-9.0281],[-37.2785,-9.1525],[-37.2292,-9.2269],[-37.1983,-9.2155],[-37.1691,-9.2657],[-37.0576,-9.3175],[-37.0553,-9.3074],[-36.9796,-9.3593],[-36.9368,-9.3774],[-36.8798,-9.2764],[-36.7968,-9.2804],[-36.6997,-9.293],[-36.6249,-9.3318],[-36.5004,-9.2628],[-36.4029,-9.2234],[-36.3559,-9.2184],[-36.2915,-9.1741],[-36.1957,-9.0448],[-36.1212,-9.0279],[-36.1115,-9.0177],[-36.1282,-8.9577],[-36.0333,-8.9084],[-35.9884,-8.904],[-35.9506,-8.8923],[-35.845,-8.8725],[-35.8266,-8.8704],[-35.7233,-8.9095],[-35.652,-8.8823],[-35.5825,-8.8465],[-35.5702,-8.8428],[-35.5398,-8.8211],[-35.409,-8.838],[-35.3508,-8.8607],[-35.235,-8.8832],[-35.1527,-8.9139],[-35.1302,-8.8623],[-35.1028,-8.7849],[-35.0878,-8.6908],[-35.0482,-8.6094],[-34.9609,-8.3667],[-34.9286,-8.2253],[-34.9088,-8.1551],[-34.8605,-8.0445],[-34.828,-7.9591],[-34.8411,-7.8451],[-34.8451,-7.8164],[-34.8482,-7.6878],[-34.8339,-7.5486],[-34.8538,-7.5396],[-34.9851,-7.5],[-34.9854,-7.462],[-35.1538,-7.3925],[-35.2802,-7.3877],[-35.3329,-7.4153],[-35.3426,-7.422],[-35.3629,-7.4428],[-35.4344,-7.4708],[-35.4949,-7.4839],[-35.5019,-7.5125],[-35.527,-7.6451],[-35.6195,-7.6625],[-35.6799,-7.7036],[-35.7899,-7.7404],[-35.8253,-7.7496],[-35.881,-7.7663],[-35.9434,-7.79],[-36.0033,-7.8128],[-36.0216,-7.8102],[-36.1268,-7.7842],[-36.2166,-7.7641],[-36.2635,-7.8317],[-36.3994,-7.8104],[-36.4463,-7.9164],[-36.5365,-7.9016],[-36.5726,-7.936],[-36.6286,-8.1111],[-36.687,-8.1557],[-36.7878,-8.1898],[-36.9083,-8.2531],[-36.9545,-8.2992],[-37.0206,-8.2897],[-37.1602,-8.1704],[-37.1442,-8.125],[-37.1496,-8.0237],[-37.3502,-7.9486],[-37.1707,-7.8002],[-37.152,-7.7798],[-37.1502,-7.7169],[-37.161,-7.698],[-37.1979,-7.6353],[-37.0793,-7.5166],[-37.0257,-7.497],[-37.0252,-7.4967],[-36.9854,-7.4756],[-37.0137,-7.4038],[-37.0532,-7.3795],[-37.1769,-7.3096],[-37.2607,-7.2742],[-37.314,-7.2894],[-37.3857,-7.3567],[-37.4318,-7.3567],[-37.5217,-7.4395],[-37.5718,-7.4891],[-37.6199,-7.5259],[-37.7349,-7.5972],[-37.7457,-7.6093],[-37.7533,-7.6258],[-37.7672,-7.6572],[-37.9033,-7.6981],[-37.9578,-7.7662],[-38.0007,-7.779],[-38.0695,-7.7723],[-38.1201,-7.819],[-38.1314,-7.7958],[-38.2219,-7.8204],[-38.3109,-7.7391],[-38.355,-7.6784],[-38.4342,-7.7205],[-38.4571,-7.7181],[-38.5936,-7.7543],[-38.7151,-7.6219],[-38.7176,-7.6269],[-38.8948,-7.7505],[-38.9621,-7.8442],[-38.966,-7.8456],[-39.018,-7.8127],[-39.093,-7.8576],[-39.1026,-7.771],[-39.1466,-7.7182],[-39.2664,-7.6648],[-39.3696,-7.6193],[-39.3919,-7.6082],[-39.4476,-7.5722],[-39.4607,-7.4712],[-39.5459,-7.4839],[-39.5992,-7.4287],[-39.7413,-7.3268],[-39.8901,-7.3398],[-39.9046,-7.3383],[-40.1571,-7.3715],[-40.242,-7.318],[-40.3454,-7.3292],[-40.4336,-7.3672],[-40.5237,-7.3185],[-40.5485,-7.3927],[-40.6523,-7.4333],[-40.7149,-7.4806],[-40.6218,-7.6583],[-40.6736,-7.7617],[-40.5549,-7.8184],[-40.5439,-7.9616],[-40.5607,-7.9973],[-40.5757,-8.0304],[-40.5757,-8.0305],[-40.6039,-8.1037],[-40.7643,-8.244],[-40.7801,-8.2963],[-40.8618,-8.3707],[-40.9269,-8.4463],[-40.9785,-8.3987],[-41.1495,-8.5339],[-41.2065,-8.6333],[-41.3583,-8.7076]]]},"properties":{"codarea":"26"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-38.0121,-9.156],[-38.0923,-9.1727],[-38.1564,-9.2501],[-38.2376,-9.3298],[-38.2149,-9.353],[-38.205,-9.4167],[-38.0778,-9.4411],[-38.0033,-9.515],[-37.8941,-9.5395],[-37.8422,-9.5794],[-37.6659,-9.6659],[-37.6596,-9.6782],[-37.466,-9.748],[-37.2965,-9.8306],[-37.2263,-9.8977],[-37.1338,-9.9138],[-36.9535,-10.0228],[-36.9484,-10.0696],[-36.9474,-10.0747],[-36.918,-10.1247],[-36.8826,-10.1475],[-36.8504,-10.1784],[-36.8449,-10.1888],[-36.7204,-10.2649],[-36.7016,-10.2704],[-36.6837,-10.2708],[-36.6319,-10.2522],[-36.5873,-10.3013],[-36.562,-10.4157],[-36.4894,-10.4245],[-36.4869,-10.4232],[-36.3959,-10.4969],[-36.3014,-10.3446],[-36.2596,-10.2641],[-36.0315,-10.0508],[-35.9627,-9.9407],[-35.9047,-9.8559],[-35.8553,-9.7883],[-35.7898,-9.7112],[-35.7237,-9.6847],[-35.5585,-9.4875],[-35.5246,-9.4426],[-35.4725,-9.358],[-35.3868,-9.2863],[-35.3391,-9.2307],[-35.2951,-9.1555],[-35.2413,-9.0647],[-35.1527,-8.9139],[-35.235,-8.8832],[-35.3508,-8.8607],[-35.409,-8.838],[-35.5398,-8.8211],[-35.5702,-8.8428],[-35.5825,-8.8465],[-35.652,-8.8823],[-35.7233,-8.9095],[-35.8266,-8.8704],[-35.845,-8.8725],[-35.9506,-8.8923],[-35.9884,-8.904],[-36.0333,-8.9084],[-36.1282,-8.9577],[-36.1115,-9.0177],[-36.1212,-9.0279],[-36.1957,-9.0448],[-36.2915,-9.1741],[-36.3559,-9.2184],[-36.4029,-9.2234],[-36.5004,-9.2628],[-36.6249,-9.3318],[-36.6997,-9.293],[-36.7968,-9.2804],[-36.8798,-9.2764],[-36.9368,-9.3774],[-36.9796,-9.3593],[-37.0553,-9.3074],[-37.0576,-9.3175],[-37.1691,-9.2657],[-37.1983,-9.2155],[-37.2292,-9.2269],[-37.2785,-9.1525],[-37.3956,-9.0281],[-37.5191,-8.9683],[-37.5253,-8.9634],[-37.6384,-9.0038],[-37.6991,-8.9359],[-37.7554,-8.8464],[-37.8262,-8.9327],[-37.9516,-9.0974],[-38.0121,-9.156]]]},"properties":{"codarea":"27"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-36.918,-10.1247],[-36.9474,-10.0747],[-36.9484,-10.0696],[-36.9535,-10.0228],[-37.1338,-9.9138],[-37.2263,-9.8977],[-37.2965,-9.8306],[-37.466,-9.748],[-37.6596,-9.6782],[-37.6659,-9.6659],[-37.8422,-9.5794],[-37.8941,-9.5395],[-38.0033,-9.515],[-38.061,-9.5876],[-38.0035,-9.9047],[-37.9021,-9.9189],[-37.7908,-10.0329],[-37.8019,-10.1113],[-37.7745,-10.1446],[-37.7656,-10.1962],[-37.7687,-10.2892],[-37.7433,-10.3384],[-37.8477,-10.4435],[-37.8153,-10.5173],[-37.8063,-10.6005],[-37.8099,-10.6888],[-37.9725,-10.7571],[-38.0421,-10.7008],[-38.1449,-10.718],[-38.2049,-10.7106],[-38.2383,-10.7999],[-38.2103,-10.931],[-38.1806,-10.9428],[-38.106,-11.0258],[-38.0469,-11.1816],[-37.9813,-11.1992],[-37.9942,-11.3434],[-37.9822,-11.3479],[-37.8331,-11.4823],[-37.8,-11.5214],[-37.673,-11.5686],[-37.6323,-11.5181],[-37.5786,-11.5522],[-37.3677,-11.4586],[-37.3411,-11.4423],[-37.2602,-11.2896],[-37.1545,-11.1616],[-37.0346,-10.9573],[-36.8527,-10.7442],[-36.6729,-10.6308],[-36.4862,-10.5364],[-36.3959,-10.4969],[-36.4869,-10.4232],[-36.4894,-10.4245],[-36.562,-10.4157],[-36.5873,-10.3013],[-36.6319,-10.2522],[-36.6837,-10.2708],[-36.7016,-10.2704],[-36.7204,-10.2649],[-36.8449,-10.1888],[-36.8504,-10.1784],[-36.8826,-10.1475],[-36.918,-10.1247]]]},"properties":{"codarea":"28"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-39.3568,-8.5475],[-39.4761,-8.5928],[-39.646,-8.6597],[-39.6733,-8.7849],[-39.893,-8.8288],[-39.8744,-8.9367],[-39.9784,-9.0549],[-40.0049,-9.0598],[-40.1299,-9.1103],[-40.2088,-9.0638],[-40.2732,-9.0824],[-40.3564,-9.377],[-40.4181,-9.3521],[-40.6232,-9.4829],[-40.7152,-9.4488],[-40.7672,-9.4454],[-40.6699,-9.1861],[-40.821,-9.0799],[-40.851,-8.9542],[-40.959,-8.842],[-41.1034,-8.7804],[-41.1137,-8.7038],[-41.2783,-8.7353],[-41.3583,-8.7076],[-41.3813,-8.7073],[-41.4114,-8.7744],[-41.5456,-8.9417],[-41.7236,-9.0135],[-41.7327,-9.0877],[-41.8547,-9.2407],[-41.9139,-9.2771],[-42.0692,-9.2575],[-42.2261,-9.2833],[-42.3161,-9.3166],[-42.4931,-9.4949],[-42.6029,-9.5168],[-42.6901,-9.5459],[-42.77,-9.6192],[-42.9514,-9.5104],[-42.9587,-9.4284],[-43.0593,-9.397],[-43.0745,-9.4],[-43.2186,-9.4006],[-43.2851,-9.42],[-43.4381,-9.2661],[-43.5409,-9.3082],[-43.606,-9.3516],[-43.7822,-9.4527],[-43.7862,-9.4576],[-43.8497,-9.5481],[-43.7849,-9.7624],[-43.6525,-9.8436],[-43.7082,-9.9198],[-43.6927,-10.0594],[-43.7592,-10.0746],[-43.8369,-10.3022],[-43.9159,-10.3931],[-43.9902,-10.418],[-44.0834,-10.5891],[-44.1655,-10.6429],[-44.3444,-10.5497],[-44.5005,-10.6497],[-44.5778,-10.6268],[-44.6688,-10.6871],[-44.6668,-10.7589],[-44.8638,-10.8852],[-44.9447,-10.919],[-45.0821,-10.8395],[-45.246,-10.8225],[-45.4145,-10.6451],[-45.4474,-10.5094],[-45.396,-10.445],[-45.4907,-10.301],[-45.5566,-10.2169],[-45.6032,-10.108],[-45.7235,-10.1554],[-45.6993,-10.2586],[-45.7982,-10.3232],[-45.8202,-10.4561],[-46.1276,-10.6206],[-46.2062,-10.8005],[-46.2605,-10.812],[-46.2673,-10.9348],[-46.3416,-10.939],[-46.553,-11.2654],[-46.5599,-11.3716],[-46.4393,-11.521],[-46.3504,-11.5062],[-46.1128,-11.606],[-46.0809,-11.624],[-46.1445,-11.6243],[-46.3617,-11.631],[-46.3078,-11.6866],[-46.3786,-11.7486],[-46.3376,-11.8131],[-46.381,-11.8631],[-46.3128,-11.9411],[-46.3889,-12.0488],[-46.3712,-12.0997],[-46.3716,-12.3498],[-46.29,-12.377],[-46.2666,-12.5067],[-46.1982,-12.504],[-46.1983,-12.5041],[-46.2967,-12.5757],[-46.2824,-12.7639],[-46.328,-12.9547],[-46.113,-12.918],[-46.2987,-13.0638],[-46.3277,-13.2529],[-46.2925,-13.3169],[-46.1032,-13.2575],[-46.0683,-13.2954],[-46.2485,-13.436],[-46.209,-13.4656],[-46.2475,-13.5787],[-46.1627,-13.6036],[-46.2357,-13.7081],[-46.2642,-13.9474],[-46.2121,-14.0101],[-46.227,-14.049],[-46.1841,-14.1569],[-46.0601,-14.2319],[-45.9072,-14.3552],[-46.0001,-14.4466],[-45.9889,-14.6558],[-46.021,-14.6699],[-46.0251,-14.6781],[-46.0394,-14.8753],[-46.0376,-14.8747],[-45.9661,-14.9656],[-46.0771,-15.2647],[-45.9717,-15.1539],[-45.7398,-15.1204],[-45.6169,-15.0141],[-45.3057,-14.8337],[-45.2056,-14.7447],[-45.0958,-14.753],[-45.0403,-14.6805],[-44.877,-14.5992],[-44.8332,-14.4998],[-44.7414,-14.4671],[-44.5572,-14.337],[-44.4118,-14.2816],[-44.296,-14.2532],[-44.0457,-14.2838],[-43.9696,-14.274],[-43.7832,-14.3392],[-43.8184,-14.3877],[-43.8812,-14.5624],[-43.8835,-14.6525],[-43.7122,-14.7153],[-43.531,-14.8154],[-43.5308,-14.8155],[-43.487,-14.7903],[-43.3112,-14.6697],[-43.175,-14.6511],[-42.9389,-14.708],[-42.8721,-14.7647],[-42.6187,-14.9397],[-42.5157,-14.9829],[-42.479,-15.0142],[-42.2776,-15.1137],[-42.2656,-15.125],[-42.1733,-15.086],[-42.0485,-15.1707],[-41.9534,-15.1757],[-41.8103,-15.1014],[-41.8023,-15.1003],[-41.7599,-15.138],[-41.4561,-15.4103],[-41.3643,-15.493],[-41.3619,-15.495],[-41.3422,-15.6386],[-41.3302,-15.7433],[-41.1425,-15.772],[-40.8168,-15.6476],[-40.7677,-15.7141],[-40.7006,-15.6673],[-40.6449,-15.7289],[-40.5198,-15.7976],[-40.45,-15.7616],[-40.425,-15.8057],[-40.2357,-15.8035],[-40.1275,-15.9071],[-40.0044,-16.0018],[-39.9148,-16],[-39.8568,-16.1138],[-39.9178,-16.2843],[-40.0172,-16.3478],[-40.1102,-16.4493],[-40.1579,-16.5795],[-40.2755,-16.5734],[-40.3132,-16.6786],[-40.307,-16.6968],[-40.2816,-16.9012],[-40.4013,-16.8902],[-40.4077,-16.8987],[-40.4336,-16.8874],[-40.4923,-16.8874],[-40.5787,-17.1496],[-40.5478,-17.2837],[-40.6047,-17.3562],[-40.5195,-17.4474],[-40.483,-17.4885],[-40.4145,-17.6101],[-40.3441,-17.6156],[-40.2402,-17.7349],[-40.2237,-17.7343],[-40.2119,-17.8949],[-40.2224,-17.9804],[-40.2204,-17.9816],[-39.9118,-18.179],[-39.6678,-18.3372],[-39.6354,-18.2323],[-39.4912,-17.9979],[-39.2575,-17.828],[-39.1373,-17.685],[-39.1917,-17.446],[-39.2121,-17.1613],[-39.1175,-16.8925],[-39.1416,-16.7615],[-39.1038,-16.6981],[-39.0621,-16.4358],[-39.0088,-16.3457],[-39.0111,-16.2458],[-38.9484,-16.0924],[-38.8528,-15.8494],[-38.8936,-15.7667],[-38.9349,-15.6654],[-38.9732,-15.3855],[-38.9963,-15.0852],[-39.0274,-14.783],[-39.0622,-14.747],[-39.0343,-14.5153],[-39.0177,-14.4185],[-38.9889,-14.2174],[-38.9288,-13.9068],[-38.9517,-13.8724],[-38.9678,-13.8488],[-38.9722,-13.8424],[-38.9884,-13.7168],[-38.9685,-13.6721],[-38.8911,-13.6405],[-38.9329,-13.546],[-38.8924,-13.4606],[-38.9508,-13.3899],[-38.9188,-13.2136],[-38.7975,-13.1375],[-38.6433,-13.0153],[-38.5856,-13.0127],[-38.4687,-13.0149],[-38.3043,-12.9109],[-38.2802,-12.8807],[-38.0302,-12.5972],[-37.8933,-12.4082],[-37.7699,-12.2387],[-37.6857,-12.099],[-37.5128,-11.7407],[-37.3411,-11.4423],[-37.3677,-11.4586],[-37.5786,-11.5522],[-37.6323,-11.5181],[-37.673,-11.5686],[-37.8,-11.5214],[-37.8331,-11.4823],[-37.9822,-11.3479],[-37.9942,-11.3434],[-37.9813,-11.1992],[-38.0469,-11.1816],[-38.106,-11.0258],[-38.1806,-10.9428],[-38.2103,-10.931],[-38.2383,-10.7999],[-38.2049,-10.7106],[-38.1449,-10.718],[-38.0421,-10.7008],[-37.9725,-10.7571],[-37.8099,-10.6888],[-37.8063,-10.6005],[-37.8153,-10.5173],[-37.8477,-10.4435],[-37.7433,-10.3384],[-37.7687,-10.2892],[-37.7656,-10.1962],[-37.7745,-10.1446],[-37.8019,-10.1113],[-37.7908,-10.0329],[-37.9021,-9.9189],[-38.0035,-9.9047],[-38.061,-9.5876],[-38.0033,-9.515],[-38.0778,-9.4411],[-38.205,-9.4167],[-38.2149,-9.353],[-38.2376,-9.3298],[-38.3129,-9.1484],[-38.3235,-8.99],[-38.4035,-9.0372],[-38.514,-8.96],[-38.4698,-8.8657],[-38.5704,-8.8304],[-38.6103,-8.9573],[-38.6936,-8.9187],[-38.7065,-8.8623],[-38.8549,-8.7845],[-38.9524,-8.8045],[-39.0645,-8.7316],[-39.2285,-8.7103],[-39.2726,-8.5838],[-39.3568,-8.5475]]]},"properties":{"codarea":"29"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-47.6797,-18.3561],[-47.7695,-18.4183],[-47.8605,-18.4402],[-47.8646,-18.4491],[-47.9546,-18.5],[-48.027,-18.4361],[-48.2272,-18.346],[-48.2718,-18.3294],[-48.3418,-18.3708],[-48.6538,-18.3428],[-48.7872,-18.3532],[-48.9177,-18.3059],[-48.9595,-18.3235],[-49.0538,-18.4026],[-49.2058,-18.4141],[-49.2493,-18.5228],[-49.2927,-18.5639],[-49.3734,-18.6348],[-49.4862,-18.5323],[-49.5476,-18.5396],[-49.723,-18.6094],[-49.7577,-18.6097],[-49.7946,-18.6438],[-50.0288,-18.6015],[-50.0798,-18.6719],[-50.27,-18.6842],[-50.3523,-18.7603],[-50.4732,-18.9214],[-50.5352,-19.0989],[-50.6457,-19.1348],[-50.7331,-19.187],[-50.7404,-19.2132],[-50.828,-19.3108],[-50.8754,-19.4228],[-50.8256,-19.4733],[-50.935,-19.4675],[-50.9306,-19.5903],[-51.0382,-19.6918],[-51.0335,-19.7907],[-51.0005,-20.0854],[-50.886,-19.9904],[-50.8441,-19.9676],[-50.6864,-19.9162],[-50.6142,-19.861],[-50.562,-19.8136],[-50.4541,-19.7862],[-50.3374,-19.8695],[-50.1718,-19.8755],[-50.1062,-19.8743],[-50.0441,-19.9164],[-49.9062,-19.9372],[-49.7494,-19.9247],[-49.6132,-19.92],[-49.4538,-19.9781],[-49.2501,-19.9693],[-49.3059,-20.1169],[-49.2652,-20.2297],[-49.2597,-20.2588],[-49.1836,-20.3147],[-49.1207,-20.2705],[-49.0659,-20.1535],[-48.986,-20.1708],[-48.963,-20.4031],[-48.8865,-20.4369],[-48.8671,-20.3989],[-48.8871,-20.2753],[-48.8221,-20.1615],[-48.7296,-20.1503],[-48.6469,-20.167],[-48.5374,-20.1336],[-48.4516,-20.1259],[-48.2186,-20.1279],[-48.2034,-20.0455],[-48.0768,-20.1484],[-47.9812,-20.0364],[-47.8994,-20.1257],[-47.8698,-20.0762],[-47.8509,-19.9898],[-47.7626,-19.986],[-47.6397,-20.0472],[-47.5492,-19.9938],[-47.4896,-19.9693],[-47.3292,-20.1153],[-47.2311,-20.2192],[-47.2326,-20.2275],[-47.2767,-20.2916],[-47.2935,-20.4187],[-47.2235,-20.4911],[-47.1442,-20.5408],[-47.1377,-20.5611],[-47.1428,-20.5656],[-47.101,-20.682],[-47.1862,-20.7314],[-47.2269,-20.8555],[-47.2274,-20.8565],[-47.1813,-20.9538],[-47.1479,-21.0355],[-47.1176,-21.1532],[-47.1185,-21.1859],[-47.0442,-21.2674],[-46.9967,-21.3573],[-47.0115,-21.4223],[-46.8846,-21.4072],[-46.7815,-21.3707],[-46.7647,-21.3601],[-46.6476,-21.3796],[-46.6161,-21.4303],[-46.5089,-21.4891],[-46.5118,-21.5654],[-46.5547,-21.6534],[-46.6145,-21.6765],[-46.6307,-21.7686],[-46.6907,-21.8376],[-46.6179,-21.995],[-46.6499,-22.0095],[-46.7195,-22.0833],[-46.5985,-22.1364],[-46.6456,-22.1806],[-46.6718,-22.1783],[-46.6803,-22.2165],[-46.7233,-22.3066],[-46.6609,-22.366],[-46.6163,-22.4386],[-46.5499,-22.4695],[-46.4565,-22.5217],[-46.4243,-22.5994],[-46.3931,-22.663],[-46.4731,-22.705],[-46.3326,-22.7661],[-46.3745,-22.8202],[-46.3449,-22.9052],[-46.1922,-22.8652],[-46.0507,-22.897],[-45.9565,-22.8498],[-45.871,-22.8715],[-45.768,-22.836],[-45.7122,-22.7698],[-45.8051,-22.7373],[-45.694,-22.6517],[-45.73,-22.6187],[-45.6787,-22.5733],[-45.6662,-22.6512],[-45.5765,-22.6017],[-45.5804,-22.6529],[-45.4804,-22.5905],[-45.4204,-22.6212],[-45.4,-22.6537],[-45.2691,-22.6114],[-45.1668,-22.5307],[-45.1244,-22.4972],[-45.1028,-22.4899],[-44.9659,-22.4752],[-44.8439,-22.4278],[-44.8094,-22.4056],[-44.8094,-22.4043],[-44.8035,-22.3937],[-44.6659,-22.3727],[-44.6619,-22.3805],[-44.5437,-22.3323],[-44.4571,-22.2576],[-44.3596,-22.254],[-44.2599,-22.268],[-44.1892,-22.2404],[-44.1794,-22.2285],[-43.9771,-22.1464],[-43.7644,-22.0632],[-43.7089,-22.0758],[-43.6684,-22.0861],[-43.5914,-22.0558],[-43.437,-22.06],[-43.3467,-22.0038],[-43.3266,-22.0078],[-43.2277,-22.0288],[-43.1312,-22.0292],[-43.1306,-22.035],[-43.1423,-22.1044],[-43.0022,-22.0328],[-42.9096,-21.9907],[-42.6653,-21.8733],[-42.606,-21.8464],[-42.4632,-21.7862],[-42.4597,-21.7848],[-42.3777,-21.7484],[-42.2666,-21.7145],[-42.3527,-21.5917],[-42.346,-21.5827],[-42.2546,-21.487],[-42.2754,-21.4275],[-42.2356,-21.3429],[-42.2242,-21.3378],[-42.2026,-21.2212],[-42.1953,-21.1603],[-42.1745,-21.1318],[-42.1185,-21.0748],[-42.0801,-21.0302],[-42.0848,-21.023],[-42.1509,-20.974],[-41.9759,-20.9355],[-41.9297,-20.8436],[-41.9282,-20.794],[-41.8747,-20.7659],[-41.8507,-20.6912],[-41.8254,-20.4833],[-41.7995,-20.477],[-41.8034,-20.4222],[-41.8366,-20.4091],[-41.8595,-20.3729],[-41.8221,-20.3109],[-41.775,-20.2601],[-41.7568,-20.2069],[-41.666,-20.207],[-41.4156,-20.2074],[-41.4119,-20.2061],[-41.2979,-19.9376],[-41.2714,-19.9422],[-41.187,-19.8915],[-41.1746,-19.7672],[-41.1685,-19.6722],[-40.9722,-19.5053],[-40.9664,-19.4236],[-40.9323,-19.2512],[-40.9354,-19.2227],[-40.9643,-19.1221],[-41.0608,-19.0565],[-41.065,-18.9448],[-41.1371,-18.8906],[-41.2432,-18.8538],[-41.2324,-18.7973],[-41.1468,-18.798],[-41.0254,-18.8372],[-40.9168,-18.8155],[-40.9415,-18.6907],[-41.0509,-18.6342],[-41.0258,-18.5276],[-41.023,-18.4573],[-41.1818,-18.4396],[-41.1442,-18.4053],[-41.1589,-18.3082],[-41.0519,-18.1651],[-40.7733,-18.1076],[-40.9024,-17.9862],[-40.7985,-17.9569],[-40.662,-18.0127],[-40.527,-17.8919],[-40.3684,-17.9229],[-40.2224,-17.9804],[-40.2119,-17.8949],[-40.2237,-17.7343],[-40.2402,-17.7349],[-40.3441,-17.6156],[-40.4145,-17.6101],[-40.483,-17.4885],[-40.5195,-17.4474],[-40.6047,-17.3562],[-40.5478,-17.2837],[-40.5787,-17.1496],[-40.4923,-16.8874],[-40.4336,-16.8874],[-40.4077,-16.8987],[-40.4013,-16.8902],[-40.2816,-16.9012],[-40.307,-16.6968],[-40.3132,-16.6786],[-40.2755,-16.5734],[-40.1579,-16.5795],[-40.1102,-16.4493],[-40.0172,-16.3478],[-39.9178,-16.2843],[-39.8568,-16.1138],[-39.9148,-16],[-40.0044,-16.0018],[-40.1275,-15.9071],[-40.2357,-15.8035],[-40.425,-15.8057],[-40.45,-15.7616],[-40.5198,-15.7976],[-40.6449,-15.7289],[-40.7006,-15.6673],[-40.7677,-15.7141],[-40.8168,-15.6476],[-41.1425,-15.772],[-41.3302,-15.7433],[-41.3422,-15.6386],[-41.3619,-15.495],[-41.3643,-15.493],[-41.4561,-15.4103],[-41.7599,-15.138],[-41.8023,-15.1003],[-41.8103,-15.1014],[-41.9534,-15.1757],[-42.0485,-15.1707],[-42.1733,-15.086],[-42.2656,-15.125],[-42.2776,-15.1137],[-42.479,-15.0142],[-42.5157,-14.9829],[-42.6187,-14.9397],[-42.8721,-14.7647],[-42.9389,-14.708],[-43.175,-14.6511],[-43.3112,-14.6697],[-43.487,-14.7903],[-43.5308,-14.8155],[-43.531,-14.8154],[-43.7122,-14.7153],[-43.8835,-14.6525],[-43.8812,-14.5624],[-43.8184,-14.3877],[-43.7832,-14.3392],[-43.9696,-14.274],[-44.0457,-14.2838],[-44.296,-14.2532],[-44.4118,-14.2816],[-44.5572,-14.337],[-44.7414,-14.4671],[-44.8332,-14.4998],[-44.877,-14.5992],[-45.0403,-14.6805],[-45.0958,-14.753],[-45.2056,-14.7447],[-45.3057,-14.8337],[-45.6169,-15.0141],[-45.7398,-15.1204],[-45.9717,-15.1539],[-46.0771,-15.2647],[-45.9661,-14.9656],[-46.0376,-14.8747],[-46.0394,-14.8753],[-46.1768,-14.9494],[-46.3193,-14.9004],[-46.3222,-14.8146],[-46.5034,-14.7041],[-46.5605,-14.815],[-46.5027,-15.0509],[-46.5261,-15.0564],[-46.6254,-15.0895],[-46.8569,-15.0103],[-46.9251,-15.0575],[-46.9373,-15.205],[-46.8737,-15.2854],[-46.8495,-15.3732],[-46.9305,-15.4431],[-46.9461,-15.5633],[-46.8826,-15.6101],[-46.8062,-15.8706],[-46.9525,-15.9166],[-47.1366,-15.9274],[-47.31,-16.0363],[-47.3085,-16.05],[-47.3226,-16.2091],[-47.4544,-16.4646],[-47.4127,-16.5744],[-47.2955,-16.6258],[-47.2257,-16.7205],[-47.2084,-16.8747],[-47.1274,-16.9787],[-47.1821,-17.064],[-47.352,-17.1665],[-47.4886,-17.3487],[-47.5108,-17.3261],[-47.5246,-17.4119],[-47.5366,-17.4571],[-47.4669,-17.534],[-47.3131,-17.5434],[-47.2648,-17.6114],[-47.3712,-17.8313],[-47.2834,-18.0408],[-47.4079,-18.1419],[-47.4298,-18.1652],[-47.607,-18.2462],[-47.6102,-18.3157],[-47.6797,-18.3561]]]},"properties":{"codarea":"31"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-41.2714,-19.9422],[-41.2979,-19.9376],[-41.4119,-20.2061],[-41.4156,-20.2074],[-41.666,-20.207],[-41.7568,-20.2069],[-41.775,-20.2601],[-41.8221,-20.3109],[-41.8595,-20.3729],[-41.8366,-20.4091],[-41.8034,-20.4222],[-41.7995,-20.477],[-41.8254,-20.4833],[-41.8507,-20.6912],[-41.8747,-20.7659],[-41.8446,-20.7773],[-41.7752,-20.7999],[-41.7415,-20.8726],[-41.7338,-20.9433],[-41.7169,-21.1051],[-41.6455,-21.1434],[-41.5577,-21.1733],[-41.4696,-21.2028],[-41.2762,-21.2401],[-41.1371,-21.2274],[-40.961,-21.3011],[-40.9261,-21.1902],[-40.8092,-20.9958],[-40.7589,-20.8657],[-40.7012,-20.8346],[-40.5709,-20.7652],[-40.3772,-20.5355],[-40.2744,-20.32],[-40.2149,-20.2426],[-40.1918,-20.0545],[-40.1545,-20.0121],[-40.0548,-19.8148],[-39.9117,-19.687],[-39.8108,-19.6496],[-39.6891,-19.3049],[-39.7193,-19.097],[-39.7465,-18.7062],[-39.7282,-18.5183],[-39.6678,-18.3372],[-39.9118,-18.179],[-40.2204,-17.9816],[-40.2224,-17.9804],[-40.3684,-17.9229],[-40.527,-17.8919],[-40.662,-18.0127],[-40.7985,-17.9569],[-40.9024,-17.9862],[-40.7733,-18.1076],[-41.0519,-18.1651],[-41.1589,-18.3082],[-41.1442,-18.4053],[-41.1818,-18.4396],[-41.023,-18.4573],[-41.0258,-18.5276],[-41.0509,-18.6342],[-40.9415,-18.6907],[-40.9168,-18.8155],[-41.0254,-18.8372],[-41.1468,-18.798],[-41.2324,-18.7973],[-41.2432,-18.8538],[-41.1371,-18.8906],[-41.065,-18.9448],[-41.0608,-19.0565],[-40.9643,-19.1221],[-40.9354,-19.2227],[-40.9323,-19.2512],[-40.9664,-19.4236],[-40.9722,-19.5053],[-41.1685,-19.6722],[-41.1746,-19.7672],[-41.187,-19.8915],[-41.2714,-19.9422]]]},"properties":{"codarea":"32"}},
{"type":"Feature","geometry":{"type":"MultiPolygon","coordinates":[[[[-44.6387,-22.9142],[-44.7919,-22.9819],[-44.8244,-23.1627],[-44.8826,-23.2027],[-44.7242,-23.3676],[-44.583,-23.3576],[-44.5358,-23.2921],[-44.6527,-23.1884],[-44.7212,-23.2018],[-44.6686,-23.0542],[-44.5211,-23.0273],[-44.3449,-22.922],[-44.347,-23.0302],[-44.1657,-23.0339],[-44.0059,-22.9421],[-43.8806,-22.9158],[-43.796,-22.9171],[-43.5624,-23.0532],[-43.2855,-23.015],[-43.1615,-22.9053],[-43.2728,-22.8098],[-43.2146,-22.7277],[-43.0389,-22.6926],[-43.0259,-22.7261],[-43.0266,-22.7431],[-43.1034,-22.8559],[-43.1104,-22.9536],[-43.0138,-22.9768],[-42.6412,-22.9375],[-42.3816,-22.9357],[-42.2812,-22.9395],[-42.0373,-22.9331],[-41.9694,-22.8228],[-41.9735,-22.7296],[-41.9914,-22.5981],[-41.9792,-22.5625],[-41.8178,-22.417],[-41.6891,-22.3],[-41.5424,-22.2346],[-41.1338,-22.0955],[-41.004,-22.0211],[-40.9818,-21.9111],[-41.0481,-21.6178],[-41.0689,-21.4976],[-40.961,-21.3011],[-41.1371,-21.2274],[-41.2762,-21.2401],[-41.4696,-21.2028],[-41.5577,-21.1733],[-41.6455,-21.1434],[-41.7169,-21.1051],[-41.7338,-20.9433],[-41.7415,-20.8726],[-41.7752,-20.7999],[-41.8446,-20.7773],[-41.8747,-20.7659],[-41.9282,-20.794],[-41.9297,-20.8436],[-41.9759,-20.9355],[-42.1509,-20.974],[-42.0848,-21.023],[-42.0801,-21.0302],[-42.1185,-21.0748],[-42.1745,-21.1318],[-42.1953,-21.1603],[-42.2026,-21.2212],[-42.2242,-21.3378],[-42.2356,-21.3429],[-42.2754,-21.4275],[-42.2546,-21.487],[-42.346,-21.5827],[-42.3527,-21.5917],[-42.2666,-21.7145],[-42.3777,-21.7484],[-42.4597,-21.7848],[-42.4632,-21.7862],[-42.606,-21.8464],[-42.6653,-21.8733],[-42.9096,-21.9907],[-43.0022,-22.0328],[-43.1423,-22.1044],[-43.1306,-22.035],[-43.1312,-22.0292],[-43.2277,-22.0288],[-43.3266,-22.0078],[-43.3467,-22.0038],[-43.437,-22.06],[-43.5914,-22.0558],[-43.6684,-22.0861],[-43.7089,-22.0758],[-43.7644,-22.0632],[-43.9771,-22.1464],[-44.1794,-22.2285],[-44.1892,-22.2404],[-44.2599,-22.268],[-44.3596,-22.254],[-44.4571,-22.2576],[-44.5437,-22.3323],[-44.6619,-22.3805],[-44.6659,-22.3727],[-44.8035,-22.3937],[-44.8094,-22.4043],[-44.8094,-22.4056],[-44.6882,-22.5215],[-44.6459,-22.6039],[-44.4662,-22.6157],[-44.3609,-22.6118],[-44.3421,-22.5893],[-44.2264,-22.6046],[-44.1656,-22.6734],[-44.3181,-22.8451],[-44.4946,-22.8468],[-44.6295,-22.9049],[-44.6387,-22.9142]]],[[[-44.3498,-23.2155],[-44.14,-23.167],[-44.2334,-23.0907],[-44.373,-23.1682],[-44.3498,-23.2155]]],[[[-43.7931,-23.0615],[-43.9733,-23.0453],[-43.9543,-23.087],[-43.793,-23.0639],[-43.6678,-23.0531],[-43.6666,-23.0426],[-43.7931,-23.0615]]]]},"properties":{"codarea":"33"}},
{"type":"Feature","geometry":{"type":"MultiPolygon","coordinates":[[[[-46.6907,-21.8376],[-46.6307,-21.7686],[-46.6145,-21.6765],[-46.5547,-21.6534],[-46.5118,-21.5654],[-46.5089,-21.4891],[-46.6161,-21.4303],[-46.6476,-21.3796],[-46.7647,-21.3601],[-46.7815,-21.3707],[-46.8846,-21.4072],[-47.0115,-21.4223],[-46.9967,-21.3573],[-47.0442,-21.2674],[-47.1185,-21.1859],[-47.1176,-21.1532],[-47.1479,-21.0355],[-47.1813,-20.9538],[-47.2274,-20.8565],[-47.2269,-20.8555],[-47.1862,-20.7314],[-47.101,-20.682],[-47.1428,-20.5656],[-47.1377,-20.5611],[-47.1442,-20.5408],[-47.2235,-20.4911],[-47.2935,-20.4187],[-47.2767,-20.2916],[-47.2326,-20.2275],[-47.2311,-20.2192],[-47.3292,-20.1153],[-47.4896,-19.9693],[-47.5492,-19.9938],[-47.6397,-20.0472],[-47.7626,-19.986],[-47.8509,-19.9898],[-47.8698,-20.0762],[-47.8994,-20.1257],[-47.9812,-20.0364],[-48.0768,-20.1484],[-48.2034,-20.0455],[-48.2186,-20.1279],[-48.4516,-20.1259],[-48.5374,-20.1336],[-48.6469,-20.167],[-48.7296,-20.1503],[-48.8221,-20.1615],[-48.8871,-20.2753],[-48.8671,-20.3989],[-48.8865,-20.4369],[-48.963,-20.4031],[-48.986,-20.1708],[-49.0659,-20.1535],[-49.1207,-20.2705],[-49.1836,-20.3147],[-49.2597,-20.2588],[-49.2652,-20.2297],[-49.3059,-20.1169],[-49.2501,-19.9693],[-49.4538,-19.9781],[-49.6132,-19.92],[-49.7494,-19.9247],[-49.9062,-19.9372],[-50.0441,-19.9164],[-50.1062,-19.8743],[-50.1718,-19.8755],[-50.3374,-19.8695],[-50.4541,-19.7862],[-50.562,-19.8136],[-50.6142,-19.861],[-50.6864,-19.9162],[-50.8441,-19.9676],[-50.886,-19.9904],[-51.0005,-20.0854],[-51.0012,-20.0963],[-51.1094,-20.2801],[-51.3435,-20.3556],[-51.4188,-20.465],[-51.5676,-20.6183],[-51.5752,-20.6234],[-51.6349,-20.7548],[-51.6236,-20.9444],[-51.7725,-21.0511],[-51.8797,-21.1979],[-51.8611,-21.3367],[-51.9622,-21.4933],[-52.1022,-21.5698],[-52.0558,-21.6772],[-52.1613,-21.7708],[-52.319,-21.9721],[-52.3919,-22.1147],[-52.4562,-22.1853],[-52.6553,-22.3031],[-52.9482,-22.4734],[-53.0738,-22.5489],[-53.1052,-22.6219],[-53.0385,-22.6184],[-53.0117,-22.5988],[-52.9247,-22.5656],[-52.7829,-22.6021],[-52.7643,-22.6086],[-52.5893,-22.5661],[-52.5378,-22.616],[-52.4457,-22.6083],[-52.4214,-22.6106],[-52.29,-22.6282],[-52.1828,-22.6554],[-52.1523,-22.5692],[-52.1356,-22.5269],[-52.0329,-22.5392],[-52.0284,-22.5395],[-51.9015,-22.6019],[-51.8902,-22.6132],[-51.8558,-22.6317],[-51.7182,-22.669],[-51.6305,-22.6579],[-51.6279,-22.6582],[-51.5172,-22.69],[-51.4464,-22.653],[-51.3331,-22.6671],[-51.2982,-22.6735],[-51.2137,-22.7237],[-51.176,-22.7388],[-51.0044,-22.7937],[-50.9787,-22.7826],[-50.9277,-22.7977],[-50.8236,-22.8661],[-50.7959,-22.9512],[-50.6373,-22.9069],[-50.5772,-22.904],[-50.5268,-22.9348],[-50.3592,-22.9161],[-50.3402,-22.9481],[-50.2039,-22.9528],[-50.1331,-22.9399],[-50.0528,-22.9055],[-49.9742,-22.9545],[-49.9725,-22.9585],[-49.8337,-23.0659],[-49.8194,-23.077],[-49.8095,-23.0892],[-49.7165,-23.1484],[-49.6271,-23.2818],[-49.6379,-23.3495],[-49.5981,-23.4582],[-49.6242,-23.5233],[-49.6021,-23.6521],[-49.5747,-23.676],[-49.5597,-23.7936],[-49.608,-23.8394],[-49.5358,-23.9282],[-49.5223,-23.9166],[-49.4872,-24.0246],[-49.3366,-24.1376],[-49.3507,-24.2208],[-49.2542,-24.3179],[-49.2535,-24.405],[-49.2524,-24.4339],[-49.2505,-24.4454],[-49.316,-24.5555],[-49.312,-24.6635],[-49.2079,-24.7009],[-49.1579,-24.6719],[-49.1298,-24.6819],[-48.9123,-24.674],[-48.8108,-24.675],[-48.6012,-24.6691],[-48.5381,-24.7262],[-48.5664,-24.9168],[-48.5981,-25.0033],[-48.5563,-25.0843],[-48.4119,-24.9804],[-48.3241,-25.0367],[-48.2397,-24.9914],[-48.0961,-25.3089],[-47.9141,-25.1594],[-47.9095,-25.0529],[-47.7315,-24.8806],[-47.4153,-24.6756],[-47.0779,-24.4482],[-46.8976,-24.2529],[-46.7094,-24.1441],[-46.6044,-24.0897],[-46.3919,-23.9986],[-46.3551,-23.9711],[-46.3063,-23.9931],[-46.1848,-23.9922],[-46.1332,-23.8565],[-45.8424,-23.7582],[-45.5551,-23.795],[-45.5146,-23.8421],[-45.3963,-23.8081],[-45.427,-23.7084],[-45.4066,-23.6239],[-45.2767,-23.5783],[-45.0669,-23.4926],[-44.9082,-23.3342],[-44.8442,-23.387],[-44.7242,-23.3676],[-44.8826,-23.2027],[-44.8244,-23.1627],[-44.7919,-22.9819],[-44.6387,-22.9142],[-44.6295,-22.9049],[-44.4946,-22.8468],[-44.3181,-22.8451],[-44.1656,-22.6734],[-44.2264,-22.6046],[-44.3421,-22.5893],[-44.3609,-22.6118],[-44.4662,-22.6157],[-44.6459,-22.6039],[-44.6882,-22.5215],[-44.8094,-22.4056],[-44.8439,-22.4278],[-44.9659,-22.4752],[-45.1028,-22.4899],[-45.1244,-22.4972],[-45.1668,-22.5307],[-45.2691,-22.6114],[-45.4,-22.6537],[-45.4204,-22.6212],[-45.4804,-22.5905],[-45.5804,-22.6529],[-45.5765,-22.6017],[-45.6662,-22.6512],[-45.6787,-22.5733],[-45.73,-22.6187],[-45.694,-22.6517],[-45.8051,-22.7373],[-45.7122,-22.7698],[-45.768,-22.836],[-45.871,-22.8715],[-45.9565,-22.8498],[-46.0507,-22.897],[-46.1922,-22.8652],[-46.3449,-22.9052],[-46.3745,-22.8202],[-46.3326,-22.7661],[-46.4731,-22.705],[-46.3931,-22.663],[-46.4243,-22.5994],[-46.4565,-22.5217],[-46.5499,-22.4695],[-46.6163,-22.4386],[-46.6609,-22.366],[-46.7233,-22.3066],[-46.6803,-22.2165],[-46.6718,-22.1783],[-46.6456,-22.1806],[-46.5985,-22.1364],[-46.7195,-22.0833],[-46.6499,-22.0095],[-46.6179,-21.995],[-46.6907,-21.8376]]],[[[-45.2904,-23.8691],[-45.2303,-23.778],[-45.3415,-23.7278],[-45.4443,-23.9341],[-45.2485,-23.9032],[-45.2904,-23.8691]]]]},"properties":{"codarea":"35"}},
{"type":"Feature","geometry":{"type":"MultiPolygon","coordinates":[[[[-49.1298,-24.6819],[-49.1579,-24.6719],[-49.2079,-24.7009],[-49.312,-24.6635],[-49.316,-24.5555],[-49.2505,-24.4454],[-49.2524,-24.4339],[-49.2535,-24.405],[-49.2542,-24.3179],[-49.3507,-24.2208],[-49.3366,-24.1376],[-49.4872,-24.0246],[-49.5223,-23.9166],[-49.5358,-23.9282],[-49.608,-23.8394],[-49.5597,-23.7936],[-49.5747,-23.676],[-49.6021,-23.6521],[-49.6242,-23.5233],[-49.5981,-23.4582],[-49.6379,-23.3495],[-49.6271,-23.2818],[-49.7165,-23.1484],[-49.8095,-23.0892],[-49.8194,-23.077],[-49.8337,-23.0659],[-49.9725,-22.9585],[-49.9742,-22.9545],[-50.0528,-22.9055],[-50.1331,-22.9399],[-50.2039,-22.9528],[-50.3402,-22.9481],[-50.3592,-22.9161],[-50.5268,-22.9348],[-50.5772,-22.904],[-50.6373,-22.9069],[-50.7959,-22.9512],[-50.8236,-22.8661],[-50.9277,-22.7977],[-50.9787,-22.7826],[-51.0044,-22.7937],[-51.176,-22.7388],[-51.2137,-22.7237],[-51.2982,-22.6735],[-51.3331,-22.6671],[-51.4464,-22.653],[-51.5172,-22.69],[-51.6279,-22.6582],[-51.6305,-22.6579],[-51.7182,-22.669],[-51.8558,-22.6317],[-51.8902,-22.6132],[-51.9015,-22.6019],[-52.0284,-22.5395],[-52.0329,-22.5392],[-52.1356,-22.5269],[-52.1523,-22.5692],[-52.1828,-22.6554],[-52.29,-22.6282],[-52.4214,-22.6106],[-52.4457,-22.6083],[-52.5378,-22.616],[-52.5893,-22.5661],[-52.7643,-22.6086],[-52.7829,-22.6021],[-52.9247,-22.5656],[-53.0117,-22.5988],[-53.0385,-22.6184],[-53.1052,-22.6219],[-53.1279,-22.6523],[-53.24,-22.7335],[-53.3274,-22.7646],[-53.4104,-22.8139],[-53.5468,-22.8901],[-53.634,-23.0034],[-53.6366,-23.125],[-53.7149,-23.2834],[-53.7622,-23.3593],[-53.9602,-23.4434],[-54.0306,-23.6282],[-54.0511,-23.6872],[-54.0836,-23.8055],[-54.084,-23.865],[-54.169,-23.999],[-54.2862,-24.0682],[-54.3456,-24.157],[-54.2616,-24.375],[-54.2956,-24.4276],[-54.3185,-24.5907],[-54.3269,-24.6595],[-54.3323,-24.6945],[-54.3899,-24.7773],[-54.4572,-25.0393],[-54.4249,-25.1533],[-54.4736,-25.2115],[-54.6191,-25.4507],[-54.5935,-25.5922],[-54.4453,-25.6657],[-54.2963,-25.5576],[-54.1764,-25.5844],[-54.144,-25.521],[-53.9912,-25.5861],[-53.8498,-25.6908],[-53.8427,-25.7707],[-53.8189,-25.9123],[-53.8368,-25.9699],[-53.7342,-26.0428],[-53.6721,-26.1762],[-53.6514,-26.2068],[-53.639,-26.2508],[-53.4309,-26.2821],[-53.4308,-26.282],[-53.4304,-26.2819],[-53.3423,-26.2491],[-53.1693,-26.3481],[-53.1602,-26.3506],[-53.028,-26.3702],[-52.9377,-26.3622],[-52.9083,-26.3594],[-52.7628,-26.3536],[-52.7006,-26.358],[-52.645,-26.3809],[-52.557,-26.4078],[-52.5232,-26.3996],[-52.4426,-26.4381],[-52.1588,-26.4662],[-52.0291,-26.5469],[-51.824,-26.5819],[-51.5121,-26.5817],[-51.4115,-26.7171],[-51.3911,-26.6632],[-51.2389,-26.6279],[-51.2221,-26.5937],[-51.3004,-26.4177],[-51.2704,-26.3869],[-51.2522,-26.3515],[-51.2029,-26.2982],[-51.0789,-26.2274],[-50.9915,-26.235],[-50.8997,-26.2893],[-50.7033,-26.188],[-50.6975,-26.1818],[-50.6285,-26.0628],[-50.5702,-26.002],[-50.3657,-26.1121],[-50.2685,-26.0428],[-50.1898,-26.07],[-49.9934,-26.0114],[-49.9341,-26.0189],[-49.8646,-26.0358],[-49.6905,-26.1895],[-49.6031,-26.2267],[-49.4872,-26.1942],[-49.486,-26.1852],[-49.4292,-26.17],[-49.3608,-26.1374],[-49.2345,-26.0307],[-48.9683,-25.9867],[-48.9504,-25.99],[-48.6821,-25.9837],[-48.5953,-25.9768],[-48.5496,-25.8523],[-48.4771,-25.7137],[-48.3583,-25.5859],[-48.3097,-25.4933],[-48.214,-25.473],[-48.0961,-25.3089],[-48.2397,-24.9914],[-48.3241,-25.0367],[-48.4119,-24.9804],[-48.5563,-25.0843],[-48.5981,-25.0033],[-48.5664,-24.9168],[-48.5381,-24.7262],[-48.6012,-24.6691],[-48.8108,-24.675],[-48.9123,-24.674],[-49.1298,-24.6819]]],[[[-53.6542,-25.3509],[-53.6251,-25.3464],[-53.6265,-25.3466],[-53.6542,-25.3509]]],[[[-53.3778,-23.2407],[-53.3781,-23.2409],[-53.3763,-23.2398],[-53.3778,-23.2407]]]]},"properties":{"codarea":"41"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-52.4426,-26.4381],[-52.5232,-26.3996],[-52.557,-26.4078],[-52.645,-26.3809],[-52.7006,-26.358],[-52.7628,-26.3536],[-52.9083,-26.3594],[-52.9377,-26.3622],[-53.028,-26.3702],[-53.1602,-26.3506],[-53.1693,-26.3481],[-53.3423,-26.2491],[-53.4304,-26.2819],[-53.4309,-26.2821],[-53.639,-26.2508],[-53.6888,-26.4286],[-53.6884,-26.4433],[-53.7209,-26.5378],[-53.7307,-26.6007],[-53.7144,-26.7508],[-53.6773,-26.8439],[-53.6754,-26.8928],[-53.6717,-26.9428],[-53.7327,-27.0042],[-53.8371,-27.1684],[-53.8197,-27.1757],[-53.7177,-27.1825],[-53.5997,-27.1894],[-53.5478,-27.1764],[-53.4882,-27.1938],[-53.3554,-27.1113],[-53.2962,-27.1324],[-53.3225,-27.2099],[-53.1877,-27.1923],[-53.0767,-27.1078],[-53.0178,-27.0931],[-52.9925,-27.14],[-52.9712,-27.2178],[-52.8513,-27.1703],[-52.801,-27.2034],[-52.7855,-27.206],[-52.6915,-27.2844],[-52.5446,-27.2406],[-52.5363,-27.2601],[-52.4325,-27.2178],[-52.4192,-27.2824],[-52.3978,-27.2925],[-52.2998,-27.3191],[-52.2613,-27.2569],[-52.2248,-27.3306],[-52.1071,-27.3434],[-52.049,-27.3463],[-51.9834,-27.3751],[-51.8582,-27.4751],[-51.8371,-27.5222],[-51.788,-27.5148],[-51.7012,-27.4798],[-51.6326,-27.4886],[-51.5784,-27.577],[-51.5476,-27.5591],[-51.4573,-27.6075],[-51.3088,-27.7195],[-51.2733,-27.7355],[-51.0534,-27.8689],[-51.0567,-27.8868],[-51.0015,-27.9632],[-50.9784,-27.9482],[-50.8753,-28.0413],[-50.7491,-28.2485],[-50.6956,-28.2699],[-50.6139,-28.3936],[-50.4248,-28.4333],[-50.0687,-28.4792],[-49.9708,-28.4402],[-49.8163,-28.469],[-49.7269,-28.5189],[-49.7031,-28.6289],[-49.7041,-28.63],[-49.7826,-28.6098],[-49.8402,-28.7131],[-49.9347,-28.7257],[-49.9509,-28.8935],[-49.9557,-28.9489],[-49.9576,-29.0682],[-50.0163,-29.1828],[-50.1378,-29.1937],[-50.1446,-29.2702],[-50.041,-29.3551],[-50.034,-29.3496],[-50.1143,-29.2576],[-49.9576,-29.1995],[-49.9016,-29.2153],[-49.7918,-29.2856],[-49.7129,-29.3256],[-49.6451,-29.2384],[-49.516,-29.0957],[-49.3764,-28.9561],[-49.2901,-28.8832],[-49.1879,-28.8022],[-48.858,-28.6157],[-48.7465,-28.5051],[-48.7063,-28.3414],[-48.6343,-28.113],[-48.6209,-27.9449],[-48.587,-27.9044],[-48.5766,-27.844],[-48.5176,-27.7815],[-48.3706,-27.4498],[-48.4172,-27.3806],[-48.5263,-27.4083],[-48.5948,-27.3161],[-48.6027,-27.2179],[-48.5784,-27.2115],[-48.4953,-27.1985],[-48.508,-27.1105],[-48.5856,-27.1449],[-48.5891,-27.061],[-48.6283,-26.9601],[-48.6422,-26.9127],[-48.6212,-26.8262],[-48.6613,-26.7712],[-48.6819,-26.7184],[-48.6648,-26.5809],[-48.6507,-26.5473],[-48.5943,-26.4522],[-48.4931,-26.2186],[-48.5694,-26.1677],[-48.5953,-25.9768],[-48.6821,-25.9837],[-48.9504,-25.99],[-48.9683,-25.9867],[-49.2345,-26.0307],[-49.3608,-26.1374],[-49.4292,-26.17],[-49.486,-26.1852],[-49.4872,-26.1942],[-49.6031,-26.2267],[-49.6905,-26.1895],[-49.8646,-26.0358],[-49.9341,-26.0189],[-49.9934,-26.0114],[-50.1898,-26.07],[-50.2685,-26.0428],[-50.3657,-26.1121],[-50.5702,-26.002],[-50.6285,-26.0628],[-50.6975,-26.1818],[-50.7033,-26.188],[-50.8997,-26.2893],[-50.9915,-26.235],[-51.0789,-26.2274],[-51.2029,-26.2982],[-51.2522,-26.3515],[-51.2704,-26.3869],[-51.3004,-26.4177],[-51.2221,-26.5937],[-51.2389,-26.6279],[-51.3911,-26.6632],[-51.4115,-26.7171],[-51.5121,-26.5817],[-51.824,-26.5819],[-52.0291,-26.5469],[-52.1588,-26.4662],[-52.4426,-26.4381]]]},"properties":{"codarea":"42"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-53.9475,-31.9546],[-53.7256,-32.0984],[-53.6765,-32.2381],[-53.644,-32.3849],[-53.4369,-32.5482],[-53.1764,-32.6585],[-52.9974,-32.5912],[-52.968,-32.4905],[-52.8024,-32.447],[-52.7242,-32.37],[-52.8211,-32.3341],[-52.7189,-32.1542],[-52.6229,-32.1456],[-52.6884,-32.3195],[-52.6023,-32.4606],[-52.6209,-32.6379],[-52.7234,-32.8339],[-52.8322,-32.915],[-53.0016,-32.7975],[-53.1239,-32.7938],[-53.1744,-33.0035],[-53.2602,-33.1074],[-53.3253,-33.0652],[-53.4692,-33.2554],[-53.4248,-33.4376],[-53.5078,-33.5311],[-53.5228,-33.6893],[-53.422,-33.7438],[-53.37,-33.7439],[-52.7767,-33.2831],[-52.6239,-33.1042],[-52.4952,-32.8672],[-52.4229,-32.6288],[-52.293,-32.3383],[-52.0972,-32.1617],[-52.1148,-31.942],[-52.2566,-31.8498],[-52.2236,-31.7889],[-52.1524,-31.6993],[-52.036,-31.6958],[-52.0135,-31.5972],[-52.0102,-31.5009],[-51.9195,-31.3108],[-51.8117,-31.2857],[-51.6191,-31.269],[-51.6287,-31.153],[-51.5378,-31.115],[-51.442,-31.0874],[-51.4993,-30.9758],[-51.4488,-30.8722],[-51.3727,-30.8725],[-51.3809,-30.6435],[-51.3188,-30.6461],[-51.2654,-30.4798],[-51.1358,-30.4368],[-51.2101,-30.3013],[-51.3283,-30.2265],[-51.3012,-30.0542],[-51.2719,-30.039],[-51.2327,-30.1827],[-51.0629,-30.2596],[-51.0556,-30.392],[-50.93,-30.4358],[-50.9148,-30.3264],[-50.6561,-30.286],[-50.6208,-30.1984],[-50.5426,-30.2523],[-50.5827,-30.4901],[-50.7295,-30.3681],[-50.6864,-30.5008],[-50.6901,-30.7069],[-50.7538,-30.8189],[-50.9668,-30.8961],[-50.9546,-31.0032],[-51.179,-31.1342],[-51.1575,-31.2847],[-51.2375,-31.4574],[-51.3611,-31.532],[-51.4282,-31.492],[-51.6587,-31.7669],[-51.8377,-31.801],[-51.9028,-31.8705],[-52.0981,-31.8359],[-52.0152,-31.9224],[-52.0772,-32.1432],[-51.8309,-31.9192],[-51.4272,-31.6956],[-51.186,-31.5044],[-50.8421,-31.19],[-50.7672,-31.1101],[-50.3343,-30.5008],[-50.2519,-30.3049],[-50.2241,-30.2363],[-50.1703,-30.0971],[-50.1192,-29.9762],[-50.0753,-29.8845],[-50.0637,-29.86],[-50.0176,-29.7725],[-49.9337,-29.6251],[-49.9222,-29.6072],[-49.8035,-29.4436],[-49.7129,-29.3256],[-49.7918,-29.2856],[-49.9016,-29.2153],[-49.9576,-29.1995],[-50.1143,-29.2576],[-50.034,-29.3496],[-50.041,-29.3551],[-50.1446,-29.2702],[-50.1378,-29.1937],[-50.0163,-29.1828],[-49.9576,-29.0682],[-49.9557,-28.9489],[-49.9509,-28.8935],[-49.9347,-28.7257],[-49.8402,-28.7131],[-49.7826,-28.6098],[-49.7041,-28.63],[-49.7031,-28.6289],[-49.7269,-28.5189],[-49.8163,-28.469],[-49.9708,-28.4402],[-50.0687,-28.4792],[-50.4248,-28.4333],[-50.6139,-28.3936],[-50.6956,-28.2699],[-50.7491,-28.2485],[-50.8753,-28.0413],[-50.9784,-27.9482],[-51.0015,-27.9632],[-51.0567,-27.8868],[-51.0534,-27.8689],[-51.2733,-27.7355],[-51.3088,-27.7195],[-51.4573,-27.6075],[-51.5476,-27.5591],[-51.5784,-27.577],[-51.6326,-27.4886],[-51.7012,-27.4798],[-51.788,-27.5148],[-51.8371,-27.5222],[-51.8582,-27.4751],[-51.9834,-27.3751],[-52.049,-27.3463],[-52.1071,-27.3434],[-52.2248,-27.3306],[-52.2613,-27.2569],[-52.2998,-27.3191],[-52.3978,-27.2925],[-52.4192,-27.2824],[-52.4325,-27.2178],[-52.5363,-27.2601],[-52.5446,-27.2406],[-52.6915,-27.2844],[-52.7855,-27.206],[-52.801,-27.2034],[-52.8513,-27.1703],[-52.9712,-27.2178],[-52.9925,-27.14],[-53.0178,-27.0931],[-53.0767,-27.1078],[-53.1877,-27.1923],[-53.3225,-27.2099],[-53.2962,-27.1324],[-53.3554,-27.1113],[-53.4882,-27.1938],[-53.5478,-27.1764],[-53.5997,-27.1894],[-53.7177,-27.1825],[-53.8197,-27.1757],[-53.8371,-27.1684],[-53.9466,-27.1513],[-54.055,-27.264],[-54.1115,-27.3025],[-54.1866,-27.2649],[-54.2174,-27.385],[-54.2839,-27.4478],[-54.4114,-27.4053],[-54.4746,-27.4812],[-54.5894,-27.4582],[-54.632,-27.5457],[-54.7233,-27.5635],[-54.8171,-27.5356],[-54.9029,-27.6989],[-54.9993,-27.7905],[-55.0517,-27.8524],[-55.2027,-27.8579],[-55.2778,-27.9329],[-55.3398,-27.966],[-55.3755,-28.034],[-55.4384,-28.0863],[-55.7712,-28.2415],[-55.6692,-28.3408],[-55.6922,-28.4164],[-55.8506,-28.3554],[-55.884,-28.4792],[-56.0232,-28.5228],[-56.0024,-28.5783],[-56.1942,-28.7752],[-56.2997,-28.8081],[-56.3233,-28.9247],[-56.4304,-29.0795],[-56.5888,-29.1198],[-56.6645,-29.295],[-56.78,-29.42],[-56.9711,-29.6434],[-57.1319,-29.7702],[-57.2354,-29.7808],[-57.3297,-29.8876],[-57.3281,-29.9719],[-57.4646,-30.1103],[-57.5941,-30.179],[-57.568,-30.2522],[-57.3894,-30.3025],[-57.2042,-30.2851],[-57.1152,-30.1137],[-56.8504,-30.0889],[-56.6581,-30.2013],[-56.5461,-30.3606],[-56.4622,-30.3845],[-56.3781,-30.5015],[-56.2899,-30.5323],[-56.1877,-30.6047],[-56.1501,-30.7055],[-56.0236,-30.7857],[-56.0111,-31.0816],[-55.8708,-31.0716],[-55.6662,-30.954],[-55.5786,-30.8329],[-55.437,-31.0047],[-55.3514,-31.0376],[-55.2468,-31.2522],[-55.0745,-31.3321],[-55.0358,-31.2839],[-54.8365,-31.4419],[-54.7013,-31.4357],[-54.5869,-31.4565],[-54.4729,-31.5704],[-54.4546,-31.6528],[-54.088,-31.9312],[-53.9475,-31.9546]]]},"properties":{"codarea":"43"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-53.4039,-17.9926],[-53.4861,-18.0404],[-53.6125,-17.978],[-53.7742,-18.0008],[-53.9517,-17.9158],[-53.8559,-17.7027],[-53.7572,-17.6728],[-53.7039,-17.6613],[-53.6801,-17.2541],[-53.8201,-17.2946],[-53.9731,-17.4722],[-54.0233,-17.4771],[-54.0764,-17.6157],[-54.1916,-17.6056],[-54.3024,-17.6617],[-54.5023,-17.4807],[-54.7469,-17.5199],[-54.8609,-17.6239],[-55.1371,-17.6502],[-55.139,-17.6478],[-55.2997,-17.5412],[-55.5057,-17.486],[-55.6028,-17.3674],[-55.6039,-17.3667],[-55.9857,-17.2584],[-56.0441,-17.1714],[-56.2513,-17.219],[-56.4406,-17.3304],[-56.7233,-17.3085],[-56.876,-17.533],[-56.9824,-17.5802],[-56.9882,-17.6593],[-57.119,-17.781],[-57.3801,-17.8273],[-57.4473,-17.8757],[-57.6024,-17.8049],[-57.6846,-17.7165],[-57.6927,-17.627],[-57.7523,-17.5645],[-57.783,-17.6368],[-57.7113,-17.7287],[-57.7214,-17.829],[-57.5741,-18.1316],[-57.4548,-18.2334],[-57.5583,-18.2407],[-57.7667,-18.8995],[-57.7104,-19.0347],[-57.7833,-19.0351],[-58.1314,-19.7594],[-57.8591,-19.9717],[-58.1686,-20.1658],[-58.0966,-20.2539],[-58.0732,-20.388],[-57.9965,-20.4434],[-58.0131,-20.6083],[-57.9582,-20.7049],[-57.8647,-20.7464],[-57.9595,-20.7979],[-57.8594,-20.8249],[-57.9289,-20.8952],[-57.8337,-20.9363],[-57.8664,-21.0393],[-57.8547,-21.3169],[-57.9616,-21.5624],[-57.8852,-21.6836],[-57.9698,-21.8443],[-57.9162,-21.8763],[-57.9951,-22.0887],[-57.7477,-22.139],[-57.6101,-22.0954],[-57.5168,-22.1736],[-57.3202,-22.2456],[-57.0497,-22.232],[-56.844,-22.3011],[-56.5691,-22.2066],[-56.5034,-22.0974],[-56.3929,-22.075],[-56.3455,-22.1813],[-56.2091,-22.2782],[-55.8431,-22.2871],[-55.7667,-22.3842],[-55.7236,-22.5518],[-55.6136,-22.6928],[-55.6659,-22.8525],[-55.5968,-23.1526],[-55.5391,-23.2412],[-55.5045,-23.3785],[-55.5604,-23.4831],[-55.5304,-23.6278],[-55.4363,-23.7168],[-55.4463,-23.9169],[-55.4029,-23.9742],[-55.262,-23.9917],[-55.0623,-23.9933],[-54.6838,-23.8305],[-54.4268,-23.9311],[-54.2862,-24.0682],[-54.169,-23.999],[-54.084,-23.865],[-54.0836,-23.8055],[-54.0511,-23.6872],[-54.0306,-23.6282],[-53.9602,-23.4434],[-53.7622,-23.3593],[-53.7149,-23.2834],[-53.6366,-23.125],[-53.634,-23.0034],[-53.5468,-22.8901],[-53.4104,-22.8139],[-53.3274,-22.7646],[-53.24,-22.7335],[-53.1279,-22.6523],[-53.1052,-22.6219],[-53.0738,-22.5489],[-52.9482,-22.4734],[-52.6553,-22.3031],[-52.4562,-22.1853],[-52.3919,-22.1147],[-52.319,-21.9721],[-52.1613,-21.7708],[-52.0558,-21.6772],[-52.1022,-21.5698],[-51.9622,-21.4933],[-51.8611,-21.3367],[-51.8797,-21.1979],[-51.7725,-21.0511],[-51.6236,-20.9444],[-51.6349,-20.7548],[-51.5752,-20.6234],[-51.5676,-20.6183],[-51.4188,-20.465],[-51.3435,-20.3556],[-51.1094,-20.2801],[-51.0012,-20.0963],[-51.0005,-20.0854],[-51.0335,-19.7907],[-51.0382,-19.6918],[-50.9306,-19.5903],[-50.935,-19.4675],[-51.092,-19.3076],[-51.4484,-19.1604],[-51.5392,-19.1427],[-51.6921,-19.118],[-51.8522,-19.0525],[-51.9407,-18.9682],[-52.0794,-18.9511],[-52.1831,-18.8476],[-52.3338,-18.8291],[-52.4119,-18.744],[-52.5019,-18.6759],[-52.7481,-18.6921],[-52.8734,-18.6459],[-52.9211,-18.6134],[-52.9649,-18.55],[-52.8385,-18.4236],[-52.7589,-18.3631],[-52.8208,-18.3107],[-53.0997,-18.3136],[-53.1432,-18.0841],[-53.0723,-18.034],[-53.2378,-18.0074],[-53.4039,-17.9926]]]},"properties":{"codarea":"50"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-56.2723,-9.4008],[-56.6719,-9.3674],[-56.7543,-9.4064],[-56.8201,-9.2463],[-56.9955,-9.2338],[-57.0598,-9.1824],[-57.0392,-9.0983],[-57.2038,-8.9208],[-57.4162,-8.859],[-57.4175,-8.7926],[-57.5929,-8.7565],[-57.6334,-8.5268],[-57.6866,-8.407],[-57.6417,-8.2199],[-57.8319,-7.9615],[-57.8967,-7.6779],[-58.0614,-7.3952],[-58.1371,-7.3561],[-58.2131,-7.4585],[-58.2022,-7.6209],[-58.2941,-7.7715],[-58.3782,-7.8274],[-58.2864,-8.0885],[-58.3149,-8.3231],[-58.4178,-8.4895],[-58.3895,-8.5948],[-58.4373,-8.7034],[-58.3284,-8.7122],[-58.4419,-8.7987],[-59.1274,-8.8033],[-60.4202,-8.7966],[-61.5831,-8.7987],[-61.4692,-8.9201],[-61.5558,-9.0924],[-61.5293,-9.2487],[-61.6283,-9.2571],[-61.6162,-9.3268],[-61.5817,-9.4591],[-61.477,-9.6299],[-61.5746,-9.7178],[-61.5079,-9.8611],[-61.5402,-10.0002],[-61.5849,-10.0616],[-61.5533,-10.307],[-61.4618,-10.4199],[-61.4766,-10.7666],[-61.5503,-10.9861],[-61.429,-10.9875],[-61.0006,-10.9922],[-60.4601,-10.9899],[-60.3916,-11.0938],[-59.9768,-11.1224],[-59.9797,-11.2395],[-59.9172,-11.3384],[-59.9344,-11.4237],[-60.1109,-11.5825],[-60.0989,-11.8456],[-59.9842,-11.9148],[-59.9794,-12.0295],[-59.8998,-12.1172],[-59.8868,-12.2451],[-59.7794,-12.3415],[-59.9477,-12.5993],[-60.0289,-12.6186],[-60.1172,-12.9596],[-60.1833,-12.9676],[-60.2676,-13.0773],[-60.3332,-13.258],[-60.3716,-13.3186],[-60.3879,-13.4547],[-60.6322,-13.5717],[-60.7093,-13.693],[-60.4727,-13.7937],[-60.4509,-13.9364],[-60.3831,-13.9929],[-60.4806,-14.0958],[-60.4536,-14.3141],[-60.2736,-14.621],[-60.245,-15.0975],[-60.5757,-15.0975],[-60.2395,-15.4746],[-60.1741,-16.2669],[-59.4692,-16.2796],[-58.7857,-16.308],[-58.4306,-16.3227],[-58.3222,-16.2664],[-58.3441,-16.5184],[-58.4362,-16.5929],[-58.4768,-16.9367],[-58.392,-17.0401],[-58.3989,-17.184],[-58.2467,-17.3552],[-57.9964,-17.5156],[-57.8834,-17.4495],[-57.7523,-17.5645],[-57.6927,-17.627],[-57.6846,-17.7165],[-57.6024,-17.8049],[-57.4473,-17.8757],[-57.3801,-17.8273],[-57.119,-17.781],[-56.9882,-17.6593],[-56.9824,-17.5802],[-56.876,-17.533],[-56.7233,-17.3085],[-56.4406,-17.3304],[-56.2513,-17.219],[-56.0441,-17.1714],[-55.9857,-17.2584],[-55.6039,-17.3667],[-55.6028,-17.3674],[-55.5057,-17.486],[-55.2997,-17.5412],[-55.139,-17.6478],[-55.1371,-17.6502],[-54.8609,-17.6239],[-54.7469,-17.5199],[-54.5023,-17.4807],[-54.3024,-17.6617],[-54.1916,-17.6056],[-54.0764,-17.6157],[-54.0233,-17.4771],[-53.9731,-17.4722],[-53.8201,-17.2946],[-53.6801,-17.2541],[-53.7039,-17.6613],[-53.7572,-17.6728],[-53.8559,-17.7027],[-53.9517,-17.9158],[-53.7742,-18.0008],[-53.6125,-17.978],[-53.4861,-18.0404],[-53.4039,-17.9926],[-53.2378,-18.0074],[-53.0723,-18.034],[-53.164,-17.7657],[-53.2352,-17.7128],[-53.2404,-17.6],[-53.242,-17.5042],[-53.2173,-17.2968],[-53.1115,-17.1086],[-53.0592,-17.0768],[-53.0141,-16.8643],[-52.9291,-16.8376],[-52.914,-16.8127],[-52.8324,-16.7722],[-52.7153,-16.637],[-52.7328,-16.5859],[-52.6294,-16.5178],[-52.6812,-16.3017],[-52.5453,-16.2226],[-52.4717,-16.1267],[-52.361,-16.0816],[-52.2543,-15.8937],[-52.0095,-15.8858],[-51.9721,-15.8381],[-51.8803,-15.8243],[-51.7679,-15.6536],[-51.7807,-15.5464],[-51.699,-15.4849],[-51.6474,-15.1735],[-51.5341,-15.0652],[-51.3531,-14.9939],[-51.4195,-14.9904],[-51.3499,-14.9903],[-51.3413,-14.9805],[-51.3387,-14.9751],[-51.3331,-14.9701],[-51.3071,-14.981],[-51.2759,-15.0438],[-51.1028,-14.9265],[-51.099,-14.9253],[-51.0871,-14.9213],[-51.0924,-14.8945],[-51.093,-14.8879],[-50.9642,-14.5283],[-50.9979,-14.4138],[-50.91,-14.1484],[-50.8415,-14.1043],[-50.8739,-13.7345],[-50.8088,-13.6974],[-50.759,-13.5203],[-50.6639,-13.435],[-50.6111,-13.3202],[-50.5708,-13.0342],[-50.511,-12.8609],[-50.6227,-12.8197],[-50.6839,-12.6481],[-50.6236,-12.4553],[-50.6437,-12.223],[-50.6814,-12.2169],[-50.6822,-11.9909],[-50.6393,-11.8846],[-50.7173,-11.7274],[-50.6701,-11.5816],[-50.7389,-11.5445],[-50.6999,-11.3131],[-50.6095,-11.0674],[-50.6326,-10.9319],[-50.5706,-10.7525],[-50.6035,-10.6609],[-50.6033,-10.6598],[-50.5414,-10.6093],[-50.4737,-10.4049],[-50.4181,-10.3546],[-50.3983,-10.1555],[-50.3026,-10.0354],[-50.2248,-9.8412],[-50.846,-9.8006],[-51.3043,-9.7729],[-52.2567,-9.7077],[-52.6193,-9.6823],[-53.1334,-9.6452],[-53.5891,-9.611],[-54.1068,-9.5719],[-54.6135,-9.5358],[-54.9956,-9.5053],[-55.8672,-9.4343],[-56.1565,-9.4104],[-56.2723,-9.4008]]]},"properties":{"codarea":"51"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-48.2349,-15.66],[-48.2,-15.5023],[-48.0744,-15.5022],[-48.0543,-15.5022],[-48.0541,-15.5022],[-48.0348,-15.5022],[-47.4927,-15.5019],[-47.3209,-15.5866],[-47.3148,-15.7481],[-47.3787,-15.8842],[-47.3687,-16.0032],[-47.31,-16.0363],[-47.1366,-15.9274],[-46.9525,-15.9166],[-46.8062,-15.8706],[-46.8826,-15.6101],[-46.9461,-15.5633],[-46.9305,-15.4431],[-46.8495,-15.3732],[-46.8737,-15.2854],[-46.9373,-15.205],[-46.9251,-15.0575],[-46.8569,-15.0103],[-46.6254,-15.0895],[-46.5261,-15.0564],[-46.5027,-15.0509],[-46.5605,-14.815],[-46.5034,-14.7041],[-46.3222,-14.8146],[-46.3193,-14.9004],[-46.1768,-14.9494],[-46.0394,-14.8753],[-46.0251,-14.6781],[-46.021,-14.6699],[-45.9889,-14.6558],[-46.0001,-14.4466],[-45.9072,-14.3552],[-46.0601,-14.2319],[-46.1841,-14.1569],[-46.227,-14.049],[-46.2121,-14.0101],[-46.2642,-13.9474],[-46.2357,-13.7081],[-46.1627,-13.6036],[-46.2475,-13.5787],[-46.209,-13.4656],[-46.2485,-13.436],[-46.0683,-13.2954],[-46.1032,-13.2575],[-46.2925,-13.3169],[-46.3277,-13.2529],[-46.2987,-13.0638],[-46.113,-12.918],[-46.3644,-12.9907],[-46.418,-12.8224],[-46.4459,-12.9358],[-46.4546,-12.9712],[-46.6354,-12.9699],[-46.7506,-12.9692],[-46.8548,-13.0676],[-47.3929,-13.2624],[-47.5687,-13.1169],[-47.6651,-13.2184],[-47.6223,-13.3687],[-47.6797,-13.4682],[-47.7982,-13.329],[-47.9668,-13.315],[-48.0745,-13.239],[-48.1699,-13.3003],[-48.1437,-13.1525],[-48.4589,-13.2804],[-48.5161,-13.1391],[-48.5801,-13.3133],[-48.5759,-13.1242],[-48.6447,-13.011],[-48.8703,-12.8033],[-48.8798,-12.8171],[-48.9762,-12.9579],[-49.1177,-12.7901],[-49.2377,-12.8838],[-49.3556,-13.1561],[-49.3683,-13.2723],[-49.9088,-12.9751],[-50.1852,-12.8936],[-50.3108,-12.7916],[-50.2448,-12.5975],[-50.1934,-12.5638],[-50.2152,-12.482],[-50.1418,-12.3954],[-50.3055,-12.4924],[-50.4342,-12.6494],[-50.511,-12.8609],[-50.5708,-13.0342],[-50.6111,-13.3202],[-50.6639,-13.435],[-50.759,-13.5203],[-50.8088,-13.6974],[-50.8739,-13.7345],[-50.8415,-14.1043],[-50.91,-14.1484],[-50.9979,-14.4138],[-50.9642,-14.5283],[-51.093,-14.8879],[-51.0924,-14.8945],[-51.0871,-14.9213],[-51.099,-14.9253],[-51.1028,-14.9265],[-51.2759,-15.0438],[-51.3071,-14.981],[-51.3387,-14.9751],[-51.3413,-14.9805],[-51.3474,-14.9877],[-51.3531,-14.9939],[-51.5341,-15.0652],[-51.6474,-15.1735],[-51.699,-15.4849],[-51.7807,-15.5464],[-51.7679,-15.6536],[-51.8803,-15.8243],[-51.9721,-15.8381],[-52.0095,-15.8858],[-52.2543,-15.8937],[-52.361,-16.0816],[-52.4717,-16.1267],[-52.5453,-16.2226],[-52.6812,-16.3017],[-52.6294,-16.5178],[-52.7328,-16.5859],[-52.7153,-16.637],[-52.8324,-16.7722],[-52.914,-16.8127],[-52.9291,-16.8376],[-53.0141,-16.8643],[-53.0592,-17.0768],[-53.1115,-17.1086],[-53.2173,-17.2968],[-53.242,-17.5042],[-53.2404,-17.6],[-53.2352,-17.7128],[-53.164,-17.7657],[-53.0723,-18.034],[-53.1432,-18.0841],[-53.0997,-18.3136],[-52.8208,-18.3107],[-52.7589,-18.3631],[-52.8385,-18.4236],[-52.9649,-18.55],[-52.9211,-18.6134],[-52.8734,-18.6459],[-52.7481,-18.6921],[-52.5019,-18.6759],[-52.4119,-18.744],[-52.3338,-18.8291],[-52.1831,-18.8476],[-52.0794,-18.9511],[-51.9407,-18.9682],[-51.8522,-19.0525],[-51.6921,-19.118],[-51.5392,-19.1427],[-51.4484,-19.1604],[-51.092,-19.3076],[-50.935,-19.4675],[-50.8256,-19.4733],[-50.8754,-19.4228],[-50.828,-19.3108],[-50.7404,-19.2132],[-50.7331,-19.187],[-50.6457,-19.1348],[-50.5352,-19.0989],[-50.4732,-18.9214],[-50.3523,-18.7603],[-50.27,-18.6842],[-50.0798,-18.6719],[-50.0288,-18.6015],[-49.7946,-18.6438],[-49.7577,-18.6097],[-49.723,-18.6094],[-49.5476,-18.5396],[-49.4862,-18.5323],[-49.3734,-18.6348],[-49.2927,-18.5639],[-49.2493,-18.5228],[-49.2058,-18.4141],[-49.0538,-18.4026],[-48.9595,-18.3235],[-48.9177,-18.3059],[-48.7872,-18.3532],[-48.6538,-18.3428],[-48.3418,-18.3708],[-48.2718,-18.3294],[-48.2272,-18.346],[-48.027,-18.4361],[-47.9546,-18.5],[-47.8646,-18.4491],[-47.8605,-18.4402],[-47.7695,-18.4183],[-47.6797,-18.3561],[-47.6102,-18.3157],[-47.607,-18.2462],[-47.4298,-18.1652],[-47.4079,-18.1419],[-47.2834,-18.0408],[-47.3712,-17.8313],[-47.2648,-17.6114],[-47.3131,-17.5434],[-47.4669,-17.534],[-47.5366,-17.4571],[-47.5246,-17.4119],[-47.5108,-17.3261],[-47.4886,-17.3487],[-47.352,-17.1665],[-47.1821,-17.064],[-47.1274,-16.9787],[-47.2084,-16.8747],[-47.2257,-16.7205],[-47.2955,-16.6258],[-47.4127,-16.5744],[-47.4544,-16.4646],[-47.3226,-16.2091],[-47.3085,-16.05],[-47.6836,-16.0498],[-47.9386,-16.0499],[-48.016,-16.0497],[-48.0178,-16.0497],[-48.0181,-16.0497],[-48.0848,-16.0497],[-48.2778,-16.0496],[-48.2818,-15.8306],[-48.208,-15.7179],[-48.2349,-15.66]]]},"properties":{"codarea":"52"}},
{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-48.016,-16.0497],[-47.9386,-16.0499],[-47.6836,-16.0498],[-47.3085,-16.05],[-47.31,-16.0363],[-47.3687,-16.0032],[-47.3787,-15.8842],[-47.3148,-15.7481],[-47.3209,-15.5866],[-47.4927,-15.5019],[-48.0348,-15.5022],[-48.0541,-15.5022],[-48.0543,-15.5022],[-48.0744,-15.5022],[-48.2,-15.5023],[-48.2349,-15.66],[-48.208,-15.7179],[-48.2818,-15.8306],[-48.2778,-16.0496],[-48.0848,-16.0497],[-48.0181,-16.0497],[-48.016,-16.0497]]]},"properties":{"codarea":"53"}}
]}$malha$::jsonb AS fc),
codigos (codigo, uf) AS (VALUES
  ('11','RO'),('12','AC'),('13','AM'),('14','RR'),('15','PA'),('16','AP'),('17','TO'),('21','MA'),('22','PI'),
  ('23','CE'),('24','RN'),('25','PB'),('26','PE'),('27','AL'),('28','SE'),('29','BA'),('31','MG'),('32','ES'),
  ('33','RJ'),('35','SP'),('41','PR'),('42','SC'),('43','RS'),('50','MS'),('51','MT'),('52','GO'),('53','DF')),
feicoes AS (
  SELECT f -> 'properties' ->> 'codarea' AS codigo,
         CASE f -> 'geometry' ->> 'type' WHEN 'Polygon' THEN jsonb_build_array(f -> 'geometry' -> 'coordinates')
                                         ELSE f -> 'geometry' -> 'coordinates' END AS poligonos
    FROM dados, jsonb_array_elements(dados.fc -> 'features') f)
INSERT INTO lote_interno.malha_uf (uf, codigo_ibge, poligonos)
SELECT c.uf, c.codigo, fe.poligonos FROM feicoes fe JOIN codigos c ON c.codigo = fe.codigo
ON CONFLICT (uf) DO UPDATE SET codigo_ibge = EXCLUDED.codigo_ibge, poligonos = EXCLUDED.poligonos;

DELETE FROM lote_interno.malha_uf_aneis;
INSERT INTO lote_interno.malha_uf_aneis (uf, poligono, anel, lats, lngs, min_lat, max_lat, min_lng, max_lng)
SELECT m.uf, p.i::int, a.j::int, v.lats, v.lngs,
       (SELECT min(x) FROM unnest(v.lats) x), (SELECT max(x) FROM unnest(v.lats) x),
       (SELECT min(x) FROM unnest(v.lngs) x), (SELECT max(x) FROM unnest(v.lngs) x)
  FROM lote_interno.malha_uf m
  CROSS JOIN LATERAL jsonb_array_elements(m.poligonos) WITH ORDINALITY p(pol, i)
  CROSS JOIN LATERAL jsonb_array_elements(p.pol) WITH ORDINALITY a(anel, j)
  CROSS JOIN LATERAL (SELECT array_agg((pt ->> 1)::double precision ORDER BY k) AS lats,
                             array_agg((pt ->> 0)::double precision ORDER BY k) AS lngs
                        FROM jsonb_array_elements(a.anel) WITH ORDINALITY q(pt, k)) v;

UPDATE lote_interno.malha_uf m
   SET min_lat = s.min_lat, max_lat = s.max_lat, min_lng = s.min_lng, max_lng = s.max_lng,
       area_caixa = (s.max_lat - s.min_lat) * (s.max_lng - s.min_lng)
  FROM (SELECT uf, min(min_lat) min_lat, max(max_lat) max_lat, min(min_lng) min_lng, max(max_lng) max_lng
          FROM lote_interno.malha_uf_aneis GROUP BY uf) s
 WHERE s.uf = m.uf;

DO $$
BEGIN
  IF (SELECT count(*) FROM lote_interno.malha_uf WHERE area_caixa IS NOT NULL) <> 27 THEN
    RAISE EXCEPTION 'Malha das UFs incompleta: esperado 27 UFs.';
  END IF;
END $$;

-- Ponto dentro do anel (teste de raio). Interna, sem GRANT.
CREATE OR REPLACE FUNCTION lote_interno.ponto_no_anel(p_lat double precision, p_lng double precision,
                                                      p_lats double precision[], p_lngs double precision[])
    RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  n integer := coalesce(array_length(p_lats, 1), 0);
  i integer; j integer; v_dentro boolean := false;
BEGIN
  IF n < 3 THEN RETURN false; END IF;
  j := n;
  FOR i IN 1 .. n LOOP
    IF ((p_lats[i] > p_lat) <> (p_lats[j] > p_lat))
       AND p_lng < (p_lngs[j] - p_lngs[i]) * (p_lat - p_lats[i]) / (p_lats[j] - p_lats[i]) + p_lngs[i] THEN
      v_dentro := NOT v_dentro;
    END IF;
    j := i;
  END LOOP;
  RETURN v_dentro;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.ponto_no_anel(double precision, double precision, double precision[], double precision[]) FROM PUBLIC, anon, authenticated;

-- Distância do ponto até o contorno do anel, em km (equirretangular na latitude do ponto). Interna.
CREATE OR REPLACE FUNCTION lote_interno.distancia_ao_anel_km(p_lat double precision, p_lng double precision,
                                                             p_lats double precision[], p_lngs double precision[])
    RETURNS double precision
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  n integer := coalesce(array_length(p_lats, 1), 0);
  kx double precision := 111.32 * cos(radians(p_lat));
  ky double precision := 110.57;
  i integer; ax double precision; ay double precision; qx double precision; qy double precision;
  dx double precision; dy double precision; l2 double precision; t double precision;
  v_min double precision := 'Infinity';
BEGIN
  FOR i IN 1 .. n - 1 LOOP
    ax := (p_lngs[i] - p_lng) * kx;     ay := (p_lats[i] - p_lat) * ky;
    qx := (p_lngs[i + 1] - p_lng) * kx; qy := (p_lats[i + 1] - p_lat) * ky;
    dx := qx - ax; dy := qy - ay; l2 := dx * dx + dy * dy;
    t := CASE WHEN l2 = 0 THEN 0 ELSE greatest(0, least(1, -(ax * dx + ay * dy) / l2)) END;
    v_min := least(v_min, sqrt((ax + t * dx) ^ 2 + (ay + t * dy) ^ 2));
  END LOOP;
  RETURN v_min;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.distancia_ao_anel_km(double precision, double precision, double precision[], double precision[]) FROM PUBLIC, anon, authenticated;

-- UF mais próxima do ponto (exceto p_exceto) e a distância em km, olhando primeiro os anéis de
-- caixa mais perto e parando quando nenhuma caixa restante pode ser mais perto. Interna.
CREATE OR REPLACE FUNCTION lote_interno.uf_mais_proxima(p_lat double precision, p_lng double precision, p_exceto text,
                                                        OUT uf text, OUT km double precision)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
#variable_conflict use_variable
DECLARE
  r record; v_d double precision;
  kx double precision := 111.32 * cos(radians(p_lat));
BEGIN
  km := 'Infinity';
  FOR r IN
    SELECT a.uf AS a_uf, a.lats, a.lngs,
           sqrt((greatest(a.min_lng - p_lng, 0, p_lng - a.max_lng) * kx) ^ 2
              + (greatest(a.min_lat - p_lat, 0, p_lat - a.max_lat) * 110.57) ^ 2) AS caixa_km
      FROM lote_interno.malha_uf_aneis a
     WHERE p_exceto IS NULL OR a.uf <> p_exceto
     ORDER BY 4
  LOOP
    EXIT WHEN r.caixa_km >= km;
    v_d := lote_interno.distancia_ao_anel_km(p_lat, p_lng, r.lats, r.lngs);
    IF v_d < km THEN km := v_d; uf := r.a_uf; END IF;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.uf_mais_proxima(double precision, double precision, text) FROM PUBLIC, anon, authenticated;

-- UF do ponto. Interna (a carga e a RPC chamam). Coordenada nula, 0,0 ou fora da faixa: tudo nulo.
CREATE OR REPLACE FUNCTION lote_interno.uf_do_ponto(p_lat double precision, p_lng double precision,
                                                    OUT uf text, OUT distancia_divisa_km numeric, OUT fora_da_malha boolean)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
#variable_conflict use_variable
DECLARE
  r record; v_k text; v_paridade jsonb := '{}'::jsonb; v_cand text[]; v_prox record;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL OR (p_lat = 0 AND p_lng = 0) OR abs(p_lat) > 90 OR abs(p_lng) > 180 THEN
    RETURN;
  END IF;
  FOR r IN
    SELECT a.uf AS a_uf, a.poligono, a.lats, a.lngs FROM lote_interno.malha_uf_aneis a
     WHERE p_lat BETWEEN a.min_lat AND a.max_lat AND p_lng BETWEEN a.min_lng AND a.max_lng
  LOOP
    IF lote_interno.ponto_no_anel(p_lat, p_lng, r.lats, r.lngs) THEN
      v_k := r.a_uf || ':' || r.poligono;
      v_paridade := v_paridade || jsonb_build_object(v_k, NOT coalesce((v_paridade ->> v_k)::boolean, false));
    END IF;
  END LOOP;
  SELECT array_agg(DISTINCT split_part(e.key, ':', 1)) INTO v_cand
    FROM jsonb_each_text(v_paridade) e WHERE e.value::boolean;

  IF v_cand IS NOT NULL THEN
    SELECT m.uf INTO uf FROM lote_interno.malha_uf m WHERE m.uf = ANY (v_cand) ORDER BY m.area_caixa, m.uf LIMIT 1;
    fora_da_malha := false;
  ELSE
    SELECT * INTO v_prox FROM lote_interno.uf_mais_proxima(p_lat, p_lng, NULL);
    uf := v_prox.uf;
    fora_da_malha := true;
  END IF;
  SELECT * INTO v_prox FROM lote_interno.uf_mais_proxima(p_lat, p_lng, uf);
  distancia_divisa_km := round(v_prox.km::numeric, 1);
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.uf_do_ponto(double precision, double precision) FROM PUBLIC, anon, authenticated;

-- RPC da Nova: UF do pino movido ou da sugestão sem região. Qualquer perfil autenticado.
CREATE OR REPLACE FUNCTION public.uf_da_coordenada(p_lat double precision, p_lng double precision)
    RETURNS TABLE (uf text, distancia_divisa_km numeric, fora_da_malha boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
#variable_conflict use_column
DECLARE
  v_perfil text;
BEGIN
  v_perfil := public.get_meu_perfil();
  IF v_perfil IS NULL THEN
    RAISE EXCEPTION 'Sem permissão para consultar a UF.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT u.uf, u.distancia_divisa_km, u.fora_da_malha
                 FROM lote_interno.uf_do_ponto(p_lat, p_lng) u WHERE u.uf IS NOT NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.uf_da_coordenada(double precision, double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.uf_da_coordenada(double precision, double precision) TO authenticated;

-- ════════ 3. Carga da UF das escoltas existentes ════════
CREATE TABLE IF NOT EXISTS backup_20261008.uf_a_conferir (
  escolta_id          uuid NOT NULL,
  lado                text NOT NULL CHECK (lado IN ('origem', 'destino')),
  codigo_escolta      text,
  uf                  text,
  distancia_divisa_km numeric,
  fora_da_malha       boolean,
  lat                 numeric,
  lng                 numeric,
  registrado_em       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (escolta_id, lado)
);
REVOKE ALL ON backup_20261008.uf_a_conferir FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION lote_interno.carregar_uf_escoltas() RETURNS integer
    LANGUAGE plpgsql VOLATILE
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  e record; o record; d record; v_n integer := 0;
BEGIN
  FOR e IN
    SELECT x.id, x.codigo_escolta, x.origem_lat, x.origem_lng, x.destino_lat, x.destino_lng
      FROM public.escoltas x
     WHERE x.origem_uf IS NULL AND x.destino_uf IS NULL
       AND coalesce(x.codigo_escolta, '') NOT IN ('ESC-2026-0001', 'ESC-2026-0007')
     ORDER BY x.codigo_escolta, x.id
  LOOP
    SELECT * INTO o FROM lote_interno.uf_do_ponto(e.origem_lat::double precision, e.origem_lng::double precision);
    SELECT * INTO d FROM lote_interno.uf_do_ponto(e.destino_lat::double precision, e.destino_lng::double precision);
    CONTINUE WHEN o.uf IS NULL AND d.uf IS NULL;
    UPDATE public.escoltas SET origem_uf = o.uf, destino_uf = d.uf, uf_estimada = true WHERE id = e.id;
    v_n := v_n + 1;
    IF o.uf IS NOT NULL AND (o.fora_da_malha OR o.distancia_divisa_km < 5) THEN
      INSERT INTO backup_20261008.uf_a_conferir (escolta_id, lado, codigo_escolta, uf, distancia_divisa_km, fora_da_malha, lat, lng)
      VALUES (e.id, 'origem', e.codigo_escolta, o.uf, o.distancia_divisa_km, o.fora_da_malha, e.origem_lat, e.origem_lng)
      ON CONFLICT (escolta_id, lado) DO UPDATE SET uf = EXCLUDED.uf, distancia_divisa_km = EXCLUDED.distancia_divisa_km,
        fora_da_malha = EXCLUDED.fora_da_malha, lat = EXCLUDED.lat, lng = EXCLUDED.lng, registrado_em = now();
    END IF;
    IF d.uf IS NOT NULL AND (d.fora_da_malha OR d.distancia_divisa_km < 5) THEN
      INSERT INTO backup_20261008.uf_a_conferir (escolta_id, lado, codigo_escolta, uf, distancia_divisa_km, fora_da_malha, lat, lng)
      VALUES (e.id, 'destino', e.codigo_escolta, d.uf, d.distancia_divisa_km, d.fora_da_malha, e.destino_lat, e.destino_lng)
      ON CONFLICT (escolta_id, lado) DO UPDATE SET uf = EXCLUDED.uf, distancia_divisa_km = EXCLUDED.distancia_divisa_km,
        fora_da_malha = EXCLUDED.fora_da_malha, lat = EXCLUDED.lat, lng = EXCLUDED.lng, registrado_em = now();
    END IF;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.carregar_uf_escoltas() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE v_n integer;
BEGIN
  v_n := lote_interno.carregar_uf_escoltas();
  RAISE NOTICE 'Onda K: % escolta(s) com UF carregada pela coordenada; % lado(s) na lista de conferência.',
    v_n, (SELECT count(*) FROM backup_20261008.uf_a_conferir);
END $$;

-- ════════ 4. Paleta de cores de cliente ════════
CREATE OR REPLACE FUNCTION lote_interno.cor_lab(p_hex text) RETURNS double precision[]
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  c double precision[] := '{}'; i integer; v double precision;
  x double precision; y double precision; z double precision;
  fx double precision; fy double precision; fz double precision;
BEGIN
  FOR i IN 0 .. 2 LOOP
    v := ('x' || substr(p_hex, 2 + 2 * i, 2))::bit(8)::integer / 255.0;
    c := c || CASE WHEN v <= 0.04045 THEN v / 12.92 ELSE ((v + 0.055) / 1.055) ^ 2.4 END;
  END LOOP;
  x := (0.4124 * c[1] + 0.3576 * c[2] + 0.1805 * c[3]) / 0.95047;
  y :=  0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3];
  z := (0.0193 * c[1] + 0.1192 * c[2] + 0.9505 * c[3]) / 1.08883;
  fx := CASE WHEN x > 0.008856 THEN cbrt(x) ELSE 7.787 * x + 16.0 / 116 END;
  fy := CASE WHEN y > 0.008856 THEN cbrt(y) ELSE 7.787 * y + 16.0 / 116 END;
  fz := CASE WHEN z > 0.008856 THEN cbrt(z) ELSE 7.787 * z + 16.0 / 116 END;
  RETURN ARRAY[116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.cor_lab(text) FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.paleta_clientes (
  cor    text PRIMARY KEY CHECK (cor ~ '^#[0-9A-F]{6}$'),
  nome   text NOT NULL,
  ordem  smallint NOT NULL UNIQUE,
  padrao boolean NOT NULL DEFAULT false,
  lab    double precision[] NOT NULL
);
ALTER TABLE public.paleta_clientes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.paleta_clientes FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.paleta_clientes IS 'Onda K: paleta fechada de cores de cliente (a mesma de lib/paleta-clientes.ts). Só a trigger de clientes lê.';
INSERT INTO public.paleta_clientes (cor, nome, ordem, padrao, lab)
SELECT v.cor, v.nome, v.ordem, v.ordem = 1, lote_interno.cor_lab(v.cor)
  FROM (VALUES ('#1D4ED8', 'Azul', 1), ('#15803D', 'Verde', 2), ('#B91C1C', 'Vermelho', 3), ('#A16207', 'Mostarda', 4),
               ('#7C3AED', 'Violeta', 5), ('#BE185D', 'Rosa escuro', 6), ('#4D7C0F', 'Oliva', 7), ('#475569', 'Grafite', 8),
               ('#1E3A8A', 'Marinho', 9), ('#86198F', 'Ameixa', 10), ('#115E59', 'Petróleo', 11), ('#6B4423', 'Marrom', 12)) v(cor, nome, ordem)
ON CONFLICT (cor) DO UPDATE SET nome = EXCLUDED.nome, ordem = EXCLUDED.ordem, padrao = EXCLUDED.padrao, lab = EXCLUDED.lab;

-- Cor da paleta mais próxima (CIE76), sem as de p_excluir enquanto sobrar alguma. Texto que não
-- é #rrggbb vira a padrão (ou a livre mais próxima da padrão). Interna.
CREATE OR REPLACE FUNCTION lote_interno.cor_da_paleta(p_cor text, p_excluir text[] DEFAULT '{}')
    RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_base text; v_lab double precision[]; v_res text;
BEGIN
  IF p_cor IS NOT NULL AND btrim(p_cor) ~* '^#[0-9a-f]{6}$' THEN
    v_base := upper(btrim(p_cor));
  ELSE
    SELECT cor INTO v_base FROM public.paleta_clientes WHERE padrao;
  END IF;
  v_lab := lote_interno.cor_lab(v_base);
  SELECT p.cor INTO v_res
    FROM public.paleta_clientes p
   WHERE NOT p.cor = ANY (coalesce(p_excluir, '{}'))
   ORDER BY (p.lab[1] - v_lab[1]) ^ 2 + (p.lab[2] - v_lab[2]) ^ 2 + (p.lab[3] - v_lab[3]) ^ 2, p.ordem
   LIMIT 1;
  IF v_res IS NULL THEN
    SELECT p.cor INTO v_res FROM public.paleta_clientes p
     ORDER BY (p.lab[1] - v_lab[1]) ^ 2 + (p.lab[2] - v_lab[2]) ^ 2 + (p.lab[3] - v_lab[3]) ^ 2, p.ordem
     LIMIT 1;
  END IF;
  RETURN v_res;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.cor_da_paleta(text, text[]) FROM PUBLIC, anon, authenticated;

-- Trigger: qualquer cor gravada em clientes cai na paleta. SECURITY DEFINER porque lê a paleta,
-- que nenhum perfil lê direto. Nunca recusa.
CREATE OR REPLACE FUNCTION lote_interno.normalizar_cor_cliente() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  NEW.cor_destaque := lote_interno.cor_da_paleta(NEW.cor_destaque);
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lote_interno.normalizar_cor_cliente() FROM PUBLIC, anon, authenticated;

ALTER TABLE public.clientes ALTER COLUMN cor_destaque SET DEFAULT '#1D4ED8';

CREATE TABLE IF NOT EXISTS backup_20261008.cores_clientes (
  cliente_id   uuid PRIMARY KEY,
  nome_cliente text,
  cor_antiga   text,
  cor_nova     text,
  ativo        boolean,
  guardado_em  timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON backup_20261008.cores_clientes FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  c record; v_usadas text[] := '{}'; v_nova text; v_trocas integer := 0;
BEGIN
  IF current_setting('lote216.carregar_cores', true) IS DISTINCT FROM 'on' THEN
    RAISE NOTICE 'Onda K: paleta já existia; cores dos clientes não redistribuídas.';
    RETURN;
  END IF;
  FOR c IN SELECT id, nome_cliente, cor_destaque, status FROM public.clientes
            ORDER BY (status = 'ativo') DESC, criado_em, id LOOP
    IF c.status = 'ativo' THEN
      v_nova := lote_interno.cor_da_paleta(c.cor_destaque, v_usadas);
      v_usadas := v_usadas || v_nova;
    ELSE
      v_nova := lote_interno.cor_da_paleta(c.cor_destaque);
    END IF;
    INSERT INTO backup_20261008.cores_clientes (cliente_id, nome_cliente, cor_antiga, cor_nova, ativo)
    VALUES (c.id, c.nome_cliente, c.cor_destaque, v_nova, c.status = 'ativo')
    ON CONFLICT (cliente_id) DO UPDATE SET cor_nova = EXCLUDED.cor_nova, nome_cliente = EXCLUDED.nome_cliente,
                                           ativo = EXCLUDED.ativo, guardado_em = now();
    IF c.cor_destaque IS DISTINCT FROM v_nova THEN
      UPDATE public.clientes SET cor_destaque = v_nova WHERE id = c.id;
      v_trocas := v_trocas + 1;
      RAISE NOTICE 'Onda K: cliente % (%): cor % para %', left(c.id::text, 8), c.status, coalesce(c.cor_destaque, 'nula'), v_nova;
    END IF;
  END LOOP;
  RAISE NOTICE 'Onda K: % cliente(s) com a cor trocada para a paleta.', v_trocas;
END $$;

DROP TRIGGER IF EXISTS tr_normalizar_cor_cliente ON public.clientes;
CREATE TRIGGER tr_normalizar_cor_cliente BEFORE INSERT OR UPDATE OF cor_destaque ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION lote_interno.normalizar_cor_cliente();

-- ════════ 6. Cor do cliente no mural do operador ════════
-- A RLS de clientes (clientes_operador_select) só mostra ao operador o cliente das escoltas em
-- que ele está no efetivo: no mural (agendadas de outras equipes) o cliente vem nulo e todas as
-- escoltas sairiam na mesma cor. Esta RPC devolve só a COR do cliente (nunca o nome, que
-- continua sigiloso para quem não é da escolta) das escoltas que a pessoa já enxerga pela
-- escoltas_select (gestão, efetivo da escolta ou agendada) e pela escoltas_arquivada_so_admin.
CREATE OR REPLACE FUNCTION public.cores_clientes_das_escoltas(p_escolta_ids uuid[])
    RETURNS TABLE (escolta_id uuid, cor_destaque text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
#variable_conflict use_column
DECLARE
  v_perfil text;
BEGIN
  v_perfil := public.get_meu_perfil();
  IF v_perfil IS NULL THEN
    RAISE EXCEPTION 'Sem permissão para consultar as cores dos clientes.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT e.id, c.cor_destaque
      FROM public.escoltas e JOIN public.clientes c ON c.id = e.cliente_id
     WHERE e.id = ANY (coalesce(p_escolta_ids, '{}'))
       AND (v_perfil IN ('administrador', 'gestor', 'supervisor', 'central') OR public.sou_do_efetivo(e.id) OR e.status = 'agendada')
       AND (e.arquivada_em IS NULL OR v_perfil = 'administrador');
END;
$$;
REVOKE ALL ON FUNCTION public.cores_clientes_das_escoltas(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cores_clientes_das_escoltas(uuid[]) TO authenticated;

-- ════════ 5. Operador não altera a UF (197 recriada) ════════
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
                               'criada_por','escala_fixa','metadados','data_solicitacao','criado_em',
                               -- onda K (216): UF de origem e destino e a marca de estimativa
                               'origem_uf','destino_uf','uf_estimada']
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
-- 216_uf_e_paleta:
-- SELECT * FROM backup_20261008.uf_a_conferir ORDER BY codigo_escolta, lado;   -- lista de UF a conferir, para o relatório
-- SELECT nome_cliente, cor_antiga, cor_nova, ativo FROM backup_20261008.cores_clientes ORDER BY ativo DESC, nome_cliente;  -- trocas de cor, para o relatório
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
UNION ALL SELECT 'onda D2: locais com UF RJ (esperado 5) e uso carregado das escoltas', (SELECT count(*) FROM public.locais_salvos WHERE uf = 'RJ') || '; ' || (SELECT string_agg(nome || '=' || vezes_usado, ', ' ORDER BY vezes_usado DESC, nome) FROM public.locais_salvos)
UNION ALL SELECT 'onda K: malha (esperado 27), paleta (12, 1 padrão), trigger de cor (1)', (SELECT count(*) FROM lote_interno.malha_uf) || ', ' || (SELECT count(*) FROM public.paleta_clientes) || ', ' || (SELECT count(*) FROM public.paleta_clientes WHERE padrao) || ', ' || (SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_normalizar_cor_cliente')
UNION ALL SELECT 'onda K: escoltas com UF, interestaduais, sem determinar, a conferir', (SELECT count(*) FROM public.escoltas WHERE origem_uf IS NOT NULL OR destino_uf IS NOT NULL) || ', ' || (SELECT count(*) FROM public.escoltas WHERE interestadual) || ', ' || (SELECT count(*) FROM public.escoltas WHERE interestadual IS NULL) || ', ' || (SELECT count(*) FROM backup_20261008.uf_a_conferir)
UNION ALL SELECT 'onda K: ESC-2026-0001 e 0007 sem UF (esperado 0)', count(*)::text FROM public.escoltas WHERE codigo_escolta IN ('ESC-2026-0001', 'ESC-2026-0007') AND (origem_uf IS NOT NULL OR destino_uf IS NOT NULL OR uf_estimada)
UNION ALL SELECT 'onda K: clientes fora da paleta (esperado 0) e trocas de cor', (SELECT count(*) FROM public.clientes c WHERE NOT EXISTS (SELECT 1 FROM public.paleta_clientes p WHERE p.cor = c.cor_destaque)) || '; ' || (SELECT count(*) FROM backup_20261008.cores_clientes WHERE cor_antiga IS DISTINCT FROM cor_nova)
UNION ALL SELECT 'onda K: RPCs para authenticated (esperado true, true)', has_function_privilege('authenticated', 'public.uf_da_coordenada(double precision, double precision)', 'EXECUTE') || ', ' || has_function_privilege('authenticated', 'public.cores_clientes_das_escoltas(uuid[])', 'EXECUTE');
-- Esperado: 9 funções, 8 tabelas, 0 abertas com periodicidade, 5 locais aguardando_conferencia,
-- troca true,true, cron lote2026_avisos_telegram e lote2026_avisos_checkin; 4; notificacoes_select; 0; false; false;
-- onda I: 9; 9, 10, 3; 3; 0; 11; true; onda D2: 2, false; 0; 5 e o uso de cada local (escoltas não canceladas);
-- onda K: 27, 12, 1, 1; os números da carga de UF; 0; 0 e as trocas; true, true. ESC-2026-0001 e 0007: atualizado_em igual ao da consulta prévia
-- (a 213 não reescreve a linha; a carga da 215 só lê escoltas; a carga de UF da 216 as exclui e a coluna gerada
-- interestadual reescreve a tabela por dentro sem trigger e sem mudar valor).
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

-- ──────── reverter 216_uf_e_paleta ────────
-- -- 216_uf_e_paleta_reverter.sql
-- -- ORDEM: primeiro o git revert do código da onda K e o deploy; depois este arquivo (antes da
-- -- 215_reverter). Guarda as UFs em backup_20261008.escoltas_uf (uma linha por escolta com UF;
-- -- rodar de novo não apaga o que já foi guardado), devolve a cor antiga (backup_20261008.cores_clientes)
-- -- aos clientes que continuam com a cor da carga (quem trocou de cor depois da 216 fica com a da
-- -- paleta, que também é válida), devolve o DEFAULT antigo da cor, tira a trigger de cor, a paleta,
-- -- as RPCs uf_da_coordenada e cores_clientes_das_escoltas, as funções internas, a malha, o índice, as restrições e as colunas
-- -- (a gerada primeiro) e recria impedir_edicao_por_operador com o corpo da 197.
-- -- A lista de conferência (backup_20261008.uf_a_conferir) e os backups ficam.
-- CREATE SCHEMA IF NOT EXISTS backup_20261008;
-- REVOKE ALL ON SCHEMA backup_20261008 FROM PUBLIC, anon, authenticated;
-- DO $$
-- BEGIN
--   IF EXISTS (SELECT 1 FROM information_schema.columns
--               WHERE table_schema = 'public' AND table_name = 'escoltas' AND column_name = 'origem_uf') THEN
--     CREATE TABLE IF NOT EXISTS backup_20261008.escoltas_uf (escolta_id uuid PRIMARY KEY, codigo_escolta text,
--       origem_uf text, destino_uf text, uf_estimada boolean, guardado_em timestamptz NOT NULL DEFAULT now());
--     REVOKE ALL ON backup_20261008.escoltas_uf FROM PUBLIC, anon, authenticated;
--     EXECUTE $q$
--       INSERT INTO backup_20261008.escoltas_uf (escolta_id, codigo_escolta, origem_uf, destino_uf, uf_estimada)
--       SELECT id, codigo_escolta, origem_uf, destino_uf, uf_estimada FROM public.escoltas
--        WHERE origem_uf IS NOT NULL OR destino_uf IS NOT NULL
--       ON CONFLICT (escolta_id) DO UPDATE SET origem_uf = EXCLUDED.origem_uf, destino_uf = EXCLUDED.destino_uf,
--         uf_estimada = EXCLUDED.uf_estimada, guardado_em = now()$q$;
--   END IF;
-- END $$;
--
-- -- Cor: trigger fora antes de devolver a cor antiga (senão ela voltaria para a paleta).
-- DROP TRIGGER IF EXISTS tr_normalizar_cor_cliente ON public.clientes;
-- DROP FUNCTION IF EXISTS lote_interno.normalizar_cor_cliente();
-- DO $$
-- BEGIN
--   IF to_regclass('backup_20261008.cores_clientes') IS NOT NULL THEN
--     UPDATE public.clientes c SET cor_destaque = b.cor_antiga
--       FROM backup_20261008.cores_clientes b
--      WHERE b.cliente_id = c.id AND c.cor_destaque IS NOT DISTINCT FROM b.cor_nova
--        AND c.cor_destaque IS DISTINCT FROM b.cor_antiga;
--   END IF;
-- END $$;
-- ALTER TABLE public.clientes ALTER COLUMN cor_destaque SET DEFAULT '#3B82F6'::text;
-- DROP FUNCTION IF EXISTS lote_interno.cor_da_paleta(text, text[]);
-- DROP TABLE IF EXISTS public.paleta_clientes;
-- DROP FUNCTION IF EXISTS lote_interno.cor_lab(text);
--
-- -- UF.
-- DROP FUNCTION IF EXISTS public.cores_clientes_das_escoltas(uuid[]);
-- DROP FUNCTION IF EXISTS public.uf_da_coordenada(double precision, double precision);
-- DROP FUNCTION IF EXISTS lote_interno.carregar_uf_escoltas();
-- DROP FUNCTION IF EXISTS lote_interno.uf_do_ponto(double precision, double precision);
-- DROP FUNCTION IF EXISTS lote_interno.uf_mais_proxima(double precision, double precision, text);
-- DROP FUNCTION IF EXISTS lote_interno.distancia_ao_anel_km(double precision, double precision, double precision[], double precision[]);
-- DROP FUNCTION IF EXISTS lote_interno.ponto_no_anel(double precision, double precision, double precision[], double precision[]);
-- DROP TABLE IF EXISTS lote_interno.malha_uf_aneis;
-- DROP TABLE IF EXISTS lote_interno.malha_uf;
-- DROP INDEX IF EXISTS public.idx_escoltas_interestadual;
-- ALTER TABLE public.escoltas DROP CONSTRAINT IF EXISTS escoltas_origem_uf_formato;
-- ALTER TABLE public.escoltas DROP CONSTRAINT IF EXISTS escoltas_destino_uf_formato;
-- ALTER TABLE public.escoltas DROP COLUMN IF EXISTS interestadual;
-- ALTER TABLE public.escoltas DROP COLUMN IF EXISTS uf_estimada;
-- ALTER TABLE public.escoltas DROP COLUMN IF EXISTS destino_uf;
-- ALTER TABLE public.escoltas DROP COLUMN IF EXISTS origem_uf;
--
-- -- Corpo da 197 (sem as colunas da UF).
-- CREATE OR REPLACE FUNCTION public.impedir_edicao_por_operador() RETURNS trigger
--     LANGUAGE plpgsql SECURITY DEFINER
--     SET search_path TO 'public', 'pg_temp'
--     AS $$
-- DECLARE
--   v_perfil text;
--   v_col    text;
--   v_old    jsonb;
--   v_new    jsonb;
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
--   -- ATENCAO (lote 2026-10): esta trigger compara checklist_pendente_no_inicio, que a
--   -- tr_verificar_checklist_pendente grava no mesmo UPDATE. Funciona porque as BEFORE
--   -- UPDATE rodam em ordem alfabetica e tr_impedir_... vem antes de tr_verificar_...
--   -- Nao renomear nenhuma das duas sem rever isto.
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
--   -- Lote 2026-10: financeiro, controle do fluxo e escala. Comparacao por jsonb para valer
--   -- tambem para coluna criada depois desta funcao (escala_fixa, onda C).
--   v_old := to_jsonb(OLD);
--   v_new := to_jsonb(NEW);
--   -- Escolta encerrada não muda mais pelo operador (relatório final e horário de término).
--   IF OLD.status IN ('finalizada', 'cancelada') THEN
--     RAISE EXCEPTION 'Escolta encerrada. Fale com o supervisor para corrigir.';
--   END IF;
--
--   -- Relatório final e término só junto da própria finalização.
--   IF (NEW.observacao_fechamento IS DISTINCT FROM OLD.observacao_fechamento
--       OR NEW.data_finalizacao IS DISTINCT FROM OLD.data_finalizacao)
--      AND NEW.status IS DISTINCT FROM 'finalizada' THEN
--     RAISE EXCEPTION 'O relatorio final so e gravado na finalizacao da escolta.';
--   END IF;
--
--   FOREACH v_col IN ARRAY ARRAY['valor_cobrado','outros_custos','observacao_financeira','fluxo_versao',
--                                'checklist_pendente_no_inicio','periodicidade_checkin_min','codigo_escolta',
--                                'criada_por','escala_fixa','metadados','data_solicitacao','criado_em']
--   LOOP
--     IF (v_new -> v_col) IS DISTINCT FROM (v_old -> v_col) THEN
--       RAISE EXCEPTION 'Operador nao altera este campo da escolta (%). Fale com o supervisor.', v_col;
--     END IF;
--   END LOOP;
--
--   IF NEW.status = 'cancelada' AND OLD.status IS DISTINCT FROM 'cancelada' THEN
--     RAISE EXCEPTION 'Somente a supervisao cancela uma escolta.';
--   END IF;
--
--   RETURN NEW;
-- END;
-- $$;
-- REVOKE ALL ON FUNCTION public.impedir_edicao_por_operador() FROM PUBLIC, anon, authenticated;

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
