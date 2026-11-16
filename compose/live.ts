import path from "node:path";
import type { ProjectModel } from "@elide/ide-core";
import { ImageStore, type CompileMessage } from "@elide/compose-backend";
import { KomodoBackend } from "@elide/compose-komodo";
import type { PreviewImage } from "@elide/compose-render";
import { createKomodo, type KomodoClient } from "./komodo";
import { previewClock, type ClockSession } from "./clock";

/** The Komodo language server of a workspace and the shared backend of the application it previews. */
export interface Stack {
  readonly java: string;
  readonly client: KomodoClient;
  backend: KomodoBackend;
  /** The application the backend previews (`<model root>\0<target>`). */
  key: string;
  /** Another application of the workspace: a new backend on the same language server. */
  replaceBackend(key: string): KomodoBackend;
  dispose(): Promise<void>;
}

export interface StackOptions {
  runtime: string;
  root: string;
  models: readonly ProjectModel[];
  java: string;
  launcher?: string;
  cache: string;
  helpers: string;
  key: string;
  signal: AbortSignal;
  log(line: string): void;
  /** Unsaved editor texts by path, which the language server analyses instead of the files. */
  overlays(): ReadonlyMap<string, string>;
  /** Whether a page shows the cards: the idle frame clock pauses otherwise. */
  clockActive(): boolean;
  onImages(images: PreviewImage[]): void;
  onCompile(outcome: { failed: boolean; messages: CompileMessage[] }): void;
  onInputReset(): void;
  onSessionLost(): void;
  onUnavailable(reason: string): void;
}

export async function createStack(options: StackOptions): Promise<Stack> {
  const controller = new AbortController();
  const signal = AbortSignal.any([options.signal, controller.signal]);
  const client = await createKomodo({
    runtime: options.runtime,
    root: options.root,
    models: options.models,
    java: options.java,
    signal,
    log: options.log,
    launcher: options.launcher,
    getDocuments: options.overlays,
  });
  let clock: ClockSession | undefined;
  let subscriptions: (() => void)[] = [];
  let disposal: Promise<void> | undefined;
  const create = (key: string): KomodoBackend => {
    const backend = new KomodoBackend(key, options.cache, options.helpers, new ImageStore(path.join(options.cache, "compose-images")), {
      previews: async (file) => {
        const found = await client.previews(file);
        for (const error of found.errors) options.log(`Komodo discovery: ${error.message}`);
        return found;
      },
      session: async (file) => {
        clock?.dispose();
        clock = await previewClock(await client.session(file), signal, options.clockActive);
        return clock;
      },
      sync: (files) => client.sync(files),
      log: options.log,
      unavailable: options.onUnavailable,
    });
    subscriptions = [
      backend.onImages(options.onImages),
      backend.onCompile(options.onCompile),
      backend.onInputReset(() => options.onInputReset()),
      backend.onSessionLost(options.onSessionLost),
    ];
    return backend;
  };
  // Close native scenes and compiler workers before their clock and language server.
  const drop = (backend: KomodoBackend): void => {
    for (const unsubscribe of subscriptions) unsubscribe();
    subscriptions = [];
    backend.dispose();
    clock?.dispose();
    clock = undefined;
  };
  const stack: Stack = {
    java: options.java,
    client,
    backend: create(options.key),
    key: options.key,
    replaceBackend(key) {
      drop(stack.backend);
      stack.key = key;
      stack.backend = create(key);
      return stack.backend;
    },
    dispose() {
      disposal ??= (async () => {
        drop(stack.backend);
        controller.abort(new Error("Compose preview stopped."));
        await client.dispose();
      })();
      return disposal;
    },
  };
  return stack;
}
