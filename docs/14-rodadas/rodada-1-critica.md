# Crítica adversarial do plano, rodada 1

Objeto: `/opt/operacao/escolta-armada/docs/14 - Plano Lote 2026-10.md` (rodada 1), branch `melhoria/2026-10-onda-a-seguranca`.
Revisor independente, que não escreveu o plano. Feita em 08/10/2026 (Brasília), somente leitura.
Fontes conferidas: comando do lote de 08/10 (seções 1 a 5), nota M1 a M4 de 03/10, `docs/13`, `analise/seguranca.md`, `analise/dados.md`, `analise/consumidores.md`, dump `database/esquema-producao-2026-10-08.sql` (abaixo "dump:N") e o código do repositório. `plano:N` é a linha do `docs/14`.

## Nota: 5 de 10

O plano é bem fundamentado em quase todos os pontos (referências de linha conferidas e corretas: detalhe `:897` e `:1913`, impressão `:224` e `:260`, Campo `:1201`, `:1390` e `:1503`, notificações `:177`, provider `:37`, clientes `:177-182`, PDF `:625`, Nova `:475`). Mas tem 2 problemas bloqueantes e 11 importantes, entre eles um furo que permite ao operador pular a aprovação do pedido chamando uma função interna, uma violação da regra 1.11 e lacunas de cobertura do comando (T2 no mural, F1 com o ponto, critério de aceite da M1 para os pontos, verificação do histórico do Git). Precisa de nova rodada.

## Problemas

### Bloqueantes

**1. Função interna `_executar_substituicao` exposta a `authenticated`: o operador pula a aprovação (T3).**
Evidência: plano:97 diz que "Todas" as funções da 203 são SECURITY DEFINER com "`GRANT` a authenticated", e plano:106 lista `_executar_substituicao` entre elas. A função, como descrita, só confere status, escala fixa, presença e equipe (plano:106), não se o pedido foi aprovado ou venceu. O solicitante chamaria `rpc('_executar_substituicao', {pedido_id})` logo depois de criar o pedido e trocaria a equipe na hora. Isso viola o requisito 8 da onda C ("nenhum operador consegue substituir equipe fora das regras chamando a RPC diretamente"). A regra geral (plano:9, "GRANT só quando for RPC") contradiz o texto da 203.
Correção: `_executar_substituicao` sem GRANT a ninguém (`REVOKE ALL ... FROM PUBLIC, anon, authenticated`). Ela também precisa receber o motivo da execução (`aprovado` ou `liberado_por_tempo`) e conferir, com o pedido travado, que `status = 'pendente'` e que há decisão de supervisor ou `expira_em < now()`. Incluir em 3.6 o teste "chamada direta a `_executar_substituicao` e a `processar_pedidos_vencidos` por operador não troca equipe antes do prazo".

**2. A migration 201 grava em `escoltas.metadados` de ESC-2026-0001 e ESC-2026-0007, e a reversão que depende disso não funciona.**
Evidência: plano:82 ("a periodicidade antiga de cada escolta fica guardada em `metadados.periodicidade_anterior` pela própria 201"). A tabela da 201 (plano:65) não menciona isso e diz que só o campo muda. O comando (regra 1.11 e onda B, item 2) só autoriza zerar a periodicidade dessas duas escoltas, e o próprio plano:13 repete essa exceção única. Além disso, a edição pela tela Nova sobrescreve `metadados` inteiro só com os complementos (`app/dashboard/escoltas/nova/page.tsx:551-565`, `metadados: Object.keys(meta).length ? meta : null`). Qualquer edição de uma escolta aberta apaga `periodicidade_anterior`, e a reversão da 201 volta nulo. O campo `metadados` também continua livre para o operador (a 197 não o protege, plano:24).
Correção: guardar `(escolta_id, periodicidade_checkin_min, gravado_em)` numa tabela de backup fora do alcance do PostgREST (ver problema 10) e fazer a reversão a partir dela. Não tocar em `metadados`. Corrigir plano:65 e plano:82 para dizer a mesma coisa.

### Importantes

**3. T2 sem o botão "Estou na base" no mural.**
Evidência: comando, T2: "A equipe escalada confirma presença ('Estou na base') no mural e no Modo Guiado". O plano só põe o botão no Painel Guiado (plano:118). O item do mural (plano:116) não tem o botão.
Correção: botão "Estou na base" no card da escolta no mural, para quem é do efetivo, chamando `confirmar_presenca_base` com GPS, e teste de ponta a ponta pelos dois caminhos.

**4. Corrida entre aprovação, recusa, cancelamento e liberação por tempo: a trava é só na escolta, não no pedido.**
Evidência: plano:106 trava só a escolta e confere de novo o estado dela. Nada diz que `aprovar_pedido_mural`, `recusar_pedido_mural`, `cancelar_meu_pedido_mural` e `processar_pedidos_vencidos` travam a linha do pedido e conferem `status = 'pendente'` sob a trava. Exemplo: supervisor aprova no segundo 15:00 enquanto uma consulta dispara a liberação por tempo. Os dois caminhos executam, e saem duas auditorias e dois avisos no aplicativo. O Telegram se salva pela chave única, mas a auditoria não. Outro exemplo: o supervisor recusa enquanto a liberação executa, e a escolta fica com o pedido "recusado" e a equipe trocada. Também não há nova checagem de T5 (outra escolta puxada pelo solicitante durante os 15 min), do vigilante ativo nem da viatura ativa no momento da execução.
Correção: ordem fixa de travas (primeiro a escolta, depois o pedido, `FOR UPDATE`), transição de status do pedido feita com `UPDATE ... WHERE status = 'pendente' RETURNING`, e a execução só segue se uma linha mudar. Na execução, conferir de novo T5, o vigilante ativo, os acompanhantes e a viatura. Proibir que o supervisor aprove o próprio pedido. Acrescentar o teste "aprovação e liberação simultâneas geram uma só substituição e uma só auditoria".

**5. A liberação por tempo e o envio ao Telegram continuam dependendo de navegador aberto.**
Evidência: plano:105 (a liberação só roda quando alguém chama `consultar`, `listar` ou carrega o mural) e plano:112 (o envio só acontece quando o navegador de quem originou o evento chama a rota, ou quando um provider de G4 aberto chama a cada 60 s). A onda F, item 3, pede "enviado uma única vez pelo servidor, não por navegador aberto", e T4 pede "envio travado no servidor". Sem nenhuma aba de G4 aberta, o aviso de substituição por tempo (T4) e o aviso de pedido (T3) ficam na fila sem prazo. Quem dispara a liberação dentro de `listar_pedidos_mural` nem sabe que gerou evento para chamar a rota. Liberar por consulta é aceito pelo comando, mas o aviso ficar parado não é.
Correção: `pg_cron` (disponível no Supabase e no Supabase local) rodando `processar_pedidos_vencidos()` a cada minuto, mais `pg_net` (ou um cron externo) chamando `/api/avisos/enviar` com segredo de servidor em cabeçalho, além do disparo pelo navegador. Se `pg_cron` não estiver habilitado em produção, registrar isso e manter o desenho atual como plano B declarado. Documentar no relatório que, sem o agendador, o aviso depende de uma aba aberta.

**6. Onda F, item 1, coberto pela metade: o ponto de controle fica fora da transação.**
Evidência: comando, onda F, item 1: "RPC transacional para ponto, status e histórico, eliminando registro órfão". Em plano:193, "Ponto de controle continua gravado antes (o ponto órfão quando a transição falha continua e fica pendente junto do Caminho 2)". O ponto órfão não depende do Caminho 2 (um escritor por etapa). Ele depende só de inserir o ponto na mesma função, com as fotos já enviadas (ids em parâmetro). A trigger `tr_exigir_transito_retorno` (dump:3005, corpo em dump:666) exige o ponto antes do status. Dentro da mesma transação, inserir o ponto primeiro resolve.
Correção: incluir em `transicionar_status_escolta` (ou numa irmã) o insert opcional do ponto (tipo, viatura, GPS, `foto_id`, `observacoes` com `foto_ids`), na ordem ponto, status e histórico. Se houver motivo real para não fazer, ele precisa estar escrito e a pendência registrada como achado da onda F, não como parte do Caminho 2.

**7. Critério de aceite da M1 para os pontos de controle não está coberto, e a onda F piora o caso.**
Evidência: a nota de 03/10 (critério da M1) diz: "pontos registrados na JAMEF não mostram outro município, ou, se a coordenada estiver certa e só o rótulo variar, o relatório deixa isso claro". O plano só diz "o rótulo reverso continua só texto (sem mudança no detalhe)" (plano:157). A onda F (plano:195) passa a gravar no Campo o endereço por geocodificação reversa, que é justamente o rótulo que traz o município vizinho na divisa (nota de 03/10, 3.2.3). O critério "escolta com origem JAMEF exibe São João de Meriti" também não tem teste.
Correção: definir a regra de exibição (por exemplo, o rótulo reverso com a marca "aproximado" e a precisão do GPS ao lado, ou, quando o ponto estiver a menos de N m de um local salvo ativo, exibir o nome e o endereço do local salvo). Colocar a regra no relatório impresso e incluir os dois critérios no portão funcional da onda D.

**8. A migration 200 pode apagar a policy de upload e quebrar todas as gravações de foto.**
Evidência: plano:27 apaga "qualquer SELECT ou ALL cujo predicado seja só `bucket_id = 'fotos'`". As policies de produção em `storage` não foram lidas (`docs/13` 0.2). A homologação usa policies reconstruídas (`/opt/operacao/escolta-homolog/seed/03_storage.sql`), sem nenhuma de SELECT. Se produção tiver uma policy `FOR ALL` só com `bucket_id = 'fotos'`, que também concede INSERT, apagá-la impede o Campo, o detalhe e o Modo Guiado de enviar foto (`app/dashboard/campo/page.tsx:795`, `app/dashboard/escoltas/[id]/page.tsx:1547`). A logo usa `upsert: true` (`app/dashboard/clientes/page.tsx:177`), que exige SELECT e UPDATE. O plano:54 manda consultar as policies, mas não diz o que fazer com o resultado.
Correção: a 200 só apaga policies `FOR SELECT`. Se houver `FOR ALL` ampla, ela aborta, ou cria antes uma policy `FOR INSERT` equivalente e só depois apaga a ampla. Escrever no plano a regra de decisão sobre o resultado da consulta (o que aborta, o que segue). Incluir teste de upload pelo Campo e pelo detalhe depois da 200, com o bucket fechado.

**9. Branches empilhadas, dependências entre ondas e "publicar sem X" não estão tratados.**
Evidência: plano:7 (cada branch parte da anterior) e o comando, 3.4.2 ("publicar sem X") e Fase 4.3 (a onda que falhar sai do pacote). A 207 (onda F) usa a fila `avisos_telegram` da 202 (onda C), conforme plano:188. A 197 (onda A) já protege `escala_fixa` (C) e `periodicidade_checkin_min` (B). Os PRs das ondas D, E e F conteriam o código de C. Com "publicar sem C", F quebra, e o merge de D leva junto o código de C.
Correção: tabela de dependências entre ondas (código e migrations), dizendo para cada onda quais podem sair sem quebrar as seguintes e qual é o procedimento (rebase ou cherry-pick numa branch de publicação, ou mover a criação de `avisos_telegram` para uma migration própria e neutra). Para C, a saída mais simples é a fila nascer numa migration separada, aplicada mesmo quando C fica de fora.

**10. Tabelas de backup criadas no schema `public` ficam expostas ao PostgREST.**
Evidência: `_backup_policies_storage_20261008` (plano:27) e as tabelas `_backup_` da reversão da 202 (plano:143), mais a de periodicidade sugerida no problema 2. No Supabase, tabela nova em `public` recebe por padrão GRANT para `anon` e `authenticated` (o dump mostra `GRANT ALL` de `anon` em quase todas as tabelas, dump:4800 a dump:5112), e sem RLS fica legível e gravável pela API. Na tabela de policies isso é grave: quem alterar o texto guardado faz a reversão da 200 recriar uma policy escolhida por ele.
Correção: criar os backups num schema não exposto (por exemplo `backup_20261008`, como já foi feito em 19/08, `LOG-ALTERACOES.md:684`), com `REVOKE ALL` de `anon` e `authenticated`, ou em `public` com `ENABLE ROW LEVEL SECURITY` sem policy e REVOKE. O mesmo vale para `avisos_telegram` (plano:92): dizer explicitamente `ENABLE ROW LEVEL SECURITY` e REVOKE.

**11. A ordem de publicação não fecha com o caminho de DDL previsto no comando.**
Evidência: o comando, 3.6, diz que sem caminho de DDL o Peçanha aplica "o pacote SQL" no SQL Editor, responde "aplicado" e só então vem o merge. O plano:15 e o plano:207-216 intercalam migrations antes e depois de cada merge: a 200 só depois do deploy e do portão da onda A, e as 202 e 203 antes do merge de C. São pelo menos 7 rodadas de "aplicado" pelo celular. O plano não registra o resultado da Fase 0, item 4 (há ou não caminho de DDL), embora `docs/13` 0.1 cite um `pg_dump` de produção, o que sugere conexão direta.
Correção: registrar no plano o caminho de DDL encontrado. Sem caminho, dividir o pacote em blocos numerados com ponto de parada ("Bloco 1: 196 a 199, responda 'aplicado 1'"; "Bloco 2, depois do deploy de A: 200"), e dizer o que acontece se o Peçanha parar no meio. Aplicar a 203 só depois do deploy do código de C. Com a 203 antes, o diálogo antigo manda motivo de 5 caracteres e espera troca imediata, e o mural fica quebrado no intervalo, ou por mais tempo se o portão de C reprovar e o merge for revertido.

**12. A verificação do histórico do Git (Fase 0, item 5) não foi feita e o plano não traz caminho para fazê-la.**
Evidência: plano:37 ("Histórico do Git: não varrido; recomendação registrada") e `docs/13` 0.4 (varredura recusada pelo controle de permissões). O comando pede verificar "se ... o histórico do Git contêm chaves reais" e, se forem reais, registrar a rotação como AÇÃO URGENTE DO PEÇANHA. O repositório é público, e a rotação da `sb_secret` está pendente desde 10/09 (plano:205).
Correção: prever a varredura sem imprimir valores (por exemplo, `git log -p --all` filtrado por padrão de JWT, `sb_secret_`, `sbp_` e token de bot, mostrando só o hash do commit, o arquivo e o tipo, com o valor mascarado). Se continuar recusada, registrar no relatório que não foi verificado (regra 1.2) e pôr a rotação preventiva como ação do Peçanha, sem apresentar o item como coberto.

**13. Os critérios de aceite das ondas A, B, D, E e F não viraram testes listados; vários não são testáveis na homologação como ela está.**
Evidência: só a onda C tem lista de testes (plano:137). O portão funcional (comando, 4.4) exige teste por perfil contra os critérios de aceite de cada item. Os casos sem teste ou sem como testar:
1. A, "leitura anônima do bucket recusada" e "todas as fotos aparecem ... em todas as telas e no PDF": não há lista por tela. A homologação não tem as policies reais de `storage` (problema 8).
2. A, Douglas e Bruno: a 199 depende do hash real em `auth.users` (plano:26). Na homologação não existe a conta real, então o teste é trivial. O nome por prefixo "Douglas" ou "Bruno" é frágil.
3. B, "fechar um aviso qualquer não o faz voltar sozinho".
4. D, "criar escolta JAMEF para Galeão sem digitar endereço", "coordenada gravada igual à do local salvo" e "operador não cadastra local". O mapa com pino não roda sem token da Mapbox (`docs/13` 0.5), então o caminho "mapa indisponível" (plano:154) é o único testável.
5. E, soma sem duplicar no PDF e na impressão: só a frase de plano:179.
6. F, as 9 etapas também pelo Modo Guiado: o `avancarStatus` do Campo é o mesmo que o Painel Guiado usa, e o plano:201 só cita detalhe e Campo.

Correção: uma tabela "critério de aceite, teste (SQL ou Playwright), perfil, evidência esperada" por onda, que diga também o que não é testável na homologação e como será conferido na produção sem escrever dado. Na 199, marcar Bruno pelo id conhecido (o comando já afirma a senha padrão), registrar a contagem de linhas afetadas e não depender de comparar hash.

### Menores

**14. Hora local nas mensagens geradas no banco.** "Substituição liberada só a partir de HH:MM" (plano:99) e os textos de Telegram montados no servidor (plano:188). O banco está em UTC e o plano não manda usar `AT TIME ZONE 'America/Sao_Paulo'` (comando, regra 1.3). Sem isso, o operador vê a hora 3 horas adiantada.

**15. Volatilidade das funções de leitura.** `consultar_pedido_mural` e `listar_pedidos_mural` executam `processar_pedidos_vencidos` (plano:105). Se forem declaradas STABLE, o PostgREST as roda em transação somente leitura e a escrita falha. Declarar VOLATILE e chamar por POST.

**16. `notificacoes` continua forjável por UPDATE.** `notificacoes_escrita` é FOR ALL com `WITH CHECK (true)` (dump:4312). A 197 só restringe INSERT (plano:24). O destinatário pode reescrever `payload` e `usuario_dest_id` da própria notificação e "entregar" a outra pessoa um aviso falso do mural, agora que a onda C usa essa tabela para aviso oficial (plano:93). Policy restritiva de UPDATE com `WITH CHECK (usuario_dest_id = get_meu_usuario_id() OR G4)`, ou "Ciente" por RPC que só mude `lida`.

**17. A auditoria do mural fica incompleta e pode ser desligada.** H9 cita também `incluir_vigilante_na_minha_escolta` sem auditoria (`docs/13`, H9). O plano audita `puxar` e `devolver` (plano:100-101), mas não `incluir`. E `auditoria_ligada` (plano:88) permite desligar T7. Auditoria não deveria ser parâmetro: tirar o campo ou ignorá-lo nas RPCs.

**18. T4 no Telegram para a equipe substituída.** O comando diz "Equipe substituída e supervisão recebem aviso no aplicativo e no Telegram". O plano manda o Telegram só ao chat central (plano:106). Se não houver chat por pessoa, declarar a limitação e registrar que a equipe recebe pelo aplicativo e vê no chat central.

**19. Duplicidade possível na fila.** Com reserva de 2 minutos (plano:108), um envio lento ou um `concluir_aviso_telegram` que falha depois do envio faz a mensagem sair de novo. Para "uma mensagem por evento", tratar como no máximo uma vez: estado `enviando`, sem reenvio automático depois do prazo sem confirmação de erro do Telegram, e teste com falha simulada no `concluir`.

**20. `TELEGRAM_API_BASE` em produção** (plano:112). Se a variável for preenchida por engano na Vercel, o token do bot vai para outro host. Aceitar a variável só fora de produção (`VERCEL_ENV !== 'production'`).

**21. Ordem das triggers de `escoltas`.** As BEFORE UPDATE rodam em ordem alfabética: `tr_escoltas_atualizado_em`, `tr_exigir_transito_retorno`, `tr_impedir_edicao_por_operador`, `tr_validar_transicao_status`, `tr_verificar_checklist_pendente` (dump:2998 a dump:3096). `verificar_checklist_pendente` grava `NEW.checklist_pendente_no_inicio` (dump:1383) depois da trava. A 197 passa a proteger essa coluna (plano:24). Hoje funciona por causa da ordem dos nomes, e renomear a trigger quebraria o início da escolta pelo operador. Manter o nome, comentar a dependência e testar "operador inicia escolta com checklist pendente".

**22. Guardas não descritas.** A 207 (`enfileirar_alerta_checkin`, `enfileirar_aviso_presenca`, plano:188), a trigger da 205 (plano:169) e `escolta_do_caminho` (plano:25) não dizem se são DEFINER, qual é a guarda (efetivo ou G4) nem quem recebe GRANT. `escolta_do_caminho` precisa de EXECUTE para `authenticated`, porque é avaliada dentro da policy. Confirmar também que o `postgres` do SQL Editor consegue criar e apagar policy em `storage.objects` no projeto (dono `supabase_storage_admin`). Fazer isso no Supabase local antes do pacote.

**23. Locais salvos.**
1. Coordenadas de Engenhão, Galeão e Santos Dumont "de referência pública" sem fonte citada (plano:149). Pela regra 1.2, citar a fonte ou deixar a coordenada nula enquanto o local estiver aguardando conferência.
2. Pela decisão 6, a ativação acontece depois da conferência por Peçanha ou Bruno. O plano deixa qualquer supervisor ativar (plano:149). Ao menos registrar `conferido_por` no relatório, ou restringir a ativação da carga inicial a gestor e administrador.
3. O comando pede a tela "em Configurações", e o plano põe em Cadastros (plano:156). Declarar o desvio.
4. O endereço do local JAMEF precisa conter "São João de Meriti" para cumprir o critério da M1.
5. A reversão da 204 apaga os locais já conferidos sem backup.

**24. Combustível.** O comando e a M3 pedem a entrada "na seção financeira da edição e do fechamento". O plano usa a aba Financeiro do detalhe (plano:173). A justificativa é boa (a edição recria `escolta_veiculos`, `nova/page.tsx:594-620`, e a FK de `pontos_controle` é ON DELETE CASCADE, dump:3573), mas o desvio deve ser declarado como tal no relatório e na homologação com o Bruno. Conferir também se a parada do tipo "Abastecimento" (`app/dashboard/escoltas/[id]/page.tsx:601`) guarda valor, para não criar uma segunda fonte (pergunta da Fase 1 da M3). CHECK de valor não negativo com `NOT VALID` seguido de `VALIDATE`.

**25. Coerência de documentos e escopo.** H15 está como pendência no `docs/13` (linha 42) e entra na onda F no plano (plano:196 e plano:205). Alinhar os dois. O Fase 2, item 1, pede o efeito em Modo Guiado, mapa, Telegram e PDF por onda, e isso falta em D, E e F. `sou_do_efetivo` ganha só `usuarios.status`, e a análise recomenda também `vigilantes.status` (`analise/seguranca.md`, seção 11, item 2). O H4 deixa de fora a revogação de sessões do alvo de `redefinir_senha_usuario`, que deve ir para pendências. Antes da 196, rodar uma consulta de conferência que conte as pessoas do efetivo de escoltas abertas com `usuarios.status <> 'ativo'`, porque elas perdem o acesso na hora.

**26. Abas antigas abertas.** Depois da 200, as abas do Campo abertas com o código anterior (o service worker não guarda cache, `public/sw.js`, mas a aba não recarrega sozinha) passam a mostrar foto quebrada até recarregar. O envio ao Telegram cai para texto (`app/api/telegram/route.ts:146-160`). Publicar fora do horário de escolta em rua, ou pedir no comunicado que recarreguem o aplicativo.

## O que está correto e deve ser mantido

1. Migrations a partir de 196 com a 195 como referência que aborta se executada (`database/migrations/195_referencia_estado_atual.sql`), com reversão por migration.
2. Bucket fechado só depois do deploy e do portão de produção (plano:53), e a policy de storage aditiva antes (198).
3. As fotos 2 a 5 pelo segmento de escolta do caminho (plano:25). O caminho é `campo/<escolta_id>/...` (`campo/page.tsx:793`) e `<prefixo>/<escolta_id>/...` (`[id]/page.tsx:1546`). `campo/geral/...` cai no ramo do autor.
4. As DELETE restritivas da 197: o app não apaga essas tabelas pelo operador (as únicas deleções são `nova/page.tsx:594-595`, feitas pela gestão, e cadastros). As RPCs DEFINER gravam auditoria sem a policy de INSERT (dump:129 e dump:1051 são funções DEFINER).
5. As proteções novas da 197 não quebram o fluxo do operador: as transições usam só `status` (`[id]/page.tsx:1124`, `:1322`, `:1753`, `:2420`; `campo/page.tsx:1133`), a finalização usa `observacao_fechamento` e `data_finalizacao`, que continuam livres (`[id]/page.tsx:2693`), e cancelar e alterar a periodicidade já são só da gestão na tela (`lib/permissions.ts:30`, `:47`).
6. O índice único parcial de um pedido pendente por escolta e o `FOR UPDATE` preservado.
7. A combinação de chave única por evento com envio pelo servidor, uma vez corrigidos os problemas 5 e 19.
