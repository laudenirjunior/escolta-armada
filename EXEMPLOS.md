# Exemplos de Integração - Escolta Armada

## 1. Exemplo: Login com Supabase Auth

### Implementar em `lib/supabase/auth.ts`

```typescript
import { createClient } from '@supabase/supabase-js'
import type { Database } from '@/types/supabase'

export async function loginComEmail(
  email: string,
  password: string,
) {
  const supabase = createClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  )

  const { data, error } = await supabase.auth.signInWithPassword({
    email,
    password,
  })

  if (error) throw error
  return data
}

export async function logout() {
  const supabase = createClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  )

  const { error } = await supabase.auth.signOut()
  if (error) throw error
}

export async function mudarSenha(
  senhaAtual: string,
  senhaNova: string,
) {
  const supabase = createClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  )

  // Primeiro verificar senha atual
  const { user } = await supabase.auth.getUser()
  if (!user?.email) throw new Error('Usuário não autenticado')

  // Reautenticar com senha atual
  const { error: reAuthError } = await supabase.auth.signInWithPassword({
    email: user.email,
    password: senhaAtual,
  })

  if (reAuthError) throw new Error('Senha atual incorreta')

  // Alterar para nova senha
  const { error } = await supabase.auth.updateUser({
    password: senhaNova,
  })

  if (error) throw error
}
```

### Usar em `hooks/useAuth.ts`

```typescript
import { useState } from 'react'
import { loginComEmail, logout, mudarSenha } from '@/lib/supabase/auth'

export function useAuth() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const login = async (email: string, password: string) => {
    try {
      setLoading(true)
      setError(null)
      const data = await loginComEmail(email, password)
      return data
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Erro ao fazer login'
      setError(message)
      throw err
    } finally {
      setLoading(false)
    }
  }

  const handleLogout = async () => {
    try {
      setLoading(true)
      await logout()
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Erro ao fazer logout'
      setError(message)
    } finally {
      setLoading(false)
    }
  }

  return { login, logout: handleLogout, mudarSenha, loading, error }
}
```

## 2. Exemplo: Buscar Escoltas

```typescript
// lib/supabase/queries.ts

import { createClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import type { Database } from '@/types/supabase'
import type { Escolta } from '@/types'

export async function buscarEscoltas(clienteId: string) {
  const supabase = createClient<Database>()

  const { data, error } = await supabase
    .from('escoltas')
    .select('*')
    .eq('cliente_id', clienteId)
    .order('data_solicitacao', { ascending: false })

  if (error) throw error
  return data as Escolta[]
}

export async function buscarEscoltaPorId(escolaId: string) {
  const supabase = createClient<Database>()

  const { data, error } = await supabase
    .from('escoltas')
    .select('*')
    .eq('id', escolaId)
    .single()

  if (error) throw error
  return data as Escolta
}
```

## 3. Exemplo: Atualizar Status da Escolta

```typescript
// services/escolta.ts

import { createServerClient } from '@supabase/ssr'
import type { StatusEscolta } from '@/types'

export async function atualizarStatusEscolta(
  escolaId: string,
  novoStatus: StatusEscolta,
  usuarioId: string,
) {
  const supabase = createServerClient()

  // 1. Atualizar status
  const { error: updateError } = await supabase
    .from('escoltas')
    .update({ status: novoStatus, atualizado_em: new Date().toISOString() })
    .eq('id', escolaId)

  if (updateError) throw updateError

  // 2. Registrar na trilha de status
  const { error: historyError } = await supabase
    .from('escolta_status_historico')
    .insert([
      {
        escolta_id: escolaId,
        status_novo: novoStatus,
        alterado_por: usuarioId,
        data_hora: new Date().toISOString(),
      },
    ])

  if (historyError) throw historyError

  // 3. Gerar evento na timeline
  const { error: eventError } = await supabase
    .from('atualizacoes_status')
    .insert([
      {
        escolta_id: escolaId,
        tipo_evento_id: `status_${novoStatus}`,
        descricao: `Status alterado para ${novoStatus}`,
        autor_id: usuarioId,
        data_hora: new Date().toISOString(),
      },
    ])

  if (eventError) throw eventError
}
```

## 4. Exemplo: Upload de Foto com Carimbo

```typescript
// services/fotos.ts

import { createClient } from '@supabase/supabase-js'
import type { Database } from '@/types/supabase'
import { formatarDataHora, formatarCoordenadas } from '@/utils/formatters'

export async function enviarFotoComCarimbo(
  arquivo: File,
  tipoFoto: string,
  latitude: number,
  longitude: number,
  usuarioId: string,
) {
  const supabase = createClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  )

  // 1. Gerar nome único para arquivo
  const timestamp = Date.now()
  const random = Math.random().toString(36).substring(7)
  const nomeArquivo = `fotos/${usuarioId}/${tipoFoto}_${timestamp}_${random}.jpg`

  // 2. Fazer upload
  const { error: uploadError, data } = await supabase.storage
    .from('fotos')
    .upload(nomeArquivo, arquivo)

  if (uploadError) throw uploadError

  // 3. Aplicar carimbo na imagem (no cliente ou servidor)
  const caminhoArquivo = data.path

  // 4. Registrar na BD
  const { error: dbError, data: foto } = await supabase
    .from('fotos')
    .insert([
      {
        caminho_arquivo: caminhoArquivo,
        tipo_foto_id: tipoFoto,
        latitude,
        longitude,
        precision_metros: 5, // Estimado
        data_hora_captura: new Date().toISOString(),
        carimbo_aplicado: true,
        criado_por: usuarioId,
      },
    ])
    .select()
    .single()

  if (dbError) throw dbError

  return foto
}

// Função para obter URL pública da foto
export function obterUrlPublicaFoto(caminhoArquivo: string) {
  const supabase = createClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  )

  const { data } = supabase.storage
    .from('fotos')
    .getPublicUrl(caminhoArquivo)

  return data.publicUrl
}
```

## 5. Exemplo: Sincronização Offline

```typescript
// services/sync.ts

import { createClient } from '@supabase/supabase-js'
import type { Database } from '@/types/supabase'

interface RegistroOffline {
  id: string
  tabela: string
  operacao: 'insert' | 'update'
  dados: Record<string, any>
  timestamp: number
}

const DB_PENDENCIAS = 'escolta_pendencias'

export async function salvarLocalmente(
  tabela: string,
  operacao: 'insert' | 'update',
  dados: Record<string, any>,
) {
  const db = await openDB()
  const store = db
    .transaction(DB_PENDENCIAS, 'readwrite')
    .objectStore(DB_PENDENCIAS)

  const registro: RegistroOffline = {
    id: dados.id || crypto.randomUUID(),
    tabela,
    operacao,
    dados: { ...dados, id: dados.id || crypto.randomUUID() },
    timestamp: Date.now(),
  }

  store.add(registro)
  return registro
}

export async function sincronizar() {
  const db = await openDB()
  const store = db
    .transaction(DB_PENDENCIAS, 'readonly')
    .objectStore(DB_PENDENCIAS)

  const todos = await store.getAll()

  const supabase = createClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  )

  for (const registro of todos) {
    try {
      if (registro.operacao === 'insert') {
        await supabase.from(registro.tabela).insert([registro.dados])
      } else if (registro.operacao === 'update') {
        await supabase
          .from(registro.tabela)
          .update(registro.dados)
          .eq('id', registro.dados.id)
      }

      // Remover após sucesso
      const delStore = db
        .transaction(DB_PENDENCIAS, 'readwrite')
        .objectStore(DB_PENDENCIAS)
      delStore.delete(registro.id)
    } catch (error) {
      console.error(`Erro sincronizando ${registro.tabela}:`, error)
    }
  }
}

async function openDB() {
  return new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open('EscoltaArmada', 1)

    request.onerror = () => reject(request.error)
    request.onsuccess = () => resolve(request.result)

    request.onupgradeneeded = (event) => {
      const db = (event.target as IDBOpenDBRequest).result
      if (!db.objectStoreNames.contains(DB_PENDENCIAS)) {
        db.createObjectStore(DB_PENDENCIAS, { keyPath: 'id' })
      }
    }
  })
}
```

## 6. Exemplo: Notificação Telegram

```typescript
// Edge Function: supabase/functions/notify-telegram/index.ts

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
)

serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 })
  }

  const { evento_id, escolta_id, descricao, foto_url } = await req.json()

  // Buscar grupo do cliente
  const { data: escolta } = await supabase
    .from('escoltas')
    .select('clientes!inner(telegram_chat_id)')
    .eq('id', escolta_id)
    .single()

  const chatId = escolta?.clientes?.telegram_chat_id
  if (!chatId) {
    return new Response(JSON.stringify({ ok: true }), { status: 200 })
  }

  // Montar mensagem
  const mensagem = `
📋 ${descricao}

🆔 Escolta: ${escolta_id}
🕐 Horário: ${new Date().toLocaleString('pt-BR')}
  `

  // Enviar para Telegram
  const botToken = Deno.env.get('TELEGRAM_BOT_TOKEN')!
  const url = `https://api.telegram.org/bot${botToken}/sendPhoto`

  const formData = new FormData()
  formData.append('chat_id', chatId)
  formData.append('caption', mensagem)
  if (foto_url) {
    formData.append('photo', foto_url)
  }

  const response = await fetch(url, {
    method: 'POST',
    body: formData,
  })

  // Registrar tentativa
  await supabase
    .from('notificacoes')
    .update({
      status_envio: response.ok ? 'enviada' : 'falha',
      data_envio: new Date().toISOString(),
    })
    .eq('escolta_id', escolta_id)

  return new Response(JSON.stringify({ ok: response.ok }), { status: 200 })
})
```

## 7. Exemplo: RLS Policy (Row Level Security)

```sql
-- Política: Usuário só vê escoltas do seu cliente
CREATE POLICY "usuarios_veem_seu_cliente"
ON escoltas
FOR SELECT
USING (
  cliente_id IN (
    SELECT cliente_id 
    FROM usuarios_clientes 
    WHERE usuario_id = auth.uid()
  )
);

-- Política: Só Gestor e Admin veem valores
CREATE POLICY "valores_apenas_gestor_admin"
ON escolta_veiculos
FOR SELECT
USING (
  (
    SELECT perfil_id FROM usuarios WHERE id = auth.uid()
  ) IN ('gestor', 'administrador')
);
```

---

Estes são exemplos práticos. Adapte conforme sua necessidade específica.
