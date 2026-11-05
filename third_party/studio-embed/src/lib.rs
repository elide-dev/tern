//! Supervised native Elide embedding. IPC carries length-delimited, unpacked
//! Cap'n Proto messages; the SDK is loaded only in the owned worker process.
mod abi;
pub use abi::Session;
#[allow(clippy::all, unused_parens)]
pub mod embedding_capnp { include!(concat!(env!("OUT_DIR"), "/embedding_capnp.rs")); }

use std::{
    io::{self, Read, Write},
    path::Path,
    process::{Child, Command, Stdio},
    sync::mpsc,
    thread,
    time::Duration,
};
pub const MAX_REQUEST: usize = 4 * 1024 * 1024;
pub const MAX_RESPONSE: usize = 16 * 1024 * 1024;

pub fn read_frame(reader: &mut impl Read, limit: usize) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0; 4];
    if reader.read(&mut header[..1])? == 0 {
        return Ok(None);
    }
    reader.read_exact(&mut header[1..])?;
    let size = u32::from_le_bytes(header) as usize;
    if size == 0 || size > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid embedded frame size",
        ));
    }
    let mut bytes = vec![0; size];
    reader.read_exact(&mut bytes)?;
    Ok(Some(bytes))
}
pub fn write_frame(writer: &mut impl Write, bytes: &[u8]) -> io::Result<()> {
    let size = u32::try_from(bytes.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "Frame too large"))?;
    writer.write_all(&size.to_le_bytes())?;
    writer.write_all(bytes)
}

type Job = (Vec<u8>, mpsc::SyncSender<Result<Vec<u8>, String>>);
pub struct Worker {
    child: Child,
    jobs: Option<mpsc::Sender<Job>>,
    io: Option<thread::JoinHandle<()>>,
    stopped: bool,
}
impl Worker {
    pub fn spawn(executable: &Path, sdk: &Path) -> Result<Self, String> {
        let mut command = Command::new(executable);
        command
            .arg(sdk)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        let child = command.spawn().map_err(|e| e.to_string())?;
        Ok(Self::from_child(child))
    }
    fn from_child(mut child: Child) -> Self {
        let mut input = child.stdin.take().expect("piped stdin");
        let mut output = child.stdout.take().expect("piped stdout");
        let (jobs, incoming) = mpsc::channel::<Job>();
        let io = thread::spawn(move || {
            for (request, reply) in incoming {
                let result = (|| {
                    write_frame(&mut input, &request)?;
                    input.flush()?;
                    read_frame(&mut output, MAX_RESPONSE)?.ok_or_else(|| {
                        io::Error::new(io::ErrorKind::UnexpectedEof, "Embedded worker exited")
                    })
                })()
                .map_err(|e: io::Error| e.to_string());
                let failed = result.is_err();
                let _ = reply.send(result);
                if failed {
                    break;
                }
            }
        });
        Self {
            child,
            jobs: Some(jobs),
            io: Some(io),
            stopped: false,
        }
    }
    /// Serial calls; timeout terminates the worker and invalidates all its handles.
    /// Includes blocked writes and reads, not just time spent executing guest code.
    pub fn exchange(&mut self, request: Vec<u8>, timeout: Duration) -> Result<Vec<u8>, String> {
        if request.is_empty() || request.len() > MAX_REQUEST || timeout.is_zero() {
            return Err("Invalid request or timeout".into());
        }
        if self.stopped {
            return Err("Embedded worker has stopped".into());
        }
        let (send, receive) = mpsc::sync_channel(1);
        let sent = self.jobs.as_ref().unwrap().send((request, send));
        let result = if sent.is_err() {
            Err("Embedded worker IO stopped".into())
        } else {
            receive
                .recv_timeout(timeout)
                .map_err(|_| "Embedded worker deadline exceeded or disconnected".to_owned())
                .and_then(|r| r)
        };
        if result.is_err() {
            self.stop();
        }
        result
    }
    /// PID for the local CPU/memory harness; no guest or credential data is exposed.
    pub fn id(&self) -> u32 {
        self.child.id()
    }

    pub fn stop(&mut self) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        #[cfg(unix)]
        // SAFETY: the child owns a dedicated process group; it has not been reaped.
        unsafe { libc::kill(-(self.child.id() as i32), libc::SIGKILL); }
        let _ = self.child.kill();
        let _ = self.child.wait();
        self.jobs.take();
        if let Some(io) = self.io.take() {
            let _ = io.join();
        }
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn frames_are_bounded_and_truncation_is_not_eof() {
        assert!(read_frame(&mut &[][..], 10).unwrap().is_none());
        for bytes in [&[1][..], &[0, 0, 0, 0], &[11, 0, 0, 0], &[2, 0, 0, 0, 1]] {
            assert!(read_frame(&mut &*bytes, 10).is_err());
        }
        let mut bytes = Vec::new();
        write_frame(&mut bytes, b"hello").unwrap();
        assert_eq!(
            read_frame(&mut bytes.as_slice(), 10).unwrap().unwrap(),
            b"hello"
        );
    }
    #[cfg(unix)]
    #[test]
    fn timeout_covers_blocked_input_and_reaps_worker() {
        let child = Command::new("/bin/sleep")
            .arg("30")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut worker = Worker::from_child(child);
        let start = std::time::Instant::now();
        assert!(worker
            .exchange(vec![1; MAX_REQUEST], Duration::from_millis(100))
            .is_err());
        assert!(start.elapsed() < Duration::from_secs(3));
        assert!(worker.child.try_wait().unwrap().is_some());
        assert!(worker.exchange(vec![1], Duration::from_secs(1)).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn drop_reaps_idle_worker() {
        let child = Command::new("/bin/cat")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut worker = Worker::from_child(child);
        assert_eq!(
            worker
                .exchange(vec![1, 2, 3], Duration::from_secs(1))
                .unwrap(),
            [1, 2, 3]
        );
        worker.stop();
        assert!(worker.child.try_wait().unwrap().is_some());
    }
}
