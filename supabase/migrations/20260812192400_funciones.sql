-- ============================================================================
-- FUNCIONES DEL SISTEMA
-- ============================================================================

-- ---------------------------------------------------------------------------
-- fn_calcular_total_cita: suma los subtotales de detalle_cita
-- ---------------------------------------------------------------------------
create or replace function public.fn_calcular_total_cita(p_id_cita int)
returns numeric
language sql
stable
set search_path = public
as $$
    select coalesce(sum(d.subtotal), 0)
    from public.detalle_cita d
    where d.id_cita = p_id_cita;
$$;

comment on function public.fn_calcular_total_cita is
    'Total de una cita = suma de subtotales de sus detalles.';

-- ---------------------------------------------------------------------------
-- fn_calcular_comision: costo_cobrado x (porcentaje_com / 100)
-- ---------------------------------------------------------------------------
create or replace function public.fn_calcular_comision(p_id_historial int)
returns numeric
language sql
stable
set search_path = public
as $$
    select round(coalesce(h.costo_cobrado * p.porcentaje_com / 100.0, 0), 2)
    from public.historial_servicio h
    join public.profesionales p on p.id_profesional = h.id_profesional
    where h.id_historial = p_id_historial;
$$;

comment on function public.fn_calcular_comision is
    'Comision del profesional sobre un servicio realizado.';

-- ---------------------------------------------------------------------------
-- fn_verificar_conflicto_horario: TRUE si el profesional ya esta ocupado
--
-- p_id_cita_excluir permite ignorar los detalles de la propia cita, de modo
-- que una cita con varios servicios del mismo profesional no choque consigo
-- misma. (RN-015)
-- ---------------------------------------------------------------------------
create or replace function public.fn_verificar_conflicto_horario(
    p_id_profesional  int,
    p_fecha_hora      timestamptz,
    p_duracion_min    int,
    p_id_cita_excluir int default null
)
returns boolean
language sql
stable
set search_path = public
as $$
    select exists (
        select 1
        from public.detalle_cita d
        join public.citas c on c.id_cita = d.id_cita
        where d.id_profesional = p_id_profesional
          and c.estado in ('pendiente', 'confirmada', 'en_proceso')
          and (p_id_cita_excluir is null or c.id_cita <> p_id_cita_excluir)
          and tstzrange(c.fecha_hora, c.fecha_hora + make_interval(mins => d.duracion_min))
              && tstzrange(p_fecha_hora, p_fecha_hora + make_interval(mins => p_duracion_min))
    );
$$;

comment on function public.fn_verificar_conflicto_horario is
    'TRUE = el profesional ya tiene un servicio solapado en citas activas.';

-- ---------------------------------------------------------------------------
-- fn_actualizar_stock: descuenta stock del producto
-- ---------------------------------------------------------------------------
create or replace function public.fn_actualizar_stock(
    p_id_producto int,
    p_cantidad    numeric
)
returns void
language plpgsql
set search_path = public
as $$
begin
    update public.productos
    set stock_actual = stock_actual - p_cantidad
    where id_producto = p_id_producto;

    if not found then
        raise exception 'Producto % inexistente', p_id_producto;
    end if;
end;
$$;

comment on function public.fn_actualizar_stock is
    'Descuenta stock. El CHECK stock_actual >= 0 impide dejarlo en negativo.';

-- ---------------------------------------------------------------------------
-- fn_registrar_auditoria: deja rastro de un cambio
-- ---------------------------------------------------------------------------
create or replace function public.fn_registrar_auditoria(
    p_tabla       varchar,
    p_accion      varchar,
    p_registro_id int,
    p_detalle     text default null
)
returns void
language plpgsql
set search_path = public
as $$
declare
    v_id_usuario int;
begin
    -- Si la operacion viene de un usuario autenticado, se lo vincula
    select u.id_usuario
    into v_id_usuario
    from public.usuarios u
    where u.auth_uid = auth.uid();

    insert into public.auditoria (id_usuario, tabla_afectada, accion, registro_id, detalle)
    values (v_id_usuario, p_tabla, p_accion, p_registro_id, p_detalle);
end;
$$;

comment on function public.fn_registrar_auditoria is
    'Registra un cambio en la tabla auditoria, vinculando al usuario autenticado si existe.';

-- ---------------------------------------------------------------------------
-- fn_generar_resumen_kpis: indicadores del periodo, en JSON
-- ---------------------------------------------------------------------------
create or replace function public.fn_generar_resumen_kpis(
    p_desde date,
    p_hasta date
)
returns json
language sql
stable
set search_path = public
as $$
    select json_build_object(
        'periodo_desde', p_desde,
        'periodo_hasta', p_hasta,
        'total_ingresos', (
            select coalesce(sum(cc.monto), 0)
            from public.cobros_cliente cc
            where cc.estado = 'pagado'
              and cc.fecha_pago::date between p_desde and p_hasta
        ),
        'clientes_atendidos', (
            select count(distinct h.id_cliente)
            from public.historial_servicio h
            where h.fecha_realizacion between p_desde and p_hasta
        ),
        'servicios_completados', (
            select count(*)
            from public.historial_servicio h
            where h.fecha_realizacion between p_desde and p_hasta
        ),
        'tasa_cancelacion', (
            select case
                       when count(*) = 0 then 0
                       else round(100.0 * count(*) filter (where c.estado = 'cancelada') / count(*), 2)
                   end
            from public.citas c
            where c.fecha_hora::date between p_desde and p_hasta
        ),
        'stock_critico_count', (
            select count(*)
            from public.productos p
            where p.estado
              and p.stock_actual <= p.stock_minimo
        ),
        'comisiones_pendientes', (
            select coalesce(sum(pp.monto), 0)
            from public.pagos_profesional pp
            where pp.estado = 'pendiente'
        )
    );
$$;

comment on function public.fn_generar_resumen_kpis is
    'KPIs del periodo para el dashboard: ingresos, clientes, servicios, cancelaciones, stock y comisiones.';
