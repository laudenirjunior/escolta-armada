'use client'

import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { Mail, Lock, Eye, EyeOff, Shield, ChevronRight, Loader2 } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'

export default function LoginPage() {
  const [email,       setEmail]       = useState('')
  const [password,    setPassword]    = useState('')
  const [showPass,    setShowPass]    = useState(false)
  const router = useRouter()
  const { user, login, loading, error, isAuthenticated, precisaTrocarSenha } = useAuth()

  // Redireciona se já estiver logado ao carregar a página
  useEffect(() => {
    if (!loading && isAuthenticated) {
      router.replace(precisaTrocarSenha ? '/auth/trocar-senha' : '/dashboard')
    }
  }, [loading, isAuthenticated, precisaTrocarSenha, router])

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    // Operadores acessam pelo usuário (primeironome_ultimonome). Sem "@" → completa com o domínio interno.
    const identificador = email.trim()
    const loginEmail = identificador.includes('@')
      ? identificador.toLowerCase()
      : `${identificador.toLowerCase()}@operador.local`
    const result = await login(loginEmail, password)
    if (result.ok) {
      router.replace(result.trocarSenha ? '/auth/trocar-senha' : '/dashboard')
    }
  }

  return (
    <div className="min-h-screen flex flex-col md:flex-row bg-white overflow-hidden"
      style={{ fontFamily: 'system-ui, sans-serif' }}>

      {/* ══════════ COLUNA ESQUERDA — Branding ══════════ */}
      <div
        className="hidden md:flex w-1/2 relative items-center justify-center p-12 lg:p-24 overflow-hidden border-r"
        style={{ backgroundColor: '#1A294A', borderColor: 'rgba(255,255,255,0.05)' }}
      >
        {/* Imagem com overlay cinematográfico */}
        <div className="absolute inset-0 z-0">
          <img
            src="https://images.unsplash.com/photo-1544197150-b99a580bb7a8?auto=format&fit=crop&q=80&w=2000"
            alt="Escolta Armada — Segurança Operacional"
            className="w-full h-full object-cover"
            style={{ opacity: 0.18, filter: 'grayscale(1) contrast(1.2)', mixBlendMode: 'luminosity' }}
          />
          <div className="absolute inset-0" style={{
            background: 'linear-gradient(135deg, #1A294A 0%, rgba(26,41,74,0.95) 60%, transparent 100%)',
          }} />
          {/* Luzes decorativas de fundo */}
          <div className="absolute top-1/4 left-1/4 w-96 h-96 rounded-full"
            style={{ backgroundColor: 'rgba(83,100,138,0.2)', filter: 'blur(120px)', opacity: 0.25 }} />
          <div className="absolute bottom-1/4 right-1/4 w-96 h-96 rounded-full"
            style={{ backgroundColor: 'rgba(37,53,98,0.3)', filter: 'blur(120px)', opacity: 0.3 }} />
        </div>

        {/* Conteúdo esquerdo */}
        <div
          className="relative z-10 w-full max-w-xl pl-12 lg:pl-20 space-y-12 animate-in fade-in slide-in-from-left-12"
          style={{ animationDuration: '1000ms', animationFillMode: 'both' }}
        >
          {/* Ícone */}
          <div
            className="w-14 h-14 flex items-center justify-center border"
            style={{
              backgroundColor: 'rgba(255,255,255,0.08)',
              backdropFilter: 'blur(12px)',
              borderColor: 'rgba(255,255,255,0.15)',
              borderRadius: '2px',
              boxShadow: '0 8px 32px rgba(0,0,0,0.3)',
            }}
          >
            <Shield size={28} style={{ color: '#ABB5C9' }} strokeWidth={2} />
          </div>

          {/* Título */}
          <div className="space-y-6 pt-8">
            <div className="space-y-4">
              <h2 className="text-white font-black leading-tight"
                style={{ fontSize: 'clamp(2rem, 3.5vw, 3rem)', letterSpacing: '-0.02em', lineHeight: 1.1 }}>
                Controle de<br />
                Escoltas<br />
                <span style={{ color: '#ABB5C9', fontStyle: 'italic' }}>Armadas.</span>
              </h2>
              <div style={{ height: '3px', width: '56px', backgroundColor: 'rgba(171,181,201,0.5)', borderRadius: '2px' }} />
            </div>
            <p className="font-black uppercase text-sm leading-relaxed" style={{
              color: 'rgba(255,255,255,0.4)', letterSpacing: '0.2em', maxWidth: '280px'
            }}>
              <span style={{ color: '#ABB5C9' }}>Segurança e precisão</span><br />
              operacional de campo.
            </p>
          </div>

          {/* Rodapé com logo */}
          <div className="pt-8 flex items-center gap-6" style={{ borderTop: '1px solid rgba(255,255,255,0.06)' }}>
            <div className="space-y-3">
              <p className="font-black uppercase" style={{
                fontSize: '9px', color: 'rgba(255,255,255,0.25)', letterSpacing: '0.3em'
              }}>
                Plataforma por
              </p>
              <div className="flex items-center gap-4">
                <img src="/logo.png" alt="Esquematiza" style={{ height: '24px', width: 'auto' }} />
                <div style={{
                  padding: '2px 8px',
                  backgroundColor: '#53648A',
                  borderRadius: '2px',
                  fontSize: '8px',
                  fontWeight: 900,
                  textTransform: 'uppercase',
                  letterSpacing: '0.15em',
                  color: '#fff',
                }}>
                  V1.0
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* ══════════ COLUNA DIREITA — Formulário ══════════ */}
      <div
        className="flex-1 flex flex-col justify-center p-8 sm:p-20 lg:p-32 relative"
        style={{ backgroundColor: '#ffffff' }}
      >
        <div
          className="w-full mx-auto space-y-10 animate-in fade-in slide-in-from-right-12"
          style={{ maxWidth: '420px', animationDuration: '1000ms', animationFillMode: 'both' }}
        >
          {/* Mobile: logo/brand */}
          <div className="md:hidden flex flex-col gap-5 mb-8">
            <div
              className="w-14 h-14 flex items-center justify-center"
              style={{ backgroundColor: '#1A294A', borderRadius: '2px' }}
            >
              <Shield size={26} color="#ABB5C9" strokeWidth={2} />
            </div>
            <div>
              <h1 className="font-black uppercase" style={{
                fontSize: '1.6rem', color: '#1A294A', letterSpacing: '-0.01em'
              }}>
                Escolta Armada
              </h1>
              <div style={{ height: '3px', width: '40px', backgroundColor: '#53648A', marginTop: '8px', borderRadius: '2px' }} />
            </div>
          </div>

          {/* Header do form */}
          <div className="space-y-2">
            <h2 className="font-black" style={{ fontSize: '2rem', color: '#0E1A33', letterSpacing: '-0.02em' }}>
              Login
            </h2>
            <div className="flex items-center gap-2">
              <div style={{ width: '3px', height: '12px', backgroundColor: '#53648A', borderRadius: '2px' }} />
              <p className="font-bold uppercase" style={{
                fontSize: '11px', color: '#5A6A80', letterSpacing: '0.2em'
              }}>
                Painel de Acesso Operacional
              </p>
            </div>
          </div>

          {/* Form */}
          <form onSubmit={handleSubmit} className="space-y-5">
            {/* Email */}
            <div className="relative" style={{ position: 'relative' }}>
              <div style={{
                position: 'absolute', left: '16px', top: '50%', transform: 'translateY(-50%)',
                color: '#ABB5C9', pointerEvents: 'none', transition: 'color 0.2s',
              }}>
                <Mail size={18} strokeWidth={2} />
              </div>
              <input
                type="text"
                value={email}
                onChange={e => setEmail(e.target.value)}
                placeholder="Usuário ou e-mail de acesso"
                required
                autoComplete="username"
                className="w-full outline-none transition-all font-bold text-sm"
                style={{
                  height: '56px',
                  paddingLeft: '48px', paddingRight: '16px',
                  backgroundColor: '#F4F5F9',
                  border: '1.5px solid #D8DBE6',
                  borderRadius: '2px',
                  color: '#1A1D2B',
                }}
                onFocus={e => { e.currentTarget.style.backgroundColor = '#fff'; e.currentTarget.style.borderColor = '#53648A'; e.currentTarget.style.boxShadow = '0 0 0 4px rgba(83,100,138,0.08)' }}
                onBlur={e  => { e.currentTarget.style.backgroundColor = '#F4F5F9'; e.currentTarget.style.borderColor = '#D8DBE6'; e.currentTarget.style.boxShadow = '' }}
              />
            </div>

            {/* Senha */}
            <div style={{ position: 'relative' }}>
              <div style={{
                position: 'absolute', left: '16px', top: '50%', transform: 'translateY(-50%)',
                color: '#ABB5C9', pointerEvents: 'none',
              }}>
                <Lock size={18} strokeWidth={2} />
              </div>
              <input
                type={showPass ? 'text' : 'password'}
                value={password}
                onChange={e => setPassword(e.target.value)}
                placeholder="Sua senha de acesso"
                required
                autoComplete="current-password"
                className="w-full outline-none transition-all font-bold text-sm"
                style={{
                  height: '56px',
                  paddingLeft: '48px', paddingRight: '48px',
                  backgroundColor: '#F4F5F9',
                  border: '1.5px solid #D8DBE6',
                  borderRadius: '2px',
                  color: '#1A1D2B',
                }}
                onFocus={e => { e.currentTarget.style.backgroundColor = '#fff'; e.currentTarget.style.borderColor = '#53648A'; e.currentTarget.style.boxShadow = '0 0 0 4px rgba(83,100,138,0.08)' }}
                onBlur={e  => { e.currentTarget.style.backgroundColor = '#F4F5F9'; e.currentTarget.style.borderColor = '#D8DBE6'; e.currentTarget.style.boxShadow = '' }}
              />
              <button
                type="button"
                onClick={() => setShowPass(!showPass)}
                className="flex items-center justify-center transition-all"
                style={{
                  position: 'absolute', right: '12px', top: '50%', transform: 'translateY(-50%)',
                  width: '32px', height: '32px', borderRadius: '2px',
                  color: '#ABB5C9', border: '1px solid transparent',
                }}
                onMouseEnter={e => { (e.currentTarget as HTMLElement).style.color = '#1A294A'; (e.currentTarget as HTMLElement).style.backgroundColor = '#EEF0F5'; (e.currentTarget as HTMLElement).style.borderColor = '#D6DAE5' }}
                onMouseLeave={e => { (e.currentTarget as HTMLElement).style.color = '#ABB5C9'; (e.currentTarget as HTMLElement).style.backgroundColor = ''; (e.currentTarget as HTMLElement).style.borderColor = 'transparent' }}
              >
                {showPass ? <EyeOff size={16} /> : <Eye size={16} />}
              </button>
            </div>

            {/* Erro */}
            {error && (
              <div
                className="flex items-center gap-3 animate-in fade-in zoom-in"
                style={{
                  backgroundColor: 'rgba(231,76,60,0.05)',
                  border: '1px solid rgba(231,76,60,0.15)',
                  borderRadius: '2px',
                  padding: '14px 18px',
                  animationDuration: '300ms',
                }}
              >
                <div style={{
                  width: '6px', height: '6px', borderRadius: '50%',
                  backgroundColor: '#e74c3c',
                  animation: 'ping 1s cubic-bezier(0,0,0.2,1) infinite',
                  flexShrink: 0,
                }} />
                <p className="font-black uppercase" style={{
                  fontSize: '11px', color: '#e74c3c', letterSpacing: '0.1em'
                }}>
                  {error}
                </p>
              </div>
            )}

            {/* Botão */}
            <button
              type="submit"
              disabled={loading}
              className="w-full flex items-center justify-center gap-3 font-black uppercase transition-all group overflow-hidden disabled:opacity-60"
              style={{
                height: '56px',
                backgroundColor: '#1A294A',
                color: '#fff',
                fontSize: '11px',
                letterSpacing: '0.3em',
                borderRadius: '2px',
                boxShadow: '0 8px 32px rgba(26,41,74,0.25)',
                border: '1px solid rgba(255,255,255,0.05)',
                cursor: loading ? 'not-allowed' : 'pointer',
              }}
              onMouseEnter={e => {
                if (!loading) {
                  (e.currentTarget as HTMLElement).style.backgroundColor = '#253562'
                  ;(e.currentTarget as HTMLElement).style.transform = 'scale(1.01)'
                  ;(e.currentTarget as HTMLElement).style.boxShadow = '0 12px 40px rgba(26,41,74,0.35)'
                }
              }}
              onMouseLeave={e => {
                (e.currentTarget as HTMLElement).style.backgroundColor = '#1A294A'
                ;(e.currentTarget as HTMLElement).style.transform = ''
                ;(e.currentTarget as HTMLElement).style.boxShadow = '0 8px 32px rgba(26,41,74,0.25)'
              }}
              onMouseDown={e => { (e.currentTarget as HTMLElement).style.transform = 'scale(0.98)' }}
              onMouseUp={e   => { (e.currentTarget as HTMLElement).style.transform = 'scale(1.01)' }}
            >
              {loading
                ? <><Loader2 size={16} className="animate-spin" /> Autenticando...</>
                : <>Autenticar <ChevronRight size={16} style={{ color: '#ABB5C9', transition: 'transform 0.3s' }}
                    className="group-hover:translate-x-1" /></>
              }
            </button>
          </form>

          {/* Copyright */}
          <div className="pt-8 text-center" style={{ borderTop: '1px solid #EEF0F5' }}>
            <p className="font-black uppercase" style={{
              fontSize: '10px', color: '#ABB5C9', letterSpacing: '0.4em', opacity: 0.5
            }}>
              © {new Date().getFullYear()} Grupo Esquematiza · Escolta Armada
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}
