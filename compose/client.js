"use strict";
// Tern passes its pinned appearance (#light or #dark); otherwise the page follows the system's.
const scheme = location.hash.slice(1);
if (scheme === "light" || scheme === "dark") document.documentElement.style.colorScheme = scheme;
const status = document.querySelector("#status");
const gallery = document.querySelector("#gallery");
const refresh = document.querySelector("#refresh");
const progress = document.querySelector("#progress");
const activity = document.querySelector("#activity");
const latest = document.querySelector("#latest");
const summary = document.querySelector("#summary");
const diagnostics = document.querySelector("#diagnostics");
const detail = document.querySelector("#detail");
const actions = document.querySelectorAll("#stop, #source, #close");
const phases = {
  starting: "Starting previews…",
  resolving: "Loading project…",
  runtime: "Preparing renderer…",
  building: "Building preview inputs…",
  refreshing: "Updating previews…",
  rendering: "Rendering previews…",
  cancelling: "Stopping previews…",
  closing: "Closing preview…",
};
// Busy phases show their label over a bar and the renderer's latest line; a running session only
// its summary in the bar; a failure its first line, with the rest (compiler output) behind a disclosure.
function showStatus(phase, message) {
  const label = phases[phase];
  const text = (message || "").trimEnd();
  if (phase === "live") summary.textContent = text;
  activity.hidden = phase === "live";
  activity.classList.toggle("failed", phase === "error");
  activity.setAttribute("aria-busy", String(!!label));
  progress.hidden = !label;
  const [first, ...rest] = text.split("\n");
  status.textContent = label || first;
  latest.textContent = label ? text.split("\n").pop() : "";
  latest.hidden = !latest.textContent;
  detail.textContent = label ? "" : rest.join("\n").trim();
  diagnostics.hidden = !detail.textContent;
  diagnostics.open = !diagnostics.hidden;
}
const cards = new Map();
// The gallery's card order, the cards its session hosts and those that take keys. No card is
// interactive between an `invalidate` and the next `gallery`.
let order = [];
let hosted = new Set();
let keyed = new Set();
let interactive = false;
let epoch = 0;
let focused;
let socket;
let stopped = false;
const namedKeys = new Set(["Backspace", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Enter", "Tab", "Escape", "Home", "End", "PageUp", "PageDown", "Insert", "Shift", "Control", "Alt", "Meta", ...Array.from({ length: 12 }, (_, i) => `F${i + 1}`)]);
function send(value) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ ...value, epoch }));
}
function release(card) {
  if (!card) return;
  if (card.pointer !== undefined) {
    send({ type: "pointer", id: card.id, action: "up", x: card.x, y: card.y });
    if (card.image.hasPointerCapture(card.pointer)) card.image.releasePointerCapture(card.pointer);
    card.pointer = undefined;
  }
  send({ type: "blur", id: card.id });
  if (focused === card) focused = undefined;
}
function reset() {
  for (const card of cards.values()) release(card);
  document.activeElement?.blur();
}
function update(card) {
  const live = interactive && hosted.has(card.id) && card.frame && !card.failed;
  if (card.live && !live) release(card);
  card.live = live;
  card.keyboard = live && keyed.has(card.id);
  card.detail.textContent = card.text + (card.keyboard ? " · Type to interact" : "");
}
function position(card, event) {
  const box = card.image.getBoundingClientRect();
  card.x = Math.max(0, Math.min(card.width - 1, (event.clientX - box.left) * card.width / box.width));
  card.y = Math.max(0, Math.min(card.height - 1, (event.clientY - box.top) * card.height / box.height));
  return { x: card.x, y: card.y };
}
function makeCard(id) {
  const element = document.createElement("article");
  const name = document.createElement("h2");
  const detail = document.createElement("p");
  detail.className = "detail";
  const image = document.createElement("img");
  image.draggable = false;
  image.decoding = "sync";
  image.tabIndex = 0;
  const error = document.createElement("p");
  error.className = "error";
  element.append(name, detail, image, error);
  gallery.append(element);
  const card = { id, element, name, detail, image, error, text: "", frame: false, failed: false, live: false, keyboard: false, x: 0, y: 0 };
  image.addEventListener("pointerdown", event => {
    if (!card.live || event.button !== 0 || card.pointer !== undefined) return;
    event.preventDefault();
    if (focused !== card) release(focused);
    focused = card;
    image.focus({ preventScroll: true });
    card.pointer = event.pointerId;
    image.setPointerCapture(event.pointerId);
    send({ type: "pointer", id, action: "down", ...position(card, event) });
  });
  // Moves reach the preview only while this card holds the pointer: a drag, not a hover.
  image.addEventListener("pointermove", event => {
    if (!card.live || card.pointer !== event.pointerId) return;
    send({ type: "pointer", id, action: "move", ...position(card, event) });
  });
  image.addEventListener("pointerup", event => {
    if (card.pointer !== event.pointerId) return;
    send({ type: "pointer", id, action: "up", ...position(card, event) });
    card.pointer = undefined;
    image.releasePointerCapture(event.pointerId);
  });
  image.addEventListener("pointercancel", () => release(card));
  image.addEventListener("lostpointercapture", () => { if (card.pointer !== undefined) release(card); });
  image.addEventListener("wheel", event => {
    if (!card.live) return;
    event.preventDefault();
    const box = image.getBoundingClientRect();
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? box.height : 1;
    send({ type: "pointer", id, action: "scroll", ...position(card, event), dx: event.deltaX * unit * card.width / box.width, dy: event.deltaY * unit * card.height / box.height });
  }, { passive: false });
  image.addEventListener("focus", () => { if (focused !== card) release(focused); focused = card; });
  image.addEventListener("blur", () => release(card));
  for (const action of ["keydown", "keyup"]) image.addEventListener(action, event => {
    if (event.key === "Escape") { event.preventDefault(); release(card); image.blur(); return; }
    if (!card.live || !card.keyboard || event.isComposing || (!namedKeys.has(event.key) && Array.from(event.key).length !== 1)) return;
    event.preventDefault();
    send({ type: "keyboard", id, event: { action: action === "keydown" ? "down" : "up", key: event.key, code: event.code, ctrlKey: event.ctrlKey, altKey: event.altKey, shiftKey: event.shiftKey, metaKey: event.metaKey, repeat: event.repeat } });
  });
  cards.set(id, card);
  return card;
}
function connect() {
  socket = new WebSocket(new URL("./events", location.href).href.replace(/^http/, "ws"));
  socket.onmessage = event => {
    const data = JSON.parse(event.data);
    if (data.type === "reset") {
      reset(); epoch = data.epoch;
    } else if (data.type === "invalidate") {
      reset(); epoch = data.epoch; interactive = false;
      for (const card of cards.values()) update(card);
    } else if (data.type === "file") {
      document.querySelector("#name").textContent = data.name;
      document.querySelector("#name").title = data.path;
      document.querySelector("#path").textContent = data.path;
      document.title = "Compose · " + data.name;
    } else if (data.type === "status" && !stopped) {
      // Once the page asked to stop or leave, the renderer's own status no longer applies.
      showStatus(data.phase, data.message);
      refresh.disabled = data.phase !== "live" && data.phase !== "error";
    } else if (data.type === "gallery") {
      epoch = data.epoch; interactive = true;
      order = data.ids; hosted = new Set(data.live); keyed = new Set(data.keyboard);
      const keep = new Set(order);
      for (const [id, card] of cards) if (!keep.has(id)) { release(card); card.element.remove(); cards.delete(id); }
      for (const card of cards.values()) update(card);
    } else if (data.type === "image" && data.epoch === epoch) {
      const value = data.image;
      let card = cards.get(value.id);
      if (!card) {
        card = makeCard(value.id);
        for (const id of order) if (cards.has(id)) gallery.append(cards.get(id).element);
      }
      card.name.textContent = value.name;
      card.text = value.detail;
      card.error.textContent = value.error || "";
      card.frame = !!value.data;
      card.failed = !!value.error;
      card.width = value.width; card.height = value.height;
      // A failing card keeps its last good pixels beside its error.
      card.image.hidden = !value.data;
      if (value.data) { card.image.src = "data:image/png;base64," + value.data; card.image.alt = value.name; card.image.width = value.width; card.image.height = value.height; }
      update(card);
    }
  };
  socket.onclose = () => {
    reset(); interactive = false; disconnected = true;
    for (const card of cards.values()) update(card);
    // With the service gone, Tern carries out Start, Open source and Close (see `ask`).
    document.querySelector("#stop").disabled = true;
    for (const button of [refresh, document.querySelector("#source"), document.querySelector("#close")]) button.disabled = false;
    refresh.title = "Start previews"; refresh.setAttribute("aria-label", "Start previews");
    showStatus("stopped", stopped ? "Preview stopped." : "Disconnected from the renderer.");
  };
}
let disconnected = false;
// Without a service Tern reads the page's address: `#<action>-<n>`, a fresh `n` per click.
function ask(action) {
  location.hash = `${action}-${Date.now()}`;
}
refresh.onclick = () => {
  if (disconnected) {
    refresh.disabled = true;
    showStatus("starting", "");
    ask("start");
    return;
  }
  reset(); refresh.disabled = true;
  showStatus("refreshing", "");
  send({ type: "refresh" });
};
document.querySelector("#stop").onclick = () => {
  reset(); stopped = true; refresh.disabled = true;
  showStatus("cancelling", "");
  send({ type: "stop" });
};
// Tern carries these out: it opens the file or closes the pane.
function request(action, phase) {
  if (disconnected) {
    ask(action);
    return;
  }
  reset();
  if (phase) {
    stopped = true; refresh.disabled = true;
    for (const button of actions) button.disabled = true;
    showStatus(phase, "");
  }
  send({ type: "request", action });
}
document.querySelector("#source").onclick = () => request("source");
document.querySelector("#close").onclick = () => request("close", "closing");
window.addEventListener("blur", reset);
document.addEventListener("visibilitychange", () => { if (document.hidden) reset(); });
window.addEventListener("pagehide", () => { reset(); socket?.close(); });
connect();
