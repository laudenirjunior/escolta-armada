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

-- 3. Excecoes deliberadas de politica `true`. A lista abaixo e a unica permitida;
--    qualquer nome novo aqui e regressao, nao decisao.
--    usuarios_select: leitura ampla entre autenticados, decidida porque a politica
--    restrita apagava o nome do autor da timeline e esvaziava o chat.
select 'politica true nao documentada' as verificacao,
       coalesce(string_agg(tablename||'.'||policyname, ', '), 'nenhuma (correto)') as resultado
from pg_policies
where schemaname = 'public'
  and tablename in ('usuarios','clientes','vigilantes','fotos','escoltas','pontos_controle')
  and (coalesce(qual,'') ~ '^\s*true\s*$' or coalesce(with_check,'') ~ '^\s*true\s*$')
  and policyname not in ('usuarios_select');

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

-- 6. View em public nao pode ser SECURITY DEFINER e alcancavel por authenticated.
--    O padrao do PostgreSQL faz a view aplicar a RLS de quem a criou, entregando
--    todas as linhas a qualquer usuario logado, por cima das politicas.
select 'view SECURITY DEFINER exposta' as verificacao,
       coalesce(string_agg(c.relname, ', '), 'nenhuma (correto)') as resultado
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'v'
  and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=on%'
  and (has_table_privilege('authenticated', c.oid, 'SELECT')
    or has_table_privilege('anon', c.oid, 'SELECT'));

-- 7. A trigger que barra escalada de privilegio em usuarios precisa conferir
--    DE QUEM e a linha, nao so o perfil de quem chama. A versao antiga liberava
--    qualquer gestor logo na primeira linha, e um PATCH no proprio id promovia
--    a administrador. Ver migration 172.
select 'trigger de escalada sem checagem de dono' as verificacao,
       case when pg_get_functiondef(p.oid) ilike '%auth_user_id = v_eu%'
                 and pg_get_functiondef(p.oid) ilike '%somente um administrador%'
            then 'nenhuma (correto)'
            else 'impedir_autopromocao regrediu' end as resultado
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'impedir_autopromocao';
