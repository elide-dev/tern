use elide_project_session::coverage::{Artifact, File, LineState, line_states};
use serde_json::{Value, json};
use std::{
  collections::{HashMap, VecDeque},
  io::Read,
  path::{Path, PathBuf},
  sync::Arc,
};

const MAX_PAGE_BYTES: usize = 256 * 1024;
/// Source files above this size are not read for inference (the Tests view's limit).
const MAX_SOURCE_BYTES: u64 = 2 * 1024 * 1024;

/// The current text of a measured file, when it lies inside `root` after resolving
/// symlinks and is at most `MAX_SOURCE_BYTES`. Artifact paths are validated project-relative
/// identifiers, never `..` or absolute.
fn read_source(root: &Path, relative: &str) -> Option<String> {
  let root = root.canonicalize().ok()?;
  let path = root.join(relative).canonicalize().ok()?;
  // Only a regular file: a FIFO or device would block the request thread on open or read.
  if !path.starts_with(&root) || !std::fs::metadata(&path).ok()?.is_file() {
    return None;
  }
  let mut text = String::new();
  std::fs::File::open(path)
    .ok()?
    .take(MAX_SOURCE_BYTES + 1)
    .read_to_string(&mut text)
    .ok()?;
  (text.len() as u64 <= MAX_SOURCE_BYTES).then_some(text)
}

/// How many files' line entries stay cached across pages.
const CACHED_FILES: usize = 32;

/// Line entries per run and file, so paging a file reads its source and infers its lines once
/// rather than once per page. A run's artifact is immutable; the source is read at the first page.
#[derive(Default)]
pub struct Inferred {
  entries: HashMap<(PathBuf, String, usize), Arc<Vec<Value>>>,
  order: VecDeque<(PathBuf, String, usize)>,
  /// How many times entries were computed (for tests).
  pub computed: usize,
}

impl Inferred {
  fn get(&mut self, key: (PathBuf, String, usize), file: &File, root: Option<&Path>) -> Arc<Vec<Value>> {
    if let Some(found) = self.entries.get(&key) {
      return found.clone();
    }
    self.computed += 1;
    let computed = Arc::new(entries(file, root));
    if self.order.len() >= CACHED_FILES
      && let Some(oldest) = self.order.pop_front()
    {
      self.entries.remove(&oldest);
    }
    self.order.push_back(key.clone());
    self.entries.insert(key, computed.clone());
    computed
  }
}

/// A file's coverage entries in line order: each measured line with its `state`, plus an
/// entry `{line, state: "inferred"}` for every closer, blank or comment line that inherits
/// a covered block's coverage. Inference reads the current source, so it is skipped when
/// the source cannot be read or no longer reaches every measured line; measured entries
/// then carry no `state`, as before.
fn entries(file: &File, root: Option<&Path>) -> Vec<Value> {
  let states = root.and_then(|root| read_source(root, &file.path)).and_then(|source| {
    let states = line_states(file, &source);
    file
      .lines
      .iter()
      .all(|line| (line.line as usize) <= states.len())
      .then_some(states)
  });
  let mut entries: Vec<(u32, Value)> = file
    .lines
    .iter()
    .map(|line| {
      let mut entry = json!(line);
      if let Some(state) = states
        .as_ref()
        .and_then(|states| states.get((line.line as usize).checked_sub(1)?))
      {
        entry["state"] = json!(state);
      }
      (line.line, entry)
    })
    .collect();
  if let Some(states) = &states {
    for (index, state) in states.iter().enumerate() {
      if *state == LineState::Inferred {
        let line = u32::try_from(index + 1).unwrap_or(u32::MAX);
        entries.push((line, json!({"line":line, "state":state})));
      }
    }
  }
  entries.sort_by_key(|(line, _)| *line);
  entries.into_iter().map(|(_, entry)| entry).collect()
}

fn source(index: usize, file: &File) -> Value {
  json!({"index":index, "engine":file.engine, "language":file.language, "path":file.path, "sourceDigest":file.source_digest})
}

/// A page of the artifact: the file listing, or one file's line entries. `root` is the
/// attached project root used to read sources for inferred lines (`None` skips inference);
/// `run` and `cache` share one computation across a file's pages.
pub fn page(
  artifact: &Artifact,
  file: Option<usize>,
  offset: usize,
  limit: usize,
  root: Option<&Path>,
  run: &str,
  cache: &mut Inferred,
) -> Result<Value, String> {
  if !(1..=100).contains(&limit) {
    return Err("Coverage page limit must be between 1 and 100".into());
  }
  if let Some(index) = file {
    let file = artifact.files.get(index).ok_or("Unknown coverage file index")?;
    let key = (root.map(Path::to_path_buf).unwrap_or_default(), run.to_owned(), index);
    let lines = cache.get(key, file, root);
    if offset > lines.len() {
      return Err("Coverage line offset exceeds the file's measurement".into());
    }
    let end = offset.saturating_add(limit).min(lines.len());
    return Ok(json!({
      "version":artifact.version, "complete":artifact.complete, "file":source(index,file),
      "offset":offset, "next":(end < lines.len()).then_some(end),
      "total":lines.len(), "lines":lines[offset..end],
    }));
  }
  if offset > artifact.files.len() {
    return Err("Coverage file offset exceeds the run's measurement".into());
  }
  let requested_end = offset.saturating_add(limit).min(artifact.files.len());
  let mut files = Vec::new();
  // Reserve envelope space; escaped filenames can be much larger than their source bytes.
  let mut remaining = MAX_PAGE_BYTES - 1024;
  for (position, file) in artifact.files[offset..requested_end].iter().enumerate() {
    let mut entry = source(offset + position, file);
    entry["total_lines"] = json!(file.lines.len());
    entry["covered_lines"] = json!(file.lines.iter().filter(|line| line.covered).count());
    let bytes = serde_json::to_vec(&entry).map_err(|error| error.to_string())?.len() + 1;
    if bytes > remaining {
      if files.is_empty() {
        return Err("Coverage file metadata exceeds the page byte limit".into());
      }
      break;
    }
    remaining -= bytes;
    files.push(entry);
  }
  let end = offset + files.len();
  Ok(json!({
    "version":artifact.version, "complete":artifact.complete, "files":files,
    "offset":offset, "next":(end < artifact.files.len()).then_some(end), "total":artifact.files.len(),
  }))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn immutable_files_and_lines_are_paged_without_dropping_unknown_identity() {
    let artifact: Artifact = serde_json::from_value(json!({
      "version":1, "complete":false, "files":[
        {"engine":"js","language":"python","path":"src/café.py","lines":[
          {"line":2,"covered":true},{"line":5,"covered":false}
        ]},
        {"engine":"js","path":"src/other.js","lines":[]}
      ]
    }))
    .unwrap();
    let first = page(&artifact, None, 0, 1, None, "r", &mut Inferred::default()).unwrap();
    assert_eq!(first["next"], 1);
    assert_eq!(first["files"][0]["covered_lines"], 1);
    assert_eq!(first["files"][0]["sourceDigest"], Value::Null);
    assert_eq!(first["files"][0]["engine"], "js");
    assert_eq!(first["files"][0]["language"], "python");
    assert_eq!(first["complete"], false);
    assert!(first["files"][0].get("lines").is_none());
    let last = page(&artifact, Some(0), 1, 1, None, "r", &mut Inferred::default()).unwrap();
    assert_eq!(last["lines"][0]["line"], 5);
    assert_eq!(last["next"], Value::Null);
    assert!(page(&artifact, Some(2), 0, 1, None, "r", &mut Inferred::default()).is_err());
    assert!(page(&artifact, Some(0), 3, 1, None, "r", &mut Inferred::default()).is_err());
    assert!(page(&artifact, None, 3, 1, None, "r", &mut Inferred::default()).is_err());
    assert!(page(&artifact, None, 0, 101, None, "r", &mut Inferred::default()).is_err());
    assert!(page(&artifact, None, 0, 0, None, "r", &mut Inferred::default()).is_err());
  }

  #[test]
  fn escaped_source_paths_stay_bounded_and_pagination_always_advances() {
    let artifact: Artifact = serde_json::from_value(json!({
      "version":1, "complete":true,
      "files":(0..100).map(|index| json!({
        "engine":"js", "path":format!("{index}/{}", "\u{1}".repeat(4000)), "lines":[]
      })).collect::<Vec<_>>(),
    }))
    .unwrap();
    let mut offset = 0;
    let mut count = 0;
    loop {
      let result = page(&artifact, None, offset, 100, None, "r", &mut Inferred::default()).unwrap();
      assert!(serde_json::to_vec(&result).unwrap().len() < MAX_PAGE_BYTES);
      let files = result["files"].as_array().unwrap();
      assert!(!files.is_empty());
      for (position, file) in files.iter().enumerate() {
        assert_eq!(file["index"], offset + position);
      }
      count += files.len();
      match result["next"].as_u64() {
        Some(next) => {
          assert_eq!(next as usize, offset + files.len());
          offset = next as usize;
        }
        None => break,
      }
    }
    assert_eq!(count, artifact.files.len());
  }

  fn project(files: &[(&str, &str)]) -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!(
      "broker-coverage-{}-{}",
      std::process::id(),
      std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos()
    ));
    for (path, text) in files {
      let path = root.join(path);
      std::fs::create_dir_all(path.parent().unwrap()).unwrap();
      std::fs::write(path, text).unwrap();
    }
    root
  }

  #[test]
  fn closers_of_covered_blocks_are_served_as_inferred_lines_in_order() {
    let root = project(&[(
      "src/a.js",
      "function f(x) {\n  if (x) {\n    return 1;\n  }\n  return 2;\n}\n",
    )]);
    let artifact: Artifact = serde_json::from_value(json!({
      "version":1, "complete":true, "files":[{"engine":"js","path":"src/a.js","lines":[
        {"line":1,"covered":true},{"line":2,"covered":true},{"line":3,"covered":true},{"line":5,"covered":false}
      ]}]
    }))
    .unwrap();
    let result = page(&artifact, Some(0), 0, 100, Some(&root), "r", &mut Inferred::default()).unwrap();
    let lines: Vec<(u64, String)> = result["lines"]
      .as_array()
      .unwrap()
      .iter()
      .map(|line| {
        (
          line["line"].as_u64().unwrap(),
          line["state"].as_str().unwrap().to_owned(),
        )
      })
      .collect();
    // Line 4 closes the covered `if`; line 6 closes a block whose last measured line (5) did
    // not run, so it stays unmeasured and is not served.
    assert_eq!(
      lines,
      [
        (1, "covered"),
        (2, "covered"),
        (3, "covered"),
        (4, "inferred"),
        (5, "uncovered")
      ]
      .map(|(line, state)| (line, state.to_owned()))
    );
    assert_eq!(result["total"], 5);
    assert_eq!(
      result["lines"][3].get("covered"),
      None,
      "inferred lines are not measured"
    );
    // Paging covers the merged entries.
    let second = page(&artifact, Some(0), 3, 1, Some(&root), "r", &mut Inferred::default()).unwrap();
    assert_eq!(second["lines"][0]["state"], "inferred");
    assert_eq!(second["next"], 4);
    std::fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn pages_of_one_file_share_one_inference() {
    let root = project(&[("a.js", "if (x) {\n  y();\n}\n")]);
    let artifact: Artifact = serde_json::from_value(json!({
      "version":1, "complete":true, "files":[{"engine":"js","path":"a.js","lines":[
        {"line":1,"covered":true},{"line":2,"covered":true}
      ]}]
    }))
    .unwrap();
    let mut cache = Inferred::default();
    let first = page(&artifact, Some(0), 0, 1, Some(&root), "run-1", &mut cache).unwrap();
    let second = page(&artifact, Some(0), 1, 2, Some(&root), "run-1", &mut cache).unwrap();
    assert_eq!(cache.computed, 1, "both pages come from one computation");
    assert_eq!(first["total"], 3);
    assert_eq!(second["lines"][1]["state"], "inferred");
    page(&artifact, Some(0), 0, 1, Some(&root), "run-2", &mut cache).unwrap();
    assert_eq!(cache.computed, 2, "another run computes its own");
    std::fs::remove_dir_all(root).unwrap();
  }

  #[cfg(unix)]
  #[test]
  fn a_fifo_source_is_never_opened() {
    let root = project(&[]);
    std::fs::create_dir_all(&root).unwrap();
    let fifo = root.join("pipe.js");
    let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let artifact: Artifact = serde_json::from_value(json!({
      "version":1, "complete":true, "files":[{"engine":"js","path":"pipe.js","lines":[{"line":1,"covered":true}]}]
    }))
    .unwrap();
    let (sent, received) = std::sync::mpsc::channel();
    let thread_root = root.clone();
    std::thread::spawn(move || {
      let result = page(
        &artifact,
        Some(0),
        0,
        10,
        Some(&thread_root),
        "r",
        &mut Inferred::default(),
      );
      let _ = sent.send(result.map(|page| page["total"].clone()));
    });
    let total = received
      .recv_timeout(std::time::Duration::from_secs(5))
      .expect("a FIFO must not block the page");
    assert_eq!(total.unwrap(), 1, "measured lines only");
    std::fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn unreadable_shrunk_or_escaping_sources_serve_measured_lines_only() {
    let measured = |path: &str, line: u32| -> Artifact {
      serde_json::from_value(json!({
        "version":1, "complete":true, "files":[{"engine":"js","path":path,"lines":[
          {"line":1,"covered":true},{"line":line,"covered":true}
        ]}]
      }))
      .unwrap()
    };
    let root = project(&[("a.js", "if (x) {\n  y();\n}\n")]);
    // A measured line past the end of the current file: the source changed, no inference.
    let shrunk = page(
      &measured("a.js", 9),
      Some(0),
      0,
      100,
      Some(&root),
      "r",
      &mut Inferred::default(),
    )
    .unwrap();
    assert_eq!(shrunk["total"], 2);
    assert!(shrunk["lines"][0].get("state").is_none());
    // A missing file and no root behave the same way.
    assert_eq!(
      page(
        &measured("missing.js", 2),
        Some(0),
        0,
        100,
        Some(&root),
        "r",
        &mut Inferred::default()
      )
      .unwrap()["total"],
      2
    );
    assert_eq!(
      page(
        &measured("a.js", 2),
        Some(0),
        0,
        100,
        None,
        "r",
        &mut Inferred::default()
      )
      .unwrap()["total"],
      2
    );
    // A symlink that leaves the root is never read.
    let outside = project(&[("secret.js", "if (x) {\n  y();\n}\n")]);
    #[cfg(unix)]
    std::os::unix::fs::symlink(outside.join("secret.js"), root.join("link.js")).unwrap();
    #[cfg(unix)]
    assert_eq!(
      page(
        &measured("link.js", 2),
        Some(0),
        0,
        100,
        Some(&root),
        "r",
        &mut Inferred::default()
      )
      .unwrap()["total"],
      2
    );
    // Inside the root the same text infers the closer.
    assert_eq!(
      page(
        &measured("a.js", 2),
        Some(0),
        0,
        100,
        Some(&root),
        "r",
        &mut Inferred::default()
      )
      .unwrap()["total"],
      3
    );
    std::fs::remove_dir_all(root).unwrap();
    std::fs::remove_dir_all(outside).unwrap();
  }
}
