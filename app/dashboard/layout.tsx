'use client'

import { useEffect, useState, useRef } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import Link from 'next/link'
import {
  LayoutDashboard, Shield, Radio, Map, Database,
  Crosshair, ClipboardList, BarChart2, FileText,
  Users, Settings, AlertTriangle, Bell, Send,
} from 'lucide-react'
import { Sidebar, MobileDrawer, SidebarContent, SidebarSection, SidebarItem, SidebarFooter } from '@/components/layout/sidebar'
import { TopBar } from '@/components/layout/topbar'
import { TelegramNotificacoesProvider } from '@/components/telegram-notificacoes-provider'
import { CheckinAlertProvider } from '@/components/checkin-alert-provider'
import { useAuth } from '@/hooks/useAuth'
import { createClient } from '@/lib/supabase/client'
import type { Perfil } from '@/types'

const sb = createClient() as any

interface NavItem {
  label: string
  href: string
  icon: React.ReactNode
  perfis: Perfil[]
}

const NAV: { section: string; items: NavItem[] }[] = [
  {
    section: 'Operações',
    items: [
      { label: 'Painel',        href: '/dashboard',               icon: <LayoutDashboard size={16} />, perfis: ['administrador','gestor','supervisor','central','operador'] as Perfil[] },
      { label: 'Escoltas',      href: '/dashboard/escoltas',       icon: <Shield size={16} />,          perfis: ['administrador','gestor','supervisor','central','operador'] as Perfil[] },
      { label: 'Campo',         href: '/dashboard/campo',          icon: <Radio size={16} />,           perfis: ['operador'] as Perfil[] },
      { label: 'Mapa',          href: '/dashboard/mapa',           icon: <Map size={16} />,             perfis: ['administrador','gestor','supervisor','central'] as Perfil[] },
      { label: 'Notificações',  href: '/dashboard/notificacoes',   icon: <Bell size={16} />,            perfis: ['administrador','gestor','supervisor','central','operador'] as Perfil[] },
    ],
  },
  {
    section: 'Gestão',
    items: [
      { label: 'Cadastros',   href: '/dashboard/cadastros',   icon: <Database size={16} />,     perfis: ['administrador','gestor','supervisor'] as Perfil[] },
      { label: 'Armamentos',  href: '/dashboard/armamentos',  icon: <Crosshair size={16} />,    perfis: ['administrador','gestor','supervisor'] as Perfil[] },
      { label: 'Checklists',  href: '/dashboard/checklists',  icon: <ClipboardList size={16} />, perfis: ['administrador','gestor','supervisor'] as Perfil[] },
    ],
  },
  {
    section: 'Análise',
    items: [
      { label: 'Indicadores', href: '/dashboard/indicadores', icon: <BarChart2 size={16} />, perfis: ['administrador','gestor','supervisor'] as Perfil[] },
      { label: 'Relatórios',  href: '/dashboard/relatorios',  icon: <FileText size={16} />,  perfis: ['administrador','gestor','supervisor'] as Perfil[] },
    ],
  },
  {
    section: 'Sistema',
    items: [
      { label: 'Usuários',      href: '/dashboard/usuarios',           icon: <Users size={16} />,       perfis: ['administrador','gestor'] as Perfil[] },
      { label: 'Telegram',      href: '/dashboard/sistema/telegram',   icon: <Send size={16} />,        perfis: ['administrador','gestor'] as Perfil[] },
      { label: 'Configurações', href: '/dashboard/configuracoes',      icon: <Settings size={16} />,    perfis: ['administrador'] as Perfil[] },
      { label: 'Auditoria',     href: '/dashboard/auditoria',          icon: <AlertTriangle size={16} />, perfis: ['administrador'] as Perfil[] },
    ],
  },
]

// Itens que aparecem na barra inferior mobile (os mais usados no campo)
const BOTTOM_NAV_ITEMS: { label: string; href: string; icon: React.ReactNode; perfis: Perfil[] }[] = [
  { label: 'Painel',     href: '/dashboard',             icon: <LayoutDashboard size={20} />, perfis: ['administrador','gestor','supervisor','central','operador'] as Perfil[] },
  { label: 'Escoltas',   href: '/dashboard/escoltas',    icon: <Shield size={20} />,          perfis: ['administrador','gestor','supervisor','central','operador'] as Perfil[] },
  { label: 'Campo',      href: '/dashboard/campo',       icon: <Radio size={20} />,           perfis: ['operador'] as Perfil[] },
  { label: 'Avisos',     href: '/dashboard/notificacoes', icon: <Bell size={20} />,           perfis: ['administrador','gestor','supervisor','central','operador'] as Perfil[] },
  { label: 'Mapa',       href: '/dashboard/mapa',        icon: <Map size={20} />,             perfis: ['administrador','gestor','supervisor','central'] as Perfil[] },
]

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  const { user, loading, isAuthenticated, logout, precisaTrocarSenha } = useAuth()
  const router = useRouter()
  const pathname = usePathname()
  const [notifCount, setNotifCount] = useState(0)
  const [mobileOpen, setMobileOpen] = useState(false)
  const notifChannelRef = useRef<any>(null)

  useEffect(() => {
    if (!isAuthenticated) return
    if (pathname === '/dashboard/notificacoes') { setNotifCount(0); return }
    const ch = sb.channel(`layout-notif-counter-${Date.now()}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'pontos_controle' }, () => setNotifCount(n => n + 1))
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'ocorrencias' }, () => setNotifCount(n => n + 1))
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'escolta_status_historico' }, () => setNotifCount(n => n + 1))
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'presencas' }, () => setNotifCount(n => n + 1))
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'chat_mensagens' }, () => setNotifCount(n => n + 1))
      .subscribe()
    notifChannelRef.current = ch
    return () => { sb.removeChannel(ch) }
  }, [isAuthenticated, pathname])

  useEffect(() => {
    if (!loading && !isAuthenticated) router.push('/auth/login')
    if (!loading && isAuthenticated && precisaTrocarSenha) router.push('/auth/trocar-senha')
    if (!loading && isAuthenticated && user?.perfil?.codigo === 'operador' && pathname === '/dashboard') {
      router.push('/dashboard/campo')
    }
  }, [loading, isAuthenticated, precisaTrocarSenha, router, user, pathname])

  // Fecha drawer ao navegar
  useEffect(() => { setMobileOpen(false) }, [pathname])

  if (loading || !user) {
    return (
      <div className="min-h-screen flex items-center justify-center" style={{ backgroundColor: '#1A294A' }}>
        <div className="flex items-center gap-3">
          <div className="w-5 h-5 rounded-full border-2 border-t-transparent animate-spin"
            style={{ borderColor: '#53648A', borderTopColor: 'transparent' }} />
          <span className="text-sm" style={{ color: 'rgba(255,255,255,0.4)' }}>Carregando...</span>
        </div>
      </div>
    )
  }

  const perfil = user.perfil?.codigo as Perfil | undefined
  const isActive = (href: string) =>
    href === '/dashboard' ? pathname === '/dashboard' : pathname.startsWith(href)

  const navContent = (
    <SidebarContent>
      {NAV.map(group => {
        const visible = group.items.filter(i => perfil && i.perfis.includes(perfil))
        if (!visible.length) return null
        return (
          <SidebarSection key={group.section} label={group.section}>
            {visible.map(item => (
              <SidebarItem key={item.href} href={item.href} icon={item.icon} isActive={isActive(item.href)}>
                {item.label}
              </SidebarItem>
            ))}
          </SidebarSection>
        )
      })}
    </SidebarContent>
  )

  const bottomNavItems = BOTTOM_NAV_ITEMS.filter(i => perfil && i.perfis.includes(perfil))

  return (
    <div className="flex flex-col h-screen overflow-hidden" style={{ backgroundColor: '#EEF0F5' }}>

      <TopBar
        userInfo={{
          name: user.nome_completo.split(' ').slice(0, 2).join(' '),
          role: user.perfil?.nome_exibicao ?? 'Usuário',
        }}
        onLogout={logout}
        notificacoesCount={notifCount}
        onBellClick={() => { setNotifCount(0); router.push('/dashboard/notificacoes') }}
        onMenuOpen={() => setMobileOpen(true)}
      />

      {/* Mobile Drawer */}
      <MobileDrawer open={mobileOpen} onClose={() => setMobileOpen(false)}>
        {navContent}
      </MobileDrawer>

      {/* Body */}
      <div className="flex flex-1 overflow-hidden">

        {/* Sidebar desktop */}
        <Sidebar>
          {navContent}
          <SidebarFooter />
        </Sidebar>

        <TelegramNotificacoesProvider />
        <CheckinAlertProvider />

        {/* Conteúdo principal — pb-20 no mobile para não ficar atrás da bottom nav */}
        <main className="flex-1 overflow-y-auto content-scroll" style={{ backgroundColor: '#EEF0F5' }}>
          <div className="p-4 md:p-6 pb-24 md:pb-6 max-w-[1400px] mx-auto">
            {children}
          </div>
        </main>
      </div>

      {/* ── Bottom Navigation Mobile ── */}
      <nav
        className="md:hidden fixed bottom-0 left-0 right-0 z-40 flex items-stretch"
        style={{
          backgroundColor: '#0B1120',
          borderTop: '1px solid rgba(83,100,138,0.25)',
          boxShadow: '0 -4px 24px rgba(0,0,0,0.4)',
          height: '64px',
        }}
      >
        {bottomNavItems.map(item => {
          const active = isActive(item.href)
          return (
            <Link
              key={item.href}
              href={item.href}
              className="flex-1 flex flex-col items-center justify-center gap-1 active:scale-95 transition-transform"
              style={{
                color: active ? '#fff' : 'rgba(255,255,255,0.35)',
                borderTop: active ? '2px solid #53648A' : '2px solid transparent',
                backgroundColor: active ? 'rgba(83,100,138,0.15)' : 'transparent',
                textDecoration: 'none',
                position: 'relative',
              }}
            >
              {/* Badge de notificação no ícone de avisos */}
              {item.href === '/dashboard/notificacoes' && notifCount > 0 && (
                <span style={{
                  position: 'absolute', top: '8px', right: '25%',
                  backgroundColor: '#B83832', color: '#fff',
                  borderRadius: '10px', fontSize: '8px', fontWeight: 900,
                  padding: '1px 4px', minWidth: '14px', textAlign: 'center',
                  lineHeight: '13px', border: '1.5px solid #0B1120',
                }}>
                  {notifCount > 99 ? '99+' : notifCount}
                </span>
              )}
              <span style={{ color: active ? '#fff' : 'rgba(255,255,255,0.3)' }}>{item.icon}</span>
              <span style={{
                fontSize: '9px', fontWeight: 900, textTransform: 'uppercase',
                letterSpacing: '0.08em', color: active ? '#ABB5C9' : 'rgba(255,255,255,0.25)',
              }}>
                {item.label}
              </span>
            </Link>
          )
        })}
      </nav>

    </div>
  )
}
