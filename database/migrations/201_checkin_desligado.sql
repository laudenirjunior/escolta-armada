-- 201_checkin_desligado.sql
-- Lote 2026-10, onda B (M4). Idempotente. Bloco 1 (antes do deploy; compatível com o código atual).
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
GRANT SELECT, INSERT, UPDATE, DELETE ON public.alertas_dispensados TO authenticated;
DROP POLICY IF EXISTS alertas_dispensados_proprio ON public.alertas_dispensados;
CREATE POLICY alertas_dispensados_proprio ON public.alertas_dispensados FOR ALL TO authenticated
  USING (usuario_id = (SELECT public.get_meu_usuario_id()))
  WITH CHECK (usuario_id = (SELECT public.get_meu_usuario_id()));

-- Conferência:
-- SELECT count(*) FROM escoltas WHERE status NOT IN ('finalizada','cancelada') AND periodicidade_checkin_min IS NOT NULL; -- 0
-- SELECT count(*) FROM backup_20261008.periodicidade_checkin;   -- 8 em 08/10/2026
