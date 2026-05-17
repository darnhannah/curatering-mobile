import "dotenv/config";
import pg from "pg";
import { dedupeCustomerAccountIds } from "./schemaNormalize.js";

async function main(): Promise<void> {
  const url = process.env.DATABASE_URL;
  if (!url) {
    console.error("DATABASE_URL is required");
    process.exit(1);
  }
  const pool = new pg.Pool({ connectionString: url });
  try {
    await dedupeCustomerAccountIds(pool);
    console.info("[renumber] done");
  } finally {
    await pool.end();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
