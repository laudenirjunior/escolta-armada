# Análise Completa do Projeto, outubro de 2026

Fase 1 do lote de 08/10/2026 (comando "2026-10-08 Comando VPS - Escolta Armada lote completo", no cofre-pessoal). Somente leitura. Feita em 08/10/2026, entre 14h e 17h30 (Brasília), sobre a branch `modo-guiado-operador` (commit `f6cdf59`, um commit de documentação à frente da master `2b3fff9`).

## 0. Fontes e limites

1. Banco: backup JSON de 08/10/2026 13h54 (34 tabelas, 816 linhas, 0 falhas, feito por Peçanha com `database/ferramentas/backup.mjs`) e dump do esquema `public` de produção (`pg_dump --schema-only`, 5.196 linhas: 34 tabelas, 73 policies, 31 funções, 26 triggers). Os dois ficam fora do Git.
2. O dump não traz os schemas `storage` e `auth`. As policies do bucket `fotos` em produção não foram lidas; a homologação usa policies reconstruídas a partir do `LOG-ALTERACOES.md` (migration 150). O pacote de publicação começa por uma consulta de conferência dessas policies.
3. `supabase_migrations.schema_migrations` não foi lida (não está no backup nem no dump do `public`). A coerência entre banco e repositório foi medida contra o dump.
4. Chaves no repositório: os arquivos atuais (`DATABASE_SETUP.md`, `README.md`, `.env.local.example`) não têm chave. O histórico do Git (47 commits, todas as branches) foi varrido nas linhas acrescentadas pelos padrões de `sb_secret_`, JWT (`eyJhbGciOi`), `sbp_`, token de bot do Telegram, token público da Mapbox e chave da OpenAI, sem exibir valores: nenhuma ocorrência. Controle: a mesma varredura encontra 16 linhas com o nome da variável da chave anon, então o histórico foi lido. Não há ação urgente de rotação por causa do repositório; a rotação da `sb_secret` continua pendente desde 10/09 por outro motivo (`docs/12` 1.1).
5. Não há token da Mapbox na VPS: a comparação entre Geocoding v5, v6 e Search Box não foi medida.
6. Evidência no formato `arquivo:linha` (código) ou `dump:linha` (esquema de produção).

## 1. Achados por gravidade e destino

Legenda de destino: letra = onda deste lote; P = pendência registrada em `docs/12`; D = decisão do Peçanha.

### 1.1 Crítico

| # | Achado | Evidência | Destino |
|---|---|---|---|
| C1 | Next.js 14.2.35 com aviso crítico no `npm audit` (RCE na otimização de imagens com AVIF, além de outros 23 avisos). O `next.config.mjs` libera `images.remotePatterns` para `**.supabase.co`, mas o app não usa `next/image`. Produção roda na Vercel, que usa o otimizador próprio, o que reduz a exposição; a correção definitiva é Next 15.5 ou superior (versão maior) | `npm audit`, `next.config.mjs` | A (retirar o bloco `images`, sem efeito na tela); P (atualização de versão maior) |

### 1.2 Alto

| # | Achado | Evidência | Destino |
|---|---|---|---|
| H1 | Bloquear usuário não corta o acesso: `perfil_usuario_atual` e `sou_do_efetivo` ignoram `usuarios.status`. Operador bloqueado continua lendo e gravando nas escoltas em que está; gestor bloqueado continua criando contas | dump:1068, dump:1268 | A |
| H2 | Operador do efetivo altera pela API campos de `escoltas` que a tela não oferece: financeiro, `fluxo_versao` (voltar para 1 desliga a exigência do ponto de trânsito de retorno), `checklist_pendente_no_inicio`, `periodicidade_checkin_min`, e cancela a escolta | dump:4222, dump:930, dump:1345 | A (B para `periodicidade_checkin_min`, C para `escala_fixa`) |
| H3 | Operador do efetivo apaga evidência: policies sem `FOR` valem para DELETE em emergências, presenças, rastreamento, checklists, respostas, atualizações de status e viaturas (o DELETE de viatura leva pontos e checklists em cascata). O app nunca apaga essas tabelas pelo operador | dump:4115, 4407, 4420, 3782, 3879, 3862, 4174 | A |
| H4 | Gestor bloqueia administrador (status de terceiro sem trava) e redefine a senha de outro gestor | dump:828, dump:1171 | A |
| H5 | Leitura ampla de `usuarios` (CPF, telefone, e-mail) por qualquer autenticado. É trade-off registrado em `docs/05` (migration 153) | dump:4453 | D, P |
| H6 | Senhas em texto claro em `usuarios_credenciais`, por decisão de Peçanha de 19/08 | dump:2124 | D, P |
| H7 | Bucket `fotos` público: foto com GPS acessível por URL, caminhos previsíveis (`<prefixo>/<escolta_id>/<epoch>`), 12 pontos de `getPublicUrl` e nenhum `createSignedUrl` | ver 3.1 | A |
| H8 | Fotos 2 a 5 de cada ponto ficam no JSON `observacoes.foto_ids` e a policy `fotos_select` não as alcança; colega de efetivo e pontos de outra viatura da mesma escolta também ficam fora | dump:4249, `lib/pontos-controle.ts:108` | A |
| H9 | Mural: qualquer operador substitui a equipe escalada a qualquer momento antes do início, com motivo de 5 caracteres; `assumir_escolta` não confere perfil, acompanhantes nem viatura; `puxar_escolta`, `devolver_escolta` e `incluir_vigilante_na_minha_escolta` não deixam auditoria | dump:40-157, `components/escolta/dialogo-assumir-escolta.tsx:95-118` | C |
| H10 | Alerta de check-in que não fecha: o X só tira o aviso da memória da aba; a trava por janela de 5 min recria o aviso. O mesmo laço manda Telegram ao chat do CLIENTE, um por janela, por navegador aberto | `components/checkin-alert-provider.tsx:104-106`, `:133`, `:200` | B, F |
| H11 | Editar uma escolta religa o check-in: periodicidade nula vira 30 ao carregar a edição | `app/dashboard/escoltas/nova/page.tsx:475` | B |
| H12 | Presenças vão ao Telegram uma vez por aba aberta, sem trava | `components/telegram-notificacoes-provider.tsx:16`, `:58` | F |
| H13 | `/api/telegram`: qualquer usuário ativo envia texto livre ao chat central ou ao grupo do cliente de escolta visível; `texto_completo` e `descricao` sem escape HTML | `app/api/telegram/route.ts:88-101`, `:119` | A (escape); P (recorte de destino) |
| H14 | Tela `/dashboard/configuracoes/telegram-test` sem conferência de perfil | `app/dashboard/configuracoes/telegram-test/page.tsx` | A |
| H15 | Mapa: com escolta selecionada, a rota da Mapbox (Directions) é pedida cerca de 240 vezes por hora por aba, porque `carregar()` recria a escolta selecionada | `app/dashboard/mapa/page.tsx:288-291`, `:311-320`, `:563` | F (onda extra de baixo risco, Fase 2 item 2) |
| H16 | Coordenada da JAMEF gravada pela busca está a 1.327 m do lugar real (ver 2.4) | backup | D (onda D) |
| H17 | Combustível nunca é gravado: nenhuma tela grava `abastecimento_*`, e os Indicadores mostram custo zerado | consumidores D.2 | E |
| H18 | Edição pela central apaga o financeiro da escolta (o formulário sem a seção financeira grava nulo e zero) e pode deixar a escolta sem equipe (DELETE de viaturas permitido à central cascateia o efetivo, cujo INSERT a RLS nega à central) | `nova/page.tsx:567-569`, `:594-635`, dump:4148 | E (preservar o financeiro); P (efetivo pela central, decisão de permissão) |

### 1.3 Médio

| # | Achado | Evidência | Destino |
|---|---|---|---|
| M1 | Troca obrigatória de senha só existe na tela; o próprio usuário desliga a marca por PATCH | `app/dashboard/layout.tsx:123`, dump:2095 | P |
| M2 | Financeiro por RLS de linha: `valor_cobrado` das agendadas visível a todos pela API; valores do efetivo visíveis aos colegas | dump:4208, dump:4155 | P |
| M3 | `logs_auditoria` e `notificacoes` aceitam INSERT com `WITH CHECK (true)`: auditoria e notificação forjáveis. O app não grava em nenhuma das duas diretamente | dump:4292, dump:4312 | A |
| M4 | `fotos_atualizacao`: o autor reescreve GPS, horário e caminho da própria foto depois do fato | dump:4235 | P |
| M5 | Autoedição de `usuarios.cpf` combinada com `garantir_vinculo_operador` permite vincular a conta a vigilante sem vínculo | dump:699, dump:3110 | P |
| M6 | Histórico de status: 12 inserts da tela de detalhe ignoram o erro; status gravado e histórico perdido não avisa ninguém | `app/dashboard/escoltas/[id]/page.tsx:1145`, 1335, 1385, 1419, 1765, 2104, 2166, 2227, 2289, 2350, 2432, 2708 | F |
| M7 | XSS armazenado no popup do mapa (nome do cliente em HTML sem escape) | `app/dashboard/mapa/page.tsx:167-180` | A |
| M8 | Check-in pelo Campo e pelo Painel Guiado sem endereço por extenso | `app/dashboard/campo/page.tsx:1491-1497` | F |
| M9 | "Check-ins Realizados" nos Indicadores conta todos os pontos de controle | `app/dashboard/indicadores/page.tsx:428-449` | B |
| M10 | `assumir_escolta` põe a equipe inteira na primeira viatura e apaga o efetivo das demais | dump:149 | P (depende das gravações só na primeira viatura, fora deste lote pela regra 1.10) |
| M11 | Central: a tela oferece "Nova escolta", mas a RLS `escoltas_insert` recusa | `lib/permissions.ts:17`, dump:4201 | D, P |
| M12 | `logs_auditoria` lido só pela tela de Auditoria, com rótulos crus para as ações do mural | `app/dashboard/auditoria/page.tsx:33-56` | C (tela Substituições) |

### 1.4 Baixo

| # | Achado | Evidência | Destino |
|---|---|---|---|
| B1 | `impedir_edicao_por_operador` com EXECUTE para `anon` (o teste `02_rls_por_perfil.sql` acusa) e cinco funções de trigger sem REVOKE de PUBLIC | dump:4657 | A |
| B2 | `search_path` sem `pg_temp` em 4 funções SECURITY DEFINER | dump | A |
| B3 | `vw_operador_sem_vinculo` com SELECT para `anon` e `authenticated` | dump:5126 | A |
| B4 | `pontos_insert` não confere `lancado_por` | dump:4359 | P |
| B5 | Rotas órfãs: `/dashboard/clientes`, `/dashboard/veiculos`, `/dashboard/vigilantes`, `/dashboard/configuracoes/telegram-test` | qualidade 2 | P (reconferir antes de apagar, como já está em `docs/12` 4.7) |
| B6 | Código morto: `lib/telegram.ts`, `hooks/useEscolta.ts`, `components/layout/index.tsx`, `components/ui/em-breve.tsx`, `utils/constants.ts`, `podeTransicionar`; `@mapbox/search-js-core` sem uso | qualidade 3 | P |
| B7 | Arquivos acima de 1.000 linhas: detalhe (5.571), Campo (2.436), Indicadores (1.679), Relatórios (1.369), Nova (1.350), Usuários (1.118), Notificações (1.006) | `wc -l` | P (decomposição do detalhe proibida neste lote) |
| B8 | Dependências incoerentes: `eslint-config-next` 15 com Next 14, `@types/react` 19 com React 18, `@tailwindcss/postcss` 4 sem uso | `package.json` | P |
| B9 | `docs/03` desatualizado (33 tabelas, 70 policies, 19 funções, histórico em dobro como atual, APIs sem autenticação, middleware desligado) | `docs/03` | F (documentação) |
| B10 | A remoção da trigger de histórico em dobro não está versionada: recriar o banco pelas migrations a traria de volta | dump:1240-1261 | F (migration de referência) |

## 2. Medidas

### 2.1 Mural (linha de base para comparar depois)

Fonte: `logs_auditoria` (só `assumir_escolta` audita).

| Data (Brasília) | Ação | Escolta | Em relação a `data_hora_prevista` |
|---|---|---|---|
| 21/09 20:02 | substituição de equipe | ESC-2026-0001 | 2 min depois |
| 21/09 20:03 | assumiu do mural | ESC-2026-0001 | 3 min depois |
| 01/10 20:40 | assumiu do mural | ESC-2026-0007 | 19 min antes |
| 06/10 20:56 | assumiu do mural | ESC-2026-0009 | 26 min depois |
| 06/10 21:04 | substituição de equipe | ESC-2026-0008 | 64 min depois |
| 08/10 10:52 | assumiu do mural | ESC-2026-0014 | 22 min depois |

Substituições: setembro 1, outubro 1 (até 08/10), as duas pelo mesmo operador e as duas depois do horário previsto, com a escolta ainda agendada. A trava T1 (janela de 60 min antes) não impediria nenhuma delas; o que as limita é T2 (presença confirmada) e T3 (aprovação ou tempo limite). Puxadas sem auditoria não entram na conta.

### 2.2 Escoltas em status de rua sem finalização

| Código | Status | Previsto (Brasília) |
|---|---|---|
| ESC-2026-0001 | em_transito_retorno | 21/09 20:00 |
| ESC-2026-0007 | em_andamento | 01/10 21:00 |
| ESC-2026-0009 | em_transito_destino | 06/10 20:30 |
| ESC-2026-0014 | em_transito_destino | 08/10 10:30 |

Agendadas com horário vencido: ESC-2026-0006 (01/10 20:00), ESC-2026-0008 (06/10 20:00), ESC-2026-0012 (07/10 22:30), ESC-2026-0013 (08/10 09:00). Escoltas abertas (agendada ou de rua) com `periodicidade_checkin_min` preenchida: 8 de 8. ESC-2026-0001 e ESC-2026-0007 não são alteradas por este lote além da periodicidade (decisão 4).

### 2.3 Outros dados

1. Operadores sem vínculo em `vigilantes`: 0.
2. Histórico de status: 56 linhas, nenhum par (escolta, status) repetido, nenhuma linha sem autor. A trigger `tr_registrar_historico_status` não existe mais em produção (função marcada como obsoleta, dump:1240-1261), então o dobro descrito em `docs/03` não acontece hoje.
3. Usuários: 11 operadores, 1 gestor, 2 administradores. `usuarios_credenciais`: 5 senhas em texto claro (ver H6).

### 2.4 Geolocalização (M1)

1. JAMEF: 12 das 14 escoltas usam como destino a coordenada `-22.795758, -43.335469`, devolvida pela Mapbox v5 para "Estrada Arthur Antônio Sendas 999, Parque Araruama" (Bruno informou "Av. Arthur Antônio Sendas, 999, Parque Santana").
2. Os 5 pontos do tipo origem registrados na JAMEF com precisão de até 15 m formam um grupo com dispersão máxima de 16 m, centrado em `-22.799521, -43.347756`, a 1.327 m da coordenada geocodificada.
3. Sede: 11 pontos de base com precisão de até 15 m, centro em `-22.918625, -43.362670`, a 29 m da coordenada geocodificada do número 204.
4. Conclusão: na JAMEF o erro é da coordenada que a busca devolve, não do GPS. O rótulo reverso não é gravado pelos pontos do Campo, e os pontos da tela de detalhe perto da JAMEF também não trazem endereço; não há dado para medir o "outro município" do rótulo.
5. Sem token da Mapbox na VPS, a troca de API não pôde ser medida; pela decisão 7, a API fica como está.

## 3. Mapa dos consumidores das regras alteradas

### 3.1 Fotos (onda A)

| # | Local | Uso |
|---|---|---|
| 1 | `app/dashboard/escoltas/[id]/page.tsx:897` | `getFotoUrl` da timeline, galeria e finalização |
| 2 | `app/dashboard/escoltas/[id]/page.tsx:1913` | foto do `sendPhoto` no Telegram |
| 3 | `app/dashboard/escoltas/[id]/print/page.tsx:224`, `:260` | impressão e relatório ao cliente |
| 4 | `app/dashboard/campo/page.tsx:1201`, `:1390`, `:1503` | Telegram do Campo e do Modo Guiado |
| 5 | `app/dashboard/notificacoes/page.tsx:177` | miniaturas do feed |
| 6 | `components/telegram-notificacoes-provider.tsx:37` | presença ao Telegram |
| 7 | `app/dashboard/clientes/page.tsx:177-182` | logo do cliente gravada como URL pública absoluta |

O mapa e o PDF de relatórios não usam foto.

### 3.2 Check-in periódico (onda B)

`lib/checkin.ts`, `components/checkin-alert-provider.tsx` (montado em `app/dashboard/layout.tsx:208`), Campo `:430-450`, `:1451-1530`, `:1641-1670`, `components/campo-guiado/painel-guiado.tsx:477-657`, detalhe `:1086-1107`, `:2005-2064`, `:3455-3508`, Nova `:378`, `:475`, `:566`, `:951-969`, Indicadores `:440-450`, `:890-896`, `app/api/telegram/route.ts:38`, `docs/09`.

### 3.3 Mural (onda C)

`app/dashboard/escoltas/page.tsx:55-197`, `:282-305`, `:406-427`, `:778-797`; `components/escolta/dialogo-assumir-escolta.tsx`; Painel Guiado `:402-437`; Campo `:1769`; `app/dashboard/auditoria/page.tsx`; RPCs `assumir_escolta`, `puxar_escolta`, `devolver_escolta`, `equipe_escalada`, `incluir_vigilante_na_minha_escolta`, `vigilantes_para_escala`. Não existe tabela de configurações nem envio de Telegram de servidor sem sessão.

### 3.4 Endereço (onda D)

Autocomplete Mapbox v5 em Nova `:124-326` (edição pela mesma tela, `?editar=`), colunas `origem_*` e `destino_*` NOT NULL, `reverseGeocode` no detalhe `:1866-1877`, mapbox-gl só em `app/dashboard/mapa/page.tsx`. Locais salvos que gravem nas mesmas colunas não exigem mudança nos leitores (mapa, detalhe, relatórios, Indicadores, impressão, PDF).

### 3.5 Combustível (onda E)

Leitores: detalhe `:4090-4103` (aba Veículos, sem trava de perfil) e `:4137-4145` (Financeiro), Indicadores `:419-420`, `:600-624`, PDF `:390-391`, `:431`, `:460`. Nenhum gravador. A edição apaga e recria `escolta_veiculos` (Nova `:594-620`), por isso o lançamento não pode ficar no formulário de edição.

## 4. Linha de base de qualidade

| Verificação | Resultado em `f6cdf59` |
|---|---|
| `npm run type-check` | passou, 0 erros |
| `npm run lint` | passou, 0 erros, 26 avisos (24 `no-unused-vars`, 2 `react-hooks/exhaustive-deps`) |
| `npm run build` | passou, 31 páginas, mesmos 26 avisos |
| `npm audit --omit=dev` | 1 crítico (`next`), 3 altos (`postcss`, `nanoid`, `source-map-js`) |
| Testes de banco existentes (homologação) | `02_rls_por_perfil.sql`: tudo correto, exceto `impedir_edicao_por_operador` executável por `anon` (B1). `01_fluxo_status.sql` depende de cliente e viatura cadastrados |

## 5. Operação

1. Telegram por navegador aberto: alerta de check-in (H10) e presenças (H12). Correção na onda F, com fila de avisos no banco e envio único pelo servidor.
2. Check-in pelo Campo sem endereço (M8): onda F.
3. Consumo da Mapbox: busca de endereço com debounce na digitação (Nova), geocodificação reversa por ação no detalhe, tiles do mapa e Directions em laço no mapa (H15).
