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

function resendApiKey(): string {
  return process.env.RESEND_API_KEY?.trim() || "";
}

const kResendFromFallback = "onboarding@resend.dev";

/** Strip BOM / smart quotes / repeated outer quotes (common when pasting Railway env values). */
function stripMailEnvDecorators(raw: string): string {
  let s = raw.replace(/^\ufeff/, "").trim();
  s = s.replace(/[\u201c\u201d\u2018\u2019\u00ab\u00bb]/g, '"');
  for (let i = 0; i < 3; i++) {
    const again = s.trim();
    if ((again.startsWith('"') && again.endsWith('"')) || (again.startsWith("'") && again.endsWith("'"))) {
      s = again.slice(1, -1).trim();
    } else {
      break;
    }
  }
  return s.trim();
}

/**
 * Resend only accepts `email@x.y` or `Display Name <email@x.y>`.
 * Railway / .env mistakes (extra quotes, smart quotes, missing `>`) produce HTTP 422.
 */
function normalizeResendFrom(raw: string): string {
  const s0 = stripMailEnvDecorators(raw);
  if (!s0) return kResendFromFallback;

  const angle = s0.match(/^(.+?)\s*<\s*([^<>]+?)\s*>$/);
  if (angle) {
    const display = angle[1].replace(/[<>]/g, "").trim();
    const addr = angle[2].trim();
    if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(addr)) {
      return display.length > 0 ? `${display} <${addr}>` : addr;
    }
  }

  if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s0)) {
    return s0;
  }

  const loose = s0.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/);
  if (loose) {
    const addr = loose[0];
    console.warn(
      `[mail] RESEND_FROM "${raw.slice(0, 80)}${raw.length > 80 ? "…" : ""}" was normalized to bare address "${addr}". Prefer explicit: Name <${addr}>`,
    );
    return addr;
  }

  console.warn(
    `[mail] RESEND_FROM is not a valid Resend "from" (need email@domain or Name <email@domain>). Using ${kResendFromFallback}.`,
  );
  return kResendFromFallback;
}

/**
 * Verified-domain "from" for Resend. If unset, falls back to other mail env vars, then SMTP user,
 * then Resend's sandbox sender (testing only — see https://resend.com/docs ).
 */
function resendFromAddress(): string {
  const raw =
    process.env.RESEND_FROM?.trim() ||
    process.env.TRANSPORTER_FROM?.trim() ||
    process.env.SMTP_FROM?.trim() ||
    process.env.MAIL_FROM?.trim() ||
    smtpUser() ||
    kResendFromFallback;
  return normalizeResendFrom(raw);
}

/** When set, all mail goes over HTTPS to Resend (works on Railway where outbound SMTP may be blocked). */
export function mailUsesResend(): boolean {
  return resendApiKey().length > 0;
}

export function isMailConfigured(): boolean {
  if (mailUsesResend()) return true;
  return !!(smtpUser() && smtpPass());
}

/** Resend Hobby plan is ~2 req/s; parallel signup/login/forgot hits 429. Serialize + throttle + retry. */
let resendSendChain: Promise<void> = Promise.resolve();
let lastResendRequestDoneAt = 0;
const kMinMsBetweenResendRequests = 520;

function sleepMs(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function sendViaResend(
  to: string,
  subject: string,
  text: string,
  attachments?: { filename: string; content: Buffer }[],
): Promise<void> {
  const apiKey = resendApiKey();
  if (!apiKey) {
    throw new Error("RESEND_API_KEY is not set");
  }
  const from = resendFromAddress();
  const body: Record<string, unknown> = {
    from,
    to: [to],
    subject,
    text,
  };
  if (attachments && attachments.length > 0) {
    body.attachments = attachments.map((a) => ({
      filename: a.filename,
      content: a.content.toString("base64"),
    }));
  }
  const payload = JSON.stringify(body);

  const run = async (): Promise<void> => {
    const waitGap = kMinMsBetweenResendRequests - (Date.now() - lastResendRequestDoneAt);
    if (waitGap > 0) await sleepMs(waitGap);
    let lastErr: Error | null = null;
    for (let attempt = 0; attempt < 8; attempt++) {
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: payload,
      });
      lastResendRequestDoneAt = Date.now();
      if (res.ok) return;
      const errText = await res.text().catch(() => "");
      lastErr = new Error(`Resend API HTTP ${res.status}: ${errText || res.statusText}`);
      if (res.status === 429 || res.status === 503) {
        const ra = res.headers.get("retry-after");
        const sec = ra ? Number.parseFloat(ra) : NaN;
        const backoff = Number.isFinite(sec) && sec > 0 ? Math.min(10_000, Math.ceil(sec * 1000)) : 400 * (attempt + 1);
        await sleepMs(backoff);
        const pad = kMinMsBetweenResendRequests - (Date.now() - lastResendRequestDoneAt);
        if (pad > 0) await sleepMs(pad);
        continue;
      }
      throw lastErr;
    }
    throw lastErr ?? new Error("Resend send failed after retries");
  };

  const job = resendSendChain.then(run, run);
  resendSendChain = job.catch(() => {});
  await job;
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
  if (mailUsesResend()) {
    return null;
  }
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
  if (mailUsesResend()) {
    try {
      await sendViaResend(to, subject, text);
    } catch (err) {
      console.warn("[mail] Resend send failed:", err);
    }
    return;
  }
  const from = smtpFrom();
  const t = await ensureTransport();
  if (!t || !from) {
    console.warn(
      "Email not configured; set RESEND_API_KEY or TRANSPORTER_EMAIL + TRANSPORTER_PASSWORD; skipping send.",
    );
    return;
  }
  try {
    await t.sendMail({ from, to, subject, text });
  } catch (err) {
    console.warn("[mail] SMTP send failed:", err);
  }
}

/** Throws if SMTP is missing or delivery fails — use for OTP and must-deliver flows. */
export async function sendMailRequired(to: string, subject: string, text: string): Promise<void> {
  if (mailUsesResend()) {
    await sendViaResend(to, subject, text);
    return;
  }
  const from = smtpFrom();
  const t = await ensureTransport();
  if (!t || !from) {
    throw new Error(
      "Mail not configured: set RESEND_API_KEY (recommended on Railway) or TRANSPORTER_EMAIL + TRANSPORTER_PASSWORD",
    );
  }
  await t.sendMail({ from, to, subject, text });
}

/** PDF attachment (Buffer) — same mail config as [sendMailSafe]. */
export async function sendMailWithPdfAttachment(
  to: string,
  subject: string,
  text: string,
  pdfFilename: string,
  pdfBuffer: Buffer,
): Promise<void> {
  if (mailUsesResend()) {
    try {
      await sendViaResend(to, subject, text, [{ filename: pdfFilename, content: pdfBuffer }]);
    } catch (err) {
      console.warn("[mail] Resend send (PDF) failed:", err);
    }
    return;
  }
  const from = smtpFrom();
  const t = await ensureTransport();
  if (!t || !from) {
    console.warn(
      "Email not configured; set RESEND_API_KEY or TRANSPORTER_EMAIL + TRANSPORTER_PASSWORD; skipping send.",
    );
    return;
  }
  try {
    await t.sendMail({
      from,
      to,
      subject,
      text,
      attachments: [{ filename: pdfFilename, content: pdfBuffer }],
    });
  } catch (err) {
    console.warn("[mail] SMTP send (PDF) failed:", err);
  }
}

/** PDF attachment — throws if mail is missing or send fails (order-summary emails). */
export async function sendMailWithPdfRequired(
  to: string,
  subject: string,
  text: string,
  pdfFilename: string,
  pdfBuffer: Buffer,
): Promise<void> {
  if (mailUsesResend()) {
    await sendViaResend(to, subject, text, [{ filename: pdfFilename, content: pdfBuffer }]);
    return;
  }
  const from = smtpFrom();
  const t = await ensureTransport();
  if (!t || !from) {
    throw new Error(
      "Mail not configured: set RESEND_API_KEY (recommended on Railway) or TRANSPORTER_EMAIL + TRANSPORTER_PASSWORD",
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
