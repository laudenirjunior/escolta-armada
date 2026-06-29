'use client'

import { useState, useEffect } from 'react'
import {
  Bell, Palette, Server, Shield, Check, ToggleLeft, ToggleRight,
  Trash2, Info, KeyRound, ChevronRight,
} from 'lucide-react'
import { useRouter } from 'next/navigation'
import { useAuth } from '@/hooks/useAuth'

interface Notificacoes {
  email: boolean
  app: boolean
  emergencias: boolean
  checklists: boolean
}

const VERSAO = '1.0.0-beta'
const BUILD = 'June 2026'

export default function ConfiguracoesPage() {
  const { user } = useAuth()
  const router = useRouter()

  const [notif, setNotif] = useState<Notificacoes>({
    email: true, app: true, emergencias: true, checklists: false,
  })
  const [cacheLimpo, setCacheLimpo] = useState(false)
  const [salvando, setSalvando] = useState(false)
  const [salvo, setSalvo] = useState(false)

  // Load from localStorage
  useEffect(() => {
    try {
      const saved = localStorage.getItem('ea_notificacoes')
      if (saved) setNotif(JSON.parse(saved))
    } catch { /* ignore */ }
  }, [])

  const toggleNotif = (key: keyof Notificacoes) => {
    const updated = { ...notif, [key]: !notif[key] }
    setNotif(updated)
    localStorage.setItem('ea_notificacoes', JSON.stringify(updated))
  }

  const limparCache = () => {
    if (typeof window !== 'undefined') {
      localStorage.removeItem('ea_notificacoes')
      setCacheLimpo(true)
      setTimeout(() => setCacheLimpo(false), 3000)
    }
  }

  const salvarPreferencias = () => {
    setSalvando(true)
    localStorage.setItem('ea_notificacoes', JSON.stringify(notif))
    setTimeout(() => {
      setSalvando(false)
      setSalvo(true)
      setTimeout(() => setSalvo(false), 3000)
    }, 600)
  }

  const Toggle = ({ ativo, onClick }: { ativo: boolean; onClick: () => void }) => (
    <button
      onClick={onClick}
      className="flex items-center transition-colors"
      style={{ color: ativo ? '#4A90A4' : '#C8D5DC' }}
    >
      {ativo
        ? <ToggleRight size={28} />
        : <ToggleLeft size={28} />
      }
    </button>
  )

  const SectionHeader = ({ icon, title, subtitle }: { icon: React.ReactNode; title: string; subtitle: string }) => (
    <div className="flex items-center gap-3 px-5 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
      <div className="w-8 h-8 rounded-lg flex items-center justify-center shrink-0"
        style={{ backgroundColor: '#EBF3FC' }}>
        <span style={{ color: '#2166A8' }}>{icon}</span>
      </div>
      <div>
        <h2 className="text-sm font-bold" style={{ color: '#1E2D35' }}>{title}</h2>
        <p className="text-[11px]" style={{ color: '#6B7E8A' }}>{subtitle}</p>
      </div>
    </div>
  )

  const SettingRow = ({
    label, description, children,
  }: {
    label: string; description?: string; children: React.ReactNode
  }) => (
    <div className="flex items-center justify-between px-5 py-3.5 border-b last:border-0"
      style={{ borderColor: '#E2E8EC' }}>
      <div>
        <p className="text-sm font-medium" style={{ color: '#1E2D35' }}>{label}</p>
        {description && (
          <p className="text-[11px] mt-0.5" style={{ color: '#6B7E8A' }}>{description}</p>
        )}
      </div>
      <div className="shrink-0 ml-4">{children}</div>
    </div>
  )

  return (
    <div className="space-y-5 max-w-2xl">

      {/* ── Header ── */}
      <div>
        <h1 className="page-title">Configurações</h1>
        <p className="page-subtitle">Preferências do sistema e conta</p>
      </div>

      {/* ── Notificações ── */}
      <div className="card-light">
        <SectionHeader
          icon={<Bell size={16} />}
          title="Notificações"
          subtitle="Controle como e quando você recebe alertas"
        />
        <SettingRow label="Notificações por E-mail" description="Receba alertas e resumos por e-mail">
          <Toggle ativo={notif.email} onClick={() => toggleNotif('email')} />
        </SettingRow>
        <SettingRow label="Notificações no App" description="Alertas dentro do painel de controle">
          <Toggle ativo={notif.app} onClick={() => toggleNotif('app')} />
        </SettingRow>
        <SettingRow label="Alertas de Emergência" description="Notificar quando uma emergência é acionada">
          <Toggle ativo={notif.emergencias} onClick={() => toggleNotif('emergencias')} />
        </SettingRow>
        <SettingRow label="Alertas de Checklist Pendente" description="Avisar sobre checklists não concluídos">
          <Toggle ativo={notif.checklists} onClick={() => toggleNotif('checklists')} />
        </SettingRow>
      </div>

      {/* ── Aparência ── */}
      <div className="card-light">
        <SectionHeader
          icon={<Palette size={16} />}
          title="Aparência"
          subtitle="Tema visual e preferências de exibição"
        />
        <div className="px-5 py-4">
          <p className="text-xs font-semibold mb-3 uppercase tracking-wider" style={{ color: '#6B7E8A' }}>
            Tema Ativo
          </p>
          <div className="flex gap-3">
            {/* SlateTech theme (active) */}
            <div className="flex-1 rounded-xl p-3 cursor-pointer border-2"
              style={{ backgroundColor: '#1C2B35', borderColor: '#4A90A4' }}>
              <div className="flex items-center gap-2 mb-2">
                <div className="w-5 h-5 rounded-full flex items-center justify-center"
                  style={{ backgroundColor: '#4A90A4' }}>
                  <Check size={10} className="text-white" />
                </div>
                <span className="text-xs font-bold text-white">SlateTech</span>
              </div>
              <div className="flex gap-1">
                <div className="h-2 flex-1 rounded" style={{ backgroundColor: '#4A90A4' }} />
                <div className="h-2 flex-1 rounded" style={{ backgroundColor: '#5C6B73' }} />
                <div className="h-2 flex-1 rounded" style={{ backgroundColor: '#3A5464' }} />
              </div>
            </div>

            {/* Classic theme (coming soon) */}
            <div className="flex-1 rounded-xl p-3 border border-dashed opacity-40"
              style={{ backgroundColor: '#F4F4F9', borderColor: '#C8D5DC' }}>
              <div className="flex items-center gap-2 mb-2">
                <div className="w-5 h-5 rounded-full border-2" style={{ borderColor: '#C8D5DC' }} />
                <span className="text-xs font-bold" style={{ color: '#6B7E8A' }}>Clássico</span>
              </div>
              <div className="flex gap-1">
                <div className="h-2 flex-1 rounded bg-blue-500" />
                <div className="h-2 flex-1 rounded bg-gray-300" />
                <div className="h-2 flex-1 rounded bg-gray-200" />
              </div>
              <p className="text-[9px] mt-1.5 text-center" style={{ color: '#A8B8C2' }}>Em breve</p>
            </div>
          </div>
        </div>
      </div>

      {/* ── Perfil ── */}
      <div className="card-light">
        <SectionHeader
          icon={<Shield size={16} />}
          title="Meu Perfil"
          subtitle="Informações da sua conta"
        />
        <div className="px-5 py-4 space-y-3">
          <div className="flex items-center gap-3">
            <div className="w-12 h-12 rounded-full flex items-center justify-center shrink-0 text-white font-black text-base"
              style={{ background: 'linear-gradient(135deg, #4A90A4, #5C6B73)' }}>
              {user?.nome_completo?.split(' ').slice(0, 2).map(n => n[0]).join('').toUpperCase() ?? 'U'}
            </div>
            <div>
              <p className="text-sm font-bold" style={{ color: '#1E2D35' }}>{user?.nome_completo}</p>
              <p className="text-xs" style={{ color: '#6B7E8A' }}>{user?.email}</p>
              <span className="badge-neutral mt-1">{user?.perfil?.nome_exibicao ?? '—'}</span>
            </div>
          </div>
        </div>
        <div className="border-t" style={{ borderColor: '#E2E8EC' }}>
          <button
            onClick={() => router.push('/auth/trocar-senha')}
            className="w-full flex items-center justify-between px-5 py-3.5 transition-all"
            onMouseEnter={(e) => (e.currentTarget as HTMLElement).style.backgroundColor = '#F8FAFC'}
            onMouseLeave={(e) => (e.currentTarget as HTMLElement).style.backgroundColor = ''}
          >
            <div className="flex items-center gap-2.5">
              <KeyRound size={15} style={{ color: '#6B7E8A' }} />
              <span className="text-sm font-medium" style={{ color: '#1E2D35' }}>Alterar Senha</span>
            </div>
            <ChevronRight size={14} style={{ color: '#C8D5DC' }} />
          </button>
        </div>
      </div>

      {/* ── Sistema ── */}
      <div className="card-light">
        <SectionHeader
          icon={<Server size={16} />}
          title="Sistema"
          subtitle="Informações técnicas e manutenção"
        />

        <div className="px-5 py-4 space-y-3">
          {/* Info grid */}
          <div className="grid grid-cols-2 gap-3">
            {[
              { label: 'Versão', value: VERSAO },
              { label: 'Build', value: BUILD },
              { label: 'Plataforma', value: 'Web' },
              { label: 'Backend', value: 'Supabase' },
            ].map((item) => (
              <div key={item.label} className="px-3 py-2.5 rounded-lg" style={{ backgroundColor: '#F4F4F9' }}>
                <p className="text-[10px] uppercase tracking-wider font-bold" style={{ color: '#A8B8C2' }}>
                  {item.label}
                </p>
                <p className="text-sm font-semibold mt-0.5" style={{ color: '#1E2D35' }}>
                  {item.value}
                </p>
              </div>
            ))}
          </div>

          {/* Info */}
          <div className="flex items-start gap-2 px-3 py-2.5 rounded-lg"
            style={{ backgroundColor: '#EBF3FC', border: '1px solid #C8DCF0' }}>
            <Info size={13} className="shrink-0 mt-0.5" style={{ color: '#2166A8' }} />
            <p className="text-[11px]" style={{ color: '#2166A8' }}>
              Os dados de preferências são armazenados localmente neste navegador. Limpar o cache remove apenas preferências locais, não dados do servidor.
            </p>
          </div>

          {/* Clear cache button */}
          <button
            onClick={limparCache}
            className="flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-semibold transition-all"
            style={{
              color: cacheLimpo ? '#1E7C52' : '#B83832',
              backgroundColor: cacheLimpo ? '#EBF7F1' : '#FEF0EE',
            }}
          >
            <Trash2 size={14} />
            {cacheLimpo ? 'Cache limpo!' : 'Limpar Cache Local'}
          </button>
        </div>
      </div>

      {/* ── Save ── */}
      <div className="flex items-center justify-end gap-3 pb-4">
        {salvo && (
          <span className="flex items-center gap-1.5 text-sm font-medium"
            style={{ color: '#1E7C52' }}>
            <Check size={14} /> Preferências salvas
          </span>
        )}
        <button
          onClick={salvarPreferencias}
          disabled={salvando}
          className="btn-primary"
        >
          {salvando ? 'Salvando...' : 'Salvar Preferências'}
        </button>
      </div>
    </div>
  )
}
