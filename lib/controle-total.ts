/**
 * Controle total da gestão (pedido de Peçanha em 2026-11-12): gestor e administrador cancelam
 * e excluem qualquer escolta, em qualquer status. Supervisor, central e operador continuam
 * exatamente como antes. Quem garante a regra é o banco (migration 221 e anteriores); aqui
 * só o que a tela oferece, para não mostrar botão que o banco vai recusar.
 *
 * Testes: node --test tests/controle-total.test.ts
 */
import { PODE_CANCELAR_ESCOLTA, PODE_EXCLUIR_ESCOLTA, PODE_VER_ARQUIVADAS, temPermissao } from './permissions.ts'

type Perfil = string | null | undefined

export interface EstadoEscolta {
  status: string
  arquivada_em?: string | null
}

/**
 * Como cancelar esta escolta, para este perfil:
 * - 'etapa': o caminho de sempre (registrar_etapa_escolta). Vale para supervisor, gestor e
 *   administrador em qualquer status antes de finalizada; não depende da migration 221.
 * - 'gestao': escolta finalizada, só gestor e administrador, pela RPC cancelar_escolta_gestao
 *   (migration 221). Sem a 221 o banco recusa e a tela avisa.
 * - null: não cancela (já cancelada, arquivada ou perfil sem permissão).
 *
 * Arquivada não muda de status (trava da 214): recuperar antes e então cancelar, ou excluir.
 */
export function modoCancelamento(perfil: Perfil, e: EstadoEscolta): 'etapa' | 'gestao' | null {
  if (e.arquivada_em || e.status === 'cancelada') return null
  if (e.status === 'finalizada') return temPermissao(perfil, PODE_EXCLUIR_ESCOLTA) ? 'gestao' : null
  return temPermissao(perfil, PODE_CANCELAR_ESCOLTA) ? 'etapa' : null
}

/** Reagendar devolve a escolta para agendada: não existe a partir de finalizada. */
export function podeReagendar(e: EstadoEscolta): boolean {
  return !e.arquivada_em && !['finalizada', 'cancelada'].includes(e.status)
}

/** Excluir: gestor e administrador, em qualquer status, inclusive arquivada. */
export function podeExcluirEscolta(perfil: Perfil): boolean {
  return temPermissao(perfil, PODE_EXCLUIR_ESCOLTA)
}

/** Recuperar do arquivo: administrador e gestor (o gestor depende da migration 221). */
export function podeRecuperarArquivada(perfil: Perfil): boolean {
  return temPermissao(perfil, PODE_VER_ARQUIVADAS)
}

export const MOTIVO_MINIMO = 10
export const MOTIVO_MAXIMO = 1000

/**
 * Exclusão em duas etapas explícitas. Etapa 1: motivo (10 a 1000 caracteres, como o banco
 * exige) e a caixa "entendi". Etapa 2: digitar o código da escolta exatamente como aparece.
 * Só com as duas a tela chama excluir_escolta.
 */
export function exclusaoEtapa1Ok(motivo: string, entendi: boolean): boolean {
  const m = motivo.trim().length
  return entendi && m >= MOTIVO_MINIMO && m <= MOTIVO_MAXIMO
}

export function exclusaoEtapa2Ok(codigoDigitado: string, codigoEscolta: string | null | undefined): boolean {
  const alvo = (codigoEscolta ?? '').trim().toUpperCase()
  return alvo.length > 0 && codigoDigitado.trim().toUpperCase() === alvo
}

export const MSG_DEPENDE_221 =
  'Esta ação depende da atualização do banco (migration 221), ainda não aplicada. Nada foi alterado. Peça ao administrador do sistema para aplicá-la.'
