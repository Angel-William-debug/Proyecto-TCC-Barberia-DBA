-- ============================================================================
-- AVISOS PUSH AL CLIENTE (fase 3b de la app movil)
--
-- Cuando la BARBERIA confirma, cancela o cambia la hora de un turno desde el
-- panel, el cliente recibe un aviso en el telefono al instante, aunque la app
-- este cerrada. En Android eso solo es posible por Firebase Cloud Messaging;
-- se usa a traves de Expo Push, y Firebase hace solo de cartero: los datos
-- siguen en Supabase.
--
-- EL CAMINO DE UN AVISO
--
--   1. La recepcion cambia una cita (`citas`).
--   2. `trg_cita_avisar_cliente` anota el aviso en `notificaciones`, con el
--      texto ya armado y `proveedor = 'expo'`.
--   3. `trg_notificacion_enviar` llama por `pg_net` a la Edge Function
--      `avisos-push`, que busca los telefonos del cliente en
--      `dispositivos_push`, envia por Expo y marca el resultado.
--
-- NO SE AVISA LO QUE HACE EL PROPIO CLIENTE: si cancela o confirma desde la
-- app, ya lo sabe. Se distingue con `fn_rol_actual()`, que mira la sesion
-- que hizo el cambio.
--
-- EL SECRETO. La Edge Function no exige la sesion de Supabase -la llama la
-- base, no un usuario-, asi que se protege con un secreto compartido: la base
-- lo lee del Vault (`avisos_push_secreto`) y la funcion lo compara con su
-- variable de entorno. El valor no esta en este archivo ni en git: se carga
-- aparte. Sin el, el aviso queda anotado como 'pendiente' y no se envia;
-- nada se rompe.
-- ============================================================================

create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- Los telefonos de cada usuario
-- ---------------------------------------------------------------------------

create table public.dispositivos_push (
    id_dispositivo int generated always as identity primary key,
    -- La sesion de Supabase y no `id_usuario`: es lo que la app conoce, y asi
    -- la politica RLS es directa.
    auth_uid       uuid not null references auth.users (id) on delete cascade,
    token          text not null unique,
    plataforma     varchar(20) not null default 'android',
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

comment on table public.dispositivos_push is
    'Identificador de notificaciones (Expo push token) de cada telefono con la app '
    'del cliente. Uno por telefono: si cambia de cuenta, el token pasa a la nueva.';

create index idx_dispositivos_push_auth_uid on public.dispositivos_push (auth_uid);

create trigger trg_dispositivos_push_updated_at
    before update on public.dispositivos_push
    for each row execute function public.fn_set_updated_at();

alter table public.dispositivos_push enable row level security;

-- Cada uno ve y borra solo los suyos. Se registran por `fn_registrar_dispositivo`,
-- que es la que decide de quien es el token.
create policy usuario_ve_sus_dispositivos on public.dispositivos_push
    for select to authenticated using (auth_uid = auth.uid());
create policy usuario_borra_sus_dispositivos on public.dispositivos_push
    for delete to authenticated using (auth_uid = auth.uid());
create policy admin_total on public.dispositivos_push
    for all to authenticated using (public.fn_es_admin()) with check (public.fn_es_admin());

create or replace function public.fn_registrar_dispositivo(p_token text, p_plataforma text default 'android')
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
    if auth.uid() is null then
        raise exception 'Hace falta una sesion para registrar el telefono.';
    end if;
    if p_token is null or length(p_token) < 10 then
        raise exception 'El identificador del telefono no es valido.';
    end if;

    -- Un telefono es de quien tiene la sesion ahora: si antes lo uso otra
    -- cuenta, el token pasa a esta y la anterior deja de recibir avisos ahi.
    insert into public.dispositivos_push (auth_uid, token, plataforma)
    values (auth.uid(), p_token, coalesce(p_plataforma, 'android'))
    on conflict (token) do update
        set auth_uid = excluded.auth_uid,
            plataforma = excluded.plataforma;
end;
$fn$;

revoke execute on function public.fn_registrar_dispositivo(text, text) from public, anon;
grant execute on function public.fn_registrar_dispositivo(text, text) to authenticated;

-- Al cerrar sesion la app borra su token: ese telefono deja de recibir los
-- avisos de esta cuenta. Solo el propio.
create or replace function public.fn_olvidar_dispositivo(p_token text)
returns void
language sql
security definer
set search_path = public
as $fn$
    delete from public.dispositivos_push
     where token = p_token
       and auth_uid = auth.uid();
$fn$;

revoke execute on function public.fn_olvidar_dispositivo(text) from public, anon;
grant execute on function public.fn_olvidar_dispositivo(text) to authenticated;

-- ---------------------------------------------------------------------------
-- notificaciones: tipos y estado nuevos
-- ---------------------------------------------------------------------------

alter table public.notificaciones drop constraint notificaciones_tipo_check;
alter table public.notificaciones add constraint notificaciones_tipo_check check (
    tipo is null or tipo in (
        'confirmacion', 'recordatorio',
        'turno_confirmado', 'turno_cancelado', 'turno_reprogramado'
    )
);

alter table public.notificaciones drop constraint notificaciones_estado_envio_check;
alter table public.notificaciones add constraint notificaciones_estado_envio_check check (
    estado_envio in ('pendiente', 'enviado', 'fallido', 'sin_email', 'sin_dispositivo')
);

-- ---------------------------------------------------------------------------
-- 2. La barberia cambio un turno: se anota el aviso
-- ---------------------------------------------------------------------------

create or replace function public.fn_trg_cita_avisar_cliente()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
    v_usuario int;
    v_zona    text := 'America/Asuncion';
    v_tipo    text;
    v_mensaje text;
    v_cuando  text;
begin
    -- Lo hizo el propio cliente desde la app o el portal: ya lo sabe.
    if public.fn_rol_actual() = 'cliente' then
        return new;
    end if;

    -- El cliente tiene que tener cuenta para tener telefono: un cliente dado
    -- de alta en el mostrador sin usuario no recibe avisos.
    select c.id_usuario into v_usuario
      from public.clientes c
     where c.id_cliente = new.id_cliente;
    if v_usuario is null then
        return new;
    end if;

    v_cuando := to_char(new.fecha_hora at time zone v_zona, 'DD/MM/YYYY "a las" HH24:MI');

    if new.estado is distinct from old.estado and new.estado = 'confirmado' then
        v_tipo := 'turno_confirmado';
        v_mensaje := 'La barbería confirmó su turno del ' || v_cuando || '. ¡Lo esperamos!';
    elsif new.estado is distinct from old.estado and new.estado = 'cancelado' then
        v_tipo := 'turno_cancelado';
        v_mensaje := 'La barbería canceló su turno del ' || v_cuando
                  || '. Puede reservar otro desde la app.';
    elsif new.fecha_hora is distinct from old.fecha_hora
          and new.estado in ('pendiente', 'confirmado') then
        v_tipo := 'turno_reprogramado';
        v_mensaje := 'Su turno cambió: ahora es el ' || v_cuando || ' (antes, '
                  || to_char(old.fecha_hora at time zone v_zona, 'DD/MM "a las" HH24:MI') || ').';
    else
        return new;
    end if;

    insert into public.notificaciones (id_cita, id_usuario, tipo, mensaje, estado_envio, proveedor)
    values (new.id_cita, v_usuario, v_tipo, v_mensaje, 'pendiente', 'expo');

    return new;
end;
$fn$;

create trigger trg_cita_avisar_cliente
    after update of estado, fecha_hora on public.citas
    for each row execute function public.fn_trg_cita_avisar_cliente();

-- ---------------------------------------------------------------------------
-- 3. Se anoto un aviso push: se le pide a la Edge Function que lo envie
-- ---------------------------------------------------------------------------

create or replace function public.fn_trg_notificacion_enviar()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
    v_secreto text;
begin
    select decrypted_secret into v_secreto
      from vault.decrypted_secrets
     where name = 'avisos_push_secreto';

    -- Sin secreto cargado, el aviso queda 'pendiente'. Ver el encabezado.
    if v_secreto is null then
        return new;
    end if;

    perform net.http_post(
        url     := 'https://tmuntxynyopzbhzmulux.supabase.co/functions/v1/avisos-push',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-avisos-secreto', v_secreto),
        body    := jsonb_build_object('id_notificacion', new.id_notificacion)
    );
    return new;
end;
$fn$;

create trigger trg_notificacion_enviar
    after insert on public.notificaciones
    for each row
    when (new.proveedor = 'expo' and new.estado_envio = 'pendiente')
    execute function public.fn_trg_notificacion_enviar();
