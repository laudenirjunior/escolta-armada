import type { LucideIcon } from 'lucide-react'

interface EmBreveProps {
  titulo: string
  descricao?: string
  icon: LucideIcon
}

export function EmBreve({ titulo, descricao, icon: Icon }: EmBreveProps) {
  return (
    <div className="flex flex-col items-center justify-center min-h-[60vh] gap-4 text-center">
      <div className="p-4 rounded-full bg-surface border border-border">
        <Icon size={32} className="text-text-secondary" />
      </div>
      <div>
        <h2 className="text-lg font-[1000] uppercase tracking-widest text-foreground">{titulo}</h2>
        <p className="text-sm text-text-secondary mt-1">
          {descricao ?? 'Esta tela está em desenvolvimento e será disponibilizada em breve.'}
        </p>
      </div>
    </div>
  )
}
