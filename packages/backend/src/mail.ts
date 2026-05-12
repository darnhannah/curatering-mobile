import dns from "node:dns";
import net from "node:net";
import nodemailer from "nodemailer";

let transporter: nodemailer.Transporter | null = null;
let transporterKey = "";
/** Serializes transport creation so concurrent mail sends share one `resolve4` + `createTransport`. */
let transportChain: Promise<void> = Promise.resolve();

/** SMTP login user (Gmail = full email address). */
function smtpUser(): string {
  return (
    process.env.TRANSPORTER_EMAIL?.trim() ||
    process.env.SMTP_LOGIN?.trim() ||
    process.env.GMAIL_USER?.trim() ||
    process.env.EMAIL_USER?.trim() ||
    ""
  );
}

/** SMTP password (Gmail = app password). */
function smtpPass(): string {
  return (
    process.env.TRANSPORTER_PASSWORD?.trim() ||
    process.env.SMTP_PASSWORD?.trim() ||
    process.env.GMAIL_APP_PASSWORD?.trim() ||
    process.env.EMAIL_PASSWORD?.trim() ||
    ""
  );
}

/** From header; defaults to the SMTP user when unset. */
function smtpFrom(): string {
  return (
    process.env.TRANSPORTER_FROM?.trim() ||
    process.env.SMTP_FROM?.trim() ||
    process.env.MAIL_FROM?.trim() ||
    smtpUser()
  );
}

export function isMailConfigured(): boolean {
  return !!(smtpUser() && smtpPass());
}

/**
 * Build nodemailer transport. Prefer connecting to an IPv4 from `resolve4` so Railway
 * (no outbound IPv6) does not hit Gmail's AAAA and ENETUNREACH on 465.
 */
async function buildTransport(): Promise<nodemailer.Transporter | null> {
  const logicalHost = process.env.TRANSPORTER_SMTP_HOST?.trim() || process.env.SMTP_HOST?.trim() || "smtp.gmail.com";
  const port = Number(process.env.TRANSPORTER_SMTP_PORT ?? process.env.SMTP_PORT) || 465;
  const user = smtpUser();
  const pass = smtpPass();
  if (!user || !pass) {
    return null;
  }

  let connectHost = logicalHost;
  let tlsServername: string | undefined;

  if (!logicalHost.includes(":") && net.isIP(logicalHost) === 0) {
    try {
      const v4 = await dns.promises.resolve4(logicalHost);
      if (v4.length > 0) {
        connectHost = v4[0]!;
        tlsServername = logicalHost;
      }
    } catch (err) {
      console.warn(`[mail] resolve4(${logicalHost}) failed; falling back to hostname (may fail on IPv6-only egress):`, err);
    }
  }

  const secure = port === 465;
  const baseTls =
    tlsServername != null
      ? { servername: tlsServername, rejectUnauthorized: true as const }
      : { rejectUnauthorized: true as const };

  let usePort = port;
  let useSecure = secure;
  let requireTLS = false;
  // If we still only have a hostname (resolve4 failed), Gmail on 465 often resolves to IPv6 and breaks on Railway.
  if (
    connectHost === logicalHost &&
    net.isIP(logicalHost) === 0 &&
    /^smtp\.gmail\.com$/i.test(logicalHost) &&
    port === 465
  ) {
    console.warn("[mail] Falling back to smtp.gmail.com:587 STARTTLS (hostname-only after resolve4).");
    usePort = 587;
    useSecure = false;
    requireTLS = true;
  }

  return nodemailer.createTransport({
    host: connectHost,
    port: usePort,
    secure: useSecure,
    requireTLS,
    auth: { user, pass },
    tls: baseTls,
    connectionTimeout: 25_000,
    greetingTimeout: 15_000,
    socketTimeout: 45_000,
  } as nodemailer.TransportOptions);
}

/** Singleflight async init — always `resolve4` before connecting (Railway / IPv6-safe). */
async function ensureTransport(): Promise<nodemailer.Transporter | null> {
  const logicalHost = process.env.TRANSPORTER_SMTP_HOST?.trim() || process.env.SMTP_HOST?.trim() || "smtp.gmail.com";
  const port = Number(process.env.TRANSPORTER_SMTP_PORT ?? process.env.SMTP_PORT) || 465;
  const user = smtpUser();
  const pass = smtpPass();
  const key = `${logicalHost}|${port}|${user}|${pass}`;
  if (!user || !pass) {
    return null;
  }
  if (transporter && transporterKey === key) {
    return transporter;
  }
  await (transportChain = transportChain.then(async () => {
    if (transporter && transporterKey === key) return;
    transporter = null;
    transporterKey = "";
    const t = await buildTransport();
    transporter = t;
    transporterKey = t ? key : "";
  }));
  return transporter;
}

/** Sends email; skips quietly if SMTP is not configured (non-critical notifications). */
export async function sendMailSafe(to: string, subject: string, text: string): Promise<void> {
  const from = smtpFrom();
  const t = await ensureTransport();
  if (!t || !from) {
    console.warn(
      "Email not configured; set TRANSPORTER_EMAIL + TRANSPORTER_PASSWORD (or GMAIL_USER + GMAIL_APP_PASSWORD); skipping send.",
    );
    return;
  }
  await t.sendMail({ from, to, subject, text });
}

/** Throws if SMTP is missing or delivery fails — use for OTP and must-deliver flows. */
export async function sendMailRequired(to: string, subject: string, text: string): Promise<void> {
  const from = smtpFrom();
  const t = await ensureTransport();
  if (!t || !from) {
    throw new Error(
      "SMTP not configured: set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD (or GMAIL_USER + GMAIL_APP_PASSWORD)",
    );
  }
  await t.sendMail({ from, to, subject, text });
}

/** PDF attachment (Buffer) — same SMTP config as [sendMailSafe]. */
export async function sendMailWithPdfAttachment(
  to: string,
  subject: string,
  text: string,
  pdfFilename: string,
  pdfBuffer: Buffer,
): Promise<void> {
  const from = smtpFrom();
  const t = await ensureTransport();
  if (!t || !from) {
    console.warn(
      "Email not configured; set TRANSPORTER_EMAIL + TRANSPORTER_PASSWORD; skipping send.",
    );
    return;
  }
  await t.sendMail({
    from,
    to,
    subject,
    text,
    attachments: [{ filename: pdfFilename, content: pdfBuffer }],
  });
}

/** PDF attachment — throws if SMTP is missing or send fails (order-summary emails). */
export async function sendMailWithPdfRequired(
  to: string,
  subject: string,
  text: string,
  pdfFilename: string,
  pdfBuffer: Buffer,
): Promise<void> {
  const from = smtpFrom();
  const t = await ensureTransport();
  if (!t || !from) {
    throw new Error(
      "SMTP not configured: set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD (or GMAIL_USER + GMAIL_APP_PASSWORD)",
    );
  }
  await t.sendMail({
    from,
    to,
    subject,
    text,
    attachments: [{ filename: pdfFilename, content: pdfBuffer }],
  });
}
