// Numeração de escolta (migration 224): concorrência entre duas sessões. RODA NA HOMOLOGAÇÃO
// (usuários QA), nunca em produção. Precisa do pacote pg (fora do package.json do app):
//   NODE_PATH=<pasta com node_modules/pg> PGHOST=127.0.0.1 PGPORT=54322 PGUSER=postgres \
//   PGPASSWORD=<senha do banco local> node database/testes/07_numeracao_escolta_concorrencia.mjs
// Cobre: (1) duas criações ao mesmo tempo saem com números diferentes e a segunda espera a
// primeira; (2) criação desfeita devolve o número; (3) código gravado por outra transação na
// mesma hora: a criar_escolta colide, tenta de novo e cria. Apaga o que criou (com as triggers
// desligadas, como o qa.nova_escolta) e devolve o contador ao valor de antes.
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { Client } = require('pg')

let falhou = 0
const ok = (cond, texto) => { console.log(`  ${cond ? 'PASSOU' : 'FALHOU'}: ${texto}`); if (!cond) falhou = 1 }
const nova = async () => { const c = new Client(); await c.connect(); return c }
const espera = ms => new Promise(r => setTimeout(r, ms))

const CAMPOS = `jsonb_build_object('cliente_id', (SELECT id FROM public.clientes ORDER BY criado_em LIMIT 1),
  'data_hora_prevista', now() + interval '1 day', 'origem_endereco', 'Origem concorrencia 224', 'origem_lat', -22.9,
  'origem_lng', -43.2, 'destino_endereco', 'Destino concorrencia 224', 'destino_lat', -22.95, 'destino_lng', -43.25)`
const VIATURAS = `jsonb_build_array(jsonb_build_object('veiculo_id', (SELECT id FROM public.veiculos ORDER BY placa LIMIT 1), 'membros', '[]'::jsonb))`
const CRIAR = `SELECT public.criar_escolta(${CAMPOS}, ${VIATURAS}) AS r`

async function comoGestor(c) {
  await c.query('BEGIN')
  await c.query(`SELECT qa.como('qa_gestor')`)
}

const adm = await nova()
const ano = new Date().getFullYear()
const antes = (await adm.query('SELECT ultimo FROM lote_interno.escolta_codigo_contador WHERE ano = $1', [ano])).rows[0]?.ultimo ?? null
const criadas = []

try {
  // 1. Duas criações ao mesmo tempo.
  const a = await nova(), b = await nova()
  await comoGestor(a); await comoGestor(b)
  const ra = (await a.query(CRIAR)).rows[0].r
  let bTerminou = false
  const pb = b.query(CRIAR).then(x => { bTerminou = true; return x.rows[0].r })
  await espera(700)
  ok(!bTerminou, 'a segunda criação espera a primeira terminar (linha do contador travada)')
  await a.query('COMMIT')
  const rb = await pb
  await b.query('COMMIT')
  criadas.push(ra.id, rb.id)
  ok(ra.codigo_escolta !== rb.codigo_escolta, `duas criações simultâneas com números diferentes (${ra.codigo_escolta} e ${rb.codigo_escolta})`)
  ok(Number(rb.codigo_escolta.split('-')[2]) === Number(ra.codigo_escolta.split('-')[2]) + 1, 'números seguidos, sem buraco')

  // 2. Criação desfeita devolve o número para a que esperava.
  await comoGestor(a); await comoGestor(b)
  const rc = (await a.query(CRIAR)).rows[0].r
  const pd = b.query(CRIAR).then(x => x.rows[0].r)
  await espera(300)
  await a.query('ROLLBACK')
  const rd = await pd
  await b.query('COMMIT')
  criadas.push(rd.id)
  ok(rd.codigo_escolta === rc.codigo_escolta, `criação desfeita devolve o número (${rc.codigo_escolta}) para a seguinte`)

  // 3. Colisão real: outra transação grava à mão o próximo código e confirma depois que a
  //    criar_escolta já calculou o número. A criar_escolta tenta de novo e cria com o seguinte.
  const prox = (await adm.query('SELECT ultimo FROM lote_interno.escolta_codigo_contador WHERE ano = $1', [ano])).rows[0].ultimo + 1
  const codigoMao = `ESC-${ano}-${String(prox).padStart(4, '0')}`
  await a.query('BEGIN')
  const rm = (await a.query(`INSERT INTO public.escoltas (cliente_id, data_hora_prevista, origem_endereco, origem_lat, origem_lng,
      destino_endereco, destino_lat, destino_lng, status, data_solicitacao, checklist_pendente_no_inicio, criada_por, codigo_escolta)
    VALUES ((SELECT id FROM public.clientes ORDER BY criado_em LIMIT 1), now() + interval '1 day', 'O', -22.9, -43.2, 'D', -22.95, -43.25,
      'agendada', now(), true, qa.usuario('qa_gestor'), $1) RETURNING id`, [codigoMao])).rows[0]
  await comoGestor(b)
  let erroB = null
  const pe = b.query(CRIAR).then(x => x.rows[0].r, e => { erroB = e; return null })
  await espera(500)
  await a.query('COMMIT')
  criadas.push(rm.id)
  const re = await pe
  if (re) { await b.query('COMMIT'); criadas.push(re.id) } else await b.query('ROLLBACK')
  ok(!!re && re.codigo_escolta !== codigoMao,
     re ? `colisão com código gravado por outra transação: tentou de novo e criou ${re.codigo_escolta}` : `colisão não tratada: ${erroB?.message}`)

  await a.end(); await b.end()
} catch (e) {
  ok(false, `erro inesperado: ${e.message}`)
} finally {
  // Limpeza: triggers desligadas só nesta transação (como o qa.nova_escolta).
  await adm.query('BEGIN')
  await adm.query('SET LOCAL session_replication_role = replica')
  if (criadas.length) {
    await adm.query('DELETE FROM public.escolta_efetivo WHERE escolta_id = ANY($1::uuid[])', [criadas])
    await adm.query('DELETE FROM public.escolta_veiculos WHERE escolta_id = ANY($1::uuid[])', [criadas])
    await adm.query('DELETE FROM public.escoltas WHERE id = ANY($1::uuid[])', [criadas])
  }
  if (antes !== null) await adm.query('UPDATE lote_interno.escolta_codigo_contador SET ultimo = $2 WHERE ano = $1', [ano, antes])
  await adm.query('COMMIT')
  const sobra = (await adm.query(`SELECT count(*)::int n FROM public.escoltas WHERE origem_endereco = 'Origem concorrencia 224'`)).rows[0].n
  ok(sobra === 0, 'limpeza: nenhuma escolta de teste ficou')
  await adm.end()
  process.exitCode = falhou
}
