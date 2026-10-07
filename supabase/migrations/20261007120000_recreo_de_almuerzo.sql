-- ============================================================================
-- RECREO DE ALMUERZO Y HORARIO UNIFICADO 09:00-20:00
--
-- La barberia pasa a abrir a las 9 (antes las 8) y cerrar a las 20 todos los
-- dias que atiende, con un recreo fijo de 12:00 a 14:00 en el que no se
-- ofrece ningun turno. Se pidio expresamente que el recreo NO sea editable
-- desde el panel -asi que no se agrega una columna a `horarios_atencion`
-- para esto-, queda fijo adentro de la funcion.
--
-- El domingo (dia_semana = 0) sigue cerrado (`activo = false`): el `update`
-- de abajo solo toca los dias activos, para no reabrir uno que estaba
-- cerrado a proposito.
-- ============================================================================

update public.horarios_atencion
set hora_apertura = '09:00',
    hora_cierre   = '20:00'
where activo;

-- Misma firma que la version de `franjas_llenas` (23/9): un `create or
-- replace` alcanza, no hace falta `drop` ni volver a otorgar permisos.
create or replace function public.fn_turnos_disponibles(
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
    v_zona       text;
    v_dow        smallint;
    v_horario    public.horarios_atencion%rowtype;
    -- Recreo fijo. Si algun dia deja de ser 12-14 para todos los dias por
    -- igual, se vuelve una columna de `horarios_atencion`; mientras sea un
    -- solo horario para toda la semana, una constante aca alcanza.
    v_recreo_ini time := '12:00';
    v_recreo_fin time := '14:00';
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
      -- Recreo de almuerzo: ninguna franja que arranque entre las 12:00 y
      -- las 14:00 (el fin queda afuera: las 14:00 SI se ofrece).
      and not (
          (f.inicio at time zone v_zona)::time >= v_recreo_ini
          and (f.inicio at time zone v_zona)::time < v_recreo_fin
      )
    group by f.inicio
    having p_incluir_llenas or count(l.id_profesional) > 0
    order by f.inicio;
end;
$fn$;

comment on function public.fn_turnos_disponibles is
    'Franjas de un dia para un servicio de cierta duracion, con cuantos '
    'barberos quedan disponibles en cada una y quienes son. La capacidad '
    'concurrente sale del numero de barberos activos, no de un cupo fijo. '
    'Con p_incluir_llenas = true devuelve tambien las franjas sin lugar. '
    'Excluye el recreo fijo de 12:00 a 14:00.';
