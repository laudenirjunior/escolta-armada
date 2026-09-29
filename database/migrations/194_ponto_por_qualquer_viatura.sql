-- Migration 194 - registro de etapa por qualquer viatura da mesma escolta
--
-- Decisao de Pecanha em 2026-09-29: em escolta com duas ou mais viaturas, qualquer
-- participante vinculado registra por qualquer viatura da mesma escolta, com o
-- registro no nome de quem gravou.
--
-- A Fase 0 (database/testes/03_fase0_modo_guiado.sql) mostrou que a policy
-- pontos_insert usa sou_do_efetivo_veiculo(escolta_veiculo_id): so a propria
-- viatura. Efeito colateral que ja existia: numa escolta com duas viaturas, a tela de
-- detalhe grava os pontos das duas num insert so, e para o operador a linha da outra
-- viatura era recusada, derrubando o lote inteiro.
--
-- ADITIVA. Nao altera nem apaga pontos_insert nem pontos_select: acrescenta duas
-- policies permissivas, e o Postgres aceita a linha quando QUALQUER policy aceita.
-- Nada que funciona hoje deixa de funcionar. Idempotente.
--
-- 1. pontos_insert_mesma_escolta: grava em qualquer viatura de uma escolta em que o
--    usuario esta no efetivo, e SO no proprio nome (lancado_por = ele). A
--    rastreabilidade de quem registrou fica garantida pelo banco, nao pela tela.
-- 2. pontos_select_mesma_escolta: le os pontos das outras viaturas da mesma escolta.
--    Sem isto o app nao veria que a outra viatura ja registrou a etapa, e a etapa
--    nunca avancaria (a conferencia "todas as viaturas registraram" conta pontos).
--
-- Aplicar no SQL Editor do Supabase. Nao ha UPDATE nem DELETE novos: ponto de
-- controle continua sem apagar, pela cadeia de custodia.

begin;

drop policy if exists pontos_insert_mesma_escolta on public.pontos_controle;
create policy pontos_insert_mesma_escolta on public.pontos_controle
  for insert to authenticated
  with check (
    lancado_por = (
      select u.id from public.usuarios u
      where u.auth_user_id = auth.uid()
      limit 1
    )
    and public.sou_do_efetivo((
      select ev.escolta_id from public.escolta_veiculos ev
      where ev.id = escolta_veiculo_id
    ))
  );

drop policy if exists pontos_select_mesma_escolta on public.pontos_controle;
create policy pontos_select_mesma_escolta on public.pontos_controle
  for select to authenticated
  using (
    public.sou_do_efetivo((
      select ev.escolta_id from public.escolta_veiculos ev
      where ev.id = escolta_veiculo_id
    ))
  );

commit;

-- Conferencia: devem aparecer as policies antigas e as duas novas.
select policyname as regra, cmd as acao
from pg_policies
where schemaname = 'public' and tablename = 'pontos_controle'
order by policyname;
