import path from "node:path";
import { errorMessage } from "./process";
import { createConfigured, projectInfo, ProjectChoiceError, resolveProject, resolveSdk } from "./project";
import { AndroidSdk, validateName } from "./sdk";
import { runView } from "./view";

const USAGE = `Usage: elide-tern-android COMMAND [OPTIONS]

Commands:
  list       List AVDs and their running emulator serials
  images     List installed system-image package IDs (no downloads)
  profiles   List hardware profile IDs and names
  create     Create a new AVD; never overwrite an existing AVD
  start      Start an existing AVD in a visible, detached emulator
  stop       Stop only the selected emulator
  delete     Delete a stopped AVD (requires --yes)
  view       Open a live emulator view; runs until closed or disconnected

Options:
  --json              Print one JSON result object (errors also on stderr)
  --sdk PATH          Explicit Android SDK; overrides project/environment lookup
  --root PATH         Android Elide project, or workspace with one Android member
  --runtime PATH      Elide executable for project resolution (not needed standalone)
  --name NAME         AVD name (defaults to the project's configured AVD)
  --image PACKAGE     Installed system-images;android-API;VARIANT;ABI (create)
  --device PROFILE    Hardware profile ID (create; list with profiles)
  --serial SERIAL     Exact emulator-PORT to stop or view
  --headless          Start without an emulator window
  --yes               Confirm deletion; never accepts SDK licenses
  --job PATH          Absolute private job directory for managed view sessions
  --help              Show this help

Standalone create requires --name, --image and --device. In project mode,
create without those options uses Elide's configured android-avd build target.
Pass an Android member directory with --root if a workspace is ambiguous.
Start does not create an AVD or install SDK components. Stop/view --serial
never targets a physical device. View prints {url,serial} once unless --job
is supplied (then writes job/view.json). No Elide runtime is needed without --root.
`;

type Command = "list" | "images" | "profiles" | "create" | "start" | "stop" | "delete" | "view";
type Args = {
  command: Command; json: boolean; yes: boolean; headless: boolean;
  sdk?: string; root?: string; runtime?: string; name?: string; image?: string; device?: string; serial?: string; job?: string;
};

function parseArgs(argv: string[]): Args {
  const commands: Record<string, true> = { list: true, images: true, profiles: true, create: true, start: true, stop: true, delete: true, view: true };
  const command = argv[0];
  if (!command || !Object.hasOwn(commands, command)) throw new Error(`Expected a command.\n${USAGE}`);
  const args: Args = { command: command as Command, json: false, yes: false, headless: false };
  const seen = new Set<string>();
  const strings: Record<string, true> = { sdk: true, root: true, runtime: true, name: true, image: true, device: true, serial: true, job: true };
  for (let i = 1; i < argv.length; i++) {
    const flag = argv[i]!;
    const key = flag.slice(2);
    if (!flag.startsWith("--") || seen.has(key)) throw new Error(`Invalid or repeated argument ${flag}. Use --help.`);
    seen.add(key);
    if (key === "json" || key === "yes" || key === "headless") args[key] = true;
    else if (Object.hasOwn(strings, key)) {
      const value = argv[++i];
      if (!value || value.startsWith("--")) throw new Error(`Missing value for ${flag}.`);
      Object.assign(args, { [key]: value });
    } else throw new Error(`Unknown option ${flag}. Use --help.`);
  }
  const only = (key: string, allowed: string[]) => {
    if (seen.has(key) && !allowed.includes(command)) throw new Error(`--${key} is only valid for ${allowed.join(" or ")}.`);
  };
  only("name", ["create", "start", "stop", "delete", "view"]);
  only("image", ["create"]);
  only("device", ["create"]);
  only("serial", ["stop", "view"]);
  only("headless", ["start"]);
  only("yes", ["delete"]);
  only("job", ["view"]);
  if (args.runtime && !args.root) throw new Error("--runtime is only needed with --root; omit it for standalone commands.");
  if (args.job && !path.isAbsolute(args.job)) throw new Error("--job must be an absolute path to a private job directory.");
  if (args.name) validateName(args.name);
  if (args.serial && !/^emulator-\d+$/.test(args.serial)) throw new Error("--serial must be emulator-PORT, never a physical device serial.");
  if (command === "delete" && !args.yes) throw new Error("Deletion requires --yes. This permanently deletes the selected AVD and its data.");
  return args;
}

async function main(args: Args): Promise<void> {
  const project = args.root ? await resolveProject(args.root, args.runtime) : undefined;
  const root = resolveSdk(args.sdk, project);
  const sdk = new AndroidSdk(root);
  const name = args.name ?? project?.avd;
  const selectedName = () => {
    if (!name) throw new Error(`Specify --name for ${args.command}, or --root for the project's configured AVD.`);
    return validateName(name);
  };
  let result: Record<string, unknown>;
  switch (args.command) {
    case "list": {
      const snapshot = await sdk.snapshot();
      result = { sdk: root, avds: snapshot.avds, ...(project ? { project: projectInfo(project) } : {}), ...(snapshot.warnings.length ? { warnings: snapshot.warnings } : {}) };
      break;
    }
    case "images": result = { images: await sdk.images() }; break;
    case "profiles": result = { profiles: await sdk.profiles() }; break;
    case "create": {
      if (project && !args.name && !args.image && !args.device) {
        const configured = selectedName();
        if ((await sdk.names()).includes(configured)) throw new Error(`AVD ${configured} already exists; it will not be overwritten or repaired by create.`);
        await createConfigured(project, root);
        if (!(await sdk.names()).includes(configured)) throw new Error(`Elide completed but the configured AVD ${configured} was not registered. Check the build output and Android AVD home.`);
        result = { message: `Created ${configured}.`, name: configured };
      } else {
        if (!args.name || !args.image || !args.device) throw new Error("Custom create requires --name, --image and --device. For the project's configured AVD, omit all three.");
        await sdk.create(args.name, args.image, args.device);
        result = { message: `Created ${args.name}.`, name: args.name };
      }
      break;
    }
    case "start": {
      const avd = selectedName();
      result = { message: `Emulator ${avd} is active.`, name: avd, ...await sdk.start(avd, args.headless) };
      break;
    }
    case "stop": {
      const selected = await sdk.stop(args.name ?? (args.serial ? undefined : selectedName()), args.serial);
      result = { message: `Stopped ${selected.serial}.`, ...selected };
      break;
    }
    case "delete": {
      const avd = selectedName();
      await sdk.delete(avd);
      result = { message: `Deleted ${avd}.`, name: avd };
      break;
    }
    case "view": {
      const wantedName = args.name ?? (args.serial ? undefined : selectedName());
      const running = await sdk.running();
      const matches = running.filter(device => args.serial ? device.serial === args.serial : device.name === wantedName);
      if (matches.length !== 1) throw new Error(matches.length
        ? `Multiple emulators run ${wantedName}. Select one with --serial: ${matches.map(device => device.serial).join(", ")}`
        : `No running emulator matches ${args.serial ?? wantedName}. Start the AVD first.`);
      const selected = matches[0]!;
      if (wantedName && selected.name !== wantedName) throw new Error(`Cannot confirm ${selected.serial} runs ${wantedName}; its AVD is ${selected.name ?? "unidentified"}.`);
      if (selected.state !== "running") throw new Error(`${selected.serial} is ${selected.state}; wait until it is connected before opening a view.`);
      await runView({ adb: await sdk.tool("adb"), serial: selected.serial, job: args.job });
      return;
    }
  }
  if (args.json) console.log(JSON.stringify(result));
  else if (typeof result.message === "string") console.log(result.message);
  else console.log(JSON.stringify(result, null, 2));
}

const argv = process.argv.slice(2);
try {
  if (argv.length === 1 && (argv[0] === "--help" || argv[0] === "-h")) process.stdout.write(USAGE);
  else await main(parseArgs(argv));
} catch (error) {
  const message = errorMessage(error);
  console.error(message);
  if (argv.includes("--json")) console.log(JSON.stringify({ error: message, ...(error instanceof ProjectChoiceError ? { projects: error.projects } : {}) }));
  process.exitCode = 1;
}
