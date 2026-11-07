-- 220_endereco_pos_envio_reverter.sql
-- Reversão da 220. Idempotente. Os endereços já gravados ficam (são só rótulo dentro de
-- observacoes); sem a função, o ponto sem endereço volta a ficar só com a coordenada.
DROP FUNCTION IF EXISTS public.preencher_endereco_ponto(uuid, text);
