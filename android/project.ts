import { stat, realpath } from "node:fs/promises";
import path from "node:path";
import {
  ANDROID_AVD_TASK, DEFAULT_AVD_NAME, MANIFEST_NAME, androidSdkRoot, buildTasksOf,
  compareElideVersions, decodeManifest, parseBuildInspect, parseElideVersion, projectName,
  resolveElideDistribution, unqualifiedTaskName, type Manifest,
} from "@elide/ide-core";
import { executable, run } from "./process";

export type Project = {
  root: string; name: string; avd: string; image?: string; device: string;
  manifest: Manifest; runtime: string;
};

export class ProjectChoiceError extends Error {
  constructor(readonly projects: { root: string; name: string }[]) {
    super(`Workspace has multiple Android projects. Select one with --root:\n${projects.map(project => project.root).join("\n")}`);
  }
}

export class NotAndroidError extends Error {}

export function projectInfo(project: Project) {
  return { root: project.root, name: project.name, avd: project.avd, image: project.image, device: project.device };
}

/** Read evaluated manifests, not source text, and avoid full models' dependency installs and classpath builds. */
export async function resolveProject(root: string, runtime?: string): Promise<Project> {
  const supplied = await realpath(path.resolve(root));
  if (!(await stat(path.join(supplied, MANIFEST_NAME)).catch(() => undefined))?.isFile()) {
    throw new Error(`No ${MANIFEST_NAME} at ${supplied}. Pass --root pointing to a project or workspace directory.`);
  }
  const bin = await executable(runtime ?? resolveElideDistribution().bin, "Elide (use --runtime PATH)");
  const version = parseElideVersion((await run(bin, ["--version"], { cwd: supplied })).trim().split("\n")[0] ?? "");
  let commands = version && compareElideVersions(version, { major: 1, minor: 6, patch: 0 }) < 0
    ? [["manifest"], ["project", "export"]] : [["project", "export"], ["manifest"]];
  const manifestAt = async (directory: string): Promise<Manifest> => {
    let failure: unknown;
    for (const command of commands) {
      let text: string;
      try { text = await run(bin, command, { cwd: directory, timeout: 60_000 }); }
      catch (error) { failure ??= error; continue; }
      commands = [command];
      return decodeManifest(text);
    }
    throw failure;
  };
  const manifest = await manifestAt(supplied);
  const candidates: { root: string; manifest: Manifest }[] = [{ root: supplied, manifest }];
  // A member path is an explicit selection. A workspace path must select exactly one Android project.
  for (const member of manifest.workspaceMembers) {
    const memberRoot = await realpath(path.resolve(supplied, member));
    candidates.push({ root: memberRoot, manifest: await manifestAt(memberRoot) });
  }
  const android = candidates.filter(candidate => candidate.manifest.android);
  if (!android.length) throw new NotAndroidError(`No Android-configured Elide project at ${supplied}. Declare an android block or omit --root for standalone AVD management.`);
  if (android.length !== 1) {
    throw new ProjectChoiceError(android.map(candidate => ({ root: candidate.root, name: projectName(candidate.manifest, candidate.root) })));
  }
  const selected = android[0]!;
  const settings = selected.manifest.android!;
  return {
    ...selected, runtime: bin, name: projectName(selected.manifest, selected.root),
    avd: settings.device.avd ?? (selected.manifest.name ?? DEFAULT_AVD_NAME).replace(/[^a-zA-Z0-9_.-]/g, "_"),
    image: settings.device.systemImage, device: settings.device.deviceProfile,
  };
}

export function resolveSdk(override?: string, project?: Project): string {
  const declared = override ?? project?.manifest.android?.sdk;
  const sdk = androidSdkRoot({ declared, projectRoot: override ? process.cwd() : project?.root });
  if (!sdk) throw new Error(declared
    ? `Android SDK directory not found: ${declared}. Correct --sdk or android.sdk.`
    : "Android SDK not found. Pass --sdk PATH, set ANDROID_HOME/ANDROID_SDK_ROOT, or install an SDK with Android Studio. No SDK packages are installed automatically.");
  return sdk;
}

export async function createConfigured(project: Project, sdk: string): Promise<void> {
  const declared = project.manifest.android?.sdk;
  if (declared && androidSdkRoot({ declared, projectRoot: project.root }) !== sdk) {
    throw new Error("Elide's configured AVD target uses android.sdk, which differs from --sdk. Correct the manifest, or create a custom AVD with --name, --image and --device using the selected SDK.");
  }
  const env = { ANDROID_HOME: sdk, ANDROID_SDK_ROOT: sdk, ELIDE_PROGRESS: "plain" };
  const tasks = parseBuildInspect(await run(project.runtime, ["build", "--inspect"], { cwd: project.root, env, timeout: 60_000 }));
  const target = buildTasksOf(tasks, project.name).find(task => unqualifiedTaskName(task) === ANDROID_AVD_TASK);
  if (!target) throw new Error(`Project ${project.name} exposes no ${ANDROID_AVD_TASK} target. Configure a signed Android APK, or create a custom AVD with --name, --image and --device.`);
  // Never pass --install-sdk or accept licenses; the build reports missing SDK components.
  await run(project.runtime, ["build", target.name], { cwd: project.root, env, timeout: 180_000 });
}
