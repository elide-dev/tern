mod protocol;

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
use studio_embed::{MAX_REQUEST, MAX_RESPONSE, Worker, read_frame, write_frame};

const DEADLINE: Duration = Duration::from_secs(10);
const IDLE: Duration = Duration::from_secs(120);
const MAX_SESSIONS: usize = 8;
type Sessions = Arc<Mutex<HashMap<String, Arc<Mutex<Runtime>>>>>;

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
    return Err("Usage: elide-tern-broker <request|serve> <state-directory>".into());
  }
  let path = Path::new(&args[1]);
  match args[0].to_str() {
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
  let path = path.canonicalize().map_err(err)?;
  if path.join("broker.sock").as_os_str().as_encoded_bytes().len() >= 100 {
    return Err("Broker state path is too long for a portable Unix socket; choose a shorter directory".into());
  }
  Ok(path)
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
  let socket = state.join("broker.sock");
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
  let mut child = Command::new(std::env::current_exe().map_err(err)?)
    .arg("serve")
    .arg(state)
    .process_group(0)
    .stdin(Stdio::null())
    .stdout(Stdio::null())
    .stderr(Stdio::null())
    .spawn()
    .map_err(err)?;
  loop {
    if let Ok(stream) = UnixStream::connect(&socket) {
      return Ok(stream);
    }
    if let Some(status) = child.try_wait().map_err(err)? {
      return Err(format!("Broker startup failed: {status}"));
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
  let socket = state.join("broker.sock");
  if socket.exists() {
    fs::remove_file(&socket).map_err(err)?;
  }
  let listener = UnixListener::bind(&socket).map_err(err)?;
  listener.set_nonblocking(true).map_err(err)?;
  let sessions: Sessions = Default::default();
  let active = Arc::new(AtomicUsize::new(0));
  let serial = Arc::new(AtomicUsize::new(1));
  let mut last = Instant::now();
  loop {
    match listener.accept() {
      Ok((stream, _)) => {
        last = Instant::now();
        if active.load(Ordering::SeqCst) >= 16 {
          drop(stream);
          continue;
        }
        active.fetch_add(1, Ordering::SeqCst);
        let (sessions, serial, active) = (sessions.clone(), serial.clone(), active.clone());
        thread::spawn(move || {
          let _ = connection(stream, &sessions, &serial);
          active.fetch_sub(1, Ordering::SeqCst);
        });
      }
      Err(e) if e.kind() == io::ErrorKind::WouldBlock => (),
      Err(e) => return Err(err(e)),
    }
    sessions
      .lock()
      .unwrap()
      .retain(|_, runtime| runtime.try_lock().map(|r| r.used.elapsed() < IDLE).unwrap_or(true));
    if active.load(Ordering::SeqCst) == 0 && last.elapsed() >= IDLE && sessions.lock().unwrap().is_empty() {
      break;
    }
    thread::sleep(Duration::from_millis(25));
  }
  fs::remove_file(socket).map_err(err)
}

fn connection(mut stream: UnixStream, sessions: &Sessions, serial: &AtomicUsize) -> Result<(), String> {
  stream.set_read_timeout(Some(Duration::from_secs(2))).map_err(err)?;
  stream.set_write_timeout(Some(Duration::from_secs(2))).map_err(err)?;
  let result = (|| {
    let bytes = read_frame(&mut stream, MAX_REQUEST)
      .map_err(err)?
      .ok_or("Empty request")?;
    let request: Request = serde_json::from_slice(&bytes).map_err(err)?;
    dispatch(request, sessions, serial)
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

fn dispatch(request: Request, sessions: &Sessions, serial: &AtomicUsize) -> Result<Value, String> {
  match &request {
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
