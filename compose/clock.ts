import { connect, createServer, type Socket } from "node:net";
import { StringDecoder } from "node:string_decoder";
import { timingSafeEqual } from "node:crypto";

export interface PreviewSession {
  protocol: number;
  port: number;
  token: string;
  pid?: number;
}

export interface ClockSession extends PreviewSession {
  dispose(): void;
}

/**
 * Keep Android's clock advancing when layoutlib stops requesting frames after two
 * identical images (a delayed coroutine or the turning point of an animation).
 * The shared backend still owns the protocol and scenes. This authenticated local
 * bridge only requests idle frames, with at most one outstanding frame per card.
 */
export async function previewClock(session: PreviewSession, signal: AbortSignal): Promise<ClockSession> {
  signal.throwIfAborted();
  if (!/^[a-f0-9]{64}$/.test(session.token)) throw new Error("Komodo returned an unsupported preview session token.");
  let downstream: Socket | undefined;
  let upstream: Socket | undefined;
  let timer: NodeJS.Timeout | undefined;
  let disposed = false;
  let configured = false;
  let busy = true;
  let lastFrame = Date.now();
  const active = new Set<string>();
  const pending = new Set<string>();
  const server = createServer(client => {
    if (downstream || disposed) { client.destroy(); return; }
    downstream = client;
    client.setTimeout(5000, dispose);
    let auth = Buffer.alloc(0);
    const authenticate = (chunk: Buffer) => {
      auth = Buffer.concat([auth, chunk]);
      const end = auth.indexOf(10);
      if (end < 0 && auth.length <= 64) return;
      if (end !== 64 || !timingSafeEqual(auth.subarray(0, end), Buffer.from(session.token))) { dispose(); return; }
      client.off("data", authenticate);
      client.setTimeout(0);
      server.close();
      upstream = connect({ host: "127.0.0.1", port: session.port });
      upstream.on("error", dispose);
      upstream.on("close", dispose);
      const commands = lines(value => {
        if (["configure", "entries", "sources"].includes(value.command)) { busy = true; pending.clear(); }
        if (value.command === "configure") { configured = false; active.clear(); }
      });
      const events = lines(value => {
        if (value.event === "configured") { configured = true; busy = active.size === 0; }
        if (value.event === "compile") busy = value.outcome === "failure";
        if (value.event === "entries") {
          active.clear(); pending.clear();
          for (const id of Array.isArray(value.hosted) ? value.hosted : []) if (typeof id === "string") active.add(id);
          busy = false;
        } else if (value.event === "frame" && typeof value.entry === "string") {
          lastFrame = Date.now(); pending.delete(value.entry);
          if (configured) busy = false;
        } else if (value.event === "error") {
          if (typeof value.entry === "string") { active.delete(value.entry); pending.delete(value.entry); }
          else busy = true;
        }
      });
      // Observe complete protocol lines without rewriting them; pipe preserves backpressure.
      client.on("data", commands);
      upstream.on("data", events);
      upstream.pipe(client);
      upstream.write(auth);
      client.pipe(upstream);
      auth = Buffer.alloc(0);
      timer = setInterval(() => {
        if (busy || !configured || pending.size || !active.size || Date.now() - lastFrame < 100 || !upstream || upstream.writableLength) return;
        for (const id of active) pending.add(id);
        upstream.write('{"command":"frame"}\n');
      }, 50);
    };
    client.on("data", authenticate);
    client.on("error", dispose);
    client.on("close", dispose);
  });
  function dispose() {
    if (disposed) return;
    disposed = true;
    clearInterval(timer);
    downstream?.destroy(); upstream?.destroy(); server.close();
    signal.removeEventListener("abort", dispose);
  }
  function lines(consume: (value: Record<string, any>) => void) {
    const decoder = new StringDecoder("utf8");
    let buffered = "";
    return (chunk: Buffer) => {
      buffered += decoder.write(chunk);
      if (buffered.length > 16 * 1024 * 1024) { dispose(); return; }
      let end: number;
      while ((end = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, end); buffered = buffered.slice(end + 1);
        try { const value = JSON.parse(line); if (value && typeof value === "object") consume(value); }
        catch { dispose(); return; }
      }
    };
  }
  const listening = Promise.withResolvers<void>();
  server.once("error", listening.reject);
  server.once("close", () => listening.reject(signal.reason ?? new Error("Preview frame clock closed before listening.")));
  server.listen(0, "127.0.0.1", listening.resolve);
  signal.addEventListener("abort", dispose, { once: true });
  try {
    await listening.promise;
    signal.throwIfAborted();
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Cannot start the preview frame clock.");
    return { ...session, port: address.port, dispose };
  } catch (error) { dispose(); throw error; }
}
