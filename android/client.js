"use strict";
const screen = document.querySelector("#screen");
const status = document.querySelector("#status");
const text = document.querySelector("#text");
const controls = [...document.querySelectorAll("[data-key], #text, #send-text")];
const keys = { Backspace: "DEL", Delete: "FORWARD_DEL", Enter: "ENTER", Tab: "TAB", ArrowUp: "DPAD_UP", ArrowDown: "DPAD_DOWN", ArrowLeft: "DPAD_LEFT", ArrowRight: "DPAD_RIGHT", Home: "MOVE_HOME", End: "MOVE_END", PageUp: "PAGE_UP", PageDown: "PAGE_DOWN" };
const socket = new WebSocket(new URL("./events", location.href).href.replace(/^http/, "ws"));
socket.binaryType = "blob";
let pointer;
let objectURL;
let connected = false;
let wheelAt = 0;
let lastError = "";
function send(value) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(value));
}
function position(event) {
  const box = screen.getBoundingClientRect();
  return {
    x: Math.max(0, Math.min(screen.naturalWidth - 1, Math.round((event.clientX - box.left) * screen.naturalWidth / box.width))),
    y: Math.max(0, Math.min(screen.naturalHeight - 1, Math.round((event.clientY - box.top) * screen.naturalHeight / box.height))),
  };
}
function cancel() {
  if (pointer && screen.hasPointerCapture(pointer.id)) screen.releasePointerCapture(pointer.id);
  pointer = undefined;
}
function gesture(start, end, duration) {
  if (!connected) return;
  send({ type: "gesture", ...start, endX: end.x, endY: end.y, duration: Math.min(1500, Math.max(0, Math.round(duration))), width: screen.naturalWidth, height: screen.naturalHeight });
}
socket.onopen = () => send({ type: "visibility", visible: !document.hidden });
socket.onmessage = event => {
  if (typeof event.data === "string") {
    const value = JSON.parse(event.data);
    if (value.type === "status") {
      status.textContent = value.message;
      status.dataset.error = String(!!value.error);
      lastError = value.error ? value.message : "";
    }
    return;
  }
  const next = URL.createObjectURL(event.data);
  screen.onload = () => {
    if (objectURL) URL.revokeObjectURL(objectURL);
    objectURL = next;
    screen.hidden = false;
    connected = true;
    for (const control of controls) control.disabled = false;
    send({ type: "ack" });
  };
  screen.onerror = () => {
    URL.revokeObjectURL(next);
    status.textContent = "Cannot decode emulator screenshot. Reopen View.";
    socket.close();
  };
  screen.src = next;
};
socket.onclose = () => {
  connected = false;
  cancel();
  for (const control of controls) control.disabled = true;
  status.textContent = lastError || "Disconnected. The emulator is still running. Reopen View to reconnect.";
};
screen.addEventListener("pointerdown", event => {
  if (!connected || event.button !== 0 || pointer) return;
  event.preventDefault();
  screen.focus({ preventScroll: true });
  pointer = { id: event.pointerId, start: position(event), time: performance.now() };
  screen.setPointerCapture(event.pointerId);
});
screen.addEventListener("pointerup", event => {
  if (!pointer || event.pointerId !== pointer.id) return;
  const down = pointer;
  const end = position(event);
  // Small hand movements remain taps rather than accidental swipes.
  if (Math.hypot(end.x - down.start.x, end.y - down.start.y) < 8) Object.assign(end, down.start);
  gesture(down.start, end, performance.now() - down.time);
  cancel();
});
screen.addEventListener("pointercancel", cancel);
screen.addEventListener("lostpointercapture", () => { pointer = undefined; });
screen.addEventListener("blur", cancel);
screen.addEventListener("wheel", event => {
  if (!connected) return;
  event.preventDefault();
  if (pointer || performance.now() - wheelAt < 300) return;
  wheelAt = performance.now();
  const start = position(event);
  const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? screen.naturalHeight : 1;
  gesture(start, {
    x: Math.max(0, Math.min(screen.naturalWidth - 1, Math.round(start.x - Math.max(-screen.naturalWidth / 2, Math.min(screen.naturalWidth / 2, event.deltaX * unit))))),
    y: Math.max(0, Math.min(screen.naturalHeight - 1, Math.round(start.y - Math.max(-screen.naturalHeight / 2, Math.min(screen.naturalHeight / 2, event.deltaY * unit))))),
  }, 250);
}, { passive: false });
screen.addEventListener("keydown", event => {
  if (event.key === "Escape") { event.preventDefault(); cancel(); screen.blur(); return; }
  if (!connected || event.isComposing || event.ctrlKey || event.altKey || event.metaKey) return;
  if (Object.hasOwn(keys, event.key)) { event.preventDefault(); send({ type: "key", key: keys[event.key] }); }
  else if (/^[\x20-\x7e]$/.test(event.key)) { event.preventDefault(); send({ type: "text", text: event.key }); }
});
for (const button of document.querySelectorAll("[data-key]")) button.onclick = () => send({ type: "key", key: button.dataset.key });
document.querySelector("#text-form").onsubmit = event => {
  event.preventDefault();
  if (connected && text.value) send({ type: "text", text: text.value });
};
document.querySelector("#close").onclick = () => { cancel(); send({ type: "close" }); };
window.addEventListener("blur", cancel);
document.addEventListener("visibilitychange", () => { cancel(); send({ type: "visibility", visible: !document.hidden }); });
window.addEventListener("pagehide", () => { cancel(); socket.close(); if (objectURL) URL.revokeObjectURL(objectURL); });
