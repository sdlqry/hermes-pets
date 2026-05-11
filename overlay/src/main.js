const { app, BrowserWindow, dialog, ipcMain, screen } = require('electron');
const WebSocket = require('ws');
const path = require('path');
const fs = require('fs');
const os = require('os');

// ─── Command-line argument parsing ──────────────────────────────────
function parseArgs() {
  const args = process.argv.slice(2);
  const config = {};
  for (const arg of args) {
    if (arg.startsWith('--hermes-pet-bridge-port=')) {
      config.bridgePort = parseInt(arg.split('=')[1], 10);
    } else if (arg.startsWith('--hermes-pet-dir=')) {
      config.stateDir = arg.split('=').slice(1).join('=');
    } else if (arg.startsWith('--hermes-pet-platform=')) {
      config.platform = arg.split('=')[1];
    }
  }
  return config;
}

const parsedArgs = parseArgs();

// ─── Cross-platform state / user-data directory ─────────────────────
function getUserDataDir() {
  const platform = parsedArgs.platform || process.platform;
  switch (platform) {
    case 'linux':
      return parsedArgs.stateDir
        || path.join(os.homedir(), '.hermes_pet', 'electron-user-data');
    case 'win32':
      return parsedArgs.stateDir
        || path.join(process.env.LOCALAPPDATA || os.homedir(), 'HermesAgent', 'pet-overlay-electron', 'user-data');
    case 'darwin':
      return parsedArgs.stateDir
        || path.join(os.homedir(), 'Library', 'Application Support', 'hermes-pet-electron');
    default:
      return parsedArgs.stateDir
        || path.join(os.homedir(), '.hermes_pet', 'electron-user-data');
  }
}

app.setPath('userData', getUserDataDir());
app.setName('Hermes Pets Overlay');

// ─── Single instance lock (cross-platform) ──────────────────────────
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  console.log('[pet-overlay] Another instance is already running — quitting.');
  app.quit();
} else {
  app.on('second-instance', () => {
    bringOverlayToFront('second-instance');
  });
}

// ─── Globals ─────────────────────────────────────────────────────────
let win = null;
let wsClient = null;
let reconnectTimer = null;
let reconnectDelayMs = 1000;
let lastConnectionLogMs = 0;
let bridgeConnected = null;
let dragState = null;
let lastSpriteRect = { left: 60, top: 164, width: 160, height: 160 };

const MIN_RECONNECT_DELAY_MS = 1000;
const MAX_RECONNECT_DELAY_MS = 30000;
const CONNECTION_LOG_INTERVAL_MS = 30000;
const ALWAYS_ON_TOP_LEVEL = process.env.HERMES_PET_ALWAYS_ON_TOP_LEVEL || 'screen-saver';
const WINDOW_SIZE = { width: 280, height: 340 };
const PET_TITLE = `Hermes Pets Overlay [${parsedArgs.platform || process.platform} ${process.pid}]`;
const PET_SPECIES = process.env.HERMES_PET_SPECIES || 'cat';
const DEBUG_EVENTS = process.env.HERMES_PET_DEBUG_EVENTS === '1';
const DEBUG_ANIMATION = process.env.HERMES_PET_DEBUG_ANIMATION === '1';
const DEBUG_DRAG = process.env.HERMES_PET_DEBUG_DRAG === '1';
const VERIFY_FILE = process.env.HERMES_PET_OVERLAY_VERIFY_FILE || '';
const CUSTOM_SPRITE_DIR = path.join(os.homedir(), '.hermes');
const CUSTOM_SPRITE_PATH = path.join(CUSTOM_SPRITE_DIR, 'pet_custom.png');

const positionFilePath = () => process.env.HERMES_PET_POSITION_FILE || path.join(os.homedir(), '.hermes', 'pet_position.json');

// ─── Debug & verification helpers (merged from main.windows.js) ─────
function debugEvent(message, ...args) {
  if (DEBUG_EVENTS) console.log(`[pet-overlay/events] ${message}`, ...args);
}

function verifyEvent(type, payload = {}) {
  if (!VERIFY_FILE) return;
  try {
    fs.mkdirSync(path.dirname(VERIFY_FILE), { recursive: true });
    fs.appendFileSync(
      VERIFY_FILE,
      JSON.stringify({ type, pid: process.pid, at: new Date().toISOString(), ...payload }) + '\n',
      'utf8',
    );
  } catch (e) {
    if (DEBUG_EVENTS) console.warn(`[pet-overlay/events] verify write failed: ${e.message}`);
  }
}

function verifyRendererSnapshot(reason) {
  if (!VERIFY_FILE || !win || win.webContents.isDestroyed()) return;
  win.webContents.executeJavaScript(`
    (() => {
      const smoke = window.__hermesPetRendererSmoke;
      if (!smoke) return null;
      const state = smoke.getState();
      return {
        species: state.species || '',
        customPet: state.custom_pet && state.custom_pet.name || '',
        animation: smoke.getCurrentAnimation(),
        trayVisible: smoke.isTrayVisible(),
        trayAttention: smoke.isTrayAttention(),
        bubbleText: smoke.getBubbleText(),
        recentTypes: smoke.getRecentEvents().map((event) => event.type),
      };
    })()
  `).then((snapshot) => {
    if (snapshot) verifyEvent('renderer-snapshot', { reason, snapshot });
  }).catch((e) => {
    verifyEvent('renderer-snapshot-error', { reason, error: e.message });
  });
}

// ─── Window helpers ─────────────────────────────────────────────────
function bringOverlayToFront(reason) {
  if (!win) return;
  try {
    if (win.isMinimized()) win.restore();
    if (!win.isVisible()) win.showInactive();
    reassertOverlayOnTop(reason);
  } catch (e) {
    console.warn(`[pet-overlay] failed to show existing overlay after ${reason}: ${e.message}`);
  }
}

function defaultWindowPosition() {
  const area = screen.getPrimaryDisplay().workArea || screen.getPrimaryDisplay().bounds;
  return { x: area.x + area.width - 200, y: area.y + area.height - 220 };
}

function clampToWorkArea(x, y, width = WINDOW_SIZE.width, height = WINDOW_SIZE.height) {
  const area = screen.getPrimaryDisplay().workArea || screen.getPrimaryDisplay().bounds;
  const maxX = area.x + Math.max(0, area.width - width);
  const maxY = area.y + Math.max(0, area.height - height);
  return { x: Math.min(Math.max(Number.isFinite(x) ? x : area.x, area.x), maxX), y: Math.min(Math.max(Number.isFinite(y) ? y : area.y, area.y), maxY) };
}

function sanitizeSpriteRect(rect, windowWidth = WINDOW_SIZE.width, windowHeight = WINDOW_SIZE.height) {
  if (!rect || typeof rect !== 'object') return null;
  const left = Number(rect.left), top = Number(rect.top), width = Number(rect.width), height = Number(rect.height);
  if (![left, top, width, height].every(Number.isFinite) || width <= 0 || height <= 0) return null;
  const normalizedLeft = Math.min(Math.max(Math.round(left), 0), Math.max(0, windowWidth - 1));
  const normalizedTop = Math.min(Math.max(Math.round(top), 0), Math.max(0, windowHeight - 1));
  return { left: normalizedLeft, top: normalizedTop, width: Math.min(Math.round(width), Math.max(1, windowWidth - normalizedLeft)), height: Math.min(Math.round(height), Math.max(1, windowHeight - normalizedTop)) };
}

function clampWindowToVisibleBounds(x, y, spriteRect = lastSpriteRect, windowWidth = WINDOW_SIZE.width, windowHeight = WINDOW_SIZE.height) {
  const rect = sanitizeSpriteRect(spriteRect, windowWidth, windowHeight);
  if (!rect) return clampToWorkArea(x, y, windowWidth, windowHeight);
  const area = screen.getPrimaryDisplay().workArea || screen.getPrimaryDisplay().bounds;
  const minX = area.x - rect.left;
  const minY = area.y - rect.top;
  const maxX = area.x + area.width - rect.left - rect.width;
  const maxY = area.y + area.height - rect.top - rect.height;
  return { x: Math.min(Math.max(Number.isFinite(x) ? x : minX, minX), maxX), y: Math.min(Math.max(Number.isFinite(y) ? y : minY, minY), maxY) };
}

function loadPosition() {
  try {
    const posFile = positionFilePath();
    if (fs.existsSync(posFile)) {
      const data = JSON.parse(fs.readFileSync(posFile, 'utf8'));
      return clampToWorkArea(data.x, data.y);
    }
  } catch (_) {}
  return defaultWindowPosition();
}

function savePosition(x, y) {
  try {
    const posFile = positionFilePath();
    fs.mkdirSync(path.dirname(posFile), { recursive: true });
    fs.writeFileSync(posFile, JSON.stringify({ x, y }, null, 2));
  } catch (e) {
    console.warn(`[pet-overlay] failed to save position: ${e.message}`);
  }
}

function persistWindowPosition() {
  if (!win) return;
  const bounds = win.getBounds();
  const clamped = clampWindowToVisibleBounds(bounds.x, bounds.y, lastSpriteRect, bounds.width, bounds.height);
  if (bounds.x !== clamped.x || bounds.y !== clamped.y) win.setBounds({ ...bounds, ...clamped });
  savePosition(clamped.x, clamped.y);
  win.webContents.send('position-changed', clamped.x, clamped.y);
}

function reassertOverlayOnTop(reason) {
  if (!win) return;
  try {
    win.setAlwaysOnTop(true, ALWAYS_ON_TOP_LEVEL);
    win.moveTop();
    console.log(`[pet-overlay] reasserted always-on-top (${ALWAYS_ON_TOP_LEVEL}) after ${reason}`);
  } catch (e) {
    console.warn(`[pet-overlay] failed to reassert always-on-top after ${reason}: ${e.message}`);
  }
}

function notifyBridgeConnected(connected) {
  if (bridgeConnected === connected) return;
  bridgeConnected = connected;
  debugEvent(`bridge connected state=${connected}`);
  verifyEvent('bridge-connected', { connected });
  setTimeout(() => verifyRendererSnapshot(`bridge-connected:${connected}`), 250);
  if (win) win.webContents.send('bridge-connected', connected);
}

function emitCustomSprite(pathOrUrl) {
  if (win) win.webContents.send('custom-sprite-set', pathOrUrl);
}

// ─── WebSocket bridge connection ────────────────────────────────────
function scheduleReconnect(url) {
  if (app.isQuitting) return;
  const delay = reconnectDelayMs;
  reconnectDelayMs = Math.min(reconnectDelayMs * 2, MAX_RECONNECT_DELAY_MS);
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(connectBridge, delay);
  reconnectTimer.unref?.();
  const now = Date.now();
  if (now - lastConnectionLogMs >= CONNECTION_LOG_INTERVAL_MS) {
    lastConnectionLogMs = now;
    console.log(`[pet-overlay] waiting for pet bridge at ${url}; retrying in ${Math.round(delay / 1000)}s`);
  }
}

function connectBridge() {
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  // Prefer parsedArgs.bridgePort from CLI, fall back to env var, then default
  const bridgePort = parsedArgs.bridgePort || process.env.HERMES_PET_PORT || 17473;
  const url = process.env.HERMES_PET_WS_URL || `ws://127.0.0.1:${bridgePort}`;
  notifyBridgeConnected(false);
  wsClient = new WebSocket(url);

  wsClient.on('open', () => {
    reconnectDelayMs = MIN_RECONNECT_DELAY_MS;
    lastConnectionLogMs = 0;
    console.log(`[pet-overlay] connected to bridge at ${url}`);
    debugEvent(`bridge open url=${url}`);
    notifyBridgeConnected(true);
  });

  wsClient.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw);
      debugEvent(`bridge message type=${msg?.type || 'unknown'}`);
      if (win) {
        win.webContents.send('pet-event', msg);
        verifyEvent('pet-event', {
          eventType: msg?.type || 'unknown',
          severity: msg?.severity || '',
          hasCustomPet: Boolean(msg?.custom_pet),
        });
        setTimeout(() => verifyRendererSnapshot(`pet-event:${msg?.type || 'unknown'}`), 250);
      } else {
        debugEvent(`dropped renderer event type=${msg?.type || 'unknown'} reason=no-window`);
      }
    } catch (_) {
      console.error('[pet-overlay] bad bridge message');
    }
  });

  wsClient.on('close', () => {
    debugEvent(`bridge close url=${url}`);
    notifyBridgeConnected(false);
    scheduleReconnect(url);
  });

  wsClient.on('error', (err) => {
    const now = Date.now();
    if (now - lastConnectionLogMs < CONNECTION_LOG_INTERVAL_MS) return;
    lastConnectionLogMs = now;
    console.warn(`[pet-overlay] Hermes bridge unavailable at ${url}: ${err.message}`);
  });
}

// ─── Window creation ────────────────────────────────────────────────
function createWindow() {
  if (win) return;
  const pos = loadPosition();
  const focusable = process.env.HERMES_PET_FOCUSABLE === '1';
  const clickThrough = process.env.HERMES_PET_CLICK_THROUGH === '1';
  const showUpload = process.env.HERMES_PET_SHOW_UPLOAD === '1' ? '1' : '0';
  const currentPlatform = parsedArgs.platform || process.platform;
  console.log(`[pet-overlay] platform ${currentPlatform}`);
  console.log(`[pet-overlay] always-on-top level ${ALWAYS_ON_TOP_LEVEL}`);
  if (clickThrough) console.log('[pet-overlay] click-through enabled');

  const windowOptions = {
    ...WINDOW_SIZE,
    x: pos.x,
    y: pos.y,
    title: PET_TITLE,
    transparent: true,
    frame: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    focusable,
    hasShadow: false,
    resizable: false,
    backgroundColor: '#00000000',
    show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  };

  // Linux X11: set window type to dock so it doesn't appear in taskbar
  // and behaves better with different window managers
  if (currentPlatform === 'linux') {
    windowOptions.type = 'dock';
  }

  win = new BrowserWindow(windowOptions);

  win.loadFile(path.join(__dirname, 'renderer.html'), {
    query: { species: PET_SPECIES, showUpload, debugEvents: DEBUG_EVENTS ? '1' : '0', debugAnimation: DEBUG_ANIMATION ? '1' : '0', debugDrag: DEBUG_DRAG ? '1' : '0' },
  });
  notifyBridgeConnected(false);

  win.webContents.once('did-finish-load', () => {
    const classes = ['overlay-mode'];
    if (clickThrough) classes.push('click-through-mode');
    if (process.env.HERMES_PET_DEBUG_SPRITE === '1') classes.push('debug-sprite');
    win.webContents.executeJavaScript(`document.body.classList.add(${classes.map((c) => JSON.stringify(c)).join(',')})`).catch(() => {});
    verifyEvent('renderer-loaded');
    setTimeout(() => verifyRendererSnapshot('renderer-loaded'), 250);
    if (fs.existsSync(CUSTOM_SPRITE_PATH)) emitCustomSprite(CUSTOM_SPRITE_PATH);
  });

  win.once('ready-to-show', () => {
    console.log(`[pet-overlay] final window bounds ${JSON.stringify(win.getBounds())}`);
    win.showInactive();
    reassertOverlayOnTop('ready-to-show');
    if (clickThrough) win.setIgnoreMouseEvents(true, { forward: true });
    verifyEvent('ready-to-show', { bounds: win.getBounds() });
  });

  let moveTimeout = null;
  win.on('move', () => {
    if (dragState) return;
    if (moveTimeout) clearTimeout(moveTimeout);
    moveTimeout = setTimeout(persistWindowPosition, 500);
  });
  win.on('blur', () => reassertOverlayOnTop('blur'));
  win.on('show', () => reassertOverlayOnTop('show'));
  win.on('restore', () => reassertOverlayOnTop('restore'));
  win.on('closed', () => { dragState = null; win = null; });
}

// ─── App lifecycle ──────────────────────────────────────────────────
if (gotTheLock) {
  app.whenReady().then(() => { createWindow(); connectBridge(); });
}
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
app.on('window-all-closed', () => {
  app.isQuitting = true;
  if (wsClient) wsClient.close();
  if (reconnectTimer) clearTimeout(reconnectTimer);
  app.quit();
});

// ─── IPC handlers ───────────────────────────────────────────────────
ipcMain.on('minimize-pet', () => { if (win) win.setSize(80, 80); });
ipcMain.on('restore-pet', () => { if (win) win.setSize(WINDOW_SIZE.width, WINDOW_SIZE.height); });
ipcMain.on('hide-pet', () => { if (win) win.hide(); });
ipcMain.on('show-pet', () => { if (win) { win.showInactive(); reassertOverlayOnTop('show-pet'); } });

ipcMain.on('pet-drag-start', (_, point) => {
  if (!win || process.env.HERMES_PET_CLICK_THROUGH === '1') return;
  const startX = Number(point?.screenX), startY = Number(point?.screenY);
  if (!Number.isFinite(startX) || !Number.isFinite(startY) || (startX === 0 && startY === 0)) return;
  const bounds = win.getBounds();
  lastSpriteRect = sanitizeSpriteRect(point?.spriteRect, bounds.width, bounds.height) || lastSpriteRect;
  dragState = { startX, startY, bounds, spriteRect: lastSpriteRect };
  if (DEBUG_DRAG) console.log(`[pet-overlay/drag] start ${JSON.stringify({ x: bounds.x, y: bounds.y })}`);
});

ipcMain.on('pet-drag-move', (_, point) => {
  if (!win || !dragState || process.env.HERMES_PET_CLICK_THROUGH === '1') return;
  const screenX = Number(point?.screenX), screenY = Number(point?.screenY);
  if (!Number.isFinite(screenX) || !Number.isFinite(screenY) || (screenX === 0 && screenY === 0)) return;
  const nextX = dragState.bounds.x + Math.round(screenX - dragState.startX);
  const nextY = dragState.bounds.y + Math.round(screenY - dragState.startY);
  const clamped = clampWindowToVisibleBounds(nextX, nextY, dragState.spriteRect, dragState.bounds.width, dragState.bounds.height);
  win.setPosition(clamped.x, clamped.y, false);
});

ipcMain.on('pet-drag-end', () => {
  if (!win || !dragState) return;
  dragState = null;
  persistWindowPosition();
  reassertOverlayOnTop('drag-end');
  if (DEBUG_DRAG) console.log(`[pet-overlay/drag] end ${JSON.stringify(win.getBounds())}`);
});

ipcMain.on('save-custom-sprite', (_, srcPath) => {
  try {
    fs.mkdirSync(CUSTOM_SPRITE_DIR, { recursive: true });
    fs.copyFileSync(srcPath, CUSTOM_SPRITE_PATH);
    emitCustomSprite(CUSTOM_SPRITE_PATH);
  } catch (e) {
    console.error('[pet-overlay] failed to save custom sprite:', e.message);
  }
});

ipcMain.on('pick-custom-sprite', async () => {
  if (!win) return;
  try {
    const result = await dialog.showOpenDialog(win, {
      title: 'Choose a pet sprite',
      filters: [{ name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'] }],
      properties: ['openFile'],
    });
    if (!result.canceled && result.filePaths.length > 0) {
      fs.mkdirSync(CUSTOM_SPRITE_DIR, { recursive: true });
      fs.copyFileSync(result.filePaths[0], CUSTOM_SPRITE_PATH);
      emitCustomSprite(CUSTOM_SPRITE_PATH);
    }
  } catch (e) {
    console.error('[pet-overlay] dialog failed:', e.message);
  }
});

// Load animation manifest from disk (renderer can't fetch file:// URLs due to context isolation)
const MANIFEST_PATH = path.join(__dirname, '..', 'assets', 'manifest.json');
let _cachedManifest = null;
ipcMain.handle('get-pet-manifest', async () => {
  if (_cachedManifest) return _cachedManifest;
  try {
    _cachedManifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
    return _cachedManifest;
  } catch (e) {
    console.error('[pet-overlay] failed to load manifest:', e.message);
    return null;
  }
});
