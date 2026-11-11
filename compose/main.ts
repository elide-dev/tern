import { format } from "node:util";
import licenses from "@elide/compose-licenses";
import { message, open, serve, type OpenArgs, type ServeArgs } from "./service";

const USAGE = "Usage: elide-tern-compose open --runtime <elide> --root <project/workspace> --file <saved.kt> --cache <directory> [--java <java-executable>] [--komodo <launcher>] [--keep-alive <minutes>]\n"
  + "       elide-tern-compose serve --runtime <elide> --root <workspace> --cache <directory> --state <file> [--java <java-executable>] [--komodo <launcher>]\n"
  + "       elide-tern-compose --help | --licenses\n";

function parseArgs(argv: string[], names: readonly string[], required: readonly string[]): Record<string, string> {
  const values: Record<string, string> = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]?.slice(2);
    const value = argv[i + 1];
    if (!argv[i]?.startsWith("--") || !key || !names.includes(key) || key in values || !value || value.startsWith("--")) {
      throw new Error(`Invalid argument ${argv[i] ?? ""}.\n${USAGE}`);
    }
    values[key] = value;
  }
  for (const key of required) if (!values[key]) throw new Error(`Missing --${key}.\n${USAGE}`);
  return values;
}

async function readStdin(): Promise<string> {
  if (process.stdin.isTTY) return "";
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 40 * 1024 * 1024) throw new Error("Editor documents on stdin exceed 40 MiB.");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

// Dependencies may log diagnostics; stdout is reserved for the machine-readable result.
for (const method of ["log", "info", "debug"] as const) console[method] = (...args: unknown[]) => { process.stderr.write(`${format(...args)}\n`); };
const [command, ...rest] = process.argv.slice(2);
if (command === "--help" && !rest.length) process.stdout.write(USAGE);
else if (command === "--licenses" && !rest.length) process.stdout.write(`${licenses}\n`);
else if (command === "open") {
  try {
    const args = parseArgs(rest, ["runtime", "root", "file", "cache", "java", "komodo", "keep-alive"], ["runtime", "root", "file", "cache"]) as OpenArgs;
    process.stdout.write(`${JSON.stringify(await open(args, await readStdin()))}\n`);
    process.exit(0);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ error: message(error).slice(0, 8192) })}\n`);
    process.exit(1);
  }
} else if (command === "serve") {
  try {
    await serve(parseArgs(rest, ["runtime", "root", "cache", "state", "java", "komodo"], ["runtime", "root", "cache", "state"]) as ServeArgs);
  } catch (error) {
    process.stderr.write(`${message(error)}\n`);
    process.exit(1);
  }
} else {
  process.stderr.write(USAGE);
  process.exit(2);
}
