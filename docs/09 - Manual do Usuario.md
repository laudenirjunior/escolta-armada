# Manual do Usuário

Sistema de Controle Operacional de Escolta Armada, Esquematiza. Versão exibida em Configurações: `1.0.0-beta`. Base do conteúdo: código em `app/`, `components/`, `lib/permissions.ts` e `lib/fluxo-escolta.ts`, no commit `f7056e4`.

Este manual é escrito por perfil, não por menu. Ele cobre a fundo os dois perfis que operam o sistema no dia a dia: o **Supervisor**, que planeja e acompanha, e o **Operador**, que registra a escolta em campo. Os demais perfis (Administrador, Gestor e Central) aparecem quando dividem uma tela com esses dois.

Os marcadores `[PRINT Pxx]` indicam onde entra cada captura de tela. A lista das capturas, com o local exato e as instruções de captura, está no documento `10 - Plano de Captura de Prints.md`.

---

## Antes de tudo: três verdades do sistema

1. **O aplicativo exige conexão.** Não existe modo offline nem fila de sincronização. Sem sinal, o Operador não registra. Isso muda o comportamento em campo e precisa estar claro desde o primeiro dia.
2. **O sistema não substitui o rádio.** A comunicação em tempo real continua pelo canal de sempre. O aplicativo é o registro formal, com foto, GPS e horário.
3. **A posição não é contínua.** O GPS é gravado nos pontos de controle, nos check-ins e nas paradas, não em rastreamento automático permanente.

---

## 1. Acesso

### 1.1 Entrar no sistema

A tela de entrada tem o título **Painel de Acesso Operacional**, um campo com o texto de apoio **"Usuário ou e-mail de acesso"** e outro **"Sua senha de acesso"**.

- O **Operador** entra pelo **usuário**, no formato `primeironome_ultimonome`. Não precisa digitar arroba: o sistema completa sozinho o domínio interno.
- Administrador, Gestor, Supervisor e Central entram pelo e-mail cadastrado.

`[PRINT P01]`

### 1.2 Primeiro acesso: troca de senha obrigatória

Todo acesso novo nasce com a senha provisória **123456** e a marca de troca obrigatória. No primeiro login, o sistema abre sozinho a tela **Troca de Senha Obrigatória**, que saúda a pessoa pelo primeiro nome e pede a **Nova Senha** com **mínimo de 6 caracteres**, mais a confirmação. Só depois de definir a nova senha a pessoa chega ao sistema.

`[PRINT P02]`

### 1.3 Instalar no celular

O sistema é uma aplicação web instalável, sem loja de aplicativos.

- **Android:** abrir no Chrome e aceitar o convite de instalação, ou usar o menu do navegador para adicionar à tela de início.
- **iPhone:** abrir **no Safari**, tocar em Compartilhar e escolher adicionar à tela de início. No iPhone só funciona pelo Safari.

O resultado é um ícone na tela de início, que abre o sistema em tela cheia, como um aplicativo comum.

`[PRINT P03]`

---

## 2. Como se orientar na tela

O menu lateral (no computador) organiza tudo em quatro seções. O que cada perfil enxerga muda conforme a permissão.

| Seção | Itens | Quem vê |
|---|---|---|
| **Operações** | Painel, Escoltas, Campo, Mapa, Notificações | Todos (Campo só o Operador) |
| **Gestão** | Cadastros, Armamentos, Checklists | Administrador, Gestor, Supervisor, Central |
| **Análise** | Indicadores, Relatórios | Administrador, Gestor, Supervisor, Central |
| **Sistema** | Usuários, Telegram, Configurações, Auditoria | Ver observação abaixo |

Na seção Sistema: **Usuários** aparece para Administrador, Gestor e Supervisor; **Telegram** para Administrador e Gestor; **Configurações** e **Auditoria** só para Administrador.

`[PRINT P04]`

**No celular**, o Operador navega por uma barra fixa na base da tela com cinco atalhos: **Painel, Escoltas, Campo, Avisos, Mapa**. É por ela que ele vive a operação.

`[PRINT P05]`

O **Operador** é um caso à parte: ao entrar, ele é levado direto para a tela **Campo**. Ele não acessa Cadastros, Armamentos, Checklists, Indicadores, Relatórios nem Usuários.

---

## 3. Perfis e o que cada um pode

A regra real vive em `lib/permissions.ts`. Abaixo, o essencial para os dois perfis deste manual, com os demais para contexto.

| Ação | Admin | Gestor | Supervisor | Central | Operador |
|---|:-:|:-:|:-:|:-:|:-:|
| Criar escolta | sim | sim | sim | sim | não |
| Editar escolta não iniciada | sim | sim | sim | sim | não |
| Cancelar ou reagendar | sim | sim | sim | não | não |
| Avançar etapa (registrar ponto) | sim | sim | sim | sim | sim |
| Editar cadastros | sim | sim | sim | sim | não |
| Acessar Usuários | sim | sim | sim, só operadores | não | não |
| Ver financeiro | sim | sim | sim | sim | não |
| Ver relatórios e indicadores | sim | sim | sim | sim | não |
| Configurar Telegram | sim | sim | não | não | não |
| Auditoria e Configurações | sim | não | não | não | não |

Dois pontos que valem destaque:

- **O Supervisor entra em Usuários com escopo restrito:** ele cria e edita apenas o perfil Operador. Não mexe em Gestor, Administrador ou Central.
- **O Operador pode assumir uma escolta agendada e escolher quem vai junto, mas não altera o que foi contratado.** A regra está na tela e também no banco.

---

# Parte A: Supervisor

O Supervisor faz três coisas: mantém os cadastros em dia, cria a escolta e acompanha a operação até o fechamento.

## A1. Cadastros

Tudo em um só lugar: **Cadastros** (menu Gestão). A tela tem três abas com contador ao lado do nome, uma busca e um botão de novo item que muda de nome conforme a aba. O Supervisor cria e edita; o perfil Central apenas consulta.

### A1.1 Viaturas (aba Veículos)

Na aba **Veículos**, o botão **Novo Veículo** abre o cadastro da viatura, com os campos:

- **Placa** (obrigatória, vira maiúscula sozinha)
- **Tipo** (Blindado Leve, Médio ou Pesado, Comum Aberto, Motocicleta)
- **Modelo**
- **Status** (Ativo, Inativo ou Em Manutenção)
- **Observações**

A viatura em manutenção recebe um aviso amarelo na lista. É desta frota que a escolta puxa as viaturas na hora de escalar.

`[PRINT P06]`

### A1.2 Armamento

O controle de armas fica em tela própria: **Armamentos** (menu Gestão). O botão **Novo Armamento** cadastra cada arma com:

- **Tipo de Armamento**
- **Calibre** (9mm, .40, .45, .223, entre outros)
- **Numeração (Série)**
- **Documentação (GU)**, o número da guia de utilização
- **Status** (Ativo ou Inativo)

É o inventário que depois se vincula a cada escolta.

`[PRINT P07]`

### A1.3 Cliente e vigilante, e a geração do acesso do Operador

Na aba **Clientes**, o botão **Novo Cliente** pede nome (obrigatório), CNPJ, telefone, contato, uma **cor de destaque** que identifica o cliente na lista e na timeline, status e observações.

Na aba **Vigilantes** acontece o ponto mais importante do cadastro: **ao cadastrar o vigilante, o sistema provisiona o acesso dele ao aplicativo, na hora.** Os campos são nome (obrigatório), CPF (obrigatório), telefone, **Função**, CNV, extensão EEA e valor padrão.

Assim que o nome é digitado, aparece um aviso azul: **"Login gerado: primeironome_ultimonome, senha inicial 123456"**. O botão de salvar se chama **Cadastrar e Provisionar**.

`[PRINT P08]`

Ao salvar, abre um aviso verde **"Operador provisionado!"** com dois blocos, **Login (usuário)** e **Senha inicial**, e um botão **Copiar**. **A senha só aparece aqui, uma vez.** O Supervisor copia e repassa ao Operador, que trocará a senha no primeiro acesso.

`[PRINT P09]`

Regra de ouro do cadastro de vigilante: **todo vigilante cadastrado aqui nasce como Operador, com acesso ao aplicativo.** Não existe cadastrar sem provisionar.

### A1.4 Sobre "cadastro de ferramenta"

O sistema não tem um cadastro geral de ferramentas ou equipamentos. O material se divide em dois lugares:

- **Armas:** na tela Armamentos, descrita em A1.2.
- **Equipamento de conferência (colete, rádio, lanterna):** não é cadastrado como item de estoque. Ele é **conferido no pré-início**, pelo checklist de partida (ver B3). Os modelos de checklist ficam em **Checklists**, aba **Modelos de Checklist**, onde cada modelo tem um nome e um tipo, **Material** ou **Viatura**.

`[PRINT P10]`

Ou seja: quem procura "cadastrar uma ferramenta" deve pensar em duas perguntas. É arma? Vai em Armamentos. É item que a equipe confere antes de sair? É item de checklist de Material, verificado no pré-início.

## A2. Criar a escolta

Botão **Nova Escolta**, dentro de Escoltas. O assistente tem **três fases** no topo (FASE 01, 02 e 03).

### Fase 01: Dados da Escolta

Bloco **Identificação da Missão**. Aqui entram **Cliente Contratante**, **Data** e **Hora de Partida**, **Endereço de Origem** e **Endereço de Destino** (escolhidos de uma lista de sugestões, não digitados livres), os complementos de cada endereço, observações e a **periodicidade de check-in em rota**. Um bloco de **Dados Financeiros** (valor cobrado, outros custos, observação) aparece só para Supervisor e acima.

`[PRINT P11]`

### Fase 02: Efetivo e Veículos

Para cada viatura, escolhe-se o **Veículo Operacional** e o **efetivo** (com o papel de comandante ou operador). Dá para adicionar mais de uma viatura. **O vigilante é opcional:** se ficar sem ninguém escalado, a escolta vai para o mural, de onde um Operador a puxa (ver B2).

`[PRINT P12]`

### Fase 03: Revisar e Confirmar

Tela de conferência com todos os dados antes de gravar. Se a escolta não tiver equipe, um aviso diz que ela vai para o mural. O botão **Confirmar e Criar Escolta** fecha o cadastro.

`[PRINT P13]`

## A3. Acompanhar a escolta

A tela de detalhe da escolta é o centro de tudo. Abre em `/dashboard/escoltas/<id>`.

### A3.1 O cabeçalho e a Jornada

No topo: o código da escolta, o status atual, o cliente, e os botões **PDF** e **Cancelar**. Logo abaixo, a **Jornada**: a faixa das **9 etapas**, com a etapa concluída em verde, a atual destacada e pulsando com o rótulo "ATUAL", e as futuras apagadas. Em uma olhada, sabe-se onde a escolta está.

`[PRINT P14]`

### A3.2 O Painel de Ações

O bloco **Painel de Ações do Operador** mostra **apenas as ações válidas para o status atual**, e só elas. Em trânsito, por exemplo, ele oferece Check-in, Registrar Parada e o botão de avançar para a próxima etapa. Cada avanço abre um diálogo com foto e GPS obrigatórios. Não existe atalho que mude o status sem prova.

`[PRINT P15]`

### A3.3 As abas

A escolta tem seis visões, em abas com contador: **Visão Geral, Timeline, Efetivo, Veículos, Ocorrências** e **Financeiro**. A aba Financeiro só aparece para quem tem permissão financeira.

`[PRINT P16]`

### A3.4 A Timeline e a prova

A aba **Timeline** é o registro cronológico completo. Cada evento com foto abre um detalhe com horário e coordenada. A foto carrega **data, hora e local carimbados na própria imagem**, o que sustenta a cadeia de custódia: a prova viaja dentro do arquivo.

`[PRINT P17]` `[PRINT P18]`

### A3.5 Fechamento

Quando a viatura volta e a escolta chega ao status **Na Base**, o Painel de Ações libera **Finalizar Escolta**. O diálogo **Finalizar Escolta e Relatório Diário** reúne três coisas: as **5 fotos de entrega da viatura**, um **checklist de entrega** (item reprovado exige descrição) e o **Relatório Diário da Operação**, que já vem preenchido com os dados reais da escolta e é editável.

`[PRINT P19]`

O botão **PDF** monta o documento de fechamento que vai ao cliente, abrindo a caixa de impressão do navegador.

`[PRINT P20]`

### A3.6 Cancelar ou reagendar

O botão **Cancelar** exige um motivo, que fica registrado. O cancelamento é possível a partir de qualquer etapa não terminal.

`[PRINT P21]`

## A4. Acompanhamento em tempo real

Além da tela de detalhe, o Supervisor tem duas telas de monitoramento.

- **Mapa** (`/dashboard/mapa`): mostra as viaturas posicionadas nos últimos pontos, e permite saltar do mapa para a escolta.

  `[PRINT P22]`

- **Notificações** (`/dashboard/notificacoes`): o feed único de tudo que acontece, com uma conversa por escolta (não por pessoa) no painel lateral.

  `[PRINT P23]`

O sistema também dispara um **alerta de check-in atrasado** quando uma escolta passa da periodicidade sem reportar. O atraso não passa despercebido.

`[PRINT P24]`

---

# Parte B: Operador

O Operador é o registrador da escolta. Ele trabalha no celular, em movimento. Este é o capítulo mais importante do manual, porque é o único usuário que não está sentado.

## B1. A tela de Campo

Ao entrar, o Operador cai direto em **Campo** (`/dashboard/campo`). A tela mostra, de cima para baixo: o cartão da escolta ativa (código, cliente, origem, destino, previsto, viatura), o bloco **Progresso da Operação** com a linha das etapas, e o **Painel de Ações** com o que fazer agora.

`[PRINT P25]`

Quando não há escolta ativa, a tela diz "Nenhuma escolta ativa". É o sinal de ir ao mural.

## B2. Puxar e assumir escolta no mural

Em **Escoltas**, o Operador tem um alternador de três modos: **Minhas Escoltas**, **Disponíveis** e **Todas as Ativas**. A aba **Disponíveis** é o mural: escoltas agendadas esperando equipe.

- Escolta **sem equipe:** botão **Puxar**. O Operador vira o comandante e escolhe quem vai junto.
- Escolta **já escalada:** badge "já escalada" e botão **Assumir**.

`[PRINT P26]`

Assumir uma escolta que já tem equipe **exige confirmação e um motivo escrito** (mínimo de cinco caracteres), porque a equipe anterior será substituída e isso fica no histórico. Enquanto a escolta não começa, dá para **Devolver** ao mural.

`[PRINT P27]`

## B3. Pré-início: a preparação de partida

O pré-início **não acontece pela tela de Campo**. Ele é um assistente de três passos na tela de detalhe da escolta, chamado **Preparação Operacional de Partida**. Na tela de Campo, enquanto isso, aparece só o aviso "Aguardando liberação da base".

- **Passo 1, Equipamentos:** três conferências marcadas (coletes balísticos nível III-A, rádios comunicadores operacionais, lanternas táticas carregadas), mais uma foto dos materiais e uma justificativa.

  `[PRINT P28]`

- **Passo 2, Viatura:** as **cinco fotos obrigatórias da viatura**, em cinco ângulos com significado individual: **Frontal, Traseira, Lateral Esquerda, Lateral Direita e Painel/Interior**. Em seguida, um checklist de condições (pneus, óleo, faróis, armas no cofre, combustível, cintos, documentação, limpeza). A viatura só é liberada quando o passo é concluído inteiro.

  `[PRINT P29]`

- **Passo 3, Saída:** a **quilometragem inicial**, a **foto do hodômetro** e as observações de saída. O botão **Confirmar e Iniciar Escolta** coloca a operação em campo.

  `[PRINT P30]`

## B4. Registrar checkpoint: o gesto que mais se repete

Do momento em que a escolta sai da base, avançar cada etapa é registrar um checkpoint. Na tela de Campo, o bloco **Registrar Checkpoint** pede, nesta ordem:

1. **A viatura do registro** (quando há mais de uma e o perfil é administrativo). Cada viatura tem o próprio ponto. **A etapa só avança quando todas as viaturas registram.**
2. **Foto (mínimo 1, até 5).** A câmera abre direto. O **GPS é capturado sozinho** no momento da foto e carimbado na imagem.
3. **Observação**, já sugerida conforme a etapa.
4. O **botão de avanço**, com o nome da próxima etapa.

Sobre o GPS no checkpoint: **a falta de sinal não trava o registro.** A foto é gravada com o aviso de que não houve coordenada, para o Operador não ficar preso sem rede. A foto, essa sim, é obrigatória.

`[PRINT P31]`

Os rótulos dos botões de avanço, etapa por etapa: Confirmar na Origem, Trânsito ao Destino, Chegada no Destino, Iniciar Trânsito de Retorno, Confirmar Retorno, Chegada na Base.

## B5. Checklist de saída e de retorno

Em dois momentos aparece um checklist: o **Pré-Saída** (na preparação) e o **Pós-Retorno** (ao voltar à base). Cada item tem dois botões: **conforme** (verde) e **não conforme** (vermelho).

**Item marcado como não conforme abre um campo de justificativa obrigatório e, quando o item exige, uma foto obrigatória.** Não dá para concluir o checklist com um item reprovado sem explicação. O botão final é **Concluir Checklist**.

`[PRINT P32]`

## B6. Check-in periódico e registrar parada

Durante o trajeto, o Operador mantém o pulso da operação. Estas duas ações ficam no **Painel de Ações do Operador**, na tela de detalhe da escolta.

- **Check-in:** a periodicidade é configurável (de 10 a 120 minutos). Quando vence, o botão fica vermelho e avisa "CHECK-IN ATRASADO". O diálogo pede **foto (mínimo 1)** e usa o **GPS**. Aqui, ao contrário do checkpoint, **o botão de confirmar fica bloqueado sem GPS e sem foto**.
- **Registrar Parada:** para qualquer parada não prevista (abastecimento, refeição, blitz, manutenção, entre outras). Pede o tipo, **foto** e **justificativa**, ambos obrigatórios.

`[PRINT P33]`

## B7. Registrar ocorrência

Para relatar incidente, irregularidade ou desvio, o bloco **Registrar Ocorrência** (na tela de Campo, durante o trânsito) pede o **tipo**, uma **descrição** obrigatória e uma **foto recomendada**. A foto aqui não é obrigatória, mas registra data, hora e GPS quando existe.

`[PRINT P34]`

## B8. Acionar emergência

O botão **Acionar Emergência** fica fixo na base da tela de Campo, largo e vermelho. Ele **pede confirmação em dois toques** para evitar disparo acidental: ao tocar, abre "Confirmar Emergência?" com o aviso "A central será notificada imediatamente. Use apenas em situação real", e só o botão **CONFIRMAR** dispara.

A emergência **nunca é bloqueada por falta de GPS**: é um toque, e a central é acionada de imediato, com a posição se houver ou com o aviso de informar por rádio se não houver.

`[PRINT P35]`

---

# Anexos

## Anexo 1: As 9 etapas e seus pontos de controle

| # | Etapa | Status interno | Ponto gerado |
|---|---|---|---|
| 1 | Planejamento | rascunho, agendada | nenhum |
| 2 | Pré-Início | em_pre_inicio | nenhum |
| 3 | Em Trânsito | em_andamento | Base Saída |
| 4 | Na Origem | na_origem | Origem |
| 5 | Trânsito p/ Destino | em_transito_destino | Trânsito Destino |
| 6 | No Destino | no_destino | Destino |
| 7 | Trânsito p/ Retorno | em_transito_retorno | Trânsito Retorno |
| 8 | Retorno | retornando | Retorno |
| 9 | Concluída | na_base, finalizada | Base Retorno |

Regras firmes:

- Cada ponto de controle aceita **até 5 fotos e exige no mínimo 1**.
- O pré-início tem regra própria: **5 fotos da viatura**, uma por ângulo.
- Para concluir o retorno é obrigatório ter passado pela etapa de Trânsito para o Retorno. O banco recusa o pulo.
- Toda etapa que gera ponto passa por diálogo com foto e GPS.

## Anexo 2: Os 12 status e seus rótulos

Rascunho, Agendada, Pré-Início, Em Andamento, Na Origem, Trânsito p/ Destino, No Destino, Trânsito p/ Retorno, Retornando, Na Base, Finalizada, Cancelada.

## Anexo 3: O que o sistema não faz

- **Não funciona sem internet.** Sem fila offline, sem sincronização posterior.
- **Não substitui o rádio.**
- **Não rastreia continuamente.** A posição é gravada nos pontos, check-ins e paradas.
- **Não há cadastro de equipamentos/ferramentas.** Arma vai em Armamentos; colete, rádio e lanterna são itens de checklist conferidos no pré-início.
- **Os gráficos dos indicadores ainda não estão implementados.** Os números aparecem em cartões e tabelas.

---

*Manual escrito em 02/09/2026, sobre o commit `f7056e4`. Se uma tela mudar, revisar o trecho correspondente antes de virar apresentação.*
