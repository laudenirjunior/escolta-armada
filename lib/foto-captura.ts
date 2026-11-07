/**
 * Marca, em memória, os arquivos de foto que saíram do carimbo (onda M, docs/12 item 2.1).
 *
 * A tela de detalhe passa as fotos como File[] do CameraInput até o uploadFoto. Antes ela
 * gravava carimbo_aplicado = false sempre, mesmo quando carimbava. Agora o CameraInput marca
 * o File que saiu do carimbo e o uploadFoto pergunta aqui. WeakSet: o arquivo descartado sai
 * da memória sozinho. Arquivo que não passou pelo carimbo (falha declarada) responde false.
 */
const carimbadas = new WeakSet<Blob>()

export function marcarCarimbada(arquivo: Blob): void {
  carimbadas.add(arquivo)
}

export function foiCarimbada(arquivo: Blob | null | undefined): boolean {
  return !!arquivo && carimbadas.has(arquivo)
}
