-- ============================================================================
-- COMPROBANTE INTERNO DE VENTA (FACTURAS) Y AJUSTES MENORES
--
-- Tres cambios, ninguno toca las 13 migraciones anteriores:
--
--   1. cobros_cliente.estado admite 'parcial'. El frontend (ESTADOS_COBRO en
--      packages/tipos/src/base-datos.ts y RN-025) ya lo esperaba; el CHECK de
--      la base se habia quedado en pendiente/pagado/anulado.
--   2. Tablas FACTURAS y DETALLE_FACTURA: comprobante interno de venta, sin
--      integracion con SIFEN/timbrado (decision del equipo, fuera del alcance
--      del TCC). Se emite desde un cobro ya registrado. No tiene CU propio en
--      el documento v4 -se agrega como CU-025 en un anexo aparte del
--      documento-, asi que sigue el mismo patron de PEDIDOS/DETALLE_PEDIDO:
--      cabecera + detalle, auditoria temporal completa y borrado logico
--      (es un documento que puede cargarse por error, mismo criterio que
--      COBROS_CLIENTE).
--   3. Dos comentarios de vista en 20260817002000_vistas_ampliadas.sql citaban
--      mal su caso de uso: la de proveedores decia CU-011 (que es "Registrar
--      Productos Utilizados en Servicio", no tiene nada que ver) y deberia
--      decir CU-016; la de auditoria decia CU-022 (que es "Consultar
--      Informacion de Inventario") y el documento no le asigna ningun CU a la
--      auditoria. Se corrigen con `comment on view`, sin recrear la vista.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. cobros_cliente: habilitar el estado 'parcial' (RN-025)
-- ---------------------------------------------------------------------------
alter table public.cobros_cliente drop constraint if exists cobros_cliente_estado_check;

alter table public.cobros_cliente add constraint cobros_cliente_estado_check
    check (estado in ('pendiente', 'parcial', 'pagado', 'anulado'));

comment on column public.cobros_cliente.estado is
    'CU-008. RN-025 habilita "parcial": el saldo queda pendiente hasta un cobro posterior.';

-- ---------------------------------------------------------------------------
-- 2. FACTURAS y DETALLE_FACTURA
-- ---------------------------------------------------------------------------
create table public.facturas (
    id_factura   int generated always as identity primary key,
    id_cliente   int not null references public.clientes (id_cliente),
    id_cita      int not null references public.citas (id_cita),
    id_cobro     int references public.cobros_cliente (id_cobro),
    fecha_emision timestamptz not null default now(),
    subtotal     numeric(10, 2) not null check (subtotal >= 0),
    total        numeric(10, 2) not null check (total >= 0),
    estado       varchar(20) not null default 'emitida'
        check (estado in ('emitida', 'anulada')),
    observaciones text,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    deleted      boolean not null default false,
    deleted_at   timestamptz,
    deleted_user_id int references public.usuarios (id_usuario)
);

comment on table public.facturas is
    'CU-025 (anexo, sin numero en el documento v4). Comprobante interno de '
    'venta emitido desde un cobro. Sin integracion con SIFEN: no reemplaza '
    'una factura legal paraguaya.';
comment on column public.facturas.id_cobro is
    'Cobro que origino la factura. Nullable: permite reconstruir el vinculo '
    'aunque el cobro se anule despues.';

create index idx_facturas_id_cliente on public.facturas (id_cliente);
create index idx_facturas_id_cita on public.facturas (id_cita);
create index idx_facturas_id_cobro on public.facturas (id_cobro);
create index if not exists idx_facturas_deleted on public.facturas (deleted) where deleted;

create table public.detalle_factura (
    id_detalle_factura int generated always as identity primary key,
    id_factura      int not null references public.facturas (id_factura) on delete cascade,
    descripcion     varchar(200) not null,
    cantidad        numeric(8, 2) not null default 1 check (cantidad > 0),
    precio_unitario numeric(10, 2) not null check (precio_unitario >= 0),
    subtotal        numeric(10, 2) not null check (subtotal >= 0),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

comment on table public.detalle_factura is
    'Lineas de una factura: un servicio o producto por fila, copiados desde '
    'detalle_cita al momento de emitir. No se recalculan si el turno cambia.';

create index idx_detalle_factura_id_factura on public.detalle_factura (id_factura);

-- Disparadores ya existentes, solo se enganchan (mismo patron que el resto).
create trigger trg_facturas_updated_at
    before update on public.facturas
    for each row
    execute function public.fn_set_updated_at();

create trigger trg_facturas_borrado
    before update on public.facturas
    for each row
    execute function public.fn_set_deleted_at();

create trigger trg_detalle_factura_updated_at
    before update on public.detalle_factura
    for each row
    execute function public.fn_set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: mismo criterio que cobros_cliente / historial_servicio.
--   Administrador   : acceso total.
--   Recepcionista   : opera (emite y consulta).
--   Profesional     : solo lectura, y solo de facturas de citas donde
--                     participo (join con detalle_cita, una cita puede tener
--                     mas de un profesional).
--   Cliente         : sin politica -> sin acceso, igual que el resto del
--                     sistema (rol reservado, sin portal).
-- ---------------------------------------------------------------------------
alter table public.facturas enable row level security;
alter table public.detalle_factura enable row level security;

create policy "admin_total" on public.facturas
    for all to authenticated
    using (public.fn_es_admin()) with check (public.fn_es_admin());

create policy "recepcion_opera" on public.facturas
    for all to authenticated
    using (public.fn_rol_actual() = 'recepcionista')
    with check (public.fn_rol_actual() = 'recepcionista');

create policy "profesional_ve_lo_suyo" on public.facturas
    for select to authenticated
    using (exists (
        select 1 from public.detalle_cita d
        where d.id_cita = facturas.id_cita
          and d.id_profesional = public.fn_id_profesional_actual()
    ));

create policy "admin_total" on public.detalle_factura
    for all to authenticated
    using (public.fn_es_admin()) with check (public.fn_es_admin());

create policy "recepcion_opera" on public.detalle_factura
    for all to authenticated
    using (public.fn_rol_actual() = 'recepcionista')
    with check (public.fn_rol_actual() = 'recepcionista');

create policy "profesional_ve_lo_suyo" on public.detalle_factura
    for select to authenticated
    using (exists (
        select 1 from public.facturas f
        join public.detalle_cita d on d.id_cita = f.id_cita
        where f.id_factura = detalle_factura.id_factura
          and d.id_profesional = public.fn_id_profesional_actual()
    ));

-- ---------------------------------------------------------------------------
-- 3. Corregir dos comentarios de vista mal citados (no se recrean las vistas)
-- ---------------------------------------------------------------------------
comment on view public.v_compras_por_proveedor is
    'CU-016. Volumen y frecuencia de compra por proveedor.';

comment on view public.v_auditoria_detalle is
    'Registro de auditoria con el usuario y su rol resueltos. Transversal: '
    'el documento de casos de uso no le asigna un CU propio.';
