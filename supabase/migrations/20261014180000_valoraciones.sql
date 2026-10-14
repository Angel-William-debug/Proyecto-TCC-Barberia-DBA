-- ============================================================================
-- VALORACIONES: EL CLIENTE CALIFICA SU TURNO, EL RANKING LAS PROMEDIA
--
-- La directora pidio un ranking de barberos (1/9/2026). Se hizo por volumen
-- de atencion -servicios, facturado, clientes, ocupacion- porque no habia de
-- donde sacar una valoracion: ningun dato decia si el cliente quedo conforme.
-- Esta migracion agrega ese dato.
--
-- QUE SE CALIFICA. Un TURNO completado (`citas`), de 1 a 5 estrellas, con un
-- comentario opcional. Uno por turno; se puede cambiar despues. Se califica el
-- turno y no cada servicio porque es lo que el cliente recuerda («como me fue
-- el martes»), y la pantalla de Historial ya los muestra asi. La valoracion
-- cuenta para cada barbero que atendio ese turno.
--
-- QUIEN LA ESCRIBE. Solo el cliente dueño del turno, por
-- `fn_valorar_turno()`: comprueba que el turno sea suyo y este completado.
-- No tiene permisos sobre la tabla. El personal las lee (ranking, ficha del
-- cliente) y no las escribe: una valoracion cargada por la barberia no es una
-- valoracion.
-- ============================================================================

create table public.valoraciones (
    id_valoracion  int generated always as identity primary key,
    id_cita        int not null unique references public.citas (id_cita) on delete cascade,
    id_cliente     int not null references public.clientes (id_cliente),
    puntaje        smallint not null check (puntaje between 1 and 5),
    comentario     varchar(500),
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

comment on table public.valoraciones is
    'Calificacion de 1 a 5 que el cliente le da a un turno completado. Una por turno.';

create index idx_valoraciones_cliente on public.valoraciones (id_cliente);

create trigger trg_valoraciones_updated_at
    before update on public.valoraciones
    for each row execute function public.fn_set_updated_at();

alter table public.valoraciones enable row level security;

-- El personal lee; nadie escribe directo (el cliente lo hace por la funcion).
create policy admin_total on public.valoraciones
    for all to authenticated using (public.fn_es_admin()) with check (public.fn_es_admin());
create policy personal_consulta on public.valoraciones
    for select to authenticated
    using (public.fn_rol_actual() in ('recepcionista', 'profesional'));

-- ---------------------------------------------------------------------------
-- El cliente califica
-- ---------------------------------------------------------------------------

create or replace function public.fn_valorar_turno(
    p_id_cita     int,
    p_puntaje     int,
    p_comentario  text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
    v_cliente int := public.fn_id_cliente_actual();
begin
    if v_cliente is null then
        raise exception 'Hace falta una cuenta de cliente para calificar.';
    end if;
    if p_puntaje is null or p_puntaje not between 1 and 5 then
        raise exception 'La calificacion va de 1 a 5 estrellas.';
    end if;
    if not exists (
        select 1 from public.citas c
         where c.id_cita = p_id_cita
           and c.id_cliente = v_cliente
           and c.estado = 'completado'
           and not c.deleted
    ) then
        raise exception 'Solo puede calificar un turno suyo que ya se completo.';
    end if;

    insert into public.valoraciones (id_cita, id_cliente, puntaje, comentario)
    values (p_id_cita, v_cliente, p_puntaje, nullif(left(trim(coalesce(p_comentario, '')), 500), ''))
    on conflict (id_cita) do update
        set puntaje    = excluded.puntaje,
            comentario = excluded.comentario;
end;
$fn$;

-- Las del cliente de la sesion, para mostrarlas en su historial.
create or replace function public.fn_mis_valoraciones()
returns table (id_cita int, puntaje smallint, comentario varchar)
language sql
stable
security definer
set search_path = public
as $fn$
    select v.id_cita, v.puntaje, v.comentario
    from public.valoraciones v
    where v.id_cliente = public.fn_id_cliente_actual();
$fn$;

revoke execute on function public.fn_valorar_turno(int, int, text) from public, anon;
revoke execute on function public.fn_mis_valoraciones() from public, anon;
grant execute on function public.fn_valorar_turno(int, int, text) to authenticated;
grant execute on function public.fn_mis_valoraciones() to authenticated;

-- ---------------------------------------------------------------------------
-- El promedio por barbero, para el ranking
-- ---------------------------------------------------------------------------

-- Cada valoracion cuenta una vez por barbero que atendio el turno, aunque le
-- haya hecho dos servicios. `security_invoker`: la ve quien puede ver
-- `valoraciones`, es decir el personal.
create or replace view public.v_valoracion_por_barbero
with (security_invoker = true) as
select atendio.id_profesional,
       round(avg(v.puntaje)::numeric, 2) as promedio,
       count(*)::int                     as cantidad
from public.valoraciones v
join (select distinct d.id_cita, d.id_profesional from public.detalle_cita d) atendio
  on atendio.id_cita = v.id_cita
group by atendio.id_profesional;

comment on view public.v_valoracion_por_barbero is
    'Promedio de valoracion (1 a 5) y cantidad de turnos calificados por barbero.';
