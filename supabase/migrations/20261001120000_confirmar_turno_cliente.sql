-- ============================================================================
-- EL CLIENTE CONFIRMA SU TURNO (fase 3a de la app movil)
--
-- La app del cliente avisa «tu turno se acerca» con dos botones, Confirmar y
-- Cancelar, en la propia notificacion. Cancelar ya se podia: la politica
-- `cliente_cancela_su_cita` deja pasar su turno a 'cancelado'. Confirmar no:
-- hasta ahora confirmar era solo del mostrador (CU-004).
--
-- POR QUE UNA FUNCION Y NO UNA POLITICA MAS
--
-- Una politica de UPDATE con `with check (estado = 'confirmado')` dejaria al
-- cliente confirmar tambien un turno cancelado, o uno que ya paso: el
-- `with check` mira la fila nueva, no de que estado viene. La transicion que
-- se quiere permitir es una sola -pendiente a confirmado, en un turno suyo y
-- futuro- y una funcion la dice exacta, con un mensaje claro si no aplica.
--
-- `fn_minutos_recordatorio()` le deja leer al cliente UN numero de
-- `configuracion_sistema` -con cuanta anticipacion avisar-, que hoy solo lee
-- el administrador. Se expone ese valor y nada mas de la configuracion.
-- ============================================================================

create or replace function public.fn_confirmar_mi_turno(p_id_cita int)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
    v_cliente int := public.fn_id_cliente_actual();
begin
    if v_cliente is null then
        raise exception 'Solo un cliente puede confirmar su turno.';
    end if;

    update public.citas
       set estado = 'confirmado'
     where id_cita    = p_id_cita
       and id_cliente = v_cliente
       and estado     = 'pendiente'
       and fecha_hora > now()
       and not deleted;

    if not found then
        raise exception 'Ese turno ya no se puede confirmar.';
    end if;
end;
$fn$;

comment on function public.fn_confirmar_mi_turno(int) is
    'El cliente confirma su propio turno: solo de pendiente a confirmado, y solo '
    'si todavia no paso. Lo usa el boton Confirmar de la notificacion de la app.';

revoke execute on function public.fn_confirmar_mi_turno(int) from public, anon;
grant execute on function public.fn_confirmar_mi_turno(int) to authenticated;


create or replace function public.fn_minutos_recordatorio()
returns int
language sql
stable
security definer
set search_path = public
as $fn$
    select coalesce(
        (select minutos_antes_recordatorio
           from public.configuracion_sistema
          where id_configuracion = 1),
        1440
    );
$fn$;

comment on function public.fn_minutos_recordatorio() is
    'Con cuantos minutos de anticipacion se avisa un turno. La app del cliente '
    'programa su recordatorio con este valor; se configura desde el panel.';

revoke execute on function public.fn_minutos_recordatorio() from public, anon;
grant execute on function public.fn_minutos_recordatorio() to authenticated;
