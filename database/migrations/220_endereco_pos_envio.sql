-- 220_endereco_pos_envio.sql
-- Onda M (leveza), item B2 do comando de 06/11/2026; docs/12 item 0.7 e plano do lote 16.3 item 10.
-- Idempotente. Bloco 1, no fim (depois da 216). Compatível com a master 2b3fff9: só cria uma
-- função nova, que a master não chama; nenhuma tabela, coluna, policy ou trigger muda.
--
-- Por quê:
-- 1. O ponto gravado sem internet (fila da onda L) ou pelo check-in do Campo sem resposta da
--    Mapbox chega ao banco só com a coordenada: o endereço por extenso, guardado dentro de
--    pontos_controle.observacoes (JSON de lib/pontos-controle.ts, chave "endereco"), fica nulo.
-- 2. O aparelho, quando termina de enviar a fila, chama a rota /api/pontos/endereco (sessão
--    obrigatória e limite por usuário). A rota lê os pontos com a RLS de quem chama, faz a
--    geocodificação reversa no servidor uma única vez e grava o texto por esta função.
-- 3. O operador não tem UPDATE em pontos_controle (pontos_update é só da gestão). Por isso a
--    função é SECURITY DEFINER e se protege sozinha:
--    - só quem é usuário ativo (get_meu_usuario_id não nulo);
--    - só o autor do ponto (lancado_por) ou administrador, gestor e supervisor;
--    - só ponto não anulado;
--    - só quando o endereço está vazio: grava uma única vez, nunca troca um endereço existente;
--    - texto aparado, de 3 a 300 caracteres.
-- 4. A coordenada do GPS continua sendo a verdade: o texto é rótulo, mostrado como "endereço
--    aproximado" (lib/rotulo-ponto.ts). O autor já podia mandar o endereço na criação do ponto;
--    esta função não abre nada além disso.
-- 5. Nenhuma coluna travada pela 214 muda (lancado_por, data_hora, anulação): só observacoes.

CREATE OR REPLACE FUNCTION public.preencher_endereco_ponto(p_ponto_id uuid, p_endereco text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_eu uuid := public.get_meu_usuario_id();
  v_perfil text := public.get_meu_perfil();
  v_texto text := btrim(coalesce(p_endereco, ''));
  v_autor uuid;
  v_obs text;
  v_json jsonb;
BEGIN
  IF v_eu IS NULL OR v_perfil IS NULL THEN
    RAISE EXCEPTION 'Usuário sem cadastro ativo.' USING ERRCODE = '42501';
  END IF;
  IF length(v_texto) < 3 OR length(v_texto) > 300 THEN
    RETURN false;
  END IF;

  SELECT lancado_por, observacoes INTO v_autor, v_obs
    FROM pontos_controle
   WHERE id = p_ponto_id AND anulado_em IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  IF v_autor IS DISTINCT FROM v_eu AND v_perfil NOT IN ('administrador', 'gestor', 'supervisor') THEN
    RETURN false;
  END IF;

  IF v_obs IS NULL OR btrim(v_obs) = '' THEN
    v_json := '{}'::jsonb;
  ELSIF left(btrim(v_obs), 1) = '{' THEN
    BEGIN
      v_json := v_obs::jsonb;
    EXCEPTION WHEN others THEN
      RETURN false; -- JSON malformado: não mexe (a leitura da tela preserva o texto)
    END;
  ELSE
    -- Texto puro legado: vira o campo observacao, como lerObservacao já mostra.
    v_json := jsonb_build_object('observacao', v_obs, 'foto_ids', '[]'::jsonb);
  END IF;

  IF jsonb_typeof(v_json) <> 'object' THEN RETURN false; END IF;
  IF coalesce(btrim(v_json ->> 'endereco'), '') <> '' THEN RETURN false; END IF;

  UPDATE pontos_controle
     SET observacoes = (v_json || jsonb_build_object('endereco', v_texto))::text
   WHERE id = p_ponto_id;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.preencher_endereco_ponto(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.preencher_endereco_ponto(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.preencher_endereco_ponto(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.preencher_endereco_ponto(uuid, text) IS
  'Onda M (220): grava uma única vez o endereço por extenso de um ponto que chegou sem ele (autor ou gestão).';
