# Arquitetura Atual

> **Atualização do lote 2026-10 (08/10/2026).** Números de 08/10 antes do lote: 34 tabelas no `public` (a `usuarios_credenciais` entrou depois deste documento), 73 policies, 31 funções. As rotas `/api/telegram` e `/api/ai/melhorar-texto` exigem sessão e o `middleware.ts` está ativo (ver `docs/12`, 4.1 e 4.2). O histórico de status **não** é mais gravado em dobro: a trigger `tr_registrar_historico_status` foi removida de produção antes de 08/10 e a remoção ficou versionada na migration 209; desde a onda F, status e histórico de cada etapa são gravados juntos pela RPC `registrar_etapa_escolta` (207). O bucket `fotos` passa a privado na onda A (migration 200), com leitura por URL assinada. As seções abaixo descrevem o estado anterior e ficam como registro; a análise atual está em `docs/13 - Analise Completa 2026-10.md`.

**Projeto Supabase:** `qthoyxujyzskydulvcfy` (escolta-armada, us-east-2, plano Free, branch `main` em produção)

Next.js 14 App Router, Supabase (Postgres 17), Tailwind 3, Mapbox GL. Sem biblioteca de gráficos.

## Aviso sobre migrations

O schema real **só existia no Supabase**, sem versionamento. Os 7 arquivos que estavam em `database/migrations/` descreviam uma v1 que nunca existiu neste banco: chaves `SMALLINT`, `usuarios.auth_id`, `escoltas.status_id`.

Foram para `database/_legado_v1/`. **Não execute nenhum deles.** O `007` redefine `auth.uid()` como `SELECT auth.uid()`, recursão infinita que sobrescreveria a função do próprio Supabase e quebraria toda a autenticação.

As migrations válidas começam no número 100 e são aplicadas via MCP, registradas em `supabase_migrations.schema_migrations`.

## Tabelas

33 no schema `public`, **todas com RLS ligada**.

| Grupo | Tabelas |
|---|---|
| Domínio | `dom_perfis`, `dom_funcoes`, `dom_calibres`, `dom_tipos_armamento`, `dom_tipos_veiculo`, `dom_tipos_ocorrencia`, `dom_tipos_evento`, `dom_tipos_foto`, `dom_tipos_ponto` |
| Acesso | `usuarios`, `vigilantes` |
| Cadastros | `clientes`, `veiculos`, `armamentos` |
| Operação | `escoltas`, `escolta_veiculos`, `escolta_efetivo`, `escolta_armamentos` |
| Campo | `pontos_controle`, `rastreamento`, `presencas`, `fotos`, `ocorrencias`, `emergencias` |
| Checklists | `checklist_modelos`, `checklist_modelo_itens`, `checklists`, `checklist_respostas` |
| Sistema | `escolta_status_historico`, `atualizacoes_status`, `notificacoes`, `logs_auditoria`, `chat_mensagens` |

## Ligações que confundem

| Coluna | Referencia | Cuidado |
|---|---|---|
| `escolta_efetivo.vigilante_id` | **`vigilantes(id)`** | As políticas antigas faziam `JOIN usuarios u ON u.id = ee.vigilante_id`, que nunca casava nada. O caminho correto passa por `vigilantes.usuario_id` |
| `pontos_controle.escolta_veiculo_id` | `escolta_veiculos(id)` | Não aponta para `escoltas` direto |
| `checklists.escolta_veiculo_id` | `escolta_veiculos(id)` | `checklists` **não tem** `escolta_id` |
| `pontos_controle.foto_id` | `fotos(id)` | Escalar. O schema comporta uma foto por ponto; as demais ficam num JSON em `observacoes` |
| `escolta_efetivo (escolta_id, vigilante_id)` e `escolta_veiculos (escolta_id, veiculo_id)` | índices únicos da 210 (lote 2026-10, onda G, bloco 2) | O mesmo vigilante entra uma vez só em cada escolta, em qualquer viatura, e a mesma placa uma vez só por escolta. As RPCs do mural (204) recusam a repetição com mensagem e invalidam o pedido que esbarrar no índice |

## Funções

19 no `public`. Nenhuma `SECURITY DEFINER` é executável por `anon`.

| Categoria | Funções | Regra de acesso |
|---|---|---|
| Resolvedores de identidade | `perfil_usuario_atual`, `get_meu_perfil`, `get_meu_usuario_id`, `get_meu_vigilante_id` | `authenticated` mantido: **as políticas de RLS dependem delas** |
| Escopo de efetivo | `sou_do_efetivo`, `sou_do_efetivo_veiculo` | `authenticated` |
| RPC de cliente | `criar_usuario_por_login`, `cadastrar_operador`, `redefinir_senha_usuario`, `excluir_auth_usuario` | `authenticated`, com guarda `IS NULL OR` de perfil |
| Trigger | `validar_transicao_status_escolta`, `exigir_ponto_transito_retorno`, `impedir_autopromocao`, `registrar_historico_status_escolta`, `verificar_checklist_pendente`, `gerar_codigo_escolta`, `update_atualizado_em`, `sync_auth_user_on_usuarios` | Sem semântica de chamada |
| Obsoleta | `criar_usuario_completo` | **Revogada.** Criava contas sem `auth.identities`, que nasciam sem conseguir entrar |

**A regra que não pode ser esquecida:** toda função `SECURITY DEFINER` nova precisa de `REVOKE EXECUTE FROM anon, PUBLIC`, guarda `IF perfil IS NULL OR perfil NOT IN (...)` e `SET search_path`. Em SQL, `NULL NOT IN (...)` é NULL, e `IF NULL THEN` não dispara: foi assim que qualquer anônimo podia criar um administrador.

## Central de avisos e schema `lote_interno` (lote 2026-10, onda J)

- **`notificacoes` é a central de avisos de cada pessoa** (migration 211): uma linha por destinatário e por evento, com `titulo`, `texto`, `criado_em`, `lida_em` e `evento_chave` (índice único `(evento_chave, usuario_dest_id)`). `lida` continua existindo e o gatilho `tr_notificacoes_sincronizar_lida` a mantém em acordo com `lida_em` nos dois sentidos. Lidos há mais de 90 dias são apagados pelo cron.
- **Acesso:** SELECT só da própria caixa (`usuario_dest_id = get_meu_usuario_id()`, decisão S5: a gestão não lê a caixa dos outros; a auditoria continua em `logs_auditoria`). Nenhuma escrita direta: `anon` sem privilégio nenhum, `authenticated` sem INSERT, UPDATE, DELETE e TRUNCATE. O app lê e marca só por RPC: `meus_avisos(p_tipo, p_escolta_id, p_so_nao_lidas, p_limite, p_antes, p_antes_id)` (paginação por cursor `(criado_em, id)`, porque os avisos de um mesmo ciclo do cron têm o mesmo `criado_em`), `contar_avisos_nao_lidos()`, `marcar_aviso_lido(p_notificacao_id)` (204, bloco 2, grava `lida_em` desde a 217; sem ela a Central mostra "Atualização em andamento") e `marcar_todos_lidos(p_tipo, p_escolta_id)` (respeita os filtros ativos da Central).
- **Quem grava:** só `lote_interno.notificar(p_chave, p_escolta_id, p_tipo, p_usuarios, p_titulo, p_texto, p_extra)`, SECURITY DEFINER, sem `auth.uid()`, `ON CONFLICT DO NOTHING`. Chamam: o cron do check-in (212) e `_avisar_app` do mural (217, chave `<tipo>:<pedido_id>`). **Exige escolta:** `notificacoes.escolta_id` é NOT NULL com FK em cascata; aviso sem escolta não é gravado (WARNING e retorno 0). A onda L (conflito `escolta_apagada`) precisa tirar o NOT NULL na própria migration ou avisar por outro caminho.
- **Schema `lote_interno`:** funções internas do adendo 01 (fora dos schemas do PostgREST). Nenhuma função dele é executável por `anon` ou `authenticated`: o `ALTER DEFAULT PRIVILEGES ... IN SCHEMA` da 211 não retira o EXECUTE global de PUBLIC (limite do PostgreSQL), então **toda função nova no `lote_interno` precisa de `REVOKE ALL ... FROM PUBLIC, anon, authenticated` explícito** (conferido em `04_lote_2026_10_j.sql`).
- **Cron `lote2026_avisos_checkin`** (pg_cron, a cada minuto, 212): `lote_interno.gerar_avisos_checkin()` calcula o check-in vencido no banco (porte de `minutosAteCheckin`, com o mesmo arredondamento: referência = último PARADA `reporte_periodico`, senão o primeiro ponto, senão a data prevista; o primeiro aviso sai logo que a periodicidade vence, com o atraso que o Painel mostra, e os seguintes a cada periodicidade), grava um aviso por período vencido (chave `checkin:<escolta>:<epoch da referência>:<n do período>`) para o efetivo, administrador, gestor, supervisor e central (S2). Cada escolta roda no próprio bloco `BEGIN ... EXCEPTION`: erro numa não desfaz as outras, o Telegram nem a limpeza. O navegador não calcula mais atraso para a tela.
- **Telegram do check-in vencido** (regra antiga da 208, pendência 0.3, mesmo texto): depende do Vault, com o navegador como reserva.
  - Pelo cron (`lote_interno.enfileirar_alerta_checkin`, fila `avisos_telegram`) só com `avisos_pelo_banco_ativos()` verdadeiro **e** `configuracao_avisos.checkin_telegram_pelo_cron` ligada. A coluna nasce falsa na 212 (bloco 1) e a 217 (bloco 2) a liga: entre o bloco 1 e o deploy, quem manda é o navegador da master, e o cron mandando junto dobraria a mensagem.
  - Fora disso (segredos fora do Vault, `pg_net` ou `pg_cron` recusados, `envio_pelo_banco` desligado, ou entre o deploy e o bloco 2), o `AvisosProvider` chama `reservar_alertas_checkin()` a cada minuto: o banco calcula a regra antiga, reserva a chave em `avisos_reservados` (padrão da `reservar_aviso_presenca`, 208) e devolve o alerta só ao primeiro navegador da gestão ou da equipe; esse navegador manda pelo `/api/telegram` com o mesmo texto e destino da master (chat do cliente). Uma mensagem por evento, com qualquer número de navegadores. Sem nenhum navegador aberto nesse modo, a mensagem não sai (como antes do lote).
  - As duas vias usam a mesma chave e uma confere a outra (reserva já feita não vai à fila; chave já na fila não é reservada): a troca de caminho não dobra a mensagem.
- **App:** `components/avisos-provider.tsx` (no layout) lê o contador e os não lidos a cada 20 s, mostra cada aviso novo no canto por 2 s (região `role="status"` `aria-live="polite"`) e alimenta o sino e o item Avisos da barra inferior. "Já mostrado" é pelo id do aviso (memória e `localStorage` por usuário), com a decisão tomada sob `navigator.locks` e avisada por `BroadcastChannel` às outras abas (sem a trava, a primeira leitura espera de 0 a 2 s ao acaso). A página Avisos tem a aba Central (`components/avisos/central-avisos.tsx`), a Atividade (feed antigo, só gestão) e o Chat. **O sino conta só os avisos da Central**: o contador antigo somava inserções em 5 tabelas, inclusive `chat_mensagens`; mensagem nova do Chat Interno tem o contador próprio na aba Chat (mensagens para mim depois da última abertura da aba, marca em `localStorage`). `checkin-alert-provider.tsx` saiu; `alertas_dispensados` ficou sem uso (sai com a reversão da 201).

## Poder total da gestão, anulação e arquivamento (lote 2026-10, onda I)

- **Nada é apagado.** Voltar etapa e zerar **anulam** registros: `anulado_em`, `anulado_por` (FK sem ação para `usuarios`), `motivo_anulacao` e `anulacao_id` em `pontos_controle`, `checklists`, `ocorrencias`, `emergencias`, `presencas`, `mural_presencas`, `atualizacoes_status`, `rastreamento` e `escolta_status_historico` (213). `fotos` e `checklist_respostas` herdam do pai. **Todo leitor conta só `anulado_em IS NULL`** (banco: `exigir_ponto_transito_retorno`, `verificar_checklist_pendente`, `registrar_etapa_escolta`, cron e Telegram do check-in, `_presenca_da_equipe`, `mural_info`; app: Campo e Modo Guiado, detalhe, mapa, indicadores, relatórios, PDF, impressão, notificações, checklists, `lib/checkin.ts`). Na tela de detalhe e na impressão os anulados aparecem riscados, em seção própria, com "Anulado em DD/MM/AAAA HH:MM (Brasília) por Nome: motivo".
- **Carimbo de etapa:** `status_escolta_no_registro`, preenchido por `tr_carimbar_etapa_<tabela>` (BEFORE INSERT, `lote_interno.carimbar_etapa`) com o status da escolta no momento; o valor do cliente é ignorado. Registros anteriores à 213 ficam sem carimbo e entram na anulação por janela de tempo, a partir do ponto que produziu a etapa ou da última linha do histórico com `via_rpc`.
- **`escolta_status_historico.via_rpc`:** true só quando a linha foi gravada por RPC do servidor (variável de transação `escolta.historico_rpc`, ligada por `registrar_etapa_escolta` desde a 214 e pelas RPCs da 218). Linha gravada pelo cliente fica false e nunca serve de âncora.
- **Trava das colunas da gestão** (`tr_travar_colunas_gestao_<tabela>`, 213): `anulado_*`, `arquivada_*`, `versao_gestao`, `reiniciada_em`, carimbo e `via_rpc` só mudam com a variável `escolta.rpc_gestao` ligada **e** perfil administrador ou gestor (dupla guarda; ligar a variável sozinho não basta), ou sem usuário final (`auth.uid()` nulo). No INSERT só recusa valor diferente do padrão.
- **Máquina de estados** (`validar_transicao_status_escolta`, 214): ramo especial para `reset` e `conclusao_antecipada`, só com a variável `escolta.transicao_especial` (e o destino em `escolta.transicao_destino`) **e** perfil de gestão; recusa mudar o status de escolta arquivada.
- **Escolta iniciada só a gestão edita** (`tr_impedir_edicao_escolta_iniciada`, 214, em `escoltas`, `escolta_veiculos` e `escolta_efetivo`): fora de rascunho e agendada, só administrador e gestor mudam o que não é do fluxo (comparação por `to_jsonb`, sem as colunas livres e sem as geradas, lidas de `pg_attribute.attgenerated`). Livres: status, fechamento, periodicidade, data prevista, KM e combustível (S10).
- **Arquivamento:** `escoltas.arquivada_em/arquivada_por/motivo_arquivamento`; RESTRICTIVE `escoltas_arquivada_so_admin` (só o administrador enxerga); as telas filtram `.is('arquivada_em', null)` e as filhas lidas por data usam `escoltas!inner` com o filtro. Apagar escolta: RESTRICTIVE `escoltas_delete_so_rascunho` (só o administrador, em rascunho, sem registro de campo).
- **Ponto em nome de quem grava:** RESTRICTIVE `pontos_insert_autor` (`lancado_por = get_meu_usuario_id()`); o nulo é preenchido antes por `tr_preencher_lancado_por`. Depois de gravado, `lancado_por` e `data_hora` só mudam pelas RPCs da gestão (trava da 213).
- **Nada é apagado** (`tr_impedir_apagar_gestao_<tabela>`, 214, BEFORE DELETE, `lote_interno.impedir_apagar_registro`): para todos os perfis, recusa apagar linha anulada nas 9 tabelas de campo e em `escolta_conclusoes_antecipadas`, e apagar `escolta_veiculos` com qualquer registro de campo (válido ou anulado), o que fecha a cascata depois de um zerar. Trigger, não policy: vale também dentro das RPCs; sem usuário final passa (migrations, reversões).
- **RPCs (218, SECURITY DEFINER, motivo de 10 caracteres, `FOR UPDATE`, auditoria por `lote_interno.auditar`, aviso por `lote_interno.avisar_acao_gestao`: Central da supervisão e da equipe e Telegram ao chat central):** `editar_escolta` (por diferença pelo `escolta_veiculo_id`; troca de placa é UPDATE de `veiculo_id` na mesma linha, e duas viaturas trocam de placa entre si com a restrição `escolta_veiculos_escolta_veiculo_uk` da 210, `DEFERRABLE INITIALLY IMMEDIATE`, adiada só dentro da RPC; não muda `versao_gestao`), `pendencias_da_escolta`, `concluir_escolta_antecipada` (grava `escolta_conclusoes_antecipadas` e a view `vw_pendencias_conclusao`), `voltar_etapa_escolta` e `zerar_escolta` (com `p_previa`, que devolve também um `resumo` com `versao_gestao`, status, total e hash dos ids a anular; a confirmação manda o resumo em `p_resumo` e é recusada se a escolta mudou; toda volta que chega a agendada tem o tratamento do zerar; registro em `escolta_resets` com os valores guardados), `arquivar_escolta` e `recuperar_escolta` (sem linha de histórico, só auditoria). Concluir, voltar, zerar e arquivar recusam com emergência aberta. Leitura de `escolta_conclusoes_antecipadas` e da view: gestão, supervisão, central e o efetivo da escolta. Reversão da 213 idempotente (uma linha por registro em `backup_20261008`) e volta por `213_poder_total_estrutura_restaurar.sql`. `versao_gestao` sobe em voltar, zerar, concluir, arquivar e recuperar (a onda L usa para detectar conflito).
- **Regra do schema `lote_interno` (onda J) vale aqui:** as 16 funções novas da onda I no `lote_interno` têm REVOKE explícito; nenhuma é executável por `anon` ou `authenticated` (conferido em `04_lote_2026_10_i.sql`).
- **App:** `components/escolta/acoes-gestao.tsx` (menu, diálogos com prévia, faixa e seção de pendências); `lib/gestao.ts` (texto do anulado, colunas de anulação, "Atualização em andamento" quando a RPC não existe); páginas `/dashboard/escoltas/arquivadas` (administrador) e `/dashboard/escoltas/pendencias` (supervisor ou acima); edição pela Nova sempre pela `editar_escolta`.

## Wizard de pré-início (lote 2026-10, onda H)

- Só tela (`app/dashboard/escoltas/[id]/page.tsx`), sem banco. O KM inicial e a foto do painel por viatura (estados `kmPartida` e `fotosPartida`, mapas por `escolta_veiculos.id`) são pedidos no Passo 2, num cartão por viatura, e conferidos por `erroPorViaturaPasso2` no avanço do Passo 2 e de novo em `handleWizardSubmit`. O Passo 3 tem só as observações de saída e o resumo do KM e da miniatura da foto do painel (`MiniaturaArquivo`); ao voltar ao Passo 2, `CameraInput` reabre com as fotos já registradas (`iniciais`). As consultas de viaturas do detalhe, da impressão e do Campo ordenam por `criado_em` e `id`, a mesma "primeira viatura" das RPCs.
- Gravação sem mudança: no Confirmar, `gravarPontosPorViatura` grava um ponto `base_saida` por viatura com a foto e o KM daquela viatura (JSON do ponto) na mesma transação da passagem a `em_andamento` (`registrar_etapa_escolta`), e `gravarKmViaturas` grava `escolta_veiculos.quilometragem_saida` depois. Checklists e as 5 fotos de ângulo continuam só na primeira viatura (S1, pendência 0.2). O diálogo "Saída da Base" fora do wizard não muda (S16).

## Locais salvos: uso e UF (lote 2026-10, onda D2)

- **Migration 215 (bloco 1):** `locais_salvos.vezes_usado` (inteiro, padrão 0) e `locais_salvos.uf` (CHECK de duas letras maiúsculas); os 5 locais da carga da 205 com UF RJ. Atalhos ordenados por `vezes_usado DESC, nome` (`lib/locais.ts`, `carregarLocaisAtivos`, com volta à ordem por nome se a 215 não estiver no banco).
- **O que é o uso:** `vezes_usado` é o número de vezes que o local é origem ou destino de uma escolta **não cancelada** (cada lado conta uma vez; uma escolta da JAMEF para a JAMEF conta 2). É recalculado a partir das escoltas, nunca somado às cegas: ida e volta numa edição não infla, cancelar desconta, apagar desconta. "Usado N vezes em escoltas" na tela de locais é esse número. Local inativo fica com 0.
- **Qual local é o de um endereço (`lote_interno.local_do_endereco`):** a Nova grava o complemento no texto (`enderecoComComplemento`: "endereço, complemento"). Vence, nesta ordem: texto completo igual a "endereço, complemento" do local (ou só o endereço, para local sem complemento); texto que começa pelo endereço do local; coordenada mais próxima até 100 m; local sem complemento; nome. Com "JAMEF" e "JAMEF Doca 9" no mesmo endereço: "..., Doca 9" é da doca; o endereço sem complemento e um complemento que nenhum local tem são da JAMEF. Locais inativos ficam de fora.
- **Trigger `tr_contar_uso_local`** (AFTER INSERT OR DELETE OR UPDATE OF origem_endereco, destino_endereco, origem_lat, origem_lng, destino_lat, destino_lng, status em `escoltas`; `lote_interno.contar_uso_local`, SECURITY DEFINER, sem GRANT, `lock_timeout` de 500 ms): quando um lado mudou de fato (IS DISTINCT FROM) ou a escolta entrou ou saiu de `cancelada`, trava o local antigo e o novo na ordem do id e recalcula os dois (`lote_interno.contar_escoltas_do_local`). Status entre não canceladas, KM, UF (onda K) e as cargas não mexem em nada.
- **Trigger `tr_recontar_uso_locais`** (AFTER INSERT OR DELETE OR UPDATE OF nome, endereco, complemento, latitude, longitude, situacao em `locais_salvos`, por comando): recalcula todos os locais (`carregar_uso_locais`), porque um local novo ou mudado pode passar a ser o local de escoltas que já existem. O UPDATE só de `vezes_usado` não a dispara.
- **Nunca recusa:** erro dentro das duas triggers (inclusive esperar mais de 500 ms pela linha do local, que vira erro capturado e não o `statement_timeout` de 8 s do PostgREST) vira WARNING e uma linha em `lote_interno.locais_uso_falhas` (sem GRANT, sem leitura para authenticated); a escolta e o local são gravados. Gestor e administrador veem o total e a última falha na tela de locais pela RPC `locais_uso_falhas_resumo()` (as demais recebem 42501); o PACOTE confere a contagem. Compatível com a master (criação e edição dela testadas na janela do bloco 1).
- **Quem grava `vezes_usado`:** só as funções internas. INSERT e UPDATE de `authenticated` em `locais_salvos` passaram a ser por coluna, sem `vezes_usado`; `locais_salvos_regras` ignora o UPDATE que só muda `vezes_usado` (o uso não grava quem criou a escolta em `atualizado_por`) e devolve para conferência o local ativo cujo nome, endereço, complemento, pino ou UF mudou.
- **Carga:** `lote_interno.carregar_uso_locais()` recalcula todos os locais pela mesma regra, só lendo `escoltas` (UPDATE só em `locais_salvos`); roda no fim de cada aplicação da 215 (reaplicar dá o mesmo número). Reversão: `215_locais_uso_reverter.sql` guarda uso e UF em `backup_20261008.locais_uso` e tira triggers, funções, o registro de falhas e o resumo.
- **App:** `components/endereco/atalhos-locais.tsx` (botões pequenos; um toque preenche endereço, complemento, coordenada e UF), `components/endereco/salvar-endereco-local.tsx` ("Salvar este endereço" ao lado de origem e destino, supervisor ou acima; cria `aguardando_conferencia` com endereço, complemento, coordenada e UF; erros em português por `mensagemErroLocal`). O complemento é do endereço escolhido: trocar de endereço pelo atalho ou por uma sugestão da busca troca ou limpa o complemento; o digitado antes da primeira escolha fica. A UF do atalho vai à escolta desde a onda K (seção abaixo). A edição lista viaturas e equipe por `criado_em`, `id` (a mesma ordem do detalhe, do Campo e das RPCs), não pela ordem física do embutido do PostgREST.
- **Tela de locais:** erro ao ler a lista (sem a 215, colunas ausentes) mostra "Atualização em andamento" em vez de lista vazia; depois de salvar, diz quando o local ativo voltou para conferência.

## Cor por cliente, cartão padrão, filtros e UF (lote 2026-10, onda K)

- **Migration 216 (bloco 1, compatível com a master):** `escoltas.origem_uf` e `destino_uf` (CHECK de duas letras maiúsculas), `uf_estimada` (boolean, padrão false: alguma UF veio da coordenada) e `interestadual` (coluna gerada `origem_uf <> 'RJ' OR destino_uf <> 'RJ'`, nula quando não dá para saber), com índice. A trava de escolta iniciada (214) pega as colunas novas por `to_jsonb` e ignora a gerada; `impedir_edicao_por_operador` (197) foi recriada com `origem_uf`, `destino_uf` e `uf_estimada` na lista que o operador não altera; `editar_escolta` (218) já as aceita.
- **UF pela coordenada:** malha das 27 UFs da API de malhas do IBGE (qualidade mínima, baixada em 09/10/2026, cópia em `database/dados/malha-uf-ibge-2026-10-09.json`) em `lote_interno.malha_uf` (GeoJSON) e `lote_interno.malha_uf_aneis` (anéis em vetores, com a caixa). `lote_interno.uf_do_ponto` faz o teste de raio (PL/pgSQL puro, sem PostGIS) nos anéis cuja caixa contém o ponto, com paridade por polígono; devolve a UF, a distância até a divisa (até o polígono de outra UF mais próximo; o litoral não conta) e `fora_da_malha` (ponto no mar ou em ilha recebe a UF mais próxima). RPC `uf_da_coordenada(lat, lng)` (STABLE, SECURITY DEFINER, qualquer perfil autenticado; zero linhas para coordenada nula ou 0,0). Funções internas sem GRANT.
- **Carga:** `lote_interno.carregar_uf_escoltas()` preenche com `uf_estimada = true` só as escoltas sem nenhuma UF e com coordenada, exceto ESC-2026-0001 e ESC-2026-0007; lado a menos de 5 km da divisa ou fora da malha vai para `backup_20261008.uf_a_conferir`. Roda a cada aplicação da 216 (escolta criada pela master na janela ganha a UF se a 216 for reaplicada depois do deploy).
- **Paleta:** `public.paleta_clientes` (12 cores, uma padrão `#1D4ED8`; RLS ligada, sem policy e sem GRANT) e `lib/paleta-clientes.ts` com a mesma lista. Trigger `tr_normalizar_cor_cliente` (BEFORE INSERT OR UPDATE OF cor_destaque em `clientes`, `lote_interno.normalizar_cor_cliente`): cor `#rrggbb` vira a mais próxima pela distância CIE76 no espaço Lab (`lote_interno.cor_lab`, `lote_interno.cor_da_paleta`); texto que não é `#rrggbb`, ou nulo, vira a padrão; nunca erro, sem CHECK. DEFAULT da coluna `#1D4ED8`. Carga só quando a paleta nasce: clientes ativos na ordem de criação, cada um na mais próxima ainda livre; cor antiga em `backup_20261008.cores_clientes`. A tela usa `corDoCliente()` (mesma regra) para nunca mostrar cor fora da paleta.
- **Cor no mural do operador:** a RLS de `clientes` (`clientes_operador_select`) esconde do operador o cliente das escoltas em que ele não está no efetivo. `cores_clientes_das_escoltas(ids)` (SECURITY DEFINER, authenticated) devolve só a cor (nunca o nome) das escoltas que a pessoa já enxerga pela `escoltas_select` e pela `escoltas_arquivada_so_admin`; `completarCoresClientes` (`lib/cartao-escolta.ts`) chama a RPC para as linhas sem cliente.
- **Cartão padrão:** `lib/cartao-escolta.ts` (`SELECT_CARTAO`, `dataHoraBrasilia`, `resumoEndereco`, `etiquetas`, `textoEquipe`) e `components/escolta/cartao-escolta.tsx` (variantes `linha` e `cartao`), usados na lista e no mural (`app/dashboard/escoltas/page.tsx`), no painel inicial, no Modo Guiado (`painel-guiado.tsx` e `campo/page.tsx`), no mapa (lista lateral e popup; o marcador fica na cor do status) e nas arquivadas. Status por `lib/fluxo-escolta.ts` (os `STATUS_MAP` duplicados saíram).
- **Filtros:** `hooks/useFiltrosEscoltas.ts` e `components/escolta/filtros-escoltas.tsx`. Status, cliente, período (limites do dia em Brasília), quem criou e interestadual vão ao servidor (`aplicarFiltrosServidor`); equipe e busca no navegador (equipe da gestão pelo efetivo embutido, do operador pela `mural_info`). Guardados em `localStorage`, chave `filtros-escoltas:<usuarios.id>`, com try/catch.
- **UF na Nova:** `lib/uf-endereco.ts` (`ufDaSugestaoMapbox`: `short_code` da região, `BR-RJ` para `RJ`). Sugestão com região: UF dela, não estimada; sem região, pino movido ou local sem UF: `uf_da_coordenada`, estimada; atalho: `locais_salvos.uf`; texto digitado: nula. Resposta atrasada da RPC é descartada por sequência por lado. INSERT e `editar_escolta` levam `origem_uf`, `destino_uf` e `uf_estimada` (um lado estimado e com UF basta); a edição lê as gravadas. O campo de endereço que já nasce preenchido (edição) não busca na Mapbox ao montar. Detalhe (uma linha no cabeçalho), impressão e PDF mostram a etiqueta.
- **Reversão:** `216_uf_e_paleta_reverter.sql` guarda as UFs em `backup_20261008.escoltas_uf`, devolve a cor antiga a quem continua com a cor da carga, tira colunas, trigger, RPCs, funções, paleta e malha e recria a 197 sem as colunas da UF.

## Triggers em `escoltas`

| Trigger | Momento | Papel |
|---|---|---|
| `tr_gerar_codigo_escolta` | BEFORE INSERT | Gera `ESC-AAAA-NNNN` |
| `tr_validar_transicao_status` | BEFORE UPDATE OF status | A máquina de estados de 9 etapas |
| `tr_exigir_transito_retorno` | BEFORE UPDATE OF status | Exige o ponto de trânsito antes de concluir o retorno |
| `tr_verificar_checklist_pendente` | BEFORE UPDATE OF status | Marca pendência de checklist |
| `tr_registrar_historico_status` | AFTER UPDATE OF status | Grava o histórico |
| `tr_contar_uso_local` (215) | AFTER INSERT OR DELETE OR UPDATE OF endereços, coordenadas e status | Recalcula o uso do local salvo antigo e novo de origem e destino |

**Defeito conhecido, não corrigido:** o histórico é gravado em dobro. A trigger insere e o app insere de novo em 12 pontos. São 111 linhas onde deveria haver cerca de 71, com 58 sem autor.

## RLS

70 políticas, 52 usando a forma `(select fn())`, que vira InitPlan e é avaliada uma vez por consulta em vez de por linha.

Modelo geral:

- **Gestão** (`administrador`, `gestor`, `supervisor`, `central`): vê tudo do operacional
- **Operador**: vê apenas o das escoltas em que está no efetivo
- **`usuarios`**: cada um lê a própria linha; gestão lê todas; ninguém altera o próprio perfil
- **`dom_*`**: leitura livre para autenticado, porque alimentam o menu e são listas fixas
- **`chat_mensagens`**: só remetente e destinatário

## Storage

Bucket único `fotos`, **público**. Não foi fechado: fechá-lo quebraria o `sendPhoto` do Telegram, que busca a URL anonimamente do servidor deles. A solução seria enviar os bytes em `multipart` e usar URL assinada nas telas, o que ficou pendente.

## Débitos conhecidos

| Item | Situação |
|---|---|
| `/api/telegram` e `/api/ai/melhorar-texto` | Sem autenticação. Proxy aberto e faturado |
| `middleware.ts` | `matcher: []`, nunca roda |
| Bucket `fotos` público | Foto operacional com GPS acessível por URL |
| Histórico em dobro | 111 linhas, ~40 duplicatas |
| Offline | Não existe. `criado_offline` é literal `false` |
| `rastreamento`, `presencas` | Praticamente sem uso |
