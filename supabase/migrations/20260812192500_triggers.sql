-- ============================================================================
-- TRIGGERS DEL SISTEMA
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Mantenimiento de updated_at
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create trigger trg_citas_set_updated_at
    before update on public.citas
    for each row
    execute function public.fn_set_updated_at();

-- ---------------------------------------------------------------------------
-- trg_detalle_cita_before_insert
-- Bloquea el alta si el profesional ya esta ocupado en ese horario. (RN-015)
-- Va en detalle_cita porque es aqui donde se conocen id_profesional y
-- duracion_min.
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_detalle_cita_before_insert()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_fecha_hora timestamptz;
begin
    select c.fecha_hora
    into v_fecha_hora
    from public.citas c
    where c.id_cita = new.id_cita;

    if public.fn_verificar_conflicto_horario(
           new.id_profesional, v_fecha_hora, new.duracion_min, new.id_cita
       ) then
        raise exception
            'Conflicto de horario: el profesional % ya tiene un servicio agendado el %',
            new.id_profesional, v_fecha_hora;
    end if;

    return new;
end;
$$;

create trigger trg_detalle_cita_before_insert
    before insert on public.detalle_cita
    for each row
    execute function public.fn_trg_detalle_cita_before_insert();

-- ---------------------------------------------------------------------------
-- trg_detalle_cita_after_insert
-- Recalcula el total de la cita. Tambien en UPDATE y DELETE, para que el
-- total no quede desactualizado si se corrige o quita un servicio.
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_detalle_cita_recalcular_total()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_id_cita int := coalesce(new.id_cita, old.id_cita);
begin
    update public.citas
    set total = public.fn_calcular_total_cita(v_id_cita)
    where id_cita = v_id_cita;

    return null;
end;
$$;

create trigger trg_detalle_cita_after_insert
    after insert or update or delete on public.detalle_cita
    for each row
    execute function public.fn_trg_detalle_cita_recalcular_total();

-- ---------------------------------------------------------------------------
-- trg_cita_completada_after_update
-- Al pasar la cita a 'completado':
--   1. genera historial_servicio por cada servicio del detalle
--   2. calcula la comision y crea el pago al profesional (pendiente)
--   3. registra la accion en auditoria
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_cita_completada()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    r_detalle    record;
    v_id_historial int;
begin
    for r_detalle in
        select d.id_servicio, d.id_profesional, d.subtotal
        from public.detalle_cita d
        where d.id_cita = new.id_cita
    loop
        insert into public.historial_servicio (
            id_cita, id_cliente, id_profesional, id_servicio,
            fecha_realizacion, costo_cobrado
        )
        values (
            new.id_cita, new.id_cliente, r_detalle.id_profesional, r_detalle.id_servicio,
            new.fecha_hora::date, r_detalle.subtotal
        )
        returning id_historial into v_id_historial;

        insert into public.pagos_profesional (id_profesional, id_historial, monto, estado)
        values (
            r_detalle.id_profesional,
            v_id_historial,
            public.fn_calcular_comision(v_id_historial),
            'pendiente'
        );
    end loop;

    perform public.fn_registrar_auditoria(
        'citas', 'UPDATE', new.id_cita, 'Cita completada: historial y comisiones generados'
    );

    return null;
end;
$$;

create trigger trg_cita_completada_after_update
    after update on public.citas
    for each row
    when (new.estado = 'completado' and old.estado is distinct from 'completado')
    execute function public.fn_trg_cita_completada();

-- ---------------------------------------------------------------------------
-- trg_producto_utilizado_after_insert
-- Descuenta stock y deja el movimiento de salida.
-- La alerta de stock minimo la dispara trg_stock_after_update.
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_producto_utilizado()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    perform public.fn_actualizar_stock(new.id_producto, new.cantidad_usada);

    insert into public.movimientos_inventario (id_producto, tipo, cantidad, motivo)
    values (
        new.id_producto,
        'salida',
        new.cantidad_usada,
        format('Consumo en servicio (historial %s)', new.id_historial)
    );

    return null;
end;
$$;

create trigger trg_producto_utilizado_after_insert
    after insert on public.productos_utilizados
    for each row
    execute function public.fn_trg_producto_utilizado();

-- ---------------------------------------------------------------------------
-- trg_stock_after_update
-- Genera alerta cuando el stock cae al minimo. Evita duplicar alertas
-- mientras exista una sin resolver para el mismo producto.
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_stock_minimo()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if not exists (
        select 1
        from public.alertas_stock a
        where a.id_producto = new.id_producto
          and not a.resuelta
    ) then
        insert into public.alertas_stock (id_producto, stock_actual, stock_minimo)
        values (new.id_producto, new.stock_actual, new.stock_minimo);

        perform public.fn_registrar_auditoria(
            'productos', 'UPDATE', new.id_producto, 'Alerta de stock minimo generada'
        );
    end if;

    return null;
end;
$$;

create trigger trg_stock_after_update
    after update on public.productos
    for each row
    when (new.stock_actual <= new.stock_minimo)
    execute function public.fn_trg_stock_minimo();

-- ---------------------------------------------------------------------------
-- trg_pedido_recibido_after_update
-- Al marcar el pedido como 'recibido': suma stock, registra las entradas
-- y audita la operacion.
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_pedido_recibido()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    r_detalle record;
begin
    for r_detalle in
        select dp.id_producto, dp.cantidad
        from public.detalle_pedido dp
        where dp.id_pedido = new.id_pedido
    loop
        update public.productos
        set stock_actual = stock_actual + r_detalle.cantidad
        where id_producto = r_detalle.id_producto;

        insert into public.movimientos_inventario (id_producto, id_usuario, tipo, cantidad, motivo)
        values (
            r_detalle.id_producto,
            new.id_usuario,
            'entrada',
            r_detalle.cantidad,
            format('Recepcion de pedido %s', new.id_pedido)
        );
    end loop;

    -- Alertas resueltas: el reabastecimiento saco al producto del minimo
    update public.alertas_stock a
    set resuelta = true
    from public.productos p
    where a.id_producto = p.id_producto
      and not a.resuelta
      and p.stock_actual > p.stock_minimo;

    perform public.fn_registrar_auditoria(
        'pedidos', 'UPDATE', new.id_pedido, 'Pedido recibido: stock actualizado'
    );

    return null;
end;
$$;

create trigger trg_pedido_recibido_after_update
    after update on public.pedidos
    for each row
    when (new.estado = 'recibido' and old.estado is distinct from 'recibido')
    execute function public.fn_trg_pedido_recibido();
