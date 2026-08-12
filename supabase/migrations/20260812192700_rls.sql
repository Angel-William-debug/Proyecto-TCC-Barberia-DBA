-- ============================================================================
-- ROW LEVEL SECURITY
--
-- En Supabase las tablas de public quedan expuestas por la API REST. Sin RLS,
-- cualquiera con la clave anonima (que viaja en el frontend) podria leer y
-- escribir todo.
--
-- Politica de partida: acceso completo para usuarios autenticados, nada para
-- anonimos. Es deliberadamente amplia para no frenar el desarrollo; hay que
-- ajustarla por rol antes de produccion (ver nota al final).
-- ============================================================================

do $$
declare
    v_tabla text;
    v_tablas text[] := array[
        'roles',
        'usuarios',
        'clientes',
        'profesionales',
        'categorias_servicio',
        'servicios',
        'categorias_producto',
        'productos',
        'servicio_producto',
        'citas',
        'detalle_cita',
        'historial_servicio',
        'productos_utilizados',
        'metodos_pago',
        'cobros_cliente',
        'pagos_profesional',
        'proveedores',
        'pedidos',
        'detalle_pedido',
        'pagos_proveedor',
        'movimientos_inventario',
        'alertas_stock',
        'notificaciones',
        'recomendaciones_ml',
        'auditoria'
    ];
begin
    foreach v_tabla in array v_tablas loop
        execute format('alter table public.%I enable row level security', v_tabla);

        execute format(
            'create policy "acceso_autenticado" on public.%I
                 for all to authenticated using (true) with check (true)',
            v_tabla
        );
    end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- PENDIENTE antes de produccion
--
-- Reemplazar "acceso_autenticado" por politicas por rol. Por ejemplo, para que
-- un cliente solo vea sus propias citas:
--
--   create policy "cliente_ve_sus_citas" on public.citas
--       for select to authenticated
--       using (
--           exists (
--               select 1
--               from public.clientes cl
--               join public.usuarios u on u.id_usuario = cl.id_usuario_reg
--               where cl.id_cliente = citas.id_cliente
--                 and u.auth_uid = auth.uid()
--           )
--       );
--
-- Y que solo administradores escriban en catalogos:
--
--   create policy "admin_gestiona_servicios" on public.servicios
--       for all to authenticated
--       using (
--           exists (
--               select 1
--               from public.usuarios u
--               join public.roles r on r.id_rol = u.id_rol
--               where u.auth_uid = auth.uid()
--                 and r.nombre = 'administrador'
--           )
--       );
-- ---------------------------------------------------------------------------
