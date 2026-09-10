# Plano de Captura de Prints

Companion de `09 - Manual do Usuário.md`. Este documento **substitui** a lista de 74 prints do arquivo `08 - Manual do Usuario - Roteiro e Prints.md`.

O que mudou, e por quê:

- **De 74 para 35 capturas.** O manual foi reescrito por perfil, focado no **Supervisor** e no **Operador**. Os prints de telas exclusivas de Administrador (Auditoria, Configurações, Telegram, Usuários) e de Gestor puro saíram, porque não são os dois perfis que operam o sistema.
- **Numeração nova, `P01` a `P35`,** amarrada ao manual `09`. Ignore a numeração do arquivo `08`.
- Cada linha diz **como capturar**: por computador (rota estável, dado fictício) ou por celular (câmera e GPS reais).

---

## 1. A verdade sobre "tirar os prints automaticamente"

Não dá para eu gerar este conjunto sozinho, e o motivo é concreto, não preguiça:

1. **Dois terços das capturas nascem no celular, com câmera e GPS reais.** Checkpoint, checklist, ocorrência, emergência e as cinco fotos da viatura no pré-início dependem da câmera do aparelho (`capture="environment"`) e de uma posição de GPS de verdade. Um navegador de desktop não fotografa nem obtém coordenada real de forma confiável.
2. **As telas operacionais só existem com uma escolta em cada status.** A Jornada, o Painel de Ações, a Timeline cheia, a finalização e o mapa exigem uma escolta caminhando pelas 9 etapas. Isso se resolve criando **uma escolta de demonstração e percorrendo o fluxo inteiro**, capturando enquanto avança.
3. **LGPD.** O sistema está em produção, com cliente, placa, CPF, série de arma e token reais. Qualquer captura tirada sobre os dados reais vaza dado sensível. Por isso toda captura precisa de **dado fictício** ou de **borrão antes de salvar**.

O que **é** viável por computador, com a extensão do Chrome, está na seção 4. O que **precisa do celular** está na seção 5. A separação está na coluna "Como capturar" da tabela.

---

## 2. Preparação (faça uma vez, antes de tudo)

1. **Cliente fictício.** Crie em Cadastros um cliente **"Cliente Demonstração Ltda"**. Nenhum print pode mostrar cliente real.
2. **Vigilante fictício.** Crie um vigilante de teste (ex.: "Teste Operador Demo") para os prints de credencial. A senha que aparecer deve ser **borrada** antes de salvar a imagem.
3. **Uma escolta de demonstração,** com o cliente fictício, e a intenção de **percorrê-la do agendamento à finalização**. Uma passagem só resolve quase todas as capturas do Operador e da tela de detalhe. Refazer depois custa o dobro.
4. **Uma conta de cada perfil à mão.** A aba Financeiro não aparece para o Operador; o Painel de Ações muda conforme quem olha.

### Padrão técnico

| Item | Padrão |
|---|---|
| Formato | PNG |
| Computador | Janela em 1440 x 900, zoom 100% |
| Celular | Aparelho real (para câmera e GPS) ou, sem alternativa, DevTools iPhone 12 Pro 390 x 844 |
| Recorte | Sem barra de endereço, sem barra de tarefas, sem relógio |
| Dado sensível | Borrar ou usar fictício **antes** de salvar |
| Pasta | `escolta-armada\escolta-armada\docs\prints\` |
| Nome | Exatamente o da coluna "Arquivo" abaixo, sem acento |

---

## 3. A lista reduzida (35 prints)

Legenda de "Como capturar": **PC** = computador, rota estável, extensão do Chrome dá conta (seção 4). **CEL** = celular com câmera e GPS reais (seção 5). Legenda de "Dado": **F** = usar cadastro fictício, **B** = borrar dado sensível, **-** = sem dado sensível.

### Acesso e orientação

| Cód. | Arquivo | Perfil / Disp. | Onde exatamente | O que prova | Pri | Como | Dado |
|---|---|---|---|---|:-:|:-:|:-:|
| P01 | `P01 - Login - Painel de Acesso.png` | deslogado / PC | `/auth/login`, campos vazios | Onde e como se entra | 1 | PC | - |
| P02 | `P02 - Primeiro Acesso - Troca de Senha.png` | usuário novo / PC | `/auth/trocar-senha`, abre sozinha no 1º login | Troca de senha obrigatória, mínimo 6 | 2 | PC | - |
| P03 | `P03 - Instalacao - Icone na Tela de Inicio.png` | qualquer / CEL | Tela de início do celular com o ícone | Resultado da instalação | 2 | CEL | - |
| P04 | `P04 - Navegacao - Menu por Perfil.png` | administrador / PC | Menu lateral expandido, 4 seções | O mapa do sistema em uma imagem | 1 | PC | - |
| P05 | `P05 - Navegacao - Barra Inferior Mobile.png` | operador / CEL | Barra inferior: Painel, Escoltas, Campo, Avisos, Mapa | Os atalhos de campo | 1 | CEL | - |

### Supervisor: cadastros

| Cód. | Arquivo | Perfil / Disp. | Onde exatamente | O que prova | Pri | Como | Dado |
|---|---|---|---|---|:-:|:-:|:-:|
| P06 | `P06 - Cadastros - Nova Viatura.png` | supervisor / PC | `/dashboard/cadastros`, aba Veículos, diálogo Novo Veículo aberto | Cadastro da frota | 1 | PC | F |
| P07 | `P07 - Armamentos - Lista e Cadastro.png` | supervisor / PC | `/dashboard/armamentos`, diálogo Novo Armamento aberto | Controle de armas | 1 | PC | B |
| P08 | `P08 - Cadastros - Vigilante e Login Gerado.png` | supervisor / PC | Aba Vigilantes, diálogo com o aviso azul "Login gerado" | Provisão de acesso na hora | 1 | PC | F |
| P09 | `P09 - Cadastros - Operador Provisionado.png` | supervisor / PC | Modal verde "Operador provisionado!", **senha borrada** | A senha aparece uma vez só | 1 | PC | B |
| P10 | `P10 - Checklists - Modelos.png` | supervisor / PC | `/dashboard/checklists`, aba Modelos de Checklist | Onde vive o checklist de Material/Viatura | 2 | PC | - |

### Supervisor: criar escolta

| Cód. | Arquivo | Perfil / Disp. | Onde exatamente | O que prova | Pri | Como | Dado |
|---|---|---|---|---|:-:|:-:|:-:|
| P11 | `P11 - Nova Escolta - Fase 1 Dados.png` | supervisor / PC | `/dashboard/escoltas/nova`, Fase 01 preenchida | Cliente, data, rota | 1 | PC | F |
| P12 | `P12 - Nova Escolta - Fase 2 Efetivo e Veiculos.png` | supervisor / PC | Fase 02, viatura e efetivo escolhidos | Como escalar | 1 | PC | F |
| P13 | `P13 - Nova Escolta - Fase 3 Revisao.png` | supervisor / PC | Fase 03, conferência final | Revisão antes de gravar | 2 | PC | F |

### Supervisor: acompanhar e fechar

| Cód. | Arquivo | Perfil / Disp. | Onde exatamente | O que prova | Pri | Como | Dado |
|---|---|---|---|---|:-:|:-:|:-:|
| P14 | `P14 - Escolta - Cabecalho e Jornada.png` | supervisor / PC | `/dashboard/escoltas/<id>`, topo com a barra das 9 etapas | Onde a escolta está no fluxo | 1 | PC | F |
| P15 | `P15 - Escolta - Painel de Acoes.png` | supervisor / PC | Bloco "Painel de Ações do Operador", escolta em andamento | Só as ações do status atual | 1 | PC | F |
| P16 | `P16 - Escolta - Abas.png` | supervisor / PC | Régua de abas com contadores | As seis visões da escolta | 2 | PC | F |
| P17 | `P17 - Escolta - Timeline.png` | supervisor / PC | Aba Timeline, escolta finalizada (linha cheia) | Registro cronológico completo | 1 | PC | F |
| P18 | `P18 - Escolta - Foto Carimbada.png` | supervisor / PC | Evento da timeline aberto, foto ampliada, carimbo legível | Foto com data, hora e local na imagem | 1 | PC | B |
| P19 | `P19 - Escolta - Finalizacao.png` | supervisor / PC | Escolta em "Na Base", diálogo "Finalizar Escolta e Relatório Diário" | O fechamento formal | 1 | PC | F |
| P20 | `P20 - Escolta - PDF de Fechamento.png` | supervisor / PC | Botão PDF, `/print`, caixa de impressão visível | O documento que vai ao cliente | 1 | PC | B |
| P21 | `P21 - Escolta - Cancelar.png` | supervisor / PC | Diálogo de cancelamento, campo de motivo | Cancelar exige motivo e fica registrado | 2 | PC | F |

### Acompanhamento em tempo real

| Cód. | Arquivo | Perfil / Disp. | Onde exatamente | O que prova | Pri | Como | Dado |
|---|---|---|---|---|:-:|:-:|:-:|
| P22 | `P22 - Mapa - Tempo Real.png` | supervisor / PC | `/dashboard/mapa`, viatura posicionada | A visão geográfica | 2 | PC | F |
| P23 | `P23 - Notificacoes - Feed e Chat.png` | supervisor / PC | `/dashboard/notificacoes`, escolta selecionada, chat aberto | Fluxo único e conversa por escolta | 2 | PC | F |
| P24 | `P24 - Notificacoes - Check-in Atrasado.png` | supervisor / PC | Alerta que surge quando o check-in atrasa | O atraso não passa despercebido | 2 | PC | F |

### Operador: campo

| Cód. | Arquivo | Perfil / Disp. | Onde exatamente | O que prova | Pri | Como | Dado |
|---|---|---|---|---|:-:|:-:|:-:|
| P25 | `P25 - Campo - Tela Inicial.png` | operador / CEL | `/dashboard/campo`, escolta ativa, "Progresso da Operação" | A tela onde o Operador vive | 1 | CEL | F |
| P26 | `P26 - Campo - Mural Disponiveis.png` | operador / CEL | Escoltas, aba Disponíveis, botão Puxar | O mural de serviço | 1 | CEL | F |
| P27 | `P27 - Campo - Assumir Escalada.png` | operador / CEL | Diálogo de assumir escolta já escalada, campo de motivo | Assumir de outra equipe exige motivo | 2 | CEL | F |
| P28 | `P28 - Pre-Inicio - Passo 1 Equipamentos.png` | operador / CEL | Preparação de Partida, passo 1 de 3 | Checklist de material antes de sair | 1 | CEL | F |
| P29 | `P29 - Pre-Inicio - Passo 2 Viatura.png` | operador / CEL | Passo 2, as cinco fotos da viatura | Cinco fotos, uma por ângulo | 1 | CEL | F |
| P30 | `P30 - Pre-Inicio - Passo 3 Saida.png` | operador / CEL | Passo 3, KM e foto do hodômetro | O ato que coloca a escolta em operação | 1 | CEL | F |
| P31 | `P31 - Campo - Registrar Checkpoint.png` | operador / CEL | Bloco "Registrar Checkpoint", foto capturada, viatura e observação | O gesto que mais se repete | 1 | CEL | F |
| P32 | `P32 - Campo - Checklist Nao Conformidade.png` | operador / CEL | Checklist, item não conforme, justificativa e foto abertas | Item reprovado exige justificativa e foto | 1 | CEL | F |
| P33 | `P33 - Campo - Check-in e Parada.png` | operador / CEL | Painel de Ações, diálogo de Check-in (foto e GPS) | O pulso de vida no trajeto | 1 | CEL | F |
| P34 | `P34 - Campo - Registrar Ocorrencia.png` | operador / CEL | Bloco "Registrar Ocorrência", tipo e foto | Como relatar incidente | 1 | CEL | F |
| P35 | `P35 - Campo - Acionar Emergencia.png` | operador / CEL | "Confirmar Emergência?" visível | Acionamento com confirmação em dois toques | 1 | CEL | F |

**Total:** 35 prints, 24 de prioridade 1. **17 são por computador (PC)** e **18 pelo celular (CEL)**.

---

## 4. Comando para a extensão Claude in Chrome (as 17 capturas PC)

As capturas marcadas **PC** são de telas estáveis, sem câmera. Dá para dirigi-las pela extensão do Chrome (Claude in Chrome). Faça primeiro a preparação da seção 2 (cliente e escolta fictícios).

Abra a extensão com o sistema já aberto e **logado como Supervisor**, e cole o pedido abaixo. Onde estiver `<URL>`, troque pelo endereço do sistema.

> Você está no sistema Escolta Armada, logado como Supervisor. Vou pedir uma sequência de capturas de tela. Para cada uma: navegue até o local indicado, deixe a tela no estado descrito, tire a captura em PNG e salve com o nome exato entre aspas. Use sempre o cliente fictício "Cliente Demonstração Ltda" e a escolta de demonstração. Nunca mostre outro cliente, placa, CPF, série de arma ou token real: se aparecer na tela, me avise para eu borrar antes de você salvar. Janela em 1440 x 900, zoom 100%.
>
> 1. `<URL>/auth/login` deslogado, campos vazios. Salve "P01 - Login - Painel de Acesso.png".
> 2. `<URL>/dashboard` com o menu lateral expandido mostrando as quatro seções. Salve "P04 - Navegacao - Menu por Perfil.png".
> 3. `<URL>/dashboard/cadastros`, aba Veículos, abra o diálogo "Novo Veículo". Salve "P06 - Cadastros - Nova Viatura.png".
> 4. `<URL>/dashboard/armamentos`, abra "Novo Armamento". Se a lista atrás mostrar série real, me avise. Salve "P07 - Armamentos - Lista e Cadastro.png".
> 5. Aba Vigilantes de Cadastros, abra "Novo Vigilante", digite o nome do vigilante fictício até aparecer o aviso azul "Login gerado". Salve "P08 - Cadastros - Vigilante e Login Gerado.png".
> 6. Salve o vigilante fictício e capture o modal verde "Operador provisionado!". Antes de salvar a imagem, me avise para borrar a senha. Salve "P09 - Cadastros - Operador Provisionado.png".
> 7. `<URL>/dashboard/checklists`, aba Modelos de Checklist. Salve "P10 - Checklists - Modelos.png".
> 8. `<URL>/dashboard/escoltas/nova`, Fase 01 preenchida com o cliente fictício. Salve "P11 - Nova Escolta - Fase 1 Dados.png".
> 9. Fase 02, com uma viatura e o efetivo escolhidos. Salve "P12 - Nova Escolta - Fase 2 Efetivo e Veiculos.png".
> 10. Fase 03, revisão. Salve "P13 - Nova Escolta - Fase 3 Revisao.png".
> 11. Abra a escolta de demonstração em `<URL>/dashboard/escoltas/<id>`, topo com a barra das 9 etapas. Salve "P14 - Escolta - Cabecalho e Jornada.png".
> 12. Mesma tela, bloco "Painel de Ações do Operador". Salve "P15 - Escolta - Painel de Acoes.png".
> 13. Régua de abas com os contadores. Salve "P16 - Escolta - Abas.png".
> 14. Aba Timeline, de preferência de uma escolta já finalizada. Salve "P17 - Escolta - Timeline.png".
> 15. Abra um evento da timeline com foto e amplie a foto até o carimbo ficar legível. Me avise se o carimbo mostrar endereço real. Salve "P18 - Escolta - Foto Carimbada.png".
> 16. Escolta em "Na Base", abra o diálogo "Finalizar Escolta e Relatório Diário". Salve "P19 - Escolta - Finalizacao.png".
> 17. Clique em PDF, deixe a caixa de impressão do navegador visível. Salve "P20 - Escolta - PDF de Fechamento.png".
> 18. Abra o diálogo de Cancelar, mostrando o campo de motivo. Salve "P21 - Escolta - Cancelar.png".
> 19. `<URL>/dashboard/mapa` com a viatura de demonstração posicionada. Salve "P22 - Mapa - Tempo Real.png".
> 20. `<URL>/dashboard/notificacoes`, selecione a escolta de demonstração e abra o chat. Salve "P23 - Notificacoes - Feed e Chat.png".
> 21. Se houver um alerta de check-in atrasado, capture-o. Salve "P24 - Notificacoes - Check-in Atrasado.png".
>
> Ao terminar, liste os arquivos salvos e diga quais telas mostraram dado real que precisou de borrão.

Observações:

- A extensão salva na pasta de downloads do Chrome. Depois, mova os arquivos para `docs\prints\`.
- P02 (troca de senha) e P24 (alerta) dependem de estado: P02 só aparece num usuário que ainda não trocou a senha; P24 só quando um check-in de fato atrasa. Se não surgirem, deixe para o percurso da escolta demo.
- **Alternativa sem extensão:** tire cada uma com `Win + Shift + S`, seguindo a mesma lista.

---

## 5. Roteiro do celular (as 18 capturas CEL)

Estas capturas têm câmera e GPS, e por isso **não saem de um computador**. Elas saem de um aparelho real, com você percorrendo a escolta de demonstração. A extensão do Chrome não segura a câmera do celular.

Faça em **uma passagem só**, do agendamento à finalização. Use o **print nativo do celular** (não a extensão). Como as fotos são de demonstração, pode fotografar qualquer viatura e ambiente, sem dado real.

Percurso, na ordem, capturando quando indicado:

1. Logado como Operador, na tela inicial: capture a barra inferior. **P05**.
2. Com o ícone do app na tela de início do aparelho: **P03**.
3. Em Escoltas, aba Disponíveis (mural): **P26**. Se houver uma escolta já escalada, abra o diálogo de assumir com o campo de motivo: **P27**.
4. Puxe a escolta de demonstração. Na tela Campo, com a escolta ativa e o "Progresso da Operação": **P25**.
5. Inicie o Pré-Início (pela tela de detalhe). Passo 1, Equipamentos: **P28**. Passo 2, as cinco fotos da viatura: **P29**. Passo 3, KM e hodômetro: **P30**.
6. Já em trânsito, no bloco "Registrar Checkpoint", com uma foto capturada e a viatura escolhida: **P31**.
7. No checklist, marque um item como não conforme para abrir a justificativa e a foto: **P32**.
8. No Painel de Ações, abra o diálogo de Check-in (foto e GPS): **P33**.
9. No bloco "Registrar Ocorrência", com tipo e foto: **P34**.
10. Toque em Acionar Emergência e capture a confirmação "Confirmar Emergência?" **antes** de confirmar: **P35**. Não confirme, para não disparar a central de verdade. Se disparar, avise a central que foi teste.

---

## 6. LGPD: o que borrar antes de salvar

Marque na origem, não depois. Prints que exigem cuidado:

- **P07** (Armamentos): série da arma e número do GU. Use armamento fictício ou borre.
- **P09** (Operador provisionado): a senha. Sempre borrar.
- **P18** (Foto carimbada): o carimbo pode conter endereço real. Use ponto de demonstração.
- **P20** (PDF): o documento reúne cliente, placa, efetivo. Gere sobre a escolta fictícia.
- Em qualquer captura de lista (Cadastros, Escoltas, Mapa), confira o que está **atrás** do diálogo. Se houver cliente ou placa real, borre.

---

## 7. Entrega ao Claude Design

Depois das capturas:

1. Confirme que `docs\prints\` tem os arquivos com o código `Pxx` na frente.
2. Envie ao Claude Design **o manual `09` mais a pasta de imagens**.
3. Peça algo nesta linha:

> Monte uma apresentação de manual do usuário a partir deste manual. Siga a ordem: Acesso, Orientação, Parte A (Supervisor) e Parte B (Operador). Cada `[PRINT Pxx]` vira um slide: a imagem no corpo, o título do slide é o assunto do trecho, e o texto de apoio sai do parágrafo ao lado, em duas ou três frases diretas. A Parte B é para o Operador em campo, com passo numerado e linguagem de rádio. Use a paleta Navy do sistema: base `#1A294A`, realce `#53648A`, secundário `#9F906D`, fundo `#EEF0F5`. Sem emoji.

4. Se faltar um print de prioridade 1, diga isso ao Claude Design, em vez de deixar o slide com um espaço vazio.

---

*Plano levantado em 02/09/2026, sobre o commit `f7056e4`.*
