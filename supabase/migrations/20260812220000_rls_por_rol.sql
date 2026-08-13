-- ============================================================================
-- SEGURIDAD POR ROL, VALORIZACION DE INVENTARIO Y LIMPIEZA DE AUTENTICACION
--
-- Reemplaza la politica provisional "acceso_autenticado" -que daba acceso
-- total a cualquier usuario logueado- por politicas diferenciadas segun el
-- rol, cumpliendo RN-039 y RN-054.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. RN-001 / RN-047: la contrasena se gestiona en Supabase Auth
-- ---------------------------------------------------------------------------
alter table public.usuarios drop column password_hash;

comment on table public.usuarios is
    'Usuarios internos. La credencial vive en auth.users; el vinculo es auth_uid.';

-- ---------------------------------------------------------------------------
-- 2. RN-052: valorizacion del inventario
-- ---------------------------------------------------------------------------
create view public.v_valorizacion_inventario
with (security_invoker = true) as
select p.id_producto,
       p.nombre                                    as nombre_producto,
       cp.nombre                                   as categoria,
       p.stock_actual,
       p.precio_unitario,
       round(p.stock_actual * p.precio_unitario, 2) as valor_total
from public.productos p
join public.categorias_producto cp on cp.id_categoria_p = p.id_categoria_p
where p.estado;

comment on view public.v_valorizacion_inventario is
    'RN-052: valor del stock disponible = stock_actual x precio_unitario.';

-- ---------------------------------------------------------------------------
-- 3. Funciones de contexto del usuario autenticado
--
--    SECURITY DEFINER porque deben poder leer usuarios y roles incluso para
--    un usuario que no tiene permiso de lectura sobre esas tablas.
-- ---------------------------------------------------------------------------
create or replace function public.fn_rol_actual()
returns text
language sql
stable
security definer
set search_path = public
as $$
    select r.nombre
    from public.usuarios u
    join public.roles r on r.id_rol = u.id_rol
    where u.auth_uid = auth.uid()
      and u.estado
      and r.estado
    limit 1;
$$;

comment on function public.fn_rol_actual is
    'Nombre del rol del usuario autenticado. NULL si no esta registrado o esta inactivo (RN-003).';

create or replace function public.fn_es_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(public.fn_rol_actual() = 'administrador', false);
$$;

create or replace function public.fn_id_profesional_actual()
returns int
language sql
stable
security definer
set search_path = public
as $$
    select p.id_profesional
    from public.profesionales p
    join public.usuarios u on u.id_usuario = p.id_usuario
    where u.auth_uid = auth.uid()
      and p.estado
    limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 4. Las funciones del sistema escriben por encima de RLS
--
--    Los triggers generan filas en tablas sobre las que el usuario que
--    dispara la operacion no tiene permiso de escritura: una recepcionista
--    completa una cita y el sistema debe crear la comision, que es
--    exclusiva del Administrador. Sin SECURITY DEFINER, RLS bloquearia esa
--    escritura automatica.
-- ---------------------------------------------------------------------------
alter function public.fn_registrar_auditoria(varchar, varchar, int, text)  security definer;
alter function public.fn_actualizar_stock(int, numeric, boolean)           security definer;
alter function public.fn_calcular_total_cita(int)                          security definer;
alter function public.fn_calcular_comision(int)                            security definer;
alter function public.fn_verificar_conflicto_horario(int, timestamptz, int, int) security definer;
alter function public.fn_set_updated_at()                                  security definer;
alter function public.fn_trg_cita_validar()                                security definer;
alter function public.fn_trg_cita_inmutable()                              security definer;
alter function public.fn_trg_cita_completada()                             security definer;
alter function public.fn_trg_detalle_cita_before_insert()                  security definer;
alter function public.fn_trg_detalle_cita_recalcular_total()               security definer;
alter function public.fn_trg_producto_utilizado()                          security definer;
alter function public.fn_trg_stock_minimo()                                security definer;
alter function public.fn_trg_stock_recuperado()                            security definer;
alter function public.fn_trg_stock_no_negativo()                           security definer;
alter function public.fn_trg_pedido_recibido()                             security definer;
alter function public.fn_trg_pedido_total()                                security definer;
alter function public.fn_trg_detalle_pedido_subtotal()                     security definer;
alter function public.fn_trg_cobro_cita_completada()                       security definer;
alter function public.fn_trg_cobro_no_excede()                             security definer;
alter function public.fn_trg_pago_prof_inmutable()                         security definer;
alter function public.fn_trg_pago_prov_pedido_recibido()                   security definer;
alter function public.fn_trg_pago_prov_no_excede()                         security definer;
alter function public.fn_trg_recomendacion_min_historial()                 security definer;

-- ---------------------------------------------------------------------------
-- 5. Se retira la politica provisional
-- ---------------------------------------------------------------------------
do $$
declare
    v_tabla text;
begin
    for v_tabla in
        select tablename from pg_policies
        where schemaname = 'public' and policyname = 'acceso_autenticado'
    loop
        execute format('drop policy "acceso_autenticado" on public.%I', v_tabla);
    end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Politicas por rol
--
--    Administrador  : acceso total a todo el sistema.
--    Recepcionista  : opera agenda, clientes, cobros e inventario; lee los
--                     catalogos; no accede a la administracion ni a compras.
--    Profesional    : solo lectura, y sobre su propio historial y comisiones.
--    Cliente        : sin acceso. El caso de uso no define un portal del
--                     cliente; el rol queda reservado.
-- ---------------------------------------------------------------------------
do $$
declare
    v_tabla text;

    -- Exclusivas del Administrador
    v_admin text[] := array[
        'roles', 'usuarios', 'configuracion_sistema', 'horarios_atencion',
        'auditoria', 'proveedores', 'pedidos', 'detalle_pedido', 'pagos_proveedor'
    ];

    -- Catalogos: el Administrador mantiene, el resto consulta
    v_catalogo text[] := array[
        'profesionales', 'categorias_servicio', 'servicios',
        'categorias_producto', 'servicio_producto', 'metodos_pago'
    ];

    -- Operacion diaria: Administrador y Recepcionista operan
    v_operacion text[] := array[
        'clientes', 'citas', 'detalle_cita', 'cobros_cliente',
        'notificaciones', 'recomendaciones_ml'
    ];

    -- Inventario: Administrador y Recepcionista operan
    v_inventario text[] := array[
        'productos', 'movimientos_inventario', 'alertas_stock'
    ];
begin
    foreach v_tabla in array v_admin loop
        execute format(
            'create policy "admin_total" on public.%I for all to authenticated
                 using (public.fn_es_admin()) with check (public.fn_es_admin())', v_tabla);
    end loop;

    foreach v_tabla in array v_catalogo loop
        execute format(
            'create policy "admin_total" on public.%I for all to authenticated
                 using (public.fn_es_admin()) with check (public.fn_es_admin())', v_tabla);
        execute format(
            'create policy "consulta_operativa" on public.%I for select to authenticated
                 using (public.fn_rol_actual() in (''recepcionista'', ''profesional''))', v_tabla);
    end loop;

    foreach v_tabla in array v_operacion || v_inventario loop
        execute format(
            'create policy "admin_total" on public.%I for all to authenticated
                 using (public.fn_es_admin()) with check (public.fn_es_admin())', v_tabla);
        execute format(
            'create policy "recepcion_opera" on public.%I for all to authenticated
                 using (public.fn_rol_actual() = ''recepcionista'')
                 with check (public.fn_rol_actual() = ''recepcionista'')', v_tabla);
        execute format(
            'create policy "profesional_consulta" on public.%I for select to authenticated
                 using (public.fn_rol_actual() = ''profesional'')', v_tabla);
    end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Tablas donde el profesional solo ve lo suyo
-- ---------------------------------------------------------------------------
create policy "admin_total" on public.historial_servicio
    for all to authenticated
    using (public.fn_es_admin()) with check (public.fn_es_admin());

create policy "recepcion_opera" on public.historial_servicio
    for all to authenticated
    using (public.fn_rol_actual() = 'recepcionista')
    with check (public.fn_rol_actual() = 'recepcionista');

create policy "profesional_ve_lo_suyo" on public.historial_servicio
    for select to authenticated
    using (id_profesional = public.fn_id_profesional_actual());

create policy "admin_total" on public.productos_utilizados
    for all to authenticated
    using (public.fn_es_admin()) with check (public.fn_es_admin());

create policy "recepcion_opera" on public.productos_utilizados
    for all to authenticated
    using (public.fn_rol_actual() = 'recepcionista')
    with check (public.fn_rol_actual() = 'recepcionista');

create policy "profesional_ve_lo_suyo" on public.productos_utilizados
    for select to authenticated
    using (exists (
        select 1 from public.historial_servicio h
        where h.id_historial = productos_utilizados.id_historial
          and h.id_profesional = public.fn_id_profesional_actual()
    ));

-- RN-026: solo el Administrador liquida comisiones. El profesional consulta
-- las suyas.
create policy "admin_total" on public.pagos_profesional
    for all to authenticated
    using (public.fn_es_admin()) with check (public.fn_es_admin());

create policy "profesional_ve_sus_comisiones" on public.pagos_profesional
    for select to authenticated
    using (id_profesional = public.fn_id_profesional_actual());
