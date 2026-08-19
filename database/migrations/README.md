# Migrations

As migrations válidas começam no **número 100**. Foram aplicadas via MCP do Supabase e estão registradas em `supabase_migrations.schema_migrations` no banco.

Este diretório guarda a referência legível do que foi aplicado. A fonte de verdade é o registro no Supabase.

## Aplicadas em 2026-08-19

| # | Nome | O que faz |
|---|---|---|
| 100 | `hotfix_seguranca_security_definer` | Fecha a criação anônima de administrador. Guarda `IS NULL OR` e `REVOKE` de `anon` |
| 101 | `hotfix_escalada_gestor_administrador` | `redefinir_senha_usuario` passa a conferir o perfil do alvo |
| 102 | `search_path_funcoes` | `search_path` fixado em 9 funções |
| 103 | `revoke_trigger_function_anon` | Revoga a função de trigger de `anon` |
| 110 | `fluxo_status_transito_retorno` | `fluxo_versao`, novo CHECK, tipos de ponto `transito_retorno` e `retorno` |
| 111 | `transicoes_status` | Máquina de estados de 9 etapas. Corrige o erro relatado |
| 112 | `exigir_transito_retorno` | Exige o ponto de trânsito antes de concluir o retorno |
| 120 | `reparar_contas_sem_identity` | Conserta as contas que não conseguiam entrar |
| 121 | `criar_usuario_por_login` | Cadastro de 4 campos, criando `auth.identities` |
| 130 | `helper_efetivo` | `sou_do_efetivo` e `sou_do_efetivo_veiculo` |
| 131 | `rls_lote1_usuarios` | RLS em `usuarios` e trava contra autopromoção |
| 132 | `rls_lote1_clientes_vigilantes_fotos` | RLS no lote sensível |
| 133 | `rls_lote2_escoltas` | RLS nas tabelas de operação |
| 134 | `rls_lote2_campo` | RLS nos dados de campo |
| 135 | `rls_lote3_dominio_sistema` | RLS em domínio e sistema |
| 136 | `revoke_funcoes_trigger` | Higiene de permissões |
| 140 | `cadastrar_operador_com_identity` | Corrige o mesmo defeito no cadastro de vigilante |

## Pendente de aplicação

`111_trigger_validacao_transicao.sql` neste diretório é uma versão consolidada da 111 e da 112 num arquivo só, mantida como referência. **Não precisa ser aplicada**: o conteúdo já está no banco pelas migrations 111 e 112.

## Regra para migrations novas

Toda função `SECURITY DEFINER` criada daqui em diante precisa de:

```sql
REVOKE EXECUTE ON FUNCTION ... FROM anon, PUBLIC;
-- e, se for RPC chamada pelo cliente:
IF v_perfil IS NULL OR v_perfil NOT IN ('administrador','gestor') THEN
  RAISE EXCEPTION 'Permissao negada.';
END IF;
-- e sempre:
SET search_path TO 'public', 'pg_temp'
```

O `IS NULL OR` não é decorativo: em SQL, `NULL NOT IN (...)` resulta NULL, e `IF NULL THEN` **não dispara**. Foi exatamente assim que qualquer anônimo podia criar uma conta de administrador.
