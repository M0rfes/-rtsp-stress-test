#pragma once

#include <QString>
#include <string>

struct AppConfig {
    std::string rtspUrl = "rtsp://127.0.0.1:8554/live";
    int streamCount = 30;
    std::string logPath = "/var/log/benchmark/fps_metrics.log";
    std::string machineId = "c7i-8xlarge-node-1";
    std::string hwAccel = "auto";
    int targetFps = 25;
    int renderFps = 30; // UI display refresh rate

    static AppConfig loadFromArgsAndEnv(int argc, char* argv[]);
    static std::string resolveLogPath(const std::string& preferredPath);
};
