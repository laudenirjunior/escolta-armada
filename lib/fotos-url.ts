/**
 * URL das fotos do bucket `fotos`.
 *
 * Lote 2026-10, onda A: o bucket deixou de ser público (migration 200). Toda tela e todo
 * envio ao Telegram passam a usar URL assinada, que só é gerada para quem tem direito à
 * escolta (policy `fotos_leitura_autenticada`, migration 198). O servidor do Telegram
 * baixa a imagem no momento do envio, então a validade curta não atrapalha.
 */
import type { SupabaseClient } from '@supabase/supabase-js'

const BUCKET = 'fotos'

/** Validade padrão das URLs nas telas e no Telegram. */
export const VALIDADE_TELA_S = 60 * 60
/** Impressão e PDF: tempo para abrir, conferir e imprimir. */
export const VALIDADE_IMPRESSAO_S = 2 * 60 * 60

/**
 * Caminho do arquivo dentro do bucket. Aceita o caminho puro ou uma URL pública antiga
 * do próprio bucket (logos gravadas antes do lote). Devolve null para URL de outro lugar.
 */
export function caminhoDoArquivo(valor: string | null | undefined): string | null {
  if (!valor) return null
  if (!/^https?:\/\//i.test(valor)) return valor.replace(/^\/+/, '')
  const marca = `/storage/v1/object/public/${BUCKET}/`
  const i = valor.indexOf(marca)
  if (i >= 0) return decodeURIComponent(valor.slice(i + marca.length).split('?')[0])
  const marcaAssinada = `/storage/v1/object/sign/${BUCKET}/`
  const j = valor.indexOf(marcaAssinada)
  if (j >= 0) return decodeURIComponent(valor.slice(j + marcaAssinada.length).split('?')[0])
  return null
}

/** URL externa (fora do bucket), que continua sendo usada como veio. */
function urlExterna(valor: string): boolean {
  return /^https?:\/\//i.test(valor) && caminhoDoArquivo(valor) === null
}

/**
 * Gera URLs assinadas em lote, uma única chamada por tela. Devolve um mapa
 * caminho -> URL. Caminhos sem permissão ou inexistentes ficam fora do mapa.
 */
export async function urlsAssinadas(
  sb: SupabaseClient,
  valores: Array<string | null | undefined>,
  validadeS: number = VALIDADE_TELA_S,
): Promise<Record<string, string>> {
  const mapa: Record<string, string> = {}
  const caminhos = new Set<string>()
  for (const v of valores) {
    if (!v) continue
    if (urlExterna(v)) { mapa[v] = v; continue }
    const c = caminhoDoArquivo(v)
    if (c) caminhos.add(c)
  }
  if (caminhos.size === 0) return mapa
  const lista = Array.from(caminhos)
  const { data, error } = await sb.storage.from(BUCKET).createSignedUrls(lista, validadeS)
  if (error || !data) return mapa
  for (const item of data) {
    if (item.path && item.signedUrl && !item.error) mapa[item.path] = item.signedUrl
  }
  return mapa
}

/** Procura no mapa de `urlsAssinadas` a URL de um caminho ou URL antiga. */
export function urlDoMapa(mapa: Record<string, string>, valor: string | null | undefined): string | null {
  if (!valor) return null
  if (mapa[valor]) return mapa[valor]
  const c = caminhoDoArquivo(valor)
  return c ? mapa[c] ?? null : null
}

/** Uma URL assinada. Para várias fotos na mesma tela, prefira `urlsAssinadas`. */
export async function urlAssinada(
  sb: SupabaseClient,
  valor: string | null | undefined,
  validadeS: number = VALIDADE_TELA_S,
): Promise<string | null> {
  const mapa = await urlsAssinadas(sb, [valor], validadeS)
  return urlDoMapa(mapa, valor)
}
