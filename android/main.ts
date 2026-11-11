import { runDisplay } from "./display";
import { EmulatorDevice } from "./emulator";
import { advertisements, emulatorEndpoint } from "./grpc";
import { MirroredDevice } from "./mirror";
import { errorMessage } from "./process";
import { createConfigured, NotAndroidError, projectInfo, ProjectChoiceError, resolveProject, resolveSdk } from "./project";
import { AndroidSdk, validateName } from "./sdk";

const USAGE = `Usage: elide-tern-android COMMAND [OPTIONS]

Commands:
  list       List AVDs with their emulator serials, and attached physical devices
  images     List installed system-image package IDs (no downloads)
  profiles   List hardware profile IDs and names
  create     Create a new AVD; never overwrite an existing AVD
  start      Start an existing AVD without an emulator window
  stop       Stop only the selected emulator
  delete     Delete a stopped AVD (requires --yes)
  display    Show and control a running emulator or attached device in this terminal until closed
             (with --start, start the AVD first, showing progress)
  wait       Wait until a device finished booting (--name: until its emulator attaches first)

Options:
  --json              Print one JSON result object (errors also on stderr)
  --sdk PATH          Explicit Android SDK; overrides project/environment lookup
  --root PATH         Android Elide project, or workspace with one Android member
  --runtime PATH      Elide executable for project resolution (not needed standalone)
  --name NAME         AVD name (defaults to the project's configured AVD)
  --image PACKAGE     Installed system-images;android-API;VARIANT;ABI (create)
  --device PROFILE    Hardware profile ID (create; list with profiles)
  --serial SERIAL     Exact emulator-PORT to stop; emulator or device serial to display
  --start             display: start the --name AVD unless it runs, showing progress
  --yes               Confirm deletion; never accepts SDK licenses
  --help              Show this help

Standalone create requires --name, --image and --device. In project mode,
create without those options uses Elide's configured android-avd build target.
Pass an Android member directory with --root if a workspace is ambiguous.
Start does not create an AVD or install SDK components. Stop --serial never
targets a physical device. Display needs a terminal with kitty graphics (a Tern
pane, kitty, Ghostty, WezTerm). Emulators need to have been started by this
helper; other serials are mirrored over adb (--sdk selects its SDK).
No Elide runtime is needed without --root.
`;
const EMULATOR = /^emulator-\d+$/;
/** adb serials: USB serial numbers, HOST:PORT and mDNS service names. */
const SERIAL = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;

type Command = "list" | "images" | "profiles" | "create" | "start" | "stop" | "delete" | "display" | "wait";
type Args = {
  command: Command; json: boolean; yes: boolean; start: boolean;
  sdk?: string; root?: string; runtime?: string; name?: string; image?: string; device?: string; serial?: string;
};

function parseArgs(argv: string[]): Args {
  const commands: Record<string, true> = { list: true, images: true, profiles: true, create: true, start: true, stop: true, delete: true, display: true, wait: true };
  const command = argv[0];
  if (!command || !Object.hasOwn(commands, command)) throw new Error(`Expected a command.\n${USAGE}`);
  const args: Args = { command: command as Command, json: false, yes: false, start: false };
  const seen = new Set<string>();
  const strings: Record<string, true> = { sdk: true, root: true, runtime: true, name: true, image: true, device: true, serial: true };
  for (let i = 1; i < argv.length; i++) {
    const flag = argv[i]!;
    const key = flag.slice(2);
    if (!flag.startsWith("--") || seen.has(key)) throw new Error(`Invalid or repeated argument ${flag}. Use --help.`);
    seen.add(key);
    if (key === "json" || key === "yes" || key === "start") args[key] = true;
    else if (Object.hasOwn(strings, key)) {
      const value = argv[++i];
      if (!value || value.startsWith("--")) throw new Error(`Missing value for ${flag}.`);
      Object.assign(args, { [key]: value });
    } else throw new Error(`Unknown option ${flag}. Use --help.`);
  }
  const only = (key: string, allowed: string[]) => {
    if (seen.has(key) && !allowed.includes(command)) throw new Error(`--${key} is only valid for ${allowed.join(" or ")}.`);
  };
  only("name", ["create", "start", "stop", "delete", "display", "wait"]);
  only("image", ["create"]);
  only("device", ["create"]);
  only("serial", ["stop", "display", "wait"]);
  only("yes", ["delete"]);
  only("start", ["display"]);
  only("json", ["list", "images", "profiles", "create", "start", "stop", "delete", "wait"]);
  if (args.runtime && !args.root) throw new Error("--runtime is only needed with --root; omit it for standalone commands.");
  if (args.command === "display" && args.start) {
    if (!args.name || args.serial) throw new Error("display --start requires --name and takes no --serial.");
  } else if (args.command === "display") {
    if (args.root) throw new Error("display finds the device by --serial or --name; --root applies only with --start.");
    if (!args.serial && !args.name) throw new Error("display requires --serial or --name.");
    if (args.sdk && (args.name || EMULATOR.test(args.serial!))) throw new Error("--sdk applies only to a physical device's --serial or with --start; emulators are found by their own advertisement.");
  }
  if (args.command === "wait" && args.name && args.serial) throw new Error("wait takes --name or --serial, not both.");
  if (args.name) validateName(args.name);
  const anySerial = command === "display" || command === "wait";
  if (args.serial && !(anySerial ? SERIAL : EMULATOR).test(args.serial)) {
    throw new Error(anySerial ? `Invalid device serial ${args.serial}.` : "--serial must be emulator-PORT, never a physical device serial.");
  }
  if (command === "delete" && !args.yes) throw new Error("Deletion requires --yes. This permanently deletes the selected AVD and its data.");
  return args;
}

async function main(args: Args): Promise<void> {
  if (args.command === "display") {
    const { name, serial } = args;
    if (args.start) {
      await runDisplay(name!, async (progress, signal) => {
        progress(`Starting ${name}…`);
        const project = args.root ? await resolveProject(args.root, args.runtime) : undefined;
        const sdk = new AndroidSdk(resolveSdk(args.sdk, project));
        const started = await sdk.start(name!, signal);
        progress(`Connecting to ${name}…`);
        return new EmulatorDevice(await emulatorEndpoint(started.serial, name));
      });
    } else if (name || EMULATOR.test(serial!)) {
      await runDisplay(name ?? serial!, async () => new EmulatorDevice(await emulatorEndpoint(serial, name)));
    } else {
      await runDisplay(serial!, async () => {
        const sdk = new AndroidSdk(resolveSdk(args.sdk));
        return MirroredDevice.connect(await sdk.tool("adb"), serial!, sdk.env);
      });
    }
    return;
  }
  const project = args.root ? await resolveProject(args.root, args.runtime) : undefined;
  const root = resolveSdk(args.sdk, project);
  const sdk = new AndroidSdk(root);
  const name = args.name ?? project?.avd;
  const selectedName = () => {
    if (!name) throw new Error(`Specify --name for ${args.command}, or --root for the project's configured AVD.`);
    return validateName(name);
  };
  let result: Record<string, unknown> = {};
  switch (args.command) {
    case "list": {
      const snapshot = await sdk.snapshot();
      const ads = await advertisements();
      const avds = snapshot.avds.map(avd => avd.serial
        ? { ...avd, embeddable: ads.some(ad => ad.serial === avd.serial && ad.port !== undefined && ad.token !== undefined) }
        : avd);
      result = { sdk: root, avds, devices: snapshot.devices, ...(project ? { project: projectInfo(project) } : {}), ...(snapshot.warnings.length ? { warnings: snapshot.warnings } : {}) };
      break;
    }
    case "images": result = { images: await sdk.images() }; break;
    case "profiles": result = { profiles: await sdk.profiles() }; break;
    case "create": {
      if (project && !args.name && !args.image && !args.device) {
        const configured = selectedName();
        if ((await sdk.names()).includes(configured)) throw new Error(`A virtual device named ${configured} already exists; it will not be overwritten or repaired by create.`);
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
      result = { message: `${avd} is running.`, name: avd, ...await sdk.start(avd) };
      break;
    }
    case "stop": {
      const selected = await sdk.stop(args.name ?? (args.serial ? undefined : selectedName()), args.serial);
      result = { message: `Stopped ${selected.name ?? selected.serial}.`, ...selected };
      break;
    }
    case "delete": {
      const avd = selectedName();
      await sdk.delete(avd);
      result = { message: `Deleted ${avd}.`, name: avd };
      break;
    }
    case "wait": {
      const booted = await sdk.waitBooted(args.serial ? { serial: args.serial } : { name: selectedName() });
      result = { message: `${booted.name ?? booted.serial} is ready.`, ...booted };
      break;
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
  if (argv.includes("--json")) console.log(JSON.stringify({ error: message, ...(error instanceof ProjectChoiceError ? { projects: error.projects } : {}), ...(error instanceof NotAndroidError ? { code: "not-android" } : {}) }));
  process.exitCode = 1;
}
