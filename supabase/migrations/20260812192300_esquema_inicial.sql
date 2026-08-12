-- ============================================================================
-- SISTEMA DE GESTION BARBER SHOP - Esquema inicial
-- Basado en el DER del proyecto (barberia_db)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- SEGURIDAD Y USUARIOS
-- ---------------------------------------------------------------------------

create table public.roles (
    id_rol      int generated always as identity primary key,
    nombre      varchar(50) not null unique,
    descripcion text,
    estado      boolean not null default true
);

comment on table public.roles is 'Roles del sistema: administrador, recepcionista, profesional, cliente.';

create table public.usuarios (
    id_usuario     int generated always as identity primary key,
    id_rol         int not null references public.roles (id_rol),
    auth_uid       uuid unique references auth.users (id) on delete set null,
    nombre         varchar(100) not null,
    email          varchar(150) not null unique,
    password_hash  varchar(255),
    fecha_creacion timestamptz not null default now(),
    estado         boolean not null default true
);

comment on table public.usuarios is 'Usuarios internos del sistema.';
comment on column public.usuarios.auth_uid is 'Enlace con auth.users de Supabase Auth.';
comment on column public.usuarios.password_hash is 'Solo para autenticacion propia. Con Supabase Auth queda NULL.';

create index idx_usuarios_id_rol on public.usuarios (id_rol);

-- ---------------------------------------------------------------------------
-- CLIENTES Y PROFESIONALES
-- ---------------------------------------------------------------------------

create table public.clientes (
    id_cliente     int generated always as identity primary key,
    id_usuario_reg int references public.usuarios (id_usuario),
    nombre         varchar(150) not null,
    email          varchar(150) unique,
    telefono       varchar(20),
    direccion      text,
    fecha_registro timestamptz not null default now(),
    estado         boolean not null default true
);

comment on column public.clientes.id_usuario_reg is 'Usuario que registro al cliente.';

create index idx_clientes_id_usuario_reg on public.clientes (id_usuario_reg);

create table public.profesionales (
    id_profesional int generated always as identity primary key,
    id_usuario     int unique references public.usuarios (id_usuario),
    nombre         varchar(150) not null,
    especialidad   varchar(100),
    tipo           varchar(50),
    porcentaje_com numeric(5, 2) not null default 0
        check (porcentaje_com >= 0 and porcentaje_com <= 100),
    estado         boolean not null default true
);

comment on column public.profesionales.porcentaje_com is 'Porcentaje de comision sobre el servicio realizado (0-100).';

-- ---------------------------------------------------------------------------
-- CATALOGO DE SERVICIOS
-- ---------------------------------------------------------------------------

create table public.categorias_servicio (
    id_categoria int generated always as identity primary key,
    nombre       varchar(80) not null unique,
    descripcion  text,
    estado       boolean not null default true
);

create table public.servicios (
    id_servicio  int generated always as identity primary key,
    id_categoria int not null references public.categorias_servicio (id_categoria),
    nombre       varchar(100) not null,
    descripcion  text,
    duracion_min int not null check (duracion_min > 0),
    precio_base  numeric(10, 2) not null check (precio_base >= 0),
    estado       boolean not null default true
);

create index idx_servicios_id_categoria on public.servicios (id_categoria);

-- ---------------------------------------------------------------------------
-- CATALOGO DE PRODUCTOS E INVENTARIO
-- ---------------------------------------------------------------------------

create table public.categorias_producto (
    id_categoria_p int generated always as identity primary key,
    nombre         varchar(80) not null unique,
    descripcion    text,
    estado         boolean not null default true
);

create table public.productos (
    id_producto           int generated always as identity primary key,
    id_categoria_p        int not null references public.categorias_producto (id_categoria_p),
    nombre                varchar(150) not null,
    descripcion           text,
    unidad_medida         varchar(20),
    unidad_uso            varchar(20),
    cantidad_uso_estandar numeric(8, 2),
    precio_unitario       numeric(10, 2) not null default 0 check (precio_unitario >= 0),
    stock_minimo          numeric(12, 2) not null default 0 check (stock_minimo >= 0),
    stock_maximo          numeric(12, 2),
    stock_actual          numeric(12, 2) not null default 0 check (stock_actual >= 0),
    estado                boolean not null default true
);

comment on column public.productos.stock_actual is
    'Numerico (no entero) para permitir consumo parcial desde productos_utilizados.cantidad_usada.';

create index idx_productos_id_categoria_p on public.productos (id_categoria_p);

-- Receta: que productos consume cada servicio y en que cantidad estandar
create table public.servicio_producto (
    id_servicio_producto int generated always as identity primary key,
    id_servicio          int not null references public.servicios (id_servicio) on delete cascade,
    id_producto          int not null references public.productos (id_producto),
    cantidad_estandar    numeric(8, 2) not null check (cantidad_estandar > 0),
    unidad_uso           varchar(20),
    estado               boolean not null default true,
    unique (id_servicio, id_producto)
);

create index idx_servicio_producto_id_producto on public.servicio_producto (id_producto);

-- ---------------------------------------------------------------------------
-- AGENDA DE CITAS
-- ---------------------------------------------------------------------------

create table public.citas (
    id_cita       int generated always as identity primary key,
    id_cliente    int not null references public.clientes (id_cliente),
    id_usuario    int references public.usuarios (id_usuario),
    fecha_hora    timestamptz not null,
    estado        varchar(50) not null default 'pendiente'
        check (estado in ('pendiente', 'confirmada', 'en_proceso', 'completado', 'cancelada', 'no_asistio')),
    observaciones text,
    total         numeric(10, 2) not null default 0,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

comment on column public.citas.id_usuario is 'Usuario que gestiona la cita.';
comment on column public.citas.total is 'Calculado por trg_detalle_cita_after_insert.';

create index idx_citas_id_cliente on public.citas (id_cliente);
create index idx_citas_id_usuario on public.citas (id_usuario);
create index idx_citas_fecha_hora on public.citas (fecha_hora);
create index idx_citas_estado on public.citas (estado);

create table public.detalle_cita (
    id_detalle     int generated always as identity primary key,
    id_cita        int not null references public.citas (id_cita) on delete cascade,
    id_servicio    int not null references public.servicios (id_servicio),
    id_profesional int not null references public.profesionales (id_profesional),
    duracion_min   int not null check (duracion_min > 0),
    precio_unit    numeric(10, 2) not null check (precio_unit >= 0),
    subtotal       numeric(10, 2) not null check (subtotal >= 0)
);

create index idx_detalle_cita_id_cita on public.detalle_cita (id_cita);
create index idx_detalle_cita_id_servicio on public.detalle_cita (id_servicio);
create index idx_detalle_cita_id_profesional on public.detalle_cita (id_profesional);

-- ---------------------------------------------------------------------------
-- HISTORIAL DE SERVICIOS PRESTADOS
-- ---------------------------------------------------------------------------

create table public.historial_servicio (
    id_historial      int generated always as identity primary key,
    id_cita           int references public.citas (id_cita),
    id_cliente        int not null references public.clientes (id_cliente),
    id_profesional    int not null references public.profesionales (id_profesional),
    id_servicio       int not null references public.servicios (id_servicio),
    fecha_realizacion date not null default current_date,
    costo_cobrado     numeric(10, 2) not null check (costo_cobrado >= 0),
    observaciones     text,
    created_at        timestamptz not null default now()
);

create index idx_historial_id_cita on public.historial_servicio (id_cita);
create index idx_historial_id_cliente on public.historial_servicio (id_cliente);
create index idx_historial_id_profesional on public.historial_servicio (id_profesional);
create index idx_historial_id_servicio on public.historial_servicio (id_servicio);
create index idx_historial_fecha on public.historial_servicio (fecha_realizacion);

create table public.productos_utilizados (
    id_uso         int generated always as identity primary key,
    id_historial   int not null references public.historial_servicio (id_historial) on delete cascade,
    id_producto    int not null references public.productos (id_producto),
    cantidad_usada numeric(8, 2) not null check (cantidad_usada > 0),
    fecha_uso      timestamptz not null default now()
);

create index idx_productos_utilizados_id_historial on public.productos_utilizados (id_historial);
create index idx_productos_utilizados_id_producto on public.productos_utilizados (id_producto);

-- ---------------------------------------------------------------------------
-- COBROS Y PAGOS
-- ---------------------------------------------------------------------------

create table public.metodos_pago (
    id_metodo int generated always as identity primary key,
    nombre    varchar(50) not null unique,
    estado    boolean not null default true
);

create table public.cobros_cliente (
    id_cobro        int generated always as identity primary key,
    id_cita         int not null references public.citas (id_cita),
    id_metodo_pago  int not null references public.metodos_pago (id_metodo),
    monto           numeric(10, 2) not null check (monto >= 0),
    estado          varchar(50) not null default 'pendiente'
        check (estado in ('pendiente', 'pagado', 'anulado')),
    fecha_pago      timestamptz,
    comprobante_url varchar(255)
);

create index idx_cobros_id_cita on public.cobros_cliente (id_cita);
create index idx_cobros_id_metodo_pago on public.cobros_cliente (id_metodo_pago);

create table public.pagos_profesional (
    id_pago_prof   int generated always as identity primary key,
    id_profesional int not null references public.profesionales (id_profesional),
    id_historial   int not null unique references public.historial_servicio (id_historial) on delete cascade,
    monto          numeric(10, 2) not null check (monto >= 0),
    fecha_liquid   date,
    estado         varchar(50) not null default 'pendiente'
        check (estado in ('pendiente', 'pagado', 'anulado'))
);

comment on column public.pagos_profesional.id_historial is
    'UNIQUE: una sola liquidacion por servicio realizado.';

create index idx_pagos_prof_id_profesional on public.pagos_profesional (id_profesional);

-- ---------------------------------------------------------------------------
-- COMPRAS A PROVEEDORES
-- ---------------------------------------------------------------------------

create table public.proveedores (
    id_proveedor int generated always as identity primary key,
    nombre       varchar(150) not null,
    email        varchar(150),
    telefono     varchar(20),
    direccion    text,
    estado       boolean not null default true
);

create table public.pedidos (
    id_pedido       int generated always as identity primary key,
    id_proveedor    int not null references public.proveedores (id_proveedor),
    id_usuario      int references public.usuarios (id_usuario),
    fecha_pedido    timestamptz not null default now(),
    fecha_recepcion timestamptz,
    estado          varchar(50) not null default 'pendiente'
        check (estado in ('pendiente', 'enviado', 'recibido', 'cancelado')),
    total           numeric(10, 2) not null default 0
);

create index idx_pedidos_id_proveedor on public.pedidos (id_proveedor);
create index idx_pedidos_id_usuario on public.pedidos (id_usuario);
create index idx_pedidos_estado on public.pedidos (estado);

create table public.detalle_pedido (
    id_detalle_pedido int generated always as identity primary key,
    id_pedido         int not null references public.pedidos (id_pedido) on delete cascade,
    id_producto       int not null references public.productos (id_producto),
    cantidad          numeric(12, 2) not null check (cantidad > 0),
    precio_unit       numeric(10, 2) not null check (precio_unit >= 0),
    subtotal          numeric(10, 2) not null check (subtotal >= 0)
);

create index idx_detalle_pedido_id_pedido on public.detalle_pedido (id_pedido);
create index idx_detalle_pedido_id_producto on public.detalle_pedido (id_producto);

create table public.pagos_proveedor (
    id_pago_prov   int generated always as identity primary key,
    id_pedido      int not null references public.pedidos (id_pedido),
    id_metodo_pago int not null references public.metodos_pago (id_metodo),
    monto          numeric(10, 2) not null check (monto >= 0),
    fecha_pago     timestamptz,
    estado         varchar(50) not null default 'pendiente'
        check (estado in ('pendiente', 'pagado', 'anulado'))
);

create index idx_pagos_prov_id_pedido on public.pagos_proveedor (id_pedido);
create index idx_pagos_prov_id_metodo_pago on public.pagos_proveedor (id_metodo_pago);

-- ---------------------------------------------------------------------------
-- MOVIMIENTOS Y ALERTAS DE INVENTARIO
-- ---------------------------------------------------------------------------

create table public.movimientos_inventario (
    id_movimiento int generated always as identity primary key,
    id_producto   int not null references public.productos (id_producto),
    id_usuario    int references public.usuarios (id_usuario),
    tipo          varchar(20) not null check (tipo in ('entrada', 'salida', 'ajuste')),
    cantidad      numeric(12, 2) not null check (cantidad > 0),
    motivo        text,
    fecha         timestamptz not null default now()
);

create index idx_movimientos_id_producto on public.movimientos_inventario (id_producto);
create index idx_movimientos_fecha on public.movimientos_inventario (fecha);

create table public.alertas_stock (
    id_alerta    int generated always as identity primary key,
    id_producto  int not null references public.productos (id_producto),
    stock_actual numeric(12, 2) not null,
    stock_minimo numeric(12, 2) not null,
    fecha_alerta timestamptz not null default now(),
    resuelta     boolean not null default false
);

create index idx_alertas_id_producto on public.alertas_stock (id_producto);
create index idx_alertas_pendientes on public.alertas_stock (id_producto) where not resuelta;

-- ---------------------------------------------------------------------------
-- NOTIFICACIONES, RECOMENDACIONES Y AUDITORIA
-- ---------------------------------------------------------------------------

create table public.notificaciones (
    id_notificacion int generated always as identity primary key,
    id_cita         int references public.citas (id_cita),
    id_usuario      int references public.usuarios (id_usuario),
    tipo            varchar(50),
    mensaje         text,
    email_destino   varchar(150),
    estado_envio    varchar(50) not null default 'pendiente',
    fecha_envio     timestamptz,
    proveedor       varchar(50)
);

comment on column public.notificaciones.proveedor is 'Servicio de envio utilizado (ej: Resend, SendGrid).';

create index idx_notificaciones_id_cita on public.notificaciones (id_cita);
create index idx_notificaciones_id_usuario on public.notificaciones (id_usuario);

create table public.recomendaciones_ml (
    id_recomendacion int generated always as identity primary key,
    id_cliente       int not null references public.clientes (id_cliente) on delete cascade,
    id_servicio      int not null references public.servicios (id_servicio),
    score_relevancia numeric(5, 4) not null check (score_relevancia >= 0 and score_relevancia <= 1),
    algoritmo        varchar(50),
    fecha_generacion timestamptz not null default now()
);

create index idx_recomendaciones_id_cliente on public.recomendaciones_ml (id_cliente);
create index idx_recomendaciones_id_servicio on public.recomendaciones_ml (id_servicio);

create table public.auditoria (
    id_auditoria   int generated always as identity primary key,
    id_usuario     int references public.usuarios (id_usuario),
    tabla_afectada varchar(50) not null,
    accion         varchar(20) not null check (accion in ('INSERT', 'UPDATE', 'DELETE')),
    registro_id    int,
    detalle        text,
    fecha_accion   timestamptz not null default now()
);

create index idx_auditoria_id_usuario on public.auditoria (id_usuario);
create index idx_auditoria_tabla on public.auditoria (tabla_afectada);
create index idx_auditoria_fecha on public.auditoria (fecha_accion);
