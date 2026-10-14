// ============================================================================
// EDGE FUNCTION: recordatorios (RN-050)
//
// Manda el recordatorio de un turno por correo, `minutos_antes_recordatorio`
// antes de la hora de la cita (configuracion_sistema; hoy 1440, un dia antes).
// La programa `pg_cron` cada 10 minutos (migracion 20261014120000).
//
// POR BREVO, NO POR RESEND (14/10/2026). Se escribio el 19/8 para Resend, que
// sin dominio propio solo manda a la direccion del dueño: nunca se activo. Ahora
// usa la API transaccional de Brevo, la misma cuenta que ya manda los correos de
// Auth (por SMTP) y los reportes del panel (por API). Secretos del proyecto:
// BREVO_API_KEY y CORREO_REMITENTE.
//
// QUIEN LA LLAMA. Solo la base, por pg_net desde pg_cron, con la cabecera
// `x-avisos-secreto` -el mismo secreto que `avisos-push`, leido del Vault-.
// `verify_jwt = false` en config.toml: la clave anonima es un JWT valido, y
// con ella cualquiera podria disparar la corrida.
//
// QUE HACE EN CADA CORRIDA
//   1. Lee minutos_antes_recordatorio y max_reintentos_notif.
//   2. Lee v_proximos_turnos: turnos pendientes o confirmados de las proximas
//      24 horas sin recordatorio enviado.
//   3. Se queda con los que ya cruzaron el umbral.
//   4. Por cada uno: sin correo, deja la notificacion en 'sin_email' y no
//      reintenta. Con correo, lo manda y guarda el resultado en
//      `notificaciones`, con reintento hasta max_reintentos_notif (RN-042).
//
// Convive con los recordatorios LOCALES de la app (fase 3a), que suenan en el
// telefono sin internet. Este es para quien no tiene la app, o no le dio
// permiso de notificaciones: el correo le llega igual.
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

const BREVO_API_KEY = Deno.env.get('BREVO_API_KEY');
const CORREO_REMITENTE = Deno.env.get('CORREO_REMITENTE');
const AVISOS_PUSH_SECRETO = Deno.env.get('AVISOS_PUSH_SECRETO');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SITIO = 'https://proyecto-tcc-barberia-frontend-web.vercel.app';
const ZONA = 'America/Asuncion';

function escapar(texto: string): string {
  return texto.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
}

/** «jueves 26 de noviembre» y «09:45», en la zona de la barberia. */
function cuando(iso: string): { dia: string; hora: string } {
  const fecha = new Date(iso);
  return {
    dia: fecha.toLocaleDateString('es-PY', { timeZone: ZONA, weekday: 'long', day: 'numeric', month: 'long' }),
    hora: fecha.toLocaleTimeString('es-PY', { timeZone: ZONA, hour: '2-digit', minute: '2-digit', hour12: false }),
  };
}

/**
 * El correo, con la identidad de Barber Shop: la misma franja carbon, filete
 * ambar y tarjeta blanca que las plantillas de Auth (DBA,
 * supabase/templates/generar.mjs). Tablas y estilos en linea, porque los
 * clientes de correo ignoran las hojas de estilo.
 */
function html(turno: TurnoProximo, barberia: string): string {
  const { dia, hora } = cuando(turno.fecha_hora);
  const SANS = "'Inter','Segoe UI',Roboto,Helvetica,Arial,sans-serif";
  const DISPLAY = "'Oswald','Arial Narrow',Arial,sans-serif";
  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light"><title>Recordatorio de turno</title></head>
<body style="margin:0;padding:0;background-color:#FAF7F2;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;">Su turno es el ${escapar(dia)} a las ${hora}.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#FAF7F2;"><tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">
  <tr><td align="center" style="background-color:#14110F;border-radius:12px 12px 0 0;padding:28px 32px;">
    <img src="${SITIO}/icon.png" width="56" height="56" alt="" style="display:block;border:0;border-radius:12px;margin:0 auto 12px;">
    <div style="font-family:${DISPLAY};font-size:28px;line-height:32px;font-weight:700;letter-spacing:2px;color:#F7F3EC;">BARBER<span style="color:#C9922B;">SHOP</span></div>
  </td></tr>
  <tr><td style="background-color:#C9922B;height:4px;line-height:4px;font-size:0;">&nbsp;</td></tr>
  <tr><td style="background-color:#FFFFFF;border:1px solid #E7E1D7;border-top:0;border-radius:0 0 12px 12px;padding:36px 32px 32px;">
    <p style="margin:0 0 8px;font-family:${SANS};font-size:12px;font-weight:600;letter-spacing:1.5px;text-transform:uppercase;color:#855B19;">Recordatorio de turno</p>
    <h1 style="margin:0 0 20px;font-family:${DISPLAY};font-size:26px;line-height:32px;font-weight:600;color:#14110F;">Hola, ${escapar(turno.nombre_cliente)}</h1>
    <p style="margin:0 0 20px;font-family:${SANS};font-size:16px;line-height:24px;color:#5C544B;">Le recordamos su turno en <strong style="color:#14110F;">${escapar(barberia)}</strong>:</p>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#FBF4E4;border-left:3px solid #C9922B;border-radius:4px;">
      <tr><td style="padding:16px 18px;font-family:${SANS};">
        <p style="margin:0 0 4px;font-size:20px;line-height:26px;font-weight:600;color:#14110F;text-transform:capitalize;">${escapar(dia)}</p>
        <p style="margin:0 0 8px;font-size:28px;line-height:32px;font-weight:700;color:#14110F;">${hora}</p>
        <p style="margin:0;font-size:14px;line-height:20px;color:#5C544B;">${escapar(turno.servicios ?? 'Servicio a definir')}</p>
      </td></tr>
    </table>
    <p style="margin:24px 0 0;font-family:${SANS};font-size:15px;line-height:22px;color:#5C544B;">Si no puede venir, cancélelo desde la app o desde <a href="${SITIO}/mi-cuenta" style="color:#855B19;">su cuenta en la web</a>: así el horario le queda libre a otro cliente.</p>
  </td></tr>
  <tr><td align="center" style="padding:24px 16px 0;font-family:${SANS};font-size:12px;line-height:18px;color:#6B6257;">
    Barber Shop · Asunción, Paraguay · Este es un correo automático, no hace falta responderlo.
  </td></tr>
</table></td></tr></table></body></html>`;
}

async function enviarCorreo(destino: string, nombre: string, asunto: string, contenido: string, texto: string): Promise<void> {
  if (!BREVO_API_KEY || !CORREO_REMITENTE) {
    throw new Error('Faltan los secretos BREVO_API_KEY o CORREO_REMITENTE del proyecto.');
  }
  const respuesta = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: { 'api-key': BREVO_API_KEY, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({
      sender: { name: 'Barber Shop', email: CORREO_REMITENTE },
      to: [{ email: destino, name: nombre }],
      subject: asunto,
      htmlContent: contenido,
      textContent: texto,
    }),
  });
  if (!respuesta.ok) {
    throw new Error(`Brevo respondio ${respuesta.status}: ${(await respuesta.text()).slice(0, 300)}`);
  }
}

Deno.serve(async (peticion) => {
  if (!AVISOS_PUSH_SECRETO || peticion.headers.get('x-avisos-secreto') !== AVISOS_PUSH_SECRETO) {
    return Response.json({ error: 'No autorizado.' }, { status: 401 });
  }

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

    if (existente?.estado_envio === 'enviado') continue;
    if (existente?.estado_envio === 'sin_email') continue;
    if (existente && existente.intentos >= configuracion.max_reintentos_notif) continue; // RN-042

    if (!turno.email) {
      sinEmail += 1;
      if (!existente) {
        await supabase.from('notificaciones').insert({
          id_cita: turno.id_cita,
          tipo: 'recordatorio',
          mensaje: 'Sin correo registrado: no se pudo enviar el recordatorio.',
          estado_envio: 'sin_email',
          proveedor: 'brevo',
          intentos: 0,
        });
      } else {
        // Lo volvieron a poner en cola desde el panel (vista 87) pero el
        // cliente sigue sin correo: vuelve a quedar como tal, no en cola.
        await supabase
          .from('notificaciones')
          .update({ estado_envio: 'sin_email', mensaje: 'Sin correo registrado: no se pudo enviar el recordatorio.' })
          .eq('id_notificacion', existente.id_notificacion);
      }
      continue;
    }

    const { dia, hora } = cuando(turno.fecha_hora);
    const asunto = `Recordatorio: su turno es el ${dia} a las ${hora}`;
    const texto =
      `Hola, ${turno.nombre_cliente}. Le recordamos su turno en ${configuracion.nombre_barberia}: ` +
      `${dia} a las ${hora}. ${turno.servicios ?? ''}. Si no puede venir, cancélelo desde la app o desde ${SITIO}/mi-cuenta.`;

    try {
      await enviarCorreo(turno.email, turno.nombre_cliente, asunto, html(turno, configuracion.nombre_barberia), texto);
      enviados += 1;
      const fila = {
        estado_envio: 'enviado',
        fecha_envio: new Date().toISOString(),
        mensaje: asunto,
        email_destino: turno.email,
        proveedor: 'brevo',
      };
      if (existente) {
        await supabase
          .from('notificaciones')
          .update({ ...fila, intentos: existente.intentos + 1 })
          .eq('id_notificacion', existente.id_notificacion);
      } else {
        await supabase.from('notificaciones').insert({ ...fila, id_cita: turno.id_cita, tipo: 'recordatorio', intentos: 1 });
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
          proveedor: 'brevo',
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
