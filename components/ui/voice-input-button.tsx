'use client'

import { useState, useRef, useEffect } from 'react'
import { Mic, MicOff, Square } from 'lucide-react'

interface VoiceInputButtonProps {
  onTranscript: (text: string) => void
  style?: React.CSSProperties
  className?: string
  disabled?: boolean
}

declare global {
  interface Window {
    SpeechRecognition: new () => SpeechRecognition
    webkitSpeechRecognition: new () => SpeechRecognition
  }
}

interface SpeechRecognition extends EventTarget {
  continuous: boolean
  interimResults: boolean
  lang: string
  start(): void
  stop(): void
  abort(): void
  onresult: ((event: SpeechRecognitionEvent) => void) | null
  onerror: ((event: SpeechRecognitionErrorEvent) => void) | null
  onend: (() => void) | null
}

interface SpeechRecognitionEvent extends Event {
  results: SpeechRecognitionResultList
  resultIndex: number
}

interface SpeechRecognitionResultList {
  length: number
  item(index: number): SpeechRecognitionResult
  [index: number]: SpeechRecognitionResult
}

interface SpeechRecognitionResult {
  isFinal: boolean
  length: number
  item(index: number): SpeechRecognitionAlternative
  [index: number]: SpeechRecognitionAlternative
}

interface SpeechRecognitionAlternative {
  transcript: string
  confidence: number
}

interface SpeechRecognitionErrorEvent extends Event {
  error: string
}

export function VoiceInputButton({ onTranscript, style, className, disabled }: VoiceInputButtonProps) {
  const [escutando, setEscutando] = useState(false)
  const [suportado, setSuportado] = useState(true)
  const [erro, setErro] = useState(false)
  const recRef = useRef<SpeechRecognition | null>(null)

  useEffect(() => {
    const SR = window.SpeechRecognition ?? window.webkitSpeechRecognition
    if (!SR) { setSuportado(false); return }
  }, [])

  const iniciar = () => {
    const SR = window.SpeechRecognition ?? window.webkitSpeechRecognition
    if (!SR) return

    const rec = new SR()
    rec.lang = 'pt-BR'
    rec.continuous = false
    rec.interimResults = false
    recRef.current = rec

    rec.onresult = (event: SpeechRecognitionEvent) => {
      const transcript = Array.from({ length: event.results.length })
        .map((_, i) => event.results[i][0].transcript)
        .join(' ')
        .trim()
      if (transcript) onTranscript(transcript)
    }

    rec.onerror = () => {
      setErro(true)
      setEscutando(false)
      setTimeout(() => setErro(false), 2000)
    }

    rec.onend = () => setEscutando(false)

    rec.start()
    setEscutando(true)
    setErro(false)
  }

  const parar = () => {
    recRef.current?.stop()
    setEscutando(false)
  }

  if (!suportado) return null

  return (
    <button
      type="button"
      onClick={escutando ? parar : iniciar}
      disabled={disabled}
      title={escutando ? 'Parar gravação' : 'Gravar voz'}
      className={className}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: '28px',
        height: '28px',
        borderRadius: '2px',
        border: escutando
          ? '1px solid rgba(184,56,50,0.6)'
          : erro
          ? '1px solid #B83832'
          : '1px solid rgba(83,100,138,0.3)',
        backgroundColor: escutando
          ? 'rgba(184,56,50,0.15)'
          : erro
          ? 'rgba(184,56,50,0.1)'
          : 'rgba(83,100,138,0.08)',
        color: escutando ? '#B83832' : erro ? '#B83832' : '#53648A',
        cursor: disabled ? 'not-allowed' : 'pointer',
        opacity: disabled ? 0.5 : 1,
        transition: 'all 150ms',
        flexShrink: 0,
        position: 'relative',
        ...style,
      }}
    >
      {escutando ? (
        <>
          <Square size={10} style={{ fill: '#B83832' }} />
          {/* Animação de pulso */}
          <span style={{
            position: 'absolute', inset: 0, borderRadius: '2px',
            border: '1px solid rgba(184,56,50,0.5)',
            animation: 'pulse 1s ease-in-out infinite',
          }} />
        </>
      ) : erro ? (
        <MicOff size={11} />
      ) : (
        <Mic size={11} />
      )}
    </button>
  )
}
