'use client'

/**
 * Onda L (Lote 2026-10; docs/14, seção 16.3.8; S13): emergência acionada sem conexão. Ela
 * fica guardada no aparelho e sobe primeiro quando o sinal voltar, mas até lá ninguém foi
 * avisado. Tela vermelha fixa com o texto e o botão de ligar para a central (número de
 * configuracao_avisos.telefone_central; sem número, só o texto). Sem botão de SMS (S13).
 */
import { Phone, Radio } from 'lucide-react'

export function EmergenciaSemConexao({ telefone, onFechar }: { telefone: string | null; onFechar: () => void }) {
  const numero = (telefone ?? '').replace(/[^\d+]/g, '')
  return (
    <div
      role="alertdialog"
      aria-modal="true"
      data-teste="emergencia-sem-conexao"
      className="fixed inset-0 flex flex-col items-center justify-center gap-6 p-6 text-center"
      style={{ backgroundColor: '#B83832', color: '#fff', zIndex: 80 }}
    >
      <Radio size={56} />
      <p className="font-black" style={{ fontSize: '26px', lineHeight: 1.25 }}>
        SEM CONEXÃO: NINGUÉM FOI AVISADO.
      </p>
      <p className="font-bold" style={{ fontSize: '20px', lineHeight: 1.35 }}>
        Use o rádio ou ligue para a central agora.
      </p>
      {numero && (
        <a
          href={`tel:${numero}`}
          data-teste="ligar-central"
          className="w-full max-w-sm flex items-center justify-center gap-3 font-black uppercase"
          style={{ minHeight: '64px', fontSize: '20px', backgroundColor: '#fff', color: '#B83832', borderRadius: '4px' }}
        >
          <Phone size={24} /> Ligar para a central
        </a>
      )}
      <p style={{ fontSize: '15px' }}>
        A emergência ficou guardada no aparelho e será a primeira a ser enviada quando houver sinal.
      </p>
      <button
        type="button"
        onClick={onFechar}
        className="w-full max-w-sm font-bold"
        style={{ minHeight: '52px', fontSize: '16px', border: '2px solid #fff', borderRadius: '4px', color: '#fff' }}
      >
        Já avisei pelo rádio ou telefone
      </button>
    </div>
  )
}
