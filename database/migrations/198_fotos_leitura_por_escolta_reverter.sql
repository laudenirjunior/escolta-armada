-- 198_fotos_leitura_por_escolta_reverter.sql
-- Antes de reverter com o bucket fechado, reverta a 200 (senão as fotos somem das telas).
DROP POLICY IF EXISTS fotos_leitura_autenticada ON storage.objects;
DROP POLICY IF EXISTS fotos_select_por_escolta ON public.fotos;
DROP FUNCTION IF EXISTS public.escolta_do_caminho(text);
