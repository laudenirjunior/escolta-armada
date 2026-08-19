# Guia de Impressão

## Como está montado

| Camada | Arquivo | Alcance |
|---|---|---|
| Regras gerais | [`app/print.css`](../app/print.css) | **Todas** as páginas, via import no `globals.css` |
| Relatório da escolta | `app/dashboard/escoltas/[id]/print/page.tsx` | Ajustes próprios por cima |
| Relatório composto | `app/dashboard/relatorios/pdf/page.tsx` | Ajustes próprios por cima |

Antes só existiam os dois blocos inline. Imprimir qualquer outra tela saía com sidebar, topbar e bottom nav no papel.

## O que a folha global resolve

- **Página**: A4 retrato, margem `14mm 12mm 18mm`. A margem inferior é maior de propósito, para reservar espaço ao rodapé fixo. Sem ela o rodapé sobrepõe as últimas linhas das tabelas longas.
- **Paisagem**: classe `.print-landscape` no container da seção, para tabelas largas.
- **Cor**: `print-color-adjust: exact` em `*`, não só em `body`. Descendente com fundo próprio não herda a diretiva, e era por isso que fundo de badge e de cabeçalho de tabela sumiam.
- **Tabelas**: `thead` repetido em toda página, linha nunca partida ao meio.
- **Órfãos**: título com `break-after: avoid` para não ficar sozinho no pé da página; `orphans` e `widows` em 3.
- **Rolagem**: todo container com `overflow` é aberto, senão só a primeira tela do conteúdo sai no papel.
- **Links**: endereço externo impresso junto, porque no papel o link se perde.
- **Numeração**: `counter(page)` e `counter(pages)` nas classes `.print-pagina` e `.print-total`.

## Classes utilitárias

| Classe | Efeito |
|---|---|
| `.no-print` | Some na impressão |
| `.print-only` | Só aparece na impressão |
| `.print-keep` | Botão que continua visível (padrão é esconder botões) |
| `.print-landscape` | Seção em paisagem |
| `.print-cabecalho` / `.print-rodape` | Faixa fixa repetida em toda página |

## Ao mexer

Confirme que as regras chegaram ao CSS final do build, e não foram descartadas pelo `@import`:

```bash
grep -c "@media print" .next/static/css/*.css
```
