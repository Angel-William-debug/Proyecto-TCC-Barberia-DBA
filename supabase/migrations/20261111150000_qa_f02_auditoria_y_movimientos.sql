-- =============================================================================
-- QA de la Fase 2 (Angel, 11/11/2026): auditoria de catalogos y usuario de
-- los movimientos de consumo
-- =============================================================================
--
-- 1. La auditoria solo registraba turnos completados, recepciones de pedidos y
--    alertas de stock (F2-24): crear un servicio o desactivar un usuario no
--    dejaba rastro. Ahora un disparador generico registra altas, cambios,
--    envios a la papelera, restauraciones y bajas en los catalogos y en las
--    cuentas. El detalle nombra el registro («Alta de «QA-A Servicio»») para
--    que se pueda buscar por nombre.
--
--    En productos no se audita el cambio de stock_actual: lo mueve cada turno
--    completado y cada orden recibida, que ya quedan en movimientos_inventario.
--
-- 2. Los movimientos de consumo que genera fn_trg_producto_utilizado no
--    guardaban el usuario y en Inventario > Movimientos la columna Usuario
--    salia vacia. Ahora toma quien confirma el consumo y, si no hay sesion
--    (carga de datos), quien gestiono el turno. Se completan los viejos de la
--    misma forma, y las recepciones de pedidos con quien cargo la orden.
-- =============================================================================

-- 1 ---------------------------------------------------------------------------
-- Argumentos del disparador: la columna de la clave primaria y, despues, las
-- columnas cuyo cambio NO se audita (ademas de updated_at, que cambia siempre).
create or replace function public.fn_trg_auditar_catalogo()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    v_pk       text := tg_argv[0];
    v_ignorar  text[] := array['updated_at', 'created_at'] || coalesce(tg_argv[1:], '{}');
    v_nuevo    jsonb;
    v_viejo    jsonb;
    v_fila     jsonb;
    v_nombre   text;
    v_campos   text[];
    v_accion   text;
    v_detalle  text;
begin
    v_nuevo := case when tg_op <> 'DELETE' then to_jsonb(new) end;
    v_viejo := case when tg_op <> 'INSERT' then to_jsonb(old) end;
    v_fila  := coalesce(v_nuevo, v_viejo);
    v_nombre := coalesce(v_fila->>'nombre', v_fila->>'nombre_barberia', v_fila->>'email',
                         'dia ' || (v_fila->>'dia_semana'));

    if tg_op = 'INSERT' then
        v_accion  := 'INSERT';
        v_detalle := format('Alta de «%s»', v_nombre);
    elsif tg_op = 'DELETE' then
        v_accion  := 'DELETE';
        v_detalle := format('Borrado definitivo de «%s»', v_nombre);
    else
        select array_agg(k order by k) into v_campos
        from jsonb_object_keys(v_nuevo) k
        where v_nuevo->k is distinct from v_viejo->k
          and k <> all (v_ignorar);

        if v_campos is null then
            return null;  -- nada que valga la pena registrar
        end if;

        if 'deleted' = any (v_campos) and (v_nuevo->>'deleted')::boolean then
            v_accion  := 'DELETE';
            v_detalle := format('«%s» enviado a la papelera', v_nombre);
        elsif 'deleted' = any (v_campos) then
            v_accion  := 'UPDATE';
            v_detalle := format('«%s» restaurado de la papelera', v_nombre);
        elsif 'estado' = any (v_campos) and array_length(v_campos, 1) = 1 then
            v_accion  := 'UPDATE';
            v_detalle := format('«%s» %s', v_nombre,
                                case when (v_nuevo->>'estado')::boolean then 'activado' else 'desactivado' end);
        else
            v_accion  := 'UPDATE';
            v_detalle := format('Cambio en «%s»: %s', v_nombre,
                                array_to_string(array_remove(array_remove(v_campos, 'deleted_at'), 'deleted_user_id'), ', '));
        end if;
    end if;

    perform public.fn_registrar_auditoria(tg_table_name::varchar, v_accion::varchar, (v_fila->>v_pk)::int, left(v_detalle, 500));
    return null;
end;
$function$;

create trigger trg_auditar_servicios after insert or update or delete on public.servicios
    for each row execute function public.fn_trg_auditar_catalogo('id_servicio');
create trigger trg_auditar_categorias_servicio after insert or update or delete on public.categorias_servicio
    for each row execute function public.fn_trg_auditar_catalogo('id_categoria');
create trigger trg_auditar_productos after insert or update or delete on public.productos
    for each row execute function public.fn_trg_auditar_catalogo('id_producto', 'stock_actual');
create trigger trg_auditar_categorias_producto after insert or update or delete on public.categorias_producto
    for each row execute function public.fn_trg_auditar_catalogo('id_categoria_p');
create trigger trg_auditar_proveedores after insert or update or delete on public.proveedores
    for each row execute function public.fn_trg_auditar_catalogo('id_proveedor');
create trigger trg_auditar_profesionales after insert or update or delete on public.profesionales
    for each row execute function public.fn_trg_auditar_catalogo('id_profesional');
create trigger trg_auditar_usuarios after insert or update or delete on public.usuarios
    for each row execute function public.fn_trg_auditar_catalogo('id_usuario');
create trigger trg_auditar_clientes after insert or update or delete on public.clientes
    for each row execute function public.fn_trg_auditar_catalogo('id_cliente');
create trigger trg_auditar_metodos_pago after insert or update or delete on public.metodos_pago
    for each row execute function public.fn_trg_auditar_catalogo('id_metodo');
create trigger trg_auditar_horarios_atencion after insert or update or delete on public.horarios_atencion
    for each row execute function public.fn_trg_auditar_catalogo('id_horario');
create trigger trg_auditar_configuracion after update on public.configuracion_sistema
    for each row execute function public.fn_trg_auditar_catalogo('id_configuracion');

-- 2 ---------------------------------------------------------------------------
create or replace function public.fn_trg_producto_utilizado()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    v_usuario integer;
begin
    perform public.fn_actualizar_stock(new.id_producto, new.cantidad_usada, new.excepcion_stock);

    -- Quien confirma el consumo; sin sesion, quien gestiono el turno.
    select u.id_usuario into v_usuario from public.usuarios u where u.auth_uid = auth.uid();
    if v_usuario is null then
        select c.id_usuario into v_usuario
        from public.historial_servicio h
        join public.citas c on c.id_cita = h.id_cita
        where h.id_historial = new.id_historial;
    end if;

    insert into public.movimientos_inventario (id_producto, id_usuario, tipo, cantidad, motivo)
    values (
        new.id_producto,
        v_usuario,
        'salida',
        new.cantidad_usada,
        format('Consumo en servicio (historial %s)%s',
               new.id_historial,
               case when new.excepcion_stock then ' - EXCEPCION DE STOCK' else '' end)
    );

    return null;
end;
$function$;

-- Los movimientos viejos sin usuario: consumos (por el turno) y recepciones
-- de pedidos (por quien cargo la orden).
update public.movimientos_inventario m
set id_usuario = c.id_usuario
from public.historial_servicio h
join public.citas c on c.id_cita = h.id_cita
where m.id_usuario is null
  and m.motivo like 'Consumo en servicio (historial %'
  and h.id_historial = substring(m.motivo from 'historial ([0-9]+)')::int;

update public.movimientos_inventario m
set id_usuario = p.id_usuario
from public.pedidos p
where m.id_usuario is null
  and m.motivo like 'Recepcion de pedido %'
  and p.id_pedido = substring(m.motivo from 'Recepcion de pedido ([0-9]+)')::int;

-- Los turnos que reservo el cliente desde el portal no tienen quien los
-- gestiono: para esos, quien los completo, que la auditoria si registra.
update public.movimientos_inventario m
set id_usuario = a.id_usuario
from public.historial_servicio h
join lateral (
    select x.id_usuario from public.auditoria x
    where x.tabla_afectada = 'citas' and x.registro_id = h.id_cita
      and x.detalle like 'Cita completada%' and x.id_usuario is not null
    order by x.id_auditoria desc limit 1
) a on true
where m.id_usuario is null
  and m.motivo like 'Consumo en servicio (historial %'
  and h.id_historial = substring(m.motivo from 'historial ([0-9]+)')::int;
