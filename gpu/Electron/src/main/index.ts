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
// "The Electron launch script must include Chromium flags to force VA-API translation on Nvidia:
// --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiOnNvidiaGPUs, --use-gl=egl, and --disable-software-rasterizer."

// Hardware acceleration is strictly ENABLED for GPU zero-copy benchmark:
app.commandLine.appendSwitch('ignore-gpu-blocklist');
app.commandLine.appendSwitch('enable-gpu-rasterization');
app.commandLine.appendSwitch('enable-zero-copy');

if (process.platform === 'linux') {
  app.commandLine.appendSwitch('enable-features', 'VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiOnNvidiaGPUs');
  app.commandLine.appendSwitch('use-gl', 'egl');
  app.commandLine.appendSwitch('disable-software-rasterizer');
  app.commandLine.appendSwitch('no-sandbox');
  app.commandLine.appendSwitch('disable-dev-shm-usage');
}

async function createWindow(): Promise<BrowserWindow> {
  const win = new BrowserWindow({
    width: 2560,
    height: 1440,
    minWidth: 1280,
    minHeight: 720,
    title: `RTSP 30-Stream Stress Test (Electron GPU Zero-Copy Benchmark) [PID: ${process.pid}]`,
    backgroundColor: '#0f172a',
    // Do NOT set show: false in headless Linux per BENCHMARK_FINDINGS.md
    show: true,
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
  console.log(`[Main] Initializing RTSP 30-Stream GPU Zero-Copy Benchmark...`);
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
