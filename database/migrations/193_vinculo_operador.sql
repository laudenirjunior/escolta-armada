-- Migration 193 - vinculo operador <-> vigilante
--
-- Problema: operador cadastrado nao consegue lancar foto, checklist, ponto nem
-- avancar status, e a tela de Campo aparece vazia. Causa unica: a linha de
-- vigilantes fica com usuario_id nulo, entao sou_do_efetivo() e
-- sou_do_efetivo_veiculo() devolvem falso e a RLS recusa toda escrita de campo.
-- Provado em dado real na base pre-zeramento: vigilante que era comandante de
-- escolta com usuario_id nulo, enquanto existia o usuario operador com login.
--
-- Este script faz tres coisas, TODAS aditivas, sem apagar nada e sem tocar em
-- nenhum lancamento (pontos, fotos, checklists, historico ficam intactos):
--   1. View de vigilancia, para operador orfao aparecer no lint em vez de sumir.
--   2. Trava para nao acontecer de novo (duas triggers de vinculo automatico).
--   3. Reparo dos operadores JA cadastrados (liga o vinculo por CPF normalizado).
--
-- Aplicar no SQL Editor do Supabase (roda como postgres e faz DDL). O PostgREST
-- nao serve: nao executa DDL. Seguro rodar o bloco inteiro de uma vez; e
-- idempotente (rodar de novo nao repete efeito).
--
-- Armadilha confirmada: usuarios.cpf e cru (11 digitos) e vigilantes.cpf e
-- mascarado (xxx.xxx.xxx-xx). O casamento normaliza os digitos dos dois lados.

-- =====================================================================
-- 0. Estado ANTES (leitura, nao muda nada)
-- =====================================================================
select 'ANTES: operadores sem vinculo' as etapa, count(*) as qtd
from usuarios u
join dom_perfis dp on dp.id = u.perfil_id
where dp.codigo = 'operador'
  and not exists (select 1 from vigilantes v where v.usuario_id = u.id);

-- =====================================================================
-- 1. View de vigilancia (security_invoker, conforme a regra de views do projeto)
-- =====================================================================
create or replace view public.vw_operador_sem_vinculo
  with (security_invoker = on) as
select u.id as usuario_id, u.nome_completo, u.cpf, u.email
from usuarios u
join dom_perfis dp on dp.id = u.perfil_id
where dp.codigo = 'operador'
  and not exists (select 1 from vigilantes v where v.usuario_id = u.id);

-- =====================================================================
-- 2. Trava A: ao inserir/alterar um vigilante sem vinculo, liga ao usuario
--    operador de mesmo CPF. Cobre o caminho em que o vigilante nasce depois
--    do usuario. So mexe quando usuario_id vem nulo; nunca sobrescreve.
-- =====================================================================
create or replace function public.vincular_vigilante_a_usuario()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid;
begin
  if NEW.usuario_id is not null then
    return NEW;
  end if;
  select u.id into v_uid
  from usuarios u
  join dom_perfis dp on dp.id = u.perfil_id
  where dp.codigo = 'operador'
    and regexp_replace(u.cpf, '\D', '', 'g') = regexp_replace(NEW.cpf, '\D', '', 'g')
    and not exists (select 1 from vigilantes v where v.usuario_id = u.id)
  limit 1;
  NEW.usuario_id := v_uid;  -- pode seguir nulo se nao houver par; a view expoe
  return NEW;
end$$;
revoke execute on function public.vincular_vigilante_a_usuario() from anon, public;

drop trigger if exists trg_vincular_vigilante_a_usuario on public.vigilantes;
create trigger trg_vincular_vigilante_a_usuario
  before insert or update of cpf, usuario_id on public.vigilantes
  for each row execute function public.vincular_vigilante_a_usuario();

-- =====================================================================
-- 3. Trava B: ao criar/virar operador, liga um vigilante existente sem vinculo
--    de mesmo CPF. Cobre o caminho em que o login nasce depois do vigilante.
--    So liga quando ha EXATAMENTE um vigilante livre; senao no-op, e a view
--    expoe o caso para tratamento manual. Nunca cria vigilante nem apaga nada.
-- =====================================================================
create or replace function public.garantir_vinculo_operador()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_perfil text;
begin
  select codigo into v_perfil from dom_perfis where id = NEW.perfil_id;
  if v_perfil is distinct from 'operador' then
    return NEW;
  end if;
  if exists (select 1 from vigilantes where usuario_id = NEW.id) then
    return NEW;
  end if;
  update vigilantes v
     set usuario_id = NEW.id, atualizado_em = now()
   where v.id = (
           select vv.id from vigilantes vv
           where vv.usuario_id is null
             and regexp_replace(vv.cpf, '\D', '', 'g') = regexp_replace(NEW.cpf, '\D', '', 'g')
           order by vv.criado_em
           limit 1)
     and (select count(*) from vigilantes w
          where w.usuario_id is null
            and regexp_replace(w.cpf, '\D', '', 'g') = regexp_replace(NEW.cpf, '\D', '', 'g')) = 1;
  return NEW;
end$$;
revoke execute on function public.garantir_vinculo_operador() from anon, public;

drop trigger if exists trg_garantir_vinculo_operador on public.usuarios;
create trigger trg_garantir_vinculo_operador
  after insert or update of perfil_id on public.usuarios
  for each row execute function public.garantir_vinculo_operador();

-- =====================================================================
-- 4. Reparo dos operadores JA cadastrados (aditivo). Liga por CPF quando ha
--    exatamente um vigilante livre. Idempotente. Nao apaga, nao recria, nao
--    mexe em lancamento.
-- =====================================================================
with alvo as (
  select u.id as usuario_id,
    (select v.id from vigilantes v
      where regexp_replace(v.cpf, '\D', '', 'g') = regexp_replace(u.cpf, '\D', '', 'g')
        and v.usuario_id is null
      limit 1) as vigilante_id,  -- limit 1: com dois livres a subconsulta abortava o script; o n = 1 abaixo descarta o caso
    (select count(*) from vigilantes v
      where regexp_replace(v.cpf, '\D', '', 'g') = regexp_replace(u.cpf, '\D', '', 'g')
        and v.usuario_id is null) as n
  from usuarios u
  join dom_perfis dp on dp.id = u.perfil_id
  where dp.codigo = 'operador'
    and not exists (select 1 from vigilantes vv where vv.usuario_id = u.id)
)
update vigilantes v
   set usuario_id = a.usuario_id, atualizado_em = now()
  from alvo a
 where v.id = a.vigilante_id and a.n = 1;

-- =====================================================================
-- 5. Estado DEPOIS (leitura). O esperado e a contagem voltar 0.
--    A segunda consulta lista quem ficou de fora (sem vigilante, ou CPF
--    ambiguo com dois vigilantes livres), para tratar caso a caso.
-- =====================================================================
select 'DEPOIS: operadores sem vinculo' as etapa, count(*) as qtd
from public.vw_operador_sem_vinculo;

select * from public.vw_operador_sem_vinculo;
