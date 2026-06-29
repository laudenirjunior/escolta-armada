'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { useAuth } from '@/hooks/useAuth'

export default function TrocarSenhaPage() {
  const [novaSenha, setNovaSenha] = useState('')
  const [confirmar, setConfirmar] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [localError, setLocalError] = useState('')
  const router = useRouter()
  const { changePassword, user } = useAuth()

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setLocalError('')

    if (novaSenha.length < 8) {
      setLocalError('A senha deve ter pelo menos 8 caracteres.')
      return
    }
    if (novaSenha !== confirmar) {
      setLocalError('As senhas não coincidem.')
      return
    }

    setSubmitting(true)
    try {
      await changePassword(novaSenha)
      router.push('/dashboard')
    } catch {
      setLocalError('Erro ao atualizar a senha. Tente novamente.')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-background p-4">
      <Card className="w-full max-w-md">
        <CardHeader className="pb-4">
          <CardTitle>Troca de Senha Obrigatória</CardTitle>
          <p className="text-sm text-text-secondary mt-1">
            Olá, {user?.nome_completo?.split(' ')[0]}. Por segurança, defina uma nova senha antes de continuar.
          </p>
        </CardHeader>

        <CardContent>
          <form onSubmit={handleSubmit} className="space-y-4">
            {localError && (
              <div className="p-3 bg-red-500/10 border border-red-500/20 rounded-sm text-red-500 text-sm">
                {localError}
              </div>
            )}

            <div className="space-y-1.5">
              <Label htmlFor="nova">Nova Senha</Label>
              <Input
                id="nova"
                type="password"
                value={novaSenha}
                onChange={(e) => setNovaSenha(e.target.value)}
                placeholder="Mínimo 8 caracteres"
                required
                disabled={submitting}
              />
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="confirmar">Confirmar Nova Senha</Label>
              <Input
                id="confirmar"
                type="password"
                value={confirmar}
                onChange={(e) => setConfirmar(e.target.value)}
                placeholder="Repita a nova senha"
                required
                disabled={submitting}
              />
            </div>

            <Button type="submit" className="w-full" disabled={submitting}>
              {submitting ? 'Salvando...' : 'Definir Nova Senha'}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
