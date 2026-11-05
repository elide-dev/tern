mod upstream {
  include!("../../../third_party/studio-embed/src/main.rs");
  pub fn entry() {
    main();
  }
}

fn main() {
  // SAFETY: establish our own process group before creating any threads or SDK children.
  if unsafe { libc::setpgid(0, 0) } != 0 {
    eprintln!(
      "Cannot isolate worker process group: {}",
      std::io::Error::last_os_error()
    );
    std::process::exit(1);
  }
  // SAFETY: getppid has no preconditions. The broker remains our parent for this worker's lifetime.
  let parent = unsafe { libc::getppid() };
  std::thread::spawn(move || {
    loop {
      std::thread::sleep(std::time::Duration::from_millis(250));
      // SAFETY: the dedicated group contains only this worker and its SDK-owned subprocesses.
      unsafe {
        if libc::getppid() != parent || parent == 1 {
          libc::kill(0, libc::SIGKILL);
        }
      }
    }
  });
  upstream::entry();
}
