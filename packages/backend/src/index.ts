import "dotenv/config";
import crypto from "node:crypto";
import bcrypt from "bcrypt";
import cors from "cors";
import express from "express";
import { isMailConfigured, sendMailRequired, sendMailSafe } from "./mail.js";
import { getPool, initDb } from "./db.js";
import { resolveMenuSql, resolveSetMenusSql } from "./webMenu.js";

const app = express();
const port = Number(process.env.PORT) || 8080;
const otpExpiryMinutes = Number(process.env.MOBILE_OTP_EXPIRY_MINUTES) || 15;

app.use(cors());
app.use(express.json({ limit: "15mb" }));

function parseJsonTextArray(raw: unknown): string[] {
  if (raw == null) return [];
  const s = String(raw).trim();
  if (!s) return [];
  try {
    const v = JSON.parse(s);
    return Array.isArray(v) ? v.map((x) => String(x)) : [];
  } catch {
    return [];
  }
}

app.get("/health", (_req, res) => {
  res.json({ ok: true });
});

app.get("/api/items", async (_req, res) => {
  try {
    const { rows } = await getPool().query(
      "SELECT id, title, created_at FROM items ORDER BY id DESC",
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/items", async (req, res) => {
  const title = typeof req.body?.title === "string" ? req.body.title.trim() : "";
  if (!title) {
    res.status(400).json({ error: "title is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      "INSERT INTO items (title) VALUES ($1) RETURNING id, title, created_at",
      [title],
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/menu", async (_req, res) => {
  const sql = resolveMenuSql();
  if (!sql) {
    res.status(503).json({
      error:
        "Menu query disabled or not configured. Remove DISABLE_DEFAULT_PUBLIC_MENU or set WEB_MENU_SQL / WEB_MENU_TABLE — see .env.example.",
    });
    return;
  }
  try {
    const { rows } = await getPool().query(sql);
    res.json(
      rows.map((r) => ({
        id: String((r as Record<string, unknown>).id ?? ""),
        name: String((r as Record<string, unknown>).name ?? ""),
        description: String((r as Record<string, unknown>).description ?? ""),
        price: Number((r as Record<string, unknown>).price ?? 0),
        dips: parseJsonTextArray((r as Record<string, unknown>).dips),
        category: String((r as Record<string, unknown>).category ?? ""),
        image_base64: (r as Record<string, unknown>).image_base64 != null
          ? String((r as Record<string, unknown>).image_base64)
          : null,
      })),
    );
  } catch (err) {
    console.error(err);
    res.status(500).json({
      error: "menu query failed — check WEB_MENU_SQL / WEB_MENU_* env matches your existing tables",
    });
  }
});

app.get("/api/mobile/set-menus", async (_req, res) => {
  const sql = resolveSetMenusSql();
  if (!sql) {
    res.json([]);
    return;
  }
  try {
    const { rows } = await getPool().query(sql);
    res.json(
      rows.map((r) => ({
        name: String((r as Record<string, unknown>).name ?? ""),
        description: String((r as Record<string, unknown>).description ?? ""),
        dishes: parseJsonTextArray((r as Record<string, unknown>).dishes),
      })),
    );
  } catch (err) {
    console.error(err);
    res.status(500).json({
      error: "set menu query failed — check WEB_SET_MENUS_SQL / WEB_SET_MENU_* env",
    });
  }
});

app.post("/api/mobile/auth/signup/request-otp", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  if (!email || !email.includes("@")) {
    res.status(400).json({ error: "valid email is required" });
    return;
  }
  if (!isMailConfigured()) {
    res.status(503).json({ error: "SMTP not configured — set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD" });
    return;
  }
  const code = String(crypto.randomInt(100000, 1000000));
  const expiresAt = new Date(Date.now() + otpExpiryMinutes * 60 * 1000);
  try {
    const existing = await getPool().query("SELECT id FROM mobile_users WHERE email = $1", [email]);
    if (existing.rows[0]) {
      res.status(409).json({ error: "account already exists — log in instead" });
      return;
    }
    await getPool().query(
      `INSERT INTO mobile_otp_codes (email, code, expires_at)
       VALUES ($1, $2, $3)
       ON CONFLICT (email) DO UPDATE SET code = EXCLUDED.code, expires_at = EXCLUDED.expires_at, created_at = NOW()`,
      [email, code, expiresAt.toISOString()],
    );
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
    return;
  }
  try {
    await sendMailRequired(
      email,
      "Your Curatering signup code",
      `Your one-time code is: ${code}\n\nIt expires in ${otpExpiryMinutes} minutes.`,
    );
  } catch (err) {
    console.error(err);
    res.status(503).json({
      error: err instanceof Error ? err.message : "failed to send OTP email",
    });
    return;
  }
  res.json({ ok: true });
});

app.post("/api/mobile/auth/signup/complete", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const otp = String(req.body?.otp ?? "").trim();
  const password = String(req.body?.password ?? "");
  if (!email || !otp || password.length < 8) {
    res.status(400).json({ error: "email, otp, and password (min 8 chars) are required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      "SELECT code, expires_at FROM mobile_otp_codes WHERE email = $1",
      [email],
    );
    const row = rows[0] as { code: string; expires_at: Date } | undefined;
    if (!row || row.code !== otp || new Date(row.expires_at) < new Date()) {
      res.status(400).json({ error: "invalid or expired code" });
      return;
    }
    const hash = await bcrypt.hash(password, 10);
    try {
      await getPool().query("INSERT INTO mobile_users (email, password_hash) VALUES ($1, $2)", [email, hash]);
    } catch (e: unknown) {
      const err = e as { code?: string };
      if (err.code === "23505") {
        res.status(409).json({ error: "account already exists" });
        return;
      }
      throw e;
    }
    await getPool().query("DELETE FROM mobile_otp_codes WHERE email = $1", [email]);
    const ts = new Date().toISOString();
    await sendMailSafe(email, "Welcome to Curatering", `Your account ${email} was created at ${ts}.`);
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/auth/login", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const password = String(req.body?.password ?? "");
  if (!email || !password) {
    res.status(400).json({ error: "email and password are required" });
    return;
  }
  try {
    const { rows } = await getPool().query("SELECT password_hash FROM mobile_users WHERE email = $1", [email]);
    const hash = rows[0] ? String((rows[0] as { password_hash: string }).password_hash) : "";
    if (!hash || !(await bcrypt.compare(password, hash))) {
      res.status(401).json({ error: "invalid email or password" });
      return;
    }
    const ts = new Date().toISOString();
    await sendMailSafe(
      email,
      "Curatering login notice",
      `A login to Curatering was completed for ${email} at ${ts}. If this was not you, change your password.`,
    );
    res.json({ ok: true, email });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/profile", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT user_email, full_name, contact_number, delivery_address
       FROM mobile_profiles WHERE user_email = $1`,
      [userEmail],
    );
    if (!rows[0]) {
      res.json({
        user_email: userEmail,
        full_name: "",
        contact_number: "",
        delivery_address: "",
      });
      return;
    }
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.put("/api/mobile/profile", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const fullName = String(req.body?.full_name ?? "").trim();
  const contactNumber = String(req.body?.contact_number ?? "").trim();
  const deliveryAddress = String(req.body?.delivery_address ?? "").trim();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `INSERT INTO mobile_profiles (user_email, full_name, contact_number, delivery_address)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (user_email)
       DO UPDATE SET full_name = EXCLUDED.full_name,
                     contact_number = EXCLUDED.contact_number,
                     delivery_address = EXCLUDED.delivery_address,
                     updated_at = NOW()
       RETURNING user_email, full_name, contact_number, delivery_address`,
      [userEmail, fullName, contactNumber, deliveryAddress],
    );
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/orders", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT id, user_email, order_no, status, note, payment_mode, payment_uploaded, payment_proof,
              delivery_name, delivery_contact, delivery_address, delivery_time, total, created_at
       FROM mobile_orders
       WHERE user_email = $1
       ORDER BY created_at DESC`,
      [userEmail],
    );
    const orderIds = rows.map((r) => Number(r.id));
    let itemRows: Array<{ order_id: number; item_name: string; dip: string; qty: number; price: string }> = [];
    if (orderIds.length > 0) {
      const { rows: ir } = await getPool().query(
        `SELECT order_id, item_name, dip, qty, price
         FROM mobile_order_items WHERE order_id = ANY($1::bigint[])`,
        [orderIds],
      );
      itemRows = ir as typeof itemRows;
    }
    const byOrder = new Map<number, typeof itemRows>();
    for (const item of itemRows) {
      const arr = byOrder.get(item.order_id) ?? [];
      arr.push(item);
      byOrder.set(item.order_id, arr);
    }
    res.json(
      rows.map((row) => ({
        ...row,
        items: (byOrder.get(Number(row.id)) ?? []).map((it) => ({
          ...it,
          price: Number(it.price),
        })),
        total: Number(row.total),
      })),
    );
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/orders", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const note = String(req.body?.note ?? "");
  const paymentMode = "GCASH ONLY";
  const deliveryName = String(req.body?.delivery_name ?? "");
  const deliveryContact = String(req.body?.delivery_contact ?? "");
  const deliveryAddress = String(req.body?.delivery_address ?? "");
  const deliveryTime = "NOW";
  const items: unknown[] = Array.isArray(req.body?.items) ? (req.body.items as unknown[]) : [];
  if (!userEmail || items.length === 0) {
    res.status(400).json({ error: "user_email and items are required" });
    return;
  }
  const parsedItems = items
    .map((i) => ({
      item_name: String((i as Record<string, unknown>)?.item_name ?? ""),
      dip: String((i as Record<string, unknown>)?.dip ?? ""),
      qty: Number((i as Record<string, unknown>)?.qty ?? 0),
      price: Number((i as Record<string, unknown>)?.price ?? 0),
    }))
    .filter((i) => i.item_name && i.qty > 0 && i.price >= 0);
  if (parsedItems.length === 0) {
    res.status(400).json({ error: "valid items are required" });
    return;
  }
  const total = parsedItems.reduce((sum, i) => sum + i.qty * i.price, 0);
  const client = await getPool().connect();
  try {
    await client.query("BEGIN");
    const { rows } = await client.query(
      `INSERT INTO mobile_orders
        (user_email, order_no, note, payment_mode, delivery_name, delivery_contact, delivery_address, delivery_time, total)
       VALUES
        ($1, 'TEMP', $2, $3, $4, $5, $6, $7, $8)
       RETURNING id`,
      [userEmail, note, paymentMode, deliveryName, deliveryContact, deliveryAddress, deliveryTime, total],
    );
    const orderId = Number(rows[0].id);
    const orderNo = `MOBILE-${String(orderId).padStart(6, "0")}`;
    await client.query("UPDATE mobile_orders SET order_no = $1 WHERE id = $2", [orderNo, orderId]);
    for (const item of parsedItems) {
      await client.query(
        `INSERT INTO mobile_order_items (order_id, item_name, dip, qty, price)
         VALUES ($1, $2, $3, $4, $5)`,
        [orderId, item.item_name, item.dip, item.qty, item.price],
      );
    }
    await client.query("COMMIT");
    void sendMailSafe(
      userEmail,
      `Order ${orderNo} submitted`,
      `Your order ${orderNo} was submitted at ${new Date().toISOString()}.\nTotal: ₱${total.toFixed(2)}\nNote: ${note || "(none)"}`,
    );
    res.status(201).json({ id: orderId, order_no: orderNo, total });
  } catch (err) {
    await client.query("ROLLBACK");
    console.error(err);
    res.status(500).json({ error: "database error" });
  } finally {
    client.release();
  }
});

app.patch("/api/mobile/orders/:id/payment", async (req, res) => {
  const id = Number(req.params.id);
  const paymentProof = String(req.body?.payment_proof ?? "");
  if (!id || !paymentProof) {
    res.status(400).json({ error: "id and payment_proof are required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `UPDATE mobile_orders
       SET payment_uploaded = TRUE, payment_proof = $2, updated_at = NOW()
       WHERE id = $1
       RETURNING id, order_no, payment_uploaded`,
      [id, paymentProof],
    );
    if (!rows[0]) {
      res.status(404).json({ error: "order not found" });
      return;
    }
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/inquiries", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT id, inquiry_no, inquiry_type, event_title, event_type, customer, contact_person, contact_number,
              inquiry_email, date_of_event, note, curate_own_menu, selected_set_menu, selected_dishes,
              include_event_theme, guest_count, menu_suggestion_note, theme_suggestion_note, estimated_total,
              status, created_at
       FROM mobile_inquiries
       WHERE user_email = $1
       ORDER BY created_at DESC`,
      [userEmail],
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/inquiries", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  const inquiryType = String(req.body?.inquiry_type ?? "CATERING");
  const eventTitle = String(req.body?.event_title ?? "");
  const eventType = String(req.body?.event_type ?? "");
  const customer = String(req.body?.customer ?? "");
  const contactPerson = String(req.body?.contact_person ?? "");
  const contactNumber = String(req.body?.contact_number ?? "");
  const inquiryEmail = String(req.body?.inquiry_email ?? "");
  const dateOfEvent = String(req.body?.date_of_event ?? "");
  const note = String(req.body?.note ?? "");
  const curateOwnMenu = Boolean(req.body?.curate_own_menu);
  const selectedSetMenu = String(req.body?.selected_set_menu ?? "");
  const selectedDishes = JSON.stringify(Array.isArray(req.body?.selected_dishes) ? req.body.selected_dishes : []);
  const includeEventTheme = Boolean(req.body?.include_event_theme);
  const guestCount = Math.max(0, Number(req.body?.guest_count ?? 0));
  const menuSuggestionNote = String(req.body?.menu_suggestion_note ?? "");
  const themeSuggestionNote = String(req.body?.theme_suggestion_note ?? "");
  const estimatedTotal = Number(req.body?.estimated_total ?? 0);
  const { rows } = await getPool().query(
    `INSERT INTO mobile_inquiries
      (user_email, inquiry_no, inquiry_type, event_title, event_type, customer, contact_person, contact_number,
       inquiry_email, date_of_event, note, curate_own_menu, selected_set_menu, selected_dishes, include_event_theme,
       guest_count, menu_suggestion_note, theme_suggestion_note, estimated_total)
     VALUES
      ($1, 'TEMP', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
     RETURNING id`,
    [
      userEmail,
      inquiryType,
      eventTitle,
      eventType,
      customer,
      contactPerson,
      contactNumber,
      inquiryEmail,
      dateOfEvent,
      note,
      curateOwnMenu,
      selectedSetMenu,
      selectedDishes,
      includeEventTheme,
      guestCount,
      menuSuggestionNote,
      themeSuggestionNote,
      estimatedTotal,
    ],
  );
  const id = Number(rows[0].id);
  const inquiryNo = `MOBILE-INQ-${String(id).padStart(6, "0")}`;
  await getPool().query("UPDATE mobile_inquiries SET inquiry_no = $1 WHERE id = $2", [inquiryNo, id]);
  void sendMailSafe(
    userEmail,
    `Inquiry ${inquiryNo} received`,
    `Your catering inquiry ${inquiryNo} was submitted at ${new Date().toISOString()}.\nEvent: ${eventTitle || "(no title)"}`,
  );
  res.status(201).json({ id, inquiry_no: inquiryNo });
});

app.post("/api/mobile/help", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const area = String(req.body?.area ?? "").trim();
  const problem = String(req.body?.problem ?? "").trim();
  const desiredOutcome = String(req.body?.desired_outcome ?? "").trim();
  if (!userEmail || !area || !problem || !desiredOutcome) {
    res.status(400).json({ error: "user_email, area, problem, and desired_outcome are required" });
    return;
  }
  try {
    await getPool().query(
      `INSERT INTO mobile_help_requests (user_email, area, problem, desired_outcome)
       VALUES ($1, $2, $3, $4)`,
      [userEmail, area, problem, desiredOutcome],
    );
    void sendMailSafe(
      userEmail,
      "Help request received",
      `We recorded your help request.\nArea: ${area}\nProblem: ${problem}\nWhat you'd like: ${desiredOutcome}`,
    );
    res.status(201).json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

async function main() {
  await initDb();
  app.listen(port, () => {
    console.log(`curatering-backend listening on http://localhost:${port}`);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
