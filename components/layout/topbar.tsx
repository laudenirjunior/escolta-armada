'use client'

import type { ReactNode } from 'react'
import { LogOut, KeyRound, Bell, ChevronDown, Menu } from 'lucide-react'
import { useState } from 'react'

interface TopBarProps {
  userInfo?: { name: string; role: string }
  onLogout?: () => void
  onChangePassword?: () => void
  action?: ReactNode
  notificacoesCount?: number
  onBellClick?: () => void
  onMenuOpen?: () => void
}

export function TopBar({ userInfo, onLogout, onChangePassword, action, notificacoesCount = 0, onBellClick, onMenuOpen }: TopBarProps) {
  const [showDropdown, setShowDropdown] = useState(false)
  const initials = userInfo?.name
    ? userInfo.name.split(' ').slice(0, 2).map(n => n[0]).join('').toUpperCase()
    : 'U'

  return (
    <header
      style={{
        backgroundColor: '#0B1120',
        borderBottom: '1px solid rgba(83,100,138,0.2)',
        boxShadow: '0 1px 0 rgba(83,100,138,0.15), 0 4px 24px rgba(0,0,0,0.4)',
        position: 'sticky',
        top: 0,
        zIndex: 40,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        flexShrink: 0,
      }}
      className="px-4 md:px-8 h-14 md:h-24"
    >
      {/* Overlay radial decorativo */}
      <div style={{
        position: 'absolute', top: 0, right: 0,
        width: '50%', height: '100%',
        background: 'radial-gradient(circle at top right, rgba(83,100,138,0.14), transparent 70%)',
        pointerEvents: 'none',
      }} />
      <div style={{
        position: 'absolute', bottom: 0, left: 0, right: 0,
        height: '1px',
        background: 'linear-gradient(90deg, transparent, rgba(83,100,138,0.6) 20%, rgba(83,100,138,0.6) 50%, transparent)',
        pointerEvents: 'none',
      }} />

      {/* Left side */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '12px', position: 'relative', zIndex: 10 }}>
        {/* Botão hamburguer — só mobile */}
        <button
          className="flex md:hidden items-center justify-center active:scale-90"
          onClick={onMenuOpen}
          style={{
            width: '40px', height: '40px',
            color: 'rgba(255,255,255,0.6)',
            backgroundColor: 'rgba(255,255,255,0.06)',
            border: '1px solid rgba(255,255,255,0.1)',
            borderRadius: '6px',
          }}
        >
          <Menu size={18} />
        </button>

        {/* Brand — desktop */}
        <div
          className="hidden md:flex items-center gap-4 animate-in fade-in slide-in-from-left-4"
          style={{ animationDuration: '700ms', animationFillMode: 'both' }}
        >
          <div style={{
            width: '4px', height: '28px',
            background: 'linear-gradient(to bottom, #53648A, #9F906D)',
            borderRadius: '2px',
          }} />
          <div>
            <p className="font-black text-white uppercase" style={{ fontSize: '13px', letterSpacing: '0.15em', lineHeight: 1 }}>
              Escolta Armada
            </p>
            <p style={{ fontSize: '10px', color: 'rgba(255,255,255,0.25)', letterSpacing: '0.15em', marginTop: '4px', textTransform: 'uppercase', fontWeight: 700 }}>
              Plataforma de Gestão · Escolta Armada
            </p>
          </div>
        </div>

        {/* Brand compact — mobile */}
        <div className="flex md:hidden items-center gap-2">
          <img src="/logo.png" alt="Esquematiza" style={{ height: '20px', width: 'auto' }} />
        </div>
      </div>

      {/* Right side */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '6px', position: 'relative', zIndex: 10 }}>
        {action && <div>{action}</div>}

        {/* Bell */}
        <button
          onClick={onBellClick}
          className="flex items-center justify-center transition-all active:scale-90"
          style={{
            position: 'relative',
            width: '40px', height: '40px',
            color: notificacoesCount > 0 ? '#fff' : 'rgba(255,255,255,0.3)',
            backgroundColor: notificacoesCount > 0 ? 'rgba(184,56,50,0.15)' : 'rgba(255,255,255,0.04)',
            border: notificacoesCount > 0 ? '1px solid rgba(184,56,50,0.4)' : '1px solid rgba(255,255,255,0.08)',
            borderRadius: '6px',
          }}
          onMouseEnter={e => {
            const el = e.currentTarget as HTMLElement
            el.style.color = '#fff'; el.style.backgroundColor = '#53648A'
            el.style.boxShadow = '0 0 20px rgba(83,100,138,0.5)'; el.style.borderColor = '#53648A'
          }}
          onMouseLeave={e => {
            const el = e.currentTarget as HTMLElement
            el.style.color = notificacoesCount > 0 ? '#fff' : 'rgba(255,255,255,0.3)'
            el.style.backgroundColor = notificacoesCount > 0 ? 'rgba(184,56,50,0.15)' : 'rgba(255,255,255,0.04)'
            el.style.boxShadow = ''
            el.style.borderColor = notificacoesCount > 0 ? 'rgba(184,56,50,0.4)' : 'rgba(255,255,255,0.08)'
          }}
        >
          <Bell size={16} />
          {notificacoesCount > 0 && (
            <span style={{
              position: 'absolute', top: '-4px', right: '-4px',
              backgroundColor: '#B83832', color: '#fff', borderRadius: '10px',
              fontSize: '9px', fontWeight: 900, padding: '1px 4px',
              minWidth: '16px', textAlign: 'center', lineHeight: '14px',
              border: '1.5px solid #0B1120',
            }}>
              {notificacoesCount > 99 ? '99+' : notificacoesCount}
            </span>
          )}
        </button>

        <div className="hidden md:block" style={{ width: '1px', height: '24px', backgroundColor: 'rgba(255,255,255,0.08)', margin: '0 4px' }} />

        {/* User dropdown */}
        {userInfo && (
          <div style={{ position: 'relative' }}>
            <button
              onClick={() => setShowDropdown(!showDropdown)}
              className="flex items-center gap-2 px-2 md:px-3 py-2 transition-all"
              style={{ color: '#fff', borderRadius: '6px' }}
              onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = 'rgba(255,255,255,0.05)' }}
              onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '' }}
            >
              <div style={{ position: 'relative', flexShrink: 0 }}>
                <div style={{
                  position: 'absolute', inset: '-4px',
                  background: 'linear-gradient(135deg, #53648A, #9F906D)',
                  borderRadius: '4px', opacity: 0.2, filter: 'blur(8px)',
                }} />
                <div
                  className="flex items-center justify-center text-white font-black"
                  style={{
                    width: '36px', height: '36px',
                    background: 'linear-gradient(135deg, #53648A, #1A294A)',
                    borderRadius: '6px', fontSize: '12px',
                    position: 'relative', zIndex: 1,
                    boxShadow: '0 4px 16px rgba(0,0,0,0.3)',
                  }}
                >
                  {initials}
                </div>
                <div style={{
                  position: 'absolute', bottom: '-2px', right: '-2px',
                  width: '10px', height: '10px', borderRadius: '50%',
                  backgroundColor: '#4ade80', border: '2px solid #0F172A',
                  boxShadow: '0 0 8px rgba(74,222,128,0.6)',
                  animation: 'pulse 2s cubic-bezier(0.4,0,0.6,1) infinite', zIndex: 2,
                }} />
              </div>

              <div className="text-left hidden sm:block">
                <p className="font-black uppercase text-white" style={{ fontSize: '11px', letterSpacing: '0.1em', lineHeight: 1 }}>
                  {userInfo.name.split(' ')[0]}
                </p>
                <p style={{ fontSize: '10px', color: '#ABB5C9', letterSpacing: '0.1em', marginTop: '3px', lineHeight: 1 }}>
                  {userInfo.role}
                </p>
              </div>
              <ChevronDown size={12} style={{ color: 'rgba(255,255,255,0.25)' }} />
            </button>

            {showDropdown && (
              <>
                <div className="fixed inset-0 z-40" onClick={() => setShowDropdown(false)} />
                <div
                  className="absolute right-0 top-full mt-2 w-52 z-50 overflow-hidden animate-in fade-in zoom-in-95"
                  style={{
                    backgroundColor: '#1A2540',
                    border: '1px solid rgba(255,255,255,0.1)',
                    borderRadius: '8px',
                    boxShadow: '0 20px 60px rgba(0,0,0,0.5)',
                    animationDuration: '200ms',
                  }}
                >
                  <div style={{ padding: '14px 16px', borderBottom: '1px solid rgba(255,255,255,0.06)' }}>
                    <p className="font-black text-white uppercase" style={{ fontSize: '12px', letterSpacing: '0.1em' }}>
                      {userInfo.name}
                    </p>
                    <p style={{ fontSize: '10px', color: '#ABB5C9', marginTop: '2px' }}>{userInfo.role}</p>
                  </div>
                  <div style={{ padding: '6px' }}>
                    {onChangePassword && (
                      <button
                        onClick={() => { setShowDropdown(false); onChangePassword() }}
                        className="w-full flex items-center gap-2.5 px-3 py-3 text-xs transition-all font-bold"
                        style={{ color: 'rgba(255,255,255,0.5)', borderRadius: '6px' }}
                        onMouseEnter={e => { (e.currentTarget as HTMLElement).style.color = '#fff'; (e.currentTarget as HTMLElement).style.backgroundColor = 'rgba(255,255,255,0.06)' }}
                        onMouseLeave={e => { (e.currentTarget as HTMLElement).style.color = 'rgba(255,255,255,0.5)'; (e.currentTarget as HTMLElement).style.backgroundColor = '' }}
                      >
                        <KeyRound size={13} /> Alterar Senha
                      </button>
                    )}
                    {onLogout && (
                      <button
                        onClick={() => { setShowDropdown(false); onLogout() }}
                        className="w-full flex items-center gap-2.5 px-3 py-3 text-xs transition-all font-bold"
                        style={{ color: 'rgba(231,76,60,0.7)', borderRadius: '6px' }}
                        onMouseEnter={e => { (e.currentTarget as HTMLElement).style.color = '#e85248'; (e.currentTarget as HTMLElement).style.backgroundColor = 'rgba(184,56,50,0.12)' }}
                        onMouseLeave={e => { (e.currentTarget as HTMLElement).style.color = 'rgba(231,76,60,0.7)'; (e.currentTarget as HTMLElement).style.backgroundColor = '' }}
                      >
                        <LogOut size={13} /> Sair do Sistema
                      </button>
                    )}
                  </div>
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </header>
  )
}
