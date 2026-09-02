-- Enlaza las cuatro cuentas de Auth con su ficha de public.usuarios.
--
-- El auth_uid se lee de auth.users por correo, en vez de pasarlo desde afuera:
-- esta consulta corre como postgres y puede leer ese esquema, asi que no hay
-- razon para hacer el viaje de ida y vuelta.
--
-- El `on conflict` apunta al indice PARCIAL `usuarios_email_vigente`, no a la
-- columna a secas. Desde la migracion de borrado logico el unico de email es
-- `unique (email) where not deleted`, y un `on conflict (email)` no coincide
-- con el: falla con "no unique or exclusion constraint matching".
insert into public.usuarios (id_rol, auth_uid, nombre, email, estado)
select r.id_rol, a.id, d.nombre, d.email, true
  from (values
        ('administrador', 'admin@barbershop.com.py',     'Angel Rolon'),
        ('recepcionista', 'recepcion@barbershop.com.py', 'Carla Duarte'),
        ('profesional',   'barbero@barbershop.com.py',   'Marcos Ayala'),
        ('cliente',       'cliente@correo.com.py',       'Rodrigo Benitez')
       ) as d(rol, email, nombre)
  join public.roles r on r.nombre = d.rol
  join auth.users   a on a.email  = d.email
    on conflict (email) where not deleted
    do update set auth_uid = excluded.auth_uid,
                  id_rol   = excluded.id_rol,
                  nombre   = excluded.nombre,
                  estado   = true;

-- El barbero necesita su fila en `profesionales`: sin ella
-- `fn_id_profesional_actual()` devuelve NULL y entra a un panel que no le
-- muestra ni su agenda ni sus comisiones.
insert into public.profesionales (id_usuario, nombre, especialidad, tipo, porcentaje_com)
select u.id_usuario, u.nombre, 'Corte clasico y navaja', 'barbero senior', 40
  from public.usuarios u
 where u.email = 'barbero@barbershop.com.py'
   and not exists (select 1 from public.profesionales p
                    where p.id_usuario = u.id_usuario and not p.deleted);

-- Y el cliente su ficha, por la misma razon con `fn_id_cliente_actual()`.
insert into public.clientes (id_usuario, nombre, email, telefono, estado)
select u.id_usuario, u.nombre, u.email, '0981 234 567', true
  from public.usuarios u
 where u.email = 'cliente@correo.com.py'
   and not exists (select 1 from public.clientes c
                    where c.id_usuario = u.id_usuario and not c.deleted);
