-- =============================================================================
-- Carga completa de prueba (18/10/2026) · Parte 1: borrado y base
-- =============================================================================
-- Pausa los recordatorios por correo, borra todos los datos de prueba (quedan
-- roles, configuracion, horarios, metodos de pago y las cuentas), y carga el
-- catalogo, los barberos y los clientes. La operacion de los seis meses la
-- genera la parte 2, dia por dia.
-- =============================================================================

select cron.alter_job(jobid, active := false) from cron.job where jobname = 'recordatorios-turnos';

truncate table
  public.alertas_stock, public.auditoria, public.valoraciones, public.recomendaciones_ml,
  public.notificaciones, public.detalle_factura, public.facturas, public.cobros_cliente,
  public.productos_utilizados, public.pagos_profesional, public.historial_servicio,
  public.detalle_cita, public.citas, public.pagos_proveedor, public.detalle_pedido, public.pedidos,
  public.movimientos_inventario, public.servicio_producto, public.servicios, public.categorias_servicio,
  public.productos, public.categorias_producto, public.proveedores, public.profesionales, public.clientes
  restart identity cascade;

-- La barberia
update public.configuracion_sistema set
  nombre_barberia = 'Barber Shop', ruc = '80123456-7', direccion = 'Av. Mariscal López 1520, Asunción',
  telefono = '021 600 200', email = 'contacto@barbershop.com.py'
where id_configuracion = 1;

-- Cuentas: corregir el nombre de Angel ("Angek") y dar de alta las nuevas.
update public.usuarios set nombre = 'Angel Rolón' where email = 'CORREO_ANGEL@gmail.com';
insert into public.usuarios (id_rol, auth_uid, nombre, email)
select r.id_rol, c.uid::uuid, c.nombre, c.email
from (values
__CUENTAS__
) as c(email, nombre, rol, uid)
join public.roles r on r.nombre = c.rol
where not exists (select 1 from public.usuarios u where u.email = c.email);

-- ---------------------------------------------------------------------------
-- Esquema auxiliar (se borra al final de la parte 4)
-- ---------------------------------------------------------------------------
drop schema if exists carga_demo cascade;
create schema carga_demo;

create table carga_demo.personal (rol text, id_usuario int, uid uuid, n int);
insert into carga_demo.personal
select r.nombre, u.id_usuario, u.auth_uid, row_number() over (partition by r.nombre order by u.id_usuario)
from public.usuarios u join public.roles r using (id_rol)
where r.nombre in ('administrador', 'recepcionista');

create table carga_demo.barbero (
  n int primary key, id_profesional int, nombre text, email text, tipo text, especialidad text,
  comision numeric, pop numeric, libre int, solo_dias int[], desde date, hasta date, calidad numeric, fuerte text
);
insert into carga_demo.barbero (n, nombre, email, tipo, especialidad, comision, pop, libre, solo_dias, desde, hasta, calidad, fuerte) values
  (1,  'Marcos Ayala',     'barbero@barbershop.com.py',            'barbero senior', 'Degradados y diseños',         40, 1.35, null, null,      '2025-01-10', null,         4.7, 'Cortes'),
  (2,  'Angel Rolón',      'CORREO_ANGEL+barbero@gmail.com',      'barbero',        'Cortes clásicos y a tijera',    35, 1.10, 3,    null,      '2025-03-01', null,         4.5, 'Cortes'),
  (3,  'William Giménez',  'CORREO_WILLIAM+barbero@gmail.com',   'barbero',        'Barba y afeitado',              35, 1.10, 4,    null,      '2025-03-01', null,         4.5, 'Barba'),
  (4,  'Diego Rojas',      'diego.rojas@prueba.barbershop.com.py', 'barbero',        'Degradados y diseño',           35, 1.15, 4,    null,      '2025-02-15', null,         4.4, 'Cortes'),
  (5,  'Fabián Ortiz',     'fabian.ortiz@prueba.barbershop.com.py','barbero senior', 'Barba y afeitado tradicional',  40, 1.25, 2,    null,      '2024-11-01', null,         4.6, 'Barba'),
  (6,  'Luis Cabrera',     'luis.cabrera@prueba.barbershop.com.py','barbero',        'Cortes a tijera',               35, 1.00, 5,    null,      '2025-04-01', null,         4.3, 'Cortes'),
  (7,  'Ramón Ferreira',   'ramon.ferreira@prueba.barbershop.com.py','especialista', 'Color y tratamientos',          45, 0.70, 1,    null,      '2025-06-01', null,         4.6, 'Tratamientos'),
  (8,  'Julio Aquino',     'julio.aquino@prueba.barbershop.com.py','barbero',        'Cortes infantiles',             30, 0.85, 3,    null,      '2025-08-01', null,         4.2, 'Niños'),
  (9,  'Matías González',  'matias.gonzalez@prueba.barbershop.com.py','barbero',     'Degradados',                    30, 0.90, 4,    null,      '2026-06-01', null,         4.1, 'Cortes'),
  (10, 'Hernán Villalba',  'hernan.villalba@prueba.barbershop.com.py','barbero',     'Cortes y barba',                30, 0.75, 2,    null,      '2026-08-01', null,         3.9, 'Combos'),
  (11, 'Néstor Cáceres',   null,                                   'externo',        'Combos de fin de semana',       50, 0.90, null, '{5,6}',   '2025-09-01', null,         4.3, 'Combos'),
  (12, 'Pablo Duarte',     null,                                   'barbero',        'Cortes',                        30, 0.90, 1,    null,      '2025-05-01', '2026-09-05', 4.0, 'Cortes');

insert into public.profesionales (id_usuario, nombre, especialidad, tipo, porcentaje_com, created_at)
select u.id_usuario, b.nombre, b.especialidad, b.tipo, b.comision, b.desde
from carga_demo.barbero b left join public.usuarios u on u.email = b.email
order by b.n;
update carga_demo.barbero b set id_profesional = p.id_profesional
from public.profesionales p where p.nombre = b.nombre;

-- ---------------------------------------------------------------------------
-- Catalogo de servicios (precios vigentes; antes de agosto, 10 % menos)
-- ---------------------------------------------------------------------------
insert into public.categorias_servicio (nombre, descripcion, created_at) values
  ('Cortes', 'Cortes de cabello para adultos', '2025-01-05'),
  ('Barba', 'Perfilado, afeitado y cuidado de la barba', '2025-01-05'),
  ('Combos', 'Corte y barba en un mismo turno', '2025-01-05'),
  ('Tratamientos', 'Cuidado de la piel y del cabello', '2025-01-05'),
  ('Niños', 'Cortes para chicos hasta 12 años', '2025-01-05');

create table carga_demo.servicio (n int primary key, id_servicio int, categoria text, nombre text, descripcion text, dur int, precio numeric, peso numeric, hasta date);
insert into carga_demo.servicio (n, categoria, nombre, descripcion, dur, precio, peso, hasta) values
  (1,  'Cortes', 'Corte clásico', 'Corte con máquina y tijera, terminación a navaja', 30, 50000, 10, null),
  (2,  'Cortes', 'Corte degradado', 'Fade bajo, medio o alto', 40, 60000, 12, null),
  (3,  'Cortes', 'Corte a tijera', 'Corte completo a tijera para pelo largo', 45, 65000, 4, null),
  (4,  'Cortes', 'Corte con lavado', 'Corte clásico con lavado y secado', 45, 60000, 5, null),
  (5,  'Cortes', 'Rapado a máquina', 'Rapado parejo con un solo número', 20, 35000, 4, null),
  (6,  'Barba', 'Perfilado de barba', 'Contorno y largo parejo', 20, 40000, 8, null),
  (7,  'Barba', 'Afeitado tradicional', 'Toalla caliente, navaja y bálsamo', 30, 55000, 6, null),
  (8,  'Barba', 'Barba con diseño', 'Perfilado con líneas y degradado', 30, 50000, 4, null),
  (9,  'Barba', 'Barba con toalla caliente', 'Ritual completo con aceites', 35, 60000, 3, null),
  (10, 'Combos', 'Corte y barba', 'Corte a elección y perfilado de barba', 55, 85000, 12, null),
  (11, 'Combos', 'Corte, barba y lavado', 'El combo con lavado y masaje capilar', 70, 100000, 4, null),
  (12, 'Combos', 'Combo premium', 'Corte, barba, mascarilla negra y toalla caliente', 90, 130000, 2, null),
  (13, 'Tratamientos', 'Mascarilla facial negra', 'Limpieza de poros con mascarilla peel-off', 20, 45000, 2, null),
  (14, 'Tratamientos', 'Lavado y masaje capilar', 'Lavado con masaje de cuero cabelludo', 25, 40000, 3, null),
  (15, 'Tratamientos', 'Tratamiento anticaspa', 'Shampoo y ampolla anticaspa', 30, 70000, 2, null),
  (16, 'Tratamientos', 'Alisado con keratina', 'Alisado progresivo para pelo rebelde', 90, 180000, 1, null),
  (17, 'Tratamientos', 'Tinte de barba', 'Cubre canas en la barba', 30, 60000, 1, null),
  (18, 'Tratamientos', 'Tinte completo', 'Color en todo el cabello', 60, 120000, 1, '2026-08-15'),
  (19, 'Niños', 'Corte infantil', 'Para chicos hasta 12 años', 25, 40000, 5, null),
  (20, 'Niños', 'Corte infantil con diseño', 'Con líneas o figuras', 35, 50000, 2, null);

insert into public.servicios (id_categoria, nombre, descripcion, duracion_min, precio_base, created_at)
select c.id_categoria, s.nombre, s.descripcion, s.dur, s.precio, '2025-01-05'
from carga_demo.servicio s join public.categorias_servicio c on c.nombre = s.categoria order by s.n;
update carga_demo.servicio s set id_servicio = x.id_servicio from public.servicios x where x.nombre = s.nombre;

-- ---------------------------------------------------------------------------
-- Proveedores y productos (stock en la unidad de uso)
-- ---------------------------------------------------------------------------
insert into public.proveedores (nombre, email, telefono, direccion, created_at) values
  ('Distribuidora Capilar SA', 'ventas@capilar.com.py', '021 555 100', 'Av. Eusebio Ayala 2340, Asunción', '2025-01-08'),
  ('Barba & Co Importaciones', 'pedidos@barbayco.com.py', '021 555 210', 'Av. España 1180, Asunción', '2025-01-08'),
  ('Estilo Fijo SRL', 'contacto@estilofijo.com.py', '021 555 330', 'Ruta Mcal. Estigarribia km 9, San Lorenzo', '2025-02-01'),
  ('Afeitar Py', 'ventas@afeitarpy.com.py', '021 555 440', 'Calle Palma 455, Asunción', '2025-02-01'),
  ('Color Pro Paraguay', 'info@colorpro.com.py', '021 555 550', 'Av. Santa Teresa 3020, Asunción', '2025-05-20'),
  ('Higiene Total SA', 'ventas@higienetotal.com.py', '021 555 660', 'Av. Artigas 1999, Asunción', '2025-01-08'),
  ('Dermocosmética del Este', 'pedidos@dermoeste.com.py', '061 520 770', 'Av. San Blas 210, Ciudad del Este', '2025-07-01'),
  ('Accesorios Barber Py', 'hola@accesoriosbarber.com.py', '0981 555 880', 'Mercado 4, puesto 112, Asunción', '2025-09-15');

insert into public.categorias_producto (nombre, descripcion, created_at) values
  ('Cuidado del cabello', 'Shampoo, acondicionador y tónicos', '2025-01-05'),
  ('Barba', 'Aceites, bálsamos y tintes para barba', '2025-01-05'),
  ('Peinado y fijación', 'Ceras, geles y pomadas', '2025-01-05'),
  ('Afeitado', 'Hojas, cremas y lociones', '2025-01-05'),
  ('Higiene y descartables', 'Lo que se usa y se tira en cada turno', '2025-01-05'),
  ('Tratamientos', 'Mascarillas, ampollas y sérums', '2025-01-05');

create table carga_demo.producto (n int primary key, id_producto int, categoria text, nombre text, um text, uu text, equiv numeric, precio numeric, minimo numeric, maximo numeric, inicial numeric, proveedor int, no_reponer_desde date, no_reponer_hasta date);
insert into carga_demo.producto (n, categoria, nombre, um, uu, equiv, precio, minimo, maximo, inicial, proveedor, no_reponer_desde) values
  (1,  'Cuidado del cabello', 'Shampoo profesional 1 L', 'frasco', 'ml', 1000, 85000, 1500, 6000, 4500, 1, null),
  (2,  'Cuidado del cabello', 'Shampoo anticaspa 500 ml', 'frasco', 'ml', 500, 52000, 500, 3000, 2000, 1, null),
  (3,  'Cuidado del cabello', 'Acondicionador 1 L', 'frasco', 'ml', 1000, 78000, 1000, 5000, 3500, 1, null),
  (4,  'Cuidado del cabello', 'Mascarilla capilar 500 g', 'pote', 'g', 500, 95000, 300, 2000, 1500, 1, null),
  (5,  'Cuidado del cabello', 'Tónico capilar 250 ml', 'frasco', 'ml', 250, 70000, 250, 1250, 1000, 1, null),
  (6,  'Cuidado del cabello', 'Tinte negro 60 ml', 'tubo', 'ml', 60, 38000, 120, 600, 480, 5, null),
  (7,  'Cuidado del cabello', 'Oxidante 20 vol 1 L', 'frasco', 'ml', 1000, 45000, 500, 3000, 2000, 5, null),
  (8,  'Tratamientos', 'Keratina 1 L', 'frasco', 'ml', 1000, 320000, 300, 2000, 1200, 5, null),
  (9,  'Barba', 'Aceite para barba 30 ml', 'frasco', 'ml', 30, 65000, 60, 360, 270, 2, '2026-10-01'),
  (10, 'Barba', 'Bálsamo para barba 50 g', 'pote', 'g', 50, 58000, 100, 500, 400, 2, null),
  (11, 'Barba', 'Shampoo para barba 250 ml', 'frasco', 'ml', 250, 60000, 250, 1250, 1000, 2, null),
  (12, 'Barba', 'Tinte para barba (kit x6)', 'kit', 'aplicación', 6, 90000, 6, 36, 24, 5, null),
  (13, 'Barba', 'Cera para bigote 15 g', 'pote', 'g', 15, 35000, 15, 90, 60, 2, null),
  (14, 'Peinado y fijación', 'Cera modeladora mate 100 g', 'pote', 'g', 100, 45000, 300, 1500, 1100, 3, null),
  (15, 'Peinado y fijación', 'Gel fijador fuerte 250 ml', 'pote', 'ml', 250, 28000, 500, 2500, 1800, 3, '2026-06-08'),
  (16, 'Peinado y fijación', 'Pomada brillante 100 g', 'pote', 'g', 100, 52000, 200, 1000, 700, 3, null),
  (17, 'Peinado y fijación', 'Spray fijador 400 ml', 'lata', 'ml', 400, 40000, 400, 2400, 1600, 3, null),
  (18, 'Peinado y fijación', 'Polvo texturizador 20 g', 'frasco', 'g', 20, 55000, 20, 120, 80, 3, null),
  (19, 'Afeitado', 'Hojas de afeitar caja x100', 'caja', 'unidad', 100, 38000, 150, 800, 600, 4, '2026-10-05'),
  (20, 'Afeitado', 'Crema de afeitar 500 ml', 'pote', 'ml', 500, 48000, 500, 3000, 2200, 4, '2026-08-10'),
  (21, 'Afeitado', 'Gel de afeitar transparente 1 L', 'frasco', 'ml', 1000, 62000, 600, 3000, 2200, 4, null),
  (22, 'Afeitado', 'Loción after shave 200 ml', 'frasco', 'ml', 200, 42000, 300, 1600, 1200, 4, null),
  (23, 'Afeitado', 'Alumbre en bloque', 'unidad', 'unidad', 1, 25000, 2, 10, 6, 4, null),
  (24, 'Afeitado', 'Talco mentolado 100 g', 'frasco', 'g', 100, 18000, 300, 1500, 1000, 4, null),
  (25, 'Higiene y descartables', 'Cuellos descartables x100', 'paquete', 'unidad', 100, 22000, 300, 1500, 1100, 6, null),
  (26, 'Higiene y descartables', 'Capas descartables x50', 'paquete', 'unidad', 50, 35000, 250, 1200, 900, 6, '2026-07-13'),
  (27, 'Higiene y descartables', 'Toallas descartables x100', 'paquete', 'unidad', 100, 40000, 150, 800, 600, 6, null),
  (28, 'Higiene y descartables', 'Guantes de nitrilo x100', 'caja', 'unidad', 100, 45000, 50, 400, 300, 6, null),
  (29, 'Higiene y descartables', 'Alcohol 70 % 1 L', 'frasco', 'ml', 1000, 18000, 1500, 8000, 6000, 6, null),
  (30, 'Higiene y descartables', 'Desinfectante para máquinas 400 ml', 'lata', 'ml', 400, 39000, 400, 2400, 1600, 6, null),
  (31, 'Higiene y descartables', 'Algodón 500 g', 'paquete', 'g', 500, 21000, 250, 1500, 1000, 6, null),
  (32, 'Higiene y descartables', 'Papel toalla (rollo)', 'rollo', 'unidad', 1, 12000, 4, 24, 16, 6, null),
  (33, 'Tratamientos', 'Mascarilla negra peel-off 120 g', 'tubo', 'g', 120, 55000, 120, 720, 480, 7, null),
  (34, 'Tratamientos', 'Exfoliante facial 200 ml', 'frasco', 'ml', 200, 60000, 200, 1000, 600, 7, null),
  (35, 'Tratamientos', 'Crema hidratante facial 100 ml', 'pote', 'ml', 100, 70000, 100, 600, 400, 7, null),
  (36, 'Tratamientos', 'Ampollas anticaída (caja x12)', 'caja', 'unidad', 12, 110000, 12, 72, 48, 7, null),
  (37, 'Tratamientos', 'Champú anticaída 300 ml', 'frasco', 'ml', 300, 75000, 300, 1500, 900, 7, null),
  (38, 'Tratamientos', 'Sérum capilar 100 ml', 'frasco', 'ml', 100, 85000, 100, 500, 300, 7, null),
  (39, 'Peinado y fijación', 'Peine de bolsillo', 'unidad', 'unidad', 1, 8000, 10, 60, 30, 8, '2026-04-01'),
  (40, 'Barba', 'Cepillo de barba', 'unidad', 'unidad', 1, 45000, 3, 20, 10, 8, null);

insert into public.productos (id_categoria_p, nombre, descripcion, unidad_medida, unidad_uso, cantidad_uso_estandar,
                              precio_unitario, stock_minimo, stock_maximo, stock_actual, created_at)
select c.id_categoria_p, p.nombre, null, p.um, p.uu, p.equiv, p.precio, p.minimo, p.maximo, p.inicial, '2025-01-05'
from carga_demo.producto p join public.categorias_producto c on c.nombre = p.categoria order by p.n;
update carga_demo.producto p set id_producto = x.id_producto from public.productos x where x.nombre = p.nombre;
-- Las tres pausas temporales (el proveedor no entrego): generan alertas que despues se resuelven.
update carga_demo.producto set no_reponer_hasta = case n when 15 then date '2026-06-29' when 20 then date '2026-08-31' when 26 then date '2026-07-27' end
where n in (15, 20, 26);

-- El stock con el que arranca el periodo, como un movimiento de entrada.
insert into public.movimientos_inventario (id_producto, id_usuario, tipo, cantidad, motivo, fecha, created_at)
select p.id_producto, (select id_usuario from carga_demo.personal where rol = 'administrador' and n = 1),
       'entrada', p.inicial, 'Inventario inicial del período', '2026-04-17 18:00-03', '2026-04-17 18:00-03'
from carga_demo.producto p;

-- Recetas: que consume cada servicio, en la unidad de uso.
create table carga_demo.receta (servicio int, producto int, cantidad numeric);
insert into carga_demo.receta values
  (1, 25, 1), (1, 26, 1), (1, 15, 10), (1, 29, 5),
  (2, 25, 1), (2, 26, 1), (2, 14, 5), (2, 29, 5), (2, 24, 3),
  (3, 25, 1), (3, 26, 1), (3, 16, 4),
  (4, 25, 1), (4, 26, 1), (4, 1, 15), (4, 3, 10),
  (5, 25, 1), (5, 29, 5),
  (6, 19, 1), (6, 9, 2), (6, 21, 10),
  (7, 19, 1), (7, 20, 15), (7, 22, 5), (7, 27, 2),
  (8, 19, 1), (8, 9, 2), (8, 21, 10),
  (9, 27, 3), (9, 19, 1), (9, 10, 3), (9, 9, 2),
  (10, 25, 1), (10, 26, 1), (10, 19, 1), (10, 9, 2), (10, 14, 5),
  (11, 25, 1), (11, 26, 1), (11, 19, 1), (11, 1, 15), (11, 9, 2),
  (12, 25, 1), (12, 26, 1), (12, 19, 1), (12, 33, 15), (12, 9, 2), (12, 35, 5), (12, 27, 2),
  (13, 33, 20), (13, 31, 5), (13, 35, 5),
  (14, 1, 15), (14, 5, 5),
  (15, 2, 20), (15, 36, 1),
  (16, 8, 80), (16, 28, 2),
  (17, 12, 1), (17, 28, 2),
  (18, 6, 60), (18, 7, 60), (18, 28, 2),
  (19, 25, 1), (19, 26, 1), (19, 15, 5),
  (20, 25, 1), (20, 26, 1), (20, 15, 5);

insert into public.servicio_producto (id_servicio, id_producto, cantidad_estandar, unidad_uso, created_at)
select s.id_servicio, p.id_producto, r.cantidad, p.uu, '2025-01-05'
from carga_demo.receta r
join carga_demo.servicio s on s.n = r.servicio
join carga_demo.producto p on p.n = r.producto;

-- ---------------------------------------------------------------------------
-- Clientes: 28 con cuenta y 172 sin cuenta
-- ---------------------------------------------------------------------------
create table carga_demo.cliente (id_cliente int primary key, peso numeric, barbero int, desde date, con_cuenta bool, id_usuario int);

select setseed(0.2026);

-- Con cuenta: los de prueba, Angel, William y los 25 nuevos.
with cuentas as (
  select u.id_usuario, u.nombre, u.email, (row_number() over (order by u.id_usuario))::int i
  from public.usuarios u join public.roles r using (id_rol)
  where r.nombre = 'cliente'
), insertados as (
  insert into public.clientes (id_usuario, nombre, email, telefono, direccion, fecha_nacimiento, fecha_registro, created_at)
  select c.id_usuario,
         case c.email when 'cliente@correo.com.py' then 'Rodrigo Benítez' else c.nombre end,
         c.email,
         '09' || (array['81','82','83','84','85','86','71','72','73','61','76','91','92','94','95'])[1 + (c.i % 15)]
           || ' ' || lpad((100 + (c.i * 37) % 900)::text, 3, '0') || ' ' || lpad((100 + (c.i * 91) % 900)::text, 3, '0'),
         (array['Villa Morra, Asunción','Sajonia, Asunción','Barrio Obrero, Asunción','San Lorenzo Centro','Fernando de la Mora','Lambaré','Luque','Mariano Roque Alonso'])[1 + (c.i % 8)],
         date '1975-01-01' + ((c.i * 523) % 12000),
         case when c.email in ('cliente@correo.com.py','CORREO_ANGEL@gmail.com','CORREO_WILLIAM+cliente@gmail.com')
              then timestamptz '2026-04-05 10:00-03'
              else timestamptz '2025-06-01 10:00-03' + ((c.i * 13) % 480) * interval '1 day' end,
         case when c.email in ('cliente@correo.com.py','CORREO_ANGEL@gmail.com','CORREO_WILLIAM+cliente@gmail.com')
              then timestamptz '2026-04-05 10:00-03'
              else timestamptz '2025-06-01 10:00-03' + ((c.i * 13) % 480) * interval '1 day' end
  from cuentas c
  returning id_cliente, id_usuario, email, fecha_registro
)
insert into carga_demo.cliente (id_cliente, peso, barbero, desde, con_cuenta, id_usuario)
select i.id_cliente,
       case when i.email in ('cliente@correo.com.py','CORREO_ANGEL@gmail.com','CORREO_WILLIAM+cliente@gmail.com') then 10
            else 4 + floor(random() * 6) end,
       case i.email when 'cliente@correo.com.py' then 1 when 'CORREO_ANGEL@gmail.com' then 4
                    when 'CORREO_WILLIAM+cliente@gmail.com' then 5 else 1 + floor(random() * 10)::int end,
       i.fecha_registro::date, true, i.id_usuario
from insertados i;

-- Sin cuenta: nombres combinados, sin repetir.
create temp table nombres_gen on commit drop as
with n as (select unnest(array['Juan','Carlos','José','Luis','Miguel','Jorge','Pedro','Ricardo','Daniel','Alberto','Sergio','Raúl',
  'Víctor','Hugo','Gustavo','Enrique','Mario','Óscar','Roberto','Fernando','Diego','Pablo','Rodrigo','Martín','Gabriel',
  'Francisco','Antonio','Héctor','Rubén','Arnaldo','César','Derlis','Édgar','Fabio','Germán','Ignacio','Joel','Kevin',
  'Leonardo','Nelson','Osvaldo','Ramiro','Santiago','Walter','Elías','Lorenzo','Benjamín','Thiago','Mateo','Joaquín',
  'Lautaro','Valentín','Bautista','Hernán','Cristhian','Adrián','Aníbal','Blas','Celso','Darío']) nombre),
a as (select unnest(array['González','Benítez','Martínez','López','Giménez','Vera','Duarte','Ramírez','Rojas','Fernández',
  'Acosta','Ortiz','Cáceres','Villalba','Báez','Cabrera','Aquino','Núñez','Sosa','Paredes','Insfrán','Ayala','Franco',
  'Riquelme','Cardozo','Florentín','Galeano','Escobar','Zárate','Sanabria','Delgado','Ríos','Medina','Ocampo','Alonso',
  'Espínola','Brítez','Céspedes','Garcete','Amarilla','Leguizamón','Penayo','Samaniego','Torres','Coronel']) apellido)
select distinct on (completo) completo, nombre, apellido from (
  select n.nombre, a.apellido, n.nombre || ' ' || a.apellido
         || case when random() < 0.5 then ' ' || (select a2.apellido from a a2 where a2.apellido <> a.apellido order by random() limit 1) else '' end completo
  from n cross join a order by random() limit 400
) x;

with elegidos as (
  select completo, nombre, apellido, row_number() over (order by random()) i from nombres_gen
  where completo not in (select nombre from public.clientes) limit 172
), insertados as (
  insert into public.clientes (id_usuario_reg, nombre, email, telefono, direccion, fecha_nacimiento, notas_internas, fecha_registro, created_at)
  select (select id_usuario from carga_demo.personal where rol = 'recepcionista' order by random() limit 1),
         e.completo,
         case when random() < 0.75 then
           translate(lower(e.nombre || '.' || e.apellido), 'áéíóúñü', 'aeiounu') || e.i || '@correo.com.py' end,
         '09' || (array['81','82','83','84','85','86','71','72','73','61','76','91','92','94','95'])[1 + floor(random() * 15)::int]
           || ' ' || lpad((100 + floor(random() * 900))::text, 3, '0') || ' ' || lpad((100 + floor(random() * 900))::text, 3, '0'),
         case when random() < 0.7 then (array['Villa Morra, Asunción','Sajonia, Asunción','Barrio Obrero, Asunción',
           'Recoleta, Asunción','Trinidad, Asunción','San Lorenzo Centro','Barrio Tayuazapé, San Lorenzo',
           'Fernando de la Mora','Lambaré','Luque','Mariano Roque Alonso','Capiatá','Ñemby','Villa Elisa'])[1 + floor(random() * 14)::int] end,
         case when random() < 0.08 then date '2012-01-01' + floor(random() * 2500)::int
              else date '1962-01-01' + floor(random() * 16000)::int end,
         case when random() < 0.15 then (array['Prefiere degradado bajo y patillas cortas','Piel sensible: no usar alcohol en el cuello',
           'Viene siempre los sábados a la mañana','Trae a su hijo para el corte infantil','Pide que no le corten mucho arriba',
           'Alérgico a la loción mentolada','Le gusta la barba bien marcada','Paga siempre con transferencia'])[1 + floor(random() * 8)::int] end,
         d.f, d.f
  from elegidos e
  cross join lateral (select case when random() < 0.55 + e.i * 0
                                  then timestamptz '2025-05-01 10:00-03' + floor(random() * 350) * interval '1 day'
                                  else timestamptz '2026-04-18 10:00-03' + floor(power(random(), 1.3) * 170) * interval '1 day'
                             end f) d
  returning id_cliente, fecha_registro
)
insert into carga_demo.cliente (id_cliente, peso, barbero, desde, con_cuenta, id_usuario)
select i.id_cliente, 1 + floor(power(random(), 2) * 9), 1 + floor(random() * 12)::int, i.fecha_registro::date, false, null
from insertados i;

-- El barbero preferido tiene que trabajar desde antes de que el cliente se registre (o desde abril).
update carga_demo.cliente c set barbero = (
  select b.n from carga_demo.barbero b
  where b.desde <= greatest(c.desde, date '2026-04-18') and b.hasta is null
  order by -ln(random()) / b.pop limit 1)
where not exists (select 1 from carga_demo.barbero b where b.n = c.barbero
                  and b.desde <= greatest(c.desde, date '2026-04-18') and b.hasta is null);

-- Indices de apoyo para la carga (se borran en la parte 4)
create index carga_demo_citas_cliente on public.citas (id_cliente, fecha_hora);
create index carga_demo_hist_creado on public.historial_servicio (created_at);
create index carga_demo_pprof_creado on public.pagos_profesional (created_at);
create index carga_demo_aud_creado on public.auditoria (created_at);
create index carga_demo_mov_creado on public.movimientos_inventario (created_at);
create index carga_demo_alerta_creado on public.alertas_stock (created_at);

select (select count(*) from public.usuarios) usuarios, (select count(*) from public.profesionales) barberos,
       (select count(*) from public.servicios) servicios, (select count(*) from public.productos) productos,
       (select count(*) from public.clientes) clientes, (select count(*) from public.clientes where id_usuario is not null) con_cuenta,
       (select count(*) from public.servicio_producto) recetas;
