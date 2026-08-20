export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.15"
  }
  public: {
    Tables: {
      armamentos: {
        Row: {
          atualizado_em: string
          atualizado_por: string | null
          calibre_id: string
          criado_em: string
          criado_por: string | null
          documentacao: string | null
          id: string
          metadados: Json | null
          numeracao: string | null
          status: string
          tipo_id: string
        }
        Insert: {
          atualizado_em?: string
          atualizado_por?: string | null
          calibre_id: string
          criado_em?: string
          criado_por?: string | null
          documentacao?: string | null
          id?: string
          metadados?: Json | null
          numeracao?: string | null
          status?: string
          tipo_id: string
        }
        Update: {
          atualizado_em?: string
          atualizado_por?: string | null
          calibre_id?: string
          criado_em?: string
          criado_por?: string | null
          documentacao?: string | null
          id?: string
          metadados?: Json | null
          numeracao?: string | null
          status?: string
          tipo_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "armamentos_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "armamentos_calibre_id_fkey"
            columns: ["calibre_id"]
            isOneToOne: false
            referencedRelation: "dom_calibres"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "armamentos_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "armamentos_tipo_id_fkey"
            columns: ["tipo_id"]
            isOneToOne: false
            referencedRelation: "dom_tipos_armamento"
            referencedColumns: ["id"]
          },
        ]
      }
      atualizacoes_status: {
        Row: {
          autor_id: string
          data_hora: string
          descricao: string
          escolta_id: string
          foto_id: string | null
          id: string
          latitude: number | null
          longitude: number | null
          tipo_evento_id: string
        }
        Insert: {
          autor_id: string
          data_hora?: string
          descricao: string
          escolta_id: string
          foto_id?: string | null
          id?: string
          latitude?: number | null
          longitude?: number | null
          tipo_evento_id: string
        }
        Update: {
          autor_id?: string
          data_hora?: string
          descricao?: string
          escolta_id?: string
          foto_id?: string | null
          id?: string
          latitude?: number | null
          longitude?: number | null
          tipo_evento_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "atualizacoes_status_autor_id_fkey"
            columns: ["autor_id"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "atualizacoes_status_escolta_id_fkey"
            columns: ["escolta_id"]
            isOneToOne: false
            referencedRelation: "escoltas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "atualizacoes_status_foto_id_fkey"
            columns: ["foto_id"]
            isOneToOne: false
            referencedRelation: "fotos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "atualizacoes_status_tipo_evento_id_fkey"
            columns: ["tipo_evento_id"]
            isOneToOne: false
            referencedRelation: "dom_tipos_evento"
            referencedColumns: ["id"]
          },
        ]
      }
      chat_mensagens: {
        Row: {
          criado_em: string | null
          de_usuario_id: string
          foto_url: string | null
          id: string
          lida: boolean | null
          mensagem: string
          para_usuario_id: string
        }
        Insert: {
          criado_em?: string | null
          de_usuario_id: string
          foto_url?: string | null
          id?: string
          lida?: boolean | null
          mensagem: string
          para_usuario_id: string
        }
        Update: {
          criado_em?: string | null
          de_usuario_id?: string
          foto_url?: string | null
          id?: string
          lida?: boolean | null
          mensagem?: string
          para_usuario_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "chat_mensagens_de_usuario_id_fkey"
            columns: ["de_usuario_id"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chat_mensagens_para_usuario_id_fkey"
            columns: ["para_usuario_id"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
        ]
      }
      checklist_modelo_itens: {
        Row: {
          ativo: boolean
          descricao_item: string
          exige_foto: boolean
          id: string
          modelo_id: string
          ordem: number
        }
        Insert: {
          ativo?: boolean
          descricao_item: string
          exige_foto?: boolean
          id?: string
          modelo_id: string
          ordem: number
        }
        Update: {
          ativo?: boolean
          descricao_item?: string
          exige_foto?: boolean
          id?: string
          modelo_id?: string
          ordem?: number
        }
        Relationships: [
          {
            foreignKeyName: "checklist_modelo_itens_modelo_id_fkey"
            columns: ["modelo_id"]
            isOneToOne: false
            referencedRelation: "checklist_modelos"
            referencedColumns: ["id"]
          },
        ]
      }
      checklist_modelos: {
        Row: {
          ativo: boolean
          atualizado_em: string
          atualizado_por: string | null
          criado_em: string
          criado_por: string | null
          id: string
          nome: string
          tipo: string
          versao: number
        }
        Insert: {
          ativo?: boolean
          atualizado_em?: string
          atualizado_por?: string | null
          criado_em?: string
          criado_por?: string | null
          id?: string
          nome: string
          tipo: string
          versao?: number
        }
        Update: {
          ativo?: boolean
          atualizado_em?: string
          atualizado_por?: string | null
          criado_em?: string
          criado_por?: string | null
          id?: string
          nome?: string
          tipo?: string
          versao?: number
        }
        Relationships: [
          {
            foreignKeyName: "checklist_modelos_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "checklist_modelos_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
        ]
      }
      checklist_respostas: {
        Row: {
          atualizado_em: string
          checklist_id: string
          conforme: boolean
          criado_em: string
          descricao_item: string
          foto_id: string | null
          id: string
          observacao: string | null
        }
        Insert: {
          atualizado_em?: string
          checklist_id: string
          conforme: boolean
          criado_em?: string
          descricao_item: string
          foto_id?: string | null
          id?: string
          observacao?: string | null
        }
        Update: {
          atualizado_em?: string
          checklist_id?: string
          conforme?: boolean
          criado_em?: string
          descricao_item?: string
          foto_id?: string | null
          id?: string
          observacao?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "checklist_respostas_checklist_id_fkey"
            columns: ["checklist_id"]
            isOneToOne: false
            referencedRelation: "checklists"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "checklist_respostas_foto_id_fkey"
            columns: ["foto_id"]
            isOneToOne: false
            referencedRelation: "fotos"
            referencedColumns: ["id"]
          },
        ]
      }
      checklists: {
        Row: {
          atualizado_em: string
          concluido: boolean
          criado_em: string
          data_conclusao: string | null
          data_inicio: string | null
          escolta_veiculo_id: string
          id: string
          modelo_id: string | null
          responsavel_id: string
          sincronizado: boolean
          tipo: string
        }
        Insert: {
          atualizado_em?: string
          concluido?: boolean
          criado_em?: string
          data_conclusao?: string | null
          data_inicio?: string | null
          escolta_veiculo_id: string
          id?: string
          modelo_id?: string | null
          responsavel_id: string
          sincronizado?: boolean
          tipo: string
        }
        Update: {
          atualizado_em?: string
          concluido?: boolean
          criado_em?: string
          data_conclusao?: string | null
          data_inicio?: string | null
          escolta_veiculo_id?: string
          id?: string
          modelo_id?: string | null
          responsavel_id?: string
          sincronizado?: boolean
          tipo?: string
        }
        Relationships: [
          {
            foreignKeyName: "checklists_escolta_veiculo_id_fkey"
            columns: ["escolta_veiculo_id"]
            isOneToOne: false
            referencedRelation: "escolta_veiculos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "checklists_modelo_id_fkey"
            columns: ["modelo_id"]
            isOneToOne: false
            referencedRelation: "checklist_modelos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "checklists_responsavel_id_fkey"
            columns: ["responsavel_id"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
        ]
      }
      clientes: {
        Row: {
          atualizado_em: string
          atualizado_por: string | null
          cnpj: string | null
          contato: string
          cor_destaque: string
          criado_em: string
          criado_por: string | null
          id: string
          km_franquia: number | null
          metadados: Json | null
          nome_cliente: string
          observacoes: string | null
          status: string
          telefone: string
          telegram_chat_id: string | null
          valor_km_excedente: number | null
          valor_padrao_escolta: number | null
        }
        Insert: {
          atualizado_em?: string
          atualizado_por?: string | null
          cnpj?: string | null
          contato: string
          cor_destaque?: string
          criado_em?: string
          criado_por?: string | null
          id?: string
          km_franquia?: number | null
          metadados?: Json | null
          nome_cliente: string
          observacoes?: string | null
          status?: string
          telefone: string
          telegram_chat_id?: string | null
          valor_km_excedente?: number | null
          valor_padrao_escolta?: number | null
        }
        Update: {
          atualizado_em?: string
          atualizado_por?: string | null
          cnpj?: string | null
          contato?: string
          cor_destaque?: string
          criado_em?: string
          criado_por?: string | null
          id?: string
          km_franquia?: number | null
          metadados?: Json | null
          nome_cliente?: string
          observacoes?: string | null
          status?: string
          telefone?: string
          telegram_chat_id?: string | null
          valor_km_excedente?: number | null
          valor_padrao_escolta?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "clientes_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "clientes_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
        ]
      }
      dom_calibres: {
        Row: {
          ativo: boolean
          id: string
          nome: string
        }
        Insert: {
          ativo?: boolean
          id?: string
          nome: string
        }
        Update: {
          ativo?: boolean
          id?: string
          nome?: string
        }
        Relationships: []
      }
      dom_funcoes: {
        Row: {
          ativo: boolean
          id: string
          nome: string
        }
        Insert: {
          ativo?: boolean
          id?: string
          nome: string
        }
        Update: {
          ativo?: boolean
          id?: string
          nome?: string
        }
        Relationships: []
      }
      dom_perfis: {
        Row: {
          ativo: boolean
          codigo: string
          id: string
          nome_exibicao: string
        }
        Insert: {
          ativo?: boolean
          codigo: string
          id?: string
          nome_exibicao: string
        }
        Update: {
          ativo?: boolean
          codigo?: string
          id?: string
          nome_exibicao?: string
        }
        Relationships: []
      }
      dom_tipos_armamento: {
        Row: {
          ativo: boolean
          id: string
          nome: string
        }
        Insert: {
          ativo?: boolean
          id?: string
          nome: string
        }
        Update: {
          ativo?: boolean
          id?: string
          nome?: string
        }
        Relationships: []
      }
      dom_tipos_evento: {
        Row: {
          ativo: boolean
          codigo: string
          gera_notificacao: boolean
          id: string
          nome_exibicao: string
        }
        Insert: {
          ativo?: boolean
          codigo: string
          gera_notificacao?: boolean
          id?: string
          nome_exibicao: string
        }
        Update: {
          ativo?: boolean
          codigo?: string
          gera_notificacao?: boolean
          id?: string
          nome_exibicao?: string
        }
        Relationships: []
      }
      dom_tipos_foto: {
        Row: {
          ativo: boolean
          codigo: string
          id: string
          nome_exibicao: string
        }
        Insert: {
          ativo?: boolean
          codigo: string
          id?: string
          nome_exibicao: string
        }
        Update: {
          ativo?: boolean
          codigo?: string
          id?: string
          nome_exibicao?: string
        }
        Relationships: []
      }
      dom_tipos_ocorrencia: {
        Row: {
          ativo: boolean
          id: string
          nome: string
        }
        Insert: {
          ativo?: boolean
          id?: string
          nome: string
        }
        Update: {
          ativo?: boolean
          id?: string
          nome?: string
        }
        Relationships: []
      }
      dom_tipos_ponto: {
        Row: {
          ativo: boolean
          codigo: string
          id: string
          nome_exibicao: string
          ordem: number
        }
        Insert: {
          ativo?: boolean
          codigo: string
          id?: string
          nome_exibicao: string
          ordem: number
        }
        Update: {
          ativo?: boolean
          codigo?: string
          id?: string
          nome_exibicao?: string
          ordem?: number
        }
        Relationships: []
      }
      dom_tipos_veiculo: {
        Row: {
          ativo: boolean
          id: string
          nome: string
        }
        Insert: {
          ativo?: boolean
          id?: string
          nome: string
        }
        Update: {
          ativo?: boolean
          id?: string
          nome?: string
        }
        Relationships: []
      }
      emergencias: {
        Row: {
          acionado_por: string
          atualizado_em: string
          criado_em: string
          data_hora: string
          encerrada_por: string | null
          escolta_id: string
          escolta_veiculo_id: string
          id: string
          latitude: number
          longitude: number
          observacao: string | null
          status: string
        }
        Insert: {
          acionado_por: string
          atualizado_em?: string
          criado_em?: string
          data_hora: string
          encerrada_por?: string | null
          escolta_id: string
          escolta_veiculo_id: string
          id?: string
          latitude: number
          longitude: number
          observacao?: string | null
          status?: string
        }
        Update: {
          acionado_por?: string
          atualizado_em?: string
          criado_em?: string
          data_hora?: string
          encerrada_por?: string | null
          escolta_id?: string
          escolta_veiculo_id?: string
          id?: string
          latitude?: number
          longitude?: number
          observacao?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "emergencias_acionado_por_fkey"
            columns: ["acionado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "emergencias_encerrada_por_fkey"
            columns: ["encerrada_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "emergencias_escolta_id_fkey"
            columns: ["escolta_id"]
            isOneToOne: false
            referencedRelation: "escoltas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "emergencias_escolta_veiculo_id_fkey"
            columns: ["escolta_veiculo_id"]
            isOneToOne: false
            referencedRelation: "escolta_veiculos"
            referencedColumns: ["id"]
          },
        ]
      }
      escolta_armamentos: {
        Row: {
          armamento_id: string | null
          atualizado_em: string
          atualizado_por: string | null
          calibre_id: string
          criado_em: string
          criado_por: string | null
          escolta_veiculo_id: string
          id: string
          quantidade: number
          tipo_id: string
        }
        Insert: {
          armamento_id?: string | null
          atualizado_em?: string
          atualizado_por?: string | null
          calibre_id: string
          criado_em?: string
          criado_por?: string | null
          escolta_veiculo_id: string
          id?: string
          quantidade: number
          tipo_id: string
        }
        Update: {
          armamento_id?: string | null
          atualizado_em?: string
          atualizado_por?: string | null
          calibre_id?: string
          criado_em?: string
          criado_por?: string | null
          escolta_veiculo_id?: string
          id?: string
          quantidade?: number
          tipo_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "escolta_armamentos_armamento_id_fkey"
            columns: ["armamento_id"]
            isOneToOne: false
            referencedRelation: "armamentos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_armamentos_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_armamentos_calibre_id_fkey"
            columns: ["calibre_id"]
            isOneToOne: false
            referencedRelation: "dom_calibres"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_armamentos_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_armamentos_escolta_veiculo_id_fkey"
            columns: ["escolta_veiculo_id"]
            isOneToOne: false
            referencedRelation: "escolta_veiculos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_armamentos_tipo_id_fkey"
            columns: ["tipo_id"]
            isOneToOne: false
            referencedRelation: "dom_tipos_armamento"
            referencedColumns: ["id"]
          },
        ]
      }
      escolta_efetivo: {
        Row: {
          atualizado_em: string
          atualizado_por: string | null
          confirmado: boolean
          criado_em: string
          criado_por: string | null
          escolta_id: string
          escolta_veiculo_id: string
          id: string
          papel_na_escolta: string
          valor_cobrado_cliente: number | null
          valor_pago_vigilante: number | null
          vigilante_id: string
        }
        Insert: {
          atualizado_em?: string
          atualizado_por?: string | null
          confirmado?: boolean
          criado_em?: string
          criado_por?: string | null
          escolta_id: string
          escolta_veiculo_id: string
          id?: string
          papel_na_escolta: string
          valor_cobrado_cliente?: number | null
          valor_pago_vigilante?: number | null
          vigilante_id: string
        }
        Update: {
          atualizado_em?: string
          atualizado_por?: string | null
          confirmado?: boolean
          criado_em?: string
          criado_por?: string | null
          escolta_id?: string
          escolta_veiculo_id?: string
          id?: string
          papel_na_escolta?: string
          valor_cobrado_cliente?: number | null
          valor_pago_vigilante?: number | null
          vigilante_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "escolta_efetivo_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_efetivo_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_efetivo_escolta_id_fkey"
            columns: ["escolta_id"]
            isOneToOne: false
            referencedRelation: "escoltas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_efetivo_escolta_veiculo_id_fkey"
            columns: ["escolta_veiculo_id"]
            isOneToOne: false
            referencedRelation: "escolta_veiculos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_efetivo_vigilante_id_fkey"
            columns: ["vigilante_id"]
            isOneToOne: false
            referencedRelation: "vigilantes"
            referencedColumns: ["id"]
          },
        ]
      }
      escolta_status_historico: {
        Row: {
          alterado_por: string | null
          data_hora: string
          escolta_id: string
          id: string
          latitude: number | null
          longitude: number | null
          observacao: string | null
          status_anterior: string
          status_novo: string
        }
        Insert: {
          alterado_por?: string | null
          data_hora?: string
          escolta_id: string
          id?: string
          latitude?: number | null
          longitude?: number | null
          observacao?: string | null
          status_anterior: string
          status_novo: string
        }
        Update: {
          alterado_por?: string | null
          data_hora?: string
          escolta_id?: string
          id?: string
          latitude?: number | null
          longitude?: number | null
          observacao?: string | null
          status_anterior?: string
          status_novo?: string
        }
        Relationships: [
          {
            foreignKeyName: "escolta_status_historico_alterado_por_fkey"
            columns: ["alterado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_status_historico_escolta_id_fkey"
            columns: ["escolta_id"]
            isOneToOne: false
            referencedRelation: "escoltas"
            referencedColumns: ["id"]
          },
        ]
      }
      escolta_veiculos: {
        Row: {
          abastecimento_litros: number | null
          abastecimento_valor: number | null
          atualizado_em: string
          atualizado_por: string | null
          criado_em: string
          criado_por: string | null
          escolta_id: string
          id: string
          metadados: Json | null
          observacoes: string | null
          quilometragem_retorno: number | null
          quilometragem_saida: number | null
          responsavel_lancamento_id: string | null
          veiculo_id: string
        }
        Insert: {
          abastecimento_litros?: number | null
          abastecimento_valor?: number | null
          atualizado_em?: string
          atualizado_por?: string | null
          criado_em?: string
          criado_por?: string | null
          escolta_id: string
          id?: string
          metadados?: Json | null
          observacoes?: string | null
          quilometragem_retorno?: number | null
          quilometragem_saida?: number | null
          responsavel_lancamento_id?: string | null
          veiculo_id: string
        }
        Update: {
          abastecimento_litros?: number | null
          abastecimento_valor?: number | null
          atualizado_em?: string
          atualizado_por?: string | null
          criado_em?: string
          criado_por?: string | null
          escolta_id?: string
          id?: string
          metadados?: Json | null
          observacoes?: string | null
          quilometragem_retorno?: number | null
          quilometragem_saida?: number | null
          responsavel_lancamento_id?: string | null
          veiculo_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "escolta_veiculos_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_veiculos_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_veiculos_escolta_id_fkey"
            columns: ["escolta_id"]
            isOneToOne: false
            referencedRelation: "escoltas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_veiculos_responsavel_lancamento_id_fkey"
            columns: ["responsavel_lancamento_id"]
            isOneToOne: false
            referencedRelation: "vigilantes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escolta_veiculos_veiculo_id_fkey"
            columns: ["veiculo_id"]
            isOneToOne: false
            referencedRelation: "veiculos"
            referencedColumns: ["id"]
          },
        ]
      }
      escoltas: {
        Row: {
          atualizado_em: string
          atualizado_por: string | null
          checklist_pendente_no_inicio: boolean
          cliente_id: string
          codigo_escolta: string | null
          criada_por: string
          criado_em: string
          data_finalizacao: string | null
          data_hora_prevista: string
          data_solicitacao: string
          destino_endereco: string
          destino_lat: number
          destino_lng: number
          id: string
          metadados: Json | null
          observacao_fechamento: string | null
          observacao_financeira: string | null
          origem_endereco: string
          origem_lat: number
          origem_lng: number
          outros_custos: number | null
          periodicidade_checkin_min: number | null
          status: string
          valor_cobrado: number | null
        }
        Insert: {
          atualizado_em?: string
          atualizado_por?: string | null
          checklist_pendente_no_inicio?: boolean
          cliente_id: string
          codigo_escolta?: string | null
          criada_por: string
          criado_em?: string
          data_finalizacao?: string | null
          data_hora_prevista: string
          data_solicitacao?: string
          destino_endereco: string
          destino_lat: number
          destino_lng: number
          id?: string
          metadados?: Json | null
          observacao_fechamento?: string | null
          observacao_financeira?: string | null
          origem_endereco: string
          origem_lat: number
          origem_lng: number
          outros_custos?: number | null
          periodicidade_checkin_min?: number | null
          status?: string
          valor_cobrado?: number | null
        }
        Update: {
          atualizado_em?: string
          atualizado_por?: string | null
          checklist_pendente_no_inicio?: boolean
          cliente_id?: string
          codigo_escolta?: string | null
          criada_por?: string
          criado_em?: string
          data_finalizacao?: string | null
          data_hora_prevista?: string
          data_solicitacao?: string
          destino_endereco?: string
          destino_lat?: number
          destino_lng?: number
          id?: string
          metadados?: Json | null
          observacao_fechamento?: string | null
          observacao_financeira?: string | null
          origem_endereco?: string
          origem_lat?: number
          origem_lng?: number
          outros_custos?: number | null
          periodicidade_checkin_min?: number | null
          status?: string
          valor_cobrado?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "escoltas_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escoltas_cliente_id_fkey"
            columns: ["cliente_id"]
            isOneToOne: false
            referencedRelation: "clientes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "escoltas_criada_por_fkey"
            columns: ["criada_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
        ]
      }
      fotos: {
        Row: {
          atualizado_em: string
          caminho_arquivo: string
          carimbo_aplicado: boolean
          criado_em: string
          criado_por: string | null
          data_hora_captura: string
          enviada_telegram: boolean
          id: string
          latitude: number | null
          longitude: number | null
          precisao_metros: number | null
          sincronizada: boolean
          tipo_foto_id: string
        }
        Insert: {
          atualizado_em?: string
          caminho_arquivo: string
          carimbo_aplicado?: boolean
          criado_em?: string
          criado_por?: string | null
          data_hora_captura: string
          enviada_telegram?: boolean
          id?: string
          latitude?: number | null
          longitude?: number | null
          precisao_metros?: number | null
          sincronizada?: boolean
          tipo_foto_id: string
        }
        Update: {
          atualizado_em?: string
          caminho_arquivo?: string
          carimbo_aplicado?: boolean
          criado_em?: string
          criado_por?: string | null
          data_hora_captura?: string
          enviada_telegram?: boolean
          id?: string
          latitude?: number | null
          longitude?: number | null
          precisao_metros?: number | null
          sincronizada?: boolean
          tipo_foto_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fotos_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fotos_tipo_foto_id_fkey"
            columns: ["tipo_foto_id"]
            isOneToOne: false
            referencedRelation: "dom_tipos_foto"
            referencedColumns: ["id"]
          },
        ]
      }
      logs_auditoria: {
        Row: {
          acao: string
          dados_antes: Json | null
          dados_depois: Json | null
          data_hora: string
          entidade_afetada: string
          id: string
          ip: string | null
          registro_id: string | null
          usuario_id: string | null
        }
        Insert: {
          acao: string
          dados_antes?: Json | null
          dados_depois?: Json | null
          data_hora?: string
          entidade_afetada: string
          id?: string
          ip?: string | null
          registro_id?: string | null
          usuario_id?: string | null
        }
        Update: {
          acao?: string
          dados_antes?: Json | null
          dados_depois?: Json | null
          data_hora?: string
          entidade_afetada?: string
          id?: string
          ip?: string | null
          registro_id?: string | null
          usuario_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "logs_auditoria_usuario_id_fkey"
            columns: ["usuario_id"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
        ]
      }
      notificacoes: {
        Row: {
          canal: string
          criado_em: string | null
          data_envio: string | null
          destino: string
          escolta_id: string
          id: string
          lida: boolean | null
          payload: Json
          status_envio: string
          tentativas: number
          tipo_evento_id: string
          usuario_dest_id: string | null
        }
        Insert: {
          canal: string
          criado_em?: string | null
          data_envio?: string | null
          destino: string
          escolta_id: string
          id?: string
          lida?: boolean | null
          payload?: Json
          status_envio?: string
          tentativas?: number
          tipo_evento_id: string
          usuario_dest_id?: string | null
        }
        Update: {
          canal?: string
          criado_em?: string | null
          data_envio?: string | null
          destino?: string
          escolta_id?: string
          id?: string
          lida?: boolean | null
          payload?: Json
          status_envio?: string
          tentativas?: number
          tipo_evento_id?: string
          usuario_dest_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "notificacoes_escolta_id_fkey"
            columns: ["escolta_id"]
            isOneToOne: false
            referencedRelation: "escoltas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notificacoes_tipo_evento_id_fkey"
            columns: ["tipo_evento_id"]
            isOneToOne: false
            referencedRelation: "dom_tipos_evento"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notificacoes_usuario_dest_id_fkey"
            columns: ["usuario_dest_id"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
        ]
      }
      ocorrencias: {
        Row: {
          atualizado_em: string
          criado_em: string
          data_hora: string
          descricao: string
          escolta_id: string
          escolta_veiculo_id: string | null
          foto_id: string | null
          id: string
          latitude: number | null
          longitude: number | null
          registrado_por: string
          sincronizado: boolean
          tipo_ocorrencia_id: string
        }
        Insert: {
          atualizado_em?: string
          criado_em?: string
          data_hora: string
          descricao: string
          escolta_id: string
          escolta_veiculo_id?: string | null
          foto_id?: string | null
          id?: string
          latitude?: number | null
          longitude?: number | null
          registrado_por: string
          sincronizado?: boolean
          tipo_ocorrencia_id: string
        }
        Update: {
          atualizado_em?: string
          criado_em?: string
          data_hora?: string
          descricao?: string
          escolta_id?: string
          escolta_veiculo_id?: string | null
          foto_id?: string | null
          id?: string
          latitude?: number | null
          longitude?: number | null
          registrado_por?: string
          sincronizado?: boolean
          tipo_ocorrencia_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "ocorrencias_escolta_id_fkey"
            columns: ["escolta_id"]
            isOneToOne: false
            referencedRelation: "escoltas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ocorrencias_escolta_veiculo_id_fkey"
            columns: ["escolta_veiculo_id"]
            isOneToOne: false
            referencedRelation: "escolta_veiculos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ocorrencias_foto_id_fkey"
            columns: ["foto_id"]
            isOneToOne: false
            referencedRelation: "fotos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ocorrencias_registrado_por_fkey"
            columns: ["registrado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ocorrencias_tipo_ocorrencia_id_fkey"
            columns: ["tipo_ocorrencia_id"]
            isOneToOne: false
            referencedRelation: "dom_tipos_ocorrencia"
            referencedColumns: ["id"]
          },
        ]
      }
      pontos_controle: {
        Row: {
          atualizado_em: string
          criado_em: string
          criado_offline: boolean
          data_hora: string
          escolta_veiculo_id: string
          foto_id: string | null
          id: string
          lancado_por: string
          latitude: number | null
          longitude: number | null
          observacoes: string | null
          precisao_metros: number | null
          sem_sinal_gps: boolean
          sincronizado: boolean
          tipo_ponto_id: string
        }
        Insert: {
          atualizado_em?: string
          criado_em?: string
          criado_offline?: boolean
          data_hora: string
          escolta_veiculo_id: string
          foto_id?: string | null
          id?: string
          lancado_por: string
          latitude: number | null
          longitude: number | null
          observacoes?: string | null
          precisao_metros?: number | null
          sem_sinal_gps?: boolean
          sincronizado?: boolean
          tipo_ponto_id: string
        }
        Update: {
          atualizado_em?: string
          criado_em?: string
          criado_offline?: boolean
          data_hora?: string
          escolta_veiculo_id?: string
          foto_id?: string | null
          id?: string
          lancado_por?: string
          latitude?: number | null
          longitude?: number | null
          observacoes?: string | null
          precisao_metros?: number | null
          sem_sinal_gps?: boolean
          sincronizado?: boolean
          tipo_ponto_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pontos_controle_escolta_veiculo_id_fkey"
            columns: ["escolta_veiculo_id"]
            isOneToOne: false
            referencedRelation: "escolta_veiculos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pontos_controle_foto_id_fkey"
            columns: ["foto_id"]
            isOneToOne: false
            referencedRelation: "fotos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pontos_controle_lancado_por_fkey"
            columns: ["lancado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pontos_controle_tipo_ponto_id_fkey"
            columns: ["tipo_ponto_id"]
            isOneToOne: false
            referencedRelation: "dom_tipos_ponto"
            referencedColumns: ["id"]
          },
        ]
      }
      presencas: {
        Row: {
          atualizado_em: string
          criado_em: string
          criado_por: string | null
          data_hora: string
          escolta_id: string
          foto_id: string
          id: string
          latitude: number
          longitude: number
          sincronizado: boolean
          vigilante_id: string
        }
        Insert: {
          atualizado_em?: string
          criado_em?: string
          criado_por?: string | null
          data_hora: string
          escolta_id: string
          foto_id: string
          id?: string
          latitude: number
          longitude: number
          sincronizado?: boolean
          vigilante_id: string
        }
        Update: {
          atualizado_em?: string
          criado_em?: string
          criado_por?: string | null
          data_hora?: string
          escolta_id?: string
          foto_id?: string
          id?: string
          latitude?: number
          longitude?: number
          sincronizado?: boolean
          vigilante_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "presencas_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "presencas_escolta_id_fkey"
            columns: ["escolta_id"]
            isOneToOne: false
            referencedRelation: "escoltas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "presencas_foto_id_fkey"
            columns: ["foto_id"]
            isOneToOne: false
            referencedRelation: "fotos"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "presencas_vigilante_id_fkey"
            columns: ["vigilante_id"]
            isOneToOne: false
            referencedRelation: "vigilantes"
            referencedColumns: ["id"]
          },
        ]
      }
      rastreamento: {
        Row: {
          criado_offline: boolean
          data_hora: string
          escolta_veiculo_id: string
          id: string
          latitude: number
          longitude: number
          precisao_metros: number | null
          sincronizado: boolean
        }
        Insert: {
          criado_offline?: boolean
          data_hora: string
          escolta_veiculo_id: string
          id?: string
          latitude: number
          longitude: number
          precisao_metros?: number | null
          sincronizado?: boolean
        }
        Update: {
          criado_offline?: boolean
          data_hora?: string
          escolta_veiculo_id?: string
          id?: string
          latitude?: number
          longitude?: number
          precisao_metros?: number | null
          sincronizado?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "rastreamento_escolta_veiculo_id_fkey"
            columns: ["escolta_veiculo_id"]
            isOneToOne: false
            referencedRelation: "escolta_veiculos"
            referencedColumns: ["id"]
          },
        ]
      }
      usuarios: {
        Row: {
          aprovado_por: string | null
          atualizado_em: string
          atualizado_por: string | null
          auth_user_id: string | null
          cpf: string | null
          criado_em: string
          criado_por: string | null
          email: string
          id: string
          metadados: Json | null
          nome_completo: string
          perfil_id: string
          status: string
          telefone: string | null
          troca_senha_obrigatoria: boolean
          ultimo_acesso: string | null
        }
        Insert: {
          aprovado_por?: string | null
          atualizado_em?: string
          atualizado_por?: string | null
          auth_user_id?: string | null
          cpf?: string | null
          criado_em?: string
          criado_por?: string | null
          email: string
          id?: string
          metadados?: Json | null
          nome_completo: string
          perfil_id: string
          status?: string
          telefone?: string | null
          troca_senha_obrigatoria?: boolean
          ultimo_acesso?: string | null
        }
        Update: {
          aprovado_por?: string | null
          atualizado_em?: string
          atualizado_por?: string | null
          auth_user_id?: string | null
          cpf?: string | null
          criado_em?: string
          criado_por?: string | null
          email?: string
          id?: string
          metadados?: Json | null
          nome_completo?: string
          perfil_id?: string
          status?: string
          telefone?: string | null
          troca_senha_obrigatoria?: boolean
          ultimo_acesso?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "usuarios_aprovado_por_fkey"
            columns: ["aprovado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usuarios_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usuarios_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usuarios_perfil_id_fkey"
            columns: ["perfil_id"]
            isOneToOne: false
            referencedRelation: "dom_perfis"
            referencedColumns: ["id"]
          },
        ]
      }
      veiculos: {
        Row: {
          atualizado_em: string
          atualizado_por: string | null
          criado_em: string
          criado_por: string | null
          id: string
          metadados: Json | null
          modelo: string | null
          observacoes: string | null
          placa: string
          status: string
          tipo_id: string
        }
        Insert: {
          atualizado_em?: string
          atualizado_por?: string | null
          criado_em?: string
          criado_por?: string | null
          id?: string
          metadados?: Json | null
          modelo?: string | null
          observacoes?: string | null
          placa: string
          status?: string
          tipo_id: string
        }
        Update: {
          atualizado_em?: string
          atualizado_por?: string | null
          criado_em?: string
          criado_por?: string | null
          id?: string
          metadados?: Json | null
          modelo?: string | null
          observacoes?: string | null
          placa?: string
          status?: string
          tipo_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "veiculos_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "veiculos_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "veiculos_tipo_id_fkey"
            columns: ["tipo_id"]
            isOneToOne: false
            referencedRelation: "dom_tipos_veiculo"
            referencedColumns: ["id"]
          },
        ]
      }
      vigilantes: {
        Row: {
          atualizado_em: string
          atualizado_por: string | null
          cnv: string | null
          cpf: string
          criado_em: string
          criado_por: string | null
          extensao_escolta_armada: string | null
          funcao_id: string
          id: string
          metadados: Json | null
          nome_completo: string
          status: string
          usuario_id: string | null
          valor_padrao_pago: number | null
        }
        Insert: {
          atualizado_em?: string
          atualizado_por?: string | null
          cnv?: string | null
          cpf: string
          criado_em?: string
          criado_por?: string | null
          extensao_escolta_armada?: string | null
          funcao_id: string
          id?: string
          metadados?: Json | null
          nome_completo: string
          status?: string
          usuario_id?: string | null
          valor_padrao_pago?: number | null
        }
        Update: {
          atualizado_em?: string
          atualizado_por?: string | null
          cnv?: string | null
          cpf?: string
          criado_em?: string
          criado_por?: string | null
          extensao_escolta_armada?: string | null
          funcao_id?: string
          id?: string
          metadados?: Json | null
          nome_completo?: string
          status?: string
          usuario_id?: string | null
          valor_padrao_pago?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "vigilantes_atualizado_por_fkey"
            columns: ["atualizado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vigilantes_criado_por_fkey"
            columns: ["criado_por"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vigilantes_funcao_id_fkey"
            columns: ["funcao_id"]
            isOneToOne: false
            referencedRelation: "dom_funcoes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vigilantes_usuario_id_fkey"
            columns: ["usuario_id"]
            isOneToOne: false
            referencedRelation: "usuarios"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      cadastrar_operador: {
        Args: {
          p_cnv?: string
          p_cpf?: string
          p_email?: string
          p_extensao?: string
          p_funcao_id?: string
          p_login_base: string
          p_nome: string
          p_status?: string
          p_telefone?: string
          p_valor_padrao?: number
        }
        Returns: Json
      }
      criar_usuario_completo: {
        Args: {
          p_cpf?: string
          p_email: string
          p_nome: string
          p_perfil_id: string
          p_senha_temporaria: string
          p_telefone?: string
        }
        Returns: Json
      }
      excluir_auth_usuario: { Args: { p_auth_uid: string }; Returns: undefined }
      get_meu_perfil: { Args: never; Returns: string }
      get_meu_usuario_id: { Args: never; Returns: string }
      get_meu_vigilante_id: { Args: never; Returns: string }
      perfil_usuario_atual: { Args: never; Returns: string }
      redefinir_senha_usuario: {
        // Atencao: apesar do nome, p_usuario_id espera o auth_user_id, nao usuarios.id.
        Args: { p_nova_senha: string; p_usuario_id: string }
        Returns: undefined
      }
      criar_usuario_por_login: {
        Args: {
          p_cpf: string
          p_nome: string
          p_perfil_id: string
          p_telefone: string | null
        }
        Returns: { login: string; senha: string; usuario_id: string }
      }
      // Credencial em texto, decisao de Pecanha em 2026-08-19. Ver migration 190.
      registrar_credencial: {
        Args: { p_provisoria?: boolean; p_senha: string; p_usuario_id: string }
        Returns: undefined
      }
      ler_credencial: {
        Args: { p_usuario_id: string }
        Returns: string | null
      }
      // Mural de escoltas e auto-escala do operador. Ver migrations 191 e 192.
      puxar_escolta: {
        Args: { p_escolta_id: string }
        Returns: { ok: boolean; escolta_veiculo_id: string }
      }
      devolver_escolta: {
        Args: { p_escolta_id: string }
        Returns: { ok: boolean }
      }
      incluir_vigilante_na_minha_escolta: {
        Args: { p_escolta_id: string; p_vigilante_id: string }
        Returns: { ok: boolean }
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
