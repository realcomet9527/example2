import { bench, run } from "mitata";
import { createRequire } from "module";
const db = createRequire(import.meta.url)("better-sqlite3")(
  "/tmp/northwind.sqlite"
);

{
  const sql = db.prepare(`SELECT * FROM "Order"`);

  bench('SELECT * FROM "Order" (objects)', () => {
    sql.all();
  });
}

{
  const sql = db.prepare(`SELECT * FROM "Product"`);

  bench('SELECT * FROM "Product" (objects)', () => {
    sql.all();
  });
}

{
  const sql = db.prepare(`SELECT * FROM "OrderDetail"`);

  bench('SELECT * FROM "OrderDetail" (objects)', () => {
    sql.all();
  });
}

run({ json: false });
