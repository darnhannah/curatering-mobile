/** Optional Twilio SMS for guest order updates (email + text). */

function twilioAccountSid(): string {
  return process.env.TWILIO_ACCOUNT_SID?.trim() || "";
}

function twilioAuthToken(): string {
  return process.env.TWILIO_AUTH_TOKEN?.trim() || "";
}

function twilioFromNumber(): string {
  return process.env.TWILIO_FROM_NUMBER?.trim() || "";
}

export function isSmsConfigured(): boolean {
  return !!(twilioAccountSid() && twilioAuthToken() && twilioFromNumber());
}

/** Normalize PH mobile numbers to E.164 (+63…). */
export function normalizeSmsPhone(raw: string): string | null {
  const digits = raw.replace(/\D/g, "");
  if (digits.length < 10) return null;
  let n = digits;
  if (n.startsWith("63") && n.length >= 12) {
    /* already country code */
  } else if (n.startsWith("0") && n.length === 11) {
    n = `63${n.slice(1)}`;
  } else if (n.length === 10) {
    n = `63${n}`;
  } else if (!n.startsWith("63")) {
    return null;
  }
  return `+${n}`;
}

export async function sendSmsSafe(toPhoneRaw: string, body: string): Promise<void> {
  const to = normalizeSmsPhone(toPhoneRaw);
  if (!to || !body.trim()) return;

  const devLog = process.env.MOBILE_DEV_SMS_LOGGING === "true";
  if (!isSmsConfigured()) {
    if (devLog) {
      console.warn(`[MOBILE_DEV_SMS_LOGGING] SMS to ${to}: ${body}`);
    }
    return;
  }

  const sid = twilioAccountSid();
  const token = twilioAuthToken();
  const from = twilioFromNumber();
  const url = `https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`;
  const params = new URLSearchParams({ To: to, From: from, Body: body });
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Basic ${Buffer.from(`${sid}:${token}`).toString("base64")}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params.toString(),
    });
    if (!res.ok) {
      const errText = await res.text().catch(() => "");
      console.warn(`[sms] Twilio HTTP ${res.status}: ${errText || res.statusText}`);
    }
  } catch (err) {
    console.warn("[sms] send failed:", err instanceof Error ? err.message : err);
  }
}
