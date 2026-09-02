-- ============================================================================
-- DATOS DE PRUEBA DE LA BARBERIA
--
-- NO es una migracion y no vive en el repositorio: son datos del negocio, no
-- del esquema. Una migracion se aplica en todo despliegue, y sembrar precios
-- inventados en cada despliegue seria un error.
--
-- Precios en guaranies, en el rango real de una barberia de San Lorenzo, para
-- que las capturas del TCC resulten verosimiles. Se pueden cambiar desde las
-- pantallas del panel sin tocar nada de esto.
--
-- Idempotente: volver a ejecutarlo no duplica filas.
-- ============================================================================

-- Se usa `where not exists` y no `on conflict (nombre)`: desde la migracion de
-- borrado logico el unico de `nombre` es un indice PARCIAL -`where not
-- deleted`- y ON CONFLICT no coincide con el; falla con "there is no unique or
-- exclusion constraint matching".
insert into public.categorias_servicio (nombre, descripcion)
select d.nombre, d.descripcion
  from (values
        ('Corte',    'Cortes de cabello'),
        ('Barba',    'Perfilado y afeitado'),
        ('Infantil', 'Hasta 12 anos')
       ) as d(nombre, descripcion)
 where not exists (select 1 from public.categorias_servicio c
                    where c.nombre = d.nombre and not c.deleted);

insert into public.servicios (id_categoria, nombre, descripcion, duracion_min, precio_base)
select c.id_categoria, d.nombre, d.descripcion, d.duracion, d.precio
  from (values
        ('Corte',    'Corte clasico',       'Corte a tijera y maquina, con lavado', 30, 50000),
        ('Corte',    'Corte degradado',     'Degradado a maquina con perfilado',    40, 60000),
        ('Corte',    'Corte y barba',       'Corte completo mas perfilado de barba',55, 85000),
        ('Barba',    'Perfilado de barba',  'Delineado y recorte con navaja',       20, 45000),
        ('Barba',    'Afeitado tradicional','Toalla caliente, navaja y balsamo',    30, 55000),
        ('Infantil', 'Corte infantil',      'Hasta 12 anos',                        25, 40000)
       ) as d(categoria, nombre, descripcion, duracion, precio)
  join public.categorias_servicio c on c.nombre = d.categoria
 where not exists (select 1 from public.servicios s
                    where s.nombre = d.nombre and not s.deleted);

-- Tres barberos mas. Con el que ya tiene cuenta (Marcos Ayala) son CUATRO, que
-- es la capacidad concurrente que pidio la Direccion: cuatro turnos en
-- paralelo en la misma franja.
insert into public.profesionales (nombre, especialidad, tipo, porcentaje_com)
select d.nombre, d.especialidad, d.tipo, d.com
  from (values
        ('Diego Rojas',   'Degradados y diseno',    'barbero', 35),
        ('Fabian Ortiz',  'Barberia tradicional',   'barbero', 35),
        ('Luis Cabrera',  'Corte infantil y color', 'barbero', 30)
       ) as d(nombre, especialidad, tipo, com)
 where not exists (select 1 from public.profesionales p
                    where p.nombre = d.nombre and not p.deleted);

insert into public.categorias_producto (nombre, descripcion)
select d.nombre, null
  from (values
        ('Peinado y fijacion'),
        ('Cuidado de barba'),
        ('Higiene'),
        ('Descartables')
       ) as d(nombre)
 where not exists (select 1 from public.categorias_producto c
                    where c.nombre = d.nombre and not c.deleted);

insert into public.productos (id_categoria_p, nombre, unidad_medida, unidad_uso,
                              cantidad_uso_estandar, precio_unitario,
                              stock_minimo, stock_maximo, stock_actual)
select c.id_categoria_p, d.nombre, d.um, d.uu, d.equiv, d.precio, d.minimo, d.maximo, d.actual
  from (values
        ('Peinado y fijacion', 'Cera modeladora mate 100 g', 'unidad', 'aplicacion', 30, 45000,  5, 30, 14),
        ('Peinado y fijacion', 'Gel fijador fuerte 250 ml',  'unidad', 'aplicacion', 50, 28000,  4, 25,  3),
        ('Cuidado de barba',   'Aceite para barba 30 ml',    'unidad', 'aplicacion', 20, 65000,  3, 15,  0),
        ('Cuidado de barba',   'Balsamo para barba 50 ml',   'unidad', 'aplicacion', 25, 58000,  4, 20,  6),
        ('Higiene',            'Shampoo anticaspa 500 ml',   'unidad', 'lavado',     40, 52000,  3, 20,  9),
        ('Higiene',            'Locion after shave 200 ml',  'unidad', 'aplicacion', 40, 42000,  4, 20, 11),
        ('Descartables',       'Talco mentolado 100 g',      'unidad', 'aplicacion', 50, 18000,  6, 40, 22),
        ('Descartables',       'Hojas de afeitar caja x100', 'caja',   'unidad',    100, 38000,  5, 30,  2)
       ) as d(categoria, nombre, um, uu, equiv, precio, minimo, maximo, actual)
  join public.categorias_producto c on c.nombre = d.categoria
 where not exists (select 1 from public.productos p
                    where p.nombre = d.nombre and not p.deleted);

insert into public.proveedores (nombre, email, telefono, direccion)
select d.nombre, d.email, d.telefono, d.direccion
  from (values
        ('Distribuidora Capilar SA', 'ventas@capilar.com.py', '021 555 100',
         'Asuncion, Central'),
        ('Insumos Barber Py',        'contacto@barberpy.com.py', '021 555 200',
         'San Lorenzo, Central')
       ) as d(nombre, email, telefono, direccion)
 where not exists (select 1 from public.proveedores p
                    where p.nombre = d.nombre and not p.deleted);

-- Datos de la barberia, para que la factura y el portal no muestren el
-- marcador de posicion.
update public.configuracion_sistema
   set nombre_barberia = 'Barber Shop',
       direccion       = 'San Lorenzo, Departamento Central',
       telefono        = '0981 555 000',
       email           = 'contacto@barbershop.com.py'
 where id_configuracion = 1;

-- La receta de un servicio, para poder probar el consumo de insumos al cerrar
-- un turno (CU-003 y CU-011).
insert into public.servicio_producto (id_servicio, id_producto, cantidad_estandar, unidad_uso)
select s.id_servicio, p.id_producto, d.cantidad, d.unidad
  from (values
        ('Corte clasico',      'Shampoo anticaspa 500 ml',   1, 'lavado'),
        ('Corte clasico',      'Cera modeladora mate 100 g', 1, 'aplicacion'),
        ('Perfilado de barba', 'Aceite para barba 30 ml',    1, 'aplicacion'),
        ('Perfilado de barba', 'Hojas de afeitar caja x100', 1, 'unidad')
       ) as d(servicio, producto, cantidad, unidad)
  join public.servicios s on s.nombre = d.servicio and not s.deleted
  join public.productos p on p.nombre = d.producto and not p.deleted
 where not exists (select 1 from public.servicio_producto sp
                    where sp.id_servicio = s.id_servicio
                      and sp.id_producto = p.id_producto);
