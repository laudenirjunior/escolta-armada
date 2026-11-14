/**
 * Criação de escolta (2026-11-13, migration 224): nova tentativa na colisão do código, mensagem
 * real do banco, trava do duplo clique e data de partida.
 * Rodar: node --test tests/criar-escolta.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  criarEscolta, criarTrava, dataHoraPrevistaISO, ehColisaoCodigo, funcaoAusente, mensagemErroBanco,
  type ClienteRpc, type ErroBanco,
} from '../lib/criar-escolta.ts'

const COLISAO: ErroBanco = {
  code: '23505', message: 'duplicate key value violates unique constraint "escoltas_codigo_escolta_key"',
  details: 'Key (codigo_escolta)=(ESC-2026-0010) already exists.',
}

/** Cliente falso: devolve as respostas na ordem e guarda as chamadas. */
function falso(respostas: Array<{ data: unknown; error: ErroBanco | null }>) {
  const chamadas: Array<{ fn: string; args: Record<string, unknown> }> = []
  const sb: ClienteRpc = {
    rpc: async (fn, args) => { chamadas.push({ fn, args }); return respostas.shift() ?? { data: null, error: { message: 'sem resposta' } } },
  }
  return { sb, chamadas }
}

test('colisão do código: reconhece só a restrição do codigo_escolta', () => {
  assert.equal(ehColisaoCodigo(COLISAO), true)
  assert.equal(ehColisaoCodigo({ code: '23505', message: 'duplicate key value violates unique constraint "escolta_veiculos_escolta_veiculo_uk"' }), false)
  assert.equal(ehColisaoCodigo({ code: '23503', message: 'codigo_escolta' }), false)
  assert.equal(ehColisaoCodigo(null), false)
})

test('cria pela RPC numa chamada só, com campos e viaturas', async () => {
  const { sb, chamadas } = falso([{ data: { id: 'e1', codigo_escolta: 'ESC-2026-0012' }, error: null }])
  const r = await criarEscolta(sb, { cliente_id: 'c1' }, [{ veiculo_id: 'v1', membros: [] }])
  assert.deepEqual(r, { ok: true, id: 'e1', codigo: 'ESC-2026-0012', tentativas: 1 })
  assert.equal(chamadas.length, 1)
  assert.equal(chamadas[0].fn, 'criar_escolta')
  assert.deepEqual(chamadas[0].args, { p_campos: { cliente_id: 'c1' }, p_viaturas: [{ veiculo_id: 'v1', membros: [] }] })
})

test('código colidiu: tenta de novo e cria', async () => {
  const { sb, chamadas } = falso([
    { data: null, error: COLISAO },
    { data: null, error: COLISAO },
    { data: { id: 'e2', codigo_escolta: 'ESC-2026-0013' }, error: null },
  ])
  const r = await criarEscolta(sb, {}, [])
  assert.equal(chamadas.length, 3)
  assert.deepEqual(r, { ok: true, id: 'e2', codigo: 'ESC-2026-0013', tentativas: 3 })
})

test('colisão em todas as tentativas: para no limite e mostra o erro real', async () => {
  const { sb, chamadas } = falso([{ data: null, error: COLISAO }, { data: null, error: COLISAO }, { data: null, error: COLISAO }, { data: null, error: COLISAO }])
  await assert.rejects(criarEscolta(sb, {}, [], 3), (e: Error) => {
    assert.match(e.message, /Nada foi gravado/)
    assert.match(e.message, /escoltas_codigo_escolta_key/)
    assert.match(e.message, /ESC-2026-0010/)
    return true
  })
  assert.equal(chamadas.length, 3)
})

test('outro erro não repete e chega com o texto do banco', async () => {
  const { sb, chamadas } = falso([{ data: null, error: { code: 'P0001', message: 'Viatura 1: defina um Comandante entre os vigilantes escalados.' } }])
  await assert.rejects(criarEscolta(sb, {}, []), /^Error: Viatura 1: defina um Comandante/)
  assert.equal(chamadas.length, 1)
})

test('função ausente (migration 224 não aplicada): avisa para o caminho antigo', async () => {
  const { sb } = falso([{ data: null, error: { code: 'PGRST202', message: 'Could not find the function public.criar_escolta' } }])
  assert.deepEqual(await criarEscolta(sb, {}, []), { ok: false, ausente: true })
  assert.equal(funcaoAusente({ code: '42883' }), true)
  assert.equal(funcaoAusente({ code: '23505' }), false)
})

test('resposta sem id não passa como sucesso', async () => {
  const { sb } = falso([{ data: {}, error: null }])
  await assert.rejects(criarEscolta(sb, {}, []), /não devolveu a escolta/)
})

test('mensagem real: nunca a genérica e sempre com o texto do banco', () => {
  assert.match(mensagemErroBanco({ code: '42501', message: 'new row violates row-level security policy for table "escoltas"' }, 'criar a escolta'),
    /^Sem permissão para criar a escolta com o seu perfil\. Detalhe: new row violates row-level security policy .*\[42501\]$/)
  assert.match(mensagemErroBanco({ code: '23503', message: 'insert or update on table "escolta_veiculos" violates foreign key constraint' }),
    /cadastro escolhido .* Detalhe: insert or update on table "escolta_veiculos"/)
  assert.equal(mensagemErroBanco({ code: 'P0001', message: 'Selecione o cliente contratante.' }), 'Selecione o cliente contratante.')
  assert.match(mensagemErroBanco({ message: 'TypeError: Failed to fetch' }), /^Sem conexão com o servidor/)
  assert.match(mensagemErroBanco({ code: 'XX000', message: 'algo inesperado', hint: 'dica' }), /^Não foi possível salvar a escolta: algo inesperado dica \[XX000\]$/)
  assert.match(mensagemErroBanco(null), /servidor não respondeu/)
  assert.equal(mensagemErroBanco(new Error('texto do erro')), 'texto do erro')
})

test('trava do duplo clique: o segundo clique no mesmo instante não passa', () => {
  const t = criarTrava()
  assert.equal(t.tentar(), true)
  assert.equal(t.tentar(), false)
  assert.equal(t.ocupada, true)
  t.soltar()
  assert.equal(t.tentar(), true)
})

test('dois cliques simultâneos geram uma chamada só', async () => {
  const { sb, chamadas } = falso([{ data: { id: 'e1', codigo_escolta: 'ESC-2026-0001' }, error: null }])
  const t = criarTrava()
  const salvar = async () => { if (!t.tentar()) return 'ignorado'; return criarEscolta(sb, {}, []) }
  const [a, b] = await Promise.all([salvar(), salvar()])
  assert.equal(chamadas.length, 1)
  assert.equal(b, 'ignorado')
  assert.equal((a as { ok: boolean }).ok, true)
})

test('data e hora de partida: inválida vira null, válida vira ISO', () => {
  assert.equal(dataHoraPrevistaISO('', '08', '00'), null)
  assert.equal(dataHoraPrevistaISO('2026-11-13', '', '00'), null)
  assert.equal(dataHoraPrevistaISO('13/11/2026', '08', '00'), null)
  assert.equal(dataHoraPrevistaISO('2026-11-13', '25', '00'), null)
  const iso = dataHoraPrevistaISO('2026-11-13', '8', '5')
  assert.ok(iso && !isNaN(new Date(iso).getTime()))
  assert.equal(iso, new Date('2026-11-13T08:05:00').toISOString())
})
