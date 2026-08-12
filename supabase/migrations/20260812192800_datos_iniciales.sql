-- ============================================================================
-- DATOS INICIALES
--
-- Solo catalogos base sin los cuales el sistema no arranca. Idempotente:
-- volver a ejecutarlo no duplica filas.
-- ============================================================================

insert into public.roles (nombre, descripcion) values
    ('administrador', 'Acceso total al sistema'),
    ('recepcionista',  'Gestiona agenda, clientes y cobros'),
    ('profesional',    'Consulta su agenda y registra servicios realizados'),
    ('cliente',        'Consulta sus turnos e historial')
on conflict (nombre) do nothing;

insert into public.metodos_pago (nombre) values
    ('Efectivo'),
    ('Tarjeta de debito'),
    ('Tarjeta de credito'),
    ('Transferencia bancaria'),
    ('Billetera electronica')
on conflict (nombre) do nothing;
