-- ============================================================================
-- LA FICHA DEL CLIENTE, SIN LAS NOTAS INTERNAS (RN-008)
--
-- EL HUECO
--
-- `clientes.notas_internas` son las anotaciones que el mostrador hace sobre el
-- cliente, y RN-008 dice que el cliente no las ve. El portal y la app nunca las
-- pidieron, pero la politica `cliente_ve_su_ficha` le daba SELECT sobre su
-- fila entera: con su propia sesion, cualquiera podia leerlas llamando a la API
-- directamente (`/rest/v1/clientes?select=*`). Lo encontro una prueba del
-- 14/10/2026: un update del perfil desde la app devolvia la fila completa.
--
-- RLS filtra filas, no columnas. Y un permiso por columna tampoco sirve: el
-- personal y el cliente son el mismo rol de base (`authenticated`), y el
-- personal SI necesita las notas.
--
-- LA CORRECCION
--
-- El cliente deja de tocar la tabla directamente. Para su ficha usa dos
-- funciones que exponen solo lo suyo y solo lo que puede ver o cambiar:
--
--   fn_mi_perfil()             lee nombre, correo, telefono, direccion,
--                              fecha de nacimiento y alta. Sin notas.
--   fn_actualizar_mi_perfil()  cambia nombre, telefono, direccion y fecha de
--                              nacimiento. Ni el correo ni los campos de
--                              control.
--
-- y se borran las dos politicas que le daban acceso a la tabla. Las del
-- personal no cambian. Lo demas que el cliente consulta ya pasaba por
-- funciones (`fn_id_cliente_actual`, `fn_mis_turnos`, `fn_turnos_disponibles`,
-- `fn_ocupacion_barberos`).
--
-- DE PASO: `v_historial_completo_cliente` suma `id_cliente` al final (pendiente
-- tecnico 13). Solo traia el nombre, y filtrar por nombre arriesga mezclar a
-- dos clientes que se llaman igual.
-- ============================================================================

create or replace function public.fn_mi_perfil()
returns table (
    id_cliente        int,
    nombre            varchar,
    email             varchar,
    telefono          varchar,
    direccion         text,
    fecha_nacimiento  date,
    fecha_registro    timestamptz
)
language sql
stable
security definer
set search_path = public
as $fn$
    select c.id_cliente, c.nombre, c.email, c.telefono, c.direccion,
           c.fecha_nacimiento, c.fecha_registro
    from public.clientes c
    where c.id_cliente = public.fn_id_cliente_actual();
$fn$;

comment on function public.fn_mi_perfil is
    'La ficha del cliente de la sesion, sin notas_internas (RN-008).';

create or replace function public.fn_actualizar_mi_perfil(
    p_nombre            text,
    p_telefono          text,
    p_direccion         text default null,
    p_fecha_nacimiento  date default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
    v_id int := public.fn_id_cliente_actual();
begin
    if v_id is null then
        raise exception 'Su cuenta todavia no tiene una ficha de cliente.';
    end if;
    if p_nombre is null or length(trim(p_nombre)) < 3 then
        raise exception 'Escriba su nombre y apellido.';
    end if;
    if p_telefono is null or length(trim(p_telefono)) < 6 then
        raise exception 'Escriba un telefono de contacto.';
    end if;

    -- Solo estos cuatro campos: el correo es la credencial y los de control
    -- son del mostrador. `trg_cliente_campos_de_control` lo vuelve a mirar.
    update public.clientes
       set nombre           = trim(p_nombre),
           telefono         = trim(p_telefono),
           direccion        = nullif(trim(coalesce(p_direccion, '')), ''),
           fecha_nacimiento = p_fecha_nacimiento
     where id_cliente = v_id;
end;
$fn$;

comment on function public.fn_actualizar_mi_perfil is
    'El cliente de la sesion cambia nombre, telefono, direccion y fecha de nacimiento.';

revoke execute on function public.fn_mi_perfil() from public, anon;
revoke execute on function public.fn_actualizar_mi_perfil(text, text, text, date) from public, anon;
grant execute on function public.fn_mi_perfil() to authenticated;
grant execute on function public.fn_actualizar_mi_perfil(text, text, text, date) to authenticated;

-- El cliente ya no lee ni edita la tabla directamente.
drop policy if exists cliente_ve_su_ficha on public.clientes;
drop policy if exists cliente_edita_su_ficha on public.clientes;

-- La vista del historial, con el id del cliente al final (las columnas
-- existentes no se pueden reordenar con `create or replace view`).
create or replace view public.v_historial_completo_cliente
with (security_invoker = true) as
select h.id_historial,
       cl.nombre AS nombre_cliente,
       s.nombre AS nombre_servicio,
       p.nombre AS nombre_profesional,
       h.fecha_realizacion,
       h.costo_cobrado,
       (select string_agg(pr.nombre::text || ' (' || pu.cantidad_usada || ')', ', ' order by pr.nombre)
          from public.productos_utilizados pu
          join public.productos pr on pr.id_producto = pu.id_producto
         where pu.id_historial = h.id_historial) AS productos_utilizados,
       h.id_cliente
from public.historial_servicio h
join public.clientes cl on cl.id_cliente = h.id_cliente
join public.servicios s on s.id_servicio = h.id_servicio
join public.profesionales p on p.id_profesional = h.id_profesional;
