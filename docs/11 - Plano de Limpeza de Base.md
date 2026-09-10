# Plano de Limpeza de Base e Renumeração das Escoltas

Objetivo declarado por Pecanha: manter apenas o que o usuário **Bruno Mendonça** cadastrou, remover o que foi inserido por Pecanha (armamento, pessoas, testes e escoltas), zerar a numeração das escoltas e deixá-la em sequência limpa.

Este documento é o planejamento e os scripts. **Nada aqui foi executado.** A fase destrutiva depende de confirmação explícita.

Data do plano: 10/09/2026. Base: código do repositório e `docs/03 - Arquitetura Atual.md`, `docs/07 - Runbook.md`.

> **O diagnóstico foi executado em 10/09/2026 às 21h58 UTC. Os números reais estão na seção 11, no fim deste documento. Leia aquilo antes de executar qualquer coisa daqui: três achados mudam o plano.**

---

## 1. O bloqueio que define quem executa

Nesta sessão eu **não tenho acesso ao banco**:

| Fato | Consequência |
|---|---|
| O conector do Supabase está desconectado nesta sessão | Não consigo consultar nem executar nada no banco |
| `.env.local` tem apenas `NEXT_PUBLIC_SUPABASE_ANON_KEY` | A chave anônima é limitada pela RLS. Não serve para inventariar autoria nem para apagar |
| Não existe `SUPABASE_SERVICE_ROLE_KEY` no projeto | O Runbook confirma que ela ainda não é usada |

Portanto, o caminho mais rápido e o mais seguro é o mesmo: **eu escrevo, você executa no SQL Editor do Supabase**, que roda como `postgres` e ignora RLS. Você cola o resultado aqui e eu monto o passo seguinte com dado real, sem deduzir nada.

Se preferir que eu execute, é preciso reconectar o conector do Supabase com acesso ao projeto `qthoyxujyzskydulvcfy`.

---

## 2. O que já está confirmado, e a fonte de cada coisa

### 2.1 Onde mora a autoria

Não existe uma tabela de "cadastros do usuário X". A autoria está espalhada em colunas por tabela, e é por elas que se separa o que é do Bruno do que é seu:

| Tabela | Coluna de autoria | Observação |
|---|---|---|
| `escoltas` | `criada_por` | **NOT NULL.** Toda escolta tem autor obrigatório |
| `clientes`, `veiculos`, `vigilantes`, `armamentos` | `criado_por` | Anulável. Registro antigo pode estar sem autor |
| `checklist_modelos` | `criado_por` | Anulável |
| `escolta_veiculos`, `escolta_efetivo`, `escolta_armamentos` | `criado_por` | Anulável |
| `fotos`, `presencas` | `criado_por` | Anulável |
| `ocorrencias` | `registrado_por` | Nome diferente das demais |
| `pontos_controle` | `lancado_por` | Nome diferente das demais |
| `checklists` | `responsavel_id` | Nome diferente das demais |
| `usuarios` | `criado_por` | Quem provisionou a conta |

Três colunas fogem do padrão `criado_por`. Um script que assuma o nome uniforme silenciosamente deixa registro para trás.

### 2.2 O grafo de dependências, das folhas para a raiz

Extraído das relações declaradas em `types/supabase.ts`:

```
escoltas
 ├─ escolta_veiculos ─────────┐
 │   ├─ checklists ─ checklist_respostas ─→ fotos
 │   ├─ pontos_controle ────────────────→ fotos
 │   ├─ rastreamento
 │   ├─ escolta_armamentos ─→ armamentos
 │   ├─ ocorrencias ────────────────────→ fotos
 │   └─ emergencias
 ├─ escolta_efetivo ─→ vigilantes
 ├─ presencas ──────────────────────────→ fotos
 ├─ atualizacoes_status ────────────────→ fotos
 ├─ escolta_status_historico
 ├─ notificacoes
 ├─ ocorrencias, emergencias (também ligam direto na escolta)
 └─ cliente_id ─→ clientes
```

`fotos` é sempre a última: cinco tabelas a referenciam.

Duas armadilhas que o documento de arquitetura já registra e que o script respeita:

- `checklists` **não tem** `escolta_id`. Liga em `escolta_veiculos`.
- `pontos_controle` também liga em `escolta_veiculos`, não na escolta.

### 2.3 Como o número da escolta é gerado

Segundo `docs/07 - Runbook.md`, o `codigo_escolta` (formato `ESC-AAAA-NNNN`) vem da trigger `tr_gerar_codigo_escolta`, BEFORE INSERT, que aplica `MAX()` sobre as escoltas do ano corrente. **Não existe sequence.**

Isso tem três consequências práticas:

1. **Zerar é apagar.** Com o ano sem escoltas, a próxima nasce `ESC-2026-0001` sozinha, sem comando nenhum.
2. **Renumerar por UPDATE é seguro** quanto à trigger, porque ela só dispara em INSERT.
3. **Só é seguro se a função usar mesmo `MAX()`.** Se usar `count(*)`, renumerar cria colisão na próxima inserção. O diagnóstico D6 imprime o corpo da função antes de qualquer coisa. Não vou renumerar sem ver esse texto.

---

## 3. As quatro regras de corte

O pedido "retirar todos os outros cadastros" é amplo, e aplicado ao pé da letra ele quebra justamente o que se quer preservar: **as escoltas do Bruno apontam para clientes, veículos e vigilantes que provavelmente foram cadastrados por você.** Apagar o cadastro apaga a base da escolta dele.

Por isso o corte tem quatro regras, não uma.

| Regra | Alvo | Critério |
|---|---|---|
| **A** | Dado operacional: `escoltas` e todas as filhas | Apaga tudo que **não** foi criado pelo Bruno. É dado transacional, não quebra nada ao sair |
| **B** | Cadastro: `clientes`, `veiculos`, `vigilantes`, `armamentos`, `checklist_modelos` | Apaga o que é seu **e** não é referenciado por nada que fica. O próprio script se protege: o `NOT EXISTS` impede apagar o que sustenta registro do Bruno |
| **C** | `usuarios` | **Inativa, não apaga.** Ver 3.1 |
| **D** | `dom_*` (9 tabelas de domínio) | **Não toca.** São listas fixas que alimentam menu, tipos de ponto, calibres e perfis. Apagar quebra a aplicação inteira |

### 3.1 Por que usuário se inativa em vez de apagar

`usuarios` é a tabela mais entrelaçada do banco. É referenciada por `escoltas.criada_por` (NOT NULL), `pontos_controle.lancado_por`, `ocorrencias.registrado_por`, `checklists.responsavel_id`, `logs_auditoria.usuario_id`, `chat_mensagens` em duas colunas, além de `criado_por` em quase tudo.

Apagar um usuário seu que assinou um ponto de controle de uma escolta do Bruno é impossível sem destruir o registro dele, que é exatamente o que se quer preservar. E há o lado do Supabase Auth: a conta vive também em `auth.users`, e existe uma RPC própria para isso, `excluir_auth_usuario`. Apagar a linha em `usuarios` na mão deixa a conta órfã do outro lado.

**Recomendação:** `update usuarios set status = 'inativo'`. O usuário some das listas e não entra mais, e o histórico continua íntegro. Exclusão de verdade só para conta comprovadamente órfã, pela RPC, e depois de tudo o mais estar feito.

---

## 4. Fase 1 - Diagnóstico, somente leitura

Nenhum destes comandos altera nada. Rode no SQL Editor, um bloco por vez, e me devolva o resultado.

### D1 - Quem é quem

```sql
select u.id,
       u.nome_completo,
       u.email,
       p.codigo   as perfil,
       u.status,
       u.criado_em::date as criado_em
from usuarios u
join dom_perfis p on p.id = u.perfil_id
order by u.criado_em;
```

Preciso do `id` do Bruno e do seu. Não vou inferir por nome parecido: o resto do plano depende desses dois UUID.

### D2 - Inventário de autoria, tabela por tabela

```sql
with a as (select id, nome_completo from usuarios)
select 'escoltas'          as tabela, coalesce(a.nome_completo,'(sem autor)') as autor, count(*) as registros
  from escoltas e          left join a on a.id = e.criada_por        group by 2
union all select 'clientes',          coalesce(a.nome_completo,'(sem autor)'), count(*)
  from clientes c          left join a on a.id = c.criado_por        group by 2
union all select 'veiculos',          coalesce(a.nome_completo,'(sem autor)'), count(*)
  from veiculos v          left join a on a.id = v.criado_por        group by 2
union all select 'vigilantes',        coalesce(a.nome_completo,'(sem autor)'), count(*)
  from vigilantes g        left join a on a.id = g.criado_por        group by 2
union all select 'armamentos',        coalesce(a.nome_completo,'(sem autor)'), count(*)
  from armamentos m        left join a on a.id = m.criado_por        group by 2
union all select 'checklist_modelos', coalesce(a.nome_completo,'(sem autor)'), count(*)
  from checklist_modelos k left join a on a.id = k.criado_por        group by 2
union all select 'usuarios',          coalesce(a.nome_completo,'(sem autor)'), count(*)
  from usuarios u          left join a on a.id = u.criado_por        group by 2
union all select 'fotos',             coalesce(a.nome_completo,'(sem autor)'), count(*)
  from fotos f             left join a on a.id = f.criado_por        group by 2
union all select 'ocorrencias',       coalesce(a.nome_completo,'(sem autor)'), count(*)
  from ocorrencias o       left join a on a.id = o.registrado_por    group by 2
union all select 'pontos_controle',   coalesce(a.nome_completo,'(sem autor)'), count(*)
  from pontos_controle t   left join a on a.id = t.lancado_por       group by 2
order by 1, 2;
```

Esta é a foto que decide tudo. Ela responde de uma vez: o Bruno chegou a cadastrar alguma coisa, e o quê.

### D3 - As escoltas, uma a uma

```sql
select e.codigo_escolta,
       e.status,
       e.criado_em::date        as criada_em,
       e.data_hora_prevista::date as prevista_para,
       cl.nome_cliente,
       u.nome_completo          as criada_por
from escoltas e
join clientes cl on cl.id = e.cliente_id
left join usuarios u on u.id = e.criada_por
order by e.criado_em;
```

Mostra quantas ficam, quais buracos a numeração vai ter e se alguma escolta do Bruno é operação real já reportada ao cliente.

### D4 - O que é seu mas sustenta o que fica

Substitua `UUID_BRUNO` antes de rodar.

```sql
with bruno as (select 'UUID_BRUNO'::uuid as id),
     fica  as (select id from escoltas where criada_por = (select id from bruno))
select 'cliente'   as tipo, cl.nome_cliente as item, count(*) as usos_pelo_bruno
  from escoltas e join clientes cl on cl.id = e.cliente_id
  where e.id in (select id from fica) and cl.criado_por is distinct from (select id from bruno)
  group by 2
union all
select 'veiculo', v.placa, count(*)
  from escolta_veiculos ev join veiculos v on v.id = ev.veiculo_id
  where ev.escolta_id in (select id from fica) and v.criado_por is distinct from (select id from bruno)
  group by 2
union all
select 'vigilante', g.nome_completo, count(*)
  from escolta_efetivo ee join vigilantes g on g.id = ee.vigilante_id
  where ee.escolta_id in (select id from fica) and g.criado_por is distinct from (select id from bruno)
  group by 2
union all
select 'armamento', coalesce(m.numeracao,'(sem numeração)'), count(*)
  from escolta_armamentos ea
  join armamentos m on m.id = ea.armamento_id
  join escolta_veiculos ev on ev.id = ea.escolta_veiculo_id
  where ev.escolta_id in (select id from fica) and m.criado_por is distinct from (select id from bruno)
  group by 2
order by 1, 2;
```

**Tudo que aparecer aqui fica**, mesmo tendo sido cadastrado por você. É a lista de intocáveis.

### D5 - O que o banco faz sozinho quando se apaga

```sql
select c.conrelid::regclass  as tabela,
       c.confrelid::regclass as referencia,
       c.conname,
       case c.confdeltype
         when 'a' then 'NO ACTION' when 'r' then 'RESTRICT' when 'c' then 'CASCADE'
         when 'n' then 'SET NULL'  when 'd' then 'SET DEFAULT' end as ao_apagar
from pg_constraint c
join pg_class t     on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where c.contype = 'f' and n.nspname = 'public'
order by 1, 2;
```

Se as chaves forem `CASCADE`, o script da fase 3 encurta muito. Se forem `NO ACTION`, a ordem folha a folha é obrigatória. Escrevi o script assumindo o pior caso, que funciona nos dois.

### D6 - A função do código e a unicidade

```sql
select pg_get_functiondef(p.oid) as corpo
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'gerar_codigo_escolta';
```

```sql
select i.relname as indice, x.indisunique as unico, pg_get_indexdef(x.indexrelid) as definicao
from pg_index x join pg_class i on i.oid = x.indexrelid
where x.indrelid = 'public.escoltas'::regclass;
```

O primeiro confirma se é `MAX()` mesmo. O segundo diz se `codigo_escolta` tem índice único, o que obriga a renumeração em dois passos.

---

## 5. Fase 2 - Backup, antes de qualquer exclusão

O Runbook exige, e o precedente de 19/08/2026 mostrou por quê.

```sql
create schema if not exists backup_20260910;

create table backup_20260910.escoltas                 as select * from public.escoltas;
create table backup_20260910.escolta_veiculos         as select * from public.escolta_veiculos;
create table backup_20260910.escolta_efetivo          as select * from public.escolta_efetivo;
create table backup_20260910.escolta_armamentos       as select * from public.escolta_armamentos;
create table backup_20260910.pontos_controle          as select * from public.pontos_controle;
create table backup_20260910.rastreamento             as select * from public.rastreamento;
create table backup_20260910.presencas                as select * from public.presencas;
create table backup_20260910.fotos                    as select * from public.fotos;
create table backup_20260910.ocorrencias              as select * from public.ocorrencias;
create table backup_20260910.emergencias              as select * from public.emergencias;
create table backup_20260910.checklists               as select * from public.checklists;
create table backup_20260910.checklist_respostas      as select * from public.checklist_respostas;
create table backup_20260910.checklist_modelos        as select * from public.checklist_modelos;
create table backup_20260910.checklist_modelo_itens   as select * from public.checklist_modelo_itens;
create table backup_20260910.atualizacoes_status      as select * from public.atualizacoes_status;
create table backup_20260910.escolta_status_historico as select * from public.escolta_status_historico;
create table backup_20260910.notificacoes             as select * from public.notificacoes;
create table backup_20260910.clientes                 as select * from public.clientes;
create table backup_20260910.veiculos                 as select * from public.veiculos;
create table backup_20260910.vigilantes               as select * from public.vigilantes;
create table backup_20260910.armamentos               as select * from public.armamentos;
create table backup_20260910.usuarios                 as select * from public.usuarios;
create table backup_20260910.logs_auditoria           as select * from public.logs_auditoria;
create table backup_20260910.chat_mensagens           as select * from public.chat_mensagens;
```

Conferência obrigatória, adaptada do Runbook. As tabelas `dom_*`, que não são copiadas de propósito, aparecem como divergentes e isso é esperado:

```sql
with c as (
  select table_schema, table_name,
         (xpath('/row/c/text()', query_to_xml(
            format('select count(*) c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::int as linhas
  from information_schema.tables
  where table_schema in ('public','backup_20260910') and table_type = 'BASE TABLE'
)
select coalesce(p.table_name, b.table_name) as tabela,
       p.linhas as origem, b.linhas as backup,
       case when p.linhas is distinct from b.linhas then 'CONFERIR' else 'ok' end as situacao
from (select * from c where table_schema = 'public') p
full join (select * from c where table_schema = 'backup_20260910') b using (table_name)
order by 1;
```

### Aviso que não pode ficar implícito

**Os arquivos do bucket `fotos` no Storage não têm cópia.** O backup guarda apenas os metadados, ou seja, caminho, GPS, data e hora. Foto apagada do Storage não volta. Foi exatamente o que aconteceu com os 117 arquivos em 19/08/2026: a restauração trouxe os dados e deixou a galeria inteira com imagem quebrada.

---

## 6. Fase 3 - Exclusão

### 6.1 Como rodar com segurança no SQL Editor

O editor do Supabase executa o bloco inteiro numa requisição só, então não dá para conferir e depois dar `commit` numa segunda execução. O procedimento é:

1. **Primeira execução com `rollback;` no fim.** Ele apaga, mostra a contagem final e desfaz tudo. É o ensaio.
2. Conferido o número, **troque a última linha para `commit;`** e rode de novo.

Substitua `UUID_BRUNO` nos dois lugares.

### 6.2 Regra A - operacional

```sql
begin;

create temp table esc_fora on commit drop as
  select id from escoltas where criada_por is distinct from 'UUID_BRUNO'::uuid;

create temp table ev_fora on commit drop as
  select id from escolta_veiculos where escolta_id in (select id from esc_fora);

-- Guarda o caminho dos arquivos ANTES de apagar as linhas.
-- Sem isto, o objeto no Storage vira órfão impossível de localizar.
create table if not exists backup_20260910.fotos_apagadas as select * from fotos where false;

insert into backup_20260910.fotos_apagadas
select distinct f.*
from fotos f
where f.id in (
      select foto_id from pontos_controle    where escolta_veiculo_id in (select id from ev_fora)  and foto_id is not null
  union select foto_id from checklist_respostas where checklist_id in (
             select id from checklists where escolta_veiculo_id in (select id from ev_fora))       and foto_id is not null
  union select foto_id from ocorrencias        where escolta_id in (select id from esc_fora)       and foto_id is not null
  union select foto_id from presencas          where escolta_id in (select id from esc_fora)       and foto_id is not null
  union select foto_id from atualizacoes_status where escolta_id in (select id from esc_fora)      and foto_id is not null
);

-- Folhas para a raiz
delete from checklist_respostas      where checklist_id in (select id from checklists where escolta_veiculo_id in (select id from ev_fora));
delete from checklists               where escolta_veiculo_id in (select id from ev_fora);
delete from pontos_controle          where escolta_veiculo_id in (select id from ev_fora);
delete from rastreamento             where escolta_veiculo_id in (select id from ev_fora);
delete from escolta_armamentos       where escolta_veiculo_id in (select id from ev_fora);
delete from ocorrencias              where escolta_id in (select id from esc_fora);
delete from emergencias              where escolta_id in (select id from esc_fora);
delete from presencas                where escolta_id in (select id from esc_fora);
delete from atualizacoes_status      where escolta_id in (select id from esc_fora);
delete from escolta_status_historico where escolta_id in (select id from esc_fora);
delete from notificacoes             where escolta_id in (select id from esc_fora);
delete from escolta_efetivo          where escolta_id in (select id from esc_fora);
delete from escolta_veiculos         where escolta_id in (select id from esc_fora);
delete from escoltas                 where id         in (select id from esc_fora);

-- Fotos por último, e só as que ninguém mais referencia
delete from fotos f
where f.id in (select id from backup_20260910.fotos_apagadas)
  and not exists (select 1 from pontos_controle     x where x.foto_id = f.id)
  and not exists (select 1 from checklist_respostas x where x.foto_id = f.id)
  and not exists (select 1 from ocorrencias         x where x.foto_id = f.id)
  and not exists (select 1 from presencas           x where x.foto_id = f.id)
  and not exists (select 1 from atualizacoes_status x where x.foto_id = f.id);

select 'escoltas' t, count(*) n from escoltas
union all select 'escolta_veiculos', count(*) from escolta_veiculos
union all select 'pontos_controle',  count(*) from pontos_controle
union all select 'checklists',       count(*) from checklists
union all select 'ocorrencias',      count(*) from ocorrencias
union all select 'fotos',            count(*) from fotos
order by 1;

rollback;   -- troque para commit; quando o número acima estiver certo
```

### 6.3 Regra B - cadastro, só o que ninguém usa

Rode **depois** do commit da regra A, senão o `NOT EXISTS` ainda enxerga as escoltas que vão sair.

```sql
begin;

delete from armamentos a
where a.criado_por is distinct from 'UUID_BRUNO'::uuid
  and not exists (select 1 from escolta_armamentos x where x.armamento_id = a.id);

delete from veiculos v
where v.criado_por is distinct from 'UUID_BRUNO'::uuid
  and not exists (select 1 from escolta_veiculos x where x.veiculo_id = v.id);

delete from vigilantes g
where g.criado_por is distinct from 'UUID_BRUNO'::uuid
  and not exists (select 1 from escolta_efetivo  x where x.vigilante_id = g.id)
  and not exists (select 1 from presencas        x where x.vigilante_id = g.id)
  and not exists (select 1 from escolta_veiculos x where x.responsavel_lancamento_id = g.id);

delete from clientes cl
where cl.criado_por is distinct from 'UUID_BRUNO'::uuid
  and not exists (select 1 from escoltas x where x.cliente_id = cl.id);

select 'armamentos' t, count(*) n from armamentos
union all select 'veiculos',   count(*) from veiculos
union all select 'vigilantes', count(*) from vigilantes
union all select 'clientes',   count(*) from clientes
order by 1;

rollback;   -- troque para commit; depois de conferir
```

`checklist_modelos` ficou de fora de propósito: sem modelo de checklist não existe pré-início, e é provável que só existam os que você criou. Se quiser removê-los, é decisão à parte.

### 6.4 Regra C - usuários

```sql
update usuarios
set status = 'inativo'
where id in ( /* cole aqui os UUID das contas de teste, vindos do D1 */ );
```

Conta que você queira apagar de verdade sai pela RPC `excluir_auth_usuario`, uma a uma, e só depois de comprovado que ela não assina nada. A consulta que prova isso:

```sql
select 'escoltas.criada_por'      onde, count(*) from escoltas             where criada_por     = 'UUID_ALVO'
union all select 'pontos.lancado_por',   count(*) from pontos_controle     where lancado_por    = 'UUID_ALVO'
union all select 'ocorrencias',          count(*) from ocorrencias         where registrado_por = 'UUID_ALVO'
union all select 'checklists',           count(*) from checklists          where responsavel_id = 'UUID_ALVO'
union all select 'logs_auditoria',       count(*) from logs_auditoria      where usuario_id     = 'UUID_ALVO'
union all select 'chat (de)',            count(*) from chat_mensagens      where de_usuario_id  = 'UUID_ALVO'
union all select 'chat (para)',          count(*) from chat_mensagens      where para_usuario_id= 'UUID_ALVO';
```

Só apaga quem der zero em todas as linhas.

### 6.5 Storage

As linhas de `fotos` saíram, mas os arquivos continuam no bucket. Dois caminhos:

- **Se nenhuma escolta sobrou:** Dashboard, Storage, bucket `fotos`, selecionar tudo e apagar. Simples e completo.
- **Se sobraram escoltas do Bruno:** apagar por lista, gerada da tabela de backup, nunca transcrita à mão:

```sql
select caminho_arquivo from backup_20260910.fotos_apagadas order by 1;
```

A remoção usa `storage.from('fotos').remove([...])` com a chave `service_role`, em lotes. A chave não pode ser commitada no repositório.

---

## 7. Fase 4 - Renumeração

Só é necessária se sobrarem escoltas do Bruno com buracos na numeração. **Se não sobrar nenhuma, não faça nada:** a próxima escolta do ano nasce `ESC-2026-0001` pela própria trigger.

Dois passos, porque se `codigo_escolta` tiver índice único (o D6 responde), renumerar direto colide: mover a `0005` para `0002` esbarra na `0002` que ainda existe.

```sql
begin;

-- Passo 1: tira todos os códigos do caminho
update escoltas
set codigo_escolta = 'TMP-' || id::text
where codigo_escolta is not null;

-- Passo 2: renumera por ano, na ordem de criação
with ordenadas as (
  select id,
         to_char(criado_em, 'YYYY') as ano,
         row_number() over (partition by date_part('year', criado_em)
                            order by criado_em, id) as seq
  from escoltas
)
update escoltas e
set codigo_escolta = 'ESC-' || o.ano || '-' || lpad(o.seq::text, 4, '0')
from ordenadas o
where o.id = e.id;

select codigo_escolta, criado_em::date, status from escoltas order by criado_em;

rollback;   -- troque para commit; depois de conferir
```

Duas escolhas embutidas, que você pode querer diferentes:

1. **A ordem é `criado_em`**, a data em que a escolta foi lançada no sistema. É o que a trigger usa. A alternativa seria `data_hora_prevista`, a data da operação. As duas divergem se alguma escolta foi cadastrada com antecedência.
2. **A numeração é por ano.** É como a trigger funciona. Uma escolta de 2025, se existir, recomeça em `ESC-2025-0001`.

**Risco a considerar antes de rodar:** renumerar reescreve código que já pode ter saído da empresa, em PDF enviado ao cliente ou em mensagem no Telegram. Se alguma escolta do Bruno for operação real já reportada, o código dela deveria ficar como está.

### Melhoria opcional, fora do pedido

O gerador por `MAX()` tem duas fragilidades conhecidas: duas inserções simultâneas podem pegar o mesmo número, e o número de uma escolta apagada é reaproveitado. Trocar por uma sequence de verdade resolve os dois. Não está incluído aqui porque muda o comportamento do sistema e não foi pedido. Fica registrado como opção.

---

## 8. Fase 5 - Verificação

```sql
-- 1. Nada sobrou de quem não é do Bruno
select count(*) as escoltas_de_terceiros from escoltas where criada_por is distinct from 'UUID_BRUNO'::uuid;

-- 2. Nenhum órfão nas filhas
select 'escolta_veiculos'   t, count(*) n from escolta_veiculos ev where not exists (select 1 from escoltas e where e.id = ev.escolta_id)
union all select 'pontos_controle', count(*) from pontos_controle p where not exists (select 1 from escolta_veiculos v where v.id = p.escolta_veiculo_id)
union all select 'checklists',      count(*) from checklists c     where not exists (select 1 from escolta_veiculos v where v.id = c.escolta_veiculo_id);

-- 3. A view de reconciliação continua vazia
select count(*) from vw_historico_divergente;

-- 4. Numeração sem buraco e sem repetição
select codigo_escolta, count(*) from escoltas group by 1 having count(*) > 1;
```

**Prova final, a do Runbook:** criar uma escolta pela aplicação, conferir que o código nasceu no número esperado, e apagá-la em seguida. Sem esse teste, a renumeração não está confirmada.

---

## 9. Riscos assumidos, por escrito

| Risco | Situação |
|---|---|
| Produção, plano Free, sem branch de teste | Tudo vai direto. Por isso backup e ensaio com `rollback` antes de cada `commit` |
| Storage sem cópia | Foto apagada não volta. Só os metadados ficam no backup |
| `usuarios` entrelaçado | Apagar usuário pode esbarrar em registro do Bruno. Daí a regra de inativar |
| Renumeração reescreve código já divulgado | Se houver PDF enviado ao cliente, o código dele muda e deixa de bater |
| Autoria ausente | Registro com `criado_por` nulo não é de ninguém. O script trata `NULL` como "não é do Bruno" e apaga. Se houver muitos, o D2 vai mostrar, e a regra pode ser revista |
| Eu não vi o dado | Todo número deste plano vem do schema, não da base. Nada de "provavelmente" foi tratado como fato |

---

## 10. O que depende de você

| # | Decisão | Recomendação |
|---|---|---|
| 1 | Quem executa | Você roda o D1 e o D2 no SQL Editor e me devolve o resultado. Ou reconecta o conector do Supabase para eu executar |
| 2 | "Pessoas" abrange `vigilantes` e `usuarios`, ou só `vigilantes`? | Vigilantes saem pela regra B, usuários são inativados pela regra C |
| 3 | Se o Bruno tiver escoltas, renumerar mesmo assim? | Só se nenhuma já tiver sido reportada ao cliente com o código atual |
| 4 | `checklist_modelos` sai também? | Não. Sem modelo não existe pré-início |

---

## 11. Diagnóstico executado

Executado em 10/09/2026, 21h58 UTC, por leitura via PostgREST com a chave `sb_secret`. **Somente leitura. Nada foi alterado.**

### 11.1 Quem é quem

| Usuário | Perfil | Situação | Criado em | Criado por |
|---|---|---|---|---|
| Laudenir Junior | administrador | ativo | 27/06/2026 | (semente do sistema) |
| DOUGLAS BRAIDO | administrador | ativo | 29/06/2026 | Laudenir Junior |
| Laudenir Teste | supervisor | ativo | 02/09/2026 | Laudenir Junior |
| **Bruno Moreira** | **gestor** | ativo | 03/09/2026 | Laudenir Junior |

O usuário chama-se **Bruno Moreira**, login `bruno_moreira@operador.local`. Existe também um vigilante **BRUNO MOREIRA DE MENDONÇA**, cadastrado em 09/07/2026. É o mesmo nome completo, mas são **dois registros que não estão ligados**: o vigilante tem `usuario_id` nulo, ou seja, aparece como "sem login". Vale corrigir depois, para que o Bruno gestor e o Bruno vigilante sejam a mesma pessoa aos olhos do sistema.

UUID do Bruno usuário: `130db52b-c966-44d9-aa35-622e24eb953c`

### 11.2 O que o Bruno cadastrou

**Uma escolta, e mais nada.**

| Tabela | Do Bruno | Do Pecanha | Sem autor | Total |
|---|:-:|:-:|:-:|:-:|
| escoltas | **1** | 5 | 0 | 6 |
| fotos | 11 | 51 | 0 | 62 |
| pontos_controle | 3 | 23 | 0 | 26 |
| checklists | 2 | 8 | 0 | 10 |
| clientes | 0 | 5 | 0 | 5 |
| veiculos | 0 | 6 | 0 | 6 |
| vigilantes | 0 | 10 | 0 | 10 |
| armamentos | 0 | 0 | **10** | 10 |
| checklist_modelos | 0 | 0 | **6** | 6 |
| escolta_veiculos | 0 | 0 | **6** | 6 |
| escolta_efetivo | 0 | 2 | 10 | 12 |

As 11 fotos, os 3 pontos e os 2 checklists do Bruno pertencem todos à mesma escolta.

`armamentos`, `checklist_modelos` e `escolta_veiculos` têm `criado_por` nulo em 100 por cento das linhas. A regra B, como está escrita, trata nulo como "não é do Bruno" e apagaria os 10 armamentos inteiros.

### 11.3 As escoltas

| Código | Status | Criada | Cliente | Autor |
|---|---|---|---|---|
| ESC-2026-0001 | finalizada | 19/08 | Grupo Ouro Branco Ltda | Laudenir Junior |
| ESC-2026-0002 | na_base | 20/08 | GRUPO ESQUEMATIZA | Laudenir Junior |
| ESC-2026-0003 | agendada | 20/08 | Grupo Ouro Branco Ltda | Laudenir Junior |
| ESC-2026-0004 | finalizada | 21/08 | Grupo Ouro Branco Ltda | Laudenir Junior |
| ESC-2026-0005 | agendada | 21/08 | GRUPO ESQUEMATIZA | Laudenir Junior |
| **ESC-2026-0006** | **em_transito_destino** | **10/09** | **Jamef Transportes** | **Bruno Moreira** |

### 11.4 Achado que trava a execução: a escolta do Bruno está em curso agora

`ESC-2026-0006` foi criada às 21h46 UTC de 10/09/2026 e o último ponto de controle entrou às 21h52, seis minutos antes do diagnóstico. Previsão de chegada: 23h00 UTC.

```
21:50:31  base_saida
21:52:08  origem
21:52:48  transito_destino
```

Rota: Rua Cândido de Figueiredo 204, Tanque, Rio de Janeiro, para Estrada Arthur Antônio Sendas 999, São João de Meriti.

**É uma operação real acontecendo neste momento, com viatura na rua.** Rodar exclusão em massa agora significa disputar linha com o operador que está lançando ponto de controle, e arriscar deixar a escolta dele num estado inconsistente no meio do trajeto. **A limpeza espera a escolta finalizar.**

### 11.5 Achado que muda o escopo: o Bruno não cadastrou nada

O pedido foi "manter apenas o que ele inseriu". Como ele não inseriu cadastro nenhum, aplicar a regra B ao pé da letra deixa a base assim:

| Tipo | Sobra | O que some |
|---|---|---|
| Clientes | 1 (Jamef Transportes) | Grupo Ouro Branco, GRUPO ESQUEMATIZA, Transporte de Valores Brasil, Logística Protegida |
| Veículos | 1 (RKQ-E707) | RVG-8J89, SRX-8G32, TUB-5H10, SRL-1C79, TTR-5J81 |
| Vigilantes | 2 (Carlos Alberto e Bruno Moreira de Mendonça) | os outros 8 |
| Armamentos | 0 | todos os 10 |

Sobram apenas os quatro cadastros que a escolta do Bruno usa. **A frota, o efetivo e o acervo de armamento da empresa saem junto.**

Parte desses cadastros parece dado real da Esquematiza, não teste: placas com modelo (FIAT ARGO, VW POLO), nomes em caixa alta com aparência de efetivo real, numerações de armamento plausíveis, e os clientes GRUPO ESQUEMATIZA e Jamef Transportes. Outros parecem demonstração: Transporte de Valores Brasil S/A, Logística Protegida do Brasil, Grupo Ouro Branco Ltda, e os vigilantes em Title Case.

**Não dá para separar real de teste sem Pecanha dizer.** Fica registrado como decisão pendente, não como suposição.

### 11.6 Volume que sai na regra A, se aplicada

| Tabela | Linhas que saem |
|---|---|
| escoltas | 5 |
| escolta_veiculos | 5 |
| escolta_efetivo | 10 |
| pontos_controle | 23 |
| checklists | 8 |
| checklist_respostas | 68 |
| escolta_status_historico | 26 |
| fotos | 50 das 62 |

As 50 fotos têm arquivo correspondente no Storage, que **não tem backup**.

### 11.7 Correção a fazer nos scripts

`escolta_status_historico` **não tem coluna `criado_em`**. A tentativa de ordenar por ela devolveu erro `42703` do PostgREST. O script da fase 3 apaga por `escolta_id` e não é afetado, mas qualquer consulta futura a essa tabela precisa conferir o nome real da coluna de data antes de usar.

---

*Plano escrito em 10/09/2026 sobre o schema descrito em `docs/03 - Arquitetura Atual.md` e o commit `f7056e4`. A seção 11 traz o diagnóstico real, somente leitura. Nenhum comando de escrita foi executado.*
