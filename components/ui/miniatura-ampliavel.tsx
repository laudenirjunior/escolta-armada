'use client'

/**
 * Onda O (M7): prévia de foto em miniatura (no máximo 160 px de altura) que amplia ao toque.
 * No teste de 07/11 a prévia ocupava a tela inteira no computador e empurrava o Confirmar
 * para fora da janela. Usada em todas as telas de captura (detalhe, Campo e Painel Guiado).
 */
import { useEffect, useState } from 'react'
import { X } from 'lucide-react'

export const ALTURA_MAX_MINIATURA = 160

export function MiniaturaAmpliavel({ src, alt, className, style }: {
  src: string
  alt: string
  className?: string
  style?: React.CSSProperties
}) {
  const [aberta, setAberta] = useState(false)
  useEffect(() => {
    if (!aberta) return
    const fechar = (e: KeyboardEvent) => { if (e.key === 'Escape') setAberta(false) }
    window.addEventListener('keydown', fechar)
    return () => window.removeEventListener('keydown', fechar)
  }, [aberta])
  return (
    <>
      <button
        type="button"
        onClick={() => setAberta(true)}
        aria-label={`Ampliar ${alt}`}
        data-miniatura
        className="block w-full h-full p-0 border-0 bg-transparent"
        style={{ cursor: 'zoom-in' }}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={src} alt={alt} className={className} style={{ maxHeight: ALTURA_MAX_MINIATURA, ...style }} />
      </button>
      {aberta && (
        <div
          role="dialog"
          aria-label={alt}
          data-foto-ampliada
          onClick={() => setAberta(false)}
          className="fixed inset-0 flex items-center justify-center p-4"
          style={{ zIndex: 100001, backgroundColor: 'rgba(0,0,0,0.88)', cursor: 'zoom-out' }}
        >
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={src} alt={alt} style={{ maxWidth: '100%', maxHeight: '100%', objectFit: 'contain' }} />
          <button type="button" aria-label="Fechar" onClick={() => setAberta(false)}
            className="absolute top-3 right-3 flex items-center justify-center text-white"
            style={{ width: 44, height: 44, backgroundColor: 'rgba(255,255,255,0.15)', borderRadius: 4 }}>
            <X size={20} />
          </button>
        </div>
      )}
    </>
  )
}
