-- Fase 0 do Modo Guiado: leitura das regras que decidem se um participante
-- vinculado a escolta consegue registrar por QUALQUER viatura da mesma escolta.
--
-- SOMENTE LEITURA. Nao cria, nao altera, nao apaga nada.
-- Rodar no SQL Editor do Supabase, projeto qthoyxujyzskydulvcfy, DEPOIS da
-- migration 193. E uma consulta unica de proposito: o SQL Editor mostra so o
-- resultado da ultima instrucao.
--
-- O que conferir no retorno (colunas secao, objeto, detalhe):
--   policy   : o predicado de INSERT/UPDATE de pontos_controle, fotos,
--              escolta_veiculos, escoltas, checklists, checklist_respostas,
--              ocorrencias, emergencias. Se usar sou_do_efetivo_veiculo(...),
--              o participante so grava na PROPRIA viatura, e a regra aprovada
--              em 29/09 (qualquer viatura da escolta) exige migration.
--   funcao   : corpo de sou_do_efetivo, sou_do_efetivo_veiculo e das funcoes de
--              trigger das tabelas acima, inclusive impedir_edicao_por_operador.
--   trigger  : quais triggers existem nessas tabelas e em que evento.
--   vinculo  : operadores ainda sem vinculo (esperado: zero linhas desta secao).

WITH tabelas(nome) AS (
  VALUES ('pontos_controle'), ('fotos'), ('escolta_veiculos'), ('escoltas'),
         ('checklists'), ('checklist_respostas'), ('ocorrencias'), ('emergencias'),
         ('escolta_status_historico'), ('escolta_efetivo')
),
pol AS (
  SELECT 'policy'::text AS secao,
         p.tablename || '.' || p.policyname || ' [' || p.cmd || ']' AS objeto,
         'USING: ' || coalesce(p.qual, '-') || E'\nWITH CHECK: ' || coalesce(p.with_check, '-') AS detalhe
  FROM pg_policies p
  JOIN tabelas t ON t.nome = p.tablename
  WHERE p.schemaname = 'public'
),
trg AS (
  SELECT 'trigger'::text,
         c.relname || '.' || tg.tgname,
         pg_get_triggerdef(tg.oid)
  FROM pg_trigger tg
  JOIN pg_class c ON c.oid = tg.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN tabelas t ON t.nome = c.relname
  WHERE n.nspname = 'public' AND NOT tg.tgisinternal
),
fn AS (
  SELECT DISTINCT 'funcao'::text,
         pr.proname,
         pg_get_functiondef(pr.oid)
  FROM pg_proc pr
  JOIN pg_namespace n ON n.oid = pr.pronamespace
  WHERE n.nspname = 'public'
    AND (
      pr.proname IN ('sou_do_efetivo', 'sou_do_efetivo_veiculo', 'impedir_edicao_por_operador')
      OR pr.oid IN (
        SELECT tg.tgfoid
        FROM pg_trigger tg
        JOIN pg_class c ON c.oid = tg.tgrelid
        JOIN tabelas t ON t.nome = c.relname
        WHERE NOT tg.tgisinternal
      )
    )
),
vinc AS (
  SELECT 'vinculo'::text,
         u.nome_completo,
         'operador sem vigilante vinculado'
  FROM usuarios u
  JOIN dom_perfis dp ON dp.id = u.perfil_id
  WHERE dp.codigo = 'operador'
    AND NOT EXISTS (SELECT 1 FROM vigilantes v WHERE v.usuario_id = u.id)
)
SELECT * FROM pol
UNION ALL SELECT * FROM trg
UNION ALL SELECT * FROM fn
UNION ALL SELECT * FROM vinc
ORDER BY 1, 2;
