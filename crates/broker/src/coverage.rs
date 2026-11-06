use elide_project_session::coverage::{Artifact, File};
use serde_json::{Value, json};

const MAX_PAGE_BYTES: usize = 256 * 1024;

fn source(index: usize, file: &File) -> Value {
  json!({"index":index, "engine":file.engine, "language":file.language, "path":file.path, "sourceDigest":file.source_digest})
}

pub fn page(artifact: &Artifact, file: Option<usize>, offset: usize, limit: usize) -> Result<Value, String> {
  if !(1..=100).contains(&limit) {
    return Err("Coverage page limit must be between 1 and 100".into());
  }
  if let Some(index) = file {
    let file = artifact.files.get(index).ok_or("Unknown coverage file index")?;
    if offset > file.lines.len() {
      return Err("Coverage line offset exceeds the file's measurement".into());
    }
    let end = offset.saturating_add(limit).min(file.lines.len());
    return Ok(json!({
      "version":artifact.version, "complete":artifact.complete, "file":source(index,file),
      "offset":offset, "next":(end < file.lines.len()).then_some(end),
      "total":file.lines.len(), "lines":file.lines[offset..end],
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
    let first = page(&artifact, None, 0, 1).unwrap();
    assert_eq!(first["next"], 1);
    assert_eq!(first["files"][0]["covered_lines"], 1);
    assert_eq!(first["files"][0]["sourceDigest"], Value::Null);
    assert_eq!(first["files"][0]["engine"], "js");
    assert_eq!(first["files"][0]["language"], "python");
    assert_eq!(first["complete"], false);
    assert!(first["files"][0].get("lines").is_none());
    let last = page(&artifact, Some(0), 1, 1).unwrap();
    assert_eq!(last["lines"][0]["line"], 5);
    assert_eq!(last["next"], Value::Null);
    assert!(page(&artifact, Some(2), 0, 1).is_err());
    assert!(page(&artifact, Some(0), 3, 1).is_err());
    assert!(page(&artifact, None, 3, 1).is_err());
    assert!(page(&artifact, None, 0, 101).is_err());
    assert!(page(&artifact, None, 0, 0).is_err());
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
      let result = page(&artifact, None, offset, 100).unwrap();
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
}
