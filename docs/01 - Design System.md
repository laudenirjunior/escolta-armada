# Design System

## A paleta em uso é a Navy

O arquivo `design_system.md` na pasta acima descreve **outro produto** (a plataforma de Lançamentos de Extras), com accent dourado e glassmorphism. O escolta-armada usa uma paleta própria, militar, definida em [`app/globals.css`](../app/globals.css).

| Token | Valor | Uso |
|---|---|---|
| `--background` | `#EEF0F5` | Fundo da página |
| `--primary` | `#1A294A` | Navy, elemento principal |
| `--accent` | `#53648A` | Steel, realce |
| `--khaki` | `#9F906D` | Realce secundário |
| `--surface` | `#ffffff` | Card, tabela, modal |
| `--text-primary` | `#0E1A33` | Texto |
| `--text-secondary` | `#5A6A80` | Apoio |
| `--status-success` | `#1E7C52` | |
| `--status-warning` | `#8B6914` | |
| `--status-error` | `#B83832` | |

Cantos praticamente retos (`0px` a `1px`), tipografia condensada em caixa alta para rótulos, sombras discretas.

## Situação real, sem maquiagem

O sistema tem **duas paletas convivendo**. A teal legada (`#4A90A4`, `#6B7E8A`, `#1E2D35`) aparece cerca de 525 vezes, principalmente em `campo`, `usuarios`, `configuracoes` e `mapa`. A navy atual aparece cerca de 375. Houve um rebrand que não terminou.

Há cerca de **1840 valores hexadecimais escritos direto no JSX** e **zero uso de `var(--token)`** em arquivos `.tsx`. Os tokens existem e quase não são consumidos.

Boa parte do CSS de componente em `globals.css` é morta: `.btn-danger`, `.badge-khaki`, `.kpi-bar-track`, `.sidebar-item-active`, `.status-dot`, `.section-label`, `.card-bezel`, `.scanline`. As páginas reimplementam inline o que já existe pronto.

`components/ui/` tem 11 primitivos e é importado por poucos arquivos. `clsx`, `tailwind-merge` e `class-variance-authority` estão instalados e nunca foram importados.

**Isso não foi corrigido**, e é o maior item da varredura página a página que ficou pendente.

## O que foi acrescentado

| Arquivo | Papel |
|---|---|
| [`app/print.css`](../app/print.css) | Regras de impressão para todas as páginas |
| [`lib/fluxo-escolta.ts`](../lib/fluxo-escolta.ts) | Fonte única de status, rótulo, classe de badge e etapa |

`CLASSE_BADGE_STATUS` no `lib/fluxo-escolta.ts` liga cada status à classe de badge do design system, em vez de cada tela escolher sua cor.

## Acessibilidade

O ponto bom é o `*:focus-visible` global em `globals.css`, com anel visível.

O resto está fraco e **não foi corrigido**: 6 `aria-label` no sistema inteiro, 2 `htmlFor`, nenhuma barra de abas com `role="tablist"`, modais sem foco preso nem tecla Escape, `<div onClick>` no lugar de botão, texto de 8 a 9px, e contraste reprovando AA em rótulos de KPI. O formulário de usuário refeito já saiu com `htmlFor`, como referência do padrão a seguir.
