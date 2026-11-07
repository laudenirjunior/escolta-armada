/**
 * Carimbo embutido na imagem: data, hora e coordenada desenhadas nos pixels.
 *
 * POR QUE ISTO EXISTE
 *
 * A coluna `fotos.carimbo_aplicado` mentia nos dois sentidos. A tela de Campo gravava
 * `true` em toda foto e nunca carimbava nenhuma: ela usa `<input type="file"
 * capture="environment">`, a camera nativa, que devolve o arquivo pronto sem passo de
 * desenho. A tela de detalhe gravava `false` mesmo quando carimbava, no caminho de
 * video ao vivo. Ou seja, a coluna nao servia para responder a unica pergunta que
 * justifica existir: esta imagem carrega a prova dentro dela.
 *
 * O metadado no banco continua sendo a fonte precisa de GPS e horario. O carimbo serve
 * para quando a imagem sai do sistema: enviada no Telegram, colada num PDF, impressa
 * ou reencaminhada. Fora do banco, o metadado nao vai junto.
 *
 * O QUE ESTA FUNCAO NAO PROMETE
 *
 * Carimbo desenhado nao e assinatura: quem tiver a imagem pode editar o texto. Ele
 * dificulta a confusao honesta, nao a fraude deliberada. Se um dia isso precisar valer
 * como prova contra adulteracao, o caminho e hash no momento do upload, nao pixel.
 *
 * FALHA E DECLARADA, NUNCA ENGOLIDA
 *
 * Aparelho antigo com foto de 12 MP pode estourar a memoria do canvas. Quando isso
 * acontece a funcao devolve o arquivo original com `carimbado: false`, e quem grava
 * registra o `false`. Foto sem carimbo e aceitavel; banco afirmando carimbo que nao
 * existe, nao.
 */

export interface DadosCarimbo {
  /** ISO do momento da captura, nao o do upload. */
  timestamp: string
  gps: { lat: number; lng: number; precisao: number } | null
}

export interface ResultadoCarimbo {
  file: File
  carimbado: boolean
}

export interface ResultadoImagemCarimbada {
  blob: Blob | null
  carimbado: boolean
  largura: number
  altura: number
}

export const LADO_MAXIMO_FOTO = 1600
export const QUALIDADE_JPEG_FOTO = 0.7

/** Calcula a redução sem ampliar imagens que já cabem no limite. */
export function dimensoesDaFoto(largura: number, altura: number): { largura: number; altura: number } {
  const ladoMaior = Math.max(largura, altura)
  const escala = ladoMaior > LADO_MAXIMO_FOTO ? LADO_MAXIMO_FOTO / ladoMaior : 1
  return {
    largura: Math.max(1, Math.round(largura * escala)),
    altura: Math.max(1, Math.round(altura * escala)),
  }
}

/** Linhas do carimbo. Exportada para a tela poder mostrar o mesmo texto na miniatura. */
export function linhasDoCarimbo(dados: DadosCarimbo): string[] {
  const quando = new Date(dados.timestamp).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })
  const onde = dados.gps
    ? `${dados.gps.lat.toFixed(5)}, ${dados.gps.lng.toFixed(5)}  (+-${Math.round(dados.gps.precisao)}m)`
    : 'SEM SINAL DE GPS'
  return [quando, onde]
}

/**
 * Caminho único de redução, carimbo e conversão para JPEG.
 *
 * É exportado para a captura por vídeo ao vivo usar exatamente o mesmo limite e a
 * mesma qualidade do seletor de arquivos. Falhas são explícitas: blob nulo e
 * `carimbado: false`.
 */
export async function reduzirECarimbarImagem(
  imagem: CanvasImageSource,
  larguraOriginal: number,
  alturaOriginal: number,
  dados: DadosCarimbo
): Promise<ResultadoImagemCarimbada> {
  const dimensoes = dimensoesDaFoto(larguraOriginal, alturaOriginal)

  try {
    if (typeof document === 'undefined') {
      return { blob: null, carimbado: false, ...dimensoes }
    }

    const canvas = document.createElement('canvas')
    canvas.width = dimensoes.largura
    canvas.height = dimensoes.altura
    const ctx = canvas.getContext('2d')
    if (!ctx) return { blob: null, carimbado: false, ...dimensoes }

    ctx.drawImage(imagem, 0, 0, canvas.width, canvas.height)

    const linhas = linhasDoCarimbo(dados)
    const corpo = Math.max(14, Math.floor(canvas.width * 0.022))
    ctx.font = `bold ${corpo}px monospace`
    ctx.textBaseline = 'alphabetic'

    const larguraTexto = Math.max(...linhas.map((linha) => ctx.measureText(linha).width))
    const margem = Math.max(8, Math.floor(corpo * 0.5))
    const alturaCaixa = corpo * (linhas.length + 0.8)
    const topoCaixa = canvas.height - alturaCaixa - margem

    ctx.fillStyle = 'rgba(0,0,0,0.55)'
    ctx.fillRect(margem, topoCaixa, larguraTexto + corpo, alturaCaixa)

    ctx.fillStyle = '#FFFFFF'
    linhas.forEach((linha, indice) => {
      ctx.fillText(linha, margem + corpo * 0.5, topoCaixa + corpo * (indice + 1.2))
    })

    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, 'image/jpeg', QUALIDADE_JPEG_FOTO)
    )
    return { blob, carimbado: blob !== null, ...dimensoes }
  } catch {
    return { blob: null, carimbado: false, ...dimensoes }
  }
}

export async function aplicarCarimbo(file: File, dados: DadosCarimbo): Promise<ResultadoCarimbo> {
  // Fora do navegador nao ha canvas. Devolve o original sem afirmar carimbo.
  if (typeof document === 'undefined' || typeof createImageBitmap === 'undefined') {
    return { file, carimbado: false }
  }

  let bitmap: ImageBitmap | null = null
  try {
    // `imageOrientation: 'from-image'` respeita o EXIF. Sem isso, foto tirada em pe no
    // celular chega deitada no canvas, e o carimbo sai girado junto.
    bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })

    const resultado = await reduzirECarimbarImagem(bitmap, bitmap.width, bitmap.height, dados)
    if (!resultado.blob || !resultado.carimbado) return { file, carimbado: false }

    const nome = file.name.replace(/\.[^.]+$/, '') + '.jpg'
    return {
      file: new File([resultado.blob], nome, { type: 'image/jpeg' }),
      carimbado: true,
    }
  } catch {
    // Memoria insuficiente, formato que o navegador nao decodifica, canvas sujo por
    // origem cruzada. Em todos os casos a foto vale; o que nao vale e mentir sobre ela.
    return { file, carimbado: false }
  } finally {
    bitmap?.close()
  }
}
