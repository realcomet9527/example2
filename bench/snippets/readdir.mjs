import { readdirSync } from "fs";
import { bench, run } from "mitata";
import { argv } from "process";

const dir = argv.length > 2 ? argv[2] : "/tmp";

const count = readdirSync(dir).length;
bench(`readdir("${dir}")`, () => {
  readdirSync(dir);
});

await run();
console.log("\n\nFor", count, "files/dirs in", dir);
