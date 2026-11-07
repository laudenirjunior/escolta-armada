'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { useAuth } from '@/hooks/useAuth'
import { validarSenha, SENHA_MINIMO } from '@/utils/validators'
import { Eye, EyeOff } from 'lucide-react'

function mensagemDeTrocaDeSenha(erro: unknown): string {
  const mensagem = erro instanceof Error ? erro.message.toLocaleLowerCase('pt-BR') : ''
  if (mensagem.includes('fetch') || mensagem.includes('network') || mensagem.includes('conexão')) {
    return 'Sem internet no momento. Confira a conexão e tente novamente.'
  }
  return 'O servidor não conseguiu atualizar a senha. Aguarde um momento e tente novamente.'
}

export default function TrocarSenhaPage() {
  const [novaSenha, setNovaSenha] = useState('')
  const [confirmar, setConfirmar] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [localError, setLocalError] = useState('')
  const [mostrarNovaSenha, setMostrarNovaSenha] = useState(false)
  const [mostrarConfirmacao, setMostrarConfirmacao] = useState(false)
  const router = useRouter()
  const { changePassword, user } = useAuth()

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setLocalError('')

    const { valida, erros } = validarSenha(novaSenha)
    if (!valida) {
      setLocalError(erros.join('. ') + '.')
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
    } catch (erro) {
      setLocalError(mensagemDeTrocaDeSenha(erro))
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
              <div role="alert" aria-live="polite" className="p-3 bg-red-500/10 border border-red-500/20 rounded-sm text-red-500 text-sm">
                {localError}
              </div>
            )}

            <div className="space-y-1.5">
              <Label htmlFor="nova">Nova Senha</Label>
              <div className="relative">
                <Input
                  id="nova"
                  type={mostrarNovaSenha ? 'text' : 'password'}
                  value={novaSenha}
                  onChange={(e) => setNovaSenha(e.target.value)}
                  placeholder={`Mínimo ${SENHA_MINIMO} caracteres`}
                  autoComplete="new-password"
                  className="h-12 pr-12"
                  required
                  disabled={submitting}
                />
                <button
                  type="button"
                  onClick={() => setMostrarNovaSenha((visivel) => !visivel)}
                  aria-label={mostrarNovaSenha ? 'Ocultar nova senha' : 'Mostrar nova senha'}
                  aria-pressed={mostrarNovaSenha}
                  className="absolute inset-y-0 right-0 flex w-12 items-center justify-center text-text-muted hover:text-foreground"
                  disabled={submitting}
                >
                  {mostrarNovaSenha ? <EyeOff size={18} /> : <Eye size={18} />}
                </button>
              </div>
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="confirmar">Confirmar Nova Senha</Label>
              <div className="relative">
                <Input
                  id="confirmar"
                  type={mostrarConfirmacao ? 'text' : 'password'}
                  value={confirmar}
                  onChange={(e) => setConfirmar(e.target.value)}
                  placeholder="Repita a nova senha"
                  autoComplete="new-password"
                  className="h-12 pr-12"
                  required
                  disabled={submitting}
                />
                <button
                  type="button"
                  onClick={() => setMostrarConfirmacao((visivel) => !visivel)}
                  aria-label={mostrarConfirmacao ? 'Ocultar confirmação da senha' : 'Mostrar confirmação da senha'}
                  aria-pressed={mostrarConfirmacao}
                  className="absolute inset-y-0 right-0 flex w-12 items-center justify-center text-text-muted hover:text-foreground"
                  disabled={submitting}
                >
                  {mostrarConfirmacao ? <EyeOff size={18} /> : <Eye size={18} />}
                </button>
              </div>
            </div>

            <Button type="submit" size="lg" className="min-h-14 w-full" disabled={submitting}>
              {submitting ? 'Salvando...' : 'Definir Nova Senha'}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
