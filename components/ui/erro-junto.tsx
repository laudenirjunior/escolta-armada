'use client'

/**
 * Onda O (M9): erro de validação junto do botão de confirmar.
 *
 * No teste de 07/11 o aviso aparecia no topo do quadro, longe do botão, e na janela longa
 * ninguém via. Agora a mensagem fica logo acima dos botões e a janela rola até o campo com
 * problema (campoComProblema), com foco nele quando dá.
 */
export function ErroJuntoAoBotao({ texto, className = '' }: { texto: string | null | undefined; className?: string }) {
  if (!texto) return null
  return (
    <p role="alert" data-erro-junto className={`text-xs p-3 font-semibold ${className}`}
      style={{ backgroundColor: '#FEF0EE', color: '#B83832', border: '1px solid #F2C9C5' }}>
      {texto}
    </p>
  )
}

function visivel(el: Element): el is HTMLElement {
  const h = el as HTMLElement
  return !!(h.offsetParent || h.getClientRects().length)
}

/**
 * O campo a que a mensagem se refere, dentro do escopo (a janela aberta ou a página): foto
 * que falta, KM, texto obrigatório ou a escolha da viatura. Sem palpite seguro, o próprio
 * aviso junto do botão.
 */
export function campoComProblema(escopo: ParentNode, mensagem: string): HTMLElement | null {
  const todos = (sel: string) => Array.from(escopo.querySelectorAll(sel)).filter(visivel)
  const vazio = (el: HTMLElement) => !((el as HTMLInputElement).value ?? '').trim()
  let alvo: HTMLElement | undefined
  if (/foto/i.test(mensagem)) alvo = todos('[data-campo-fotos][data-vazio="true"]')[0]
  else if (/\bKM\b/.test(mensagem)) alvo = todos('input[type=number], input[inputmode=numeric]').find(vazio) ?? todos('input[type=number]')[0]
  else if (/viatura deste|escolha a viatura/i.test(mensagem)) alvo = todos('select')[0]
  else if (/observa|relat[oó]rio|justific|descreva|complete a sugest|motivo/i.test(mensagem)) alvo = todos('textarea').find(vazio) ?? todos('textarea')[0]
  return alvo ?? (todos('[data-erro-junto]')[0] ?? null)
}

/** Rola até o campo com problema e põe o foco nele (sem pular a tela de novo). */
export function levarAoCampo(mensagem: string): void {
  if (typeof document === 'undefined') return
  const modais = Array.from(document.querySelectorAll('div.fixed.inset-0')).filter(visivel)
  const escopo: ParentNode = modais.length ? modais[modais.length - 1] : document
  const alvo = campoComProblema(escopo, mensagem)
  if (!alvo) return
  alvo.scrollIntoView({ block: 'center', behavior: 'smooth' })
  if (alvo.matches('input, textarea, select, button')) {
    try { alvo.focus({ preventScroll: true }) } catch { /* nada */ }
  }
}
