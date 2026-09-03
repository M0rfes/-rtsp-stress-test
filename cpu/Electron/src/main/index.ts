import { app, BrowserWindow } from 'electron';
import path from 'path';
import { config } from './config';
import { StreamPool } from './rtsp-demuxer';
import { VideoWebSocketServer } from './ws-server';
import { telemetry } from './telemetry';

let mainWindow: BrowserWindow | null = null;
let streamPool: StreamPool | null = null;
let wsServer: VideoWebSocketServer | null = null;

// Architecture Constraint:
// "Because no VA-API hardware flags are passed to Chromium, it will natively fall back to its internal software decoder (libvpx/ffmpeg)."
// We do NOT pass --enable-features=VaapiVideoDecoder or --use-gl=egl
// Disable hardware acceleration for video decoding to guarantee pure CPU software decode:
app.commandLine.appendSwitch('disable-accelerated-video-decode');

if (process.platform === 'linux') {
  app.commandLine.appendSwitch('no-sandbox');
  app.commandLine.appendSwitch('disable-dev-shm-usage');
}

async function createWindow(): Promise<BrowserWindow> {
  const win = new BrowserWindow({
    width: 2560,
    height: 1440,
    minWidth: 1280,
    minHeight: 720,
    title: `RTSP 30-Stream Stress Test (Electron CPU Benchmark) [PID: ${process.pid}]`,
    backgroundColor: '#0f172a',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: false,
      webSecurity: false, // Allows connecting to local ws easily
    },
  });

  win.webContents.on('console-message', (e, level, msg, line, sourceId) => {
    console.log(`[Renderer Console] ${msg}`);
  });

  if (process.env.VITE_DEV_SERVER_URL) {
    await win.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    const indexPath = path.join(__dirname, '../renderer/index.html');
    await win.loadFile(indexPath);
  }

  win.on('closed', () => {
    mainWindow = null;
  });

  return win;
}

async function bootstrap() {
  console.log(`[Main] Initializing RTSP 30-Stream CPU Benchmark...`);
  console.log(`[Main] Config: Streams=${config.streamCount}, Mode=${config.hardwareMode}, RTSP=${config.rtspUrl}`);
  console.log(`[Main] Telemetry Log Path: ${telemetry.getLogPath()}`);

  // Initialize and start RTSP demuxers (demuxing only, NO decode in Node.js)
  streamPool = new StreamPool(config.streamCount);
  streamPool.startAll();

  // Initialize and start WebSocket server for streaming compressed NAL units to React
  wsServer = new VideoWebSocketServer(streamPool);
  await wsServer.listen();

  // Create UI Window
  mainWindow = await createWindow();
}

app.whenReady().then(bootstrap);

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});

app.on('before-quit', () => {
  console.log('[Main] Application shutting down. Cleaning up resources...');
  if (telemetry) {
    telemetry.flushToDisk();
  }
  if (streamPool) {
    streamPool.stopAll();
  }
  if (wsServer) {
    wsServer.close();
  }
});
