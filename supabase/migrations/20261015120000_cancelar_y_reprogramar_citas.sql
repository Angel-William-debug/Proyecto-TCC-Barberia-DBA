-- ============================================================================
-- CANCELAR CON MOTIVO Y REPROGRAMAR UN TURNO DESDE EL PANEL (CU-006)
--
-- El panel solo podia agendar y completar turnos: no los podia cancelar ni
-- cambiar de hora (vistas 44, 45 y 46 del anexo). Esta migracion prepara la
-- base para las dos cosas.
--
-- 1. EL MOTIVO DE LA CANCELACION (CU-006 4b). Columna nueva en `citas`. La
--    pide el panel; el cliente que cancela su propio turno desde el portal o
--    la app no la completa (ya sabe por que).
--
-- 2. REPROGRAMAR SIN PISAR OTRO TURNO (RN-015). El choque de horarios se
--    validaba solo al cargar los servicios (`trg_detalle_cita_before_insert`).
--    Cambiar despues la `fecha_hora` de la cita no pasaba por ningun control:
--    se podia mover un turno encima de otro del mismo barbero, o al pasado.
--    `trg_cita_reprogramar` lo controla cuando cambia la hora de un turno
--    vigente, con los servicios uno detras del otro, como en la migracion
--    20261007180000.
-- ============================================================================

alter table public.citas
    add column if not exists motivo_cancelacion varchar(300);

comment on column public.citas.motivo_cancelacion is
    'Por que se cancelo el turno (CU-006 4b). Lo completa el panel al cancelar.';

create or replace function public.fn_trg_cita_reprogramar()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
    v_linea record;
begin
    if new.fecha_hora is not distinct from old.fecha_hora
       or new.estado not in ('pendiente', 'confirmado') then
        return new;
    end if;

    if new.fecha_hora < now() then
        raise exception 'No se puede mover un turno al pasado (%)', new.fecha_hora;
    end if;

    -- Cada servicio en su lugar: empieza cuando termina el anterior.
    for v_linea in
        select d.id_profesional,
               new.fecha_hora + make_interval(mins => coalesce(sum(d.duracion_min) over (
                   order by d.id_detalle
                   rows between unbounded preceding and 1 preceding
               ), 0)::int) as inicio,
               d.duracion_min
        from public.detalle_cita d
        where d.id_cita = new.id_cita
    loop
        if public.fn_verificar_conflicto_horario(
               v_linea.id_profesional, v_linea.inicio, v_linea.duracion_min, new.id_cita
           ) then
            raise exception
                'RN-015: el profesional % ya tiene un servicio agendado el %',
                v_linea.id_profesional, v_linea.inicio;
        end if;
    end loop;

    return new;
end;
$fn$;

create trigger trg_cita_reprogramar
    before update of fecha_hora on public.citas
    for each row execute function public.fn_trg_cita_reprogramar();
