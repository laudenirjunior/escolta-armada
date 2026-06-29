'use client'

import { useEffect, useState } from 'react'
import type { Escolta, StatusEscolta, EstadoSincronizacao } from '@/types'

export function useEscolta(escolaId?: string) {
  const [escolta, setEscolta] = useState<Escolta | null>(null)
  const [loading, setLoading] = useState(!!escolaId)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!escolaId) return

    const fetchEscolta = async () => {
      try {
        setLoading(true)
        // TODO: Buscar escolta do Supabase
        console.log('Fetching escolta:', escolaId)
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Erro ao carregar escolta')
      } finally {
        setLoading(false)
      }
    }

    fetchEscolta()
  }, [escolaId])

  const updateStatus = async (newStatus: StatusEscolta) => {
    if (!escolta) return

    try {
      // TODO: Atualizar status da escolta
      console.log('Update status:', escolaId, newStatus)
      setEscolta({ ...escolta, status: newStatus })
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erro ao atualizar status')
    }
  }

  return {
    escolta,
    loading,
    error,
    updateStatus,
  }
}

export function useSincronizacao() {
  const [estado, setEstado] = useState<EstadoSincronizacao>({
    pendente: 0,
    enviado: 0,
    erros: 0,
  })
  const [sincronizando, setSincronizando] = useState(false)

  const sincronizar = async () => {
    setSincronizando(true)
    try {
      // TODO: Implementar lógica de sincronização
      console.log('Sincronizando...')
    } catch (err) {
      console.error('Erro ao sincronizar:', err)
    } finally {
      setSincronizando(false)
    }
  }

  return {
    estado,
    sincronizando,
    sincronizar,
  }
}
