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

/** Máscara progressiva de CPF: 000.000.000-00 (aceita digitação só de números) */
export function mascaraCPF(valor: string): string {
  const d = valor.replace(/\D/g, '').slice(0, 11)
  if (d.length > 9) return `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}`
  if (d.length > 6) return `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6)}`
  if (d.length > 3) return `${d.slice(0, 3)}.${d.slice(3)}`
  return d
}

/** Máscara progressiva de telefone: (00) 00000-0000 ou (00) 0000-0000 */
export function mascaraTelefone(valor: string): string {
  const d = valor.replace(/\D/g, '').slice(0, 11)
  if (d.length === 0) return ''
  if (d.length <= 2) return `(${d}`
  if (d.length <= 6) return `(${d.slice(0, 2)}) ${d.slice(2)}`
  if (d.length <= 10) return `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`
  return `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}`
}

/** Gera login do operador no formato primeironome_ultimonome (minúsculo, sem acentos) */
export function gerarLoginOperador(nomeCompleto: string): string {
  const limpo = nomeCompleto
    .normalize('NFD').replace(/\p{Diacritic}/gu, '')
    .toLowerCase().replace(/[^a-z\s]/g, '').trim()
  const partes = limpo.split(/\s+/).filter(Boolean)
  if (partes.length === 0) return ''
  if (partes.length === 1) return partes[0]
  return `${partes[0]}_${partes[partes.length - 1]}`
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
