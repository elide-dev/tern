import { test, expect } from "bun:test";
import { connect, createServer, type Socket } from "node:net";
import { previewClock } from "../compose/clock";

// This integration exercises the platform interval against real TCP I/O: the peer
// deliberately withholds completion while the event loop continues ticking.
async function until(condition: () => boolean) {
  const deadline = Date.now() + 5000;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for preview protocol state");
    await Bun.sleep(10);
  }
}

/** A renderer peer behind a clock, configured with two hosted cards. */
async function hosted(showing: () => boolean) {
  const token = "a".repeat(64);
  const commands: Record<string, unknown>[] = [];
  let renderer: Socket | undefined;
  const peer = createServer(socket => {
    renderer = socket;
    socket.setEncoding("utf8");
    let lines = "";
    socket.on("data", data => {
      lines += data;
      let end: number;
      while ((end = lines.indexOf("\n")) >= 0) {
        const line = lines.slice(0, end); lines = lines.slice(end + 1);
        if (line !== token) commands.push(JSON.parse(line));
      }
    });
  });
  const listening = Promise.withResolvers<void>();
  peer.once("error", listening.reject);
  peer.listen(0, "127.0.0.1", listening.resolve);
  await listening.promise;
  const address = peer.address();
  if (!address || typeof address === "string") throw new Error("Missing peer port");
  const controller = new AbortController();
  const clock = await previewClock({ protocol: 2, port: address.port, token }, controller.signal, showing);
  const backend = connect({ host: "127.0.0.1", port: clock.port });
  backend.on("error", () => {});
  backend.resume();
  const send = (command: string) => backend.write(JSON.stringify({ command }) + "\n");
  const emit = (value: Record<string, unknown>) => renderer!.write(JSON.stringify(value) + "\n");
  const frames = () => commands.filter(command => command.command === "frame").length;
  const close = () => { controller.abort(); clock.dispose(); backend.destroy(); renderer?.destroy(); peer.close(); };
  backend.write(token + "\n");
  await until(() => renderer !== undefined);
  send("configure");
  await until(() => commands.some(command => command.command === "configure"));
  emit({ event: "configured" });
  send("entries");
  await until(() => commands.some(command => command.command === "entries"));
  emit({ event: "entries", hosted: ["first", "second"] });
  return { commands, send, emit, frames, close, controller, backend, renderer: () => renderer! };
}

test("idle clock bounds outstanding frames and pauses across failed compilations", async () => {
  const { commands, send, emit, frames, close, controller, backend, renderer } = await hosted(() => true);
  try {
    await until(() => frames() === 1);
    await Bun.sleep(300);
    expect(frames()).toBe(1); // A slow renderer cannot accumulate frame requests.
    emit({ event: "frame", entry: "first" });
    await Bun.sleep(300);
    expect(frames()).toBe(1); // Every card must complete, not just the first.
    emit({ event: "frame", entry: "second" });
    await until(() => frames() === 2);

    send("sources");
    await until(() => commands.some(command => command.command === "sources"));
    emit({ event: "compile", outcome: "failure" });
    await Bun.sleep(300);
    expect(frames()).toBe(2);
    send("sources");
    await until(() => commands.filter(command => command.command === "sources").length === 2);
    emit({ event: "compile", outcome: "success" });
    await until(() => frames() === 3);

    controller.abort();
    await until(() => backend.destroyed && renderer().destroyed);
    expect(frames()).toBe(3);
  } finally {
    close();
  }
}, 10000);

test("idle clock requests no frames while no page shows the cards", async () => {
  let showing = false;
  const { frames, close } = await hosted(() => showing);
  try {
    await Bun.sleep(400);
    expect(frames()).toBe(0);
    showing = true;
    await until(() => frames() === 1);
  } finally {
    close();
  }
}, 10000);
