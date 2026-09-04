import { contextBridge } from 'electron';

contextBridge.exposeInMainWorld('electronBenchmark', {
  wsPort: parseInt(process.env.WS_PORT || '9999', 10),
  streamCount: parseInt(process.env.STREAM_COUNT || '30', 10),
  platform: process.platform,
  getPid: () => process.pid,
});
