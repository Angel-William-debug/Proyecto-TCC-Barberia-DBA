// Arma y corre la carga completa contra Supabase.
//   node correr.mjs prueba   -> todo en una transaccion con rollback, y la verificacion
//   node correr.mjs real     -> lo mismo con commit
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const dir = import.meta.dirname;
const modo = process.argv[2];
if (!['prueba', 'real'].includes(modo)) throw new Error('modo: prueba | real');

const leer = (f) => readFileSync(join(dir, f), 'utf8');
const cuentas = JSON.parse(leer('cuentas.json'));
const esc = (v) => `'${String(v).replace(/'/g, "''")}'`;
const base = leer('01_base.plantilla.sql').replace(
  '__CUENTAS__',
  cuentas.map((x) => `  (${[x.email, x.nombre, x.rol, x.uid].map(esc).join(', ')})`).join(',\n'),
);
writeFileSync(join(dir, '01_base.sql'), base);

const sql = [
  'begin;',
  base,
  leer('02_funciones.sql'),
  "select * from carga_demo.simular('2026-04-18', '2026-10-17');",
  leer('03_cierre_y_futuro.sql'),
  leer('verificar.sql'),
  modo === 'real' ? 'commit;' : 'rollback;',
].join('\n');

const env = readFileSync('C:/Users/angel/Desktop/Proyecto-TCC-Barberia-Contenedor-de-repos/Proyecto-TCC-Barberia-DBA/.env', 'utf8');
const token = /SUPABASE_ACCESS_TOKEN=["']?([^"'\r\n]+)/.exec(env)[1];
const inicio = Date.now();
const r = await fetch('https://api.supabase.com/v1/projects/tmuntxynyopzbhzmulux/database/query', {
  method: 'POST',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }),
  signal: AbortSignal.timeout(130_000),
});
const texto = await r.text();
writeFileSync(join(dir, `resultado-${modo}.json`), texto);
console.log(`${modo}: ${r.status} en ${Math.round((Date.now() - inicio) / 1000)} s`);
try {
  const datos = JSON.parse(texto);
  console.log(datos.message ?? JSON.stringify(datos.at(-1)?.verificacion ?? datos, null, 1));
} catch {
  console.log(texto.slice(0, 500));
}
