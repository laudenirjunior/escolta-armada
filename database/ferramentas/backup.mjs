// Exporta todas as tabelas do public para JSON, antes da limpeza.
import { writeFileSync, mkdirSync } from 'node:fs'
const BASE = 'https://qthoyxujyzskydulvcfy.supabase.co/rest/v1'
const KEY = process.env.SB_KEY
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` }
const DEST = process.argv[2]
if (!KEY || !DEST) { console.error('uso: SB_KEY=... node backup.mjs <destino>'); process.exit(1) }

const TABELAS = [
  'dom_perfis', 'dom_funcoes', 'dom_calibres', 'dom_tipos_armamento', 'dom_tipos_veiculo',
  'dom_tipos_ocorrencia', 'dom_tipos_evento', 'dom_tipos_foto', 'dom_tipos_ponto',
  'usuarios', 'vigilantes', 'clientes', 'veiculos', 'armamentos',
  'escoltas', 'escolta_veiculos', 'escolta_efetivo', 'escolta_armamentos',
  'pontos_controle', 'rastreamento', 'presencas', 'fotos', 'ocorrencias', 'emergencias',
  'checklist_modelos', 'checklist_modelo_itens', 'checklists', 'checklist_respostas',
  'escolta_status_historico', 'atualizacoes_status', 'notificacoes', 'logs_auditoria', 'chat_mensagens',
  'usuarios_credenciais',
]

mkdirSync(DEST, { recursive: true })
const resumo = {}
let falhas = 0

for (const t of TABELAS) {
  const r = await fetch(`${BASE}/${t}?select=*&limit=10000`, { headers: H })
  const txt = await r.text()
  if (!r.ok) { console.error(`FALHA ${t}: ${r.status} ${txt.slice(0, 150)}`); falhas++; resumo[t] = 'FALHA'; continue }
  const dados = JSON.parse(txt)
  writeFileSync(`${DEST}/${t}.json`, JSON.stringify(dados, null, 2), 'utf8')
  resumo[t] = dados.length
  console.log(`${t.padEnd(28)} ${dados.length}`)
}

writeFileSync(`${DEST}/_manifesto.json`, JSON.stringify({
  projeto: 'qthoyxujyzskydulvcfy',
  gerado_em: new Date().toISOString(),
  motivo: 'Backup anterior a limpeza de base: manter so o que Bruno Moreira criou',
  aviso: 'Os arquivos do bucket fotos NAO estao aqui. Só os metadados.',
  linhas: resumo,
}, null, 2), 'utf8')

console.log(`\nfalhas: ${falhas}`)
if (falhas) process.exit(1)
