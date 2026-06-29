export function printEscolta(escoltaId: string) {
  const url = `/dashboard/escoltas/${escoltaId}/print`

  const existing = document.getElementById('__escolta_print_frame')
  if (existing) existing.remove()

  const iframe = document.createElement('iframe')
  iframe.id = '__escolta_print_frame'
  iframe.src = url
  // Invisible but must have real dimensions for print to work correctly
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

  document.body.appendChild(iframe)

  iframe.addEventListener('load', () => {
    // Wait for React to hydrate and render the content
    setTimeout(() => {
      try {
        iframe.contentWindow?.focus()
        iframe.contentWindow?.print()
      } catch {
        // Fallback: nova aba
        window.open(url, '_blank')
      }
      // Limpar após o diálogo fechar
      setTimeout(() => iframe.remove(), 5000)
    }, 1200)
  })
}
