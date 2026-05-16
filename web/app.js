const BUTTON_BITS = {
  up: 0x01,
  down: 0x02,
  left: 0x04,
  right: 0x08,
  a: 0x10,
  b: 0x20,
};

const canvas = document.querySelector("#screen");
const ctx = canvas.getContext("2d", { alpha: false });
const imageData = ctx.createImageData(canvas.width, canvas.height);
const statusEl = document.querySelector("#status");
const romInput = document.querySelector("#rom-file");
const runButton = document.querySelector("#run-button");
const pauseButton = document.querySelector("#pause-button");
const skipButton = document.querySelector("#skip-button");
const romList = document.querySelector("#rom-list");

let rubyReady = false;
let romLoaded = false;
let running = false;
let inputMask = 0;
let lastFrame = 0;
let fpsFrames = 0;
let fpsStarted = performance.now();
let frameSkip = 1;
let runMsTotal = 0;
let packMsTotal = 0;
let drawMsTotal = 0;
let cpuMsTotal = 0;
let vdpMsTotal = 0;
let cpuStepsTotal = 0;

globalThis.smsSetStatus = (message) => {
  statusEl.textContent = message;
};

globalThis.smsRubyReady = () => {
  rubyReady = true;
  statusEl.textContent = "Ruby VM ready. Pick a cached ROM or open a .sms file.";
  refreshRomList();
};

globalThis.smsDrawRgbaFrame = (rgba, frameCount, runMs, packMs, cpuMs, vdpMs, cpuSteps) => {
  const drawStarted = performance.now();
  if (rgba instanceof Uint8Array || rgba instanceof Uint8ClampedArray) {
    imageData.data.set(rgba);
  } else {
    for (let i = 0; i < rgba.length; i += 1) {
      imageData.data[i] = rgba.charCodeAt(i);
    }
  }
  ctx.putImageData(imageData, 0, 0);
  const drawMs = performance.now() - drawStarted;

  fpsFrames += 1;
  runMsTotal += Number(runMs) || 0;
  packMsTotal += Number(packMs) || 0;
  drawMsTotal += drawMs;
  cpuMsTotal += Number(cpuMs) || 0;
  vdpMsTotal += Number(vdpMs) || 0;
  cpuStepsTotal += Number(cpuSteps) || 0;
  const now = performance.now();
  if (now - fpsStarted >= 1000) {
    const fps = (fpsFrames * 1000) / (now - fpsStarted);
    statusEl.textContent = `Frame ${frameCount} | ${fps.toFixed(1)} fps | run ${(runMsTotal / fpsFrames).toFixed(1)} ms | cpu ${(cpuMsTotal / fpsFrames).toFixed(1)} ms | vdp ${(vdpMsTotal / fpsFrames).toFixed(1)} ms | pack ${(packMsTotal / fpsFrames).toFixed(1)} ms | draw ${(drawMsTotal / fpsFrames).toFixed(1)} ms | steps ${Math.round(cpuStepsTotal / fpsFrames)}`;
    fpsFrames = 0;
    runMsTotal = 0;
    packMsTotal = 0;
    drawMsTotal = 0;
    cpuMsTotal = 0;
    vdpMsTotal = 0;
    cpuStepsTotal = 0;
    fpsStarted = now;
  }
};

async function loadRomBytes(bytes, label) {
  if (!rubyReady || typeof globalThis.smsLoadRom !== "function") return;

  running = false;
  statusEl.textContent = `Loading ${label}...`;
  const ok = globalThis.smsLoadRom(bytes);
  romLoaded = Boolean(ok);
  running = romLoaded;
  runButton.disabled = !romLoaded;
  pauseButton.disabled = !romLoaded;
}

romInput.addEventListener("change", async () => {
  const file = romInput.files?.[0];
  if (!file) return;

  const bytes = new Uint8Array(await file.arrayBuffer());
  loadRomBytes(bytes, file.name);
});

runButton.addEventListener("click", () => {
  running = romLoaded;
});

pauseButton.addEventListener("click", () => {
  running = false;
  statusEl.textContent = `Paused at frame ${lastFrame}`;
});

skipButton.addEventListener("click", () => {
  frameSkip = frameSkip === 1 ? 2 : frameSkip === 2 ? 3 : 1;
  skipButton.textContent = `Skip ${frameSkip}`;
});

async function refreshRomList() {
  if (!romList) return;

  let manifest;
  try {
    const response = await fetch("/roms/manifest.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    manifest = await response.json();
  } catch {
    romList.textContent = "No cached ROM manifest. Put .sms files in /home/nichlas/SMSWEB/roms and run scripts/export_sms_web.rb.";
    return;
  }

  const roms = (manifest.roms || []).slice(0, 4);
  if (roms.length === 0) {
    romList.textContent = "No cached ROMs yet. Put .sms files in /home/nichlas/SMSWEB/roms and export again.";
    return;
  }

  romList.replaceChildren();
  roms.forEach((rom, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = `${index + 1}. ${rom.name}`;
    button.addEventListener("click", () => loadCachedRom(rom));
    romList.append(button);
  });

  cacheRoms(roms);
}

async function loadCachedRom(rom) {
  const cache = "caches" in window ? await caches.open("astral-sms-roms-v1") : null;
  const cached = cache ? await cache.match(rom.path) : null;
  const response = cached || await fetch(rom.path);
  if (!response.ok) {
    statusEl.textContent = `Could not load ${rom.name}: HTTP ${response.status}`;
    return;
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  loadRomBytes(bytes, rom.name);
}

async function cacheRoms(roms) {
  if (!("caches" in window)) return;
  try {
    const cache = await caches.open("astral-sms-roms-v1");
    await Promise.all(roms.map((rom) => cache.add(rom.path).catch(() => null)));
  } catch {
    // Cache is an optimization only.
  }
}

function setButton(name, pressed) {
  const bit = BUTTON_BITS[name];
  if (!bit) return;
  inputMask = pressed ? (inputMask | bit) : (inputMask & ~bit);
}

document.querySelectorAll("[data-button]").forEach((button) => {
  const name = button.dataset.button;
  const press = (event) => {
    event.preventDefault();
    button.setPointerCapture?.(event.pointerId);
    setButton(name, true);
  };
  const release = (event) => {
    event.preventDefault();
    setButton(name, false);
  };
  button.addEventListener("pointerdown", press);
  button.addEventListener("pointerup", release);
  button.addEventListener("pointercancel", release);
  button.addEventListener("pointerleave", release);
});

const keyMap = {
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  z: "a",
  Z: "a",
  Enter: "a",
  x: "b",
  X: "b",
};

window.addEventListener("keydown", (event) => {
  const name = keyMap[event.key];
  if (!name) return;
  event.preventDefault();
  setButton(name, true);
});

window.addEventListener("keyup", (event) => {
  const name = keyMap[event.key];
  if (!name) return;
  event.preventDefault();
  setButton(name, false);
});

function loop() {
  if (running && typeof globalThis.smsStepFrame === "function") {
    let ok = true;
    for (let i = 0; i < frameSkip && ok; i += 1) {
      ok = globalThis.smsStepFrame(inputMask);
    }
    running = Boolean(ok);
    lastFrame += frameSkip;
  }
  requestAnimationFrame(loop);
}

requestAnimationFrame(loop);
