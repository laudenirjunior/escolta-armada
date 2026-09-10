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

/** Linhas do carimbo. Exportada para a tela poder mostrar o mesmo texto na miniatura. */
export function linhasDoCarimbo(dados: DadosCarimbo): string[] {
  const quando = new Date(dados.timestamp).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })
  const onde = dados.gps
    ? `${dados.gps.lat.toFixed(5)}, ${dados.gps.lng.toFixed(5)}  (+-${Math.round(dados.gps.precisao)}m)`
    : 'SEM SINAL DE GPS'
  return [quando, onde]
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

    const canvas = document.createElement('canvas')
    canvas.width = bitmap.width
    canvas.height = bitmap.height
    const ctx = canvas.getContext('2d')
    if (!ctx) return { file, carimbado: false }

    ctx.drawImage(bitmap, 0, 0)

    const linhas = linhasDoCarimbo(dados)
    const corpo = Math.max(14, Math.floor(canvas.width * 0.022))
    ctx.font = `bold ${corpo}px monospace`
    ctx.textBaseline = 'alphabetic'

    const larguraTexto = Math.max(...linhas.map((l) => ctx.measureText(l).width))
    const margem = Math.max(8, Math.floor(corpo * 0.5))
    const alturaCaixa = corpo * (linhas.length + 0.8)
    const topoCaixa = canvas.height - alturaCaixa - margem

    ctx.fillStyle = 'rgba(0,0,0,0.55)'
    ctx.fillRect(margem, topoCaixa, larguraTexto + corpo, alturaCaixa)

    ctx.fillStyle = '#FFFFFF'
    linhas.forEach((linha, i) => {
      ctx.fillText(linha, margem + corpo * 0.5, topoCaixa + corpo * (i + 1.2))
    })

    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, 'image/jpeg', 0.92)
    )
    if (!blob) return { file, carimbado: false }

    const nome = file.name.replace(/\.[^.]+$/, '') + '.jpg'
    return { file: new File([blob], nome, { type: 'image/jpeg' }), carimbado: true }
  } catch {
    // Memoria insuficiente, formato que o navegador nao decodifica, canvas sujo por
    // origem cruzada. Em todos os casos a foto vale; o que nao vale e mentir sobre ela.
    return { file, carimbado: false }
  } finally {
    bitmap?.close()
  }
}
