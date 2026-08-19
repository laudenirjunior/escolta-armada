# Decisões Técnicas

Cada decisão com a alternativa que foi descartada e o custo assumido.

## Fluxo

**A etapa nova fica entre No Destino e Retorno.** O pedido foi literal: "entre o destino e o retorno deve haver o trânsito para o retorno". A regra de exigir o ponto vive na aresta `retornando -> na_base`, porque o pedido fala em **concluir** o retorno, não em iniciá-lo.

**Grandfathering por coluna, não por data.** `fluxo_versao` é explícita e auditável. Comparar `criado_em` com a data da migration seria implícito e frágil.

**Custo assumido:** enquanto houver escolta versão 1 em andamento, a trigger carrega um ramo de compatibilidade que aceita pular etapas.

## Fotos

**Até 5, mínimo 1.** O pedido inicial era mínimo 5. Na confirmação foi ajustado, e é uma escolha boa: mínimo 5 em 6 pontos daria mais de 30 fotos e algo entre 90 e 150 MB por escolta, subidos de dentro de uma viatura em movimento, num app **sem fila offline**.

**Custo assumido:** a prova fotográfica é menor do que seria com 5 obrigatórias. Em compensação, a regra sobrevive ao uso real em campo.

## Cadastro de usuário

**RPC corrigida em vez de admin API.** O caminho mais durável seria uma Route Handler com `auth.admin.createUser()` e a service role key, porque não depende da estrutura interna do GoTrue. Mas a chave não estava configurada, e a RPC corrigida resolve a causa e funciona hoje.

**Custo assumido:** `criar_usuario_por_login` escreve em `auth.users` e `auth.identities`, que são tabelas internas do Supabase. Se o GoTrue mudar de estrutura, a função quebra. Quando a service role key estiver disponível, migrar.

**Acesso por login, não por e-mail.** O e-mail interno `<login>@operador.local` é invisível ao usuário. **Custo assumido:** essas contas não têm como recuperar a senha sozinhas, porque não existe caixa postal. Toda redefinição depende de um administrador. Com dois administradores, se ambos ficarem indisponíveis, ninguém redefine senha de ninguém.

**Senha `123456` sem exigência de complexidade.** Decisão de usabilidade, tomada conscientemente. **Custo assumido:** senha inicial pública e igual para todos. Mitigações: troca obrigatória no primeiro acesso, proibição de "trocar" `123456` por `123456`, e a RLS limitando o alcance de uma conta comprometida. Conflita com a proteção contra senha vazada do Supabase, que por isso segue desligada.

## RLS

**Substituir as políticas, não só ligar a chave.** 33 das 78 políticas tinham predicado `true`, e políticas permissivas se combinam por OU: a permissiva anulava a restrita ao lado. Ligar RLS sem trocá-las zeraria os advisors sem proteger nada.

**Leitura livre nas tabelas de domínio.** `dom_*` são listas fixas sem dado sensível, e `dom_perfis` alimenta o menu inteiro. Restringir deixaria a navegação vazia.

**Leitura da própria linha em `usuarios` é obrigatória.** O `useAuth` resolve o perfil da sessão com select direto e o layout bloqueia a renderização se voltar vazio. Negar trancaria todo operador fora do sistema.

**Forma `(select fn())` nas políticas.** Vira InitPlan e é avaliada uma vez por consulta, não por linha.

**Custo assumido:** 13 avisos permanentes de `SECURITY DEFINER` executável por autenticado. São necessários: as políticas chamam os resolvedores de identidade e as RPCs precisam ser chamáveis.

## Migrations

**O `database/migrations/` original foi aposentado.** Os 7 arquivos descreviam um schema v1 que nunca existiu neste banco. O `007` redefinia `auth.uid()` recursivamente e quebraria toda a autenticação se executado. Foram para `database/_legado_v1/` com um README de alerta.

## Gráficos

**Sem biblioteca de gráficos, se e quando forem feitos.** Os gráficos precisam sair no PDF impresso, e canvas não imprime bem. SVG próprio, com `d3-scale` e `d3-shape` apenas para escalas e geometria.
