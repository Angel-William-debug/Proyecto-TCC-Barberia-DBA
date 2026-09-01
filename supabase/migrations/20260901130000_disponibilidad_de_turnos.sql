-- ============================================================================
-- DISPONIBILIDAD DE TURNOS
--
-- Hasta ahora la agenda solo sabia RECHAZAR: `fn_verificar_conflicto_horario`
-- responde "ese barbero ya esta ocupado" cuando alguien intenta guardar. Sirve
-- para el mostrador, donde la recepcionista ya tiene la agenda a la vista y
-- propone la hora ella misma.
--
-- El portal del cliente necesita lo contrario: que el sistema PROPONGA los
-- huecos libres. Nadie va a adivinar horarios hasta que uno sea aceptado.
--
-- LA CAPACIDAD CONCURRENTE NO ES UN PARAMETRO
--
-- El pedido de "hasta 4 turnos en paralelo en una misma hora" no se configura:
-- se deduce. En una franja caben tantos turnos simultaneos como barberos
-- activos queden libres en ella. Con cuatro barberos hay cuatro lugares; si
-- uno esta de licencia -`estado = false`- hay tres, sin tocar ninguna
-- configuracion. Por eso la funcion devuelve la CANTIDAD de barberos libres
-- por franja y quienes son, en vez de un cupo fijo.
-- ============================================================================

create or replace function public.fn_turnos_disponibles(
    p_fecha           date,
    p_duracion_min    int,
    p_id_profesional  int default null,
    p_paso_min        int default 15
)
returns table (
    inicio                timestamptz,
    hora_local            time,
    barberos_disponibles  int,
    ids_barberos          int[]
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
    v_zona    text;
    v_dow     smallint;
    v_horario public.horarios_atencion%rowtype;
begin
    if p_duracion_min is null or p_duracion_min <= 0 then
        raise exception 'La duracion del servicio debe ser mayor a cero.';
    end if;

    if p_paso_min is null or p_paso_min <= 0 then
        raise exception 'El paso entre franjas debe ser mayor a cero.';
    end if;

    select coalesce(zona_horaria, 'America/Asuncion') into v_zona
    from public.configuracion_sistema
    where id_configuracion = 1;

    v_zona := coalesce(v_zona, 'America/Asuncion');

    -- El dia de la semana se calcula sobre la fecha local, no sobre UTC: cerca
    -- de la medianoche las dos no coinciden y la barberia terminaria abriendo
    -- el dia equivocado.
    v_dow := extract(dow from p_fecha)::smallint;

    select * into v_horario
    from public.horarios_atencion
    where dia_semana = v_dow;

    -- Dia cerrado: cero filas, no una excepcion. Que la barberia no atienda un
    -- domingo es una respuesta valida a "que turnos hay", no un error.
    if v_horario.id_horario is null or not v_horario.activo then
        return;
    end if;

    return query
    with franjas as (
        -- Desde la apertura hasta el ultimo comienzo posible: un servicio de
        -- 45 minutos no puede empezar 30 minutos antes de cerrar.
        select generate_series(
                   (p_fecha + v_horario.hora_apertura) at time zone v_zona,
                   (p_fecha + v_horario.hora_cierre) at time zone v_zona
                       - make_interval(mins => p_duracion_min),
                   make_interval(mins => p_paso_min)
               ) as inicio
    ),
    barberos as (
        select p.id_profesional
        from public.profesionales p
        where p.estado
          and not p.deleted
          and (p_id_profesional is null or p.id_profesional = p_id_profesional)
    ),
    libres as (
        select f.inicio,
               b.id_profesional
        from franjas f
        cross join barberos b
        where not public.fn_verificar_conflicto_horario(
                  b.id_profesional, f.inicio, p_duracion_min, null
              )
    )
    select f.inicio,
           (f.inicio at time zone v_zona)::time            as hora_local,
           count(l.id_profesional)::int                    as barberos_disponibles,
           coalesce(
               array_agg(l.id_profesional order by l.id_profesional)
                   filter (where l.id_profesional is not null),
               '{}'::int[]
           )                                               as ids_barberos
    from franjas f
    left join libres l on l.inicio = f.inicio
    -- Una franja que ya paso no se ofrece. `trg_cita_validar` la rechazaria
    -- igual, pero mostrarla y despues rechazarla es un mal formulario.
    where f.inicio > now()
    group by f.inicio
    having count(l.id_profesional) > 0
    order by f.inicio;
end;
$fn$;

comment on function public.fn_turnos_disponibles is
    'Franjas libres de un dia para un servicio de cierta duracion, con cuantos '
    'barberos quedan disponibles en cada una y quienes son. La capacidad '
    'concurrente sale del numero de barberos activos, no de un cupo fijo.';

-- Se ejecuta con los permisos de su dueno porque tiene que leer `citas` y
-- `detalle_cita` para saber que esta ocupado, y el cliente no puede leer los
-- turnos de los demas. Lo unico que devuelve son horas libres y nombres de
-- barberos disponibles: nada sobre quien tiene turno ni para que.
--
-- `anon` incluido a proposito: el portal muestra la disponibilidad antes de
-- pedir que alguien se registre.
grant execute on function public.fn_turnos_disponibles(date, int, int, int)
    to anon, authenticated;
