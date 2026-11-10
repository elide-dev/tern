import { spawn } from "node:child_process";
import { constants } from "node:fs";
import { access, realpath, stat } from "node:fs/promises";
import path from "node:path";
import { killProcessTree, whichExecutable } from "@elide/ide-core";

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export async function executable(value: string, label: string): Promise<string> {
  const candidate = value.includes("/") || value.includes("\\") ? path.resolve(value) : whichExecutable(value);
  try {
    if (!candidate) throw new Error("not found");
    const resolved = await realpath(candidate);
    if (!(await stat(resolved)).isFile()) throw new Error("not a file");
    await access(resolved, constants.X_OK);
    return resolved;
  } catch {
    throw new Error(`${label} executable not found or not executable: ${value}`);
  }
}

/** No shell; every finite child has a deadline and a bounded combined output capture. */
export function run(file: string, args: string[], options: {
  cwd?: string; env?: NodeJS.ProcessEnv; input?: string; timeout?: number;
} = {}): Promise<string> {
  const { promise, resolve, reject } = Promise.withResolvers<string>();
  const child = spawn(file, args, {
    cwd: options.cwd, env: { ...process.env, NO_COLOR: "1", ...options.env },
    detached: process.platform !== "win32", stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  let size = 0;
  let failure: Error | undefined;
  const terminate = (message: string) => {
    failure ??= new Error(message);
    if (child.pid !== undefined) killProcessTree(child.pid, "SIGKILL");
  };
  const timeout = options.timeout ?? 30_000;
  const timer = setTimeout(() => terminate(`${path.basename(file)} timed out after ${timeout / 1000}s.`), timeout);
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  const capture = (text: string, err: boolean) => {
    size += Buffer.byteLength(text);
    if (size > 4 * 1024 * 1024) return terminate(`${path.basename(file)} exceeded the 4 MiB output limit.`);
    if (err) stderr += text;
    else stdout += text;
  };
  child.stdout.on("data", text => capture(text, false));
  child.stderr.on("data", text => capture(text, true));
  child.stdin.on("error", () => {}); // A command can finish without reading its input.
  child.stdin.end(options.input ?? "");
  child.once("error", error => { clearTimeout(timer); reject(new Error(`Cannot run ${file}: ${errorMessage(error)}`)); });
  child.once("close", (code, signal) => {
    clearTimeout(timer);
    const detail = (stderr.trim() || stdout.trim()).slice(-16_384);
    if (failure || code !== 0) {
      reject(new Error(`${failure?.message ?? `${path.basename(file)} failed (${signal ?? code}).`}${detail ? `\n${detail}` : ""}`));
    } else resolve(stdout);
  });
  return promise;
}
