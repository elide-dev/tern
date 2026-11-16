"use strict";
const status = document.querySelector("#status");
const gallery = document.querySelector("#gallery");
const refresh = document.querySelector("#refresh");
const progress = document.querySelector("#progress");
const activity = document.querySelector("#activity");
const diagnostics = document.querySelector("#diagnostics");
const detail = document.querySelector("#detail");
const phases = {
  starting: "Starting previews…",
  resolving: "Loading project…",
  waiting: "Waiting for workspace build…",
  runtime: "Preparing renderer…",
  building: "Building preview inputs…",
  refreshing: "Updating previews…",
  rendering: "Rendering previews…",
  cancelling: "Stopping previews…",
};
function showStatus(phase, message) {
  const label = phases[phase];
  status.textContent = label || message;
  progress.hidden = !label;
  activity.setAttribute("aria-busy", String(!!label));
  detail.textContent = label ? message : "";
  diagnostics.hidden = !detail.textContent;
}
const cards = new Map();
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
  image.tabIndex = 0;
  const error = document.createElement("p");
  error.className = "error";
  element.append(name, detail, image, error);
  gallery.append(element);
  const card = { id, element, name, detail, image, error, live: false, keyboard: false, x: 0, y: 0 };
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
  image.addEventListener("pointermove", event => {
    if (!card.live || (card.pointer !== undefined && card.pointer !== event.pointerId)) return;
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
      for (const card of cards.values()) card.live = false;
    } else if (data.type === "status") {
      showStatus(data.phase, data.message);
      refresh.disabled = data.phase !== "live" && data.phase !== "error";
    } else if (data.type === "gallery") {
      reset(); epoch = data.epoch;
      const keep = new Set(data.ids);
      for (const [id, card] of cards) if (!keep.has(id)) { card.element.remove(); cards.delete(id); }
    } else if (data.type === "image" && data.epoch === epoch) {
      const value = data.image;
      const card = cards.get(value.id) || makeCard(value.id);
      card.name.textContent = value.name;
      card.detail.textContent = value.detail + (value.keyboard ? " · Type to interact" : "");
      card.error.textContent = value.error || "";
      card.live = !!value.live && !value.error;
      card.keyboard = value.keyboard;
      if (!card.live) release(card);
      card.width = value.width; card.height = value.height;
      card.image.hidden = !value.data || !!value.error;
      if (value.data) { card.image.src = "data:image/png;base64," + value.data; card.image.alt = value.name; card.image.width = value.width; card.image.height = value.height; }
    }
  };
  socket.onclose = () => {
    reset(); refresh.disabled = true;
    for (const card of cards.values()) card.live = false;
    showStatus("stopped", stopped ? "Preview stopped." : "Disconnected. Reopen Live preview from the Compose pane.");
  };
}
refresh.onclick = () => {
  reset(); refresh.disabled = true;
  showStatus("refreshing", "");
  send({ type: "refresh" });
};
document.querySelector("#stop").onclick = () => {
  reset(); stopped = true; refresh.disabled = true;
  showStatus("cancelling", "");
  send({ type: "stop" });
};
window.addEventListener("blur", reset);
document.addEventListener("visibilitychange", () => { if (document.hidden) reset(); });
window.addEventListener("pagehide", () => { reset(); socket?.close(); });
connect();
