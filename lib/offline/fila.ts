/**
 * Fila local dos registros de campo feitos sem internet (Lote 2026-10, onda L; docs/14,
 * seção 16.3.1). IndexedDB direto, sem dependência nova.
 *
 * Banco "escolta-campo", versão 1, quatro depósitos:
 * - registros: um por registro de campo (chave seq, ordem de registro), com o client_id
 *   gerado no aparelho, o dono (auth_user_id), a escolta, o tipo, o payload do envelope
 *   (as mesmas linhas que a tela monta hoje), a versao_gestao vista, a hora e o GPS da ação,
 *   a prioridade (emergência primeiro), o estado e as tentativas.
 * - fotos: o blob já carimbado, gravado no momento da captura, com o caminho determinístico
 *   campo/{escolta}/{foto_client_id}.jpg (reenvio depois de queda acha o objeto e conta
 *   como sucesso).
 * - snapshot: o que as telas precisam para abrir sem internet (perfil, escoltas do operador
 *   com versao_gestao), por auth_user_id.
 * - recibos: registros aplicados, guardados 7 dias para o operador conferir.
 *
 * Este módulo não importa nada do app em tempo de execução (só tipos): roda no navegador e
 * nos testes de unidade (node --test com fake-indexeddb).
 */

export const NOME_BANCO = 'escolta-campo'
export const VERSAO_BANCO = 1
export const VERSAO_FILA = 1 as const
export const DIAS_RECIBO = 7

export type TipoRegistro = 'linhas' | 'etapa' | 'presenca_base' | 'emergencia'
/**
 * pendente: guardado, ainda não enviado; enviando: em envio agora (volta a pendente se a
 * página fechar no meio); conflito: o servidor gravou no livro como conflito (supervisão
 * avisada; o operador vê, sem poder apagar); recusado: SEM_VINCULO ou PAYLOAD_INVALIDO
 * (nada gravado no servidor; fica visível em "Registros recusados" e não é reenviado).
 * Aplicado sai da fila e vira recibo.
 */
export type EstadoRegistro = 'pendente' | 'enviando' | 'conflito' | 'recusado'
export type EstadoFoto = 'pendente' | 'subida'

export interface GpsAcao {
  lat: number
  lng: number
  precisao: number | null
}

/** Dados do Telegram que a tela montaria hoje; enviados só depois de aplicado. */
export interface AvisoPosEnvio {
  /** Corpo do POST /api/telegram, como a tela monta hoje. */
  corpo: Record<string, unknown>
  /** Caminho no bucket da foto que vai na mensagem (a URL assinada é gerada no envio). */
  fotoCaminho?: string | null
}

export interface RegistroFila {
  seq?: number
  versao_fila: typeof VERSAO_FILA
  client_id: string
  auth_user_id: string
  usuario_id: string | null
  escolta_id: string
  escolta_veiculo_id: string | null
  tipo: TipoRegistro
  payload: Record<string, unknown>
  versao_gestao: number | null
  data_hora_acao: string
  relogio: Record<string, unknown> | null
  gps: GpsAcao | null
  /** 0 = emergência (sobe primeiro); 1 = demais, na ordem de registro. */
  prioridade: number
  estado: EstadoRegistro
  tentativas: number
  ultimo_erro: string | null
  fotos: string[]
  criado_em: string
  enviado_em?: string | null
  resposta?: Record<string, unknown> | null
  aviso?: AvisoPosEnvio | null
}

/** registro_client_id de uma foto guardada na captura, ainda sem registro. */
export const FOTO_AVULSA = 'avulsa'

export interface FotoFila {
  foto_client_id: string
  registro_client_id: string
  auth_user_id: string
  escolta_id: string
  caminho: string
  blob: Blob
  bytes: number
  tipo_mime: string
  estado: EstadoFoto
  criado_em: string
}

export interface ReciboFila {
  client_id: string
  auth_user_id: string
  escolta_id: string
  tipo: TipoRegistro
  data_hora_acao: string
  recebido_em: string | null
  resultado: 'aplicado'
  texto_offline: string | null
  /** Resposta do registrar_campo (inclui a resposta da etapa: avancou, faltando). */
  resposta: Record<string, unknown> | null
  guardado_em: string
}

export interface SnapshotFila<T = unknown> {
  chave: string
  auth_user_id: string
  nome: string
  dados: T
  salvo_em: string
}

/** Espaço do aparelho acabou: a captura é bloqueada com aviso (S12), nunca perdida em silêncio. */
export class ErroEspacoAparelho extends Error {
  constructor() {
    super('O espaço do aparelho acabou. Envie os registros guardados (procure sinal) ou libere espaço antes de continuar.')
    this.name = 'ErroEspacoAparelho'
  }
}

// ── Abertura ───────────────────────────────────────────────────────────────────────
let fabricaConfigurada: IDBFactory | null = null
let bancoAberto: Promise<IDBDatabase> | null = null

/** Só para os testes (fake-indexeddb) ou para fechar e reabrir. */
export function configurarFabrica(fabrica: IDBFactory | null): void {
  fabricaConfigurada = fabrica
  if (bancoAberto) bancoAberto.then(b => b.close()).catch(() => {})
  bancoAberto = null
}

export function filaDisponivel(): boolean {
  return !!(fabricaConfigurada ?? (typeof indexedDB !== 'undefined' ? indexedDB : null))
}

function abrir(): Promise<IDBDatabase> {
  if (bancoAberto) return bancoAberto
  const fabrica = fabricaConfigurada ?? (typeof indexedDB !== 'undefined' ? indexedDB : null)
  if (!fabrica) return Promise.reject(new Error('Este navegador não guarda registros no aparelho (IndexedDB indisponível).'))
  bancoAberto = new Promise<IDBDatabase>((resolve, reject) => {
    const req = fabrica.open(NOME_BANCO, VERSAO_BANCO)
    req.onupgradeneeded = () => {
      const db = req.result
      if (!db.objectStoreNames.contains('registros')) {
        const r = db.createObjectStore('registros', { keyPath: 'seq', autoIncrement: true })
        r.createIndex('client_id', 'client_id', { unique: true })
        r.createIndex('auth_user_id', 'auth_user_id', { unique: false })
      }
      if (!db.objectStoreNames.contains('fotos')) {
        const f = db.createObjectStore('fotos', { keyPath: 'foto_client_id' })
        f.createIndex('registro_client_id', 'registro_client_id', { unique: false })
      }
      if (!db.objectStoreNames.contains('snapshot')) {
        const s = db.createObjectStore('snapshot', { keyPath: 'chave' })
        s.createIndex('auth_user_id', 'auth_user_id', { unique: false })
      }
      if (!db.objectStoreNames.contains('recibos')) {
        const c = db.createObjectStore('recibos', { keyPath: 'client_id' })
        c.createIndex('auth_user_id', 'auth_user_id', { unique: false })
      }
    }
    req.onsuccess = () => {
      const db = req.result
      // Outra aba abriu uma versão nova: fecha esta para não travar a atualização.
      db.onversionchange = () => { db.close(); bancoAberto = null }
      resolve(db)
    }
    req.onerror = () => { bancoAberto = null; reject(req.error ?? new Error('Falha ao abrir a fila do aparelho.')) }
    req.onblocked = () => { /* espera a outra aba fechar */ }
  })
  return bancoAberto
}

function ehErroDeEspaco(e: unknown): boolean {
  const nome = (e as { name?: string } | null)?.name ?? ''
  return nome === 'QuotaExceededError' || nome === 'NS_ERROR_DOM_QUOTA_REACHED'
}

/** Roda uma transação e resolve quando ela termina (complete), não só quando o pedido volta. */
async function transacao<T>(
  depositos: string[],
  modo: IDBTransactionMode,
  corpo: (t: IDBTransaction) => T | Promise<T>,
): Promise<T> {
  const db = await abrir()
  return new Promise<T>((resolve, reject) => {
    let t: IDBTransaction
    try {
      t = db.transaction(depositos, modo)
    } catch (e) {
      reject(e)
      return
    }
    let valor: T
    t.oncomplete = () => resolve(valor)
    t.onabort = () => reject(ehErroDeEspaco(t.error) ? new ErroEspacoAparelho() : (t.error ?? new Error('Transação da fila abortada.')))
    t.onerror = () => { /* tratado em onabort */ }
    Promise.resolve()
      .then(() => corpo(t))
      .then(v => { valor = v })
      .catch(e => {
        try { t.abort() } catch { /* já terminou */ }
        reject(ehErroDeEspaco(e) ? new ErroEspacoAparelho() : e)
      })
  })
}

function pedido<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

// ── Registros ──────────────────────────────────────────────────────────────────────
/**
 * Guarda o registro e as fotos dele numa transação só: ou fica tudo no aparelho, ou nada
 * (espaço acabou: ErroEspacoAparelho). Devolve o seq (ordem de registro).
 */
export async function guardarRegistro(registro: RegistroFila, fotos: FotoFila[] = []): Promise<number> {
  return transacao(['registros', 'fotos'], 'readwrite', async t => {
    const fs = t.objectStore('fotos')
    for (const f of fotos) await pedido(fs.put(f))
    const r = { ...registro }
    delete r.seq
    return (await pedido(t.objectStore('registros').add(r))) as number
  })
}

export async function lerRegistro(clientId: string): Promise<RegistroFila | null> {
  return transacao(['registros'], 'readonly', async t =>
    ((await pedido(t.objectStore('registros').index('client_id').get(clientId))) as RegistroFila | undefined) ?? null)
}

export async function registrosDoUsuario(authUserId: string): Promise<RegistroFila[]> {
  return transacao(['registros'], 'readonly', async t =>
    (await pedido(t.objectStore('registros').index('auth_user_id').getAll(authUserId))) as RegistroFila[])
}

/** Ordem de envio: emergência primeiro; depois a ordem de registro (seq), nunca o relógio. */
export function ordenarParaEnvio(lista: RegistroFila[]): RegistroFila[] {
  return [...lista].sort((a, b) => (a.prioridade - b.prioridade) || ((a.seq ?? 0) - (b.seq ?? 0)))
}

/** Pendentes do usuário (pendente ou enviando), na ordem de envio. */
export async function pendentesDoUsuario(authUserId: string): Promise<RegistroFila[]> {
  const todos = await registrosDoUsuario(authUserId)
  return ordenarParaEnvio(todos.filter(r => r.estado === 'pendente' || r.estado === 'enviando'))
}

export interface ContagemFila {
  pendentes: number
  conflitos: number
  recusados: number
}

export async function contarFila(authUserId: string): Promise<ContagemFila> {
  const todos = await registrosDoUsuario(authUserId)
  return {
    pendentes: todos.filter(r => r.estado === 'pendente' || r.estado === 'enviando').length,
    conflitos: todos.filter(r => r.estado === 'conflito').length,
    recusados: todos.filter(r => r.estado === 'recusado').length,
  }
}

export async function atualizarRegistro(clientId: string, alteracao: Partial<RegistroFila>): Promise<RegistroFila | null> {
  return transacao(['registros'], 'readwrite', async t => {
    const st = t.objectStore('registros')
    const atual = (await pedido(st.index('client_id').get(clientId))) as RegistroFila | undefined
    if (!atual) return null
    const novo = { ...atual, ...alteracao, seq: atual.seq, client_id: atual.client_id }
    await pedido(st.put(novo))
    return novo
  })
}

/** Registro enviando que ficou para trás (página fechada no meio do envio) volta a pendente. */
export async function recuperarEnviando(authUserId: string): Promise<number> {
  const presos = (await registrosDoUsuario(authUserId)).filter(r => r.estado === 'enviando')
  for (const r of presos) await atualizarRegistro(r.client_id, { estado: 'pendente' })
  return presos.length
}

/**
 * Aplicado: o registro sai da fila, as fotos dele saem do aparelho (já estão no bucket e em
 * fotos) e fica o recibo por 7 dias.
 */
export async function concluirAplicado(clientId: string, recibo: Omit<ReciboFila, 'guardado_em'>): Promise<void> {
  await transacao(['registros', 'fotos', 'recibos'], 'readwrite', async t => {
    const st = t.objectStore('registros')
    const atual = (await pedido(st.index('client_id').get(clientId))) as RegistroFila | undefined
    if (atual?.seq !== undefined) await pedido(st.delete(atual.seq))
    const fs = t.objectStore('fotos')
    const ids = (await pedido(fs.index('registro_client_id').getAllKeys(clientId))) as IDBValidKey[]
    for (const id of ids) await pedido(fs.delete(id))
    await pedido(t.objectStore('recibos').put({ ...recibo, guardado_em: new Date().toISOString() }))
  })
}

/** Conflito ou recusado: o registro fica (visível ao operador); as fotos já subidas saem do aparelho. */
export async function apagarFotosSubidas(clientId: string): Promise<void> {
  await transacao(['fotos'], 'readwrite', async t => {
    const fs = t.objectStore('fotos')
    const lista = (await pedido(fs.index('registro_client_id').getAll(clientId))) as FotoFila[]
    for (const f of lista) if (f.estado === 'subida') await pedido(fs.delete(f.foto_client_id))
  })
}

// ── Fotos ──────────────────────────────────────────────────────────────────────────
export async function lerFoto(fotoClientId: string): Promise<FotoFila | null> {
  return transacao(['fotos'], 'readonly', async t =>
    ((await pedido(t.objectStore('fotos').get(fotoClientId))) as FotoFila | undefined) ?? null)
}

export async function fotosDoRegistro(clientId: string): Promise<FotoFila[]> {
  return transacao(['fotos'], 'readonly', async t =>
    (await pedido(t.objectStore('fotos').index('registro_client_id').getAll(clientId))) as FotoFila[])
}

export async function marcarFotoSubida(fotoClientId: string): Promise<void> {
  await transacao(['fotos'], 'readwrite', async t => {
    const fs = t.objectStore('fotos')
    const f = (await pedido(fs.get(fotoClientId))) as FotoFila | undefined
    if (f && f.estado !== 'subida') await pedido(fs.put({ ...f, estado: 'subida' }))
  })
}

/** Caminho determinístico no bucket (16.3.1): o reenvio acha o mesmo objeto. */
export function caminhoFoto(escoltaId: string, fotoClientId: string): string {
  return `campo/${escoltaId}/${fotoClientId}.jpg`
}

// ── Snapshot ───────────────────────────────────────────────────────────────────────
export async function salvarSnapshot<T>(authUserId: string, nome: string, dados: T): Promise<void> {
  await transacao(['snapshot'], 'readwrite', async t => {
    const s: SnapshotFila<T> = { chave: `${authUserId}:${nome}`, auth_user_id: authUserId, nome, dados, salvo_em: new Date().toISOString() }
    await pedido(t.objectStore('snapshot').put(s))
  })
}

export async function lerSnapshot<T>(authUserId: string, nome: string): Promise<SnapshotFila<T> | null> {
  return transacao(['snapshot'], 'readonly', async t =>
    ((await pedido(t.objectStore('snapshot').get(`${authUserId}:${nome}`))) as SnapshotFila<T> | undefined) ?? null)
}

/** Apaga o snapshot de um usuário (logout) ou de todos menos um (troca de usuário). */
export async function apagarSnapshots(filtro: { doUsuario?: string; excetoUsuario?: string }): Promise<void> {
  await transacao(['snapshot'], 'readwrite', async t => {
    const st = t.objectStore('snapshot')
    const todos = (await pedido(st.getAll())) as SnapshotFila[]
    for (const s of todos) {
      if ((filtro.doUsuario && s.auth_user_id === filtro.doUsuario)
          || (filtro.excetoUsuario && s.auth_user_id !== filtro.excetoUsuario)) {
        await pedido(st.delete(s.chave))
      }
    }
  })
}

// ── Recibos ────────────────────────────────────────────────────────────────────────
export async function recibosDoUsuario(authUserId: string): Promise<ReciboFila[]> {
  return transacao(['recibos'], 'readonly', async t =>
    (await pedido(t.objectStore('recibos').index('auth_user_id').getAll(authUserId))) as ReciboFila[])
}

export async function lerRecibo(clientId: string): Promise<ReciboFila | null> {
  return transacao(['recibos'], 'readonly', async t =>
    ((await pedido(t.objectStore('recibos').get(clientId))) as ReciboFila | undefined) ?? null)
}

/** Foto guardada no momento da captura, antes de o registro existir (blob já carimbado). */
export async function guardarFotoAvulsa(foto: FotoFila): Promise<void> {
  await transacao(['fotos'], 'readwrite', async t => { await pedido(t.objectStore('fotos').put(foto)) })
}

/** Foto avulsa descartada (o operador cancelou o registro antes de confirmar). */
export async function descartarFotoAvulsa(fotoClientId: string): Promise<void> {
  await transacao(['fotos'], 'readwrite', async t => {
    const fs = t.objectStore('fotos')
    const f = (await pedido(fs.get(fotoClientId))) as FotoFila | undefined
    if (f && f.registro_client_id === FOTO_AVULSA) await pedido(fs.delete(fotoClientId))
  })
}

export async function limparRecibos(dias = DIAS_RECIBO, agora = Date.now()): Promise<number> {
  return transacao(['recibos'], 'readwrite', async t => {
    const st = t.objectStore('recibos')
    const todos = (await pedido(st.getAll())) as ReciboFila[]
    let n = 0
    for (const r of todos) {
      if (agora - Date.parse(r.guardado_em) > dias * 86_400_000) { await pedido(st.delete(r.client_id)); n++ }
    }
    return n
  })
}

// ── Identificadores ────────────────────────────────────────────────────────────────
/** UUID v4 gerado no aparelho (crypto.randomUUID, ou getRandomValues onde ele não existe). */
export function novoId(): string {
  const c = (globalThis as { crypto?: Crypto }).crypto
  if (c?.randomUUID) return c.randomUUID()
  const b = new Uint8Array(16)
  if (c?.getRandomValues) c.getRandomValues(b)
  else for (let i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256)
  b[6] = (b[6] & 0x0f) | 0x40
  b[8] = (b[8] & 0x3f) | 0x80
  const h = Array.from(b, x => x.toString(16).padStart(2, '0')).join('')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}
