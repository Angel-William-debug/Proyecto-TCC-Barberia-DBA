// ============================================================================
// EDGE FUNCTION: avisos-push (fase 3b de la app del cliente)
//
// Envia al telefono del cliente un aviso que anoto la base en
// `notificaciones`: la barberia confirmo, cancelo o cambio la hora de su
// turno. Ver la migracion 20261001130000_avisos_push.sql para el camino
// completo.
//
// QUIEN LA LLAMA: la base, por `pg_net`, desde `trg_notificacion_enviar`, con
// el cuerpo { id_notificacion }. No la llama un usuario, asi que no exige la
// sesion de Supabase (`verify_jwt = false` en config.toml): se protege con el
// secreto compartido AVISOS_PUSH_SECRETO, que la base manda en la cabecera
// `x-avisos-secreto` leyendolo del Vault.
//
// COMO ENVIA: por la API de Expo Push (exp.host), que en Android entrega por
// Firebase Cloud Messaging con la clave de servicio cargada en EAS. Firebase
// es solo el cartero: aca no hay nada de Firebase.
//
// RESULTADO, en la misma fila de `notificaciones`:
//   enviado          Expo acepto el aviso para al menos un telefono.
//   sin_dispositivo  El cliente no tiene la app instalada con sesion.
//   fallido          Expo lo rechazo; se guarda el intento.
// Un telefono que Expo informa como dado de baja (DeviceNotRegistered) se
// borra de `dispositivos_push`: la app fue desinstalada.
// ============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const AVISOS_PUSH_SECRETO = Deno.env.get('AVISOS_PUSH_SECRETO');

const TITULOS: Record<string, string> = {
  turno_confirmado: 'Turno confirmado',
  turno_cancelado: 'Turno cancelado',
  turno_reprogramado: 'Su turno cambió de hora',
};

interface Notificacion {
  id_notificacion: number;
  id_cita: number | null;
  id_usuario: number | null;
  tipo: string | null;
  mensaje: string | null;
  estado_envio: string;
  intentos: number;
}

interface TicketExpo {
  status: 'ok' | 'error';
  message?: string;
  details?: { error?: string };
}

Deno.serve(async (peticion) => {
  if (!AVISOS_PUSH_SECRETO || peticion.headers.get('x-avisos-secreto') !== AVISOS_PUSH_SECRETO) {
    return Response.json({ error: 'No autorizado.' }, { status: 401 });
  }

  const { id_notificacion } = await peticion.json().catch(() => ({}));
  if (typeof id_notificacion !== 'number') {
    return Response.json({ error: 'Falta id_notificacion.' }, { status: 400 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: aviso, error: errorAviso } = await supabase
    .from('notificaciones')
    .select('id_notificacion, id_cita, id_usuario, tipo, mensaje, estado_envio, intentos')
    .eq('id_notificacion', id_notificacion)
    .single<Notificacion>();

  if (errorAviso || !aviso) {
    return Response.json({ error: 'No existe esa notificacion.' }, { status: 404 });
  }
  if (aviso.estado_envio !== 'pendiente') {
    return Response.json({ ok: true, omitida: aviso.estado_envio });
  }

  const marcar = (estado_envio: string) =>
    supabase
      .from('notificaciones')
      .update({ estado_envio, intentos: aviso.intentos + 1, fecha_envio: new Date().toISOString() })
      .eq('id_notificacion', aviso.id_notificacion);

  // Los telefonos del cliente: `dispositivos_push` guarda la sesion
  // (`auth_uid`), y `notificaciones` el usuario.
  const { data: usuario } = await supabase
    .from('usuarios')
    .select('auth_uid')
    .eq('id_usuario', aviso.id_usuario ?? -1)
    .maybeSingle<{ auth_uid: string | null }>();

  const { data: dispositivos } = usuario?.auth_uid
    ? await supabase.from('dispositivos_push').select('token').eq('auth_uid', usuario.auth_uid)
    : { data: [] as Array<{ token: string }> };

  const tokens = (dispositivos ?? []).map((d) => d.token);
  if (tokens.length === 0) {
    await marcar('sin_dispositivo');
    return Response.json({ ok: true, estado: 'sin_dispositivo' });
  }

  const mensajes = tokens.map((to) => ({
    to,
    title: TITULOS[aviso.tipo ?? ''] ?? 'Barber Shop',
    body: aviso.mensaje ?? '',
    data: { tipo: 'aviso_turno', idCita: aviso.id_cita },
    sound: 'default',
    priority: 'high',
    // Mismo canal que crea la app para estos avisos.
    channelId: 'avisos',
  }));

  let tickets: TicketExpo[] = [];
  try {
    const respuesta = await fetch('https://exp.host/--/api/v2/push/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(mensajes),
    });
    const cuerpo = await respuesta.json();
    tickets = (cuerpo?.data ?? []) as TicketExpo[];
  } catch (causa) {
    await marcar('fallido');
    return Response.json({ error: `No se pudo contactar a Expo: ${causa}` }, { status: 502 });
  }

  // Telefonos dados de baja: la app se desinstalo o cerro sesion en otro lado.
  const bajas = tokens.filter((_, i) => tickets[i]?.details?.error === 'DeviceNotRegistered');
  if (bajas.length) await supabase.from('dispositivos_push').delete().in('token', bajas);

  const algunoOk = tickets.some((t) => t.status === 'ok');
  await marcar(algunoOk ? 'enviado' : 'fallido');

  return Response.json({ ok: algunoOk, enviados: tickets.filter((t) => t.status === 'ok').length, bajas: bajas.length });
});
