// Crea las cuentas de Auth de la carga completa (18/10/2026). Ya confirmadas:
// no se manda ningun correo. Idempotente: si la cuenta existe, toma su id.
// La clave de servicio se lee de apps/web/.env.local y no se imprime.
import { readFileSync, writeFileSync } from 'node:fs';

const env = Object.fromEntries(
  readFileSync(process.argv[2], 'utf8')
    .split(/\r?\n/)
    .filter((l) => l.includes('=') && !l.startsWith('#'))
    .map((l) => {
      const i = l.indexOf('=');
      return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^"|"$/g, '')];
    }),
);
const URL = env.NEXT_PUBLIC_SUPABASE_URL;
const CLAVE = env.SUPABASE_SERVICE_ROLE_KEY;
const CONTRASENA = 'BarberTCC2026!';
const D = 'prueba.barbershop.com.py';

const cuentas = [
  // Angel y William: un alias por rol (Gmail entrega igual en su bandeja).
  { email: 'CORREO_ANGEL+admin@gmail.com', nombre: 'Angel Rolón', rol: 'administrador' },
  { email: 'CORREO_ANGEL+recepcion@gmail.com', nombre: 'Angel Rolón', rol: 'recepcionista' },
  { email: 'CORREO_ANGEL+barbero@gmail.com', nombre: 'Angel Rolón', rol: 'profesional' },
  { email: 'CORREO_WILLIAM+recepcion@gmail.com', nombre: 'William Giménez', rol: 'recepcionista' },
  { email: 'CORREO_WILLIAM+barbero@gmail.com', nombre: 'William Giménez', rol: 'profesional' },
  { email: 'CORREO_WILLIAM+cliente@gmail.com', nombre: 'William Giménez', rol: 'cliente' },
  // Recepcionistas
  { email: `lucia.benitez@${D}`, nombre: 'Lucía Benítez', rol: 'recepcionista' },
  { email: `mirta.ocampo@${D}`, nombre: 'Mirta Ocampo', rol: 'recepcionista' },
  // Barberos
  ...[
    'Diego Rojas', 'Fabián Ortiz', 'Luis Cabrera', 'Ramón Ferreira', 'Julio Aquino', 'Matías González', 'Hernán Villalba',
  ].map((nombre) => ({ email: correo(nombre), nombre, rol: 'profesional' })),
  // Clientes con cuenta (portal y app)
  ...[
    'Carlos Vera Duarte', 'Oscar Fernández', 'Hugo Ramírez Sosa', 'Ramón Insfrán', 'Rodrigo Martínez Ruiz',
    'Pedro Benítez Cáceres', 'Fernando Giménez', 'Juan Carlos González', 'Sebastián Duarte', 'Marcelo Cabañas',
    'Andrés Benítez', 'Gabriel Ortiz Paredes', 'Nicolás Riquelme', 'Federico Báez', 'Tomás Acosta',
    'Lucas Zárate', 'Bruno Florentín', 'Iván Sanabria', 'Mauricio Delgado', 'Alejandro Cardozo',
    'Diego Vera Rojas', 'Rubén Galeano', 'Cristian Escobar', 'Javier Ayala Núñez', 'Emanuel Ríos',
  ].map((nombre) => ({ email: correo(nombre), nombre, rol: 'cliente' })),
];

function correo(nombre) {
  const p = nombre
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .split(' ');
  return `${p[0]}.${p[1]}@${D}`;
}

async function api(ruta, opciones = {}) {
  const r = await fetch(`${URL}/auth/v1${ruta}`, {
    ...opciones,
    headers: { apikey: CLAVE, Authorization: `Bearer ${CLAVE}`, 'Content-Type': 'application/json' },
  });
  return { status: r.status, cuerpo: await r.json().catch(() => ({})) };
}

// Las que ya existen, para no duplicar.
const existentes = new Map();
for (let pagina = 1; pagina < 10; pagina++) {
  const { cuerpo } = await api(`/admin/users?page=${pagina}&per_page=200`);
  const lista = cuerpo.users ?? [];
  for (const u of lista) existentes.set(u.email, u.id);
  if (lista.length < 200) break;
}

const salida = [];
for (const c of cuentas) {
  let uid = existentes.get(c.email);
  if (!uid) {
    const r = await api('/admin/users', {
      method: 'POST',
      body: JSON.stringify({ email: c.email, password: CONTRASENA, email_confirm: true, user_metadata: { nombre: c.nombre } }),
    });
    if (r.status >= 300) throw new Error(`${c.email}: ${r.status} ${JSON.stringify(r.cuerpo).slice(0, 200)}`);
    uid = r.cuerpo.id;
  }
  salida.push({ ...c, uid });
}
writeFileSync(process.argv[3], JSON.stringify(salida, null, 2));
console.log('cuentas', salida.length, 'nuevas', salida.filter((c) => !existentes.has(c.email)).length);
