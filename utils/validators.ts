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

/** Comprimento minimo da senha. Decidido com Pecanha: 6, sem exigencia de complexidade. */
export const SENHA_MINIMO = 6

/** Senha provisoria padrao de todo cadastro novo. Trocada no primeiro acesso. */
export const SENHA_PROVISORIA = '123456'

export function validarSenha(senha: string): {
  valida: boolean
  erros: string[]
} {
  const erros: string[] = []

  if (senha.length < SENHA_MINIMO) {
    erros.push(`Mínimo ${SENHA_MINIMO} caracteres`)
  }

  // Nao adianta "trocar" a provisoria por ela mesma.
  if (senha === SENHA_PROVISORIA) {
    erros.push('A nova senha não pode ser igual à senha provisória')
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
