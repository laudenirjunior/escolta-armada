-- Confere o estado da RLS. Nao substitui o teste com JWT real de cada perfil,
-- que e o unico que prova o escopo de leitura, mas pega regressao estrutural.

-- 1. Toda tabela precisa estar com RLS ligada.
select 'tabelas sem RLS' as verificacao,
       coalesce(string_agg(c.relname, ', '), 'nenhuma (correto)') as resultado
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' and not c.relrowsecurity;

-- 2. Nenhuma funcao SECURITY DEFINER pode ser executavel por anon.
select 'SECURITY DEFINER executavel por anon' as verificacao,
       coalesce(string_agg(p.proname, ', '), 'nenhuma (correto)') as resultado
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prosecdef
  and has_function_privilege('anon', p.oid, 'EXECUTE');

-- 3. Politica permissiva com `true` em tabela sensivel anula a restrita ao lado.
select 'politicas true em tabela sensivel' as verificacao,
       coalesce(string_agg(tablename||'.'||policyname, ', '), 'nenhuma (correto)') as resultado
from pg_policies
where schemaname='public'
  and tablename in ('usuarios','clientes','vigilantes','fotos','escoltas','pontos_controle')
  and (coalesce(qual,'') ~ '^\s*true\s*$' or coalesce(with_check,'') ~ '^\s*true\s*$');

-- 4. As guardas de perfil precisam do IS NULL OR.
select 'RPC sem guarda IS NULL OR' as verificacao,
       coalesce(string_agg(p.proname, ', '), 'nenhuma (correto)') as resultado
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prosecdef
  and p.proname in ('criar_usuario_por_login','cadastrar_operador','redefinir_senha_usuario','excluir_auth_usuario')
  and pg_get_functiondef(p.oid) not ilike '%is null or%';

-- 5. Toda conta precisa de identity, senao nao consegue entrar.
select 'contas sem auth.identities' as verificacao,
       coalesce(string_agg(u.email, ', '), 'nenhuma (correto)') as resultado
from auth.users u
where not exists (select 1 from auth.identities i where i.user_id=u.id);
