# CLAUDE.md

Regras e contexto para o Claude neste repositório (app Escolta Armada). Leia também o README.md, a ARQUITETURA.md e o LOG-ALTERACOES.md antes de começar.

## Contexto da frente (19/11/2026)

Frente: Escolta Armada (consultoria Esquematiza). Contexto no cofre do Peçanha (Obsidian, cofre-pessoal):

- Mapa de frentes: cofre-pessoal, `90 Sistema/Manuais/Mapa de frentes.md` (seção 2.4).
- Estado vivo: cofre-pessoal, `90 Sistema/Handoffs/Estado vivo - Escolta Armada onda O 07-11.md`.
- Índice da frente: cofre-pessoal, `01 Projetos/Escolta Armada/MOC - Escolta Armada.md`.
- ClickUp: lista "Escolta Armada" (901114078269), espaço Consultoria.
- Prévia: escolta-armada.vercel.app.

Se o ambiente não alcançar o cofre, trabalhe só com este repositório e diga isso no PR.

## Regras de trabalho do Peçanha

1. O pedido chega por issue com o briefing do Programador (manual "Programador - modelo de briefing para o Claude Code da VPS", versão 2) e a marcação @claude, ou pela tarefa da VPS com o mesmo briefing.
2. Resultado sempre em PR numa branch nova. Nunca merge, nunca push na `master`, nunca push forçado: o merge é do Peçanha.
3. Nenhum segredo (senha, token, chave, cookie) em código, log, PR ou comentário.
4. Speak Up fora: nada de apuração, denúncia ou caso neste repositório.
5. Só dados fictícios em teste e exemplo.
6. Português do Brasil revisado, sem travessão nem meia-risca (use vírgula, dois-pontos, parênteses ou hífen).
7. O PR diz o que foi feito, os testes rodados com a saída resumida, o link da prévia e as pendências que dependem do Peçanha.
8. Este repositório é público: nada de dado de cliente, nome de pessoa, endereço ou credencial em arquivo, issue ou PR.
