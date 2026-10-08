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
      OR EXISTS (SELECT 1 FROM public.fotos f
                 WHERE f.caminho_arquivo = storage.objects.name
                   AND f.criado_por = (SELECT public.get_meu_usuario_id()))
    )
  );

-- Conferência: SELECT policyname FROM pg_policies WHERE policyname IN
--   ('fotos_select_por_escolta','fotos_leitura_autenticada');   -- esperado: 2 linhas
