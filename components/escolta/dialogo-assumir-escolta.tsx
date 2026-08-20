'use client'

import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle, Users, Truck, X, Loader2 } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'

/**
 * Assumir uma escolta do mural, inclusive quando ja ha equipe escalada.
 *
 * O caso que originou isto, trazido por Pecanha em 2026-08-20: a dupla escalada faltou,
 * a gestao nao esta disponivel para reescalar, e a escolta nao pode parar. Os operadores
 * presentes precisam conseguir assumir sozinhos, colocar o proprio nome, o do companheiro
 * e a viatura que de fato vao usar.
 *
 * Substituir equipe de colega e ato sensivel, entao o dialogo faz tres coisas antes:
 * mostra QUEM esta escalado e em QUAL viatura, pede confirmacao explicita, e exige o
 * motivo por escrito. A RPC `assumir_escolta` grava tudo em `logs_auditoria` antes de
 * apagar o que existia, para o registro sobreviver a substituicao.
 *
 * Escolta que ainda nao tem equipe pula a confirmacao e o motivo: nao ha nada a
 * substituir, e transformar o caminho simples em burocracia so faria o operador evitar
 * o sistema.
 */

const sb = createClient() as any

interface Membro { vigilante_id: string; nome: string; papel: string }
interface Viatura { escolta_veiculo_id: string; veiculo_id: string; placa: string | null; modelo: string | null }
interface VigilanteOpt { id: string; nome: string; funcao: string | null }
interface VeiculoOpt { id: string; placa: string; modelo: string | null }

type Etapa = 'carregando' | 'confirmar' | 'editar' | 'enviando'

export function DialogoAssumirEscolta({
  escoltaId,
  codigo,
  meuVigilanteId,
  onFechar,
  onAssumido,
}: {
  escoltaId: string
  codigo: string | null
  /** Vigilante vinculado a quem esta usando. Ele vira o comandante. */
  meuVigilanteId: string | null
  onFechar: () => void
  onAssumido: (substituiu: boolean) => void
}) {
  const [etapa, setEtapa] = useState<Etapa>('carregando')
  const [erro, setErro] = useState<string | null>(null)

  const [equipeAtual, setEquipeAtual] = useState<Membro[]>([])
  const [viaturaAtual, setViaturaAtual] = useState<Viatura | null>(null)

  const [vigilantes, setVigilantes] = useState<VigilanteOpt[]>([])
  const [veiculos, setVeiculos] = useState<VeiculoOpt[]>([])

  const [acompanhantes, setAcompanhantes] = useState<string[]>([])
  const [trocarViatura, setTrocarViatura] = useState(false)
  const [veiculoNovo, setVeiculoNovo] = useState('')
  const [motivo, setMotivo] = useState('')

  const temEquipe = equipeAtual.length > 0

  const carregar = useCallback(async () => {
    setEtapa('carregando')
    setErro(null)
    try {
      const [{ data: info, error: e1 }, { data: vigs, error: e2 }, { data: veics }] = await Promise.all([
        sb.rpc('equipe_escalada', { p_escolta_id: escoltaId }),
        sb.rpc('vigilantes_para_escala'),
        sb.from('veiculos').select('id, placa, modelo').eq('status', 'ativo').order('placa'),
      ])
      if (e1) throw new Error(e1.message)
      if (e2) throw new Error(e2.message)

      const equipe: Membro[] = info?.equipe ?? []
      setEquipeAtual(equipe)
      setViaturaAtual(info?.viaturas?.[0] ?? null)
      setVigilantes(vigs ?? [])
      setVeiculos(veics ?? [])

      // Sem equipe nao ha o que confirmar: vai direto para a montagem.
      setEtapa(equipe.length > 0 ? 'confirmar' : 'editar')
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Não foi possível carregar a escolta.')
      setEtapa('confirmar')
    }
  }, [escoltaId])

  useEffect(() => { carregar() }, [carregar])

  const alternarAcompanhante = (id: string) =>
    setAcompanhantes(a => a.includes(id) ? a.filter(x => x !== id) : [...a, id])

  const enviar = async () => {
    setErro(null)
    if (temEquipe && motivo.trim().length < 5) {
      setErro('Descreva o motivo da substituição. Ele fica registrado no histórico da escolta.')
      return
    }
    if (trocarViatura && !veiculoNovo) {
      setErro('Selecione a viatura que será usada.')
      return
    }
    setEtapa('enviando')
    const { data, error } = await sb.rpc('assumir_escolta', {
      p_escolta_id: escoltaId,
      p_acompanhantes: acompanhantes,
      p_veiculo_id: trocarViatura ? veiculoNovo : null,
      p_motivo: motivo.trim() || null,
    })
    if (error) {
      setErro(error.message ?? 'Não foi possível assumir a escolta.')
      setEtapa('editar')
      return
    }
    onAssumido(Boolean(data?.substituiu_equipe))
  }

  // O proprio usuario nao entra na lista de acompanhantes: ele ja e o comandante.
  const opcoesAcompanhante = vigilantes.filter(v => v.id !== meuVigilanteId)

  return (
    <div
      className="fixed inset-0 z-[9000] flex items-end md:items-center justify-center p-0 md:p-4"
      style={{ backgroundColor: 'rgba(11,17,32,0.6)' }}
      onClick={onFechar}
    >
      <div
        className="w-full md:max-w-lg bg-white max-h-[92vh] overflow-y-auto"
        style={{ borderRadius: '2px' }}
        onClick={e => e.stopPropagation()}
      >
        {/* Cabeçalho */}
        <div className="flex items-center justify-between px-5 py-4 sticky top-0 bg-white" style={{ borderBottom: '1px solid #E2E8EC' }}>
          <div>
            <p className="text-[10px] font-black uppercase tracking-widest" style={{ color: '#6B7E8A' }}>
              {temEquipe ? 'Escolta já escalada' : 'Assumir escolta'}
            </p>
            <p className="text-sm font-black" style={{ color: '#1E2D35' }}>{codigo ?? 'Escolta'}</p>
          </div>
          <button onClick={onFechar} className="p-1" style={{ color: '#6B7E8A' }} aria-label="Fechar">
            <X size={18} />
          </button>
        </div>

        <div className="p-5 space-y-4">
          {etapa === 'carregando' && (
            <div className="py-10 flex items-center justify-center gap-2" style={{ color: '#6B7E8A' }}>
              <Loader2 size={16} className="animate-spin" />
              <span className="text-sm">Carregando a escala atual…</span>
            </div>
          )}

          {/* ── Confirmação: quem já está escalado ── */}
          {etapa === 'confirmar' && (
            <>
              <div className="p-4" style={{ border: '1.5px solid #C8813A', backgroundColor: '#FFFBEB' }}>
                <div className="flex items-start gap-2 mb-3">
                  <AlertTriangle size={16} style={{ color: '#8A5A10', flexShrink: 0, marginTop: 1 }} />
                  <p className="text-xs font-bold leading-relaxed" style={{ color: '#8A5A10' }}>
                    Esta escolta já tem equipe designada. Se você assumir, a equipe abaixo
                    será substituída e o registro ficará no histórico do sistema.
                  </p>
                </div>

                <div className="space-y-2 pl-1">
                  <div className="flex items-start gap-2">
                    <Users size={13} style={{ color: '#8A5A10', flexShrink: 0, marginTop: 2 }} />
                    <div>
                      <p className="text-[10px] font-black uppercase tracking-wider" style={{ color: '#8A5A10' }}>Equipe escalada</p>
                      {equipeAtual.map(m => (
                        <p key={m.vigilante_id} className="text-xs" style={{ color: '#1E2D35' }}>
                          {m.nome}
                          <span className="ml-1 text-[10px]" style={{ color: '#6B7E8A' }}>
                            ({m.papel === 'comandante' ? 'comandante' : 'operador'})
                          </span>
                        </p>
                      ))}
                    </div>
                  </div>

                  {viaturaAtual && (
                    <div className="flex items-start gap-2">
                      <Truck size={13} style={{ color: '#8A5A10', flexShrink: 0, marginTop: 2 }} />
                      <div>
                        <p className="text-[10px] font-black uppercase tracking-wider" style={{ color: '#8A5A10' }}>Viatura</p>
                        <p className="text-xs" style={{ color: '#1E2D35' }}>
                          {viaturaAtual.placa ?? 'sem placa'}
                          {viaturaAtual.modelo ? ` · ${viaturaAtual.modelo}` : ''}
                        </p>
                      </div>
                    </div>
                  )}
                </div>
              </div>

              <p className="text-sm font-bold text-center" style={{ color: '#1E2D35' }}>
                Deseja realmente assumir esta escolta?
              </p>

              {erro && (
                <p className="text-xs p-2" style={{ color: '#B83832', backgroundColor: 'rgba(184,56,50,0.08)' }}>{erro}</p>
              )}

              <div className="flex gap-2">
                <button onClick={onFechar}
                  className="flex-1 text-xs font-bold" style={{ minHeight: '44px', border: '1px solid #C8D5DC', color: '#5A6A80' }}>
                  Cancelar
                </button>
                <button onClick={() => setEtapa('editar')}
                  className="flex-1 text-xs font-black uppercase tracking-wider text-white"
                  style={{ minHeight: '44px', backgroundColor: '#C8813A' }}>
                  Sim, assumir
                </button>
              </div>
            </>
          )}

          {/* ── Montagem da equipe ── */}
          {(etapa === 'editar' || etapa === 'enviando') && (
            <>
              <div className="p-3" style={{ backgroundColor: '#EBF7F1', border: '1px solid rgba(30,124,82,0.25)' }}>
                <p className="text-xs" style={{ color: '#1E7C52' }}>
                  Você entra como <strong>comandante</strong> desta escolta.
                </p>
              </div>

              <div>
                <label className="block text-[11px] font-black uppercase tracking-widest mb-2" style={{ color: '#6B7E8A' }}>
                  Quem vai com você
                </label>
                {opcoesAcompanhante.length === 0 ? (
                  <p className="text-xs" style={{ color: '#A8B8C2' }}>Nenhum outro vigilante ativo cadastrado.</p>
                ) : (
                  <div className="space-y-1 max-h-44 overflow-y-auto" style={{ border: '1px solid #E2E8EC' }}>
                    {opcoesAcompanhante.map(v => (
                      <label key={v.id}
                        className="flex items-center gap-2 px-3 py-2 cursor-pointer"
                        style={{ backgroundColor: acompanhantes.includes(v.id) ? '#EBF3FC' : 'transparent' }}>
                        <input type="checkbox" checked={acompanhantes.includes(v.id)}
                          onChange={() => alternarAcompanhante(v.id)} />
                        <span className="text-xs" style={{ color: '#1E2D35' }}>{v.nome}</span>
                        {v.funcao && <span className="text-[10px]" style={{ color: '#A8B8C2' }}>{v.funcao}</span>}
                      </label>
                    ))}
                  </div>
                )}
                <p className="text-[10px] mt-1" style={{ color: '#A8B8C2' }}>
                  Pode deixar em branco e incluir depois, se ainda não souber.
                </p>
              </div>

              <div>
                <label className="flex items-center gap-2 cursor-pointer">
                  <input type="checkbox" checked={trocarViatura} onChange={e => setTrocarViatura(e.target.checked)} />
                  <span className="text-xs font-semibold" style={{ color: '#1E2D35' }}>
                    Vamos usar outra viatura
                  </span>
                </label>
                {viaturaAtual && !trocarViatura && (
                  <p className="text-[10px] mt-1 ml-6" style={{ color: '#A8B8C2' }}>
                    Mantendo {viaturaAtual.placa ?? 'a viatura atual'}
                    {viaturaAtual.modelo ? ` · ${viaturaAtual.modelo}` : ''}
                  </p>
                )}
                {trocarViatura && (
                  <select value={veiculoNovo} onChange={e => setVeiculoNovo(e.target.value)}
                    className="input-light w-full mt-2 text-sm" style={{ minHeight: '44px' }}>
                    <option value="">Selecione a viatura</option>
                    {veiculos.map(v => (
                      <option key={v.id} value={v.id}>{v.placa}{v.modelo ? ` · ${v.modelo}` : ''}</option>
                    ))}
                  </select>
                )}
              </div>

              {temEquipe && (
                <div>
                  <label className="block text-[11px] font-black uppercase tracking-widest mb-1" style={{ color: '#6B7E8A' }}>
                    Motivo da substituição *
                  </label>
                  <textarea value={motivo} onChange={e => setMotivo(e.target.value)} rows={3}
                    className="input-light w-full text-sm"
                    placeholder="Ex: equipe escalada não compareceu. Assumindo com a dupla disponível na base." />
                  <p className="text-[10px] mt-1" style={{ color: '#A8B8C2' }}>
                    Fica registrado no histórico, junto com quem estava escalado antes.
                  </p>
                </div>
              )}

              {erro && (
                <p className="text-xs p-2" style={{ color: '#B83832', backgroundColor: 'rgba(184,56,50,0.08)' }}>{erro}</p>
              )}

              <div className="flex gap-2">
                <button onClick={onFechar} disabled={etapa === 'enviando'}
                  className="flex-1 text-xs font-bold disabled:opacity-50"
                  style={{ minHeight: '44px', border: '1px solid #C8D5DC', color: '#5A6A80' }}>
                  Cancelar
                </button>
                <button onClick={enviar} disabled={etapa === 'enviando'}
                  className="flex-1 text-xs font-black uppercase tracking-wider text-white disabled:opacity-50"
                  style={{ minHeight: '44px', backgroundColor: '#1E7C52' }}>
                  {etapa === 'enviando' ? 'Assumindo…' : temEquipe ? 'Substituir e assumir' : 'Assumir escolta'}
                </button>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  )
}
