# Manual do Usuário - Roteiro de Conteúdo e Plano de Prints

Documento de trabalho. Serve para duas coisas: dizer o que o manual precisa explicar, na ordem certa, e dizer exatamente onde cada captura de tela deve ser tirada, o que ela prova e com que nome salvar.

Não é o manual pronto. É o esqueleto mais o roteiro fotográfico. Depois de tirar os prints, este arquivo e a pasta de imagens vão juntos para o Claude Design montar a apresentação.

**Base do levantamento:** código em `app/`, `components/`, `lib/permissions.ts` e `lib/fluxo-escolta.ts`, na versão do commit `f7056e4`, de 20/08/2026. Versão exibida em Configurações: `1.0.0-beta`, build `June 2026`.

---

## 1. O que o sistema é, em uma frase

Plataforma web de controle operacional de escolta armada, instalável no celular, que registra cada etapa da operação com foto carimbada, GPS e horário, e transforma esse registro em timeline, notificação no Telegram e relatório em PDF.

Ponto que o manual precisa deixar claro logo no começo, porque muda o comportamento em campo: **o aplicativo exige conexão. Não existe modo offline nem fila de sincronização.** Sem sinal, o operador não consegue registrar.

---

## 2. Os cinco perfis

O manual deve ser escrito por perfil, não por menu. Quem usa o sistema quer saber o que ele faz, não o que o sistema tem.

| Perfil | Papel | Onde cai ao entrar |
|---|---|---|
| Administrador | Acesso total, auditoria, gestão de usuários, configurações | Painel |
| Gestor | Cadastra escoltas, vê valores e indicadores financeiros | Painel |
| Supervisor | Cadastra e acompanha escoltas, gerencia só operadores | Painel |
| Central | Monitora painel e mapa, recebe alertas, cria escolta | Painel |
| Operador | Atua em campo, lança dados, faz checklist | **Campo** (redirecionado automaticamente) |

### Matriz de permissões, conforme `lib/permissions.ts`

| Ação | Admin | Gestor | Supervisor | Central | Operador |
|---|:-:|:-:|:-:|:-:|:-:|
| Criar escolta | sim | sim | sim | sim | não |
| Editar escolta não iniciada | sim | sim | sim | sim | não |
| Cancelar ou reagendar | sim | sim | sim | não | não |
| Avançar status | sim | sim | sim | sim | sim |
| Finalizar escolta | sim | sim | sim | não | não |
| Editar cadastros | sim | sim | sim | sim | não |
| Acessar Usuários | sim | sim | sim (só operadores) | não | não |
| Ver financeiro | sim | sim | sim | sim | não |
| Ver relatórios e indicadores | sim | sim | sim | sim | não |
| Configurar Telegram | sim | sim | não | não | não |
| Auditoria e Configurações | sim | não | não | não | não |

Detalhe que rende um bloco de destaque no manual: o operador **pode assumir** uma escolta agendada e escolher o companheiro de viatura, mas **não pode alterar o que foi contratado**. A regra está na tela e também no banco, na trigger `impedir_edicao_por_operador`.

---

## 3. O fluxo da escolta, em 9 etapas

Coluna vertebral do manual. Tudo em campo gira em torno disto.

| # | Etapa | Status interno | Ponto de controle gerado |
|---|---|---|---|
| 1 | Planejamento | `rascunho`, `agendada` | nenhum |
| 2 | Pré-Início | `em_pre_inicio` | nenhum |
| 3 | Em Trânsito | `em_andamento` | Base Saída |
| 4 | Na Origem | `na_origem` | Origem |
| 5 | Trânsito para o Destino | `em_transito_destino` | Trânsito Destino |
| 6 | No Destino | `no_destino` | Destino |
| 7 | Trânsito para o Retorno | `em_transito_retorno` | Trânsito Retorno |
| 8 | Retorno | `retornando` | Retorno |
| 9 | Concluída | `na_base`, `finalizada` | Base Retorno |

Cancelamento é possível de qualquer etapa não terminal.

**Regras que o manual precisa afirmar sem rodeio:**

1. Cada ponto de controle aceita **até 5 fotos e exige no mínimo 1**.
2. O pré-início tem regra própria: **5 fotos específicas da viatura** (frente, traseira, duas laterais e painel), porque cada uma tem significado individual.
3. Para concluir o retorno é obrigatório ter passado pela etapa de Trânsito para o Retorno. O banco recusa o pulo.
4. Toda etapa que gera ponto de controle passa por diálogo dedicado, com foto e GPS. Não existe atalho que avance o status sem prova.

---

## 4. Estrutura proposta do manual

Dez capítulos. A numeração dos prints acompanha os capítulos.

| Cap. | Título | Público | Prints |
|---|---|---|---|
| 1 | Acesso e instalação no celular | todos | P01 a P06 |
| 2 | Como se orientar na tela | todos | P07 a P12 |
| 3 | Painel de operações | gestão | P13 a P15 |
| 4 | Ciclo de vida de uma escolta | gestão | P16 a P40 |
| 5 | Operação em campo | operador | P41 a P49 |
| 6 | Monitoramento e comunicação | central | P50 a P53 |
| 7 | Cadastros e material | gestão | P54 a P61 |
| 8 | Indicadores e relatórios | gestão | P62 a P67 |
| 9 | Administração do sistema | administrador | P68 a P74 |
| 10 | Anexos: permissões, status, limites | todos | sem print |

---

## 5. Antes de tirar o primeiro print

### 5.1 Prepare o ambiente

1. Suba a aplicação: `npm run dev` na pasta `escolta-armada`, acesso em `http://localhost:3000`.
2. Crie um cliente fictício de demonstração, por exemplo **Cliente Demonstração Ltda**. Nenhum print deve mostrar cliente real, valor real de contrato, placa real, CPF ou telefone de vigilante.
3. Crie uma escolta de demonstração e **percorra o fluxo inteiro com ela**, do agendamento à finalização, tirando os prints do capítulo 4 e 5 conforme avança. Uma passagem só resolve quase trinta capturas. Refazer o percurso depois custa muito mais.
4. Tenha à mão uma conta de cada perfil. Vários prints só existem no perfil certo: a aba Financeiro não aparece para operador, o menu Auditoria só existe para administrador.

### 5.2 Padrão técnico das capturas

| Item | Padrão |
|---|---|
| Formato | PNG |
| Desktop | Janela do navegador em 1440 x 900, zoom 100 por cento |
| Mobile | DevTools do Chrome, modo dispositivo, iPhone 12 Pro (390 x 844) |
| Navegador | Chrome ou Edge, janela anônima, sem barra de extensões visível |
| Captura no Windows | `Win + Shift + S`, seleção retangular |
| Recorte | Sem barra de endereço, sem barra de tarefas, sem relógio do Windows |
| Dados sensíveis | Borrar ou substituir antes de salvar, nunca depois |

### 5.3 Onde salvar e como nomear

Salvar tudo em:

```
escolta-armada\escolta-armada\docs\prints\
```

Padrão do nome, com separador espaço-hífen-espaço, sem acento no nome do arquivo:

```
P00 - Contexto - Assunto.png
```

Exemplo: `P18 - Nova Escolta - Passo 1 Dados.png`

O código `P00` é o que amarra a imagem ao texto. Mantenha-o mesmo que você decida pular alguma captura.

### 5.4 Prioridade

A coluna **Pri** nas tabelas abaixo tem dois valores:

- **1** = essencial. Sem esta imagem o capítulo não se sustenta. São 45 no total, distribuídos por todos os capítulos.
- **2** = complementar. Enriquece, mas o manual funciona sem.

Se o tempo for curto, faça todos os de prioridade 1 primeiro, na ordem.

---

## 6. Plano de prints

### Capítulo 1 - Acesso e instalação no celular

| Cód. | Arquivo | Perfil / Dispositivo | Onde exatamente | O que a imagem prova | Pri |
|---|---|---|---|---|:-:|
| P01 | `P01 - Login - Tela de Acesso.png` | deslogado / desktop | `/auth/login`, tela limpa, campos vazios | Onde se entra: campo "Usuário ou e-mail de acesso" e campo de senha | 1 |
| P02 | `P02 - Login - Credencial Invalida.png` | deslogado / desktop | `/auth/login`, digite uma senha errada e envie | Como o erro aparece, para o usuário não achar que travou | 2 |
| P03 | `P03 - Primeiro Acesso - Troca de Senha.png` | usuário novo / desktop | `/auth/trocar-senha`, tela que abre sozinha no primeiro login | Que a troca de senha é obrigatória e tem mínimo de caracteres | 1 |
| P04 | `P04 - Instalacao - Banner Android.png` | qualquer / celular Android | Abrir o sistema no Chrome do Android e aguardar o convite de instalação | Como instalar na tela de início pelo Android | 2 |
| P05 | `P05 - Instalacao - Instrucao iPhone.png` | qualquer / iPhone | Abrir no **Safari**, tocar em Compartilhar, ver a instrução exibida pelo sistema | Que no iPhone só funciona pelo Safari, via Compartilhar | 2 |
| P06 | `P06 - Instalacao - Icone na Tela de Inicio.png` | qualquer / celular | Tela de início do celular com o ícone do aplicativo instalado | Resultado final da instalação | 2 |

### Capítulo 2 - Como se orientar na tela

| Cód. | Arquivo | Perfil / Dispositivo | Onde exatamente | O que a imagem prova | Pri |
|---|---|---|---|---|:-:|
| P07 | `P07 - Navegacao - Menu Lateral Completo.png` | administrador / desktop | Qualquer tela, menu lateral expandido, mostrando as quatro seções: Operações, Gestão, Análise e Sistema | O mapa completo do sistema em uma imagem | 1 |
| P08 | `P08 - Navegacao - Menu Recolhido.png` | administrador / desktop | Clicar na seta do topo do menu para recolher, passar o mouse em um ícone até aparecer o rótulo | Que o menu recolhe e ainda assim identifica cada item | 2 |
| P09 | `P09 - Navegacao - Menu do Usuario.png` | qualquer / desktop | Clicar no avatar no canto superior direito, dropdown aberto com "Alterar Senha" e "Sair do Sistema" | Onde se troca senha e onde se sai | 1 |
| P10 | `P10 - Navegacao - Sino com Avisos.png` | central / desktop | Barra superior com o sino marcado em vermelho e o contador de novos eventos | Que o sino acumula eventos em tempo real | 2 |
| P11 | `P11 - Navegacao - Menu Mobile Aberto.png` | operador / mobile | Tocar no botão de três traços no canto superior esquerdo, gaveta aberta | Como navegar pelo celular | 1 |
| P12 | `P12 - Navegacao - Barra Inferior Mobile.png` | operador / mobile | Recorte da barra inferior fixa: Painel, Escoltas, Campo, Avisos, Mapa | Os cinco atalhos de campo, sempre à mão | 1 |

### Capítulo 3 - Painel de operações

| Cód. | Arquivo | Perfil / Dispositivo | Onde exatamente | O que a imagem prova | Pri |
|---|---|---|---|---|:-:|
| P13 | `P13 - Painel - Visao Geral.png` | gestor / desktop | `/dashboard`, tela inteira, com pelo menos uma escolta ativa | A primeira tela de quem gerencia | 1 |
| P14 | `P14 - Painel - Indicadores do Topo.png` | gestor / desktop | Recorte dos quatro cartões escuros: Em Operação, Programadas Hoje, Emergências Abertas, Checklists Pendentes | Os quatro números que importam agora | 1 |
| P15 | `P15 - Painel - Operacoes em Andamento.png` | gestor / desktop | Rolar até o bloco "Operações em andamento" | Como acompanhar o que está rodando neste momento | 2 |

### Capítulo 4 - Ciclo de vida de uma escolta

| Cód. | Arquivo | Perfil / Dispositivo | Onde exatamente | O que a imagem prova | Pri |
|---|---|---|---|---|:-:|
| P16 | `P16 - Escoltas - Lista Geral.png` | supervisor / desktop | `/dashboard/escoltas`, lista com escoltas em status variados | A lista mestra e os cartões de resumo do topo | 1 |
| P17 | `P17 - Escoltas - Filtros e Busca.png` | supervisor / desktop | Mesma tela, recorte da faixa de filtros, com o campo "Buscar por código, endereço ou cliente" preenchido | Como achar uma escolta específica | 2 |
| P18 | `P18 - Nova Escolta - Passo 1 Dados.png` | supervisor / desktop | `/dashboard/escoltas/nova`, passo 1 de 3, blocos Identificação da Missão, Cliente Contratante e Endereço de Origem preenchidos | Onde entram cliente, data, horário e rota | 1 |
| P19 | `P19 - Nova Escolta - Busca de Endereco.png` | supervisor / desktop | Mesmo passo 1, digitando no campo de endereço até a lista de sugestões aparecer | Que o endereço é escolhido de uma lista, não digitado livre | 2 |
| P20 | `P20 - Nova Escolta - Passo 2 Efetivo e Veiculos.png` | supervisor / desktop | Passo 2, com uma viatura e o efetivo já selecionados | Como escalar viatura e vigilantes | 1 |
| P21 | `P21 - Nova Escolta - Passo 3 Revisao.png` | supervisor / desktop | Passo 3, tela de conferência antes de confirmar | Que existe uma revisão final antes de gravar | 1 |
| P22 | `P22 - Escolta - Cabecalho e Jornada.png` | supervisor / desktop | `/dashboard/escoltas/<id>`, topo da tela, com a barra das 9 etapas e a etapa atual destacada | Onde a escolta está no fluxo, em uma olhada | 1 |
| P23 | `P23 - Escolta - Painel de Acoes.png` | supervisor / desktop | Mesma tela, bloco "Painel de Ações", com escolta em andamento | Quais ações o sistema oferece naquele status, e só elas | 1 |
| P24 | `P24 - Escolta - Abas e Resumo.png` | gestor / desktop | Recorte da faixa de abas: Visão Geral, Timeline, Efetivo, Veículos, Ocorrências e Financeiro, com os contadores | Que a escolta tem seis visões diferentes | 1 |
| P25 | `P25 - Escolta - Timeline.png` | supervisor / desktop | Aba Timeline, de preferência com escolta já finalizada, para a linha estar cheia | O registro cronológico completo da operação | 1 |
| P26 | `P26 - Escolta - Detalhe do Evento.png` | supervisor / desktop | Clicar em um item da timeline que tenha foto, modal aberto | Que cada evento guarda foto, horário e coordenada | 1 |
| P27 | `P27 - Escolta - Foto Carimbada.png` | supervisor / desktop | Clicar na foto dentro do modal, visualizador ampliado, carimbo legível | Que a foto carrega data, hora e local gravados na própria imagem | 1 |
| P28 | `P28 - Escolta - Aba Efetivo.png` | supervisor / desktop | Aba Efetivo | Quem está escalado e a confirmação de presença | 2 |
| P29 | `P29 - Escolta - Aba Veiculos.png` | supervisor / desktop | Aba Veículos | Viatura empregada e dados de quilometragem | 2 |
| P30 | `P30 - Escolta - Aba Ocorrencias.png` | supervisor / desktop | Aba Ocorrências, com pelo menos uma ocorrência registrada | Como a ocorrência aparece para a gestão | 2 |
| P31 | `P31 - Escolta - Aba Financeiro.png` | gestor / desktop | Aba Financeiro, visível apenas para quem tem permissão financeira | Que valor de contrato e margem existem e são restritos | 2 |
| P32 | `P32 - Pre-Inicio - Passo 1 Equipamentos.png` | operador / mobile | Escolta em Pré-Início, assistente de partida, passo 1 de 3: coletes, rádios e lanternas | O checklist de material antes de sair da base | 1 |
| P33 | `P33 - Pre-Inicio - Passo 2 Viatura.png` | operador / mobile | Passo 2 de 3, com as cinco fotos da viatura | Que são cinco fotos específicas, uma por ângulo | 1 |
| P34 | `P34 - Pre-Inicio - Passo 3 Saida.png` | operador / mobile | Passo 3 de 3, confirmação da saída da base | O ato que coloca a escolta em operação | 1 |
| P35 | `P35 - Escolta - Check-in Periodico.png` | operador / mobile | Escolta em trânsito, ação de check-in periódico, diálogo aberto com foto e localização | O pulso de vida durante o trajeto | 1 |
| P36 | `P36 - Escolta - Registrar Parada.png` | operador / mobile | Diálogo de parada aberto | Como registrar parada não prevista sem quebrar o fluxo | 2 |
| P37 | `P37 - Escolta - Chegada na Origem.png` | operador / mobile | Diálogo de chegada na origem, com foto capturada e GPS obtido | O modelo de todos os diálogos de etapa: foto obrigatória mais localização | 1 |
| P38 | `P38 - Escolta - Finalizacao.png` | supervisor / desktop | Escolta em "Na Base", diálogo de finalização com o relatório final | O fechamento formal da operação | 1 |
| P39 | `P39 - Escolta - Cancelar ou Reagendar.png` | supervisor / desktop | Diálogo de cancelamento e reagendamento aberto | Que cancelar exige motivo e fica registrado | 2 |
| P40 | `P40 - Escolta - PDF de Fechamento.png` | supervisor / desktop | Botão PDF na tela da escolta, que abre `/dashboard/escoltas/<id>/print`, com a caixa de impressão do navegador visível | O documento que sai para o cliente | 1 |

### Capítulo 5 - Operação em campo

Todo este capítulo é mobile. É o capítulo mais importante do manual, porque é o único usuário que não está sentado.

| Cód. | Arquivo | Perfil / Dispositivo | Onde exatamente | O que a imagem prova | Pri |
|---|---|---|---|---|:-:|
| P41 | `P41 - Campo - Tela Inicial.png` | operador / mobile | `/dashboard/campo`, com escolta ativa, mostrando o bloco "Progresso da Operação" | A tela onde o operador vive | 1 |
| P42 | `P42 - Campo - Registrar Checkpoint.png` | operador / mobile | Bloco "Registrar Checkpoint" aberto, com foto capturada, viatura selecionada e campo de observação | O gesto que mais se repete na operação | 1 |
| P43 | `P43 - Campo - Checklist com Nao Conformidade.png` | operador / mobile | Bloco de checklist, um item marcado como não conforme, com o campo de justificativa aberto e o aviso de foto obrigatória | Que item reprovado exige justificativa e foto | 1 |
| P44 | `P44 - Campo - Registrar Ocorrencia.png` | operador / mobile | Bloco "Registrar Ocorrência", tipo selecionado e foto anexada | Como relatar incidente, irregularidade ou desvio | 1 |
| P45 | `P45 - Campo - Acionar Emergencia.png` | operador / mobile | Botão "Acionar Emergência" pressionado, tela de confirmação visível | O acionamento de emergência e a confirmação que evita disparo acidental | 1 |
| P46 | `P46 - Campo - Escolta Finalizada.png` | operador / mobile | Tela após a conclusão, com a mensagem de operação concluída | O encerramento visto pelo operador | 2 |
| P47 | `P47 - Campo - Mural de Escoltas.png` | operador / mobile | `/dashboard/escoltas`, alternador com as três opções: Minhas Escoltas, Disponíveis e Todas as Ativas, na aba Disponíveis | Que o operador puxa serviço de um mural | 1 |
| P48 | `P48 - Campo - Assumir Escolta Escalada.png` | operador / mobile | No mural, tocar em uma escolta que já tem equipe designada, diálogo aberto com a equipe atual e o campo de motivo | Que assumir escolta de outra equipe exige motivo escrito e fica no histórico | 1 |
| P49 | `P49 - Campo - Alerta de Check-in Atrasado.png` | central / desktop | Aviso que aparece sozinho quando uma escolta passa da periodicidade sem check-in | Que o atraso não passa despercebido | 2 |

### Capítulo 6 - Monitoramento e comunicação

| Cód. | Arquivo | Perfil / Dispositivo | Onde exatamente | O que a imagem prova | Pri |
|---|---|---|---|---|:-:|
| P50 | `P50 - Mapa - Operacoes em Tempo Real.png` | central / desktop | `/dashboard/mapa`, com pelo menos uma viatura posicionada | A visão geográfica da operação | 1 |
| P51 | `P51 - Mapa - Painel Lateral.png` | central / desktop | Mesma tela, painel lateral com a escolta selecionada | Como saltar do mapa para a escolta | 2 |
| P52 | `P52 - Notificacoes - Feed de Eventos.png` | central / desktop | `/dashboard/notificacoes`, feed carregado | O fluxo único de tudo que acontece | 1 |
| P53 | `P53 - Notificacoes - Chat da Escolta.png` | central / desktop | Selecionar uma escolta no feed, painel de conversa aberto à direita | Que existe conversa por escolta, e não por pessoa | 2 |

### Capítulo 7 - Cadastros e material

| Cód. | Arquivo | Perfil / Dispositivo | Onde exatamente | O que a imagem prova | Pri |
|---|---|---|---|---|:-:|
| P54 | `P54 - Cadastros - Aba Clientes.png` | supervisor / desktop | `/dashboard/cadastros`, aba Clientes, com os contadores visíveis nas três abas | A base de clientes | 1 |
| P55 | `P55 - Cadastros - Novo Cliente.png` | supervisor / desktop | Botão de adicionar, diálogo de cliente aberto | Os campos exigidos de um cliente | 2 |
| P56 | `P56 - Cadastros - Aba Vigilantes.png` | supervisor / desktop | Aba Vigilantes | O efetivo cadastrado | 1 |
| P57 | `P57 - Cadastros - Credenciais do Operador.png` | supervisor / desktop | Ao salvar um vigilante com acesso, modal com as credenciais geradas. **Use um cadastro fictício e borre a senha** | Que o sistema gera o acesso do operador na hora, e a senha só aparece uma vez | 1 |
| P58 | `P58 - Cadastros - Aba Veiculos.png` | supervisor / desktop | Aba Veículos | A frota cadastrada | 2 |
| P59 | `P59 - Armamentos - Lista.png` | supervisor / desktop | `/dashboard/armamentos` | O controle de armamento | 2 |
| P60 | `P60 - Checklists - Das Escoltas.png` | supervisor / desktop | `/dashboard/checklists`, aba "Checklists das Escoltas" | Onde a gestão confere o que foi preenchido em campo | 2 |
| P61 | `P61 - Checklists - Modelos.png` | administrador / desktop | Aba "Modelos de Checklist", com o diálogo de novo modelo aberto | Que o checklist é configurável e versionado | 1 |

### Capítulo 8 - Indicadores e relatórios

| Cód. | Arquivo | Perfil / Dispositivo | Onde exatamente | O que a imagem prova | Pri |
|---|---|---|---|---|:-:|
| P62 | `P62 - Indicadores - Aba Operacional.png` | gestor / desktop | `/dashboard/indicadores`, período "Este Mês", aba Operacional, com a faixa de filtros e a faixa de abas visíveis | Os números da operação e as seis dimensões de análise | 1 |
| P63 | `P63 - Indicadores - Alertas de SLA.png` | gestor / desktop | Mesma tela, bloco de alertas de SLA, com pelo menos um alerta | Que o sistema aponta escolta fora do limite operacional | 2 |
| P64 | `P64 - Indicadores - Aba Financeiro.png` | gestor / desktop | Aba Financeiro, restrita a quem tem permissão | Faturamento, custo e margem, e o fato de serem restritos | 2 |
| P65 | `P65 - Relatorios - Filtros e Abas.png` | gestor / desktop | `/dashboard/relatorios`, período selecionado, abas Resumo Executivo, Relatório de Escoltas, Análise por Cliente e Ocorrências | O ponto de partida de qualquer relatório | 1 |
| P66 | `P66 - Relatorios - Montagem do Documento.png` | gestor / desktop | Mesma tela, bloco de montagem, mostrando os modelos prontos: Para o Cliente, Fechamento, Operacional e Completo, com as seções marcadas | Que o relatório é montado por seções, e que existe um modelo sem dado interno para enviar ao cliente | 1 |
| P67 | `P67 - Relatorios - PDF Gerado.png` | gestor / desktop | Gerar o documento, nova aba com a caixa de impressão aberta | O resultado impresso | 1 |

### Capítulo 9 - Administração do sistema

| Cód. | Arquivo | Perfil / Dispositivo | Onde exatamente | O que a imagem prova | Pri |
|---|---|---|---|---|:-:|
| P68 | `P68 - Usuarios - Lista.png` | administrador / desktop | `/dashboard/usuarios`, lista com perfis variados, mostrando as etiquetas de perfil e de situação | Quem tem acesso e em que condição | 1 |
| P69 | `P69 - Usuarios - Novo Usuario.png` | administrador / desktop | Diálogo de criação, com o seletor de perfil aberto | Como se concede acesso e se escolhe o perfil | 1 |
| P70 | `P70 - Usuarios - Redefinir Senha.png` | administrador / desktop | Ação de redefinir senha em um usuário fictício, modal aberto, **senha borrada** | O procedimento quando alguém perde a senha | 2 |
| P71 | `P71 - Telegram - Configuracao.png` | administrador / desktop | `/dashboard/sistema/telegram`. **Borre qualquer token ou identificador de grupo** | Onde se liga a notificação ao grupo do cliente | 2 |
| P72 | `P72 - Telegram - Teste de Envio.png` | administrador / desktop | `/dashboard/configuracoes/telegram-test`, com um envio de teste realizado | Como se confirma que a integração está viva | 2 |
| P73 | `P73 - Configuracoes - Sistema.png` | administrador / desktop | `/dashboard/configuracoes`, com os blocos Notificações, Aparência, Perfil e Sistema, este último mostrando versão e build | As preferências e a identificação da versão | 2 |
| P74 | `P74 - Auditoria - Trilha.png` | administrador / desktop | `/dashboard/auditoria`, filtro em "Últimos 7 dias" | Que toda ação sensível deixa rastro com autor e horário | 1 |

---

## 7. Capítulo 10, anexos, sem print

Três blocos de texto que fecham o manual e evitam a maior parte das dúvidas de suporte.

### 7.1 Tabela de status

Os doze status e o rótulo que aparece na tela: Rascunho, Agendada, Pré-Início, Em Andamento, Na Origem, Trânsito para Destino, No Destino, Trânsito para Retorno, Retornando, Na Base, Finalizada, Cancelada.

### 7.2 Matriz de permissões

A tabela da seção 2 deste documento, reproduzida como anexo consultável.

### 7.3 O que o sistema não faz

Bloco de honestidade. Evita reclamação e evita promessa que a operação não pode cumprir:

- **Não funciona sem internet.** Não existe fila offline nem sincronização posterior. Sem sinal, o registro não acontece.
- **Não substitui o rádio.** A comunicação em tempo real continua sendo pelo canal de sempre.
- **Não rastreia continuamente por conta própria.** A posição é gravada nos pontos de controle e nos check-ins periódicos, não em fluxo contínuo automático.
- Gráficos nos indicadores ainda não estão implementados: os números aparecem em cartões e tabelas.

---

## 8. Como entregar isto ao Claude Design

Depois de tirar os prints:

1. Confirme que a pasta `docs\prints\` tem os arquivos nomeados com o código `P00` na frente.
2. Envie ao Claude Design **este arquivo mais a pasta de imagens**.
3. Use um pedido nesta linha:

> Monte uma apresentação de manual do usuário a partir deste roteiro. Siga os dez capítulos na ordem. Cada print citado vira um slide: a imagem ocupa o corpo do slide, o título do slide é o assunto do print e o texto de apoio é a coluna "O que a imagem prova", desenvolvida em duas ou três frases. Capítulos 1, 2 e 5 são para o operador em campo, com linguagem direta e passo numerado. Capítulos 3, 4, 7, 8 e 9 são para gestão. Use a paleta do design system do projeto: azul marinho escuro como base e cinza-azulado como apoio. Sem emoji.

4. Se algum print de prioridade 1 faltar, diga isso ao Claude Design em vez de deixar o slide vazio: é melhor o capítulo ter um slide a menos do que ter um espaço reservado sem imagem.

---

## 9. Resumo de execução

| Etapa | O que fazer | Tempo estimado |
|---|---|---|
| 1 | Preparar cliente e escolta de demonstração | 30 min |
| 2 | Percorrer o fluxo completo capturando os capítulos 4 e 5 | 90 min |
| 3 | Capturar os capítulos 1, 2, 3 e 6 | 45 min |
| 4 | Capturar os capítulos 7, 8 e 9 com conta administradora | 45 min |
| 5 | Revisar nomes, borrar dados sensíveis | 30 min |
| 6 | Enviar ao Claude Design | 10 min |

**Total de prints:** 74, sendo 45 de prioridade 1 e 29 complementares.

---

*Roteiro levantado em 02/09/2026, sobre o commit `f7056e4`. Se o sistema mudar de tela, este arquivo precisa ser revisto antes de virar apresentação.*
