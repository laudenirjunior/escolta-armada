'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'

export default function Home() {
  const [isLoading, setIsLoading] = useState(true)
  const router = useRouter()

  useEffect(() => {
    // Verificar se há usuário autenticado
    // Se não houver, redirecionar para login
    const checkAuth = async () => {
      try {
        // Por enquanto, redirecionar para login
        router.push('/auth/login')
      } catch {
        router.push('/auth/login')
      } finally {
        setIsLoading(false)
      }
    }

    checkAuth()
  }, [router])

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <div className="text-center">
          <h1 className="text-2xl font-[1000] uppercase tracking-[0.2em] text-primary mb-2">
            Escolta Armada
          </h1>
          <p className="text-text-secondary">Carregando...</p>
        </div>
      </div>
    )
  }

  return null
}
