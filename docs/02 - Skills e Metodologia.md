# Skills e Metodologia

## Sobre o `/gauntlet-loop`

O skill **não está instalado** nesta máquina. Procurei em `~/.claude/skills`, `~/.claude/commands` e `~/.claude/plugins`.

No lugar dele apliquei o ciclo equivalente, que é o que de fato produziu o resultado: **exploração paralela, redação, crítica adversarial por agente independente com nota, e refazer até convergir.**

## As rodadas de crítica

O agente crítico recebia acesso ao código e ao banco, com instrução explícita de ser adversarial e de não inflar nota.

| Rodada | Nota | O que derrubou a nota |
|---|---|---|
| v1 | **6** | Não via o furo de criação anônima de administrador; travaria as 3 escoltas em `retornando`; propunha uma trigger de contagem de fotos impossível |
| v2 | **7** | Três bloqueadores: `next build` nunca passou, a service role key não existia, e uma tabela era referenciada duas fases antes de existir |
| v3 | **8** | As políticas de RLS existentes não eram apenas inertes, eram permissivas demais, o que invalidava o aceite da fase de segurança |
| v4 | **8** | Consequências não rastreadas do `REVOKE`; contradições internas de um documento remendado |
| v5 | **9** | O `REVOKE UPDATE` por coluna que eu propunha era um no-op; `handleFinalizacao` faltava na lista de escritores |
| v6 | **9** | O aceite de `usuarios` trancaria todo operador fora do dashboard |
| v7 | **10** | Nada material restante |

Duas alegações do revisor foram **recusadas** por não se confirmarem na verificação: a contagem de políticas com predicado `true` (ele disse 39, são 33) e a de chamadas `.from()` (disse 212, são 203).

## O que o ciclo pegou que eu não tinha visto

Vale registrar, porque foi o maior ganho do método. Erros meus, encontrados pela crítica:

- Uma trigger `BEFORE INSERT` contando linhas de uma chave estrangeira que ainda não existe. Impossível por construção.
- Um plano que travaria as 3 escoltas em andamento.
- `REVOKE UPDATE (coluna)` quando o privilégio foi concedido no nível da tabela: o PostgreSQL ignora, passa com aviso e não muda nada.
- Dois critérios de aceitação que só poderiam ser cumpridos quebrando produção.
- Um bug de `$` em substituição de texto que corrompeu o próprio documento do plano.

## Skills usadas

| Momento | Skill |
|---|---|
| Banco e RLS | `.claude/skills/supabase`, `supabase-postgres-best-practices` |
| Exploração inicial | Agentes `Explore` em paralelo |
| Crítica de cada versão | Agente independente com acesso ao código e ao banco |

## Verificação adotada

Nada foi dado como pronto sem prova. O padrão foi sempre o mesmo: **medir antes, alterar, medir depois**.

Exemplos do que isso pegou:

- O furo de segurança foi comprovado com o ataque real (`HTTP 401` depois da correção).
- O defeito de login foi isolado por probe: `HTTP 500` nas contas quebradas contra `400` na sadia.
- A RLS foi medida com JWT real de cada perfil, contando linhas visíveis antes e depois.
- O relatório PDF foi testado no PostgREST, onde o erro realmente acontecia.
