'use client'

import { type ReactNode, createContext, useContext, useState } from 'react'
import Link from 'next/link'
import { ChevronLeft, Menu } from 'lucide-react'

const CollapsedCtx = createContext(false)

// ── Sidebar ───────────────────────────────────────────────────────────────────

export function Sidebar({ children }: { children: ReactNode }) {
  const [collapsed, setCollapsed] = useState(false)

  return (
    <CollapsedCtx.Provider value={collapsed}>
      <aside
        style={{
          width: collapsed ? '96px' : '288px',
          backgroundColor: '#0F172A',
          transition: 'width 0.5s cubic-bezier(0.4,0,0.2,1)',
          flexShrink: 0,
          borderRight: '1px solid rgba(255,255,255,0.05)',
          boxShadow: '20px 0px 60px -15px rgba(0,0,0,0.5)',
          position: 'relative',
          overflow: 'hidden',
          zIndex: 50,
          display: 'flex',
          flexDirection: 'column',
          height: '100%',
        }}
      >
        {/* Aura de fundo — radial gradiente canto superior direito */}
        <div style={{
          position: 'absolute', top: 0, right: 0,
          width: '200%', height: '100%',
          background: 'radial-gradient(circle at top right, rgba(56,189,248,0.08), transparent 50%)',
          pointerEvents: 'none',
        }} />

        {/* Fade gradiente rodapé */}
        <div style={{
          position: 'absolute', bottom: 0, left: 0,
          width: '100%', height: '30%',
          background: 'linear-gradient(to top, rgba(0,0,0,0.6), transparent)',
          pointerEvents: 'none',
        }} />

        {/* ── Brand Header com Glassmorphism ── */}
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: collapsed ? 'center' : 'space-between',
            padding: '0 32px',
            height: '96px',
            borderBottom: '1px solid rgba(255,255,255,0.05)',
            position: 'relative',
            zIndex: 10,
            backgroundColor: 'rgba(0,0,0,0.1)',
            backdropFilter: 'blur(12px)',
            flexShrink: 0,
          }}
        >
          {!collapsed && (
            <div className="animate-in fade-in zoom-in-95" style={{ animationDuration: '500ms' }}>
              <img src="/logo.png" alt="Esquematiza" style={{ height: '28px', width: 'auto', objectFit: 'contain' }} />
            </div>
          )}
          <button
            onClick={() => setCollapsed(!collapsed)}
            className="flex items-center justify-center transition-all active:scale-90"
            style={{
              width: '40px', height: '40px',
              color: 'rgba(255,255,255,0.3)',
              backgroundColor: 'rgba(255,255,255,0.05)',
              border: '1px solid rgba(255,255,255,0.1)',
              borderRadius: '2px',
              cursor: 'pointer',
              marginLeft: collapsed ? 0 : undefined,
            }}
            onMouseEnter={e => {
              const el = e.currentTarget as HTMLElement
              el.style.color = '#fff'
              el.style.backgroundColor = '#53648A'
              el.style.boxShadow = '0 0 20px rgba(83,100,138,0.5)'
              el.style.borderColor = '#53648A'
            }}
            onMouseLeave={e => {
              const el = e.currentTarget as HTMLElement
              el.style.color = 'rgba(255,255,255,0.3)'
              el.style.backgroundColor = 'rgba(255,255,255,0.05)'
              el.style.boxShadow = ''
              el.style.borderColor = 'rgba(255,255,255,0.1)'
            }}
          >
            {collapsed ? <Menu size={18} /> : <ChevronLeft size={18} />}
          </button>
        </div>

        {/* Nav content */}
        <div style={{ flex: 1, overflowY: 'auto', overflowX: 'hidden', position: 'relative', zIndex: 10 }}>
          {children}
        </div>
      </aside>
    </CollapsedCtx.Provider>
  )
}

// ── SidebarContent ────────────────────────────────────────────────────────────

export function SidebarContent({ children }: { children: ReactNode }) {
  return (
    <nav style={{ padding: '24px 16px', display: 'flex', flexDirection: 'column', gap: '6px' }}>
      {children}
    </nav>
  )
}

// ── SidebarSection ────────────────────────────────────────────────────────────

export function SidebarSection({ label, children }: { label: string; children: ReactNode }) {
  const collapsed = useContext(CollapsedCtx)
  return (
    <div style={{ marginBottom: '8px' }}>
      {collapsed
        ? <div style={{ margin: '12px 16px 8px', height: '1px', backgroundColor: 'rgba(255,255,255,0.08)' }} />
        : (
          <div style={{
            margin: '16px 0 4px',
            background: 'linear-gradient(90deg, rgba(83,100,138,0.22), transparent)',
            borderBottom: '1px solid rgba(83,100,138,0.28)',
            padding: '7px 24px 7px',
            display: 'flex', alignItems: 'center', gap: '8px',
          }}>
            <div style={{ width: '3px', height: '3px', backgroundColor: '#53648A', borderRadius: '50%', flexShrink: 0 }} />
            <p style={{
              fontSize: '9px', fontWeight: 900,
              textTransform: 'uppercase', letterSpacing: '0.22em',
              color: '#ABB5C9', margin: 0,
            }}>
              {label}
            </p>
          </div>
        )
      }
      {children}
    </div>
  )
}

// ── SidebarItem ───────────────────────────────────────────────────────────────

export function SidebarItem({
  children,
  isActive = false,
  icon,
  href,
  onClick,
}: {
  children: ReactNode
  isActive?: boolean
  icon?: ReactNode
  href?: string
  onClick?: () => void
}) {
  const collapsed = useContext(CollapsedCtx)

  const baseStyle: React.CSSProperties = {
    display: 'flex',
    alignItems: 'center',
    gap: collapsed ? 0 : '16px',
    width: '100%',
    padding: '14px 16px',
    paddingLeft: collapsed ? 0 : '21px',
    paddingRight: collapsed ? 0 : '16px',
    justifyContent: collapsed ? 'center' : undefined,
    cursor: 'pointer',
    textDecoration: 'none',
    position: 'relative',
    overflow: 'hidden',
    borderRadius: '2px',
    transition: 'all 0.4s cubic-bezier(0.4,0,0.2,1)',
    background: isActive
      ? 'linear-gradient(90deg, rgba(83,100,138,0.45), rgba(26,41,74,0.3))'
      : 'transparent',
    color: isActive ? '#fff' : 'rgba(255,255,255,0.35)',
    borderLeft: isActive ? '3px solid #53648A' : '3px solid transparent',
    boxShadow: isActive ? 'inset 3px 0 16px rgba(83,100,138,0.18), 0 4px 20px rgba(83,100,138,0.22)' : 'none',
  }

  const inner = (
    <>
      {/* Shimmer animado no item ativo */}
      {isActive && (
        <div
          className="animate-shimmer"
          style={{
            position: 'absolute', inset: 0,
            background: 'linear-gradient(110deg, transparent, rgba(255,255,255,0.1), transparent)',
            backgroundSize: '200% 100%',
            pointerEvents: 'none',
          }}
        />
      )}

      {/* Ícone */}
      <span style={{
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        width: collapsed ? '100%' : undefined,
        flexShrink: 0,
        color: isActive ? '#fff' : 'rgba(255,255,255,0.2)',
        transition: 'all 0.4s ease',
      }}
        className={isActive ? '' : 'group-hover:text-[#ABB5C9] group-hover:scale-110'}
      >
        {icon}
      </span>

      {/* Label */}
      {!collapsed && (
        <span style={{
          fontSize: '10px', fontWeight: 900,
          textTransform: 'uppercase', letterSpacing: '0.15em',
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          flex: 1,
          transition: 'transform 0.3s ease',
        }}>
          {children}
        </span>
      )}

      {/* Indicador de ativo — barra direita */}
      {isActive && !collapsed && (
        <div style={{ width: '3px', height: '16px', backgroundColor: 'rgba(255,255,255,0.4)', borderRadius: '2px', flexShrink: 0 }} />
      )}

      {/* Tooltip quando collapsed */}
      {collapsed && (
        <span
          className="sidebar-tooltip"
          style={{
            position: 'absolute', left: '100%', top: '50%',
            transform: 'translateY(-50%) translateX(-8px)',
            marginLeft: '16px',
            padding: '10px 14px',
            backgroundColor: '#0F172A',
            border: '1px solid rgba(255,255,255,0.1)',
            borderRadius: '2px',
            fontSize: '9px', fontWeight: 900,
            textTransform: 'uppercase', letterSpacing: '0.15em',
            color: '#fff', whiteSpace: 'nowrap',
            pointerEvents: 'none', opacity: 0,
            transition: 'all 0.15s ease', zIndex: 100,
            boxShadow: '20px 20px 60px -15px rgba(0,0,0,0.6)',
            backdropFilter: 'blur(12px)',
          }}
        >
          {children}
        </span>
      )}
    </>
  )

  const hoverIn = (el: HTMLElement) => {
    if (!isActive) {
      el.style.color = '#fff'
      el.style.backgroundColor = 'rgba(255,255,255,0.06)'
    }
    const tooltip = el.querySelector('.sidebar-tooltip') as HTMLElement | null
    if (tooltip) {
      tooltip.style.opacity = '1'
      tooltip.style.transform = 'translateY(-50%) translateX(0)'
    }
  }

  const hoverOut = (el: HTMLElement) => {
    if (!isActive) {
      el.style.color = 'rgba(255,255,255,0.35)'
      el.style.backgroundColor = 'transparent'
    }
    const tooltip = el.querySelector('.sidebar-tooltip') as HTMLElement | null
    if (tooltip) {
      tooltip.style.opacity = '0'
      tooltip.style.transform = 'translateY(-50%) translateX(-8px)'
    }
  }

  const props = {
    style: baseStyle,
    onMouseEnter: (e: React.MouseEvent) => hoverIn(e.currentTarget as HTMLElement),
    onMouseLeave: (e: React.MouseEvent) => hoverOut(e.currentTarget as HTMLElement),
  }

  if (href) {
    return <Link href={href} {...props}>{inner}</Link>
  }

  return (
    <button onClick={onClick} style={{ ...baseStyle, background: isActive ? baseStyle.background : 'none', textAlign: 'left' }}
      onMouseEnter={e => hoverIn(e.currentTarget as HTMLElement)}
      onMouseLeave={e => hoverOut(e.currentTarget as HTMLElement)}
    >
      {inner}
    </button>
  )
}

// ── SidebarFooter ─────────────────────────────────────────────────────────────

export function SidebarFooter({ children }: { children?: ReactNode }) {
  const collapsed = useContext(CollapsedCtx)
  return (
    <div
      style={{
        padding: '24px',
        borderTop: '1px solid rgba(255,255,255,0.05)',
        backgroundColor: 'rgba(0,0,0,0.2)',
        position: 'relative',
        zIndex: 10,
      }}
    >
      {!collapsed ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '10px', padding: '4px 8px' }}>
            <div style={{
              width: '8px', height: '8px', borderRadius: '50%',
              backgroundColor: '#4ade80',
              boxShadow: '0 0 10px rgba(16,185,129,0.5)',
              animation: 'pulse 2s cubic-bezier(0.4,0,0.6,1) infinite',
              flexShrink: 0,
            }} />
            <span style={{
              fontSize: '8px', fontWeight: 900,
              textTransform: 'uppercase', letterSpacing: '0.3em',
              color: 'rgba(255,255,255,0.25)',
            }}>
              Sistema Online
            </span>
          </div>
          {children}
        </div>
      ) : (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            width: '8px', height: '8px', borderRadius: '50%',
            backgroundColor: '#4ade80',
            boxShadow: '0 0 10px rgba(16,185,129,0.3)',
            animation: 'pulse 2s cubic-bezier(0.4,0,0.6,1) infinite',
          }} />
        </div>
      )}
    </div>
  )
}
