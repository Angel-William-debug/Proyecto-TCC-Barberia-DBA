-- ============================================================================
-- BORRADO LOGICO CON TRAZABILIDAD
--
-- Agrega a las tablas que lo necesitan:
--   deleted          boolean not null default false
--   deleted_at       timestamptz
--   deleted_user_id  int references usuarios
--
-- POR QUE NO REEMPLAZA A `estado`
--
-- Las dos columnas conviven porque significan cosas distintas:
--   estado = false   la barberia dejo de ofrecer ese servicio por ahora y
--                    puede volver a activarlo. Es un estado de negocio.
--   deleted = true   el registro se cargo por error o se dio de baja
--                    definitivamente. Ya no deberia aparecer en ningun lado.
-- Unificarlas haria imposible desactivar sin borrar, que es un caso real
-- del CU-003.
--
-- LA TRAMPA DE LOS INDICES UNICOS
--
-- Un UNIQUE sigue contando las filas borradas. Sin corregirlo, borrar
-- logicamente a un cliente deja su correo bloqueado para siempre: nadie mas
-- puede darse de alta con esa direccion y el registro que estorba es
-- invisible. Por eso los unicos afectados pasan a ser indices parciales
-- `where not deleted`.
--
-- CONSECUENCIA: RESTAURAR PUEDE FALLAR, Y ESTA BIEN QUE FALLE
--
-- Liberar el valor tiene un efecto que conviene conocer antes de que aparezca
-- en produccion: si se borra a un cliente, otro toma su correo, y despues se
-- intenta restaurar al primero, la base rechaza la restauracion porque
-- quedarian dos vigentes con la misma direccion.
--
-- Es el comportamiento correcto -la alternativa seria admitir datos
-- duplicados- pero la aplicacion tiene que traducirlo a un mensaje que se
-- entienda: "No se puede restaurar este cliente porque su correo ya fue
-- asignado a otro". Verificado en la validacion de esta migracion.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnas
--
-- Se aplica a las entidades que el usuario da de alta y puede querer
-- eliminar, mas los documentos que pueden cargarse por error.
--
-- NO se aplica a los registros historicos -auditoria, movimientos_inventario,
-- historial_servicio, pagos_profesional, alertas_stock, notificaciones,
-- recomendaciones_ml-: un asiento de auditoria que se puede borrar deja de
-- ser auditoria, y una comision liquidada no puede desaparecer (RN-027).
-- ---------------------------------------------------------------------------
do $$
declare
    v_tabla text;
    v_tablas text[] := array[
        -- Entidades de alta
        'clientes', 'profesionales', 'usuarios',
        'servicios', 'categorias_servicio',
        'productos', 'categorias_producto', 'servicio_producto',
        'proveedores', 'metodos_pago',
        -- Documentos que pueden cargarse por error
        'citas', 'cobros_cliente', 'pedidos', 'horarios_atencion'
    ];
begin
    foreach v_tabla in array v_tablas loop
        execute format(
            'alter table public.%I add column if not exists deleted boolean not null default false',
            v_tabla
        );
        execute format(
            'alter table public.%I add column if not exists deleted_at timestamptz',
            v_tabla
        );
        execute format(
            'alter table public.%I add column if not exists deleted_user_id int references public.usuarios (id_usuario)',
            v_tabla
        );

        -- Indice parcial: solo indexa lo borrado, que es la minoria. Sirve
        -- para el listado de papelera sin engordar el indice con todo lo
        -- vigente.
        execute format(
            'create index if not exists idx_%s_deleted on public.%I (deleted) where deleted',
            v_tabla, v_tabla
        );

        -- El id de quien borro se consulta al mostrar la papelera.
        execute format(
            'create index if not exists idx_%s_deleted_user on public.%I (deleted_user_id) where deleted_user_id is not null',
            v_tabla, v_tabla
        );

        execute format(
            'comment on column public.%I.deleted is %L',
            v_tabla,
            'Borrado logico. false = vigente. Distinto de `estado`, que indica si esta activo.'
        );
        execute format(
            'comment on column public.%I.deleted_at is %L',
            v_tabla, 'Instante del borrado. Lo completa el disparador trg_' || v_tabla || '_borrado.'
        );
        execute format(
            'comment on column public.%I.deleted_user_id is %L',
            v_tabla, 'Usuario que borro el registro. Lo completa la aplicacion.'
        );
    end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Disparador de coherencia
--
-- Completa deleted_at solo cuando deleted pasa a verdadero, y lo limpia si se
-- restaura. Asi la aplicacion no puede dejar un registro marcado como borrado
-- sin fecha, ni una fecha de borrado en un registro vigente.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_deleted_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if new.deleted and not old.deleted then
        new.deleted_at := coalesce(new.deleted_at, now());
    elsif not new.deleted and old.deleted then
        -- Restauracion: se limpia el rastro para que no quede una fecha de
        -- borrado en una fila viva.
        new.deleted_at := null;
        new.deleted_user_id := null;
    end if;

    return new;
end;
$$;

comment on function public.fn_set_deleted_at() is
    'Mantiene deleted_at coherente con deleted. Ver migracion de borrado logico.';

do $$
declare
    v_tabla text;
    v_tablas text[] := array[
        'clientes', 'profesionales', 'usuarios',
        'servicios', 'categorias_servicio',
        'productos', 'categorias_producto', 'servicio_producto',
        'proveedores', 'metodos_pago',
        'citas', 'cobros_cliente', 'pedidos', 'horarios_atencion'
    ];
begin
    foreach v_tabla in array v_tablas loop
        execute format('drop trigger if exists trg_%s_borrado on public.%I', v_tabla, v_tabla);
        execute format(
            'create trigger trg_%s_borrado
                 before update on public.%I
                 for each row
                 execute function public.fn_set_deleted_at()',
            v_tabla, v_tabla
        );
    end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Indices unicos parciales
--
-- Cada UNIQUE que alcanzaba a filas borradas se reemplaza por un indice
-- parcial que solo mira lo vigente. Es el paso que evita que un registro
-- invisible bloquee un alta legitima.
-- ---------------------------------------------------------------------------

-- usuarios.email
alter table public.usuarios drop constraint if exists usuarios_email_key;
create unique index if not exists usuarios_email_vigente
    on public.usuarios (email) where not deleted;

-- clientes.email (admite nulos: un cliente puede no tener correo)
alter table public.clientes drop constraint if exists clientes_email_key;
create unique index if not exists clientes_email_vigente
    on public.clientes (email) where not deleted and email is not null;

-- categorias_servicio.nombre
alter table public.categorias_servicio drop constraint if exists categorias_servicio_nombre_key;
create unique index if not exists categorias_servicio_nombre_vigente
    on public.categorias_servicio (nombre) where not deleted;

-- categorias_producto.nombre
alter table public.categorias_producto drop constraint if exists categorias_producto_nombre_key;
create unique index if not exists categorias_producto_nombre_vigente
    on public.categorias_producto (nombre) where not deleted;

-- metodos_pago.nombre
alter table public.metodos_pago drop constraint if exists metodos_pago_nombre_key;
create unique index if not exists metodos_pago_nombre_vigente
    on public.metodos_pago (nombre) where not deleted;

-- servicios: nombre unico dentro de su categoria (agregado en validaciones)
alter table public.servicios drop constraint if exists servicios_categoria_nombre_key;
create unique index if not exists servicios_categoria_nombre_vigente
    on public.servicios (id_categoria, nombre) where not deleted;

-- servicio_producto: un producto no se repite dentro del mismo servicio
alter table public.servicio_producto drop constraint if exists servicio_producto_id_servicio_id_producto_key;
create unique index if not exists servicio_producto_vigente
    on public.servicio_producto (id_servicio, id_producto) where not deleted;

-- horarios_atencion: un solo horario por dia
alter table public.horarios_atencion drop constraint if exists horarios_atencion_dia_semana_key;
create unique index if not exists horarios_atencion_dia_vigente
    on public.horarios_atencion (dia_semana) where not deleted;

-- profesionales.id_usuario y usuarios.auth_uid conservan su UNIQUE original:
-- son vinculos con la identidad, no datos que el usuario reingrese. Si un
-- profesional se borra logicamente, su id_usuario debe seguir ocupado.

-- ---------------------------------------------------------------------------
-- 4. Las vistas existentes dejan de mostrar lo borrado
--
-- Sin esto, un cliente borrado seguiria apareciendo en la agenda y en el
-- historial. Se recrean las cuatro vistas afectadas; las otras tres consultan
-- solo tablas historicas, que no llevan borrado logico.
-- ---------------------------------------------------------------------------
create or replace view public.v_citas_activas
with (security_invoker = true) as
select c.id_cita,
       c.fecha_hora,
       c.estado,
       cl.nombre as nombre_cliente,
       s.nombre  as nombre_servicio,
       p.nombre  as nombre_profesional,
       d.duracion_min
from public.citas c
join public.clientes cl on cl.id_cliente = c.id_cliente and not cl.deleted
join public.detalle_cita d on d.id_cita = c.id_cita
join public.servicios s on s.id_servicio = d.id_servicio and not s.deleted
join public.profesionales p on p.id_profesional = d.id_profesional and not p.deleted
where c.estado in ('pendiente', 'confirmado', 'en_proceso')
  and not c.deleted;

create or replace view public.v_stock_critico
with (security_invoker = true) as
select p.id_producto,
       p.nombre as nombre_producto,
       p.stock_minimo,
       p.stock_maximo,
       p.stock_actual,
       p.stock_minimo - p.stock_actual as diferencia
from public.productos p
where p.estado
  and not p.deleted
  and p.stock_actual <= p.stock_minimo;

create or replace view public.v_ingresos_por_periodo
with (security_invoker = true) as
select extract(year from cc.fecha_pago)::int  as anio,
       extract(month from cc.fecha_pago)::int as mes,
       sum(cc.monto)                          as total_ingresos,
       count(*)                               as cantidad_servicios,
       round(avg(cc.monto), 2)                as ticket_promedio
from public.cobros_cliente cc
where cc.estado in ('pagado', 'parcial')
  and cc.fecha_pago is not null
  and not cc.deleted
group by 1, 2;

create or replace view public.v_pedidos_estado
with (security_invoker = true) as
select pe.id_pedido,
       pr.nombre as nombre_proveedor,
       pe.estado,
       pe.fecha_pedido,
       pe.total,
       (select string_agg(p.nombre || ' x' || dp.cantidad, ', ' order by p.nombre)
        from public.detalle_pedido dp
        join public.productos p on p.id_producto = dp.id_producto
        where dp.id_pedido = pe.id_pedido) as productos_incluidos
from public.pedidos pe
join public.proveedores pr on pr.id_proveedor = pe.id_proveedor
where not pe.deleted;
