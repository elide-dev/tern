use serde_json::{Value, json};
use std::{
  collections::hash_map::DefaultHasher,
  hash::{Hash, Hasher},
  path::Path,
};

// Detection never evaluates Pkl or loads project code.
pub fn discover(path: &Path) -> Result<Value, String> {
  let path = path.canonicalize().map_err(|e| e.to_string())?;
  let directory = if path.is_dir() {
    path.as_path()
  } else {
    path.parent().ok_or("No parent directory")?
  };
  for root in directory.ancestors() {
    if root.join("elide.pkl").is_file() {
      let mut identity = DefaultHasher::new();
      root.hash(&mut identity);
      return Ok(json!({
        "root": root,
        "name": root.file_name().map(|name| name.to_string_lossy()),
        "session_key": format!("{:016x}", identity.finish()),
      }));
    }
  }
  Ok(Value::Null)
}
