/**
 * Concorrência na mesma escolta (pedido de Peçanha em 2026-11-12): (a) mensagem de conflito com
 * quem, o quê e quando; (c) tempo real na página de detalhe; (d) barra de presença.
 * Rodar: node --test tests/concorrencia.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  FECHO_NADA_GRAVADO, FECHO_TELA_ATUALIZADA, MENSAGEM_CONFLITO_GENERICA,
  agruparPresenca, alteracaoDoHistorico, buscarUltimaAlteracao, classificarConflito, criarAgrupador,
  decidirAtualizacao, iniciais, lerUltimaAlteracao, mensagemConflito, mostrarAvisoAposReler, quandoBrasilia,
  rotuloPresenca, statusMudouNoServidor, textoAtualizadaPor, textoMudancaStatus, textoUltimaAlteracao,
  type ClienteConcorrencia, type Relogio,
} from '../lib/concorrencia.ts'

// 12/11/2026 14:40 em Brasília (17:40 UTC).
const AGORA = new Date('2026-11-12T17:40:00Z')
const RPC_GESTOR = {
  escolta_id: 'e1', status: 'em_transito_destino', versao_gestao: 3, quem_id: 'u2', quem_nome: 'Fulano de Tal',
  perfil: 'Gestor', perfil_codigo: 'gestor', eu: false, o_que: 'etapa avançada para Trânsito p/ Destino',
  quando: '2026-11-12T17:32:10Z', fonte: 'historico',
}

// ── (a) reconhecer o conflito ────────────────────────────────────────────────────

test('a: reconhece as recusas de conflito existentes', () => {
  assert.equal(classificarConflito('ERRO_SEM_TRANSICAO'), 'etapa')
  assert.equal(classificarConflito('A etapa já foi avançada em outra tela ou por outra pessoa. Nenhum registro foi gravado.'), 'etapa')
  assert.equal(classificarConflito('A escolta mudou de status em outro dispositivo. Recarregue a página.'), 'etapa')
  assert.equal(classificarConflito('A escolta mudou desde a prévia: confira a lista de novo antes de confirmar.'), 'previa')
  assert.equal(classificarConflito('A escolta ou as etapas mudaram desde a conferência: confira de novo antes de confirmar.'), 'previa')
  assert.equal(classificarConflito('Esta escolta já está cancelada.'), 'estado')
  assert.equal(classificarConflito('Esta escolta já está arquivada.'), 'estado')
  assert.equal(classificarConflito('Esta escolta não está mais disponível: ela já saiu do mural.'), 'estado')
})

test('a: erro que não é conflito continua sem classificação', () => {
  assert.equal(classificarConflito('Permissão negada.'), null)
  assert.equal(classificarConflito('Informe o motivo com pelo menos 10 caracteres.'), null)
  assert.equal(classificarConflito('erro_sem_transicao com texto a mais'), null)
  assert.equal(classificarConflito(''), null)
  assert.equal(classificarConflito(null), null)
})

// ── (a) a mensagem ───────────────────────────────────────────────────────────────

test('a: mensagem com quem, perfil, o quê e quando (Brasília)', () => {
  const alt = lerUltimaAlteracao(RPC_GESTOR)
  assert.equal(mensagemConflito(alt, { agora: AGORA }),
    'Esta escolta foi alterada por Fulano de Tal (Gestor) às 14h32: etapa avançada para Trânsito p/ Destino. '
    + `${FECHO_NADA_GRAVADO} ${FECHO_TELA_ATUALIZADA}`)
})

test('a: o horário é sempre o de Brasília, qualquer que seja o fuso do aparelho', () => {
  // 02:05 UTC do dia 13 é 23:05 do dia 12 em Brasília.
  assert.equal(quandoBrasilia('2026-11-13T02:05:00Z', new Date('2026-11-13T02:30:00Z')), 'às 23h05')
  assert.equal(quandoBrasilia('2026-11-12T03:15:00Z', AGORA), 'às 00h15')
  assert.equal(quandoBrasilia('2026-11-11T20:00:00Z', AGORA), 'em 11/11 às 17h00')
  assert.equal(quandoBrasilia('2025-12-31T20:00:00Z', AGORA), 'em 31/12/2025 às 17h00')
  assert.equal(quandoBrasilia(null, AGORA), '')
  assert.equal(quandoBrasilia('não é data', AGORA), '')
})

test('a: alteração do próprio usuário em outra tela', () => {
  const alt = lerUltimaAlteracao({ ...RPC_GESTOR, eu: true })
  assert.equal(textoUltimaAlteracao(alt, AGORA),
    'alterada por você, em outra tela ou aparelho, às 14h32: etapa avançada para Trânsito p/ Destino')
  const semHora = lerUltimaAlteracao({ ...RPC_GESTOR, eu: true, quando: null })
  assert.equal(textoUltimaAlteracao(semHora, AGORA), 'alterada por você, em outra tela ou aparelho: etapa avançada para Trânsito p/ Destino')
})

test('a: sem nome (RLS de usuarios ou autor nulo) diz "outra pessoa"; sem perfil, só o nome', () => {
  assert.match(mensagemConflito(lerUltimaAlteracao({ ...RPC_GESTOR, quem_nome: null }), { agora: AGORA }),
    /^Esta escolta foi alterada por outra pessoa às 14h32: etapa avançada/)
  assert.match(mensagemConflito(lerUltimaAlteracao({ ...RPC_GESTOR, perfil: null }), { agora: AGORA }),
    /^Esta escolta foi alterada por Fulano de Tal às 14h32:/)
})

test('a: fallback seguro sem informação nenhuma', () => {
  for (const raw of [null, undefined, 'texto', [], {}, { quem_nome: '  ', o_que: '' }]) {
    const alt = lerUltimaAlteracao(raw)
    assert.equal(alt, null)
    assert.equal(mensagemConflito(alt), `${MENSAGEM_CONFLITO_GENERICA} ${FECHO_NADA_GRAVADO} ${FECHO_TELA_ATUALIZADA}`)
  }
  assert.equal(textoAtualizadaPor(null), 'Esta escolta foi atualizada por outra pessoa.')
})

test('a: data inválida da RPC é descartada sem quebrar o texto', () => {
  const alt = lerUltimaAlteracao({ ...RPC_GESTOR, quando: 'ontem' })
  assert.equal(alt?.quando, null)
  assert.equal(textoUltimaAlteracao(alt, AGORA), 'alterada por Fulano de Tal (Gestor): etapa avançada para Trânsito p/ Destino')
})

test('a: as frases do fim podem ser trocadas ou omitidas pela tela', () => {
  const alt = lerUltimaAlteracao(RPC_GESTOR)
  assert.equal(mensagemConflito(alt, { agora: AGORA, nadaGravado: 'Nada foi gravado.', fecho: 'A prévia foi atualizada; confira e confirme de novo.' }),
    'Esta escolta foi alterada por Fulano de Tal (Gestor) às 14h32: etapa avançada para Trânsito p/ Destino. Nada foi gravado. A prévia foi atualizada; confira e confirme de novo.')
  assert.equal(mensagemConflito(alt, { agora: AGORA, nadaGravado: null, fecho: null }),
    'Esta escolta foi alterada por Fulano de Tal (Gestor) às 14h32: etapa avançada para Trânsito p/ Destino.')
})

test('a: texto da mudança de status segue o mesmo critério da função do banco', () => {
  assert.equal(textoMudancaStatus('na_origem', 'em_transito_destino'), 'etapa avançada para Trânsito p/ Destino')
  assert.equal(textoMudancaStatus('na_origem', 'em_transito_destino', null, true), 'etapa avançada para Trânsito p/ Destino (lançamento retroativo)')
  assert.equal(textoMudancaStatus('na_origem', 'cancelada'), 'escolta cancelada')
  assert.equal(textoMudancaStatus('em_andamento', 'agendada', 'Zerada pela gestão: motivo'), 'escolta zerada para Agendada')
  assert.equal(textoMudancaStatus('no_destino', 'em_transito_destino', 'Reset: motivo'), 'etapa voltada para Trânsito p/ Destino')
  assert.equal(textoMudancaStatus('agendada', 'agendada', 'Reagendamento para 13/11/2026 08:00. Motivo: x'), 'escolta reagendada')
  assert.equal(textoMudancaStatus('no_destino', 'na_origem'), 'status alterado de No Destino para Na Origem')
})

test('a: alteração lida direto do histórico (antes da 223)', () => {
  const alt = alteracaoDoHistorico({
    status_anterior: 'em_andamento', status_novo: 'na_origem', data_hora: '2026-11-12T17:20:00Z', alterado_por: 'u9',
    autor: { nome_completo: 'Beltrano', perfil: { nome_exibicao: 'Operador', codigo: 'operador' } },
  }, 'u1')
  assert.equal(mensagemConflito(alt, { agora: AGORA, nadaGravado: null, fecho: null }),
    'Esta escolta foi alterada por Beltrano (Operador) às 14h20: etapa avançada para Na Origem.')
  assert.equal(alteracaoDoHistorico({ status_anterior: 'a', status_novo: 'na_origem', data_hora: 'x', alterado_por: 'u1' }, 'u1')?.eu, true)
  assert.equal(alteracaoDoHistorico(null), null)
})

test('a: ERRO_SEM_TRANSICAO só é concorrência se o status do servidor mudou', () => {
  const alt = lerUltimaAlteracao(RPC_GESTOR)
  assert.equal(statusMudouNoServidor(alt, 'na_origem'), true)
  assert.equal(statusMudouNoServidor(alt, 'em_transito_destino'), false)
  assert.equal(statusMudouNoServidor(null, 'na_origem'), true, 'sem leitura, na dúvida, é conflito')
})

function clienteFalso(rpc: { data: unknown; error: { code?: string; message?: string } | null }, historico?: unknown[]): ClienteConcorrencia & { chamadas: string[] } {
  const chamadas: string[] = []
  return {
    chamadas,
    rpc: async (fn) => { chamadas.push(`rpc:${fn}`); return rpc },
    from: (t) => {
      chamadas.push(`from:${t}`)
      const fim = { limit: async () => ({ data: historico ?? null, error: historico ? null : { message: 'x' } }) }
      return { select: () => ({ eq: () => ({ order: () => fim }) }) }
    },
  }
}

test('a: busca pela RPC da 223; sem ela, cai no histórico; outro erro, nulo', async () => {
  const c1 = clienteFalso({ data: RPC_GESTOR, error: null })
  assert.equal((await buscarUltimaAlteracao(c1, 'e1'))?.quemNome, 'Fulano de Tal')
  assert.deepEqual(c1.chamadas, ['rpc:ultima_alteracao_escolta'])

  const c2 = clienteFalso({ data: null, error: { code: 'PGRST202', message: 'função ausente' } },
    [{ status_anterior: 'em_andamento', status_novo: 'na_origem', data_hora: '2026-11-12T17:20:00Z', alterado_por: 'u9', autor: null }])
  const alt2 = await buscarUltimaAlteracao(c2, 'e1')
  assert.equal(alt2?.oQue, 'etapa avançada para Na Origem')
  assert.equal(alt2?.quemNome, null)
  assert.deepEqual(c2.chamadas, ['rpc:ultima_alteracao_escolta', 'from:escolta_status_historico'])

  const c3 = clienteFalso({ data: null, error: { code: '42501', message: 'Permissão negada.' } })
  assert.equal(await buscarUltimaAlteracao(c3, 'e1'), null)
  assert.deepEqual(c3.chamadas, ['rpc:ultima_alteracao_escolta'])

  const c4: ClienteConcorrencia = { rpc: async () => { throw new Error('rede') }, from: clienteFalso({ data: null, error: null }).from }
  assert.equal(await buscarUltimaAlteracao(c4, 'e1'), null)
})

// ── (c) tempo real ───────────────────────────────────────────────────────────────

test('c: gravando ignora; editando avisa; senão recarrega', () => {
  assert.equal(decidirAtualizacao({ gravando: true, editando: true }), 'ignorar')
  assert.equal(decidirAtualizacao({ gravando: true, editando: false }), 'ignorar')
  assert.equal(decidirAtualizacao({ gravando: false, editando: true }), 'avisar')
  assert.equal(decidirAtualizacao({ gravando: false, editando: false }), 'recarregar')
})

test('c: aviso depois da releitura só para alteração recente de outra pessoa', () => {
  const recente = { ...RPC_GESTOR, quando: '2026-11-12T17:38:30Z' }
  assert.equal(mostrarAvisoAposReler(lerUltimaAlteracao(recente), AGORA), true)
  assert.equal(mostrarAvisoAposReler(lerUltimaAlteracao({ ...recente, eu: true }), AGORA), false, 'evento do próprio usuário')
  assert.equal(mostrarAvisoAposReler(lerUltimaAlteracao(RPC_GESTOR), AGORA), false, '8 minutos: fora da janela de 5')
  assert.equal(mostrarAvisoAposReler(lerUltimaAlteracao({ ...RPC_GESTOR, quando: '2026-11-12T16:00:00Z' }), AGORA), false, 'antiga')
  assert.equal(mostrarAvisoAposReler(null, AGORA), false)
})

test('c: texto do aviso "atualizada por"', () => {
  assert.equal(textoAtualizadaPor(lerUltimaAlteracao(RPC_GESTOR), AGORA),
    'Esta escolta foi atualizada por Fulano de Tal (Gestor) às 14h32: etapa avançada para Trânsito p/ Destino.')
})

function relogioFalso(): Relogio & { avancar: (ms: number) => void } {
  let t = 0
  let seq = 0
  const fila = new Map<number, { quando: number; fn: () => void }>()
  return {
    agora: () => t,
    setTimeout: (fn, ms) => { const id = ++seq; fila.set(id, { quando: t + ms, fn }); return id },
    clearTimeout: (h) => { fila.delete(h as number) },
    avancar(ms) {
      const fim = t + ms
      for (;;) {
        const prox = [...fila.entries()].filter(([, v]) => v.quando <= fim).sort((a, b) => a[1].quando - b[1].quando)[0]
        if (!prox) break
        fila.delete(prox[0]); t = prox[1].quando; prox[1].fn()
      }
      t = fim
    },
  }
}

test('c: rajada de eventos vira uma releitura só (debounce)', () => {
  const r = relogioFalso()
  let n = 0
  const ag = criarAgrupador(() => { n++ }, 600, 3000, r)
  ag.evento(); r.avancar(200); ag.evento(); r.avancar(200); ag.evento()
  assert.equal(n, 0)
  r.avancar(599)
  assert.equal(n, 0)
  r.avancar(1)
  assert.equal(n, 1)
  assert.equal(ag.pendente(), false)
})

test('c: fluxo contínuo dispara no máximo a cada maxEspera', () => {
  const r = relogioFalso()
  let n = 0
  const ag = criarAgrupador(() => { n++ }, 600, 2000, r)
  for (let i = 0; i < 10; i++) { ag.evento(); r.avancar(300) }
  // 3000 ms de eventos a cada 300 ms: dispara em 2000 e de novo 600 ms depois do último.
  assert.equal(n, 1)
  r.avancar(600)
  assert.equal(n, 2)
})

test('c: cancelar (unmount) não dispara depois', () => {
  const r = relogioFalso()
  let n = 0
  const ag = criarAgrupador(() => { n++ }, 600, 2000, r)
  ag.evento(); ag.cancelar(); r.avancar(5000)
  assert.equal(n, 0)
})

// ── (d) presença ─────────────────────────────────────────────────────────────────

test('d: agrupa abas do mesmo usuário, tira o próprio e ordena (editando primeiro, depois nome)', () => {
  const lista = agruparPresenca({
    a1: [{ usuario_id: 'eu', nome: 'Eu Mesmo', perfil: 'Gestor', desde: '2026-11-12T17:00:00Z' }],
    a2: [{ usuario_id: 'u3', nome: 'Zélia Souza', perfil: 'Central', desde: '2026-11-12T17:10:00Z' }],
    a3: [{ usuario_id: 'u2', nome: 'Ana Lima', perfil: 'Supervisor', desde: '2026-11-12T17:05:00Z' }],
    a4: [{ usuario_id: 'u3', nome: 'Zélia Souza', perfil: 'Central', editando: true, desde: '2026-11-12T17:02:00Z' }],
    a5: [{ usuario_id: 'eu', nome: 'Eu Mesmo', perfil: 'Gestor', editando: true }],
    a6: [{ usuario_id: 'u4', nome: 'Bruno Alves', perfil: 'Operador' }],
  }, 'eu')
  assert.deepEqual(lista.map(p => p.usuarioId), ['u3', 'u2', 'u4'])
  assert.equal(lista[0].abas, 2)
  assert.equal(lista[0].editando, true)
  assert.equal(lista[0].desde, '2026-11-12T17:02:00Z', 'a aba mais antiga')
  assert.equal(rotuloPresenca(lista[0]), 'Zélia Souza (Central), editando')
  assert.equal(rotuloPresenca(lista[1]), 'Ana Lima (Supervisor)')
})

test('d: sozinho na escolta, a barra fica vazia; metas inválidas são ignoradas', () => {
  assert.deepEqual(agruparPresenca({ a: [{ usuario_id: 'eu', nome: 'Eu', perfil: null }] }, 'eu'), [])
  assert.deepEqual(agruparPresenca({ a: undefined, b: [] }, 'eu'), [])
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(agruparPresenca({ a: [{ nome: 'Sem id' } as any] }, 'eu'), [])
  const semNome = agruparPresenca({ a: [{ usuario_id: 'u1', nome: '', perfil: null }] }, null)
  assert.equal(semNome[0].nome, 'Usuário')
  assert.equal(semNome[0].iniciais, '?')
})

test('d: iniciais do avatar', () => {
  assert.equal(iniciais('Maria da Silva'), 'MS')
  assert.equal(iniciais('João'), 'J')
  assert.equal(iniciais('  ana   de souza  lima '), 'AL')
  assert.equal(iniciais('Érico dos Santos'), 'ÉS')
  assert.equal(iniciais(null), '?')
})
