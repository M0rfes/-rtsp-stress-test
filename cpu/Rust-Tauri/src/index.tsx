import ReactDOM from 'react-dom/client';
import { App } from './App';
import './styles/index.css';

// Forward browser console messages to the backend WebSocket for diagnostics
(() => {
  let logSocket: WebSocket | null = null;
  const queue: string[] = [];

  const connect = () => {
    try {
      const ws = new WebSocket('ws://127.0.0.1:9999/control');
      ws.onopen = () => {
        logSocket = ws;
        while (queue.length > 0) {
          const item = queue.shift();
          if (item) ws.send(item);
        }
      };
      ws.onclose = () => {
        logSocket = null;
        setTimeout(connect, 2000);
      };
      ws.onerror = () => {
        logSocket = null;
      };
    } catch {
      // Ignore
    }
  };

  connect();

  const sendLog = (level: string, ...args: any[]) => {
    const message = args
      .map((a) => (typeof a === 'object' ? JSON.stringify(a) : String(a)))
      .join(' ');
    const payload = JSON.stringify({ type: 'log', level, message });
    if (logSocket && logSocket.readyState === WebSocket.OPEN) {
      logSocket.send(payload);
    } else {
      if (queue.length < 50) queue.push(payload);
    }
  };

  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;

  console.log = (...args) => {
    origLog.apply(console, args);
    sendLog('INFO', ...args);
  };
  console.warn = (...args) => {
    origWarn.apply(console, args);
    sendLog('WARN', ...args);
  };
  console.error = (...args) => {
    origError.apply(console, args);
    sendLog('ERROR', ...args);
  };

  window.addEventListener('error', (e) => {
    console.error(`Uncaught exception: ${e.message} at ${e.filename}:${e.lineno}`);
  });
  window.addEventListener('unhandledrejection', (e) => {
    console.error(`Unhandled promise rejection: ${e.reason}`);
  });

})();

const rootElement = document.getElementById('root');
if (rootElement) {
  const root = ReactDOM.createRoot(rootElement);
  root.render(<App />);
}
