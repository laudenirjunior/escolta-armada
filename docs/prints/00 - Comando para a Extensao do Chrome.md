# Comando para a extensão do Chrome (capturas de computador)

Comando autônomo: abre o link, faz o login com as suas credenciais, percorre as telas, captura e salva. Cobre as **17 capturas marcadas PC** no plano (`docs/10`). As 18 de celular (câmera e GPS) ficam para o roteiro da seção 5 do plano.

## Como usar

1. Antes, crie no sistema o **cliente fictício "Cliente Demonstração Ltda"** e, se possível, a **escolta de demonstração** já percorrida no celular (para existir Timeline cheia, "Na Base" e PDF).
2. Abra a extensão Claude in Chrome e **cole o bloco abaixo inteiro**.
3. Preencha os três espaços no topo do bloco: **`<URL>`** (endereço do sistema), **`<USUARIO>`** e **`<SENHA>`** de um Supervisor de teste.
4. As imagens vão para a pasta de downloads do Chrome. Ao final, mova para `docs\prints\`.

Dependências de estado: **P19** (finalização) só com a escolta em "Na Base" ainda não finalizada; **P20** (PDF) com a operação completa; **P24** (alerta) só quando um check-in atrasa de fato. O comando pula e anota quando não existirem.

---

```
Você é meu assistente dentro do Chrome. Vou dar um link, um usuário e uma senha, e você vai fazer login e tirar uma sequência de capturas de tela do sistema Escolta Armada, salvando cada uma no computador. Trabalhe de forma autônoma: só me interrompa se o login falhar ou se aparecer dado real que eu precise borrar.

DADOS (preencha antes de enviar):
- Link: <URL>
- Usuário: <USUARIO>
- Senha: <SENHA>

REGRAS PARA TODAS AS CAPTURAS:
- Salve cada imagem no computador, em PNG, com o nome exato entre aspas.
- Janela em 1440 x 900, zoom 100%.
- Use somente o cliente fictício "Cliente Demonstração Ltda" e a escolta de demonstração, para não expor dado real.
- Só capture. Não crie, edite, cancele nem finalize nada de produção. A única criação permitida é o vigilante fictício do passo 6.
- Se um passo depender de um estado que não existe agora (escolta em "Na Base", alerta de atraso), pule e anote na lista final.
- LGPD: se em alguma tela aparecer cliente, placa, CPF, série de arma ou token reais (inclusive atrás de um diálogo), capture mesmo assim, mas anote o arquivo na lista final como "revisar borrão". No passo 6, a senha que aparecer eu vou borrar depois.

LOGIN:
0. Abra <URL>/auth/login. Se a tela de login aparecer (título "Painel de Acesso Operacional"), com os campos vazios, salve "P01 - Login - Painel de Acesso.png". Se você já estiver logado e for redirecionado ao painel, pule o P01 e anote. Em seguida, se estava na tela de login, digite o Usuário no campo "Usuário ou e-mail de acesso", a Senha no campo de senha, e entre.

CAPTURAS, na ordem:
1. Vá a <URL>/dashboard com o menu lateral expandido, mostrando as quatro seções (Operações, Gestão, Análise, Sistema). Salve "P04 - Navegacao - Menu por Perfil.png".
2. Vá a <URL>/dashboard/cadastros, aba Veículos, e abra o diálogo "Novo Veículo" (vazio). Salve "P06 - Cadastros - Nova Viatura.png". Feche o diálogo sem salvar.
3. Vá a <URL>/dashboard/armamentos e abra "Novo Armamento". Salve "P07 - Armamentos - Lista e Cadastro.png". Feche sem salvar.
4. Vá à aba Vigilantes de Cadastros, abra "Novo Vigilante" e digite o nome fictício "Teste Operador Demo" até aparecer o aviso azul "Login gerado". Salve "P08 - Cadastros - Vigilante e Login Gerado.png".
5. Clique em "Cadastrar e Provisionar" e capture o modal verde "Operador provisionado!". Salve "P09 - Cadastros - Operador Provisionado.png" e anote na lista final que a senha desta imagem precisa de borrão.
6. Vá a <URL>/dashboard/checklists, aba "Modelos de Checklist". Salve "P10 - Checklists - Modelos.png".
7. Vá a <URL>/dashboard/escoltas/nova, Fase 01, com o cliente fictício e os campos preenchidos. Salve "P11 - Nova Escolta - Fase 1 Dados.png".
8. Avance para a Fase 02, com uma viatura e o efetivo escolhidos. Salve "P12 - Nova Escolta - Fase 2 Efetivo e Veiculos.png".
9. Avance para a Fase 03, a revisão. Salve "P13 - Nova Escolta - Fase 3 Revisao.png". Não confirme a criação.
10. Abra a escolta de demonstração em <URL>/dashboard/escoltas e clique nela; na tela de detalhe, mostre o topo com a barra das 9 etapas (a Jornada). Salve "P14 - Escolta - Cabecalho e Jornada.png".
11. Na mesma escolta, mostre o bloco "Painel de Ações do Operador". Salve "P15 - Escolta - Painel de Acoes.png".
12. Mostre a régua de abas com os contadores (Visão Geral, Timeline, Efetivo, Veículos, Ocorrências, Financeiro). Salve "P16 - Escolta - Abas.png".
13. Abra a aba Timeline, de preferência de uma escolta já finalizada, para a linha estar cheia. Salve "P17 - Escolta - Timeline.png".
14. Abra um evento da timeline que tenha foto e amplie a foto até o carimbo (data, hora, local) ficar legível. Salve "P18 - Escolta - Foto Carimbada.png".
15. Com uma escolta em "Na Base" (ainda não finalizada), abra o diálogo "Finalizar Escolta e Relatório Diário". Salve "P19 - Escolta - Finalizacao.png". Não finalize.
16. Clique no botão "PDF" e deixe a caixa de impressão do navegador visível. Salve "P20 - Escolta - PDF de Fechamento.png". Feche sem imprimir.
17. Abra o diálogo de "Cancelar", mostrando o campo de motivo. Salve "P21 - Escolta - Cancelar.png". Não cancele.
18. Vá a <URL>/dashboard/mapa com a viatura de demonstração posicionada. Salve "P22 - Mapa - Tempo Real.png".
19. Vá a <URL>/dashboard/notificacoes, selecione a escolta de demonstração e abra o chat lateral. Salve "P23 - Notificacoes - Feed e Chat.png".
20. Se houver um alerta de check-in atrasado na tela, capture-o. Salve "P24 - Notificacoes - Check-in Atrasado.png".

AO TERMINAR: liste os arquivos salvos, os passos que pulou e por quê, e os arquivos marcados "revisar borrão".
```

---

Se em vez de colar você preferir que eu mesmo dirija o Chrome conectado, me passe **`<URL>`**, **`<USUARIO>`** e **`<SENHA>`** de um Supervisor de teste e a confirmação de que o cliente fictício já existe, que eu conduzo daqui.
