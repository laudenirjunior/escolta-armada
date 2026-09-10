// Diagnostico somente leitura da base do escolta-armada.
// A chave vem por variavel de ambiente, nunca gravada aqui.
const BASE = 'https://qthoyxujyzskydulvcfy.supabase.co/rest/v1'
const KEY = process.env.SB_KEY
if (!KEY) { console.error('faltou SB_KEY'); process.exit(1) }
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` }

async function get(path) {
  const r = await fetch(`${BASE}/${path}`, { headers: H })
  const txt = await r.text()
  if (!r.ok) return { __erro: `${r.status} ${txt.slice(0, 300)}` }
  try { return JSON.parse(txt) } catch { return { __erro: 'json invalido' } }
}

async function contar(tabela) {
  const r = await fetch(`${BASE}/${tabela}?select=*&limit=1`, { headers: { ...H, Prefer: 'count=exact' } })
  if (!r.ok) return `erro ${r.status}`
  const cr = r.headers.get('content-range')
  return cr ? cr.split('/')[1] : '?'
}

const nome = (m, id) => id == null ? '(sem autor)' : (m[id] ?? `(id desconhecido ${String(id).slice(0, 8)})`)

function tabela(titulo, linhas) {
  console.log(`\n=== ${titulo} ===`)
  if (!linhas.length) { console.log('(vazio)'); return }
  console.log(linhas.join('\n'))
}

const main = async () => {
  // ---------- D1: usuarios ----------
  const perfis = await get('dom_perfis?select=id,codigo,nome_exibicao')
  if (perfis.__erro) { console.error('ERRO dom_perfis:', perfis.__erro); process.exit(1) }
  const mapPerfil = Object.fromEntries(perfis.map(p => [p.id, p.codigo]))

  const usuarios = await get('usuarios?select=id,nome_completo,email,status,perfil_id,criado_por,criado_em&order=criado_em')
  if (usuarios.__erro) { console.error('ERRO usuarios:', usuarios.__erro); process.exit(1) }
  const mapUser = Object.fromEntries(usuarios.map(u => [u.id, u.nome_completo]))

  tabela('D1 - USUARIOS', usuarios.map(u =>
    `${u.id}  ${String(u.nome_completo).padEnd(28)} ${String(mapPerfil[u.perfil_id] ?? '?').padEnd(14)} ${String(u.status).padEnd(10)} ${u.email}  criado ${String(u.criado_em).slice(0, 10)} por ${nome(mapUser, u.criado_por)}`
  ))

  // ---------- D2: inventario de autoria ----------
  const fontes = [
    ['escoltas', 'escoltas?select=criada_por', 'criada_por'],
    ['clientes', 'clientes?select=criado_por', 'criado_por'],
    ['veiculos', 'veiculos?select=criado_por', 'criado_por'],
    ['vigilantes', 'vigilantes?select=criado_por', 'criado_por'],
    ['armamentos', 'armamentos?select=criado_por', 'criado_por'],
    ['checklist_modelos', 'checklist_modelos?select=criado_por', 'criado_por'],
    ['usuarios', 'usuarios?select=criado_por', 'criado_por'],
    ['fotos', 'fotos?select=criado_por&limit=5000', 'criado_por'],
    ['ocorrencias', 'ocorrencias?select=registrado_por', 'registrado_por'],
    ['pontos_controle', 'pontos_controle?select=lancado_por&limit=5000', 'lancado_por'],
    ['checklists', 'checklists?select=responsavel_id&limit=5000', 'responsavel_id'],
    ['escolta_veiculos', 'escolta_veiculos?select=criado_por', 'criado_por'],
    ['escolta_efetivo', 'escolta_efetivo?select=criado_por', 'criado_por'],
    ['escolta_armamentos', 'escolta_armamentos?select=criado_por', 'criado_por'],
    ['presencas', 'presencas?select=criado_por', 'criado_por'],
  ]
  const linhasD2 = []
  for (const [rotulo, path, col] of fontes) {
    const dados = await get(path)
    if (dados.__erro) { linhasD2.push(`${rotulo.padEnd(20)} ERRO ${dados.__erro}`); continue }
    const acc = {}
    for (const r of dados) { const k = nome(mapUser, r[col]); acc[k] = (acc[k] ?? 0) + 1 }
    const partes = Object.entries(acc).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k}: ${v}`)
    linhasD2.push(`${rotulo.padEnd(20)} total ${String(dados.length).padEnd(5)} | ${partes.join('  |  ') || '(vazio)'}`)
  }
  tabela('D2 - AUTORIA POR TABELA', linhasD2)

  // ---------- D3: escoltas uma a uma ----------
  const clientes = await get('clientes?select=id,nome_cliente,criado_por,criado_em')
  const mapCliente = clientes.__erro ? {} : Object.fromEntries(clientes.map(c => [c.id, c.nome_cliente]))
  const escoltas = await get('escoltas?select=id,codigo_escolta,status,criada_por,criado_em,data_hora_prevista,cliente_id&order=criado_em')
  if (escoltas.__erro) { console.error('ERRO escoltas:', escoltas.__erro) }
  else tabela('D3 - ESCOLTAS', escoltas.map(e =>
    `${String(e.codigo_escolta ?? '(sem codigo)').padEnd(16)} ${String(e.status).padEnd(16)} criada ${String(e.criado_em).slice(0, 10)} prevista ${String(e.data_hora_prevista).slice(0, 10)}  ${String(mapCliente[e.cliente_id] ?? '?').padEnd(24)} por ${nome(mapUser, e.criada_por)}`
  ))

  // ---------- Cadastros em detalhe ----------
  const vigilantes = await get('vigilantes?select=id,nome_completo,status,usuario_id,criado_por,criado_em&order=criado_em')
  if (!vigilantes.__erro) tabela('VIGILANTES', vigilantes.map(v =>
    `${String(v.nome_completo).padEnd(30)} ${String(v.status).padEnd(10)} ${v.usuario_id ? 'com login' : 'sem login'}  criado ${String(v.criado_em).slice(0, 10)} por ${nome(mapUser, v.criado_por)}`))

  const armamentos = await get('armamentos?select=id,numeracao,status,criado_por,criado_em&order=criado_em')
  if (!armamentos.__erro) tabela('ARMAMENTOS', armamentos.map(a =>
    `${String(a.numeracao ?? '(sem numeracao)').padEnd(24)} ${String(a.status).padEnd(12)} criado ${String(a.criado_em).slice(0, 10)} por ${nome(mapUser, a.criado_por)}`))

  const veiculos = await get('veiculos?select=id,placa,modelo,status,criado_por,criado_em&order=criado_em')
  if (!veiculos.__erro) tabela('VEICULOS', veiculos.map(v =>
    `${String(v.placa).padEnd(12)} ${String(v.modelo ?? '').padEnd(20)} ${String(v.status).padEnd(12)} criado ${String(v.criado_em).slice(0, 10)} por ${nome(mapUser, v.criado_por)}`))

  if (!clientes.__erro) tabela('CLIENTES', clientes.map(c =>
    `${String(c.nome_cliente).padEnd(34)} criado ${String(c.criado_em).slice(0, 10)} por ${nome(mapUser, c.criado_por)}`))

  const modelos = await get('checklist_modelos?select=id,nome,tipo,versao,ativo,criado_por,criado_em&order=criado_em')
  if (!modelos.__erro) tabela('MODELOS DE CHECKLIST', modelos.map(m =>
    `${String(m.nome).padEnd(34)} ${String(m.tipo).padEnd(12)} v${m.versao} ${m.ativo ? 'ativo' : 'inativo'}  por ${nome(mapUser, m.criado_por)}`))

  // ---------- Volume geral ----------
  const tabelas = ['escoltas', 'escolta_veiculos', 'escolta_efetivo', 'escolta_armamentos', 'pontos_controle',
    'rastreamento', 'presencas', 'fotos', 'ocorrencias', 'emergencias', 'checklists', 'checklist_respostas',
    'checklist_modelos', 'checklist_modelo_itens', 'atualizacoes_status', 'escolta_status_historico',
    'notificacoes', 'clientes', 'veiculos', 'vigilantes', 'armamentos', 'usuarios', 'logs_auditoria', 'chat_mensagens']
  const vol = []
  for (const t of tabelas) vol.push(`${t.padEnd(28)} ${await contar(t)}`)
  tabela('VOLUME POR TABELA', vol)
}

main().catch(e => { console.error('FALHA:', e.message) })
