'use client'

/**
 * Entradas de foto e de KM da tela de detalhe da escolta (onda N, 06/11/2026).
 *
 * Saíram de app/dashboard/escoltas/[id]/page.tsx sem mudança de comportamento: CameraInput
 * (câmera ao vivo e seletor de arquivo, com redução e carimbo da onda M), a miniatura do
 * arquivo local, as fotos e o KM por viatura. Import estático: carregar sob demanda quebrava
 * a tela sem internet quando o pedaço de código não estava no cache (testes L1, L3 e L4).
 */
import { useEffect, useRef, useState } from 'react'
import { AlertCircle, Camera, CheckCircle2, Truck } from 'lucide-react'
import { formatarPlaca } from '@/utils/formatters'
import { FOTOS_POR_PONTO } from '@/lib/fluxo-escolta'
import { conferirEspacoParaFoto, textoErroGravacao } from '@/lib/offline/tela'
import { gpsRapido } from '@/lib/gps'
import { aplicarCarimbo, reduzirECarimbarImagem } from '@/lib/carimbo-foto'
import { marcarCarimbada } from '@/lib/foto-captura'

/** O que estas entradas leem de uma viatura da escolta (ViaturaDetalhe da página cabe aqui). */
export interface ViaturaEntrada {
  id: string
  veiculo: { placa: string; modelo: string | null } | null
}

// ─── CameraInput ─────────────────────────────────────────────────────────────

export function CameraInput({
  onChange,
  max = 1,
  prefixoNome = 'foto',
  iniciais,
}: {
  onChange: (files: File[]) => void
  max?: number
  prefixoNome?: string
  /** Fotos já registradas no estado do pai: o componente volta mostrando as miniaturas ao ser remontado. */
  iniciais?: File[]
}) {
  const [fotos, setFotos] = useState<Array<{ file: File; url: string }>>(
    () => (iniciais ?? []).map((file) => ({ file, url: URL.createObjectURL(file) })),
  )
  const [aberto, setAberto] = useState(false)
  const [stream, setStream] = useState<MediaStream | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const videoRef = useRef<HTMLVideoElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const handleFileInput = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    // Onda L (S12): sem espaço no aparelho, a captura é bloqueada com aviso.
    try { await conferirEspacoParaFoto(file.size) } catch (err) {
      setErro(textoErroGravacao(err, 'O espaço do aparelho acabou.'))
      e.target.value = ''
      return
    }
    const agora = new Date()
    e.target.value = ''
    // Onda M (D7 e docs/12 item 2.1): o seletor de arquivo passa pelo mesmo carimbo do Campo,
    // que já reduz (lado maior de 1600 px, JPEG 0,7). Falha do carimbo é declarada: a foto
    // vale como veio e o banco grava carimbo_aplicado = false.
    const gps = await gpsRapido()
    const r = await aplicarCarimbo(file, { timestamp: agora.toISOString(), gps })
    const tsStr = agora.toISOString().replace(/[:.]/g, '-').slice(0, 19)
    // Revisão cruzada (2.6): sem carimbo, o arquivo é o original (HEIC, PNG...): nome e tipo
    // reais, nunca um rótulo de JPEG sobre bytes de outro formato.
    const ext = r.carimbado ? 'jpg' : (r.file.name.split('.').pop() || 'jpg').toLowerCase()
    const namedFile = new File([r.file], `${prefixoNome}_${tsStr}.${ext}`, { type: r.carimbado ? 'image/jpeg' : (r.file.type || 'application/octet-stream') })
    if (r.carimbado) marcarCarimbada(namedFile)
    const novas = [...fotos, { file: namedFile, url: URL.createObjectURL(namedFile) }]
    setFotos(novas)
    onChange(novas.map(f => f.file))
  }

  const abrirCamera = async () => {
    if (fotos.length >= max) return
    setErro(null)
    // Fallback para dispositivos móveis sem suporte a getUserMedia
    if (!navigator.mediaDevices?.getUserMedia) {
      fileInputRef.current?.click()
      return
    }
    setAberto(true)
    try {
      const s = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } },
        audio: false,
      })
      setStream(s)
    } catch {
      // getUserMedia falhou — usa seletor de arquivo nativo (câmera no mobile)
      setAberto(false)
      fileInputRef.current?.click()
    }
  }

  useEffect(() => {
    if (stream && videoRef.current) {
      videoRef.current.srcObject = stream
      videoRef.current.play().catch(() => {})
    }
  }, [stream])

  const capturar = async () => {
    if (!videoRef.current) return
    const v = videoRef.current
    // Revisão cruzada (2.8): o vídeo ainda sem dimensões daria uma foto de 1 por 1.
    if (!v.videoWidth || !v.videoHeight) {
      setErro('A câmera ainda está abrindo. Aguarde um instante e toque de novo.')
      return
    }
    const agora = new Date()
    // Onda M (D7): o vídeo ao vivo passa pela mesma redução e pelo mesmo carimbo do seletor de
    // arquivo e do Campo (lado maior de 1600 px, JPEG 0,7, data, hora e coordenada).
    const gps = await gpsRapido()
    const r = await reduzirECarimbarImagem(v, v.videoWidth, v.videoHeight, { timestamp: agora.toISOString(), gps })
    if (!r.blob) {
      setErro('Não foi possível capturar a foto. Tente de novo ou use o seletor de arquivo.')
      return
    }
    const blob = r.blob
    // Onda L (S12): sem espaço no aparelho, a captura é bloqueada com aviso.
    try { await conferirEspacoParaFoto(blob.size) } catch (err) {
      setErro(textoErroGravacao(err, 'O espaço do aparelho acabou.'))
      return
    }
    const tsStr = agora.toISOString().replace(/[:.]/g, '-').slice(0, 19)
    const file = new File([blob], `${prefixoNome}_${tsStr}.jpg`, { type: 'image/jpeg' })
    if (r.carimbado) marcarCarimbada(file)
    const novas = [...fotos, { file, url: URL.createObjectURL(blob) }]
    setFotos(novas)
    onChange(novas.map(f => f.file))
    if (novas.length >= max) fechar()
  }

  const remover = (idx: number) => {
    URL.revokeObjectURL(fotos[idx].url)
    const novas = fotos.filter((_, i) => i !== idx)
    setFotos(novas)
    onChange(novas.map(f => f.file))
  }

  const fechar = () => {
    stream?.getTracks().forEach(t => t.stop())
    setStream(null)
    setAberto(false)
    setErro(null)
  }

  useEffect(() => () => { stream?.getTracks().forEach(t => t.stop()) }, [stream])
  // Onda M (revisão da onda L, achado 6): miniaturas liberadas quando o componente sai da tela.
  const fotosRef = useRef(fotos)
  fotosRef.current = fotos
  useEffect(() => () => { fotosRef.current.forEach(f => URL.revokeObjectURL(f.url)) }, [])

  const cols = Math.min(fotos.length + (fotos.length < max ? 1 : 0), 4)

  return (
    <>
      {/* Input file hidden — fallback mobile para getUserMedia */}
      <input
        ref={fileInputRef}
        type="file"
        accept="image/*"
        capture="environment"
        style={{ display: 'none' }}
        onChange={handleFileInput}
      />
      {fotos.length > 0 && (
        <div style={{ display: 'grid', gridTemplateColumns: `repeat(${cols}, 1fr)`, gap: '6px', marginBottom: '6px' }}>
          {fotos.map((f, idx) => (
            <div key={idx} style={{ position: 'relative', aspectRatio: '1' }}>
              <img src={f.url} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
              <button type="button" onClick={() => remover(idx)}
                style={{ position: 'absolute', top: 2, right: 2, backgroundColor: '#B83832', color: '#fff', width: '16px', height: '16px', fontSize: '12px', display: 'flex', alignItems: 'center', justifyContent: 'center', border: 'none', cursor: 'pointer', lineHeight: 1 }}>
                ×
              </button>
              <div style={{ position: 'absolute', bottom: 2, left: 2, backgroundColor: 'rgba(0,0,0,0.6)', color: '#fff', fontSize: '8px', fontWeight: 700, padding: '1px 4px' }}>
                {idx + 1}/{max}
              </div>
            </div>
          ))}
          {fotos.length < max && (
            <button type="button" onClick={abrirCamera}
              style={{ aspectRatio: '1', backgroundColor: '#F5F7FA', border: '1.5px dashed #D6DAE5', color: '#5A6A80', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: '4px', cursor: 'pointer' }}>
              <Camera size={16} />
              <span style={{ fontSize: '8px', fontWeight: 700, textTransform: 'uppercase' }}>+ Foto</span>
            </button>
          )}
        </div>
      )}
      {fotos.length === 0 && (
        <button type="button" onClick={abrirCamera}
          className="flex items-center justify-center gap-2 w-full font-black uppercase tracking-widest text-white transition-all active:scale-[0.98]"
          style={{ height: '42px', backgroundColor: '#1A294A', fontSize: '10px', letterSpacing: '0.12em' }}
          onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#253562' }}
          onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#1A294A' }}>
          <Camera size={15} /> Abrir Câmera
        </button>
      )}
      {fotos.length >= max && (
        <div className="flex items-center gap-1.5 mt-1">
          <CheckCircle2 size={11} style={{ color: '#1E7C52' }} />
          <span style={{ fontSize: '10px', fontWeight: 700, color: '#1E7C52' }}>{fotos.length} foto(s) capturada(s)</span>
        </div>
      )}
      {aberto && (
        <div style={{ position: 'fixed', inset: 0, zIndex: 99999, backgroundColor: 'rgba(0,0,0,0.95)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: '1rem', padding: '1rem' }}>
          {erro ? (
            <div style={{ textAlign: 'center', color: '#fff', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '12px' }}>
              <p style={{ fontSize: '14px' }}>{erro}</p>
              <button type="button" onClick={() => { fechar(); fileInputRef.current?.click() }}
                style={{ padding: '0.75rem 1.5rem', backgroundColor: '#1E7C52', color: '#fff', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', display: 'flex', alignItems: 'center', gap: '8px' }}>
                <Camera size={14} /> Selecionar Foto
              </button>
              <button type="button" onClick={fechar} style={{ padding: '0.5rem 1.5rem', backgroundColor: '#53648A', color: '#fff', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em' }}>Cancelar</button>
            </div>
          ) : (
            <>
              <p style={{ color: 'rgba(255,255,255,0.5)', fontSize: '10px', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.12em' }}>
                {stream ? `Foto ${fotos.length + 1} de ${max} — Enquadre e capture` : 'Iniciando câmera...'}
              </p>
              <video ref={videoRef} playsInline autoPlay muted style={{ width: '100%', maxWidth: '480px', maxHeight: '60vh', objectFit: 'cover', backgroundColor: '#111' }} />
              <div style={{ display: 'flex', gap: '0.75rem', width: '100%', maxWidth: '480px' }}>
                <button type="button" onClick={capturar} disabled={!stream}
                  style={{ flex: 1, height: '48px', backgroundColor: stream ? '#1E7C52' : '#333', color: '#fff', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '8px' }}>
                  <Camera size={16} /> Capturar Foto
                </button>
                <button type="button" onClick={fechar}
                  style={{ height: '48px', padding: '0 1.25rem', backgroundColor: fotos.length > 0 ? '#1A294A' : '#B83832', color: '#fff', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em' }}>
                  {fotos.length > 0 ? 'Concluir' : 'Cancelar'}
                </button>
              </div>
            </>
          )}
        </div>
      )}
    </>
  )
}

// ─── Registro por viatura ─────────────────────────────────────────────────────

/**
 * Fotos de um ponto de controle, chaveadas pelo id de `escolta_veiculos`.
 *
 * Decisao de Pecanha: com duas viaturas, cada uma tem o proprio ponto de controle,
 * com foto e localizacao proprias. Antes disso a segunda viatura nao aparecia em
 * lugar nenhum, e se ela se separava do comboio ou atrasava, nada registrava.
 */
export type FotosPorViatura = Record<string, File[]>

/** KM digitado por viatura, chaveado pelo id de `escolta_veiculos`. */
export type KmPorViatura = Record<string, string>

/** Onda H: mesma frase do aviso de FotosViaturasInput, para o wizard sem viatura vinculada. */
export const ERRO_SEM_VIATURA_WIZARD = 'Escolta sem viatura vinculada. Vincule a viatura na aba Veículos antes de continuar.'

/** Onda H: miniatura de um arquivo local (a foto do painel no resumo do Passo 3). */
export function MiniaturaArquivo({ arquivo, rotulo }: { arquivo?: File; rotulo: string }) {
  const [url, setUrl] = useState<string | null>(null)
  useEffect(() => {
    if (!arquivo) { setUrl(null); return }
    const u = URL.createObjectURL(arquivo)
    setUrl(u)
    return () => URL.revokeObjectURL(u)
  }, [arquivo])
  if (!url) {
    return <div style={{ width: 48, height: 48, flexShrink: 0, border: '1.5px dashed #D6DAE5', backgroundColor: '#FFFFFF' }} />
  }
  // eslint-disable-next-line @next/next/no-img-element
  return <img src={url} alt={rotulo} data-miniatura-painel style={{ width: 48, height: 48, flexShrink: 0, objectFit: 'cover', border: '1px solid #D6DAE5' }} />
}

/** Rotulo curto da viatura, para titulo de secao e mensagem de erro. */
export function rotuloViatura(v: ViaturaEntrada): string {
  return v.veiculo?.placa ? formatarPlaca(v.veiculo.placa) : 'Viatura sem placa'
}

/**
 * Uma secao de captura de fotos por viatura.
 *
 * Com uma viatura so, a secao aparece sem cabecalho e sem moldura, identica a tela
 * antiga: o caso comum nao pode ficar mais pesado por causa do comboio de duas.
 */
export function FotosViaturasInput({
  viaturas,
  valor,
  onChange,
  prefixoNome,
  max = FOTOS_POR_PONTO.max,
  manterRegistradas = false,
}: {
  viaturas: ViaturaEntrada[]
  valor: FotosPorViatura
  onChange: (viaturaId: string, files: File[]) => void
  prefixoNome: string
  max?: number
  /** Onda H: ao remontar (Voltar do wizard), mostra as fotos já registradas em `valor`. */
  manterRegistradas?: boolean
}) {
  const varias = viaturas.length > 1

  // Sem viatura vinculada nao ha foto a tirar, e o dialogo ficaria mudo: nenhum botao de
  // camera, nenhuma explicacao, e o confirmar desabilitado para sempre. A mensagem e a
  // mesma de validarPreRequisitos, que nesse estado nem chega a rodar.
  if (viaturas.length === 0) {
    return (
      <div className="p-3" style={{ border: '1.5px solid rgba(184,56,50,0.35)', backgroundColor: 'rgba(184,56,50,0.05)' }}>
        <div className="flex items-start gap-2">
          <AlertCircle size={14} style={{ color: '#B83832', flexShrink: 0, marginTop: 1 }} />
          <p className="text-[11px] leading-relaxed" style={{ color: '#B83832' }}>
            Escolta sem viatura vinculada. Vincule a viatura na aba Veículos antes de
            registrar o ponto de controle.
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className={varias ? 'space-y-3' : undefined}>
      {viaturas.map((v) => {
        const qtd = valor[v.id]?.length ?? 0
        const ok = qtd >= FOTOS_POR_PONTO.min
        return (
          <div
            key={v.id}
            style={varias
              ? { border: `1.5px solid ${ok ? '#1E7C52' : '#D6DAE5'}`, padding: '12px', backgroundColor: ok ? 'rgba(30,124,82,0.04)' : '#F8FAFC' }
              : undefined}
          >
            {varias && (
              <div className="flex items-center gap-2 mb-2">
                {ok
                  ? <CheckCircle2 size={13} style={{ color: '#1E7C52', flexShrink: 0 }} />
                  : <Truck size={13} style={{ color: '#B83832', flexShrink: 0 }} />
                }
                <span className="text-[11px] font-black uppercase tracking-wide" style={{ color: ok ? '#1E7C52' : '#B83832' }}>
                  {rotuloViatura(v)}{v.veiculo?.modelo ? ` · ${v.veiculo.modelo}` : ''}
                </span>
              </div>
            )}
            <CameraInput
              max={max}
              prefixoNome={prefixoNome}
              iniciais={manterRegistradas ? valor[v.id] : undefined}
              onChange={(fs) => onChange(v.id, fs)}
            />
            {max > 1 && (
              <p className="text-[11px] mt-1 text-[#5A6A80]">{qtd} de {max} registradas</p>
            )}
          </div>
        )
      })}
    </div>
  )
}

/** Um campo de KM por viatura, com a placa no rotulo quando ha comboio. */
export function KmViaturasInput({
  viaturas,
  valor,
  onChange,
  label,
  placeholder,
  className = 'input-light w-full',
  labelClassName = 'block text-xs font-semibold mb-1.5 text-[#5A6A80]',
}: {
  viaturas: ViaturaEntrada[]
  valor: KmPorViatura
  onChange: (viaturaId: string, km: string) => void
  label: string
  placeholder?: string
  className?: string
  labelClassName?: string
}) {
  const varias = viaturas.length > 1
  return (
    <div className={varias ? 'space-y-3' : undefined}>
      {viaturas.map((v) => (
        <div key={v.id}>
          <label className={labelClassName}>
            {label}{varias ? ` · ${rotuloViatura(v)}` : ''}
          </label>
          <input
            type="number"
            value={valor[v.id] ?? ''}
            onChange={(e) => onChange(v.id, e.target.value)}
            placeholder={placeholder}
            className={className}
          />
        </div>
      ))}
    </div>
  )
}
