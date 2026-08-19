import type { Metadata, Viewport } from 'next'
import { DM_Sans, JetBrains_Mono } from 'next/font/google'
import './globals.css'

const dmSans = DM_Sans({
  subsets: ['latin'],
  variable: '--font-sans',
  display: 'swap',
})

const jetbrainsMono = JetBrains_Mono({
  subsets: ['latin'],
  variable: '--font-mono',
  display: 'swap',
})

export const metadata: Metadata = {
  title: 'Escolta Armada | Controle Operacional',
  description:
    'Plataforma de controle de escolta armada com georreferenciamento, checklists e timeline de eventos.',
  applicationName: 'Escolta Armada',
  appleWebApp: {
    capable: true,
    title: 'Escolta',
    // 'default' e proposital. 'black-translucent' joga o conteudo por baixo da
    // barra de status do iPhone e exigiria safe-area-inset-top em toda tela, que
    // o projeto nao tem.
    statusBarStyle: 'default',
  },
  // Evita o iOS transformar codigo de escolta e placa em link de telefone.
  formatDetection: { telephone: false, address: false, email: false },
}

export const viewport: Viewport = {
  themeColor: '#1A294A',
  width: 'device-width',
  initialScale: 1,
  // 'cover' pinta a barra de status ate a borda no iPhone. Em troca, quem fica
  // responsavel pelo recorte e o env(safe-area-inset-*) aplicado na barra
  // inferior e no conteudo do dashboard.
  viewportFit: 'cover',
  // NAO acrescentar maximumScale nem userScalable: bloquear o zoom e regressao
  // de acessibilidade num app usado em campo, na rua, com luz ruim.
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="pt-BR" suppressHydrationWarning>
      <body
        className={`${dmSans.variable} ${jetbrainsMono.variable} antialiased bg-background text-foreground`}
      >
        {children}
      </body>
    </html>
  )
}
