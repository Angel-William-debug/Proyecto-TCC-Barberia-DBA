-- ============================================================================
-- FRANJAS LLENAS
--
-- `fn_turnos_disponibles` descartaba las franjas sin ningun barbero libre
-- (`having count(...) > 0`). Para el portal eso era un problema: una hora
-- llena directamente no aparecia, y el cliente no podia distinguir "esta
-- llena" de "a esa hora no se atiende".
--
-- La reserva del portal pasa a mostrar TODAS las franjas del dia con su
-- estado -cuantos lugares quedan, o «Lleno»- y cada barbero ocupado como tal.
-- Para eso la funcion tiene que devolver tambien las franjas con cero barberos
-- libres. Los ocupados no hace falta devolverlos: son los barberos activos que
-- no estan en `ids_barberos`, y la lista de barberos ya es publica.
--
-- POR QUE UN PARAMETRO Y NO CAMBIAR EL RESULTADO
--
-- `p_incluir_llenas` vale `false` por defecto, asi que quien llamaba a la
-- funcion sin el sigue recibiendo exactamente lo mismo. Como cambia la firma,
-- hay que borrar la version anterior: `create or replace` con un parametro de
-- mas crearia una segunda funcion con el mismo nombre, y PostgREST no sabria
-- a cual llamar.
--
-- Las franjas que ya pasaron se siguen omitiendo: no son "llenas", son
-- imposibles, y `trg_cita_validar` las rechazaria igual.
-- ============================================================================

drop function if exists public.fn_turnos_disponibles(date, int, int, int);

create function public.fn_turnos_disponibles(
    p_fecha           date,
    p_duracion_min    int,
    p_id_profesional  int     default null,
    p_paso_min        int     default 15,
    p_incluir_llenas  boolean default false
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
    having p_incluir_llenas or count(l.id_profesional) > 0
    order by f.inicio;
end;
$fn$;

comment on function public.fn_turnos_disponibles is
    'Franjas de un dia para un servicio de cierta duracion, con cuantos '
    'barberos quedan disponibles en cada una y quienes son. La capacidad '
    'concurrente sale del numero de barberos activos, no de un cupo fijo. '
    'Con p_incluir_llenas = true devuelve tambien las franjas sin lugar.';

-- Mismos permisos que la version anterior: el `drop` se los llevo.
grant execute on function public.fn_turnos_disponibles(date, int, int, int, boolean)
    to anon, authenticated;
