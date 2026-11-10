import { readFile } from "node:fs/promises";
import path from "node:path";
import { ImageStore, type PreviewBuild, type PreviewKeyEvent } from "@elide/compose-backend";
import { KomodoBackend } from "@elide/compose-komodo";
import type { PreviewImage } from "@elide/compose-render";
import type { ComposeRuntime } from "@elide/compose-runtime";
import { createKomodo, type KomodoClient } from "./komodo";
import { previewClock, type ClockSession } from "./clock";

export interface LivePreview {
  readonly images: PreviewImage[];
  pointer(id: string, action: "down" | "up" | "move" | "scroll", x: number, y: number, dx?: number, dy?: number): boolean;
  keyboard(id: string, event: PreviewKeyEvent): boolean;
  blur(id: string): boolean;
  keyboardSupported(id: string): boolean;
  refresh(): Promise<PreviewImage[]>;
  dispose(): Promise<void>;
}

export interface LiveOptions {
  runtime: string;
  root: string;
  source: string;
  packageName: string;
  build: PreviewBuild;
  composeRuntime: ComposeRuntime;
  java: string;
  helpers: string;
  cache: string;
  signal: AbortSignal;
  log: (line: string) => void;
  launcher?: string;
  onImages: (images: PreviewImage[]) => void;
  onStatus: (phase: string, message: string) => void;
  onReset: () => void;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Saved-source adapter for the same live backend used by the VSCode preview panel. */
export async function startLive(options: LiveOptions): Promise<LivePreview> {
  const controller = new AbortController();
  const signal = AbortSignal.any([options.signal, controller.signal]);
  let opening: Promise<KomodoClient> | undefined;
  let backend: KomodoBackend | undefined;
  let clock: ClockSession | undefined;
  let images: PreviewImage[] = [];
  let disposed = false;
  let disposal: Promise<void> | undefined;
  let published = false;
  let compileFailure: string | undefined;
  let discoveryFailure: string | undefined;
  let sessionFailure: string | undefined;
  const subscriptions: (() => void)[] = [];

  const report = (): void => {
    if (disposed) return;
    const failure = sessionFailure ?? compileFailure ?? discoveryFailure;
    if (failure) options.onStatus("error", failure);
    else if (published) {
      const failed = images.filter((image) => image.error !== undefined).length;
      options.onStatus("live", `${images.length} live preview${images.length === 1 ? "" : "s"}${failed ? ` · ${failed} failed card${failed === 1 ? "" : "s"}` : ""}`);
    }
  };

  const dispose = (): Promise<void> => {
    if (disposal) return disposal;
    disposed = true;
    options.signal.removeEventListener("abort", abort);
    for (const unsubscribe of subscriptions) unsubscribe();
    // Close native scenes and compiler workers before stopping their language server.
    backend?.dispose();
    clock?.dispose();
    controller.abort(new Error("Compose live preview disposed."));
    disposal = (async () => {
      // An abort during startup must also reap a client that finishes opening late.
      const client = await opening?.catch(() => undefined);
      try { await client?.dispose(); }
      finally { options.onReset(); }
    })();
    return disposal;
  };
  const abort = (): void => {
    void dispose().catch((error: unknown) => options.log(`Compose live cleanup failed: ${message(error)}`));
  };
  options.signal.addEventListener("abort", abort, { once: true });

  try {
    signal.throwIfAborted();
    options.onStatus("runtime", "Starting the Komodo language server…");
    signal.throwIfAborted();
    opening = createKomodo({
      runtime: options.runtime,
      root: options.root,
      models: options.build.models,
      java: options.java,
      signal,
      log: options.log,
      launcher: options.launcher,
    });
    const client = await opening;
    signal.throwIfAborted();
    const live = backend = new KomodoBackend(
      `${options.root}\0${options.source}`,
      options.cache,
      options.helpers,
      new ImageStore(path.join(options.cache, "compose-images")),
      {
        previews: async (file) => {
          const found = await client.previews(file);
          signal.throwIfAborted();
          discoveryFailure = found.errors.length ? found.errors.map((error) => error.message).join("\n") : undefined;
          for (const error of found.errors) options.log(`Komodo discovery: ${error.message}`);
          report();
          return found;
        },
        session: async (file) => {
          clock?.dispose();
          const session = await client.session(file);
          clock = await previewClock(session, signal);
          return clock;
        },
        sync: (files) => client.sync(files),
        log: options.log,
        unavailable: (reason) => {
          sessionFailure = reason;
          report();
        },
      },
    );
    subscriptions.push(
      live.onImages((updates) => {
        if (disposed || !published) return;
        // Events are partial galleries. Replace cards, including failures, without
        // resurrecting declarations removed by the most recent full preview.
        const changed = new Map(updates.map((image) => [image.id, image]));
        images = images.map((image) => changed.get(image.id) ?? image);
        options.onImages(updates.filter((update) => images.some((image) => image.id === update.id)));
      }),
      live.onCompile((outcome) => {
        if (disposed) return;
        const diagnostics = outcome.messages.map((entry) => {
          const at = entry.file ? `${entry.file}${entry.line === undefined ? "" : `:${entry.line}${entry.column === undefined ? "" : `:${entry.column}`}`}: ` : "";
          return `${at}${entry.level}: ${entry.text}`;
        });
        for (const diagnostic of diagnostics) options.log(diagnostic);
        compileFailure = outcome.failed ? diagnostics.join("\n") || "Komodo could not compile the saved preview source." : undefined;
        report();
      }),
      live.onInputReset(() => { if (!disposed) options.onReset(); }),
      live.onSessionLost(() => {
        if (disposed) return;
        sessionFailure = "The Komodo preview session closed. Refresh or rebuild to reconnect.";
        report();
      }),
    );

    options.onStatus("runtime", "Opening the live Compose session…");
    await live.prepareSession(options.source, false, signal);
    signal.throwIfAborted();
    await live.startRenderer(options.composeRuntime);
    options.onStatus("rendering", "Preparing shared Compose compiler inputs…");
    const documents = new Map([[options.source, await readFile(options.source, { encoding: "utf8", signal })]]);
    signal.throwIfAborted();
    await live.configure(options.build, documents, false);
    signal.throwIfAborted();

    let refreshing: Promise<unknown> = Promise.resolve();
    const refresh = (): Promise<PreviewImage[]> => {
      const next = refreshing.then(async () => {
        signal.throwIfAborted();
        const text = await readFile(options.source, { encoding: "utf8", signal });
        // Synchronize discovery too: preview() itself detects changed declarations
        // and replaces the daemon entries rather than retaining a static gallery.
        await client.sync([options.source]);
        signal.throwIfAborted();
        const gallery = await live.preview({
          sourceFile: options.source,
          packageName: options.packageName,
          documents: new Map([[options.source, text]]),
        });
        signal.throwIfAborted();
        images = [...live.latestImages(gallery.images)];
        sessionFailure = undefined;
        published = true;
        options.onImages(images);
        report();
        return images;
      }).catch((error: unknown) => {
        if (!disposed && !signal.aborted) options.onStatus("error", message(error));
        throw error;
      });
      refreshing = next.catch(() => {});
      return next;
    };

    options.onStatus("rendering", "Rendering live Compose previews…");
    await refresh();
    signal.throwIfAborted();
    return {
      get images() { return images; },
      pointer: (id, action, x, y, dx, dy) => !disposed && live.pointer(id, action, x, y, dx, dy),
      keyboard: (id, event) => !disposed && live.keyboard(id, event),
      blur: (id) => !disposed && live.blur(id),
      keyboardSupported: (id) => !disposed && live.keyboardSupported(id),
      refresh,
      dispose,
    };
  } catch (error) {
    try { await dispose(); }
    catch (cleanupError) { options.log(`Compose live cleanup failed: ${message(cleanupError)}`); }
    throw error;
  }
}
