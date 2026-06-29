import type { ReactNode } from 'react'

interface DialogProps {
  isOpen: boolean
  onClose: () => void
  title?: string
  children: ReactNode
  footer?: ReactNode
}

export function Dialog({ isOpen, onClose, title, children, footer }: DialogProps) {
  if (!isOpen) return null

  return (
    <>
      {/* Overlay */}
      <div
        className="fixed inset-0 z-40 bg-slate-900/60 backdrop-blur-sm"
        onClick={onClose}
      />

      {/* Dialog */}
      <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div className="w-full max-w-lg bg-surface border border-border rounded-sm shadow-lg">
          {title && (
            <div className="px-6 py-4 border-b border-border">
              <h2 className="text-lg font-[1000] uppercase tracking-tight text-foreground">
                {title}
              </h2>
            </div>
          )}

          <div className="px-6 py-4">
            {children}
          </div>

          {footer && (
            <div className="px-6 py-4 border-t border-border bg-surface-alt flex items-center justify-end gap-3">
              {footer}
            </div>
          )}
        </div>
      </div>
    </>
  )
}
