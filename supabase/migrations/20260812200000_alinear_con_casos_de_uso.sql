-- ============================================================================
-- ALINEACION CON EL DOCUMENTO DE CASOS DE USO v3.0
--
-- Corrige las diferencias entre el esquema inicial (derivado del DER) y las
-- reglas de negocio del documento de casos de uso. Cada bloque indica el CU
-- o la RN que lo motiva.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. citas.estado - concordancia con el CU (CU-006, CU-007)
--    El DER usaba femenino ('cancelada', 'confirmada'); el CU usa masculino.
-- ---------------------------------------------------------------------------
alter table public.citas drop constraint citas_estado_check;

alter table public.citas add constraint citas_estado_check
    check (estado in ('pendiente', 'confirmado', 'en_proceso', 'completado', 'cancelado', 'no_asistio'));

-- ---------------------------------------------------------------------------
-- 2. pedidos.estado - RN-036: pedido -> recibido -> completado | cancelado
-- ---------------------------------------------------------------------------
alter table public.pedidos drop constraint pedidos_estado_check;

alter table public.pedidos alter column estado set default 'pedido';

alter table public.pedidos add constraint pedidos_estado_check
    check (estado in ('pedido', 'recibido', 'completado', 'cancelado'));

-- ---------------------------------------------------------------------------
-- 3. pagos_profesional.estado - CU-009 / RN-026: el estado final es 'liquidado'
-- ---------------------------------------------------------------------------
alter table public.pagos_profesional drop constraint pagos_profesional_estado_check;

alter table public.pagos_profesional add constraint pagos_profesional_estado_check
    check (estado in ('pendiente', 'liquidado', 'anulado'));

-- ---------------------------------------------------------------------------
-- 4. cobros_cliente.estado - RN-025 / CU-008 A1: cobros parciales
-- ---------------------------------------------------------------------------
alter table public.cobros_cliente drop constraint cobros_cliente_estado_check;

alter table public.cobros_cliente add constraint cobros_cliente_estado_check
    check (estado in ('pendiente', 'parcial', 'pagado', 'anulado'));

-- ---------------------------------------------------------------------------
-- 5. clientes - CU-002 paso 4 y RN-008: fecha de nacimiento y notas internas
-- ---------------------------------------------------------------------------
alter table public.clientes add column fecha_nacimiento date;
alter table public.clientes add column notas_internas text;

comment on column public.clientes.notas_internas is
    'RN-008: visible unicamente para Empleados y Administradores.';

-- ---------------------------------------------------------------------------
-- 6. notificaciones - RN-042 y CU-015 A2: tipos y reintentos
-- ---------------------------------------------------------------------------
alter table public.notificaciones add column intentos int not null default 0;

alter table public.notificaciones add constraint notificaciones_tipo_check
    check (tipo is null or tipo in ('confirmacion', 'recordatorio'));

alter table public.notificaciones add constraint notificaciones_estado_envio_check
    check (estado_envio in ('pendiente', 'enviado', 'fallido', 'sin_email'));

comment on column public.notificaciones.intentos is
    'CU-015 A2: reintento automatico hasta 3 veces.';

-- ---------------------------------------------------------------------------
-- 7. CU-020 - Configuracion del Sistema (no existia en el DER)
-- ---------------------------------------------------------------------------
create table public.configuracion_sistema (
    id_configuracion           int primary key default 1 check (id_configuracion = 1),
    nombre_barberia            varchar(150) not null,
    ruc                        varchar(20),
    direccion                  text,
    telefono                   varchar(20),
    email                      varchar(150),
    logo_url                   varchar(255),
    moneda                     varchar(10) not null default 'PYG',
    zona_horaria               varchar(50) not null default 'America/Asuncion',
    minutos_antes_recordatorio int not null default 1440 check (minutos_antes_recordatorio > 0),
    max_reintentos_notif       int not null default 3 check (max_reintentos_notif >= 0),
    updated_at                 timestamptz not null default now()
);

comment on table public.configuracion_sistema is
    'CU-020: parametros generales. Fila unica (id_configuracion = 1).';
comment on column public.configuracion_sistema.minutos_antes_recordatorio is
    'RN-042: recordatorio 24 horas antes = 1440 minutos.';

create table public.horarios_atencion (
    id_horario    int generated always as identity primary key,
    dia_semana    smallint not null check (dia_semana between 0 and 6),
    hora_apertura time not null,
    hora_cierre   time not null,
    activo        boolean not null default true,
    unique (dia_semana),
    check (hora_cierre > hora_apertura)
);

comment on table public.horarios_atencion is
    'CU-020: horario de atencion por dia. dia_semana: 0 = domingo ... 6 = sabado.';

-- ---------------------------------------------------------------------------
-- 8. Funciones y vistas que referenciaban los estados anteriores
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
          and c.estado in ('pendiente', 'confirmado', 'en_proceso')
          and (p_id_cita_excluir is null or c.id_cita <> p_id_cita_excluir)
          and tstzrange(c.fecha_hora, c.fecha_hora + make_interval(mins => d.duracion_min))
              && tstzrange(p_fecha_hora, p_fecha_hora + make_interval(mins => p_duracion_min))
    );
$$;

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
            where cc.estado in ('pagado', 'parcial')
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
                       else round(100.0 * count(*) filter (where c.estado = 'cancelado') / count(*), 2)
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

create or replace view public.v_citas_activas
with (security_invoker = true) as
select c.id_cita,
       c.fecha_hora,
       c.estado,
       cl.nombre as nombre_cliente,
       s.nombre  as nombre_servicio,
       p.nombre  as nombre_profesional,
       d.duracion_min
from public.citas c
join public.clientes cl on cl.id_cliente = c.id_cliente
join public.detalle_cita d on d.id_cita = c.id_cita
join public.servicios s on s.id_servicio = d.id_servicio
join public.profesionales p on p.id_profesional = d.id_profesional
where c.estado in ('pendiente', 'confirmado', 'en_proceso');

create or replace view public.v_ingresos_por_periodo
with (security_invoker = true) as
select extract(year from cc.fecha_pago)::int  as anio,
       extract(month from cc.fecha_pago)::int as mes,
       sum(cc.monto)                          as total_ingresos,
       count(*)                               as cantidad_servicios,
       round(avg(cc.monto), 2)                as ticket_promedio
from public.cobros_cliente cc
where cc.estado in ('pagado', 'parcial')
  and cc.fecha_pago is not null
group by 1, 2;

-- ---------------------------------------------------------------------------
-- 9. Reglas de negocio que ahora hace cumplir la base
-- ---------------------------------------------------------------------------

-- RN-018: no se puede modificar ni cancelar una cita completada o cancelada.
-- Se permite el recalculo de total y updated_at, que no son cambios de negocio.
create or replace function public.fn_trg_cita_inmutable()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if old.estado in ('completado', 'cancelado')
       and (new.estado       is distinct from old.estado
         or new.fecha_hora   is distinct from old.fecha_hora
         or new.id_cliente   is distinct from old.id_cliente) then
        raise exception
            'RN-018: no se puede modificar una cita con estado %', old.estado;
    end if;

    return new;
end;
$$;

create trigger trg_cita_inmutable
    before update on public.citas
    for each row
    execute function public.fn_trg_cita_inmutable();

-- RN-024: solo se registra cobro para citas completadas.
create or replace function public.fn_trg_cobro_cita_completada()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_estado varchar(50);
begin
    select c.estado into v_estado
    from public.citas c
    where c.id_cita = new.id_cita;

    if v_estado is distinct from 'completado' then
        raise exception
            'RN-024: solo se puede cobrar una cita completada (estado actual: %)', v_estado;
    end if;

    return new;
end;
$$;

create trigger trg_cobro_cita_completada
    before insert on public.cobros_cliente
    for each row
    execute function public.fn_trg_cobro_cita_completada();

-- RN-027: un pago liquidado no puede modificarse ni revertirse.
create or replace function public.fn_trg_pago_prof_inmutable()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if old.estado = 'liquidado' then
        raise exception 'RN-027: un pago liquidado no puede modificarse ni revertirse';
    end if;

    return new;
end;
$$;

create trigger trg_pago_prof_inmutable
    before update on public.pagos_profesional
    for each row
    execute function public.fn_trg_pago_prof_inmutable();

-- RN-028 / RN-038: solo se paga al proveedor una orden recibida.
create or replace function public.fn_trg_pago_prov_pedido_recibido()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_estado varchar(50);
begin
    select p.estado into v_estado
    from public.pedidos p
    where p.id_pedido = new.id_pedido;

    if v_estado not in ('recibido', 'completado') then
        raise exception
            'RN-028: solo se puede pagar una orden recibida (estado actual: %)', v_estado;
    end if;

    return new;
end;
$$;

create trigger trg_pago_prov_pedido_recibido
    before insert on public.pagos_proveedor
    for each row
    execute function public.fn_trg_pago_prov_pedido_recibido();

-- ---------------------------------------------------------------------------
-- 10. RLS para las tablas nuevas
-- ---------------------------------------------------------------------------
alter table public.configuracion_sistema enable row level security;
alter table public.horarios_atencion enable row level security;

create policy "acceso_autenticado" on public.configuracion_sistema
    for all to authenticated using (true) with check (true);

create policy "acceso_autenticado" on public.horarios_atencion
    for all to authenticated using (true) with check (true);

-- ---------------------------------------------------------------------------
-- 11. Datos iniciales de configuracion
-- ---------------------------------------------------------------------------
insert into public.configuracion_sistema (id_configuracion, nombre_barberia, zona_horaria)
values (1, 'Barberia TCC', 'America/Asuncion')
on conflict (id_configuracion) do nothing;

insert into public.horarios_atencion (dia_semana, hora_apertura, hora_cierre, activo) values
    (0, '09:00', '13:00', false),
    (1, '08:00', '19:00', true),
    (2, '08:00', '19:00', true),
    (3, '08:00', '19:00', true),
    (4, '08:00', '19:00', true),
    (5, '08:00', '20:00', true),
    (6, '08:00', '18:00', true)
on conflict (dia_semana) do nothing;
