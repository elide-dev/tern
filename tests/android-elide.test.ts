// Cases ported from elide-dev/vscode packages/core/test/{android,buildTasks,version}.test.ts.
import { describe, expect, test } from "bun:test";
import {
  androidSdkRoot, buildTasksOf, compareElideVersions, decodeManifest, parseAdbDevices, parseBuildInspect,
  parseElideVersion, unqualifiedTaskName,
} from "../android/elide";

describe("androidSdkRoot", () => {
  const isDirectory = (dirs: string[]) => (p: string) => dirs.includes(p);

  test("a declared root is read against the project and wins over the environment", () => {
    const root = androidSdkRoot({
      declared: "vendor/sdk",
      projectRoot: "/p",
      env: { ANDROID_HOME: "/opt/android" },
      isDirectory: isDirectory(["/p/vendor/sdk", "/opt/android"]),
    });
    expect(root).toBe("/p/vendor/sdk");
  });

  test("a declared root that is not a directory resolves to nothing rather than falling through", () => {
    const root = androidSdkRoot({
      declared: "vendor/sdk",
      projectRoot: "/p",
      env: { ANDROID_HOME: "/opt/android" },
      isDirectory: isDirectory(["/opt/android"]),
    });
    expect(root).toBeUndefined();
  });

  test("ANDROID_HOME is preferred over ANDROID_SDK_ROOT, and both over the conventional location", () => {
    const dirs = isDirectory(["/opt/home", "/opt/legacy", "/u/Library/Android/sdk"]);
    expect(androidSdkRoot({ env: { ANDROID_HOME: "/opt/home", ANDROID_SDK_ROOT: "/opt/legacy" }, isDirectory: dirs })).toBe("/opt/home");
    expect(androidSdkRoot({ env: { ANDROID_SDK_ROOT: "/opt/legacy" }, isDirectory: dirs })).toBe("/opt/legacy");
    expect(androidSdkRoot({ env: {}, homeDir: "/u", platform: "darwin", isDirectory: dirs })).toBe("/u/Library/Android/sdk");
  });

  test("the conventional location follows the host", () => {
    const linux = androidSdkRoot({ env: {}, homeDir: "/home/u", platform: "linux", isDirectory: isDirectory(["/home/u/Android/Sdk"]) });
    expect(linux).toBe("/home/u/Android/Sdk");
  });

  test("nothing installed resolves to nothing", () => {
    expect(androidSdkRoot({ env: {}, homeDir: "/u", platform: "darwin", isDirectory: () => false })).toBeUndefined();
  });
});

describe("parseAdbDevices", () => {
  test("the header and the daemon's chatter carry no device", () => {
    const text = [
      "* daemon not running; starting now at tcp:5037",
      "* daemon started successfully",
      "List of devices attached",
      "emulator-5554\tdevice",
      "R58M30ABCDE\tunauthorized",
      "4c1a0f2b\toffline",
      "",
    ].join("\n");
    expect(parseAdbDevices(text)).toEqual([
      { serial: "emulator-5554", state: "device", emulator: true, ready: true },
      { serial: "R58M30ABCDE", state: "unauthorized", emulator: false, ready: false },
      { serial: "4c1a0f2b", state: "offline", emulator: false, ready: false },
    ]);
  });

  test("no device attached yields none", () => {
    expect(parseAdbDevices("List of devices attached\n\n")).toEqual([]);
  });

  test("malformed lines carry no device", () => {
    expect(parseAdbDevices("List of devices attached\nonly-serial\na\tb\tc\n\tdevice\nserial\t\n")).toEqual([]);
  });
});

const INSPECT = `Elide 1.5.3

3 tasks available:

  compile-kotlin-main   Compile main Kotlin source files to bytecode
    no options declared

  jvm-test   Run JVM tests using JUnit
    --debugger   Attach JDWP debugger, optionally specify host:port
    --test-name-pattern   Run only tests whose name matches this regular expression

  write-classpath-files
    no options declared

Global options:
  --no-cache   Disable the build cache for this run
`;

const INSPECT_WORKSPACE = `43 tasks across 5 projects:

logstat
  logstat:compile-java-main   Compile main Java source files
    no options declared

  logstat:run   Run the main JVM application
    --debugger   Attach JDWP debugger, optionally specify host:port
    --args   Space-separated program arguments

model
  model:compile-kotlin-main   Compile main Kotlin source files to bytecode
    no options declared

  model:model   Package compiled classes into a JAR archive
    no options declared

cli
  cli:run   Run the main JVM application
    --debugger   Attach JDWP debugger, optionally specify host:port

Global options:
  --no-cache   Disable the build cache for this run
`;

const INSPECT_WORKSPACE_BARE_ROOT = `3 tasks across 2 projects:

workspace-sample
  maven-dependencies   Resolve and download Maven dependencies
    --fresh   Re-download dependencies even if present in the local cache

core
  core:jar   Package compiled classes into a JAR archive
    no options declared

  core:run   Run the main JVM application
    no options declared

Global options:
  --no-cache   Disable the build cache for this run
`;

describe("parseBuildInspect", () => {
  test("reads the task table, its descriptions and its option rows", () => {
    expect(parseBuildInspect(INSPECT)).toEqual([
      { name: "compile-kotlin-main", description: "Compile main Kotlin source files to bytecode", options: [] },
      {
        name: "jvm-test",
        description: "Run JVM tests using JUnit",
        options: [
          { option: "--debugger", description: "Attach JDWP debugger, optionally specify host:port" },
          { option: "--test-name-pattern", description: "Run only tests whose name matches this regular expression" },
        ],
      },
      { name: "write-classpath-files", description: "", options: [] },
    ]);
  });

  test("an option is named as the CLI takes it, without the value form or negation the listing shows", () => {
    const [debug] = parseBuildInspect(`1 task available:

  android-debug-app   Install and debug 'app' on a device
    --debug[=<value>]   Local port
    --device=<value>   Serial number
    --window (or --no-window) [default: true]   Show the emulator window
`);
    expect(debug!.options.map((o) => o.option)).toEqual(["--debug", "--device", "--window"]);
  });

  test("output without a task header yields no tasks", () => {
    expect(parseBuildInspect("error: no project found\n")).toEqual([]);
    expect(parseBuildInspect("")).toEqual([]);
  });

  test("group headers scope the rows below them and are not tasks themselves", () => {
    const tasks = parseBuildInspect(INSPECT_WORKSPACE);
    expect(tasks.map((t) => [t.project, t.name])).toEqual([
      ["logstat", "logstat:compile-java-main"],
      ["logstat", "logstat:run"],
      ["model", "model:compile-kotlin-main"],
      ["model", "model:model"],
      ["cli", "cli:run"],
    ]);
    expect(tasks.map((t) => t.name)).not.toContain("--no-cache");
  });

  test("each project's tasks, under the names the project knows them by", () => {
    const tasks = parseBuildInspect(INSPECT_WORKSPACE);
    expect(buildTasksOf(tasks, "model").map(unqualifiedTaskName)).toEqual(["compile-kotlin-main", "model"]);
    expect(buildTasksOf(tasks, "report")).toEqual([]);
  });

  test("a root whose tasks are listed bare still owns its group", () => {
    const tasks = parseBuildInspect(INSPECT_WORKSPACE_BARE_ROOT);
    expect(buildTasksOf(tasks, "workspace-sample").map(unqualifiedTaskName)).toEqual(["maven-dependencies"]);
    expect(buildTasksOf(tasks, "core").map(unqualifiedTaskName)).toEqual(["jar", "run"]);
  });

  test("a standalone listing belongs wholly to its project", () => {
    const tasks = parseBuildInspect(INSPECT);
    expect(buildTasksOf(tasks, "anything")).toEqual(tasks);
    expect(tasks.map(unqualifiedTaskName)).toEqual(tasks.map((t) => t.name));
  });
});

describe("versions", () => {
  test("reads the release triple, ignoring a build suffix", () => {
    expect(parseElideVersion("1.5.1+db2bc827b")).toEqual({ major: 1, minor: 5, patch: 1 });
    expect(parseElideVersion("garbage")).toBeUndefined();
    expect(parseElideVersion("1.5")).toBeUndefined();
  });

  test("orders by major, then minor, then patch", () => {
    const v = (major: number, minor: number, patch: number) => ({ major, minor, patch });
    expect(compareElideVersions(v(1, 5, 0), v(1, 5, 0))).toBe(0);
    expect(compareElideVersions(v(1, 4, 9), v(1, 5, 0))).toBeLessThan(0);
    expect(compareElideVersions(v(2, 0, 0), v(1, 9, 9))).toBeGreaterThan(0);
    expect(compareElideVersions(v(1, 5, 1), v(1, 5, 0))).toBeGreaterThan(0);
  });
});

describe("decodeManifest", () => {
  test("the device profile defaults to pixel_6", () => {
    const manifest = decodeManifest(JSON.stringify({ name: "app", android: { sdk: "/sdk", device: { avd: "a" } } }));
    expect(manifest).toEqual({ name: "app", workspaceMembers: [], android: { sdk: "/sdk", device: { avd: "a", deviceProfile: "pixel_6" } } });
  });

  test("a manifest without an android block has none", () => {
    const manifest = decodeManifest(JSON.stringify({ workspace: { members: ["core", 3] } }));
    expect(manifest).toEqual({ workspaceMembers: ["core"] });
    expect(() => decodeManifest("[]")).toThrow("Elide returned an invalid project manifest.");
    expect(() => decodeManifest("{")).toThrow("Elide returned an invalid project manifest.");
  });
});
