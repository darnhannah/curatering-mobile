# curatering-backend

HTTP API with Express and **PostgreSQL** (e.g. Supabase). Connection string comes from `DATABASE_URL` in `.env` (never commit `.env`).

## Setup

```bash
npm install
cp .env.example .env
# Edit .env — paste your Supabase DATABASE_URL from the project settings (Database → Connection string → URI).
```

## Run

```bash
npm run dev
```

- Health: `GET http://localhost:8080/health`
- List rows: `GET http://localhost:8080/api/items`
- Create row: `POST http://localhost:8080/api/items` with JSON `{ "title": "Example" }`

On startup the server runs `CREATE TABLE IF NOT EXISTS items (...)` so the `items` table is created in your online DB the first time you run it.

## Supabase notes

- **Pooler (port 6543):** fine for this API. If you see prepared-statement errors with PgBouncer, switch the URI to the **session** pooler or **direct** connection from the Supabase dashboard and update `DATABASE_URL`.
- **`sslmode=require`** is added automatically if your URL does not already include it.

## Production build

```bash
npm run build
npm start
```
