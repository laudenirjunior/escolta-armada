'use client'

import { useCallback, useEffect, useState } from 'react'
import { Download, Plus, Share, Shield, X } from 'lucide-react'

/**
 * Convite para instalar o app na tela de inicio do celular.
 *
 * Android e iPhone nao funcionam do mesmo jeito. No Android o navegador dispara
 * `beforeinstallprompt` e da para oferecer um botao proprio de instalar. No
 * Safari do iPhone esse evento NAO existe: a instalacao so acontece pelo menu
 * Compartilhar, entao o unico caminho honesto e a instrucao visual.
 *
 * O banner some quando o app ja esta instalado, quando o usuario dispensa (fica
 * calado por 14 dias) e assim que chega o evento `appinstalled`.
 */

const CHAVE_DISPENSA = 'ea_pwa_instalar_dispensado'
const DIAS_DE_SILENCIO = 14
const MS_POR_DIA = 24 * 60 * 60 * 1000

// Tipagem do evento proprietario do Chromium, que nao existe no lib.dom.
interface PromptDeInstalacao extends Event {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>
}

type Modo = 'android' | 'ios'

function jaInstalado(): boolean {
  if (window.matchMedia?.('(display-mode: standalone)').matches) return true
  // Safari do iPhone nao implementa display-mode e usa esta propriedade legada.
  return (window.navigator as Navigator & { standalone?: boolean }).standalone === true
}

function dispensadoRecentemente(): boolean {
  try {
    const bruto = localStorage.getItem(CHAVE_DISPENSA)
    if (!bruto) return false
    const quando = Number(bruto)
    if (!Number.isFinite(quando)) return false
    return Date.now() - quando < DIAS_DE_SILENCIO * MS_POR_DIA
  } catch {
    // Safari em navegacao privada lanca ao ler localStorage. Sem memoria do
    // descarte, o certo e mostrar de novo, nunca calar para sempre.
    return false
  }
}

export function InstalarAppProvider() {
  const [modo, setModo] = useState<Modo | null>(null)
  const [promptAndroid, setPromptAndroid] = useState<PromptDeInstalacao | null>(null)

  useEffect(() => {
    if (typeof window === 'undefined') return

    // O service worker e registrado sempre, mesmo com o banner escondido: ele e
    // pre-requisito de instalabilidade e nao tem cache nenhum (ver public/sw.js).
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('/sw.js').catch(() => {
        // Falha de registro nao pode derrubar o dashboard. O app continua
        // funcionando pela rede, so perde a oferta de instalacao.
      })
    }

    const aoInstalar = () => setModo(null)
    window.addEventListener('appinstalled', aoInstalar)

    if (jaInstalado() || dispensadoRecentemente()) {
      return () => window.removeEventListener('appinstalled', aoInstalar)
    }

    const ua = navigator.userAgent
    const ehIOS =
      /iphone|ipad|ipod/i.test(ua) ||
      // iPadOS 13 em diante se declara Mac, e so os toques o denunciam.
      (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
    // Chrome, Firefox e Edge no iOS nao conseguem instalar, entao ensinar o
    // caminho do Compartilhar la seria instrucao falsa.
    const ehSafariIOS = ehIOS && !/crios|fxios|edgios/i.test(ua)
    const ehAndroid = /android/i.test(ua)

    if (ehSafariIOS) {
      setModo('ios')
      return () => window.removeEventListener('appinstalled', aoInstalar)
    }

    if (!ehAndroid) {
      // Desktop nao recebe convite: a tela de inicio do celular e o alvo.
      return () => window.removeEventListener('appinstalled', aoInstalar)
    }

    const aoPoderInstalar = (evento: Event) => {
      // Sem preventDefault o Chrome mostra o proprio mini-infobar e o banner
      // daqui viraria um segundo aviso pedindo a mesma coisa.
      evento.preventDefault()
      setPromptAndroid(evento as PromptDeInstalacao)
      setModo('android')
    }
    window.addEventListener('beforeinstallprompt', aoPoderInstalar)

    return () => {
      window.removeEventListener('beforeinstallprompt', aoPoderInstalar)
      window.removeEventListener('appinstalled', aoInstalar)
    }
  }, [])

  const dispensar = useCallback(() => {
    try {
      localStorage.setItem(CHAVE_DISPENSA, String(Date.now()))
    } catch {
      // Sem localStorage o banner volta na proxima visita. Aceitavel.
    }
    setModo(null)
  }, [])

  const instalar = useCallback(async () => {
    if (!promptAndroid) return
    await promptAndroid.prompt()
    const { outcome } = await promptAndroid.userChoice
    // O evento so pode ser consumido uma vez.
    setPromptAndroid(null)
    setModo(null)
    if (outcome === 'dismissed') dispensar()
  }, [promptAndroid, dispensar])

  if (!modo) return null

  return (
    <div
      style={{
        position: 'fixed',
        left: '12px',
        right: '12px',
        // A barra inferior do mobile tem 64px, mais o recorte do indicador de
        // home do iPhone.
        bottom: 'calc(72px + env(safe-area-inset-bottom))',
        zIndex: 8500,
        backgroundColor: '#fff',
        border: '1.5px solid #C9D0DE',
        borderLeft: '4px solid #1A294A',
        borderRadius: '4px',
        padding: '12px 14px',
        boxShadow: '0 4px 16px rgba(0,0,0,0.18)',
        display: 'flex',
        gap: '10px',
        alignItems: 'flex-start',
      }}
    >
      <Shield size={15} style={{ color: '#1A294A', flexShrink: 0, marginTop: '2px' }} />

      <div style={{ flex: 1, minWidth: 0 }}>
        <p style={{ fontSize: '11px', fontWeight: 800, color: '#1A294A', textTransform: 'uppercase', letterSpacing: '0.08em' }}>
          Instalar na Tela de Início
        </p>
        <p style={{ fontSize: '12px', fontWeight: 600, color: '#0E1A33', marginTop: '2px' }}>
          Abra a escolta com um toque, sem passar pelo navegador.
        </p>

        {modo === 'android' ? (
          <button
            onClick={instalar}
            style={{
              marginTop: '10px',
              display: 'inline-flex',
              alignItems: 'center',
              gap: '6px',
              backgroundColor: '#1A294A',
              color: '#fff',
              border: 'none',
              borderRadius: '3px',
              padding: '8px 14px',
              fontSize: '11px',
              fontWeight: 900,
              textTransform: 'uppercase',
              letterSpacing: '0.08em',
            }}
          >
            <Download size={13} />
            Instalar
          </button>
        ) : (
          <div style={{ marginTop: '8px', display: 'flex', flexDirection: 'column', gap: '6px' }}>
            <p style={{ fontSize: '11px', color: '#5A6A80', display: 'flex', alignItems: 'center', gap: '5px', flexWrap: 'wrap' }}>
              <span>1. Toque em</span>
              <Share size={13} style={{ color: '#1A294A' }} />
              <strong style={{ color: '#0E1A33' }}>Compartilhar</strong>
              <span>na barra do Safari.</span>
            </p>
            <p style={{ fontSize: '11px', color: '#5A6A80', display: 'flex', alignItems: 'center', gap: '5px', flexWrap: 'wrap' }}>
              <span>2. Escolha</span>
              <Plus size={13} style={{ color: '#1A294A' }} />
              <strong style={{ color: '#0E1A33' }}>Adicionar à Tela de Início</strong>.
            </p>
          </div>
        )}
      </div>

      <button
        onClick={dispensar}
        aria-label="Dispensar aviso de instalação"
        style={{ padding: '2px', color: '#A8B8C2', flexShrink: 0 }}
      >
        <X size={13} />
      </button>
    </div>
  )
}
