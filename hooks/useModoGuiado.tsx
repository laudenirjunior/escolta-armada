'use client'

import { createContext, useCallback, useContext, useEffect, useState } from 'react'

/**
 * Chave do Modo Guiado.
 *
 * Decisao de Pecanha em 2026-09-29 (opcao B): nasce LIGADO e o proprio usuario pode
 * desligar. A preferencia fica no aparelho, separada por usuario, porque celular de
 * viatura e compartilhado.
 *
 * Preparado para a opcao A (supervisor decide quem pode desligar): se um dia
 * `usuarios.metadados.modo_guiado.pode_desligar` vier `false`, o modo fica ligado e a
 * preferencia guardada no aparelho e ignorada. Para essa trava valer de verdade ela
 * precisa de migration, porque hoje o proprio usuario consegue gravar a propria
 * linha de `usuarios`; ate la, nada grava esse campo.
 *
 * Context no layout, e nao hook solto: a barra inferior e a tela de Campo precisam
 * enxergar a mesma chave, senao desligar numa nao muda a outra ate recarregar.
 */

interface ModoGuiadoContexto {
  ligado: boolean
  podeDesligar: boolean
  definir: (ligado: boolean) => void
}

const Contexto = createContext<ModoGuiadoContexto>({
  ligado: true,
  podeDesligar: true,
  definir: () => {},
})

function chave(usuarioId: string) {
  return `modoGuiado:${usuarioId}`
}

function lerPreferencia(usuarioId: string | null): boolean {
  if (!usuarioId || typeof window === 'undefined') return true
  try {
    // Ausente vale ligado: so '0' desliga.
    return window.localStorage.getItem(chave(usuarioId)) !== '0'
  } catch {
    // Navegacao privada pode lancar ao ler localStorage. Fica no padrao, ligado.
    return true
  }
}

export function ModoGuiadoProvider({
  usuarioId,
  metadados,
  children,
}: {
  usuarioId: string | null
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  metadados?: any
  children: React.ReactNode
}) {
  const podeDesligar = metadados?.modo_guiado?.pode_desligar !== false
  const [preferencia, setPreferencia] = useState<boolean>(() => lerPreferencia(usuarioId))

  // Troca de usuario no mesmo aparelho relê a preferencia do novo usuario.
  useEffect(() => { setPreferencia(lerPreferencia(usuarioId)) }, [usuarioId])

  const definir = useCallback((ligado: boolean) => {
    setPreferencia(ligado)
    if (!usuarioId) return
    try {
      window.localStorage.setItem(chave(usuarioId), ligado ? '1' : '0')
    } catch {
      // Sem localStorage a escolha vale ate recarregar. Aceitavel.
    }
  }, [usuarioId])

  const ligado = podeDesligar ? preferencia : true

  return (
    <Contexto.Provider value={{ ligado, podeDesligar, definir }}>
      {children}
    </Contexto.Provider>
  )
}

export function useModoGuiado(): ModoGuiadoContexto {
  return useContext(Contexto)
}
