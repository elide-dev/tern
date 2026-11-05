use serde::Deserialize;
use serde_json::{Value, json};
use studio_embed::embedding_capnp as wire;

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
  ProjectAttach {
    root: String,
    runtime: String,
  },
  ProjectSnapshot {
    binding: elide_project_session::Binding,
    #[serde(default)]
    after: Option<String>,
  },
  ProjectSummary {
    binding: elide_project_session::Binding,
  },
  ProjectDetach {
    binding: elide_project_session::Binding,
  },
  ProjectTest {
    binding: elide_project_session::Binding,
    command: String,
    subject: String,
  },
  ProjectCancel {
    binding: elide_project_session::Binding,
    run: String,
  },
  Ping {},
  Open {
    sdk: String,
  },
  Close {
    session: String,
  },
  Discover {
    session: String,
  },
  OpenKernel {
    session: String,
    language: String,
  },
  Evaluate {
    session: String,
    kernel: String,
    language: String,
    source: String,
  },
  Protocol {
    session: String,
    kind: String,
    #[serde(default)]
    service: String,
    #[serde(default)]
    json: String,
    #[serde(default)]
    poll: bool,
    #[serde(default)]
    close: bool,
  },
}

impl Request {
  pub fn session(&self) -> Option<&str> {
    match self {
      Self::Close { session }
      | Self::Discover { session }
      | Self::OpenKernel { session, .. }
      | Self::Evaluate { session, .. }
      | Self::Protocol { session, .. } => Some(session),
      _ => None,
    }
  }

  pub fn encode(&self) -> Result<Vec<u8>, String> {
    let mut message = capnp::message::Builder::new_default();
    let mut root = message.init_root::<wire::request::Builder>();
    root.set_major(1);
    root.set_minor(0);
    root.set_id(1);
    match self {
      Self::Discover { .. } => root.set_discover(()),
      Self::OpenKernel { language, .. } => root.set_open_kernel(language.as_str()),
      Self::Evaluate {
        kernel,
        language,
        source,
        ..
      } => {
        let mut evaluation = root.init_evaluate();
        evaluation.set_kernel(kernel.parse::<u64>().map_err(|_| "Invalid kernel handle")?);
        let mut doc = evaluation.init_document();
        doc.set_uri("elide-tern:repl");
        doc.set_language(language.as_str());
        doc.set_source(source.as_str());
        doc.set_version(1);
        doc.set_module(false);
      }
      Self::Protocol {
        kind,
        service,
        json,
        poll,
        close,
        ..
      } => {
        if *poll && *close || ((*poll || *close) && !json.is_empty()) {
          return Err("Poll/close operations must not contain JSON or be combined".into());
        }
        if !*poll && !*close {
          serde_json::from_str::<Value>(json).map_err(|e| format!("Invalid JSON-RPC: {e}"))?;
        }
        let mut protocol = root.init_protocol();
        protocol.set_kind(match kind.as_str() {
          "lsp" => wire::protocol_message::Kind::Lsp,
          "mcp" => wire::protocol_message::Kind::Mcp,
          _ => return Err("Protocol kind must be lsp or mcp".into()),
        });
        protocol.set_service(service.as_str());
        protocol.set_json(json.as_str());
        protocol.set_poll(*poll);
        protocol.set_close(*close);
        protocol.set_wait_millis(0);
      }
      _ => return Err("Not an SDK request".into()),
    }
    Ok(capnp::serialize::write_message_to_words(&message))
  }
}

pub fn decode(bytes: &[u8]) -> Result<Value, String> {
  fn inner(bytes: &[u8]) -> Result<Value, Box<dyn std::error::Error>> {
    let message = capnp::serialize::read_message(&mut &*bytes, Default::default())?;
    let root = message.get_root::<wire::response::Reader>()?;
    if root.get_major() != 1 || root.get_id() != 1 {
      return Err("Unexpected SDK response version or request ID".into());
    }
    let status = root.get_status()?;
    if status != wire::Status::Ok {
      return Err(format!("{status:?}: {}", root.get_error()?.to_str()?).into());
    }
    use wire::response::Which;
    Ok(match root.which()? {
      Which::Capabilities(caps) => {
        let caps = caps?;
        let mut languages = Vec::new();
        for lang in caps.get_languages()? {
          languages.push(
            json!({"id": lang.get_id()?.to_str()?, "version": lang.get_version()?.to_str()?,
            "execution": lang.get_execution(), "partial_analysis": lang.get_partial_analysis()}),
          );
        }
        let services = caps
          .get_language_servers()?
          .iter()
          .map(|v| Ok(v?.to_str()?.to_owned()))
          .collect::<Result<Vec<_>, Box<dyn std::error::Error>>>()?;
        json!({"languages": languages, "language_servers": services, "lsp": caps.get_lsp(), "mcp": caps.get_mcp()})
      }
      Which::Kernel(kernel) => json!({"kernel": kernel.to_string()}),
      Which::Evaluation(value) => {
        let value = value?;
        json!({"value": value.get_value()?.to_str()?, "stdout": String::from_utf8_lossy(value.get_stdout()?),
        "stderr": String::from_utf8_lossy(value.get_stderr()?), "truncated": value.get_truncated(), "display": match value.get_display()? {
          studio_embed::embedding_capnp::evaluation_result::Display::Legacy => "legacy",
          studio_embed::embedding_capnp::evaluation_result::Display::None => "none",
          studio_embed::embedding_capnp::evaluation_result::Display::Text => "text",
          studio_embed::embedding_capnp::evaluation_result::Display::Json => "json",
        }})
      }
      Which::Messages(messages) => {
        let messages = messages?
          .iter()
          .map(|v| Ok(v?.to_str()?.to_owned()))
          .collect::<Result<Vec<_>, Box<dyn std::error::Error>>>()?;
        json!({"messages": messages})
      }
      Which::Empty(()) => json!({}),
      _ => return Err("Unexpected SDK response variant".into()),
    })
  }
  inner(bytes).map_err(|e| e.to_string())
}
