'use client'

import type { ReactNode } from 'react'
import { LogOut, KeyRound, Bell, ChevronDown } from 'lucide-react'
import { useState } from 'react'

interface TopBarProps {
  userInfo?: { name: string; role: string }
  onLogout?: () => void
  onChangePassword?: () => void
  action?: ReactNode
  notificacoesCount?: number
  onBellClick?: () => void
}

export function TopBar({ userInfo, onLogout, onChangePassword, action, notificacoesCount = 0, onBellClick }: TopBarProps) {
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
        padding: '0 32px',
        height: '96px',
        flexShrink: 0,
      }}
    >
      {/* Overlay radial decorativo */}
      <div style={{
        position: 'absolute', top: 0, right: 0,
        width: '50%', height: '100%',
        background: 'radial-gradient(circle at top right, rgba(83,100,138,0.14), transparent 70%)',
        pointerEvents: 'none',
      }} />

      {/* Accent line — command center bottom separator */}
      <div style={{
        position: 'absolute', bottom: 0, left: 0, right: 0,
        height: '1px',
        background: 'linear-gradient(90deg, transparent, rgba(83,100,138,0.6) 20%, rgba(83,100,138,0.6) 50%, transparent)',
        pointerEvents: 'none',
      }} />

      {/* Título com barra gradiente + animate-in */}
      <div
        className="animate-in fade-in slide-in-from-left-4"
        style={{ animationDuration: '700ms', animationFillMode: 'both', display: 'flex', alignItems: 'center', gap: '16px' }}
      >
        {/* Barra vertical gradiente */}
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

      {/* Right side */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '8px', position: 'relative', zIndex: 10 }}>

        {/* Slot de ação externo */}
        {action && <div>{action}</div>}

        {/* Bell com glow no hover + contador */}
        <button
          onClick={onBellClick}
          className="flex items-center justify-center transition-all active:scale-90"
          style={{
            position: 'relative',
            width: '40px', height: '40px',
            color: notificacoesCount > 0 ? '#fff' : 'rgba(255,255,255,0.3)',
            backgroundColor: notificacoesCount > 0 ? 'rgba(184,56,50,0.15)' : 'rgba(255,255,255,0.04)',
            border: notificacoesCount > 0 ? '1px solid rgba(184,56,50,0.4)' : '1px solid rgba(255,255,255,0.08)',
            borderRadius: '2px',
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
            el.style.color = notificacoesCount > 0 ? '#fff' : 'rgba(255,255,255,0.3)'
            el.style.backgroundColor = notificacoesCount > 0 ? 'rgba(184,56,50,0.15)' : 'rgba(255,255,255,0.04)'
            el.style.boxShadow = ''
            el.style.borderColor = notificacoesCount > 0 ? 'rgba(184,56,50,0.4)' : 'rgba(255,255,255,0.08)'
          }}
        >
          <Bell size={16} />
          {notificacoesCount > 0 && (
            <span style={{
              position: 'absolute',
              top: '-4px', right: '-4px',
              backgroundColor: '#B83832',
              color: '#fff',
              borderRadius: '10px',
              fontSize: '9px',
              fontWeight: 900,
              padding: '1px 4px',
              minWidth: '16px',
              textAlign: 'center',
              lineHeight: '14px',
              border: '1.5px solid #0B1120',
            }}>
              {notificacoesCount > 99 ? '99+' : notificacoesCount}
            </span>
          )}
        </button>

        <div style={{ width: '1px', height: '24px', backgroundColor: 'rgba(255,255,255,0.08)', margin: '0 4px' }} />

        {/* User dropdown */}
        {userInfo && (
          <div style={{ position: 'relative' }}>
            <button
              onClick={() => setShowDropdown(!showDropdown)}
              className="flex items-center gap-3 px-3 py-2 transition-all"
              style={{ color: '#fff', borderRadius: '2px' }}
              onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = 'rgba(255,255,255,0.05)' }}
              onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '' }}
            >
              {/* Avatar com dot online */}
              <div style={{ position: 'relative', flexShrink: 0 }}>
                {/* Anel de glow ao redor do avatar */}
                <div style={{
                  position: 'absolute', inset: '-4px',
                  background: 'linear-gradient(135deg, #53648A, #9F906D)',
                  borderRadius: '2px',
                  opacity: 0.2,
                  filter: 'blur(8px)',
                }} />
                <div
                  className="flex items-center justify-center text-white font-black"
                  style={{
                    width: '44px', height: '44px',
                    background: 'linear-gradient(135deg, #53648A, #1A294A)',
                    borderRadius: '2px',
                    fontSize: '13px',
                    position: 'relative',
                    zIndex: 1,
                    boxShadow: '0 4px 16px rgba(0,0,0,0.3)',
                  }}
                >
                  {initials}
                </div>
                {/* Dot online */}
                <div style={{
                  position: 'absolute', bottom: '-2px', right: '-2px',
                  width: '11px', height: '11px', borderRadius: '50%',
                  backgroundColor: '#4ade80',
                  border: '2px solid #0F172A',
                  boxShadow: '0 0 8px rgba(74,222,128,0.6)',
                  animation: 'pulse 2s cubic-bezier(0.4,0,0.6,1) infinite',
                  zIndex: 2,
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

            {/* Dropdown */}
            {showDropdown && (
              <>
                <div className="fixed inset-0 z-40" onClick={() => setShowDropdown(false)} />
                <div
                  className="absolute right-0 top-full mt-2 w-52 z-50 overflow-hidden animate-in fade-in zoom-in-95"
                  style={{
                    backgroundColor: '#1A2540',
                    border: '1px solid rgba(255,255,255,0.1)',
                    borderRadius: '2px',
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
                        className="w-full flex items-center gap-2.5 px-3 py-2.5 text-xs transition-all font-bold"
                        style={{ color: 'rgba(255,255,255,0.5)', borderRadius: '2px' }}
                        onMouseEnter={e => { (e.currentTarget as HTMLElement).style.color = '#fff'; (e.currentTarget as HTMLElement).style.backgroundColor = 'rgba(255,255,255,0.06)' }}
                        onMouseLeave={e => { (e.currentTarget as HTMLElement).style.color = 'rgba(255,255,255,0.5)'; (e.currentTarget as HTMLElement).style.backgroundColor = '' }}
                      >
                        <KeyRound size={13} /> Alterar Senha
                      </button>
                    )}
                    {onLogout && (
                      <button
                        onClick={() => { setShowDropdown(false); onLogout() }}
                        className="w-full flex items-center gap-2.5 px-3 py-2.5 text-xs transition-all font-bold"
                        style={{ color: 'rgba(231,76,60,0.7)', borderRadius: '2px' }}
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
