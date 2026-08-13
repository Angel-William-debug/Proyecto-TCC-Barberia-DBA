-- ============================================================================
-- VALIDACIONES DE INTEGRIDAD Y REGLAS DE NEGOCIO
--
-- Completa las validaciones que el DER y el documento de casos de uso exigen
-- pero que no estaban implementadas en la base.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. STOCK: excepcion controlada (CU-007 A1, CU-011 A1) vs RN-031
--
--    El CHECK "stock_actual >= 0" impedia el flujo alternativo del CU, que
--    permite completar un servicio con stock insuficiente si el usuario
--    confirma la excepcion. Se reemplaza por un control que distingue:
--      - consumo real con excepcion confirmada  -> permitido, queda negativo
--      - cualquier otro camino (ajuste manual)  -> bloqueado (RN-031)
-- ---------------------------------------------------------------------------
alter table public.productos_utilizados
    add column excepcion_stock boolean not null default false;

comment on column public.productos_utilizados.excepcion_stock is
    'CU-007 A1 / CU-011 A1: el usuario confirmo consumir por encima del stock disponible.';

alter table public.productos drop constraint productos_stock_actual_check;

alter table public.productos add constraint productos_stock_min_max_check
    check (stock_maximo is null or stock_maximo >= stock_minimo);

create or replace function public.fn_trg_stock_no_negativo()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if new.stock_actual < 0
       and coalesce(current_setting('app.permitir_stock_negativo', true), 'off') <> 'on' then
        raise exception
            'RN-031: el stock de "%" no puede quedar negativo (resultado: %)',
            new.nombre, new.stock_actual;
    end if;

    return new;
end;
$$;

create trigger trg_stock_no_negativo
    before update on public.productos
    for each row
    execute function public.fn_trg_stock_no_negativo();

-- La firma cambia: se elimina la version de 2 argumentos para no dejar
-- una sobrecarga ambigua.
drop function if exists public.fn_actualizar_stock(int, numeric);

create function public.fn_actualizar_stock(
    p_id_producto       int,
    p_cantidad          numeric,
    p_permitir_negativo boolean default false
)
returns void
language plpgsql
set search_path = public
as $$
begin
    if p_permitir_negativo then
        perform set_config('app.permitir_stock_negativo', 'on', true);
    end if;

    update public.productos
    set stock_actual = stock_actual - p_cantidad
    where id_producto = p_id_producto;

    if not found then
        raise exception 'Producto % inexistente', p_id_producto;
    end if;

    perform set_config('app.permitir_stock_negativo', 'off', true);
end;
$$;

comment on function public.fn_actualizar_stock(int, numeric, boolean) is
    'Descuenta stock. Con p_permitir_negativo = true habilita la excepcion del CU-007 A1.';

-- El consumo pasa la confirmacion de excepcion al descuento de stock
create or replace function public.fn_trg_producto_utilizado()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    perform public.fn_actualizar_stock(new.id_producto, new.cantidad_usada, new.excepcion_stock);

    insert into public.movimientos_inventario (id_producto, tipo, cantidad, motivo)
    values (
        new.id_producto,
        'salida',
        new.cantidad_usada,
        format('Consumo en servicio (historial %s)%s',
               new.id_historial,
               case when new.excepcion_stock then ' - EXCEPCION DE STOCK' else '' end)
    );

    return null;
end;
$$;

-- Al recuperarse el stock por encima del minimo, la alerta se cierra sola
create or replace function public.fn_trg_stock_recuperado()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    update public.alertas_stock
    set resuelta = true
    where id_producto = new.id_producto
      and not resuelta;

    return null;
end;
$$;

create trigger trg_stock_recuperado
    after update on public.productos
    for each row
    when (new.stock_actual > new.stock_minimo)
    execute function public.fn_trg_stock_recuperado();

-- ---------------------------------------------------------------------------
-- 2. AGENDA: solo se agenda sobre entidades activas y dentro del horario
--    CU-002 A3, CU-003 A2, CU-004 A2, CU-020
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_cita_validar()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_cliente_activo boolean;
    v_zona           text;
    v_local          timestamp;
    v_dow            smallint;
    v_horario        public.horarios_atencion%rowtype;
begin
    select estado into v_cliente_activo
    from public.clientes
    where id_cliente = new.id_cliente;

    if not coalesce(v_cliente_activo, false) then
        raise exception 'CU-002 A3: el cliente % esta desactivado y no puede ser agendado',
            new.id_cliente;
    end if;

    -- Las validaciones de tiempo aplican a citas vigentes; el historial se carga
    -- directamente en estado completado y no las atraviesa.
    if new.estado in ('pendiente', 'confirmado') then

        if tg_op = 'INSERT' and new.fecha_hora < now() then
            raise exception 'No se puede agendar una cita en el pasado (%)', new.fecha_hora;
        end if;

        select coalesce(zona_horaria, 'America/Asuncion') into v_zona
        from public.configuracion_sistema
        where id_configuracion = 1;

        v_local := new.fecha_hora at time zone coalesce(v_zona, 'America/Asuncion');
        v_dow   := extract(dow from v_local)::smallint;

        select * into v_horario
        from public.horarios_atencion
        where dia_semana = v_dow;

        if v_horario.id_horario is null or not v_horario.activo then
            raise exception 'CU-020: la barberia no atiende los dias % (0=domingo)', v_dow;
        end if;

        if v_local::time < v_horario.hora_apertura or v_local::time >= v_horario.hora_cierre then
            raise exception 'CU-020: la hora % queda fuera del horario de atencion (% a %)',
                v_local::time, v_horario.hora_apertura, v_horario.hora_cierre;
        end if;
    end if;

    return new;
end;
$$;

create trigger trg_cita_validar
    before insert or update on public.citas
    for each row
    execute function public.fn_trg_cita_validar();

-- Servicio y profesional activos, ademas del conflicto de horario (RN-015)
create or replace function public.fn_trg_detalle_cita_before_insert()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_fecha_hora timestamptz;
begin
    if not exists (select 1 from public.servicios s
                   where s.id_servicio = new.id_servicio and s.estado) then
        raise exception 'CU-003 A2: el servicio % esta desactivado', new.id_servicio;
    end if;

    if not exists (select 1 from public.profesionales p
                   where p.id_profesional = new.id_profesional and p.estado) then
        raise exception 'CU-004 A2: el profesional % esta desactivado', new.id_profesional;
    end if;

    select c.fecha_hora into v_fecha_hora
    from public.citas c
    where c.id_cita = new.id_cita;

    if public.fn_verificar_conflicto_horario(
           new.id_profesional, v_fecha_hora, new.duracion_min, new.id_cita
       ) then
        raise exception
            'RN-015: el profesional % ya tiene un servicio agendado el %',
            new.id_profesional, v_fecha_hora;
    end if;

    return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. COBROS: los pagos parciales no pueden superar el total (RN-025)
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_cobro_no_excede()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_total   numeric;
    v_cobrado numeric;
begin
    select c.total into v_total
    from public.citas c
    where c.id_cita = new.id_cita;

    select coalesce(sum(cc.monto), 0) into v_cobrado
    from public.cobros_cliente cc
    where cc.id_cita = new.id_cita
      and cc.estado in ('pagado', 'parcial');

    if v_cobrado > v_total then
        raise exception
            'RN-025: los cobros de la cita % suman % y superan el total de %',
            new.id_cita, v_cobrado, v_total;
    end if;

    return null;
end;
$$;

create trigger trg_cobro_no_excede
    after insert or update on public.cobros_cliente
    for each row
    execute function public.fn_trg_cobro_no_excede();

-- ---------------------------------------------------------------------------
-- 4. COMPRAS: subtotal y total calculados por el sistema (CU-017 paso 4)
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_detalle_pedido_subtotal()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    new.subtotal := round(new.cantidad * new.precio_unit, 2);
    return new;
end;
$$;

create trigger trg_detalle_pedido_subtotal
    before insert or update on public.detalle_pedido
    for each row
    execute function public.fn_trg_detalle_pedido_subtotal();

create or replace function public.fn_trg_pedido_total()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_id_pedido int := coalesce(new.id_pedido, old.id_pedido);
begin
    update public.pedidos
    set total = (select coalesce(sum(dp.subtotal), 0)
                 from public.detalle_pedido dp
                 where dp.id_pedido = v_id_pedido)
    where id_pedido = v_id_pedido;

    return null;
end;
$$;

create trigger trg_pedido_total
    after insert or update or delete on public.detalle_pedido
    for each row
    execute function public.fn_trg_pedido_total();

-- Los pagos parciales al proveedor tampoco superan el total (CU-018 A1)
create or replace function public.fn_trg_pago_prov_no_excede()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_total  numeric;
    v_pagado numeric;
begin
    select p.total into v_total
    from public.pedidos p
    where p.id_pedido = new.id_pedido;

    select coalesce(sum(pp.monto), 0) into v_pagado
    from public.pagos_proveedor pp
    where pp.id_pedido = new.id_pedido
      and pp.estado in ('pagado', 'pendiente');

    if v_pagado > v_total then
        raise exception
            'CU-018 A1: los pagos de la orden % suman % y superan el total de %',
            new.id_pedido, v_pagado, v_total;
    end if;

    return null;
end;
$$;

create trigger trg_pago_prov_no_excede
    after insert or update on public.pagos_proveedor
    for each row
    execute function public.fn_trg_pago_prov_no_excede();

-- ---------------------------------------------------------------------------
-- 5. RECOMENDACIONES: minimo 3 servicios en historial (RN-009)
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_recomendacion_min_historial()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_servicios int;
begin
    select count(*) into v_servicios
    from public.historial_servicio h
    where h.id_cliente = new.id_cliente;

    if v_servicios < 3 then
        raise exception
            'RN-009: se requieren minimo 3 servicios en historial para recomendar (el cliente tiene %)',
            v_servicios;
    end if;

    return new;
end;
$$;

create trigger trg_recomendacion_min_historial
    before insert on public.recomendaciones_ml
    for each row
    execute function public.fn_trg_recomendacion_min_historial();

-- ---------------------------------------------------------------------------
-- 6. Restricciones de datos que faltaban
-- ---------------------------------------------------------------------------

-- RN-005: nombre y telefono son obligatorios para el cliente
alter table public.clientes alter column telefono set not null;

-- CU-003 A1: no se repite el nombre de servicio dentro de una categoria
alter table public.servicios add constraint servicios_categoria_nombre_key
    unique (id_categoria, nombre);

-- CU-015 A2 / RN-042: hasta 3 reintentos de envio
alter table public.notificaciones add constraint notificaciones_intentos_check
    check (intentos between 0 and 3);

-- Formato de correo electronico
alter table public.usuarios add constraint usuarios_email_formato_check
    check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

alter table public.clientes add constraint clientes_email_formato_check
    check (email is null or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

alter table public.proveedores add constraint proveedores_email_formato_check
    check (email is null or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');
