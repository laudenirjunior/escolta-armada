# Testes de banco

Os testes que importam neste sistema são de banco, porque é lá que as regras
vivem: a máquina de estados, a exigência de foto e a RLS.

## Como rodar

Cole no SQL Editor do Supabase ou execute via MCP. Cada arquivo é idempotente
e limpa o que cria.

| Arquivo | Cobre |
|---|---|
| `01_fluxo_status.sql` | As 9 etapas, as transições inválidas e a exigência do ponto de trânsito de retorno |
| `02_rls_por_perfil.sql` | O que cada perfil enxerga e o que é recusado |

## Resultado esperado

Todos os passos devem sair como `PASSOU` ou `BLOQUEADO CORRETAMENTE`.
Qualquer `PASSOU (ERRADO)` é regressão.
