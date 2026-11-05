@0xd8934c7abf91e625;

# Copyright (c) 2026 Elide Technologies, Inc.
# SPDX-License-Identifier: Apache-2.0
using Java = import "/capnp/java.capnp";
$Java.package("dev.elide.proto.v1");
$Java.outerClassname("EmbeddingProtocol");

# Standard unpacked Cap'n Proto stream framing; one request and one response per exchange.
# Service handles are scoped to the owning transport session, never native addresses.
struct Request {
  major @0 :UInt16;
  minor @1 :UInt16;
  id @2 :UInt64;
  union {
    discover @3 :Void;
    analyze @4 :Document;
    openKernel @5 :Text;
    evaluate @6 :Evaluation;
    closeKernel @7 :UInt64;
    statistics @8 :Void;
    protocol @9 :ProtocolMessage;
  }
}

struct ProtocolMessage {
  kind @0 :Kind;
  json @1 :Text;
  # One JSON-RPC message without stream headers. State belongs to the owning session.
  service @2 :Text;
  # Empty selects the built-in adapter. Named LSP channels select SDK-owned compiler workers.
  poll @3 :Bool;
  waitMillis @4 :UInt16;
  # Polling drains asynchronous messages; waits are bounded to 1000 ms. Polls carry no JSON.
  close @5 :Bool;
  # Terminal close for the named channel. A later message opens a fresh worker.
  enum Kind { mcp @0; lsp @1; }
}

struct Document {
  uri @0 :Text;
  version @1 :Int64;
  language @2 :Text;
  source @3 :Text;
  module @4 :Bool;
}

struct Evaluation {
  kernel @0 :UInt64;
  document @1 :Document;
}

enum Status {
  ok @0;
  invalidRequest @1;
  unsupported @2;
  notFound @3;
  limitExceeded @4;
  guestError @5;
  internalError @6;
}

struct Response {
  major @0 :UInt16;
  minor @1 :UInt16;
  id @2 :UInt64;
  status @3 :Status;
  error @4 :Text;
  union {
    empty @5 :Void;
    capabilities @6 :Capabilities;
    analysis @7 :Analysis;
    kernel @8 :UInt64;
    evaluation @9 :EvaluationResult;
    statistics @10 :Statistics;
    messages @11 :List(Text);
  }
}

struct Capabilities {
  languages @0 :List(Language);
  maxSourceUnits @1 :UInt32;
  maxMessageBytes @2 :UInt32;
  maxKernels @3 :UInt32;
  # Calls are synchronous and serialized per transport session.
  cancellation @4 :Bool;
  osIsolation @5 :Bool;
  format @6 :Bool;
  typeChecking @7 :Bool;
  lsp @8 :Bool;
  mcp @9 :Bool;
  languageServers @10 :List(Text);
  # Named SDK-owned worker channels. Each negotiates semantic capabilities through LSP initialize.
}

struct Language {
  id @0 :Text;
  version @1 :Text;
  lexicalAnalysis @2 :Bool;
  execution @3 :Bool;
  # Analysis reports loaded lexical sections, not a complete semantic model.
  partialAnalysis @4 :Bool;
  syntaxDiagnostics @5 :Bool;
  variableAccesses @6 :Bool;
  rootSymbols @7 :Bool;
}

struct Location {
  present @0 :Bool;
  offset @1 :UInt32;
  length @2 :UInt32;
  # UTF-16 code units in the request's exact source buffer.
}

struct Symbol {
  name @0 :Text;
  declaration @1 :Location;
}

struct Scope {
  location @0 :Location;
  symbols @1 :List(Symbol);
}

struct Diagnostic {
  message @0 :Text;
  location @1 :Location;
}

struct Analysis {
  uri @0 :Text;
  version @1 :Int64;
  digest @2 :Text;
  language @3 :Text;
  scopes @4 :List(Scope);
  diagnostics @5 :List(Diagnostic);
  partial @6 :Bool = true;
  accesses @7 :List(VariableAccess);
  roots @8 :List(RootSymbol);
}

struct VariableAccess {
  name @0 :Text;
  kind @1 :Kind;
  location @2 :Location;
  # Instrumentation site; may span a declaration/assignment rather than one token.
  enum Kind { read @0; write @1; }
}

struct RootSymbol {
  qualifiedName @0 :Text;
  location @1 :Location;
}

struct EvaluationResult {
  value @0 :Text;
  stdout @1 :Data;
  stderr @2 :Data;
  truncated @3 :Bool;
  display @4 :Display;
  # Legacy clients keep reading value. New clients distinguish absent results from JSON null.
  enum Display { legacy @0; none @1; text @2; json @3; }
}

struct Statistics {
  requests @0 :UInt64;
  analyses @1 :UInt64;
  evaluations @2 :UInt64;
  kernels @3 :UInt32;
  # Session activity counters; not static code statistics or execution coverage.
}
