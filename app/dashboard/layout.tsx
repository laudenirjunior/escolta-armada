'use client'

import { useEffect, useState, useRef } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import {
  LayoutDashboard, Shield, Radio, Map, Database,
  Crosshair, ClipboardList, BarChart2, FileText,
  Users, Settings, AlertTriangle, Bell, Send,
} from 'lucide-react'
import { Sidebar, SidebarContent, SidebarSection, SidebarItem, SidebarFooter } from '@/components/layout/sidebar'
import { TopBar } from '@/components/layout/topbar'
import { TelegramNotificacoesProvider } from '@/components/telegram-notificacoes-provider'
import { CheckinAlertProvider } from '@/components/checkin-alert-provider'
import { useAuth } from '@/hooks/useAuth'
import { createClient } from '@/lib/supabase/client'
import type { Perfil } from '@/types'

// cliente criado uma vez fora do componente — evita recriar a cada render
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
      { label: 'Painel', href: '/dashboard', icon: <LayoutDashboard size={16} />, perfis: ['administrador','gestor','supervisor','central','operador'] as Perfil[] },
      { label: 'Escoltas', href: '/dashboard/escoltas', icon: <Shield size={16} />, perfis: ['administrador','gestor','supervisor','central','operador'] as Perfil[] },
      { label: 'Campo', href: '/dashboard/campo', icon: <Radio size={16} />, perfis: ['operador'] as Perfil[] },
      { label: 'Mapa', href: '/dashboard/mapa', icon: <Map size={16} />, perfis: ['administrador','gestor','supervisor','central'] as Perfil[] },
      { label: 'Notificações', href: '/dashboard/notificacoes', icon: <Bell size={16} />, perfis: ['administrador','gestor','supervisor','central','operador'] as Perfil[] },
    ],
  },
  {
    section: 'Gestão',
    items: [
      { label: 'Cadastros', href: '/dashboard/cadastros', icon: <Database size={16} />, perfis: ['administrador','gestor','supervisor'] as Perfil[] },
      { label: 'Armamentos', href: '/dashboard/armamentos', icon: <Crosshair size={16} />, perfis: ['administrador','gestor','supervisor'] as Perfil[] },
      { label: 'Checklists', href: '/dashboard/checklists', icon: <ClipboardList size={16} />, perfis: ['administrador','gestor','supervisor'] as Perfil[] },
    ],
  },
  {
    section: 'Análise',
    items: [
      { label: 'Indicadores', href: '/dashboard/indicadores', icon: <BarChart2 size={16} />, perfis: ['administrador','gestor','supervisor'] as Perfil[] },
      { label: 'Relatórios', href: '/dashboard/relatorios', icon: <FileText size={16} />, perfis: ['administrador','gestor','supervisor'] as Perfil[] },
    ],
  },
  {
    section: 'Sistema',
    items: [
      { label: 'Usuários', href: '/dashboard/usuarios', icon: <Users size={16} />, perfis: ['administrador','gestor'] as Perfil[] },
      { label: 'Telegram', href: '/dashboard/sistema/telegram', icon: <Send size={16} />, perfis: ['administrador','gestor'] as Perfil[] },
      { label: 'Configurações', href: '/dashboard/configuracoes', icon: <Settings size={16} />, perfis: ['administrador'] as Perfil[] },
      { label: 'Auditoria', href: '/dashboard/auditoria', icon: <AlertTriangle size={16} />, perfis: ['administrador'] as Perfil[] },
    ],
  },
]

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  const { user, loading, isAuthenticated, logout, precisaTrocarSenha } = useAuth()
  const router = useRouter()
  const pathname = usePathname()
  const [notifCount, setNotifCount] = useState(0)
  const notifChannelRef = useRef<any>(null)

  // Real-time: incrementa contador ao receber eventos de múltiplas tabelas
  useEffect(() => {
    if (!isAuthenticated) return
    // Zera ao visitar página de notificações
    if (pathname === '/dashboard/notificacoes') {
      setNotifCount(0)
      return
    }
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

  // Determine active path considering sub-routes
  const isActive = (href: string) =>
    href === '/dashboard' ? pathname === '/dashboard' : pathname.startsWith(href)

  return (
    <div className="flex flex-col h-screen overflow-hidden" style={{ backgroundColor: '#EEF0F5' }}>

      {/* ── Full-width topbar ── */}
      <TopBar
        userInfo={{
          name: user.nome_completo.split(' ').slice(0, 2).join(' '),
          role: user.perfil?.nome_exibicao ?? 'Usuário',
        }}
        onLogout={logout}
        notificacoesCount={notifCount}
        onBellClick={() => { setNotifCount(0); router.push('/dashboard/notificacoes') }}
      />

      {/* ── Body ── */}
      <div className="flex flex-1 overflow-hidden">

        {/* ── Sidebar ── */}
        <Sidebar>
          <SidebarContent>
            {NAV.map(group => {
              const visible = group.items.filter(i => perfil && i.perfis.includes(perfil))
              if (!visible.length) return null
              return (
                <SidebarSection key={group.section} label={group.section}>
                  {visible.map(item => (
                    <SidebarItem
                      key={item.href}
                      href={item.href}
                      icon={item.icon}
                      isActive={isActive(item.href)}
                    >
                      {item.label}
                    </SidebarItem>
                  ))}
                </SidebarSection>
              )
            })}
          </SidebarContent>
          <SidebarFooter />
        </Sidebar>

        {/* ── Confirmação de presença dos vigilantes ── */}
        <TelegramNotificacoesProvider />
        {/* ── Alertas de check-in periódico atrasado ── */}
        <CheckinAlertProvider />

        {/* ── Content area ── */}
        <main className="flex-1 overflow-y-auto content-scroll" style={{ backgroundColor: '#EEF0F5' }}>
          <div className="p-6 max-w-[1400px] mx-auto">
            {children}
          </div>
        </main>
      </div>
    </div>
  )
}
