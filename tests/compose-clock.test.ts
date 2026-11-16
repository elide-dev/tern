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

test("idle clock bounds outstanding frames and pauses across failed compilations", async () => {
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
  const clock = await previewClock({ protocol: 2, port: address.port, token }, controller.signal);
  const backend = connect({ host: "127.0.0.1", port: clock.port });
  backend.on("error", () => {});
  backend.resume();
  const send = (command: string) => backend.write(JSON.stringify({ command }) + "\n");
  const emit = (value: Record<string, unknown>) => renderer!.write(JSON.stringify(value) + "\n");
  const frames = () => commands.filter(command => command.command === "frame").length;
  try {
    backend.write(token + "\n");
    await until(() => renderer !== undefined);
    send("configure");
    await until(() => commands.some(command => command.command === "configure"));
    emit({ event: "configured" });
    send("entries");
    await until(() => commands.some(command => command.command === "entries"));
    emit({ event: "entries", hosted: ["first", "second"] });
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
    await until(() => backend.destroyed && renderer!.destroyed);
    expect(frames()).toBe(3);
  } finally {
    controller.abort(); clock.dispose(); backend.destroy(); renderer?.destroy(); peer.close();
  }
}, 10000);
