-- ============================================================================
-- OCUPACION DE LOS BARBEROS, para el calendario de disponibilidad del cliente
--
-- Pedido de la directora (7/10/2026): que el cliente pueda elegir uno o mas
-- barberos y ver en un calendario cuando estan ocupados y cuando libres,
-- antes de reservar. En la web y en la app.
--
-- POR QUE UNA FUNCION
--
-- RLS no le deja al cliente leer turnos ajenos (`citas` y `detalle_cita` solo
-- le muestran los suyos), y esta bien que asi sea: un turno dice quien viene,
-- a que hora y a hacerse que. Lo que el calendario necesita es mucho menos:
-- que barbero esta ocupado y de que hora a que hora. Esta funcion devuelve
-- exactamente eso y nada mas -ni cliente, ni servicio, ni estado-, igual que
-- `fn_turnos_disponibles` devuelve cuantos lugares quedan sin decir quien
-- ocupa los demas.
--
-- QUE ES «OCUPADO»
--
-- La misma definicion que `fn_verificar_conflicto_horario`, la que valida al
-- guardar: un turno pendiente, confirmado o en curso, con cada linea de
-- detalle medida desde el comienzo de la cita. Si las dos definiciones
-- difirieran, el calendario mostraria libre un horario que la base despues
-- rechaza. Un turno con varias lineas del mismo barbero es un solo bloque,
-- el de la mas larga.
--
-- Tope de 62 dias por consulta: un mes con sus semanas incompletas entra
-- holgado, y nadie puede pedir de una vez la agenda de un año.
-- ============================================================================

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
    select d.id_profesional,
           (c.fecha_hora at time zone v_zona)::date                          as fecha,
           c.fecha_hora                                                      as inicio,
           c.fecha_hora + make_interval(mins => max(d.duracion_min)::int)    as fin
    from public.citas c
    join public.detalle_cita d on d.id_cita = c.id_cita
    join public.profesionales p on p.id_profesional = d.id_profesional
    where c.estado in ('pendiente', 'confirmado', 'en_proceso')
      and p.estado
      and not p.deleted
      and c.fecha_hora >= (p_desde::timestamp at time zone v_zona)
      and c.fecha_hora <  ((p_hasta + 1)::timestamp at time zone v_zona)
      and (p_ids_profesional is null or d.id_profesional = any (p_ids_profesional))
    group by d.id_profesional, c.id_cita, c.fecha_hora
    order by c.fecha_hora, d.id_profesional;
end;
$fn$;

comment on function public.fn_ocupacion_barberos is
    'Bloques ocupados de cada barbero activo entre dos fechas (como mucho 62 '
    'dias), para el calendario de disponibilidad del portal y de la app. Solo '
    'barbero, inicio y fin: nunca quien es el cliente ni que servicio es.';

-- Solo con sesion: el calendario esta dentro del portal y de la app. El
-- catalogo y los horarios siguen siendo publicos; la ocupacion no.
revoke execute on function public.fn_ocupacion_barberos(date, date, int[]) from public, anon;
grant execute on function public.fn_ocupacion_barberos(date, date, int[]) to authenticated;
