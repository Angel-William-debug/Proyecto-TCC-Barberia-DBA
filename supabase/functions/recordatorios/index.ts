// ============================================================================
// EDGE FUNCTION: recordatorios (RN-050)
//
// Manda el recordatorio de un turno por correo, `minutos_antes_recordatorio`
// antes de la hora de la cita (configuracion_sistema). Pensada para correr
// periodicamente (cada 5-10 minutos) via un disparador programado; ver
// README.md en esta misma carpeta para el despliegue y la programacion.
//
// NO SE DESPLEGO TODAVIA. El codigo esta listo para `supabase functions
// deploy recordatorios`, pero hace falta configurar el secreto
// RESEND_API_KEY del proyecto antes de activarla -decision del equipo,
// 18/8/2026-.
//
// QUE HACE EN CADA CORRIDA
//   1. Lee minutos_antes_recordatorio y max_reintentos_notif de
//      configuracion_sistema (fila unica).
//   2. Lee v_proximos_turnos: turnos de las proximas 24 horas que todavia no
//      tienen un recordatorio marcado como enviado.
//   3. Se queda solo con los que ya cruzaron el umbral de minutos_antes_recordatorio
//      -la vista trae 24 horas, no el umbral exacto: la mayoria de las
//      corridas no le tocan a casi ninguno todavia-.
//   4. Por cada uno: si el cliente no tiene correo, deja la notificacion en
//      'sin_email' y no reintenta. Si tiene, llama a la API de Resend y
//      guarda el resultado en NOTIFICACIONES, con reintento hasta
//      max_reintentos_notif (RN-042).
//
// SECURITY DEFINER Y RLS
//   Corre con la clave de servicio (SUPABASE_SERVICE_ROLE_KEY, que Supabase
//   inyecta sola en toda Edge Function): no hay sesion de usuario, y
//   `notificaciones` y `configuracion_sistema` tienen RLS que exige rol
//   administrador o recepcionista. Es el mismo motivo por el que
//   `clienteAdmin()` existe del lado de `apps/api` (ver su comentario).
// ============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2';

interface TurnoProximo {
  id_cita: number;
  fecha_hora: string;
  nombre_cliente: string;
  telefono: string;
  email: string | null;
  servicios: string | null;
  recordatorio_enviado: boolean;
}

interface Configuracion {
  nombre_barberia: string;
  minutos_antes_recordatorio: number;
  max_reintentos_notif: number;
}

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const RESEND_FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') ?? 'Barber Shop <onboarding@resend.dev>';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

function formatoHora(iso: string): string {
  return new Date(iso).toLocaleString('es-PY', {
    timeZone: 'America/Asuncion',
    dateStyle: 'long',
    timeStyle: 'short',
  });
}

async function enviarCorreo(destino: string, asunto: string, html: string): Promise<void> {
  if (!RESEND_API_KEY) {
    throw new Error('Falta el secreto RESEND_API_KEY del proyecto.');
  }

  const respuesta = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ from: RESEND_FROM_EMAIL, to: destino, subject: asunto, html }),
  });

  if (!respuesta.ok) {
    const texto = await respuesta.text();
    throw new Error(`Resend respondio ${respuesta.status}: ${texto}`);
  }
}

Deno.serve(async () => {
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: configuracion, error: errorConfig } = await supabase
    .from('configuracion_sistema')
    .select('nombre_barberia, minutos_antes_recordatorio, max_reintentos_notif')
    .eq('id_configuracion', 1)
    .single<Configuracion>();

  if (errorConfig || !configuracion) {
    return Response.json({ error: 'No se pudo leer configuracion_sistema.' }, { status: 500 });
  }

  const { data: turnos, error: errorTurnos } = await supabase
    .from('v_proximos_turnos')
    .select('*')
    .eq('recordatorio_enviado', false)
    .returns<TurnoProximo[]>();

  if (errorTurnos) {
    return Response.json({ error: errorTurnos.message }, { status: 500 });
  }

  const ahora = Date.now();
  const umbralMs = configuracion.minutos_antes_recordatorio * 60_000;

  // Solo los que ya entraron en la ventana de aviso: faltan menos minutos
  // para el turno que minutos_antes_recordatorio, y todavia no paso.
  const porAvisar = (turnos ?? []).filter((t) => {
    const faltanMs = new Date(t.fecha_hora).getTime() - ahora;
    return faltanMs > 0 && faltanMs <= umbralMs;
  });

  let enviados = 0;
  let sinEmail = 0;
  let fallidos = 0;

  for (const turno of porAvisar) {
    // Notificacion existente para este turno (reintento) o una nueva.
    const { data: existente } = await supabase
      .from('notificaciones')
      .select('id_notificacion, intentos, estado_envio')
      .eq('id_cita', turno.id_cita)
      .eq('tipo', 'recordatorio')
      .maybeSingle();

    if (existente?.estado_envio === 'enviado') continue; // ya se mando, no debería llegar aca
    if (existente && existente.intentos >= configuracion.max_reintentos_notif) continue; // RN-042: se acabaron los reintentos

    if (!turno.email) {
      sinEmail += 1;
      if (!existente) {
        await supabase.from('notificaciones').insert({
          id_cita: turno.id_cita,
          tipo: 'recordatorio',
          mensaje: 'Sin correo registrado: no se pudo enviar el recordatorio.',
          estado_envio: 'sin_email',
          proveedor: 'resend',
          intentos: 0,
        });
      }
      continue;
    }

    const asunto = `Recordatorio: tu turno en ${configuracion.nombre_barberia}`;
    const html = `
      <p>Hola ${turno.nombre_cliente},</p>
      <p>Te recordamos tu turno en <strong>${configuracion.nombre_barberia}</strong>:</p>
      <p><strong>${formatoHora(turno.fecha_hora)}</strong></p>
      <p>Servicios: ${turno.servicios ?? '—'}</p>
    `;

    try {
      await enviarCorreo(turno.email, asunto, html);
      enviados += 1;

      if (existente) {
        await supabase
          .from('notificaciones')
          .update({ estado_envio: 'enviado', fecha_envio: new Date().toISOString() })
          .eq('id_notificacion', existente.id_notificacion);
      } else {
        await supabase.from('notificaciones').insert({
          id_cita: turno.id_cita,
          tipo: 'recordatorio',
          email_destino: turno.email,
          estado_envio: 'enviado',
          fecha_envio: new Date().toISOString(),
          proveedor: 'resend',
          intentos: 1,
        });
      }
    } catch (causa) {
      fallidos += 1;
      const mensaje = causa instanceof Error ? causa.message : String(causa);

      if (existente) {
        await supabase
          .from('notificaciones')
          .update({ estado_envio: 'fallido', intentos: existente.intentos + 1, mensaje })
          .eq('id_notificacion', existente.id_notificacion);
      } else {
        await supabase.from('notificaciones').insert({
          id_cita: turno.id_cita,
          tipo: 'recordatorio',
          email_destino: turno.email,
          estado_envio: 'fallido',
          mensaje,
          proveedor: 'resend',
          intentos: 1,
        });
      }
    }
  }

  return Response.json({
    revisados: turnos?.length ?? 0,
    dentro_del_umbral: porAvisar.length,
    enviados,
    sin_email: sinEmail,
    fallidos,
  });
});
