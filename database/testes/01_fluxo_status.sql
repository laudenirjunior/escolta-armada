-- Teste da maquina de estados. Cria uma escolta descartavel, percorre as
-- 9 etapas, tenta violar as regras e remove tudo no fim.
create temp table if not exists res(passo text, resultado text);
truncate res;

do $$
declare
  v_cli uuid; v_usr uuid; v_esc uuid; v_ev uuid; v_veic uuid; v_tp uuid;
begin
  select id into v_cli from clientes limit 1;
  select id into v_usr from usuarios limit 1;
  select id into v_veic from veiculos limit 1;

  insert into escoltas (cliente_id, data_hora_prevista, status, fluxo_versao,
    origem_endereco, origem_lat, origem_lng, destino_endereco, destino_lat, destino_lng,
    checklist_pendente_no_inicio, criada_por)
  values (v_cli, now(), 'agendada', 2, 'TESTE', -22.9, -43.1, 'TESTE', -23.5, -46.6, false, v_usr)
  returning id into v_esc;

  insert into escolta_veiculos (escolta_id, veiculo_id, quilometragem_saida, criado_por)
  values (v_esc, v_veic, 1000, v_usr) returning id into v_ev;

  update escoltas set status='em_pre_inicio' where id=v_esc;
  update escoltas set status='em_andamento'  where id=v_esc;
  update escoltas set status='na_origem'     where id=v_esc;

  begin
    update escoltas set status='em_transito_destino' where id=v_esc;
    insert into res values ('na_origem -> em_transito_destino','PASSOU');
  exception when others then
    insert into res values ('na_origem -> em_transito_destino','FALHOU: '||SQLERRM);
  end;

  update escoltas set status='no_destino' where id=v_esc;

  begin
    update escoltas set status='em_transito_retorno' where id=v_esc;
    insert into res values ('no_destino -> em_transito_retorno (etapa nova)','PASSOU');
  exception when others then
    insert into res values ('etapa nova','FALHOU: '||SQLERRM);
  end;

  update escoltas set status='retornando' where id=v_esc;

  begin
    update escoltas set status='na_base' where id=v_esc;
    insert into res values ('concluir retorno SEM ponto de transito','PASSOU (ERRADO)');
  exception when others then
    insert into res values ('concluir retorno SEM ponto de transito','BLOQUEADO CORRETAMENTE');
  end;

  select id into v_tp from dom_tipos_ponto where codigo='transito_retorno';
  insert into pontos_controle (escolta_veiculo_id, tipo_ponto_id, data_hora, latitude, longitude, lancado_por)
  values (v_ev, v_tp, now(), -23.0, -45.0, v_usr);

  begin
    update escoltas set status='na_base'    where id=v_esc;
    update escoltas set status='finalizada' where id=v_esc;
    insert into res values ('concluir retorno COM ponto de transito','PASSOU');
  exception when others then
    insert into res values ('concluir COM ponto','FALHOU: '||SQLERRM);
  end;

  begin
    update escoltas set status='em_andamento' where id=v_esc;
    insert into res values ('transicao invalida recusada','PASSOU (ERRADO)');
  exception when others then
    insert into res values ('transicao invalida recusada','BLOQUEADO CORRETAMENTE');
  end;

  delete from escolta_status_historico where escolta_id=v_esc;
  delete from pontos_controle where escolta_veiculo_id=v_ev;
  delete from escolta_veiculos where id=v_ev;
  delete from escoltas where id=v_esc;
  insert into res values ('limpeza','OK');
end $$;

select * from res;
