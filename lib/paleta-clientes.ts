/**
 * Paleta fechada de cores de cliente (lote 2026-10, onda K; docs/14, seção 15).
 *
 * São 12 cores escuras o bastante para texto branco por cima (contraste de pelo menos
 * 4,5:1, conferido pelo teste da onda K) e distinguíveis entre si (distância CIE76 de
 * pelo menos 23 entre quaisquer duas). A mesma lista está no banco, na tabela
 * paleta_clientes da migration 216, cuja trigger normaliza qualquer cor gravada em
 * clientes.cor_destaque para a mais próxima desta paleta (a master grava cor livre e
 * continua funcionando). A cor não é exclusiva por cliente (decisão S6): a tela só avisa
 * quando a cor já está em uso por outro cliente ativo.
 *
 * Não é a paleta visual do app (regra 7 da seção 0): só a cor que identifica o cliente.
 * Este arquivo não importa nada, para o teste de contraste rodar direto no Node.
 */

export interface CorPaleta {
  cor: string
  nome: string
}

export const PALETA_CLIENTES: CorPaleta[] = [
  { cor: '#1D4ED8', nome: 'Azul' },
  { cor: '#15803D', nome: 'Verde' },
  { cor: '#B91C1C', nome: 'Vermelho' },
  { cor: '#A16207', nome: 'Mostarda' },
  { cor: '#7C3AED', nome: 'Violeta' },
  { cor: '#BE185D', nome: 'Rosa escuro' },
  { cor: '#4D7C0F', nome: 'Oliva' },
  { cor: '#475569', nome: 'Grafite' },
  { cor: '#1E3A8A', nome: 'Marinho' },
  { cor: '#86198F', nome: 'Ameixa' },
  { cor: '#115E59', nome: 'Petróleo' },
  { cor: '#6B4423', nome: 'Marrom' },
]

/** Cor padrão (cliente sem cor ou com texto que não é #rrggbb). Igual ao DEFAULT da coluna na 216. */
export const COR_PADRAO_CLIENTE = '#1D4ED8'

const HEX = /^#[0-9a-fA-F]{6}$/

function canal(c: number): number {
  const v = c / 255
  return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function rgbLinear(hex: string): [number, number, number] {
  return [1, 3, 5].map(i => canal(parseInt(hex.slice(i, i + 2), 16))) as [number, number, number]
}

/** Luminância relativa (WCAG 2.1). */
export function luminancia(hex: string): number {
  const [r, g, b] = rgbLinear(hex)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/** Contraste entre texto branco e a cor de fundo (WCAG 2.1). */
export function contrasteComBranco(hex: string): number {
  return 1.05 / (luminancia(hex) + 0.05)
}

/** Cor no espaço CIE Lab (D65), a mesma conta de lote_interno.cor_lab na 216. */
export function corLab(hex: string): [number, number, number] {
  const [r, g, b] = rgbLinear(hex)
  const x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
  const y = 0.2126 * r + 0.7152 * g + 0.0722 * b
  const z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
  const f = (t: number) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116)
  return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]
}

/** Distância CIE76 entre duas cores #rrggbb. */
export function distanciaCor(a: string, b: string): number {
  const [l1, a1, b1] = corLab(a)
  const [l2, a2, b2] = corLab(b)
  return Math.sqrt((l1 - l2) ** 2 + (a1 - a2) ** 2 + (b1 - b2) ** 2)
}

/**
 * Cor da paleta para mostrar: a própria, se já for da paleta; a mais próxima, se for
 * #rrggbb fora dela (cor gravada antes da 216); a padrão, para nulo ou texto inválido.
 * Mesma regra da trigger do banco, para a tela nunca mostrar cor fora da paleta.
 */
export function corDoCliente(cor: string | null | undefined): string {
  if (!cor || !HEX.test(cor.trim())) return COR_PADRAO_CLIENTE
  const c = cor.trim().toUpperCase()
  const igual = PALETA_CLIENTES.find(p => p.cor === c)
  if (igual) return igual.cor
  let melhor = PALETA_CLIENTES[0].cor
  let menor = Infinity
  for (const p of PALETA_CLIENTES) {
    const d = distanciaCor(c, p.cor)
    if (d < menor) { menor = d; melhor = p.cor }
  }
  return melhor
}

/** Nome da cor da paleta (para o seletor e para o aviso de cor repetida). */
export function nomeDaCor(cor: string | null | undefined): string {
  const c = corDoCliente(cor)
  return PALETA_CLIENTES.find(p => p.cor === c)?.nome ?? c
}
