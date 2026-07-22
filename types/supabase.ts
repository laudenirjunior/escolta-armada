export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  public: {
    Tables: {
      // ── Domínio ──────────────────────────────────────────────────────────────
      dom_perfis: {
        Row: { id: string; codigo: string; nome_exibicao: string; ativo: boolean }
        Insert: { id?: string; codigo: string; nome_exibicao: string; ativo?: boolean }
        Update: { codigo?: string; nome_exibicao?: string; ativo?: boolean }
      }
      dom_funcoes: {
        Row: { id: string; nome: string; ativo: boolean }
        Insert: { id?: string; nome: string; ativo?: boolean }
        Update: { nome?: string; ativo?: boolean }
      }
      dom_tipos_veiculo: {
        Row: { id: string; nome: string; ativo: boolean }
        Insert: { id?: string; nome: string; ativo?: boolean }
        Update: { nome?: string; ativo?: boolean }
      }
      dom_calibres: {
        Row: { id: string; nome: string; ativo: boolean }
        Insert: { id?: string; nome: string; ativo?: boolean }
        Update: { nome?: string; ativo?: boolean }
      }
      dom_tipos_armamento: {
        Row: { id: string; nome: string; ativo: boolean }
        Insert: { id?: string; nome: string; ativo?: boolean }
        Update: { nome?: string; ativo?: boolean }
      }
      dom_tipos_ponto: {
        Row: { id: string; codigo: string; nome_exibicao: string; ordem: number; ativo: boolean }
        Insert: { id?: string; codigo: string; nome_exibicao: string; ordem: number; ativo?: boolean }
        Update: { codigo?: string; nome_exibicao?: string; ordem?: number; ativo?: boolean }
      }
      dom_tipos_ocorrencia: {
        Row: { id: string; nome: string; ativo: boolean }
        Insert: { id?: string; nome: string; ativo?: boolean }
        Update: { nome?: string; ativo?: boolean }
      }
      dom_tipos_evento: {
        Row: { id: string; codigo: string; nome_exibicao: string; gera_notificacao: boolean; ativo: boolean }
        Insert: { id?: string; codigo: string; nome_exibicao: string; gera_notificacao?: boolean; ativo?: boolean }
        Update: { codigo?: string; nome_exibicao?: string; gera_notificacao?: boolean; ativo?: boolean }
      }
      dom_tipos_foto: {
        Row: { id: string; codigo: string; nome_exibicao: string; ativo: boolean }
        Insert: { id?: string; codigo: string; nome_exibicao: string; ativo?: boolean }
        Update: { codigo?: string; nome_exibicao?: string; ativo?: boolean }
      }

      // ── Pessoas e Acesso ──────────────────────────────────────────────────────
      usuarios: {
        Row: {
          id: string
          auth_user_id: string | null
          nome_completo: string
          cpf: string
          email: string
          telefone: string | null
          perfil_id: string
          status: 'pendente' | 'ativo' | 'inativo' | 'bloqueado'
          troca_senha_obrigatoria: boolean
          ultimo_acesso: string | null
          criado_por: string | null
          aprovado_por: string | null
          atualizado_por: string | null
          metadados: Json | null
          criado_em: string
          atualizado_em: string
        }
        Insert: {
          id?: string
          auth_user_id?: string | null
          nome_completo: string
          cpf: string
          email: string
          telefone?: string | null
          perfil_id: string
          status?: 'pendente' | 'ativo' | 'inativo' | 'bloqueado'
          troca_senha_obrigatoria?: boolean
          ultimo_acesso?: string | null
          criado_por?: string | null
          aprovado_por?: string | null
          atualizado_por?: string | null
          metadados?: Json | null
          criado_em?: string
          atualizado_em?: string
        }
        Update: {
          auth_user_id?: string | null
          nome_completo?: string
          email?: string
          telefone?: string | null
          perfil_id?: string
          status?: 'pendente' | 'ativo' | 'inativo' | 'bloqueado'
          troca_senha_obrigatoria?: boolean
          ultimo_acesso?: string | null
          criado_por?: string | null
          aprovado_por?: string | null
          atualizado_por?: string | null
          metadados?: Json | null
          criado_em?: string
          atualizado_em?: string
        }
      }
      vigilantes: {
        Row: {
          id: string
          usuario_id: string | null
          nome_completo: string
          cpf: string
          funcao_id: string
          cnv: string | null
          extensao_escolta_armada: string | null
          valor_padrao_pago: number | null
          status: 'ativo' | 'inativo'
          metadados: Json | null
          criado_em: string
          atualizado_em: string
          criado_por: string | null
          atualizado_por: string | null
        }
        Insert: {
          id?: string
          usuario_id?: string | null
          nome_completo: string
          cpf: string
          funcao_id: string
          cnv?: string | null
          extensao_escolta_armada?: string | null
          valor_padrao_pago?: number | null
          status?: 'ativo' | 'inativo'
          metadados?: Json | null
          criado_por?: string | null
        }
        Update: {
          usuario_id?: string | null
          nome_completo?: string
          funcao_id?: string
          cnv?: string | null
          extensao_escolta_armada?: string | null
          valor_padrao_pago?: number | null
          status?: 'ativo' | 'inativo'
          metadados?: Json | null
          atualizado_por?: string | null
        }
      }
      clientes: {
        Row: {
          id: string
          nome_cliente: string
          cnpj: string | null
          contato: string
          telefone: string
          cor_destaque: string
          telegram_chat_id: string | null
          observacoes: string | null
          status: 'ativo' | 'inativo'
          metadados: Json | null
          criado_em: string
          atualizado_em: string
          criado_por: string | null
          atualizado_por: string | null
        }
        Insert: {
          id?: string
          nome_cliente: string
          cnpj?: string | null
          contato: string
          telefone: string
          cor_destaque?: string
          telegram_chat_id?: string | null
          observacoes?: string | null
          status?: 'ativo' | 'inativo'
          metadados?: Json | null
          criado_por?: string | null
        }
        Update: {
          nome_cliente?: string
          cnpj?: string | null
          contato?: string
          telefone?: string
          cor_destaque?: string
          telegram_chat_id?: string | null
          observacoes?: string | null
          status?: 'ativo' | 'inativo'
          metadados?: Json | null
          atualizado_por?: string | null
        }
      }

      // ── Recursos Operacionais ─────────────────────────────────────────────────
      veiculos: {
        Row: {
          id: string
          tipo_id: string
          placa: string
          modelo: string | null
          status: 'ativo' | 'inativo' | 'manutencao'
          observacoes: string | null
          metadados: Json | null
          criado_em: string
          atualizado_em: string
          criado_por: string | null
          atualizado_por: string | null
        }
        Insert: {
          id?: string
          tipo_id: string
          placa: string
          modelo?: string | null
          status?: 'ativo' | 'inativo' | 'manutencao'
          observacoes?: string | null
          metadados?: Json | null
          criado_por?: string | null
        }
        Update: {
          tipo_id?: string
          placa?: string
          modelo?: string | null
          status?: 'ativo' | 'inativo' | 'manutencao'
          observacoes?: string | null
          metadados?: Json | null
          atualizado_por?: string | null
        }
      }
      armamentos: {
        Row: {
          id: string
          tipo_id: string
          calibre_id: string
          numeracao: string | null
          documentacao: string | null
          status: 'ativo' | 'inativo'
          metadados: Json | null
          criado_em: string
          atualizado_em: string
          criado_por: string | null
          atualizado_por: string | null
        }
        Insert: {
          id?: string
          tipo_id: string
          calibre_id: string
          numeracao?: string | null
          documentacao?: string | null
          status?: 'ativo' | 'inativo'
          metadados?: Json | null
          criado_por?: string | null
        }
        Update: {
          tipo_id?: string
          calibre_id?: string
          numeracao?: string | null
          documentacao?: string | null
          status?: 'ativo' | 'inativo'
          metadados?: Json | null
          atualizado_por?: string | null
        }
      }

      // ── Escoltas ──────────────────────────────────────────────────────────────
      escoltas: {
        Row: {
          id: string
          cliente_id: string
          codigo_escolta: string | null
          data_solicitacao: string
          data_hora_prevista: string
          status: 'rascunho' | 'agendada' | 'em_pre_inicio' | 'em_andamento' | 'na_origem' | 'em_transito_destino' | 'no_destino' | 'retornando' | 'na_base' | 'finalizada' | 'cancelada'
          origem_endereco: string
          origem_lat: number
          origem_lng: number
          destino_endereco: string
          destino_lat: number
          destino_lng: number
          checklist_pendente_no_inicio: boolean
          observacao_fechamento: string | null
          data_finalizacao: string | null
          criada_por: string
          atualizado_por: string | null
          metadados: Json | null
          criado_em: string
          atualizado_em: string
        }
        Insert: {
          id?: string
          cliente_id: string
          codigo_escolta?: string | null
          data_solicitacao?: string
          data_hora_prevista: string
          status?: 'rascunho' | 'agendada' | 'em_pre_inicio' | 'em_andamento' | 'na_origem' | 'em_transito_destino' | 'no_destino' | 'retornando' | 'na_base' | 'finalizada' | 'cancelada'
          origem_endereco: string
          origem_lat: number
          origem_lng: number
          destino_endereco: string
          destino_lat: number
          destino_lng: number
          checklist_pendente_no_inicio?: boolean
          observacao_fechamento?: string | null
          data_finalizacao?: string | null
          criada_por: string
          atualizado_por?: string | null
          metadados?: Json | null
        }
        Update: {
          status?: 'rascunho' | 'agendada' | 'em_pre_inicio' | 'em_andamento' | 'na_origem' | 'em_transito_destino' | 'no_destino' | 'retornando' | 'na_base' | 'finalizada' | 'cancelada'
          checklist_pendente_no_inicio?: boolean
          observacao_fechamento?: string | null
          data_finalizacao?: string | null
          atualizado_por?: string | null
          metadados?: Json | null
        }
      }
      escolta_status_historico: {
        Row: {
          id: string
          escolta_id: string
          status_anterior: string
          status_novo: string
          alterado_por: string | null
          data_hora: string
          latitude: number | null
          longitude: number | null
          observacao: string | null
        }
        Insert: {
          id?: string
          escolta_id: string
          status_anterior: string
          status_novo: string
          alterado_por?: string | null
          data_hora?: string
          latitude?: number | null
          longitude?: number | null
          observacao?: string | null
        }
        Update: { observacao?: string | null }
      }
      escolta_veiculos: {
        Row: {
          id: string
          escolta_id: string
          veiculo_id: string
          responsavel_lancamento_id: string | null
          quilometragem_saida: number
          quilometragem_retorno: number | null
          abastecimento_litros: number | null
          abastecimento_valor: number | null
          observacoes: string | null
          metadados: Json | null
          criado_em: string
          atualizado_em: string
          criado_por: string | null
          atualizado_por: string | null
        }
        Insert: {
          id?: string
          escolta_id: string
          veiculo_id: string
          responsavel_lancamento_id?: string | null
          quilometragem_saida: number
          quilometragem_retorno?: number | null
          abastecimento_litros?: number | null
          abastecimento_valor?: number | null
          observacoes?: string | null
          metadados?: Json | null
          criado_por?: string | null
        }
        Update: {
          responsavel_lancamento_id?: string | null
          quilometragem_saida?: number
          quilometragem_retorno?: number | null
          abastecimento_litros?: number | null
          abastecimento_valor?: number | null
          observacoes?: string | null
          metadados?: Json | null
          atualizado_por?: string | null
        }
      }
      escolta_efetivo: {
        Row: {
          id: string
          escolta_id: string
          escolta_veiculo_id: string
          vigilante_id: string
          papel_na_escolta: 'comandante' | 'operador'
          valor_cobrado_cliente: number | null
          valor_pago_vigilante: number | null
          confirmado: boolean
          criado_em: string
          atualizado_em: string
          criado_por: string | null
          atualizado_por: string | null
        }
        Insert: {
          id?: string
          escolta_id: string
          escolta_veiculo_id: string
          vigilante_id: string
          papel_na_escolta: 'comandante' | 'operador'
          valor_cobrado_cliente?: number | null
          valor_pago_vigilante?: number | null
          confirmado?: boolean
          criado_por?: string | null
        }
        Update: {
          papel_na_escolta?: 'comandante' | 'operador'
          valor_cobrado_cliente?: number | null
          valor_pago_vigilante?: number | null
          confirmado?: boolean
          atualizado_por?: string | null
        }
      }
      escolta_armamentos: {
        Row: {
          id: string
          escolta_veiculo_id: string
          armamento_id: string | null
          tipo_id: string
          calibre_id: string
          quantidade: number
          criado_em: string
          atualizado_em: string
          criado_por: string | null
          atualizado_por: string | null
        }
        Insert: {
          id?: string
          escolta_veiculo_id: string
          armamento_id?: string | null
          tipo_id: string
          calibre_id: string
          quantidade: number
          criado_por?: string | null
        }
        Update: { quantidade?: number; atualizado_por?: string | null }
      }

      // ── Campo e Geolocalização ────────────────────────────────────────────────
      fotos: {
        Row: {
          id: string
          caminho_arquivo: string
          tipo_foto_id: string
          latitude: number | null
          longitude: number | null
          precisao_metros: number | null
          data_hora_captura: string
          carimbo_aplicado: boolean
          enviada_telegram: boolean
          sincronizada: boolean
          criado_por: string | null
          criado_em: string
          atualizado_em: string
        }
        Insert: {
          id?: string
          caminho_arquivo: string
          tipo_foto_id: string
          latitude?: number | null
          longitude?: number | null
          precisao_metros?: number | null
          data_hora_captura: string
          carimbo_aplicado?: boolean
          enviada_telegram?: boolean
          sincronizada?: boolean
          criado_por?: string | null
        }
        Update: {
          enviada_telegram?: boolean
          sincronizada?: boolean
          carimbo_aplicado?: boolean
        }
      }
      pontos_controle: {
        Row: {
          id: string
          escolta_veiculo_id: string
          tipo_ponto_id: string
          data_hora: string
          latitude: number
          longitude: number
          precisao_metros: number | null
          foto_id: string | null
          lancado_por: string
          sincronizado: boolean
          criado_offline: boolean
          criado_em: string
          atualizado_em: string
        }
        Insert: {
          id?: string
          escolta_veiculo_id: string
          tipo_ponto_id: string
          data_hora: string
          latitude: number
          longitude: number
          precisao_metros?: number | null
          foto_id?: string | null
          lancado_por: string
          sincronizado?: boolean
          criado_offline?: boolean
        }
        Update: { sincronizado?: boolean; foto_id?: string | null }
      }
      rastreamento: {
        Row: {
          id: string
          escolta_veiculo_id: string
          data_hora: string
          latitude: number
          longitude: number
          precisao_metros: number | null
          sincronizado: boolean
          criado_offline: boolean
        }
        Insert: {
          id?: string
          escolta_veiculo_id: string
          data_hora: string
          latitude: number
          longitude: number
          precisao_metros?: number | null
          sincronizado?: boolean
          criado_offline?: boolean
        }
        Update: { sincronizado?: boolean }
      }
      presencas: {
        Row: {
          id: string
          escolta_id: string
          vigilante_id: string
          foto_id: string
          data_hora: string
          latitude: number
          longitude: number
          sincronizado: boolean
          criado_em: string
          atualizado_em: string
          criado_por: string | null
        }
        Insert: {
          id?: string
          escolta_id: string
          vigilante_id: string
          foto_id: string
          data_hora: string
          latitude: number
          longitude: number
          sincronizado?: boolean
          criado_por?: string | null
        }
        Update: { sincronizado?: boolean }
      }

      // ── Checklists ────────────────────────────────────────────────────────────
      checklist_modelos: {
        Row: {
          id: string
          tipo: 'material' | 'viatura'
          nome: string
          versao: number
          ativo: boolean
          criado_em: string
          atualizado_em: string
          criado_por: string | null
          atualizado_por: string | null
        }
        Insert: {
          id?: string
          tipo: 'material' | 'viatura'
          nome: string
          versao?: number
          ativo?: boolean
          criado_por?: string | null
        }
        Update: { nome?: string; ativo?: boolean; atualizado_por?: string | null }
      }
      checklist_modelo_itens: {
        Row: {
          id: string
          modelo_id: string
          descricao_item: string
          exige_foto: boolean
          ordem: number
          ativo: boolean
        }
        Insert: {
          id?: string
          modelo_id: string
          descricao_item: string
          exige_foto?: boolean
          ordem: number
          ativo?: boolean
        }
        Update: { descricao_item?: string; exige_foto?: boolean; ordem?: number; ativo?: boolean }
      }
      checklists: {
        Row: {
          id: string
          escolta_veiculo_id: string
          modelo_id: string
          tipo: 'material' | 'viatura'
          concluido: boolean
          data_conclusao: string | null
          responsavel_id: string
          sincronizado: boolean
          criado_em: string
          atualizado_em: string
        }
        Insert: {
          id?: string
          escolta_veiculo_id: string
          modelo_id: string
          tipo: 'material' | 'viatura'
          concluido?: boolean
          data_conclusao?: string | null
          responsavel_id: string
          sincronizado?: boolean
        }
        Update: { concluido?: boolean; data_conclusao?: string | null; sincronizado?: boolean }
      }
      checklist_respostas: {
        Row: {
          id: string
          checklist_id: string
          descricao_item: string
          conforme: boolean
          observacao: string | null
          foto_id: string | null
          criado_em: string
          atualizado_em: string
        }
        Insert: {
          id?: string
          checklist_id: string
          descricao_item: string
          conforme: boolean
          observacao?: string | null
          foto_id?: string | null
        }
        Update: { conforme?: boolean; observacao?: string | null; foto_id?: string | null }
      }

      // ── Exceções e Emergência ─────────────────────────────────────────────────
      ocorrencias: {
        Row: {
          id: string
          escolta_id: string
          escolta_veiculo_id: string | null
          tipo_ocorrencia_id: string
          descricao: string
          data_hora: string
          latitude: number | null
          longitude: number | null
          foto_id: string | null
          registrado_por: string
          sincronizado: boolean
          criado_em: string
          atualizado_em: string
        }
        Insert: {
          id?: string
          escolta_id: string
          escolta_veiculo_id?: string | null
          tipo_ocorrencia_id: string
          descricao: string
          data_hora: string
          latitude?: number | null
          longitude?: number | null
          foto_id?: string | null
          registrado_por: string
          sincronizado?: boolean
        }
        Update: { descricao?: string; foto_id?: string | null; sincronizado?: boolean }
      }
      emergencias: {
        Row: {
          id: string
          escolta_id: string
          escolta_veiculo_id: string
          acionado_por: string
          data_hora: string
          latitude: number
          longitude: number
          status: 'aberta' | 'em_atendimento' | 'encerrada'
          encerrada_por: string | null
          observacao: string | null
          criado_em: string
          atualizado_em: string
        }
        Insert: {
          id?: string
          escolta_id: string
          escolta_veiculo_id: string
          acionado_por: string
          data_hora: string
          latitude: number
          longitude: number
          status?: 'aberta' | 'em_atendimento' | 'encerrada'
          encerrada_por?: string | null
          observacao?: string | null
        }
        Update: {
          status?: 'aberta' | 'em_atendimento' | 'encerrada'
          encerrada_por?: string | null
          observacao?: string | null
        }
      }

      // ── Timeline, Notificações e Auditoria ────────────────────────────────────
      atualizacoes_status: {
        Row: {
          id: string
          escolta_id: string
          tipo_evento_id: string
          descricao: string
          foto_id: string | null
          autor_id: string
          data_hora: string
          latitude: number | null
          longitude: number | null
        }
        Insert: {
          id?: string
          escolta_id: string
          tipo_evento_id: string
          descricao: string
          foto_id?: string | null
          autor_id: string
          data_hora?: string
          latitude?: number | null
          longitude?: number | null
        }
        Update: Record<string, unknown>
      }
      notificacoes: {
        Row: {
          id: string
          escolta_id: string
          canal: 'app' | 'telegram'
          tipo_evento_id: string
          destino: string
          payload: Json
          status_envio: 'pendente' | 'enviada' | 'falha'
          tentativas: number
          data_envio: string | null
        }
        Insert: {
          id?: string
          escolta_id: string
          canal: 'app' | 'telegram'
          tipo_evento_id: string
          destino: string
          payload?: Json
          status_envio?: 'pendente' | 'enviada' | 'falha'
          tentativas?: number
          data_envio?: string | null
        }
        Update: {
          status_envio?: 'pendente' | 'enviada' | 'falha'
          tentativas?: number
          data_envio?: string | null
        }
      }
      logs_auditoria: {
        Row: {
          id: string
          usuario_id: string | null
          acao: string
          entidade_afetada: string
          registro_id: string | null
          dados_antes: Json | null
          dados_depois: Json | null
          data_hora: string
          ip: string | null
        }
        Insert: {
          id?: string
          usuario_id?: string | null
          acao: string
          entidade_afetada: string
          registro_id?: string | null
          dados_antes?: Json | null
          dados_depois?: Json | null
          data_hora?: string
          ip?: string | null
        }
        Update: Record<string, unknown>
      }
    }
    Views: Record<string, { Row: Record<string, unknown> }>
    Functions: {
      get_meu_perfil: { Args: Record<string, unknown>; Returns: string | null }
      get_meu_usuario_id: { Args: Record<string, unknown>; Returns: string | null }
      get_meu_vigilante_id: { Args: Record<string, unknown>; Returns: string | null }
    }
    Enums: Record<string, string[]>
  }
}
