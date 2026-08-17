-- ============================================================================
-- AUDITORIA TEMPORAL EN TODAS LAS TABLAS
--
-- Motivo: hasta ahora solo `citas` tenia el par created_at / updated_at con su
-- disparador conectado. El resto no permitia responder cuando se cargo un
-- registro ni cuando se lo toco por ultima vez.
--
-- Que hace esta migracion:
--   1. Agrega created_at y updated_at a las 26 tablas que no los tenian.
--   2. Conecta fn_set_updated_at() en las 27, incluida configuracion_sistema,
--      que tenia la columna updated_at pero ningun disparador la actualizaba:
--      mostraba siempre la fecha del alta.
--   3. Rellena created_at con la fecha propia que cada tabla ya guardaba, para
--      no perder el historico que hoy existe.
--
-- La funcion fn_set_updated_at() NO se crea aca: ya existe desde la migracion
-- de triggers y esta declarada security definer. Solo se la engancha.
--
-- Se aplica a las 27 tablas sin excepciones, incluidos los catalogos fijos
-- como roles y metodos_pago. La uniformidad vale mas que ahorrar dos columnas:
-- "toda tabla tiene created_at y updated_at" es una regla que se verifica de
-- un vistazo, y cualquier excepcion obliga a recordar cual era.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnas
-- ---------------------------------------------------------------------------
do $$
declare
    v_tabla text;
    v_tablas text[] := array[
        'roles', 'usuarios', 'clientes', 'profesionales',
        'categorias_servicio', 'servicios',
        'categorias_producto', 'productos', 'servicio_producto',
        'citas', 'detalle_cita', 'historial_servicio', 'productos_utilizados',
        'metodos_pago', 'cobros_cliente', 'pagos_profesional',
        'proveedores', 'pedidos', 'detalle_pedido', 'pagos_proveedor',
        'movimientos_inventario', 'alertas_stock',
        'notificaciones', 'recomendaciones_ml', 'auditoria',
        'configuracion_sistema', 'horarios_atencion'
    ];
begin
    foreach v_tabla in array v_tablas loop
        execute format(
            'alter table public.%I add column if not exists created_at timestamptz not null default now()',
            v_tabla
        );
        execute format(
            'alter table public.%I add column if not exists updated_at timestamptz not null default now()',
            v_tabla
        );
    end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Disparadores
--
-- Se borra antes de crear para que la migracion pueda reejecutarse y para no
-- duplicar el que `citas` ya tenia con otro nombre.
-- ---------------------------------------------------------------------------
drop trigger if exists trg_citas_set_updated_at on public.citas;

do $$
declare
    v_tabla text;
    v_tablas text[] := array[
        'roles', 'usuarios', 'clientes', 'profesionales',
        'categorias_servicio', 'servicios',
        'categorias_producto', 'productos', 'servicio_producto',
        'citas', 'detalle_cita', 'historial_servicio', 'productos_utilizados',
        'metodos_pago', 'cobros_cliente', 'pagos_profesional',
        'proveedores', 'pedidos', 'detalle_pedido', 'pagos_proveedor',
        'movimientos_inventario', 'alertas_stock',
        'notificaciones', 'recomendaciones_ml', 'auditoria',
        'configuracion_sistema', 'horarios_atencion'
    ];
begin
    foreach v_tabla in array v_tablas loop
        execute format(
            'drop trigger if exists trg_%s_updated_at on public.%I',
            v_tabla, v_tabla
        );
        execute format(
            'create trigger trg_%s_updated_at
                 before update on public.%I
                 for each row
                 execute function public.fn_set_updated_at()',
            v_tabla, v_tabla
        );
    end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Relleno del historico
--
-- Cada tabla que ya guardaba su propia fecha de alta la copia a created_at.
-- Sin esto, todos los registros existentes quedarian marcados con la fecha de
-- esta migracion y se perderia el dato real.
--
-- Las columnas originales NO se eliminan: varias tienen significado de negocio
-- propio (fecha_pedido es cuando se hizo el pedido, no cuando se inserto la
-- fila) y ademas el frontend las usa hoy. Las dos que si quedan redundantes
-- -usuarios.fecha_creacion y clientes.fecha_registro- se pueden retirar en una
-- migracion posterior, una vez que el frontend deje de leerlas.
-- ---------------------------------------------------------------------------
update public.usuarios               set created_at = fecha_creacion    where fecha_creacion is not null;
update public.clientes               set created_at = fecha_registro    where fecha_registro is not null;
update public.pedidos                set created_at = fecha_pedido      where fecha_pedido is not null;
update public.productos_utilizados   set created_at = fecha_uso         where fecha_uso is not null;
update public.movimientos_inventario set created_at = fecha             where fecha is not null;
update public.alertas_stock          set created_at = fecha_alerta      where fecha_alerta is not null;
update public.auditoria              set created_at = fecha_accion      where fecha_accion is not null;
update public.recomendaciones_ml     set created_at = fecha_generacion  where fecha_generacion is not null;

-- `citas` e `historial_servicio` ya traian created_at con su valor correcto.
-- `notificaciones` no tiene fecha de alta: fecha_envio es cuando se envio, que
-- puede ser mucho despues, y queda nula mientras el envio esta pendiente.

-- El updated_at recien creado arranca igual al created_at: hasta que alguien
-- modifique la fila, "creado" y "actualizado" son el mismo instante.
do $$
declare
    v_tabla text;
    v_tablas text[] := array[
        'usuarios', 'clientes', 'pedidos', 'productos_utilizados',
        'movimientos_inventario', 'alertas_stock', 'auditoria',
        'recomendaciones_ml', 'historial_servicio'
    ];
begin
    foreach v_tabla in array v_tablas loop
        execute format('update public.%I set updated_at = created_at', v_tabla);
    end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Indices
--
-- created_at se usa para ordenar listados por antiguedad y para acotar
-- reportes por periodo. Se indexa donde el volumen lo justifica: las tablas
-- que crecen con la operacion diaria, no los catalogos.
-- ---------------------------------------------------------------------------
create index if not exists idx_citas_created_at        on public.citas (created_at desc);
create index if not exists idx_clientes_created_at     on public.clientes (created_at desc);
create index if not exists idx_cobros_created_at       on public.cobros_cliente (created_at desc);
create index if not exists idx_historial_created_at    on public.historial_servicio (created_at desc);
create index if not exists idx_movimientos_created_at  on public.movimientos_inventario (created_at desc);
create index if not exists idx_auditoria_created_at    on public.auditoria (created_at desc);

-- ---------------------------------------------------------------------------
-- 5. Documentacion de las columnas
-- ---------------------------------------------------------------------------
do $$
declare
    v_tabla text;
    v_tablas text[] := array[
        'roles', 'usuarios', 'clientes', 'profesionales',
        'categorias_servicio', 'servicios',
        'categorias_producto', 'productos', 'servicio_producto',
        'citas', 'detalle_cita', 'historial_servicio', 'productos_utilizados',
        'metodos_pago', 'cobros_cliente', 'pagos_profesional',
        'proveedores', 'pedidos', 'detalle_pedido', 'pagos_proveedor',
        'movimientos_inventario', 'alertas_stock',
        'notificaciones', 'recomendaciones_ml', 'auditoria',
        'configuracion_sistema', 'horarios_atencion'
    ];
begin
    foreach v_tabla in array v_tablas loop
        execute format(
            'comment on column public.%I.created_at is %L',
            v_tabla, 'Instante de alta de la fila. Lo fija el valor por defecto.'
        );
        execute format(
            'comment on column public.%I.updated_at is %L',
            v_tabla, 'Ultima modificacion. Lo mantiene el disparador trg_' || v_tabla || '_updated_at.'
        );
    end loop;
end;
$$;
