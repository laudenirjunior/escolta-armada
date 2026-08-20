# Log de Alterações

Ordem cronológica inversa. Cada entrada registra o que mudou, por quê, e como foi verificado.

Plano de referência: `~/.claude/plans/fa-a-um-planejamento-detalhado-greedy-wirth.md`
Projeto Supabase: `qthoyxujyzskydulvcfy` (escolta-armada, us-east-2)
Branch de trabalho: `master` (producao serve master; ver a entrada de 19/08 sobre por que isso importa)

---

## 2026-08-20 - Credenciais visíveis, mural de escoltas e edição

### Antes de tudo: a jornada de 9 etapas rodou inteira em produção

A ESC-2026-0001, criada por Pecanha em 19/08 às 22:56, foi finalizada às 23:53 com **sete pontos de controle**, todos com GPS: `base_saida`, `origem`, `transito_destino`, `destino`, `transito_retorno`, `retorno`, `base_retorno`.

A linha do tempo mostra o deploy acontecendo no meio: ele avançou até `na_origem` às 23:00 e **parou 51 minutos**, porque o site ainda servia o fluxo de 8 etapas. Às 23:51 as cinco etapas restantes saíram em dois minutos. As observações gravadas a partir daí são os textos padrão de `lib/textos-padrao.ts`, o que confirma que o bundle novo estava valendo.

O ponto de `origem` ficou sem foto e a observação dele termina com `Obs: ` órfão: os dois são resíduo do código antigo, gravados às 23:00, antes do deploy.

### Migration 190 - `credencial_visivel_ao_administrador`

**Decisão de Pecanha, reafirmada depois de eu apresentar o limite.**

**O limite é físico, não de permissão.** `auth.users` guarda bcrypt de mão única. As senhas definidas antes desta data não são recuperáveis por ninguém: nem pelo administrador, nem pelo Supabase, nem por mim. Carvalho e Pecanha já haviam trocado as deles, e essas duas estão perdidas para sempre.

O que passou a existir é o registro daqui em diante, em `usuarios_credenciais`. Tabela separada de `usuarios`, e não coluna nela, porque `usuarios` tem leitura ampla entre autenticados (decisão anterior, para o nome do autor aparecer na timeline): guardar a senha lá a exporia a todo mundo.

Proteções: RLS restrita a `administrador`; escrita só pela RPC `registrar_credencial`; leitura só pela RPC `ler_credencial`, que grava cada consulta em `logs_auditoria` com quem consultou e de quem.

**Custo assumido e declarado a Pecanha:** senha em texto num banco significa que um vazamento a entrega pronta, e como as pessoas repetem senha entre sistemas o estrago ultrapassa este aplicativo.

**Detalhe do desenho que veio de uma recusa:** tentei semear as senhas provisórias conhecidas direto no banco e a operação foi barrada por ser gravação de senha em texto. Isso levou a um desenho melhor: enquanto a senha ainda é a provisória, a tela **deriva** de `troca_senha_obrigatoria`, sem guardar nada. Só passa a guardar depois da primeira troca. Menos senha em texto, mesmo resultado.

### Migrations 191 e 192 - mural de escoltas

Decisões de Pecanha: gestão edita tudo enquanto a escolta não começou; qualquer um vê as não iniciadas, com tudo menos o financeiro; o operador pode puxar uma para si, virando comandante, e incluir outro vigilante; sai do mural dos demais ao ser puxada; pode devolver enquanto não começar; quem puxou **não** edita.

"Não começou" é `agendada`. `rascunho` fica fora de propósito: é planejamento incompleto, e oferecer para puxar produziria escolta impossível de executar.

A trava de edição é uma **trigger**, e não revoke por coluna, porque o Postgres ignora revoke de coluna quando o privilégio foi concedido no nível da tabela. Ela deixa o operador mudar status e barra cliente, data e local.

`puxar_escolta` trava a linha com `FOR UPDATE`: sem isso, dois operadores puxam no mesmo instante e os dois viram comandante.

**Defeito meu, corrigido na 192:** `escolta_efetivo` tem `escolta_id` E `escolta_veiculo_id`, os dois NOT NULL, e a versão original preenchia só o segundo. Teria quebrado com 23502 na primeira tentativa real de puxar. Pego ao conferir o schema antes de testar.

**Provado com credencial real de operador:** o mural aparece; puxar funciona; puxar de novo é recusado com "esta escolta já tem equipe designada"; editar é recusado com mensagem explicando o caminho; devolver funciona; depois que a escolta começa não devolve mais; e o mural fica vazio quando a escolta sai de `agendada`.

### Último acesso deixou de mentir

O update de `ultimo_acesso` era promessa solta, sem `await`. O `supabase-js` só dispara a requisição quando a promessa é consumida, então o UPDATE muitas vezes nunca saía. Resultado: **quatro dos cinco usuários já tinham entrado no sistema e a tela dizia "Nunca acessou" para todos eles**.

### Edição de escolta: ela não existia

Ao implementar a decisão "gestão edita tudo enquanto não começou", descobri que **a edição de escolta não existe no sistema**. O botão "Editar" da lista apontava para `?acao=editar`, parâmetro que a tela de detalhe nunca leu. Desde o início do projeto nunca foi possível corrigir cliente, data, endereço, viatura ou vigilante depois de criar.

A tela de criação passou a atender também `?editar=<id>`, em vez de nascer uma segunda tela. Ela já tem o seletor de endereço corrigido, o campo de complemento, as viaturas e o efetivo. Duas telas com os mesmos campos divergem no primeiro ajuste que alguém esquecer de replicar, e este projeto já pagou esse preço.

**O complemento passou a ser guardado também em `metadados`**, além de concatenado na coluna. Separar de volta pela vírgula seria adivinhação: o endereço do Mapbox já vem com vírgulas próprias, e não há como saber qual marca o início do complemento. Escolta criada antes do campo existir abre com o endereço inteiro e complemento vazio, que é o correto.

Travas: a tela recusa abrir para escolta iniciada; o update leva `.in('status', ['rascunho','agendada'])` junto, então se a escolta começar com o formulário aberto nenhuma linha casa e o salvamento para em vez de sobrescrever operação em andamento; viaturas e efetivo são substituídos por inteiro, o que só é seguro porque não há ponto de controle apontando para eles.

**Corrigido junto:** o insert de efetivo engolia erro. A escolta nascia com viatura e sem equipe, e ninguém ficava sabendo até a hora de sair da base.

### Relatório final com modelo

Vem preenchido com os dados reais da escolta: código, cliente, trajeto, horários, equipe, viaturas e contagem de ocorrências. Editável.

**Consequência declarada a Pecanha:** o campo tinha `if (!relatorioFinal.trim())` como única barreira, e vir preenchido faz essa barreira parar de recusar qualquer coisa. Foi escolha dele, pela agilidade de fechar a escolta em campo. É a exceção à regra da entrada de 19/08, que separa campo de rotina de campo com validação.

### Estado da verificação

`tsc` zero erros, `build` verde. Rotas em produção respondendo: públicas 200, dashboard 307 para o login, manifesto 200. A rota `?editar=` responde igual às demais, o que confirma que o limite de Suspense exigido pelo `useSearchParams` não quebrou a pré-renderização.

### Pendências abertas nesta rodada

1. **Nada disso foi visto em tela renderizada.** Continua valendo: o que tem oráculo objetivo eu verifico, o que depende de olhar não.
2. `redefinir_senha_usuario` tem uma armadilha de nome: o parâmetro se chama `p_usuario_id` mas espera o `auth_user_id`. Está comentado nos tipos, mas o certo seria renomear.
3. A senha só é registrada quando o usuário troca ou o administrador redefine. Conta criada e nunca usada mostra a provisória por derivação, sem registro.
4. Ocorrência, emergência e checklist continuam atribuídos à primeira viatura em escolta com comboio.


---

## 2026-08-19 - As cinco frentes relatadas por Pecanha

### A causa do bloqueio: banco e código em versões diferentes

**O quê:** produção servia `origin/master`, com o fluxo antigo de 8 etapas, enquanto o banco já estava no de 9. O botão em "No Destino" mandava `retornando` e o banco só aceitava `em_transito_retorno`, então o PATCH voltava 400 e a escolta não avançava.

**Prova:** log do Postgres em 2026-08-19T14:17:32.494Z com `Transicao de status invalida: no_destino para retornando`, e no mesmo instante o log de borda com `PATCH /rest/v1/escoltas?id=eq.bc0f9212-...`, status 400, referer `https://escolta-armada.vercel.app/`. `git show origin/master:lib/fluxo-escolta.ts` responde que o caminho existe em disco mas não em `origin/master`.

**Por quê aconteceu:** as migrations 100 a 172 foram aplicadas direto em produção ao longo do trabalho, e o código correspondente ficou na branch `fase0-seguranca`, que nunca foi publicada. A combinação "não fazer push sem ordem" mais "aplicar migration em produção" produz exatamente este resultado. **A ordem banco/deploy que o plano declarava por fase não foi seguida na prática, e isso travou a operação de Pecanha por horas.**

**Regra que fica:** migration que muda contrato de fluxo só vai para produção na mesma janela do deploy do código. Se o deploy depende de autorização, a migration espera pela mesma autorização.

### Decisões de Pecanha nesta rodada

| Assunto | Decisão |
|---|---|
| Publicação | Testar no preview antes de publicar em produção |
| GPS sem sinal em campo | **Deixar avançar e marcar o ponto como sem sinal**, em vez de bloquear |
| ESC-2026-0001 | Apagar e começar limpa |

### Migration 180 - `ponto_sem_sinal_gps`

**O quê:** `pontos_controle.latitude` e `longitude` passam a aceitar nulo, nasce `sem_sinal_gps boolean NOT NULL DEFAULT false`, e um CHECK amarra os dois estados.

**Por quê:** decisão de Pecanha. O operador em garagem, subsolo ou trecho sem cobertura precisa conseguir avançar, e a falta de sinal precisa ficar registrada em vez de virar coordenada inventada.

**O CHECK não é zelo excessivo:** sem ele, a combinação "sem coordenada e sem marca" voltaria a existir e o relatório não teria como distinguir ponto sem GPS de ponto mal gravado. Coordenada sentinela 0,0 está proibida por escrito: é uma posição real no golfo da Guiné e sujaria mapa, `fitBounds` e indicador de precisão com dado falso.

`GRANT` explícito para a coluna nova, porque `ALTER DEFAULT PRIVILEGES` cobre tabela nova, não coluna nova de tabela existente.

### Três arquivos de fundação

`lib/fluxo-escolta.ts` ganhou `exigeDialogoDedicado`, que separa as etapas que exigem prova das que não exigem. Os rótulos de `PROXIMO_STATUS` foram alinhados com os do Painel de Ações, porque existiam dois nomes para a mesma ação na mesma tela.

`lib/textos-padrao.ts`, novo, com todas as frases padrão. A divisão em duas famílias é a parte que importa: **campo cuja única barreira é `if (!campo.trim())` recebe o texto como placeholder, nunca como valor**. Pôr frase de fábrica no valor desses campos anularia a validação e liberaria a jornada inteira sem uma linha digitada, justamente no wizard de pré-início, na parada, no cancelamento e no relatório final. Ocorrência, emergência, cancelamento e item de checklist não conforme não recebem sugestão nenhuma: existem para registrar o que fugiu do previsto, e texto pronto ali facilita registro falso.

`lib/pontos-controle.ts`, novo, com a serialização única das observações. Ele já corrigiu um defeito silencioso: **a página de impressão procurava a chave `justificativa` e os pontos gravavam `observacao`**, então o texto do operador sumia do relatório que vai para o cliente. A leitura é tolerante e aceita as três formas encontradas em produção, incluindo texto puro legado.

### Frente 1 - o fluxo travado

- O botão verde do cabeçalho da tela de detalhe **deixa de avançar as sete etapas que produzem ponto de controle**, mais a finalização. Ele mudava o status sem foto, sem GPS e sem gerar ponto, com rótulo quase idêntico ao do botão certo do Painel de Ações. Foi por ele que a ESC-2026-0001 chegou ao destino sem os pontos `transito_destino` e `destino`. Sobram para ele apenas `rascunho -> agendada` e `agendada -> em_pre_inicio`, que não produzem ponto.
- Ordem invertida em oito handlers: **ponto de controle antes do update de status**. O modo de falha muda de "status avançado sem prova, que trava para sempre" para "ponto sem transição, que se resolve conferindo a etapa".
- Precondição `.eq('status', ...)` com `.select('id')` em todos os updates. Sem o `select`, o PostgREST devolve sucesso quando casa zero linhas, e a tela anunciava transição que não aconteceu.
- Conferência da etapa imediatamente antes de gravar o ponto, nas duas telas. O upload das fotos leva segundos, e nesse intervalo outra pessoa pode avançar a escolta. Isso reduz a janela de segundos para milissegundos; **não a elimina**, e só uma RPC transacional fecharia de vez.
- `handleWizardSubmit` recebeu o mesmo tratamento. Ele era o único caminho de avanço sem nenhuma dessas proteções, e ainda bloqueava o operador quando o GPS falhava.

### Frente 2 - textos padrão

Grupo com valor inicial, e o asterisco do rótulo sai junto porque a tela deixa de mentir sobre o que é obrigatório: saída da base, origem, trânsito ao destino, destino, trânsito de retorno, retorno, chegada na base, check-in e avanço genérico. O valor é reaplicado toda vez que o diálogo abre, senão o campo ficaria vazio a partir da segunda etapa.

Grupo com placeholder apenas: os três campos do wizard, parada, cancelamento, reagendamento, relatório final e item de checklist não conforme.

As sugestões por tipo de parada entram por clique, nunca como valor. Quatro tipos ficam sem sugestão nenhuma: manutenção, ocorrência, bloqueio e fiscalização, que são eventos de desvio com valor probatório.

No Telegram, a observação só é enviada quando difere do texto padrão daquela etapa. Sem isso, toda etapa notificaria "sem alterações" ao cliente e a notificação viraria ruído.

### Frente 3 - seletor de endereço

Duas causas, não uma, para o mesmo sintoma que Pecanha descreveu como "por vezes continua aberto".

A primeira: escolher a sugestão preenchia o campo, e o efeito de busca observava o valor do campo, então a escolha disparava uma busca nova que voltava depois e reabria a lista. Resolvido com marcação de pulo e contador de sequência, mais `AbortController` por ciclo.

A segunda, encontrada só na revisão: clicar fora fechava a lista, mas a resposta em voo chegava depois e reabria por cima do formulário. Clicar fora não muda o texto nem desmonta o componente, então nada invalidava aquele ciclo.

Uma terceira, introduzida pela correção e pega pela revisão: a guarda de sequência no `finally` deixava o indicador de carregamento girando para sempre se o usuário apagasse o texto enquanto uma busca estava em voo.

### Frente 4 - instalação na tela do celular

`app/manifest.ts`, `public/sw.js`, `components/instalar-app-provider.tsx` e cinco ícones PNG.

**O service worker não tem cache nenhum, de propósito.** Cache-first é exatamente o que serve página velha depois de um deploy, e sobrevive à limpeza normal do navegador. Este projeto acabou de passar horas com bundle antigo em produção; criar uma segunda forma de isso acontecer, agora do lado do cliente, seria pior. O handler de fetch é vazio e existe apenas para satisfazer o critério de instalabilidade do Chrome no Android.

Os ícones foram gerados por script próprio, com `zlib` puro, porque o projeto não tem `sharp`, `canvas` nem `jimp`. A arte é o mesmo escudo da tela de login. O `maskable` traz o escudo menor, dentro dos 80% centrais, com o fundo sangrando, para sobreviver ao recorte circular do Android. O `apple-icon` de 180x180 existe porque o iOS ignora por completo o array de ícones do manifesto.

O aviso cobre Android e iPhone, que funcionam de formas diferentes: no Android captura `beforeinstallprompt` e oferece botão; no iOS mostra a instrução de Compartilhar e Adicionar à Tela de Início, porque esse evento não existe lá. Não aparece se já estiver instalado, no desktop, ou se tiver sido dispensado há menos de 14 dias.

`viewportFit: 'cover'` veio acompanhado do tratamento de área segura nos quatro eixos. A barra inferior usa `calc(64px + env(safe-area-inset-bottom))`, e não `minHeight: 64px` com padding: com `box-sizing: border-box` global, o padding seria descontado de dentro dos 64px e a área tocável cairia para cerca de 40px no iPhone, abaixo do mínimo de 44px do iOS.

`maximumScale` não foi usado: bloquear o zoom é regressão de acessibilidade num aplicativo de campo.

### Frente 5 - impressão

A impressão era disparada por relógio, 600 ms depois de os dados chegarem, sem esperar imagem nenhuma. Com até 5 fotos por ponto em resolução integral, uma escolta de 8 pontos pede dezenas de megabytes: quem imprimisse pelo celular receberia um PDF com as molduras em branco, sem erro visível, **justamente na seção criada para carregar a prova**. Agora a página espera as imagens decodificarem, com teto de 15 segundos para uma foto travada não impedir o resto.

`utils/print.ts` foi reescrito. Ele chamava `print()` por conta própria 1200 ms depois do load, o que somado ao disparo da própria página produzia **dois diálogos de impressão**. Agora quem decide a hora é a página, que avisa por `postMessage`, e o utilitário só espera para remover o iframe, com rede de segurança de 25 segundos.

O contador de fotos passa a declarar a lacuna. A policy `fotos_select` só dá acesso amplo a administrador, gestor, supervisor e central; para os demais perfis ela alcança apenas a foto escalar de `pontos_controle.foto_id`, e os ids das fotos 2 a 5 vivem no JSON de observações. Sem isso o relatório diria "5 fotos" e mostraria uma, sem explicar. **A correção de fundo é estender a policy, que exige migration e ficou pendente.**

### Documentação corrigida

README, ARQUITETURA e ESTRUTURA prometiam funcionamento offline com IndexedDB, Cache API e Service Workers desde junho, e nada disso existia. Agora que o aplicativo ficou instalável, a promessa ficaria ainda mais enganosa. Os três dizem o que é: instalável na tela de início, **sem funcionamento offline**, com um service worker que não guarda nada.

### Método

Três rodadas de agentes em paralelo, uma por arquivo para não haver conflito de edição, cada uma seguida de um revisor instruído a refutar, não a concordar.

A revisão adversarial se pagou: das cinco frentes implementadas, **as cinco voltaram com defeito**, sendo cinco regressões que o `tsc` não pegaria. As duas mais caras seriam invisíveis até o cliente reclamar: a impressão sem fotos e o endereço do ponto sumindo do mapa.

### As três decisões de Pecanha

Tomadas em 2026-08-19, depois de eu apresentar as opções com o custo de cada uma.

#### 1. Pré-início não acontece pela tela de campo

Ao derivar o mapa de etapas da fonte única, a tela de campo tinha ganhado um caminho de `em_pre_inicio -> em_andamento` que antes não existia: o operador saía da base com uma foto e uma observação, sem conferência de material, sem conferência de viatura, sem as 5 fotos de ângulo e sem o KM de saída. A escolta começava sem registro nenhum do estado da viatura.

Pecanha escolheu exigir o questionário completo. O caminho saiu, e no lugar entrou um aviso dizendo que a saída é liberada pelo supervisor e que o registro dos pontos aparece assim que ele confirmar.

#### 2. Campo separado de complemento de endereço

O comportamento que zera a coordenada ao redigitar existe para a escolta não nascer com o endereço de um lugar e a coordenada de outro, e continua de pé. O efeito colateral era não haver como registrar "apto 302", "portão dos fundos", "doca 2", que é informação operacional real: sem ela a equipe chega no número e descobre o resto por rádio.

Agora há um campo próprio de complemento para origem e para destino. Ele não passa pela busca do Mapbox, não dispara requisição e não toca em coordenada nenhuma. Na gravação, entra concatenado ao endereço escolhido, e aparece já concatenado no passo de revisão, para o usuário ver o que será gravado.

#### 3. Um ponto de controle por viatura

**A decisão mais cara das três, e Pecanha escolheu sabendo.** Antes, `viaturas[0]` aparecia 20 vezes na tela de detalhe: todo ponto era gravado para a primeira viatura e a segunda não aparecia em lugar nenhum. Se ela se separasse do comboio ou atrasasse, nada registrava, e o sistema declarava a escolta conforme.

Agora cada viatura tem o próprio ponto, com fotos e KM próprios, e a placa entra no rótulo para o relatório distinguir os dois pontos da mesma etapa. A validação diz **qual** viatura está faltando foto, pela placa: mensagem genérica ali deixaria o supervisor adivinhando.

**O caso de uma viatura não piorou**, e isso foi requisito explícito: sem cabeçalho extra, sem moldura, sem passo a mais, e o texto "por viatura" só aparece quando há comboio.

**A regra que dá sentido à decisão, na tela de campo:** o status só avança quando **todas** as viaturas tiverem ponto naquela etapa. Sem isso a decisão não se sustentaria ali: o primeiro registro avançaria a etapa, o botão sumiria, e a segunda viatura ficaria para sempre sem o ponto. Cada equipe registra a sua, e a última destrava a jornada. Com uma viatura, a primeira já é a última e nada muda.

Para perfil administrativo com comboio, a tela pede a escolha explícita da viatura, com a placa. A alternativa seria gravar a mesma foto para as duas, o que criaria prova falsa de que ambas foram vistas: quem está no dashboard não está na estrada.

#### O que a revisão pegou nesta rodada

**Insert em lote, não um por viatura.** Um insert por viatura em sequência criava uma janela nova de graça: se o da primeira passasse e o da segunda falhasse, o status não seria tocado, o operador repetiria a etapa e a primeira ficaria com o ponto **duplicado** no relatório do cliente, sem ninguém conseguir apagar, porque `pontos_controle` não tem policy de DELETE. O PostgREST aceita array, e insert com várias linhas é um statement só, portanto atômico.

**Escolta sem viatura vinculada abria um diálogo mudo.** O componente novo iterava sobre uma lista vazia: nenhum botão de câmera, nenhuma explicação, e o confirmar desabilitado para sempre. Antes o operador ao menos clicava e recebia a mensagem. Agora a explicação aparece no lugar da lista.

**Prefixo por placa que não chegava a lugar nenhum.** O componente compunha um nome de arquivo com a placa, mas o caminho no storage é montado em outro lugar, com prefixo único. Prometer no código o que não acontece confunde quem for depurar depois.

Um achado do revisor **não se confirmou**: ele previu que a chave computada de union no update de KM quebraria a compilação, com argumento técnico detalhado sobre como o `postgrest-js` tipa o update. O `tsc` passou limpo. Registrado porque a análise era plausível e mesmo assim errada, o que é exatamente o motivo de verificar antes de aceitar.

#### Prova no banco

Escolta de teste com duas viaturas, criada e apagada:

| Passo | Resultado |
|---|---|
| Só a viatura A registrou | 1 viatura faltando, etapa **não** avança |
| A viatura B também registrou | 0 faltando, etapa **destrava** |
| Lote com uma linha violando o CHECK de GPS | recusado **inteiro** |
| Pontos após o lote recusado | 2, nenhuma linha parcial entrou |
| Base após a limpeza | 0 escoltas, 0 pontos, 0 vínculos |

`tsc` zero erros, `build` verde, `lint` zero erros.

#### Pendências abertas por esta decisão, declaradas

1. **Checklist de entrega da finalização** continua cobrindo apenas a primeira viatura: com comboio, a segunda é entregue sem registro de estado. Há aviso no diálogo dizendo qual placa está sendo registrada.
2. **Checklists de partida do wizard** (materiais e viatura, com as 5 fotos de ângulo) idem. O que o wizard já faz por viatura é o ponto de saída e o KM.
3. **Parada e check-in periódico** continuam num ponto só. O argumento escrito no código: a parada é do comboio inteiro e quem registra está dentro de uma viatura, no acostamento; exigir foto das duas obrigaria o operador a caminhar até a outra viatura no meio da estrada. **Precisa da confirmação de Pecanha.**
4. **Ocorrência, emergência e checklist** continuam atribuídos à primeira viatura quando quem usa é perfil administrativo em escolta com comboio. Não estendi por conta própria: a decisão foi sobre ponto de controle, e o seletor vive no painel de checkpoint.
5. A corrida entre duas pessoas registrando a mesma etapa para viaturas diferentes ficou **mais provável**, porque agora duas pessoas têm motivo legítimo para isso. O tratamento existente responde certo (mensagem de etapa já avançada, com o ponto salvo), mas fechar de vez continua dependendo da RPC transacional.

### Revisão final: o que quase foi para produção

A revisão adversarial do conjunto fechado encontrou quatro coisas que o `tsc` e o `build` não pegariam, sendo uma delas a mais grave do dia inteiro.

#### Migration 181 - `emergencia_sem_gps_e_sem_viatura`

**O botão de emergência não funcionava, e mentia dizendo que sim.**

Três defeitos empilhados em `campo/page.tsx`:

1. `emergencias.latitude` e `longitude` são NOT NULL, e a tela enviava nulo quando não havia sinal. O insert violava `23502`.
2. O retorno do insert **não era lido**. O `supabase-js` nunca lança: devolve `{ data, error }`. O `try/catch` em volta não via nada.
3. Não havia chamada ao Telegram em lugar nenhum de `acionarEmergencia`, nem trigger, nem webhook em `emergencias`.

O resultado somado: o operador em túnel, subsolo ou garagem apertava o botão de pânico, via a confirmação verde escrita **"EMERGÊNCIA ACIONADA! Central notificada"**, e nada tinha sido gravado nem comunicado a ninguém. A central só descobriria se estivesse olhando o contador da tela de indicadores, que também estaria em zero.

`select count(*) from emergencias` devolvia **0**: o botão nunca foi usado em produção, então isto estava armado esperando o primeiro uso real, que por definição seria o pior momento possível.

Correção em três frentes, porque nenhuma sozinha resolve: a migration solta as duas coordenadas e `escolta_veiculo_id` (perfil administrativo aciona sem viatura vinculada) com o mesmo CHECK de coerência da 180; o código passa a ler o erro e a mandar ligar para a central se falhar; e o acionamento passa a disparar o Telegram de verdade, sem `await`, porque o registro já está salvo e esperar a rede atrasaria a confirmação de quem está em emergência. O texto virou "EMERGÊNCIA REGISTRADA! Central acionada", que é o que de fato acontece.

#### A tela de campo finalizava escolta sem nada

Com `finalizada` na lista de etapas sem ponto de controle, a exigência de foto sumia e o botão deixava de travar. Qualquer vigilante escalado tocava "Finalizar Escolta" no celular e a escolta encerrava com **zero foto, zero checklist de entrega, zero relatório final**. O banco aceita: `validar_transicao_status_escolta` não impõe pré-condição em `na_base -> finalizada`.

A mesma transição, pela tela de detalhe, exige 5 fotos de ângulo da viatura, os 5 itens do checklist respondidos, descrição de cada não conformidade e relatório não vazio.

Pior que a diferença de portão: o caminho do campo não gravava `observacao_fechamento` nem `data_finalizacao`, e nenhuma trigger preenche esses campos. A escolta ficava finalizada com `data_finalizacao` nula, o que quebra a duração no impresso e o indicador de tempo médio.

`na_base` saiu do avanço da tela de campo, e no lugar do botão entrou um aviso dizendo onde a finalização acontece. A exceção `finalizada` saiu junto: exceção morta é o que faz alguém reintroduzir o caminho por engano.

#### A finalização era o único passo que ainda travava por GPS

Dez dos onze caminhos já usavam a função que não bloqueia. `handleFinalizacao` continuava com a que lança, e a exceção virava "User denied Geolocation" **depois** de as 5 fotos da viatura já terem subido. O cenário é diário: a viatura é recolhida na garagem coberta da base, que é exatamente onde não há sinal, e cada nova tentativa subia mais 5 fotos órfãs no bucket.

#### O impresso perdia etapas de escolta antiga

O filtro do feed descartava do histórico todas as sete etapas que produzem ponto, na premissa de que a linha equivalente viria dos pontos. A premissa vale para escolta nova e falha para as antigas. A primeira escolta de teste chegou ao destino sem os pontos `transito_destino` e `destino`: o relatório dela deixaria de mostrar essas etapas por caminho nenhum, junto com a observação que o operador digitou na transição, que só existe em `escolta_status_historico`.

A supressão passou a depender da existência do ponto, não do status. Exigiu trazer o código do tipo de ponto na consulta.

#### Menores, corrigidos junto

- As fotos do diálogo de finalização não eram zeradas ao reabrir. O componente de câmera guarda a lista em estado interno e é desmontado ao fechar, então os widgets voltavam vazios enquanto o cabeçalho continuava verde com "OK" e o contador dizia "5 de 5": a tela mostrava uma coisa e o banco recebia os arquivos antigos.
- O wizard de pré-início não passava pela guarda de pré-requisitos. Sessão expirada com o wizard aberto gravava os dois checklists e as 7 fotos, e só então quebrava no insert do ponto, porque `lancado_por` é NOT NULL.
- O botão do check-in era o único dos nove sem a trava de foto mínima: ficava verde e habilitado e só devolvia erro depois do toque.
- `STATUS_ATIVOS` estava importado na tela de campo e nunca usado, enquanto a tela mantinha o próprio array, que exclui `agendada` enquanto o importado a inclui. Import morto de regra compartilhada é pior que nenhum, porque sugere que a regra está unificada.

### Estado da verificação

`npx tsc --noEmit` em zero erros. `npm run build` verde. `npx next lint` com zero erros e 30 avisos, todos de código morto pré-existente.

Servidor de produção subido localmente: as 11 rotas do dashboard devolvem 307 para o login sem sessão, as duas públicas devolvem 200, `/manifest.webmanifest` devolve 200 com `application/manifest+json`, e os cinco ícones respondem. O HTML traz `<link rel="apple-touch-icon">` de 180x180, que é o que o iPhone usa.

### O que continua pendente, declarado

1. **Atomicidade real.** A conferência de etapa antes de gravar o ponto reduziu a janela de segundos para milissegundos. Não a fechou. Só uma RPC transacional, gravando ponto, status e histórico numa transação, elimina o ponto órfão.
2. **Policy `fotos_select`.** Ela só alcança a coluna escalar `pontos_controle.foto_id`, e os ids das fotos 2 a 5 vivem no JSON de observações. Operador e vigilante veem uma foto por ponto no impresso, com o aviso de lacuna. A correção é migration.
3. **`PODE_FINALIZAR_ESCOLTA`** existe em `lib/permissions.ts` restrito a administrador, gestor e supervisor, e não é importado em lugar nenhum. Nem o botão da tela de detalhe o consulta.
4. **Diálogo "Saída da Base" inalcançável.** `setDialogStartBase(true)` não existe no arquivo: são cerca de 150 linhas mortas, incluindo um caminho completo de insert. Já era morto antes desta rodada.
5. **Ponto de controle da tela de campo não grava `tipoLabel` nem `endereco`**, então o mapa não rotula o último ponto da equipe na estrada e a tela de notificações mostra menos contexto. A tela de detalhe grava os dois.
6. **Três decisões de produto** aguardando Pecanha: se o pré-início pode ser vencido pela tela de campo sem o wizard; como complementar endereço com "apto 302" sem perder a coordenada; e para qual viatura vai o ponto quando a escolta tem duas.


---

## 2026-08-19 - Limpeza da base operacional para testes

### Migration 172 - `corrige_escalada_por_update_direto`

**O quê:** reescrita completa de `impedir_autopromocao()`, a trigger de `usuarios`.

**Por quê:** furo de escalada de privilégio, **comprovado ao vivo com JWT real**. O gestor Bruno fez um único `PATCH /rest/v1/usuarios?id=eq.<o proprio id>` com `perfil_id` de administrador, recebeu **HTTP 200**, e o perfil dele passou a `administrador` de fato. O perfil foi restaurado para `gestor` em seguida.

A causa é a primeira linha da trigger que eu mesmo escrevi:

```sql
SELECT public.get_meu_perfil() INTO v_perfil;
IF v_perfil IN ('administrador','gestor') THEN
  RETURN NEW;                 -- libera antes de olhar DE QUEM e a linha
END IF;
```

Ela conferia o perfil do **chamador** e nunca conferia se a linha alterada era a dele. O nome da função prometia impedir autopromoção e era exatamente a autopromoção que passava.

O mesmo defeito tinha um segundo efeito, invertido: com `auth.uid()` nulo (SQL direto, migration, service role), `get_meu_perfil()` devolve NULL, NULL não está na lista, e a função caía no ramo de bloqueio. Ou seja, **liberava o gestor e barrava a via de reparo administrativo**. Foi por isso que o `UPDATE` de restauração do perfil do Bruno falhou na primeira tentativa.

É a terceira ocorrência da mesma classe de defeito neste banco, depois de `criar_usuario_completo` (§1.0 do plano) e `criar_usuario_por_login` (migration 151). A lição não é sobre `NULL NOT IN` desta vez, é sobre **conferir o sujeito e o objeto da operação, não só o sujeito**.

**Regras agora aplicadas:**

| Situação | Comportamento |
|---|---|
| Alterar o próprio `perfil_id` | Recusado para **todos**, inclusive administrador |
| Alterar o próprio `status` | Recusado para todos |
| Alterar `auth_user_id` pela API | Recusado sempre. Trocar o vínculo é sequestro de conta, não edição de cadastro |
| Gestor alterando perfil de terceiro | Permitido, **exceto** conceder ou remover `administrador` |
| Administrador alterando perfil de terceiro | Permitido |
| Perfil não gestor alterando perfil de terceiro | Recusado |
| Sessão sem `auth.uid()` | Passa, declaradamente. É a via de reparo do banco, controlada pela reconciliação detectiva |

A checagem usa `OLD.auth_user_id = v_eu OR NEW.auth_user_id = v_eu`, para o caso de a linha ser reapontada na mesma instrução.

**Verificação, toda com JWT real:**

| # | Ataque ou operação | Antes | Depois |
|---|---|---|---|
| 1 | Gestor se promove a administrador | **200, promovido** | 400 `Voce nao pode alterar o proprio perfil de acesso` |
| 2 | Gestor rebaixa um administrador | 200 | 400 `Somente um administrador concede ou remove o perfil administrador` |
| 3 | Gestor promove terceiro a administrador | 200 | 400, mesma mensagem |
| 4 | Gestor troca o próprio `auth_user_id` | 200 | 400 `O vinculo de autenticacao nao pode ser alterado` |
| 5 | Gestor se inativa | 200 | 400 `Voce nao pode alterar o proprio status` |
| 6 | Administrador altera o próprio perfil | 200 | 400 |
| 7 | Administrador se inativa | 200 | 400 |
| 8 | Gestor edita o próprio telefone | 204 | **204**, continua funcionando |
| 9 | Gestor promove supervisor a central | 204 | **204**, continua funcionando |
| 10 | Administrador promove terceiro a administrador | 204 | **204**, continua funcionando |

O usuário `ALVO TESTE ESCALADA`, criado só para os casos 3, 9 e 10, foi apagado. Estado final conferido: Douglas administrador, Laudenir administrador, Bruno gestor, os três ativos.

**Como o furo foi encontrado:** não foi por advisor nem por leitura de código. Apareceu ao rodar o script `database/testes/02_rls_por_perfil.sql`, cuja verificação 3 acusou `usuarios.usuarios_select` com predicado `true`. Ao conferir se aquilo era mesmo a exceção documentada, olhei o conjunto completo de políticas de `usuarios`, vi que o `UPDATE` dependia de uma trigger, e testei a trigger com um JWT real em vez de acreditar no nome dela.

### Migration 171 - `view_reconciliacao_security_invoker`

**O quê:** `security_invoker = on` em `vw_historico_divergente` e `REVOKE ALL FROM authenticated, anon, PUBLIC`.

**Por quê:** o advisor apontou ERROR de `security_definer_view`. **View no PostgreSQL nasce SECURITY DEFINER por padrão**: ela aplica a RLS de quem a criou, não a de quem consulta. Como a view foi criada com privilégio de `postgres` e `authenticated` tinha grant, qualquer usuário logado enxergava por ela **todas as escoltas do sistema**, contornando exatamente a RLS que as migrations 130 a 136 ligaram. Furo criado por mim ao criar a view de reconciliação nas migrations 162 e 163.

Nenhum código do app consome a view: `grep` em `.ts` e `.tsx` não devolveu nada. Ela é ferramenta de auditoria consultada por SQL direto, então a correção certa é tirá-la da API, não ajustar predicado.

**Verificação:**

| Prova | Antes | Depois |
|---|---|---|
| `reloptions` da view | nulo | `{security_invoker=on}` |
| ACL | inclui `authenticated=arwdDxtm` | só `postgres` e `service_role` |
| `GET /rest/v1/vw_historico_divergente` com JWT de administrador | 200 com dados | **403** `permission denied for view` |
| Mesma chamada sem autenticação | - | **401** |
| `get_advisors` de segurança | 1 ERROR | **0 ERROR**, 11 WARN esperados |

Os 11 WARN restantes são permanentes e conhecidos: 10 funções `SECURITY DEFINER` executáveis por `authenticated`, porque as próprias políticas de RLS chamam os resolvedores de identidade, e 1 de proteção de senha vazada, desligada por decisão, já que a senha provisória é `123456`.

**Lição para o runbook:** toda view nova em `public` precisa de `security_invoker = on` no ato da criação, ou de `REVOKE` se não for para ser consumida pela API. Não basta a RLS estar ligada nas tabelas de origem.

### Migration 170 - `backup_pre_limpeza`

**O quê:** schema `backup_20260819` com cópia integral de 15 tabelas operacionais mais os metadados dos objetos do bucket `fotos`.

**Por quê:** Pecanha pediu a base zerada para começar os testes do fluxo novo de 9 etapas. Exclusão em produção não se faz sem cópia recuperável, conforme a regra do `CLAUDE.md` de `Documents`. Backup em schema, e não em arquivo de texto, porque não passa por serialização e volta com `INSERT INTO ... SELECT`.

**Verificação:** contagem por tabela conferida contra a origem antes de qualquer exclusão. Todas bateram: escoltas 16, escolta_veiculos 18, escolta_efetivo 44, escolta_armamentos 6, pontos_controle 63, fotos 120, checklists 27, checklist_respostas 171, ocorrencias 1, presencas 1, escolta_status_historico 71, storage_objetos 117.

O schema tem `REVOKE ALL ... FROM anon, authenticated, PUBLIC`, então não é alcançável pela API.

### Exclusão dos dados operacionais

**O quê:** `DELETE` em 16 tabelas dentro de uma transação, das folhas para a raiz, e remoção dos 117 objetos do bucket `fotos`.

Apagado: checklist_respostas (171), checklists (27), pontos_controle (63), ocorrencias (1), emergencias (0), presencas (1), rastreamento (0), atualizacoes_status (0), escolta_status_historico (71), notificacoes (0), escolta_armamentos (6), escolta_efetivo (44), escolta_veiculos (18), escoltas (16), fotos (120). Mais 117 arquivos no Storage.

Preservado: usuarios (3), clientes (5), vigilantes (11), veiculos (6), armamentos (10), checklist_modelos (6), checklist_modelo_itens (35), logs_auditoria (10) e as tabelas de domínio.

**Por quê essa fronteira:** sem cliente, viatura e modelo de checklist não é possível criar a primeira escolta, e o pedido era deixar pronto para testar, não para recadastrar. As notificações entraram na exclusão por decisão de Pecanha na confirmação.

**Sobre os arquivos do Storage:** o backup guarda os metadados (id, nome, bucket, data, `metadata`), **não os bytes**. Os 117 arquivos foram removidos definitivamente e não têm cópia. Isso foi declarado a Pecanha antes da execução e a exclusão foi autorizada.

A remoção usou listagem recursiva pela própria API de Storage, não uma lista transcrita, e conferiu o bucket vazio depois. `storage.objects` para o bucket `fotos` ficou em 0.

**Verificação, com JWT real de administrador:**

| Prova | Resultado |
|---|---|
| 15 tabelas operacionais | 0 linhas cada |
| Bucket `fotos` | 0 objetos, no banco e no storage |
| Cadastros base | intactos, todos legíveis com HTTP 200 |
| `vw_historico_divergente` | vazia |
| Listar escoltas, pontos, fotos e checklists com base vazia | HTTP 200, sem erro |
| Criar escolta pela API | HTTP 201 |
| Código gerado | `ESC-2026-0001`, sequência reiniciada corretamente |
| `fluxo_versao` da escolta nova | 2, ou seja, já nasce sob a regra do trânsito de retorno |
| Apagar a escolta de teste | HTTP 200, 1 linha |

A escolta de teste foi removida em seguida, e a base ficou de fato em zero.

**Como restaurar**, se for preciso voltar atrás:

```sql
-- ordem inversa da exclusao: raiz primeiro, folhas depois
insert into public.fotos select * from backup_20260819.fotos;
insert into public.escoltas select * from backup_20260819.escoltas;
insert into public.escolta_veiculos select * from backup_20260819.escolta_veiculos;
insert into public.escolta_efetivo select * from backup_20260819.escolta_efetivo;
insert into public.escolta_armamentos select * from backup_20260819.escolta_armamentos;
insert into public.pontos_controle select * from backup_20260819.pontos_controle;
insert into public.checklists select * from backup_20260819.checklists;
insert into public.checklist_respostas select * from backup_20260819.checklist_respostas;
insert into public.ocorrencias select * from backup_20260819.ocorrencias;
insert into public.presencas select * from backup_20260819.presencas;
insert into public.escolta_status_historico select * from backup_20260819.escolta_status_historico;
```

**Limite da restauração:** ela devolve as linhas, **não as fotos**. Os registros de `fotos` voltariam apontando para caminhos que não existem mais no bucket, e toda galeria mostraria imagem quebrada. Restaurar só faz sentido para recuperar dado operacional (datas, GPS, observações, checklists), não a prova fotográfica.

**Risco assumido:** os 11 vigilantes continuam com `usuario_id` nulo. Nenhum deles tem conta, então **nenhum login de perfil operador enxerga escolta hoje**, porque toda a RLS de campo depende desse vínculo. Para testar o fluxo de campo é preciso criar um operador pela tela de usuários, que cria o vínculo automaticamente.

---

## 2026-08-19 - Fase 0: Guardrails e hotfix de segurança

### Migration 100 - `hotfix_seguranca_security_definer`

**O quê:** guarda `IS NULL OR` em `criar_usuario_completo` e `cadastrar_operador`, mais `REVOKE EXECUTE ... FROM anon, PUBLIC` nas quatro RPCs de cliente e nos quatro resolvedores de identidade.

**Por quê:** as duas funções de criação conferiam permissão com `IF perfil NOT IN ('administrador','gestor')`. Para chamador anônimo, `perfil_usuario_atual()` devolve NULL, e em SQL `NULL NOT IN (...)` é NULL, não `true`, então o `IF` não disparava e a exceção nunca era levantada. Somado ao `EXECUTE` que `anon` possuía, **qualquer pessoa com a chave pública do navegador podia criar uma conta de administrador**. Ligar RLS não resolveria, porque `SECURITY DEFINER` ignora RLS.

**Como foi feito:** o corpo das funções foi preservado. A migration lê `pg_get_functiondef`, substitui só o `IF` e reexecuta a definição, abortando se a guarda esperada não for encontrada. Isso evita transcrever 4145 caracteres à mão.

**Cuidado tomado:** `authenticated` foi **mantido** nos resolvedores `perfil_usuario_atual`, `get_meu_perfil`, `get_meu_usuario_id` e `get_meu_vigilante_id`. Retirar quebraria as 42 políticas de RLS que os chamam.

**Verificação:**

```
POST /rest/v1/rpc/criar_usuario_completo  (chave anon)  -> HTTP 401
  {"code":"42501","message":"permission denied for function criar_usuario_completo"}
POST /rest/v1/rpc/cadastrar_operador      (chave anon)  -> HTTP 401
  {"code":"42501","message":"permission denied for function cadastrar_operador"}
```

Dados conferidos depois do teste: 3 auth.users, 3 usuarios, **0 invasores**, 16 escoltas, 120 fotos, 63 pontos, 11 vigilantes. Nada alterado.

### Migration 101 - `hotfix_escalada_gestor_administrador`

**O quê:** `redefinir_senha_usuario` passa a conferir o perfil do **alvo**, não só o de quem chama.

**Por quê:** a função só validava que o chamador era administrador ou gestor. Um gestor podia redefinir a senha de um administrador e entrar como ele. O sistema tem um gestor (Bruno) e dois administradores.

**Regra nova:** apenas um administrador redefine a senha de outro administrador.

### Migration 102 - `search_path_funcoes`

**O quê:** `SET search_path = public, pg_temp` nas 9 funções que estavam com `proconfig` nulo.

**Por quê:** função com `search_path` mutável pode ser induzida a resolver um nome para um objeto plantado por quem a chama.

### Migration 103 - `revoke_trigger_function_anon`

**O quê:** `REVOKE EXECUTE` de `anon` e `PUBLIC` em `registrar_historico_status_escolta`.

**Por quê:** é `SECURITY DEFINER` e função de trigger. Ninguém precisa chamá-la diretamente. Será removida na Fase 4 junto com a trigger.

### Resultado nos advisors de segurança

| Aviso | Antes | Depois |
|---|---|---|
| `function_search_path_mutable` | 9 | **0** |
| `anon_security_definer_function_executable` | 9 | **0** |
| `authenticated_security_definer_function_executable` | 9 | 9 (esperado: as políticas precisam) |
| `rls_disabled_in_public` | 33 | 33 (Fase 2) |
| `policy_exists_rls_disabled` | 32 | 32 (Fase 2) |
| `auth_leaked_password_protection` | 1 | 1 (Fase 2) |
| **Total** | **93** | **75** |

### Código

| Arquivo | Mudança | Motivo |
|---|---|---|
| `app/dashboard/relatorios/pdf/page.tsx` | Conteúdo movido para `RelatoriosPDFConteudo`, com `export default` envolvendo em `<Suspense>` | `useSearchParams()` sem limite de Suspense fazia `next build` **falhar na pré-renderização**. O build nunca tinha passado: não existia `.next/BUILD_ID` |
| `.eslintrc.json` | Criado (`next/core-web-vitals` + `next/typescript`) | Não existia nenhuma configuração de ESLint, então `npm run lint` não rodava e o gate de verificação era fictício |
| `tsconfig.json` | `exclude` passa a incluir `.claude` e `database/_legado_v1` | A cópia obsoleta em `.claude/worktrees/` estava sendo typecheckada. **`.next` não foi excluído**, porque o `include` depende de `.next/types/**/*.ts` para os tipos de rota do Next 14 e o `exclude` vence o `include` |
| `app/dashboard/page.tsx` | Dois `<a>` para rotas internas viram `<Link>` | Erro de lint `no-html-link-for-pages` |
| `app/dashboard/sistema/telegram/page.tsx` | Aspas escapadas como `&quot;` | Erro de lint `react/no-unescaped-entities` |
| `indicadores`, `mapa`, `relatorios` | `let` para `const` em 3 variáveis nunca reatribuídas | Erro de lint `prefer-const` |
| `components/ui/textarea.tsx` | `interface` vazia vira `type` | Erro de lint `no-empty-object-type` |

**Verificação:** `npx tsc --noEmit` exit 0. `npx next build` **verde**, pela primeira vez no projeto.

Achados confirmados pelo próprio lint, que reforçam o diagnóstico do plano: `CabecalhoLogos` definido e nunca usado, e `paginaAtual`/`totalPaginas` do rodapé declarados e nunca recebidos.

### Pendências da Fase 0

| Item | Situação |
|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | **Bloqueado.** Precisa ser copiada do painel do Supabase. A Fase 5 depende dela |
| Backup lógico com teste de restauração | A fazer antes da Fase 2 |
| Branch do Supabase para validar RLS | A fazer antes da Fase 2 |
| Regerar `types/supabase.ts` | Fase 1 |

---

## 2026-08-19 - Fases 1, 3, 4 (parcial) e 6.1

### Fase 1 - Reconciliar o banco

- Os 7 arquivos SQL v1 e o seed foram para `database/_legado_v1/`, com um README explicando que descrevem um schema que **nunca existiu** neste banco, e alertando que `007` redefine `auth.uid()` recursivamente e quebraria toda a autenticação se executado.
- `types/supabase.ts` regenerado a partir do banco real: **805 -> 1981 linhas**. Passa a conhecer `chat_mensagens`, que era usada pelo código e não existia nos tipos.

### Fase 3 - Máquina de estados única, com a etapa nova

**Migrations 110, 111 e 112.**

- `escoltas.fluxo_versao SMALLINT NOT NULL DEFAULT 2`, com as 16 escoltas existentes marcadas como `1`. Sem isso, as 3 escoltas em `retornando` travariam para sempre, porque não têm nem podem ter o ponto de trânsito de retorno.
- CHECK de status aceita `em_transito_retorno`.
- `dom_tipos_ponto` ganha `transito_retorno` e `retorno`. O segundo resolve a colisão em que `base_retorno` servia a dois eventos diferentes.
- Trigger de transição reescrita com o mapa completo. Corrige o erro relatado e acrescenta as arestas do retorno. Escolta `fluxo_versao = 1` continua podendo pular as etapas de trânsito.
- Trigger nova `tr_exigir_transito_retorno`: `retornando -> na_base` só passa se existir ponto `transito_retorno`. Vale só para `fluxo_versao = 2`.

**Código.** `lib/fluxo-escolta.ts` passa a ser a fonte única: status, rótulos, classes de badge, transições válidas, próximo status, as 9 etapas e o tipo de ponto por status. Antes havia quatro definições divergentes. A tela de detalhe passou a importar daqui.

Etapa nova na interface: estado, handler `handleIniciarTransitoRetorno`, diálogo com GPS e fotos, e os botões "Iniciar Trânsito de Retorno" e "Confirmar Retorno".

**Teste de fluxo executado no banco:**

| Caso | Resultado |
|---|---|
| `na_origem -> em_transito_destino` (o erro relatado) | PASSOU |
| `no_destino -> em_transito_retorno` (etapa nova) | PASSOU |
| Concluir retorno **sem** o ponto de trânsito | BLOQUEADO |
| Concluir retorno **com** o ponto | PASSOU |
| Transição inválida (`finalizada -> em_andamento`) | BLOQUEADO |
| Escolta antiga (v1) conclui sem o ponto novo | Não travou |
| Dados de teste removidos | OK |

Distribuição das 16 escoltas conferida antes e depois: idêntica.

### Fase 4 (parcial) - Fotos obrigatórias

- Guarda bloqueante nos cinco handlers que rotulavam a foto como obrigatória e aceitavam sem: saída da base, chegada na origem, trânsito ao destino, chegada no destino e chegada na base.
- **`handleChegadaBase` corrigido.** A foto era capturada e descartada: `uploadFoto` nunca era chamado e o insert do ponto não tinha `foto_id`. É a causa dos 12 pontos `base_retorno` sem foto.
- `uploadFotosPonto` novo, respeitando o limite de 5 por ponto.
- Os pontos de retorno passam a gravar `observacoes` como JSON com `foto_ids`, no mesmo formato já usado pelas paradas.

### Fase 6.1 - Os quatro defeitos do relatório PDF

Todos no mesmo arquivo, e precisavam sair juntos: consertar um revelava o próximo.

| # | Defeito | Correção |
|---|---|---|
| 1 | `select` pedia `papel`, coluna inexistente | `papel_na_escolta`, e a interface TypeScript junto |
| 2 | `.in('escolta_id', ...)` sobre `checklists`, que não tem essa coluna | Sem viatura, devolve vazio em vez de consultar |
| 3 | Sub-select de veículos não pedia `id`, `veiculo_id` nem a placa | Acrescentados. `escVeicIds` era sempre vazio e a seção Frota mostrava sempre `—` |
| 4 | `checklist_respostas` sem alias, mas o render lê `c.respostas` | Alias `respostas:` |

**Comprovação por HTTP:**

```
ANTES:  GET .../escoltas?select=id,efetivo:escolta_efetivo(papel)
        HTTP 400  {"code":"42703","message":"column escolta_efetivo_1.papel does not exist"}

DEPOIS: GET .../escoltas?select=...papel_na_escolta...veiculo:veiculos(placa,modelo)
        HTTP 200  dados reais, com placa e efetivo preenchidos
```

### Verificação

`npx tsc --noEmit` exit 0. `npx next build` compilado com sucesso, `.next/BUILD_ID` presente.

---

## 2026-08-19 - Fase 5: Cadastro de usuário e conserto das contas

Feito **sem** a `SUPABASE_SERVICE_ROLE_KEY`. Eu havia tratado a chave como bloqueio e estava errado: o acesso privilegiado ao banco permite corrigir a própria função de criação, o que resolve a causa em vez de contorná-la.

### Diagnóstico comprovado por probe HTTP

Login com senha propositalmente errada, antes de qualquer alteração:

| Conta | HTTP | Leitura |
|---|---|---|
| laudenirjunior@gmail.com | **400** | credencial inválida, conta sadia |
| douglasbraido@... | **500** | GoTrue quebra antes de conferir a senha |
| bruno@grupoesquematiza... | **500** | idem |

O 500 confirma o defeito das colunas de texto nulas. Depois do reparo, as três devolvem 400.

### Migration 120 - reparar as contas

Dois defeitos, ambos presentes:

1. `email_change`, `email_change_token_new` e outras colunas de texto estavam **NULL**. O GoTrue as lê em tipo não anulável e devolve 500. Normalizadas para string vazia, como na conta que funciona. `confirmation_token` e `recovery_token` estavam com hash preenchido e foram zerados.
2. **Sem linha em `auth.identities`.** O login por e-mail resolve o usuário por ela. Criada no formato do provider `email`.

Senha definida como `123456` com troca obrigatória.

**Resultado:** Douglas e Bruno fazem login e recebem token. As três contas agora têm `identities = 1` e `last_sign_in_at` preenchido. Douglas e Bruno nunca tinham conseguido entrar.

### Migration 121 - `criar_usuario_por_login`

Função nova com a assinatura do cadastro reduzido: nome, CPF, telefone e perfil.

- Gera o login `primeiro_ultimo`, sem acento, com desambiguação por sufixo numérico.
- E-mail interno `<login>@operador.local`, invisível ao usuário. A tela de login já completa o domínio quando não há `@`.
- Cria `auth.users` **com todas as colunas de texto preenchidas** e a linha em `auth.identities`. É o que faltava na função antiga.
- Valida CPF (11 dígitos e unicidade), nome e perfil.
- Senha `123456` com `troca_senha_obrigatoria = true`.
- Nasce sob a regra de classe da Fase 0: guarda `IS NULL OR`, `REVOKE` de `anon` e `PUBLIC`, `search_path` fixado.

### Teste de ponta a ponta executado

| Passo | Resultado |
|---|---|
| Admin cria usuário com 4 campos | HTTP 200, login `jose_teste` gerado |
| Login com o login gerado e `123456` | **OK**, token emitido, identities 1 |
| Trocar por senha de 6 caracteres | HTTP 200 |
| Login com a senha nova | **OK** |
| CPF com menos de 11 dígitos | recusado |
| CPF duplicado | recusado |
| Sem nome / sem perfil | recusados |
| Anônimo tenta criar | **HTTP 401** |
| Usuário de teste removido | OK |

### Código

| Arquivo | Mudança |
|---|---|
| `utils/validators.ts` | `validarSenha` passa a exigir só o mínimo de 6, sem complexidade, e proíbe reusar a provisória. Constantes `SENHA_MINIMO` e `SENHA_PROVISORIA` |
| `app/auth/trocar-senha/page.tsx` | Usa `validarSenha` em vez do 8 fixo |
| `app/dashboard/usuarios/page.tsx` | Formulário de 4 campos. Campo de e-mail removido. CPF obrigatório com máscara e validação em tempo real pelo `validarCPF`, que existia e nunca era usado. Telefone com máscara. Mostra o login previsto e a senha provisória antes de salvar. Chama `criar_usuario_por_login` |

### Ressalva registrada

A RPC manipula tabelas internas do GoTrue (`auth.users` e `auth.identities`). Funciona e está testada, mas é acoplada à estrutura interna do Supabase. Quando a `SUPABASE_SERVICE_ROLE_KEY` estiver configurada, o caminho suportado é migrar para uma Route Handler com `auth.admin.createUser()`. A função atual fica como está até lá.

### Verificação

`tsc` exit 0, `next build` compilado, 7 rotas testadas com HTTP 200.

---

## 2026-08-19 - Fase 2 (RLS), Fase 6 (impressão) e Fase 7 (honestidade dos indicadores)

### Fase 2 - RLS: substituir as políticas e ligar, em três lotes

O diagnóstico dizia "políticas criadas porém inertes". Estava incompleto: **33 das 78 políticas tinham predicado `true`**, e como políticas permissivas são combinadas por OU, elas anulavam as restritas na mesma tabela. Ligar RLS sem trocá-las teria zerado os advisors sem proteger nada.

**Defeito estrutural encontrado nas políticas antigas.** Elas escopavam por efetivo com `JOIN usuarios u ON u.id = ee.vigilante_id`, mas `escolta_efetivo.vigilante_id` referencia `vigilantes(id)`, não `usuarios(id)`. Essas políticas nunca casavam nada. Se eu tivesse apenas removido as permissivas, o operador ficaria sem ver a própria escolta. Criei `sou_do_efetivo()` e `sou_do_efetivo_veiculo()` com o caminho correto, passando por `vigilantes.usuario_id`.

| Migration | Lote |
|---|---|
| 130 | Helpers de efetivo |
| 131 | `usuarios` (não tinha política nenhuma) + trigger contra autopromoção |
| 132 | `clientes`, `vigilantes`, `fotos` |
| 133 | `escoltas`, `escolta_veiculos`, `escolta_efetivo`, `escolta_armamentos` |
| 134 | Dados de campo: pontos, checklists, ocorrências, emergências, presenças, histórico, rastreamento |
| 135 | Domínio e sistema: `dom_*`, veículos, armamentos, modelos, auditoria, notificações, chat |
| 136 | Revoke das funções de trigger e da RPC obsoleta |

**Cuidado deliberado em duas tabelas.** `usuarios` precisa permitir a leitura da própria linha, porque `useAuth.ts:17-23` resolve o perfil da sessão com select direto e `layout.tsx:107` bloqueia a renderização se voltar vazio. `dom_perfis` precisa continuar legível por autenticado, porque `layout.tsx:126` filtra todo item de menu por ele. Negar qualquer uma das duas trancaria o operador fora do sistema ou deixaria a navegação vazia.

**Verificação com JWT real de cada perfil**, antes e depois:

| Tabela | anon antes | anon depois | operador depois | admin |
|---|---|---|---|---|
| `usuarios` | 4 | **0** | 1 (a própria) | 4 |
| `clientes` | 5 | **0** | 1 (o da escolta dele) | 5 |
| `vigilantes` | 11 | **0** | 3 (o efetivo dele) | 11 |
| `fotos` | 120 | **0** | 1 | 120 |
| `escoltas` | 16 | **0** | 1 | 16 |
| `pontos_controle` | 63 | **0** | 1 | 63 |

**Testes de violação:**

| Tentativa | Resultado |
|---|---|
| Operador se promove a administrador | **HTTP 400**, "Voce nao pode alterar o proprio perfil de acesso" |
| Operador lê o CPF de outro usuário | `[]` |
| Operador grava ponto na própria escolta | **HTTP 201** |
| Operador grava ponto em escolta alheia | **HTTP 403**, viola a política |
| Operador resolve o próprio perfil (useAuth) | funciona |
| Operador lê `dom_perfis` (menu) | funciona |

**Advisors: 93 -> 14, e nenhum ERROR.** Os 13 WARN restantes são `SECURITY DEFINER` executável por autenticado, o que é necessário: as políticas chamam os resolvedores e as RPCs precisam ser chamáveis. O 14º é a proteção contra senha vazada, que conflita com a senha `123456` decidida.

**33 de 33 tabelas com RLS ligada.** 70 políticas, 52 usando a forma `(select fn())` que vira InitPlan e é avaliada uma vez por consulta em vez de por linha.

### Fase 6 - Impressão

`app/print.css` novo, importado pelo `globals.css`, então vale para **todas** as páginas. Antes só existiam dois blocos inline nas duas telas dedicadas, e imprimir qualquer outra saía com sidebar, topbar e bottom nav.

Cobre: `@page` A4 com margem inferior maior para reservar espaço ao rodapé fixo; variante paisagem por classe; `print-color-adjust` em `*` e não só em `body`; `thead` repetido; `break-inside: avoid` em linha, imagem e card; título com `break-after: avoid` para não ficar órfão; `orphans`/`widows`; expansão de link externo; contêiner com rolagem aberto; animação e sombra desligadas; e numeração de página com `counter(page)`.

Corrigido em `relatorios/pdf`: `@page { margin: 0 }`, que jogava o conteúdo na área não imprimível e fazia o rodapé fixo sobrepor o texto; e `page-break-after: always` em toda seção, que gastava uma folha para uma seção de cinco linhas.

Conferido que as regras chegam ao CSS final do build, e não são descartadas pelo `@import`.

### Fase 7 - Honestidade dos indicadores

| Problema | Correção |
|---|---|
| Setas de tendência eram comparação com limiar (`taxaConclusao >= 80 ? 'up' : 'down'`), lidas como variação de período | Removidas. Sem base de comparação, não se desenha seta |
| "Taxa SLA: 100%" quando não havia nenhuma escolta ativa | Passa a exibir traço e a legenda "nenhuma escolta ativa agora" |
| Badge "LIVE" em dado estático, sem realtime nem polling | Vira "PERÍODO" e "AGORA" |
| Gráfico de 12 meses com fator `* 1.2` na altura, fazendo o mês de pico vazar o trilho | Fator removido |

### Verificação

`tsc` exit 0, `next build` compilado, **18 rotas em HTTP 200 com a RLS ligada**. Dados de teste removidos: 3 usuários, 11 vigilantes, 16 escoltas, 63 pontos, 120 fotos, iguais ao início.

---

## 2026-08-19 - Fechamento: cadastro de vigilante, documentação e testes

### Migration 140 - `cadastrar_operador_com_identity`

`cadastrar_operador`, usada ao cadastrar um vigilante em `/dashboard/cadastros`, tinha **o mesmo defeito** da função de usuário: inseria em `auth.users` sem criar `auth.identities` e sem preencher as colunas de texto do GoTrue. Todo vigilante cadastrado pela tela nasceria sem conseguir entrar.

Corrigida preservando o corpo, com o mesmo método da migration 100: lê a definição, insere só o que falta e aborta se os padrões esperados não forem encontrados.

**Teste de ponta a ponta:** cadastrar vigilante devolveu HTTP 200 com `login: vigilante_prova`, e o login com `123456` funcionou, com `identities: 1`. Dados de teste removidos.

### Verificações estruturais, todas passando

| Verificação | Resultado |
|---|---|
| Tabelas sem RLS | nenhuma |
| `SECURITY DEFINER` executável por `anon` | nenhuma |
| Política com predicado `true` em tabela sensível | nenhuma |
| RPC sem a guarda `IS NULL OR` | nenhuma |
| Conta sem `auth.identities` | nenhuma |

### Documentação

Pasta `docs/` criada, para ser recortada ao final:

| Arquivo | Conteúdo |
|---|---|
| `00 - INDICE.md` | Índice |
| `01 - Design System.md` | Paleta Navy, tokens, e o estado real (duas paletas convivendo, ~1840 hexes inline, CSS morto) |
| `02 - Skills e Metodologia.md` | O ciclo de crítica adversarial e as notas de cada rodada, com os erros que ele pegou |
| `03 - Arquitetura Atual.md` | Schema real, funções, triggers, RLS, storage e os débitos conhecidos |
| `04 - Fluxo Operacional.md` | A jornada de 9 etapas e as regras de foto |
| `05 - Decisoes Tecnicas.md` | Cada decisão com a alternativa descartada e o custo assumido |
| `06 - Guia de Impressao.md` | Como as folhas de impressão funcionam |
| `07 - Runbook.md` | Setup, variáveis, cadastro, recuperação de senha e diagnóstico |

### Testes

`database/testes/` com dois arquivos idempotentes: o fluxo das 9 etapas com as tentativas de violação, e as cinco verificações estruturais da RLS. `database/migrations/README.md` documenta as 17 migrations aplicadas e a regra obrigatória para funções `SECURITY DEFINER` novas.

### O que continua pendente

| Item | Motivo |
|---|---|
| Gráficos nos indicadores | Só as correções de honestidade foram feitas |
| Varredura página a página | Duas paletas, ~1840 hexes inline, acessibilidade |
| Autenticação em `/api/telegram` e `/api/ai/melhorar-texto` | Continuam aceitando chamada sem sessão |
| `middleware.ts` | Continua com `matcher: []` |
| Bucket `fotos` público | Fechar quebraria o `sendPhoto` do Telegram |
| Histórico gravado em dobro | Não corrigido |
| Fila offline | Não existe |

---

## 2026-08-19 - Correção das regressões apontadas na revisão

Uma revisão adversarial da implementação deu **nota 5** e apontou regressões que eu havia introduzido. As bloqueantes foram corrigidas.

### R1 - A tela de Campo travaria toda escolta nova, e falsificava histórico

`campo/page.tsx` mantinha o próprio mapa de status, com `no_destino -> retornando`. A trigger nova só aceita essa aresta para `fluxo_versao = 1`, e o default é 2. **Toda escolta criada a partir de agora travaria em `no_destino` justamente na tela para onde o operador é redirecionado.**

Pior: `:431` fazia `await sb.from('escoltas').update(...)` **sem ler o erro**. A trigger recusava, o código seguia e inseria a linha de histórico afirmando uma transição que não aconteceu. O operador via sucesso, a escolta não andava e o histórico ficava falso.

Corrigido: mapa derivado de `lib/fluxo-escolta.ts`, tipos de ponto `transito_retorno` e `retorno` acrescentados, jornada com 8 passos, e o update passa a ler o erro e a usar precondição de status antes de gravar qualquer coisa.

O upload de foto em `:340` também engolia a falha e deixava o status avançar sem foto. Agora lança.

### R2 - O cadastro novo criava operadores que a RLS trancava

`criar_usuario_por_login` não criava linha em `vigilantes`. Toda a RLS de campo depende de `sou_do_efetivo()`, que caminha `escolta_efetivo -> vigilantes.usuario_id -> usuarios.auth_user_id`. Operador sem vigilante não enxergava escolta nenhuma: tela de Campo permanentemente vazia.

Migration 152: a função passa a criar o vigilante vinculado quando o perfil é operador. Testado, devolve `vigilante_id: CRIADO`.

Registro do que **não** foi resolvido: os 11 vigilantes existentes têm `usuario_id` nulo. Não é backfill possível, porque são pessoas sem conta no sistema (há 3 usuários, todos de gestão). Quando algum deles precisar de acesso, o cadastro tem de ser feito pelo fluxo que cria o vínculo.

### S1 - A escalada gestor para administrador continuava aberta, e por uma porta que eu mesmo abri

A migration 121 aceitava **qualquer** `p_perfil_id`. Como a senha inicial é a constante `123456`, um gestor criava uma conta de administrador e entrava nela. A trigger `impedir_autopromocao` era só de UPDATE, não cobria INSERT.

Migration 151: trigger `BEFORE INSERT` em `usuarios` impedindo criação de perfil administrador por quem não é administrador.

```
GESTOR tenta criar ADMINISTRADOR -> HTTP 400, "Apenas um administrador pode criar outra conta de administrador"
GESTOR cria OPERADOR             -> HTTP 200
```

### S2 - Qualquer usuário logado apagava qualquer foto

As políticas do bucket eram `USING (bucket_id = 'fotos')` para `authenticated`, em DELETE e UPDATE. Em cadeia de custódia isso invalida o acervo: qualquer operador apagava prova de escolta alheia.

Migration 150: apagar e sobrescrever passam a exigir perfil de gestão.

**O bucket continua público para leitura.** Fechar quebraria o `sendPhoto` do Telegram, que busca a URL anonimamente. Continua pendente.

### R3, R4 - Nome do autor sumia da interface para central e operador

A política restrita de `usuarios` fazia todos os embeds `autor:usuarios!fk(nome_completo)` voltarem null, na timeline, nos relatórios e nas notificações, e deixava a lista de contatos do chat vazia. Para o perfil central, que monitora todas as escoltas, é perda direta de função.

Migration 153: leitura ampla entre autenticados. **Trade-off assumido e comentado na própria política:** expõe CPF e telefone entre funcionários. É sistema interno, todos são da mesma empresa, e o estado anterior era qualquer anônimo lendo tudo. A escrita continua restrita e a autopromoção continua bloqueada.

### R5, R6 - Telas fingiam ter salvo

Com RLS ligada, UPDATE ou DELETE negado devolve 204 com zero linhas e **sem erro**. O diálogo fechava, a lista recarregava igual, e o usuário achava que tinha salvo. Corrigido em `cadastros/page.tsx` (cliente) e `usuarios/page.tsx` (bloquear/desbloquear) com `.select('id')` e checagem de linhas afetadas.

### R7 - A etapa nova era invisível para contagem, filtro e mapa

Sobravam **15 arrays de status literais** sem `em_transito_retorno`, em 9 arquivos. A escolta sumia do mapa ao vivo e da lista durante a etapa nova, e o check-in periódico ficava escondido justamente na perna de estrada. Todos corrigidos, nenhum restante.

### Ainda pendente da revisão

| Item | Motivo |
|---|---|
| Bucket público para leitura | Fechar quebra o Telegram; exige `multipart` e URL assinada |
| `handleParada` sem exigir foto e com GPS 0,0 | Não corrigido |
| `fotos_select` sem cobrir checklist, presença e ocorrência | Não corrigido |
| Histórico gravado em dobro | Não corrigido |
| Rotas de API e `middleware.ts` | Não corrigidos |
| `utils/constants.ts` com definição antiga de status | Não removida |

### Verificação

`tsc` exit 0, `next build` compilado, rotas em 200. Dados iguais ao início: 3 usuários, 11 vigilantes, 16 escoltas, 120 fotos, 63 pontos, 44 efetivo.

---

## 2026-08-19 - Fechamento dos pendentes

### Rotas de API: de abertas para autenticadas

`lib/api-auth.ts` novo, com guarda de sessão, limite por usuário e escape de HTML.

| Chamada | Antes | Depois |
|---|---|---|
| `POST /api/ai/melhorar-texto` | **200** | **401** |
| `POST /api/telegram` | **200** | **401** |
| `GET /api/telegram?action=me` | **200** | **401** |
| `GET /api/telegram?action=updates` | **200** | **401** |

Além da sessão:

- **`chat_id` deixa de vir do cliente.** Era possível usar o bot para mandar mensagem a qualquer destino. Agora é resolvido no servidor a partir da escolta; um `chat_id` explícito só é aceito de administrador ou gestor.
- `GET` restrito a administrador e gestor. O `?action=updates` despejava as conversas recentes do bot.
- **HTML escapado** em 7 pontos de interpolação. Dado do usuário ia direto para `parse_mode: HTML`: um `<` quebrava a mensagem e uma tag `<a href>` virava link de phishing no canal de operações.
- Limite de 20 requisições por minuto na IA e 30 no Telegram, por usuário.
- O corpo de erro da OpenAI deixa de ser repassado ao cliente: vazava organização, projeto e detalhe de cota.

### `middleware.ts`: de inerte para ativo

Tinha `matcher: []` e nunca rodava. O comentário justificava com `@supabase/ssr@0.0.10`, mas o projeto está em `^0.12.0`, que persiste sessão em cookie. A justificativa estava obsoleta havia meses.

Agora renova a sessão a cada navegação e barra quem não está autenticado antes de a página existir:

```
/dashboard            307 -> /auth/login?de=%2Fdashboard
/dashboard/campo      307
/dashboard/usuarios   307
/auth/login           200
```

Usa `getUser()`, que revalida o token no servidor, e não `getSession()`, que apenas lê o cookie e aceitaria um token forjado.

### `handleParada`

Passa a exigir foto, como todo ponto do fluxo, e a **bloquear quando não há GPS**. Antes gravava `latitude 0, longitude 0` quando o sinal falhava, o que põe o ponto no golfo da Guiné. Ponto de controle sem coordenada real não serve como prova.

### `fotos_select` completa

A política só reconhecia a foto por `criado_por` ou por `pontos_controle.foto_id`. Ficavam de fora checklist, presença e ocorrência: um operador não via a foto de checklist registrada pelo colega da mesma escolta. Agora cobre os quatro caminhos.

### Histórico em dobro, resolvido

| Métrica | Antes | Depois |
|---|---|---|
| Total de linhas | 111 | **71** |
| `agendada -> em_pre_inicio` | 19 linhas / 13 escoltas | **13 / 13** |
| `em_andamento -> na_origem` | 17 / 11 | **11 / 11** |
| `retornando -> na_base` | 11 / 6 | **6 / 6** |

Uma linha por escolta por transição, como deve ser. A consolidação preservou a linha com `status_anterior` correto e trouxe autor, observação e GPS da outra.

A trigger `tr_registrar_historico_status` foi removida: o app continua gravando, e só ele tem observação, autor e GPS. **Contrapartida:** escrita feita fora do app não deixa rastro. O controle é a view `vw_historico_divergente`, que aponta escolta cujo status não bate com a última linha do histórico. Hoje retorna vazia.

Um detalhe do processo: a primeira tentativa de deduplicação não funcionou. Meu `UPDATE` preencheu `alterado_por` e, com isso, o `DELETE` seguinte não encontrou mais os pares, porque o critério era justamente `alterado_por IS NULL`. Refeito na ordem certa.

### `utils/constants.ts`

Removidas `STATUS_ESCOLTA`, `TIPOS_PONTO`, `LABELS_STATUS`, `LABELS_PONTO` e `TRANSICOES_VALIDAS_STATUS`. Eram a quinta definição divergente de status, sem a etapa nova. Nenhum arquivo importava desse módulo.

### Verificação final

| Item | Resultado |
|---|---|
| Tabelas sem RLS | nenhuma |
| `SECURITY DEFINER` executável por `anon` | nenhuma |
| Quem apaga foto no storage | só gestão |
| Contas sem `auth.identities` | nenhuma |
| Escoltas com histórico divergente | nenhuma |
| Fluxo das 9 etapas | passa |
| Conclusão sem ponto de trânsito | bloqueada |
| `tsc`, `build` | limpos |
| APIs sem sessão | 401 |
| Dashboard sem sessão | 307 |

### O que continua pendente

| Item | Motivo |
|---|---|
| Bucket `fotos` público para leitura | Fechar exige trocar `getPublicUrl` por URL assinada em 9 pontos e enviar bytes ao Telegram em `multipart` |
| Gráficos nos indicadores | Só as correções de honestidade foram feitas |
| Varredura página a página | Duas paletas, ~1840 hexes inline, acessibilidade |
| `viaturas[0]` em 19 pontos | 2 escoltas têm 2 viaturas; a segunda não recebe ponto |
| Fila offline | Não existe |
| 4 rotas órfãs | 1364 linhas não removidas |

---

## 2026-08-19 - Commit e verificação final

Commit `5a6c198` na branch `fase0-seguranca`: 49 arquivos, 4058 inserções.

O arquivo `types/supabase.ts.antigo`, backup meu da geração de tipos, foi retirado do commit e apagado. Nenhum arquivo `.env` entrou.

### Correção da view de reconciliação

`vw_historico_divergente` acusava 3 escoltas como divergentes. Era falso positivo meu: são escoltas em `agendada` que nunca mudaram de status, e por isso nunca geraram histórico. A view passou a exigir que a escolta tenha saído do estado inicial. Agora retorna vazia.

### Verificação final

| Verificação | Resultado |
|---|---|
| Tabelas sem RLS | nenhuma |
| `SECURITY DEFINER` executável por `anon` | nenhuma |
| Política com `true` em tabela sensível | nenhuma |
| Conta sem `auth.identities` | nenhuma |
| Histórico divergente | nenhum |
| Histórico total | 71 linhas (eram 111, com 40 duplicatas) |
| Dados | 16 escoltas, 120 fotos, 63 pontos, 3 usuários |
| `tsc --noEmit` | exit 0 |
| `next build` | compilado |
| Rotas do dashboard sem sessão | 307 |
| Rotas públicas | 200 |
| APIs sem sessão | 401 |
| Árvore de trabalho | limpa |

### Push

**Não realizado.** O comando foi bloqueado pelo classificador de permissões do ambiente. O commit está local, íntegro e verificado. O push precisa ser executado por Pecanha:

```bash
cd "C:/Users/Laudenir/Documents/00 - Projetos Vibe/escolta-armada/escolta-armada"
git push -u origin fase0-seguranca
```
