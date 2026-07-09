import { NextRequest, NextResponse } from 'next/server'

export async function POST(req: NextRequest) {
  try {
    const { texto, contexto } = await req.json()

    if (!texto?.trim()) {
      return NextResponse.json({ error: 'Texto vazio' }, { status: 400 })
    }

    const apiKey = process.env.OPENAI_API_KEY
    if (!apiKey) {
      return NextResponse.json({ error: 'OPENAI_API_KEY não configurada' }, { status: 500 })
    }

    const systemPrompt = `Você é um assistente especializado em revisão de textos para operações de segurança privada e escolta armada.
Sua tarefa: melhore a escrita, corrija todos os erros de português e pontuação, organize as informações, sem alterar o sentido do texto.
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
      return NextResponse.json({ error: err }, { status: resp.status })
    }

    const data = await resp.json()
    const melhorado: string = data.choices?.[0]?.message?.content?.trim() ?? texto

    return NextResponse.json({ melhorado })
  } catch (err: any) {
    console.error('[melhorar-texto]', err)
    return NextResponse.json({ error: err.message ?? 'Erro interno' }, { status: 500 })
  }
}
