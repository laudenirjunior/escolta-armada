import { NextRequest, NextResponse } from 'next/server'
import { exigirSessao, dentroDoLimite } from '@/lib/api-auth'

// Sem sessao, qualquer um na internet podia gastar a cota da OpenAI.
const LIMITE_POR_MINUTO = 20
const TAMANHO_MAXIMO = 8000

export async function POST(req: NextRequest) {
  try {
    const auth = await exigirSessao()
    if (!auth.ok) {
      return NextResponse.json({ error: auth.erro }, { status: auth.status })
    }

    if (!dentroDoLimite('ia:' + auth.sessao.usuarioId, LIMITE_POR_MINUTO, 60_000)) {
      return NextResponse.json({ error: 'Muitas solicitações. Aguarde um minuto.' }, { status: 429 })
    }

    const { texto, contexto } = await req.json()

    if (!texto?.trim()) {
      return NextResponse.json({ error: 'Texto vazio' }, { status: 400 })
    }

    if (texto.length > TAMANHO_MAXIMO) {
      return NextResponse.json({ error: 'Texto longo demais.' }, { status: 413 })
    }

    const apiKey = process.env.OPENAI_API_KEY
    if (!apiKey) {
      return NextResponse.json({ error: 'OPENAI_API_KEY não configurada' }, { status: 500 })
    }

    const systemPrompt = `Você é um assistente especializado em revisão de textos para operações de segurança privada e escolta armada.
Sua tarefa: melhore a escrita, corrija todos os erros de português e pontuação, organize as informações, sem alterar o sentido do texto.
Corrija também palavras que estão erradas pelo contexto — digitação rápida, erros de voz para texto ou letras trocadas (exemplos: "parda" → "parada", "chegua" → "chegou", "viatura" escrita como "vaatura"). Use o contexto da frase e do domínio de escolta armada para inferir a palavra correta.
Não adicione informações que não estavam no texto original.
Retorne APENAS o texto melhorado, sem explicações, sem aspas, sem prefixos.`

    const userPrompt = contexto
      ? `Contexto: ${contexto}\n\nTexto:\n${texto}`
      : `Texto:\n${texto}`

    const resp = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        max_tokens: 1024,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userPrompt },
        ],
      }),
    })

    if (!resp.ok) {
      const err = await resp.text()
      console.error('[melhorar-texto] OpenAI:', err)
      return NextResponse.json({ error: 'Falha ao processar o texto.' }, { status: 502 })
    }

    const data = await resp.json()
    const melhorado: string = data.choices?.[0]?.message?.content?.trim() ?? texto

    return NextResponse.json({ melhorado })
  } catch (err: any) {
    console.error('[melhorar-texto]', err)
    return NextResponse.json({ error: 'Erro interno.' }, { status: 500 })
  }
}
