/**
 * Abre o relatorio da escolta num iframe oculto e imprime.
 *
 * Havia dois defeitos aqui, e os dois pioraram quando o relatorio passou a trazer
 * ate 5 fotos por ponto de controle:
 *
 * 1. DOIS DIALOGOS. Esta funcao chamava `contentWindow.print()` e a propria pagina
 *    de impressao tambem chamava `window.print()`, entao o usuario via a caixa de
 *    impressao duas vezes.
 * 2. DISPARO NO ESCURO. O print saia 1200 ms depois do load, sem esperar imagem
 *    nenhuma, e o iframe era removido 5 segundos depois. Com dezenas de megabytes
 *    de foto para baixar, o PDF saia com as molduras em branco e sem erro visivel.
 *
 * Agora quem decide a hora e a pagina de impressao, que e quem sabe se as imagens
 * terminaram de decodificar. Ela avisa por postMessage e esta funcao apenas espera
 * para remover o iframe. O teto existe para o caso de a pagina nunca responder.
 */

const SINAL_PRONTO = 'escolta-print-pronto'
const TETO_MS = 25000

export function printEscolta(escoltaId: string) {
  const url = `/dashboard/escoltas/${escoltaId}/print`

  const existing = document.getElementById('__escolta_print_frame')
  if (existing) existing.remove()

  const iframe = document.createElement('iframe')
  iframe.id = '__escolta_print_frame'
  iframe.src = url
  // Invisivel, mas precisa de dimensao real para a impressao paginar certo.
  iframe.style.cssText = [
    'position:fixed',
    'top:0',
    'left:0',
    'width:100vw',
    'height:100vh',
    'border:none',
    'z-index:-9999',
    'opacity:0',
    'pointer-events:none',
  ].join(';')

  let encerrado = false
  let tetoId: ReturnType<typeof setTimeout>

  const encerrar = () => {
    if (encerrado) return
    encerrado = true
    clearTimeout(tetoId)
    window.removeEventListener('message', aoReceber)
    // Folga para o dialogo do navegador terminar antes de o iframe sumir.
    setTimeout(() => iframe.remove(), 5000)
  }

  const aoReceber = (ev: MessageEvent) => {
    // Same-origin apenas: o iframe carrega uma rota do proprio app.
    if (ev.origin !== window.location.origin) return
    if (ev.data?.tipo === SINAL_PRONTO) encerrar()
  }

  window.addEventListener('message', aoReceber)

  // Rede de seguranca: se a pagina nunca sinalizar (erro de carregamento, foto
  // travada alem do teto dela), imprime assim mesmo em vez de deixar o usuario
  // olhando para nada. Um relatorio incompleto e melhor que relatorio nenhum.
  tetoId = setTimeout(() => {
    try {
      iframe.contentWindow?.focus()
      iframe.contentWindow?.print()
    } catch {
      window.open(url, '_blank')
    }
    encerrar()
  }, TETO_MS)

  iframe.addEventListener('error', () => {
    clearTimeout(tetoId)
    window.removeEventListener('message', aoReceber)
    iframe.remove()
    window.open(url, '_blank')
  })

  document.body.appendChild(iframe)
}
