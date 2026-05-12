/**
 * Load `.env` from predictable locations so SMTP/DB work when the process
 * cwd is the monorepo root, `packages/frontend`, etc. (dotenv/config only reads cwd.)
 */
import dotenv from "dotenv";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const envPaths = [
  path.resolve(__dirname, "../.env"),
  path.resolve(__dirname, "../../packages/backend/.env"),
  path.resolve(process.cwd(), "packages/backend/.env"),
  path.resolve(process.cwd(), ".env"),
];

dotenv.config();
for (const p of envPaths) {
  if (fs.existsSync(p)) {
    dotenv.config({ path: p, override: true });
  }
}
