var tab = "\t";
var シ = "wow";
var f = "";
var obj = {
  "\r\n": "\r\n",
  "\n": "\n",
  "\t": "\t",
  "\u2028": "\u2028",
  "\u2029": "\u2029",
  "😊": "😊",
  "😃": "😃",
  "㋡": "㋡",
  "☺": "☺",
  シ: "シ",
  f: f,
  "☹": "☹",
  "☻": "☻",
  children: 123,
};
const foo = () => {};
const Bar = foo("a", {
  children: 123,
});

const carriage = obj["\r\n"];
const newline = obj["\n"];

export { obj };

export function test() {
  console.assert(carriage === "\r\n");
  console.assert(newline === "\n");
  console.assert(tab === "\t");
  return testDone(import.meta.url);
}
