import {
  file,
  gc,
  readableStreamToArrayBuffer,
  readableStreamToArray,
} from "bun";
import { expect, it } from "bun:test";
import { writeFileSync } from "node:fs";

it("exists globally", () => {
  expect(typeof ReadableStream).toBe("function");
  expect(typeof ReadableStreamBYOBReader).toBe("function");
  expect(typeof ReadableStreamBYOBRequest).toBe("function");
  expect(typeof ReadableStreamDefaultController).toBe("function");
  expect(typeof ReadableStreamDefaultReader).toBe("function");
  expect(typeof TransformStream).toBe("function");
  expect(typeof TransformStreamDefaultController).toBe("function");
  expect(typeof WritableStream).toBe("function");
  expect(typeof WritableStreamDefaultController).toBe("function");
  expect(typeof WritableStreamDefaultWriter).toBe("function");
  expect(typeof ByteLengthQueuingStrategy).toBe("function");
  expect(typeof CountQueuingStrategy).toBe("function");
});

it("ReadableStream (bytes)", async () => {
  var stream = new ReadableStream({
    start(controller) {
      controller.enqueue(Buffer.from("abdefgh"));
    },
    pull(controller) {},
    cancel() {},
    type: "bytes",
  });
  const chunks = [];
  const chunk = await stream.getReader().read();
  chunks.push(chunk.value);
  expect(chunks[0].join("")).toBe(Buffer.from("abdefgh").join(""));
});

it("ReadableStream (default)", async () => {
  var stream = new ReadableStream({
    start(controller) {
      controller.enqueue(Buffer.from("abdefgh"));
      controller.close();
    },
    pull(controller) {},
    cancel() {},
  });
  const chunks = [];
  const chunk = await stream.getReader().read();
  chunks.push(chunk.value);
  expect(chunks[0].join("")).toBe(Buffer.from("abdefgh").join(""));
});

it("readableStreamToArray", async () => {
  var queue = [Buffer.from("abdefgh")];
  var stream = new ReadableStream({
    pull(controller) {
      var chunk = queue.shift();
      if (chunk) {
        controller.enqueue(chunk);
      } else {
        controller.close();
      }
    },
    cancel() {},
    type: "bytes",
  });

  const chunks = await readableStreamToArray(stream);

  expect(chunks[0].join("")).toBe(Buffer.from("abdefgh").join(""));
});

it("readableStreamToArrayBuffer (bytes)", async () => {
  var queue = [Buffer.from("abdefgh")];
  var stream = new ReadableStream({
    pull(controller) {
      var chunk = queue.shift();
      if (chunk) {
        controller.enqueue(chunk);
      } else {
        controller.close();
      }
    },
    cancel() {},
    type: "bytes",
  });
  const buffer = await readableStreamToArrayBuffer(stream);
  expect(new TextDecoder().decode(new Uint8Array(buffer))).toBe("abdefgh");
});

it("readableStreamToArrayBuffer (default)", async () => {
  var queue = [Buffer.from("abdefgh")];
  var stream = new ReadableStream({
    pull(controller) {
      var chunk = queue.shift();
      if (chunk) {
        controller.enqueue(chunk);
      } else {
        controller.close();
      }
    },
    cancel() {},
  });

  const buffer = await readableStreamToArrayBuffer(stream);
  expect(new TextDecoder().decode(new Uint8Array(buffer))).toBe("abdefgh");
});

it("ReadableStream for Blob", async () => {
  var blob = new Blob(["abdefgh", "ijklmnop"]);
  expect(await blob.text()).toBe("abdefghijklmnop");
  var stream = blob.stream();
  const chunks = [];
  var reader = stream.getReader();
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    chunks.push(new TextDecoder().decode(chunk.value));
  }
  expect(chunks.join("")).toBe(
    new TextDecoder().decode(Buffer.from("abdefghijklmnop"))
  );
});

it("ReadableStream for File", async () => {
  var blob = file(import.meta.dir + "/fetch.js.txt");
  var stream = blob.stream(24);
  const chunks = [];
  var reader = stream.getReader();
  stream = undefined;
  while (true) {
    const chunk = await reader.read();
    gc(true);
    if (chunk.done) break;
    chunks.push(chunk.value);
    expect(chunk.value.byteLength <= 24).toBe(true);
    gc(true);
  }
  reader = undefined;
  const output = new Uint8Array(await blob.arrayBuffer()).join("");
  const input = chunks.map((a) => a.join("")).join("");
  expect(output).toBe(input);
  gc(true);
});

it("ReadableStream for File errors", async () => {
  try {
    var blob = file(import.meta.dir + "/fetch.js.txt.notfound");
    blob.stream().getReader();
    throw new Error("should not reach here");
  } catch (e) {
    expect(e.code).toBe("ENOENT");
    expect(e.syscall).toBe("open");
  }
});

it("ReadableStream for empty blob closes immediately", async () => {
  var blob = new Blob([]);
  var stream = blob.stream();
  const chunks = [];
  var reader = stream.getReader();
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    chunks.push(chunk.value);
  }

  expect(chunks.length).toBe(0);
});

it("ReadableStream for empty file closes immediately", async () => {
  writeFileSync("/tmp/bun-empty-file-123456", "");
  var blob = file("/tmp/bun-empty-file-123456");
  var stream = blob.stream();
  const chunks = [];
  var reader = stream.getReader();
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    chunks.push(chunk.value);
  }

  expect(chunks.length).toBe(0);
});
