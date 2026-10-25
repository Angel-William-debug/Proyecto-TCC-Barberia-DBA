-- =============================================================================
-- Errores que encontro el robot de QA en la web publicada (25/10/2026)
-- =============================================================================
--
-- 1. configuracion_sistema solo la leia el administrador (politica admin_total).
--    La factura y el comprobante en PDF toman de ahi el nombre, el RUC y la
--    direccion de la barberia, asi que a la recepcionista y al cliente el PDF
--    les fallaba con «Cannot read properties of null». Lo que hay en esa fila
--    es lo que figura en cualquier factura: cualquier usuario con sesion la
--    puede leer. Modificarla sigue siendo solo del administrador.
--
-- 2. fn_verificar_conflicto_horario contaba los turnos borrados (en la
--    papelera): un turno borrado seguia ocupando el horario del barbero.
--
-- 3. Se podia completar un turno de un dia que todavia no llego. Ahora solo
--    se completa un turno de hoy o de un dia anterior, en la hora de la
--    barberia. El historial cargado directamente como completado (INSERT) no
--    pasa por aca.
--
-- 4. Una fecha de nacimiento futura se guardaba sin aviso, desde el portal y
--    desde el panel.
-- =============================================================================

-- 1 ---------------------------------------------------------------------------
create policy autenticados_leen on public.configuracion_sistema
    for select to authenticated
    using (true);

-- 2 ---------------------------------------------------------------------------
create or replace function public.fn_verificar_conflicto_horario(
    p_id_profesional integer,
    p_fecha_hora timestamp with time zone,
    p_duracion_min integer,
    p_id_cita_excluir integer default null::integer)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
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
          and not c.deleted
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
$function$;

-- 3 ---------------------------------------------------------------------------
create or replace function public.fn_trg_cita_no_completar_futuro()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    v_zona text;
begin
    select coalesce(zona_horaria, 'America/Asuncion') into v_zona
    from public.configuracion_sistema
    where id_configuracion = 1;
    v_zona := coalesce(v_zona, 'America/Asuncion');

    if (new.fecha_hora at time zone v_zona)::date > (now() at time zone v_zona)::date then
        raise exception 'RN-018b: no se puede completar un turno de un dia que todavia no llego (%)',
            to_char(new.fecha_hora at time zone v_zona, 'DD/MM/YYYY');
    end if;

    return new;
end;
$function$;

create trigger trg_cita_no_completar_futuro
    before update of estado on public.citas
    for each row
    when (new.estado = 'completado' and old.estado is distinct from 'completado')
    execute function public.fn_trg_cita_no_completar_futuro();

-- 4 ---------------------------------------------------------------------------
create or replace function public.fn_trg_cliente_fecha_nacimiento()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
begin
    if new.fecha_nacimiento is not null and new.fecha_nacimiento > current_date then
        raise exception 'RN-008b: la fecha de nacimiento no puede ser futura';
    end if;
    return new;
end;
$function$;

create trigger trg_cliente_fecha_nacimiento
    before insert or update of fecha_nacimiento on public.clientes
    for each row
    execute function public.fn_trg_cliente_fecha_nacimiento();
