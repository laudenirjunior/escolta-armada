/**
 * Formatadores de dados para apresentação
 */

export function formatarData(data: string | Date): string {
  const date = typeof data === 'string' ? new Date(data) : data
  return date.toLocaleDateString('pt-BR')
}

export function formatarDataHora(data: string | Date): string {
  const date = typeof data === 'string' ? new Date(data) : data
  return date.toLocaleString('pt-BR')
}

export function formatarHora(data: string | Date): string {
  const date = typeof data === 'string' ? new Date(data) : data
  return date.toLocaleTimeString('pt-BR', {
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function formatarMoeda(valor: number): string {
  return new Intl.NumberFormat('pt-BR', {
    style: 'currency',
    currency: 'BRL',
  }).format(valor)
}

export function formatarCPF(cpf: string): string {
  return cpf
    .replace(/\D/g, '')
    .replace(/(\d{3})(\d{3})(\d{3})(\d{2})/, '$1.$2.$3-$4')
}

export function formatarPlaca(placa: string): string {
  return placa.toUpperCase().replace(/(\w{3})(\w{4})/, '$1-$2')
}

export function formatarCoordenadas(lat: number, lng: number): string {
  return `${lat.toFixed(4)}, ${lng.toFixed(4)}`
}

export function formatarDistancia(metros: number): string {
  if (metros < 1000) {
    return `${metros.toFixed(0)}m`
  }
  return `${(metros / 1000).toFixed(2)}km`
}

export function formatarTempoDecorrido(ms: number): string {
  const segundos = Math.floor(ms / 1000)
  const minutos = Math.floor(segundos / 60)
  const horas = Math.floor(minutos / 60)

  if (horas > 0) {
    return `${horas}h ${minutos % 60}m`
  }
  if (minutos > 0) {
    return `${minutos}m`
  }
  return `${segundos}s`
}

export function gerarCodigoEscolta(): string {
  const timestamp = Date.now().toString(36).toUpperCase()
  const random = Math.random().toString(36).substring(2, 7).toUpperCase()
  return `ESC-${timestamp}-${random}`
}

export function gerarSenhaTemporaria(nome: string, sobrenome: string, cpf: string): string {
  const primeirosDigitos = cpf.replace(/\D/g, '').substring(0, 6)
  return `${nome}${sobrenome}${primeirosDigitos}`.toLocaleLowerCase()
}
