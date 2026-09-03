import React from 'react';

export interface TelemetrySummary {
  machineId: string;
  framework: string;
  hardwareMode: string;
  activeStreams: number;
  currentWindowSec: number;
  acceptable25to30: number;
  acceptable20to24: number;
  unacceptable10to19: number;
  unacceptable5to9: number;
  unacceptableUnder5: number;
  avgFps: number;
  logPath: string;
}

interface StatsBarProps {
  stats: TelemetrySummary;
}

export const StatsBar: React.FC<StatsBarProps> = ({ stats }) => {
  const windowProgressPercent = Math.min(100, Math.round((stats.currentWindowSec / 60) * 100));
  const acceptableTotal = stats.acceptable25to30 + stats.acceptable20to24;
  const unacceptableTotal = stats.unacceptable10to19 + stats.unacceptable5to9 + stats.unacceptableUnder5;
  const totalStreamSeconds = acceptableTotal + unacceptableTotal;
  const healthPercent = totalStreamSeconds > 0 ? Math.round((acceptableTotal / totalStreamSeconds) * 100) : 100;

  return (
    <div className="stats-bar">
      <div className="stats-title-group">
        <span className="benchmark-badge">RUST TAURI</span>
        <span className="hardware-badge-gpu">GPU ZERO-COPY DECODE</span>
        <span className="stats-title">30-Camera 1440p RTSP Stress Grid</span>
      </div>

      <div className="metrics-row">
        <div className="metric-card">
          <span className="metric-label">Active Feeds</span>
          <span className="metric-value">{stats.activeStreams} / 30</span>
        </div>

        <div className="metric-card">
          <span className="metric-label">Avg FPS</span>
          <span className={`metric-value ${stats.avgFps >= 24 ? 'green' : stats.avgFps >= 20 ? 'yellow' : 'red'}`}>
            {stats.avgFps.toFixed(1)}
          </span>
        </div>

        <div className="metric-card">
          <span className="metric-label">Acceptable (≥20fps)</span>
          <span className="metric-value green">{acceptableTotal}s</span>
        </div>

        <div className="metric-card">
          <span className="metric-label">Unacceptable (&lt;20fps)</span>
          <span className={`metric-value ${unacceptableTotal === 0 ? 'green' : 'red'}`}>
            {unacceptableTotal}s
          </span>
        </div>

        <div className="metric-card">
          <span className="metric-label">Health</span>
          <span className={`metric-value ${healthPercent >= 98 ? 'green' : healthPercent >= 90 ? 'yellow' : 'red'}`}>
            {healthPercent}%
          </span>
        </div>

        <div className="countdown-bar-container" title={`60s Rolling Window: ${stats.currentWindowSec}/60s`}>
          <div className="countdown-bar">
            <div className="countdown-bar-fill" style={{ width: `${windowProgressPercent}%` }} />
          </div>
          <span className="countdown-text">{stats.currentWindowSec}s / 60s</span>
        </div>
      </div>
    </div>
  );
};
