-- ============================================================================
-- LOS SERVICIOS DE UN TURNO SE ATIENDEN SEGUIDOS, TAMBIEN AL VALIDAR CHOQUES
--
-- EL ERROR
--
-- Un turno con varios servicios los atiende uno detras del otro, en el orden
-- en que se cargaron: un corte de 30 minutos y un degradado de 40 a las 09:45
-- terminan a las 10:55. Asi lo calculan `fn_mis_turnos` (fecha_hora_fin), la
-- agenda del panel y la reserva del portal, que pide franjas por la duracion
-- TOTAL.
--
-- Pero `fn_verificar_conflicto_horario`, la regla que impide dos turnos del
-- mismo barbero a la vez (RN-015), medía CADA servicio desde el comienzo del
-- turno: el de 40 minutos ocupaba de 09:45 a 10:25, y el barbero quedaba
-- «libre» desde las 10:25 aunque siguiera atendiendo hasta las 10:55. La base
-- aceptaba otro turno con el a las 10:30. Lo encontro el calendario de
-- disponibilidad (7/10/2026), que usa la misma regla.
--
-- Del lado del turno nuevo pasaba lo mismo: `trg_detalle_cita_before_insert`
-- validaba el segundo servicio desde el comienzo del turno, no desde que
-- termina el primero.
--
-- LA CORRECCION
--
-- Cada linea de `detalle_cita` empieza cuando termina la anterior del mismo
-- turno (por `id_detalle`, el orden de carga) y dura su `duracion_min`. Las
-- tres funciones que miden ocupacion pasan a ubicarla asi:
--
--   - fn_verificar_conflicto_horario: los turnos existentes.
--   - fn_trg_detalle_cita_before_insert: la linea nueva, despues de las que
--     su turno ya tiene.
--   - fn_ocupacion_barberos: el calendario, una fila por linea; el portal y
--     la app juntan las que se tocan.
--
-- `fn_turnos_disponibles` no cambia: ya pide la duracion total desde el
-- comienzo de la franja, que es exactamente lo que ocupa un turno nuevo.
--
-- Solo afecta lo que se valida de aca en adelante. Un turno ya agendado que
-- hoy choque con otro no se toca: lo resuelve el mostrador.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los turnos existentes, con cada servicio en su lugar
-- ---------------------------------------------------------------------------

create or replace function public.fn_verificar_conflicto_horario(
    p_id_profesional  integer,
    p_fecha_hora      timestamptz,
    p_duracion_min    integer,
    p_id_cita_excluir integer default null
)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
    with lineas as (
        select d.id_profesional,
               c.fecha_hora
                 + make_interval(mins => coalesce(sum(d.duracion_min) over (
                       partition by d.id_cita
                       order by d.id_detalle
                       rows between unbounded preceding and 1 preceding
                   ), 0)::int)                                        as inicio,
               d.duracion_min
        from public.detalle_cita d
        join public.citas c on c.id_cita = d.id_cita
        where c.estado in ('pendiente', 'confirmado', 'en_proceso')
          and (p_id_cita_excluir is null or c.id_cita <> p_id_cita_excluir)
          -- Acota antes de la ventana: un turno de un dia lejano no puede
          -- chocar. Doce horas cubren el turno mas largo posible.
          and c.fecha_hora <  p_fecha_hora + make_interval(mins => p_duracion_min)
          and c.fecha_hora >  p_fecha_hora - interval '12 hours'
    )
    select exists (
        select 1
        from lineas l
        where l.id_profesional = p_id_profesional
          and tstzrange(l.inicio, l.inicio + make_interval(mins => l.duracion_min))
              && tstzrange(p_fecha_hora, p_fecha_hora + make_interval(mins => p_duracion_min))
    );
$fn$;

comment on function public.fn_verificar_conflicto_horario is
    'RN-015: true si el profesional ya tiene un servicio en ese intervalo. Los '
    'servicios de un turno se atienden seguidos, en el orden de carga: cada uno '
    'empieza cuando termina el anterior (corregido el 7/10/2026).';

-- ---------------------------------------------------------------------------
-- 2. La linea nueva, despues de las que su turno ya tiene
-- ---------------------------------------------------------------------------

create or replace function public.fn_trg_detalle_cita_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
    v_inicio timestamptz;
begin
    if not exists (select 1 from public.servicios s
                   where s.id_servicio = new.id_servicio and s.estado) then
        raise exception 'CU-003 A2: el servicio % esta desactivado', new.id_servicio;
    end if;

    if not exists (select 1 from public.profesionales p
                   where p.id_profesional = new.id_profesional and p.estado) then
        raise exception 'CU-004 A2: el profesional % esta desactivado', new.id_profesional;
    end if;

    -- Empieza cuando terminan las lineas que el turno ya tiene. En un insert
    -- de varias filas a la vez, cada una ve las anteriores: los disparadores
    -- de fila corren uno por uno.
    select c.fecha_hora + make_interval(mins => coalesce((
               select sum(d.duracion_min)
               from public.detalle_cita d
               where d.id_cita = new.id_cita
           ), 0)::int)
      into v_inicio
    from public.citas c
    where c.id_cita = new.id_cita;

    if public.fn_verificar_conflicto_horario(
           new.id_profesional, v_inicio, new.duracion_min, new.id_cita
       ) then
        raise exception
            'RN-015: el profesional % ya tiene un servicio agendado el %',
            new.id_profesional, v_inicio;
    end if;

    return new;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. El calendario de disponibilidad, una fila por servicio
-- ---------------------------------------------------------------------------

create or replace function public.fn_ocupacion_barberos(
    p_desde            date,
    p_hasta            date,
    p_ids_profesional  int[] default null
)
returns table (
    id_profesional  int,
    fecha           date,
    inicio          timestamptz,
    fin             timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
    v_zona text;
begin
    if auth.uid() is null then
        raise exception 'Hace falta una sesion para ver la disponibilidad.';
    end if;
    if p_desde is null or p_hasta is null or p_hasta < p_desde then
        raise exception 'El periodo no es valido.';
    end if;
    if p_hasta - p_desde > 62 then
        raise exception 'El periodo no puede superar los 62 dias.';
    end if;

    select coalesce(zona_horaria, 'America/Asuncion') into v_zona
    from public.configuracion_sistema
    where id_configuracion = 1;
    v_zona := coalesce(v_zona, 'America/Asuncion');

    return query
    with lineas as (
        select d.id_profesional,
               c.fecha_hora
                 + make_interval(mins => coalesce(sum(d.duracion_min) over (
                       partition by d.id_cita
                       order by d.id_detalle
                       rows between unbounded preceding and 1 preceding
                   ), 0)::int)                                        as inicio,
               d.duracion_min
        from public.citas c
        join public.detalle_cita d on d.id_cita = c.id_cita
        where c.estado in ('pendiente', 'confirmado', 'en_proceso')
          and c.fecha_hora >= (p_desde::timestamp at time zone v_zona)
          and c.fecha_hora <  ((p_hasta + 1)::timestamp at time zone v_zona)
    )
    select l.id_profesional,
           (l.inicio at time zone v_zona)::date,
           l.inicio,
           l.inicio + make_interval(mins => l.duracion_min)
    from lineas l
    join public.profesionales p on p.id_profesional = l.id_profesional
    where p.estado
      and not p.deleted
      and (p_ids_profesional is null or l.id_profesional = any (p_ids_profesional))
    order by l.inicio, l.id_profesional;
end;
$fn$;

-- `create or replace` conserva los permisos de las tres, pero se repiten los
-- de la ocupacion para que esta migracion se lea sola.
revoke execute on function public.fn_ocupacion_barberos(date, date, int[]) from public, anon;
grant execute on function public.fn_ocupacion_barberos(date, date, int[]) to authenticated;
