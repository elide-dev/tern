use elide_project_session::DebugSnapshot;
use serde_json::Value;

const MAX_AGENT_BYTES: usize = 512 * 1024;

pub fn compact(snapshot: DebugSnapshot) -> Result<Value, String> {
  let mut value = serde_json::to_value(snapshot).map_err(|error| error.to_string())?;
  loop {
    if serde_json::to_vec(&value).map_err(|error| error.to_string())?.len() <= MAX_AGENT_BYTES {
      return Ok(value);
    }
    let debug = &mut value["debug"];
    let largest = ["output", "variables", "frames", "scopes", "breakpoints"]
      .into_iter()
      .filter(|key| debug[*key].as_array().is_some_and(|array| !array.is_empty()))
      .max_by_key(|key| serde_json::to_vec(&debug[*key]).map_or(0, |bytes| bytes.len()));
    let Some(key) = largest else {
      return Err("Debugger metadata exceeds the agent response limit".into());
    };
    let array = debug[key].as_array_mut().expect("array selected above");
    array.truncate(array.len() / 2);
    debug["truncated"] = Value::Bool(true);
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use elide_project_session::debug::{Capabilities, Mode, Snapshot, State};

  #[test]
  fn bounded_agent_reads_keep_stop_identity_and_mark_omitted_data() {
    let snapshot = DebugSnapshot {
      debug: Snapshot {
        generation: "generation".into(),
        subject: "script.py".into(),
        mode: Mode::Run,
        revision: 4,
        state: State::Stopped,
        stop_epoch: 7,
        reason: Some("breakpoint".into()),
        thread_id: Some(1),
        frames: vec![],
        scopes: vec![],
        variables: vec![],
        selected_frame: None,
        selected_reference: None,
        breakpoints: vec![],
        output: vec!["\u{1}".repeat(1024); 128],
        error: None,
        pending: false,
        last_command: None,
        truncated: false,
        capabilities: Capabilities::default(),
      },
      controls: false,
      controller: "another attachment".into(),
      grace_seconds: None,
    };
    let value = compact(snapshot).unwrap();
    assert!(serde_json::to_vec(&value).unwrap().len() <= MAX_AGENT_BYTES);
    assert_eq!(value["debug"]["generation"], "generation");
    assert_eq!(value["debug"]["stop_epoch"], 7);
    assert_eq!(value["debug"]["truncated"], true);
    assert_eq!(value["controls"], false);
    assert!(!value["debug"]["output"].as_array().unwrap().is_empty());
  }
}
