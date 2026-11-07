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
