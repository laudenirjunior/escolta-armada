async (page) => {
  // O executor substitui este marcador pelo JavaScript transpilado do módulo real.
  // Assim o teste roda no Chromium sem manter uma cópia da implementação.
  const modulo = '__CARIMBO_FOTO_MODULO__'

  await page.goto('about:blank')
  const resultado = await page.evaluate(async (codigo) => {
    const urlModulo = URL.createObjectURL(new Blob([codigo], { type: 'text/javascript' }))
    try {
      const { aplicarCarimbo } = await import(urlModulo)
      const origem = document.createElement('canvas')
      origem.width = 4000
      origem.height = 3000
      const ctx = origem.getContext('2d')
      if (!ctx) throw new Error('Canvas de teste indisponível.')

      const gradiente = ctx.createLinearGradient(0, 0, origem.width, origem.height)
      gradiente.addColorStop(0, '#17213b')
      gradiente.addColorStop(0.5, '#c7d4e8')
      gradiente.addColorStop(1, '#5c371f')
      ctx.fillStyle = gradiente
      ctx.fillRect(0, 0, origem.width, origem.height)
      ctx.strokeStyle = 'rgba(255,255,255,0.35)'
      ctx.lineWidth = 5
      for (let x = -origem.height; x < origem.width; x += 48) {
        ctx.beginPath()
        ctx.moveTo(x, 0)
        ctx.lineTo(x + origem.height, origem.height)
        ctx.stroke()
      }

      const png = await new Promise((resolve, reject) =>
        origem.toBlob((blob) => blob ? resolve(blob) : reject(new Error('PNG de teste não gerado.')), 'image/png')
      )
      const arquivo = new File([png], 'foto-4000x3000.png', { type: 'image/png' })
      const saida = await aplicarCarimbo(arquivo, {
        timestamp: '2026-11-06T21:17:00.000Z',
        gps: { lat: -23.55052, lng: -46.63331, precisao: 8 },
      })
      const imagem = await createImageBitmap(saida.file)
      const medicao = {
        carimbado: saida.carimbado,
        largura: imagem.width,
        altura: imagem.height,
        bytes: saida.file.size,
        tipo: saida.file.type,
        menor: null,
      }
      imagem.close()

      const origemMenor = document.createElement('canvas')
      origemMenor.width = 800
      origemMenor.height = 600
      const ctxMenor = origemMenor.getContext('2d')
      if (!ctxMenor) throw new Error('Canvas menor indisponível.')
      ctxMenor.fillStyle = '#53648A'
      ctxMenor.fillRect(0, 0, origemMenor.width, origemMenor.height)
      const pngMenor = await new Promise((resolve, reject) =>
        origemMenor.toBlob((blob) => blob ? resolve(blob) : reject(new Error('PNG menor não gerado.')), 'image/png')
      )
      const saidaMenor = await aplicarCarimbo(
        new File([pngMenor], 'foto-800x600.png', { type: 'image/png' }),
        { timestamp: '2026-11-06T21:17:00.000Z', gps: null },
      )
      const imagemMenor = await createImageBitmap(saidaMenor.file)
      medicao.menor = { largura: imagemMenor.width, altura: imagemMenor.height }
      imagemMenor.close()
      return medicao
    } finally {
      URL.revokeObjectURL(urlModulo)
    }
  }, modulo)

  if (!resultado.carimbado) throw new Error('A saída declarou carimbado=false.')
  if (Math.max(resultado.largura, resultado.altura) !== 1600) {
    throw new Error(`Lado maior esperado: 1600 px; recebido: ${resultado.largura} x ${resultado.altura}.`)
  }
  if (resultado.bytes >= 500 * 1024) {
    throw new Error(`Saída esperada abaixo de 500 KB; recebido: ${resultado.bytes} bytes.`)
  }
  if (resultado.tipo !== 'image/jpeg') throw new Error(`Tipo esperado: image/jpeg; recebido: ${resultado.tipo}.`)
  if (resultado.menor?.largura !== 800 || resultado.menor?.altura !== 600) {
    throw new Error(`Imagem menor não pode ser ampliada; recebido: ${JSON.stringify(resultado.menor)}.`)
  }

  return resultado
}
