mod coverage;
mod debug;
mod project;
mod protocol;

use elide_embed_host::{MAX_REQUEST, MAX_RESPONSE, Worker, read_frame, write_frame};
use fs2::FileExt;
use protocol::Request;
use serde_json::{Value, json};
use std::{
  collections::HashMap,
  fs::{self, File, OpenOptions},
  io::{self, Read, Write},
  os::unix::{
    fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    net::{UnixListener, UnixStream},
    process::CommandExt,
  },
  path::{Path, PathBuf},
  process::{Command, Stdio},
  sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
  },
  thread,
  time::{Duration, Instant},
};

/// Coverage line entries shared across a file's pages (see `coverage::Inferred`).
static INFERRED: std::sync::LazyLock<Mutex<coverage::Inferred>> =
  std::sync::LazyLock::new(|| Mutex::new(coverage::Inferred::default()));

const DEADLINE: Duration = Duration::from_secs(10);
const IDLE: Duration = Duration::from_secs(120);
const MAX_SESSIONS: usize = 8;
type Sessions = Arc<Mutex<HashMap<String, Arc<Mutex<Runtime>>>>>;
type Projects = Arc<Mutex<elide_project_session::Host>>;

struct Runtime {
  worker: Worker,
  used: Instant,
}

fn main() {
  if let Err(error) = run() {
    eprintln!("elide-tern: {error}");
    std::process::exit(1);
  }
}

fn run() -> Result<(), String> {
  let args: Vec<_> = std::env::args_os().skip(1).collect();
  if args.len() != 2 {
    return Err("Usage: elide-tern-broker <request|serve|socket|project-root> <state-directory>".into());
  }
  let path = Path::new(&args[1]);
  match args[0].to_str() {
    Some("project-root") => {
      println!("{}", project::discover(path)?);
      Ok(())
    }
    Some("socket") => {
      println!("{}", socket(&private_dir(path)?)?.display());
      Ok(())
    }
    Some("serve") => serve(&private_dir(path)?),
    Some("request") => {
      // Validate and bound input before starting a broker or connecting to it.
      let mut input = Vec::new();
      io::stdin()
        .take((MAX_REQUEST + 1) as u64)
        .read_to_end(&mut input)
        .map_err(err)?;
      if input.len() > MAX_REQUEST {
        return Err("Request too large".into());
      }
      serde_json::from_slice::<Request>(&input).map_err(err)?;
      let state = private_dir(path)?;
      let mut stream = connect(&state)?;
      stream.set_read_timeout(Some(Duration::from_secs(15))).map_err(err)?;
      stream.set_write_timeout(Some(Duration::from_secs(2))).map_err(err)?;
      write_frame(&mut stream, &input).map_err(err)?;
      let response = read_frame(&mut stream, MAX_RESPONSE)
        .map_err(err)?
        .ok_or("Broker disconnected")?;
      io::stdout().write_all(&response).map_err(err)?;
      println!();
      Ok(())
    }
    _ => Err("Unknown command".into()),
  }
}

fn err(e: impl std::fmt::Display) -> String {
  e.to_string()
}

fn private_dir(path: &Path) -> Result<PathBuf, String> {
  match fs::DirBuilder::new().recursive(true).mode(0o700).create(path) {
    Ok(()) => (),
    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => (),
    Err(e) => return Err(err(e)),
  }
  let meta = fs::symlink_metadata(path).map_err(err)?;
  // SAFETY: geteuid has no pointer arguments or preconditions.
  if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
    return Err("Broker state must be an owned, non-symlink directory with mode 0700".into());
  }
  path.canonicalize().map_err(err)
}

/// The socket lives outside `state` (see `elide_project_session::client::socket`).
fn socket(state: &Path) -> Result<PathBuf, String> {
  elide_project_session::client::socket(state).map_err(|e| format!("Broker socket for state {}: {e}", state.display()))
}

fn lock(path: &Path) -> Result<File, String> {
  OpenOptions::new()
    .read(true)
    .write(true)
    .create(true)
    .truncate(false)
    .mode(0o600)
    .custom_flags(libc::O_NOFOLLOW)
    .open(path)
    .map_err(err)
}

fn connect(state: &Path) -> Result<UnixStream, String> {
  let socket = socket(state)?;
  if let Ok(stream) = UnixStream::connect(&socket) {
    return Ok(stream);
  }
  let startup = lock(&state.join("startup.lock"))?;
  let start = Instant::now();
  while startup.try_lock_exclusive().is_err() {
    if start.elapsed() > Duration::from_secs(5) {
      return Err("Broker startup lock timed out".into());
    }
    thread::sleep(Duration::from_millis(25));
  }
  if let Ok(stream) = UnixStream::connect(&socket) {
    return Ok(stream);
  }
  // The broker's error output, and its workers' (they inherit it), for the startup error below and
  // for a person reading the state directory. Each start writes it afresh.
  let log_path = state.join("broker.log");
  let log = OpenOptions::new()
    .write(true)
    .create(true)
    .truncate(true)
    .mode(0o600)
    .custom_flags(libc::O_NOFOLLOW)
    .open(&log_path)
    .map_err(err)?;
  let mut child = Command::new(std::env::current_exe().map_err(err)?)
    .arg("serve")
    .arg(state)
    .process_group(0)
    .stdin(Stdio::null())
    .stdout(Stdio::null())
    .stderr(log)
    .spawn()
    .map_err(err)?;
  loop {
    if let Ok(stream) = UnixStream::connect(&socket) {
      return Ok(stream);
    }
    if let Some(status) = child.try_wait().map_err(err)? {
      let said = fs::read(&log_path).unwrap_or_default();
      let said = String::from_utf8_lossy(&said[said.len().saturating_sub(2048)..]);
      return Err(format!("Broker startup failed ({status}): {}", said.trim()));
    }
    if start.elapsed() > Duration::from_secs(5) {
      let _ = child.kill();
      let _ = child.wait();
      return Err("Broker startup timed out".into());
    }
    thread::sleep(Duration::from_millis(25));
  }
}

fn serve(state: &Path) -> Result<(), String> {
  let lifetime = lock(&state.join("broker.lock"))?;
  lifetime.try_lock_exclusive().map_err(|_| "Broker already running")?;
  let socket = socket(state)?;
  if socket.exists() {
    fs::remove_file(&socket).map_err(err)?;
  }
  let listener = UnixListener::bind(&socket).map_err(err)?;
  listener.set_nonblocking(true).map_err(err)?;
  let sessions: Sessions = Default::default();
  let projects: Projects = Default::default();
  let active = Arc::new(AtomicUsize::new(0));
  let serial = Arc::new(AtomicUsize::new(1));
  let mut last = Instant::now();
  // An upgrade (`make broker` renames a new build into place) must not leave clients talking to the
  // old broker for as long as they keep it busy: once its executable is replaced, it stops taking
  // connections and exits when the ones it has end, and the next request starts the new build.
  let build = executable();
  let mut checked = Instant::now();
  let mut replaced = false;
  loop {
    let mut idle = false;
    if !replaced && checked.elapsed() >= Duration::from_secs(1) {
      checked = Instant::now();
      if build.is_some() && executable() != build {
        replaced = true;
        let _ = fs::remove_file(&socket);
      }
    }
    if replaced {
      if active.load(Ordering::SeqCst) == 0 {
        return Ok(());
      }
      thread::sleep(Duration::from_millis(25));
      continue;
    }
    match listener.accept() {
      Ok((mut stream, _)) => {
        last = Instant::now();
        if active.load(Ordering::SeqCst) >= 16 {
          // Said, not just dropped: the client reports why instead of a lost connection.
          let _ = stream.set_nonblocking(false);
          let _ = stream.set_write_timeout(Some(Duration::from_millis(200)));
          let _ = write_frame(&mut stream, br#"{"ok":false,"error":"Broker busy; try again"}"#);
          continue;
        }
        active.fetch_add(1, Ordering::SeqCst);
        let (sessions, serial, active) = (sessions.clone(), serial.clone(), active.clone());
        let projects = projects.clone();
        thread::spawn(move || {
          let _ = connection(stream, &sessions, &serial, &projects);
          active.fetch_sub(1, Ordering::SeqCst);
        });
      }
      Err(e) if e.kind() == io::ErrorKind::WouldBlock => idle = true,
      // Out of descriptors and the like pass; one failed accept must not end the broker.
      Err(e) => {
        eprintln!("elide-tern: accept failed: {e}");
        idle = true;
      }
    }
    sessions
      .lock()
      .unwrap()
      .retain(|_, runtime| runtime.try_lock().map(|r| r.used.elapsed() < IDLE).unwrap_or(true));
    projects.lock().unwrap().tick(Instant::now());
    if active.load(Ordering::SeqCst) == 0
      && last.elapsed() >= IDLE
      && sessions.lock().unwrap().is_empty()
      && projects.lock().unwrap().is_empty()
    {
      break;
    }
    // Waiting connections are taken at once; only an idle broker sleeps between polls.
    if idle {
      thread::sleep(Duration::from_millis(25));
    }
  }
  fs::remove_file(socket).map_err(err)
}

/// The running executable's identity on disk (device, inode, modification time), when it can be
/// read.
fn executable() -> Option<(u64, u64, std::time::SystemTime)> {
  let metadata = fs::metadata(std::env::current_exe().ok()?).ok()?;
  Some((metadata.dev(), metadata.ino(), metadata.modified().ok()?))
}

fn connection(
  mut stream: UnixStream,
  sessions: &Sessions,
  serial: &AtomicUsize,
  projects: &Projects,
) -> Result<(), String> {
  stream.set_read_timeout(Some(Duration::from_secs(2))).map_err(err)?;
  stream.set_write_timeout(Some(Duration::from_secs(2))).map_err(err)?;
  let result = (|| {
    let bytes = read_frame(&mut stream, MAX_REQUEST)
      .map_err(err)?
      .ok_or("Empty request")?;
    let request: Request = serde_json::from_slice(&bytes).map_err(err)?;
    dispatch(request, sessions, serial, projects)
  })();
  let response = match result {
    Ok(value) => json!({"ok": true, "result": value}),
    Err(error) => json!({"ok": false, "error": error}),
  };
  let bytes = serde_json::to_vec(&response).map_err(err)?;
  if bytes.len() > MAX_RESPONSE {
    return Err("Response too large".into());
  }
  write_frame(&mut stream, &bytes).map_err(err)
}

fn dispatch(request: Request, sessions: &Sessions, serial: &AtomicUsize, projects: &Projects) -> Result<Value, String> {
  match &request {
    Request::ProjectAttach { root, runtime } => {
      let binding = projects
        .lock()
        .unwrap()
        .attach(Path::new(root), Path::new(runtime), Instant::now())?;
      return serde_json::to_value(binding).map_err(err);
    }
    Request::ProjectSnapshot { binding, after } => {
      let snapshot = projects
        .lock()
        .unwrap()
        .snapshot(binding, after.as_deref(), Instant::now())?;
      return serde_json::to_value(snapshot).map_err(err);
    }
    Request::ProjectSummary { binding } => {
      let snapshot = projects
        .lock()
        .unwrap()
        .snapshot(binding, None, Instant::now())?
        .ok_or("Missing project snapshot")?;
      let runs: Vec<_> = snapshot
        .runs
        .iter()
        .map(|run| {
          let failures: Vec<_> = run
            .result
            .tests
            .iter()
            .filter(|test| {
              matches!(
                test.status,
                elide_project_session::tap::Status::Fail | elide_project_session::tap::Status::Abort
              )
            })
            .take(2)
            .map(|test| {
              json!({
                "number": test.number.to_string(), "name": test.label,
                "diagnostic": test.diagnostics.chars().take(512).collect::<String>(),
                "file": test.metadata.as_ref().and_then(|metadata| metadata.file.as_ref()),
              })
            })
            .collect();
          json!({"run":run.id, "subject":run.subject, "status":run.status, "running":run.running,
          "duration_ms":run.duration_ms, "passed":run.result.passed, "failed":run.result.failed,
          "total":run.result.total, "truncated":run.result.truncated, "report":run.report,
          "failures":failures, "failure_limit":2, "options":run.options, "coverage":run.coverage})
        })
        .collect();
      return Ok(
        json!({"schema":snapshot.schema, "session":snapshot.session, "epoch":snapshot.epoch,
        "revision":snapshot.revision, "root":snapshot.root, "configuration":snapshot.configuration,
        "attachments":snapshot.attachments, "runs":runs, "debug":snapshot.debug}),
      );
    }
    Request::ProjectDetach { binding } => {
      projects.lock().unwrap().detach(binding, Instant::now())?;
      return Ok(json!({}));
    }
    Request::ProjectTest {
      binding,
      command,
      subject,
      options,
    } => {
      let run =
        projects
          .lock()
          .unwrap()
          .test_with_options(binding, command, Path::new(subject), *options, Instant::now())?;
      return Ok(json!({"run": run}));
    }
    Request::ProjectCoverage { binding, run } => {
      let artifact = projects.lock().unwrap().coverage(binding, run, Instant::now())?;
      return serde_json::to_value(artifact).map_err(err);
    }
    Request::ProjectCoveragePage {
      binding,
      run,
      file,
      offset,
      limit,
    } => {
      let (artifact, root) = {
        let mut projects = projects.lock().unwrap();
        let now = Instant::now();
        let artifact = projects.coverage(binding, run, now)?;
        // Line pages read the measured source under the project root to serve inferred lines.
        let root = match (&artifact, file) {
          (Some(_), Some(_)) => projects.snapshot(binding, None, now)?.map(|snapshot| snapshot.root),
          _ => None,
        };
        (artifact, root)
      };
      return artifact.map_or(Ok(Value::Null), |artifact| {
        let mut cache = INFERRED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        coverage::page(&artifact, *file, *offset, *limit, root.as_deref(), run, &mut cache)
      });
    }
    Request::ProjectDebugLaunch {
      binding,
      command,
      subject,
      options,
    } => {
      let generation =
        projects
          .lock()
          .unwrap()
          .debug_launch(binding, command, Path::new(subject), options.clone(), Instant::now())?;
      return Ok(json!({"generation":generation}));
    }
    Request::ProjectDebugSnapshot { binding, compact } => {
      let snapshot = projects.lock().unwrap().debug_snapshot(binding, Instant::now())?;
      return if *compact {
        snapshot.map_or(Ok(Value::Null), debug::compact)
      } else {
        serde_json::to_value(snapshot).map_err(err)
      };
    }
    Request::ProjectDebugOperation {
      binding,
      command,
      request,
    } => {
      projects
        .lock()
        .unwrap()
        .debug_request(binding, command, request.clone(), Instant::now())?;
      return Ok(json!({}));
    }
    Request::ProjectDebugTakeover { binding, generation } => {
      projects
        .lock()
        .unwrap()
        .debug_takeover(binding, generation, Instant::now())?;
      return Ok(json!({}));
    }
    Request::ProjectCancel { binding, run } => {
      projects.lock().unwrap().cancel(binding, run, Instant::now())?;
      return Ok(json!({}));
    }
    Request::Ping {} => {
      return Ok(json!({"protocol": 1, "pid": std::process::id(), "sessions": sessions.lock().unwrap().len()}));
    }
    Request::Open { sdk } => {
      let sdk = Path::new(sdk).canonicalize().map_err(err)?;
      if !sdk.join("embedder.json").is_file() {
        return Err("Expected a complete embedded SDK directory".into());
      }
      let mut sessions = sessions.lock().unwrap();
      if sessions.len() >= MAX_SESSIONS {
        return Err("Session limit reached (8)".into());
      }
      let executable = std::env::current_exe()
        .map_err(err)?
        .with_file_name("elide-tern-worker");
      let worker = Worker::spawn(&executable, &sdk)?;
      let id = format!("{}-{}", std::process::id(), serial.fetch_add(1, Ordering::Relaxed));
      sessions.insert(
        id.clone(),
        Arc::new(Mutex::new(Runtime {
          worker,
          used: Instant::now(),
        })),
      );
      return Ok(json!({"session": id}));
    }
    Request::Close { session } => {
      let runtime = sessions
        .lock()
        .unwrap()
        .remove(session)
        .ok_or("Unknown or expired session")?;
      // An in-flight exchange owns its worker until its deadline; removing the session prevents reuse.
      drop(runtime);
      return Ok(json!({}));
    }
    _ => (),
  }
  let id = request.session().ok_or("Missing session")?;
  let runtime = sessions
    .lock()
    .unwrap()
    .get(id)
    .cloned()
    .ok_or("Unknown or expired session; open a new one")?;
  let mut runtime = runtime.try_lock().map_err(|_| "Session busy")?;
  let bytes = request.encode()?;
  let response = runtime.worker.exchange(bytes, DEADLINE);
  runtime.used = Instant::now();
  match response {
    Ok(bytes) => protocol::decode(&bytes),
    Err(error) => {
      // Stop has already killed and reaped the worker; its handles can never be reused.
      sessions.lock().unwrap().remove(id);
      Err(error)
    }
  }
}
