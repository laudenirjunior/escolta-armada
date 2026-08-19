# Migrations legadas (v1) - NAO EXECUTAR

Estes 7 arquivos SQL e o seed descrevem um schema **que nunca existiu neste banco**.

Sao de uma versao v1 abandonada: chaves primarias `SMALLINT`, `usuarios.auth_id`,
`escoltas.status_id`, `local_saida`. O banco real e v2: chaves UUID, `auth_user_id`,
`status` TEXT com CHECK, `origem_endereco`.

Executar qualquer um deles produz um banco que a aplicacao nao consegue usar.

## Perigo especifico

`007_create_rls_policies.sql:35` redefine `auth.uid()` como `SELECT auth.uid()`:

```sql
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID AS $$
  SELECT auth.uid()
$$ LANGUAGE sql STABLE;
```

Isso e **recursao infinita** e sobrescreve a funcao do proprio Supabase.
Executar esse arquivo quebra toda a autenticacao do projeto.

## O que usar no lugar

`database/migrations/`, numerado a partir de 100, aplicado via Supabase e
registrado em `supabase_migrations.schema_migrations`.

Mantidos aqui apenas como registro historico.
