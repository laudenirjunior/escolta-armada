/**
 * Validadores de dados
 */

export function validarEmail(email: string): boolean {
  const regex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
  return regex.test(email)
}

export function validarCPF(cpf: string): boolean {
  const sanitized = cpf.replace(/\D/g, '')

  if (sanitized.length !== 11) return false
  if (/^(\d)\1{10}$/.test(sanitized)) return false

  let soma = 0
  let resto

  for (let i = 1; i <= 9; i++) {
    soma += parseInt(sanitized.substring(i - 1, i)) * (11 - i)
  }

  resto = (soma * 10) % 11
  if (resto === 10 || resto === 11) resto = 0
  if (resto !== parseInt(sanitized.substring(9, 10))) return false

  soma = 0
  for (let i = 1; i <= 10; i++) {
    soma += parseInt(sanitized.substring(i - 1, i)) * (12 - i)
  }

  resto = (soma * 10) % 11
  if (resto === 10 || resto === 11) resto = 0
  if (resto !== parseInt(sanitized.substring(10, 11))) return false

  return true
}

export function validarSenha(senha: string): {
  valida: boolean
  erros: string[]
} {
  const erros: string[] = []

  if (senha.length < 8) {
    erros.push('Mínimo 8 caracteres')
  }

  if (!/[A-Z]/.test(senha)) {
    erros.push('Deve conter letra maiúscula')
  }

  if (!/[a-z]/.test(senha)) {
    erros.push('Deve conter letra minúscula')
  }

  if (!/[0-9]/.test(senha)) {
    erros.push('Deve conter números')
  }

  return {
    valida: erros.length === 0,
    erros,
  }
}

export function validarPlaca(placa: string): boolean {
  const regex = /^[A-Z]{3}-?[A-Z0-9]{4}$/
  return regex.test(placa.toUpperCase())
}

export function validarCoordenadas(lat: number, lng: number): boolean {
  return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180
}

export function validarQuilometragem(saida: number, retorno?: number): boolean {
  if (saida < 0) return false
  if (retorno !== undefined && retorno < saida) return false
  return true
}

export function validarValor(valor: number): boolean {
  return valor >= 0 && Number.isFinite(valor)
}
