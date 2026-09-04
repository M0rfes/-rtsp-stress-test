#include "telemetry.h"

#include <QDateTime>
#include <QJsonObject>
#include <QJsonDocument>
#include <QFile>
#include <QDir>
#include <QFileInfo>
#include <iostream>

TelemetryManager::TelemetryManager(const std::string& logPath, const std::string& machineId, int activeStreams)
    : m_logPath(logPath)
    , m_machineId(machineId)
    , m_activeStreams(activeStreams)
{
}

void TelemetryManager::tick(const std::vector<StreamWorker*>& workers) {
    std::lock_guard<std::mutex> lock(m_mutex);

    size_t count = workers.size();
    if (m_prevFrames.size() != count) {
        m_prevFrames.resize(count, 0);
    }

    float totalFps = 0.0f;
    int liveStreams = 0;

    for (size_t i = 0; i < count; ++i) {
        if (!workers[i] || !workers[i]->isConnected()) {
            // Phase 2 Rule: Do NOT count frames or log bucket seconds for dropped / inactive streams
            if (workers[i]) {
                m_prevFrames[i] = workers[i]->paintedFrames();
                workers[i]->setCurrentFps(0.0f);
            }
            continue;
        }

        liveStreams++;
        uint64_t current = workers[i]->paintedFrames();
        if (current == 0) {
            current = workers[i]->decodedFrames();
        }

        uint64_t prev = m_prevFrames[i];
        uint32_t deltaFps = (current >= prev) ? static_cast<uint32_t>(current - prev) : static_cast<uint32_t>(current);
        m_prevFrames[i] = current;

        workers[i]->setCurrentFps(static_cast<float>(deltaFps));
        totalFps += static_cast<float>(deltaFps);

        // Categorize active streams into performance buckets
        if (deltaFps >= 25) {
            m_windowBuckets.fps_25_to_30++;
        } else if (deltaFps >= 20) {
            m_windowBuckets.fps_20_to_24++;
        } else if (deltaFps >= 10) {
            m_windowBuckets.fps_10_to_19++;
        } else if (deltaFps >= 5) {
            m_windowBuckets.fps_5_to_9++;
        } else {
            m_windowBuckets.fps_under_5++;
        }
    }

    m_aggregateFps = totalFps;
    m_liveStreams = liveStreams;
    m_accumulatedActiveStreams += liveStreams;
    m_activeStreamsSampleCount++;
    m_secondsInWindow++;

    // Check if 60-second window is reached
    if (m_secondsInWindow >= 60) {
        flushWindow();
        m_windowBuckets.reset();
        m_accumulatedActiveStreams = 0;
        m_activeStreamsSampleCount = 0;
        m_secondsInWindow = 0;
    }
}

void TelemetryManager::flushWindow() {
    QString timestamp = QDateTime::currentDateTimeUtc().toString("yyyy-MM-ddTHH:mm:ss'Z'");
    int avgActiveStreams = m_activeStreamsSampleCount > 0 
        ? static_cast<int>(std::round(static_cast<double>(m_accumulatedActiveStreams) / m_activeStreamsSampleCount))
        : m_liveStreams;

    QJsonObject acceptable;
    acceptable["25_to_30_fps"] = static_cast<int>(m_windowBuckets.fps_25_to_30);
    acceptable["20_to_24_fps"] = static_cast<int>(m_windowBuckets.fps_20_to_24);

    QJsonObject unacceptable;
    unacceptable["10_to_19_fps"] = static_cast<int>(m_windowBuckets.fps_10_to_19);
    unacceptable["5_to_9_fps"] = static_cast<int>(m_windowBuckets.fps_5_to_9);
    unacceptable["under_5_fps"] = static_cast<int>(m_windowBuckets.fps_under_5);

    QJsonObject fpsStreamSeconds;
    fpsStreamSeconds["acceptable"] = acceptable;
    fpsStreamSeconds["unacceptable"] = unacceptable;

    QJsonObject root;
    root["timestamp"] = timestamp;
    root["machine_id"] = QString::fromStdString(m_machineId);
    root["framework"] = "cpp_qt6";
    root["hardware_mode"] = "cpu";
    root["window_duration_seconds"] = 60;
    root["active_streams"] = avgActiveStreams;
    root["fps_stream_seconds"] = fpsStreamSeconds;

    QJsonDocument doc(root);
    QByteArray jsonData = doc.toJson(QJsonDocument::Indented);

    QString path = QString::fromStdString(m_logPath);
    QFileInfo fileInfo(path);
    QDir dir = fileInfo.dir();
    if (!dir.exists()) {
        dir.mkpath(".");
    }

    QFile file(path);
    if (file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        file.write(jsonData);
        file.write("\n");
        file.close();

        std::cout << "[Telemetry] Flushed 60s window (" << m_windowBuckets.totalStreamSeconds()
                  << " stream-seconds) to " << m_logPath << std::endl;
        std::cout << "            Acceptable (25-30: " << m_windowBuckets.fps_25_to_30
                  << ", 20-24: " << m_windowBuckets.fps_20_to_24
                  << ") | Unacceptable (10-19: " << m_windowBuckets.fps_10_to_19
                  << ", 5-9: " << m_windowBuckets.fps_5_to_9
                  << ", <5: " << m_windowBuckets.fps_under_5 << ")" << std::endl;
    } else {
        std::cerr << "[Telemetry] Error: Failed to open log file for writing: " << m_logPath << std::endl;
    }
}

FpsBuckets TelemetryManager::currentWindowBuckets() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_windowBuckets;
}

int TelemetryManager::secondsRemaining() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return 60 - m_secondsInWindow;
}

float TelemetryManager::aggregateFps() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_aggregateFps;
}

int TelemetryManager::activeStreamsCount() const {
    return m_activeStreams;
}

int TelemetryManager::liveStreamsCount() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_liveStreams;
}
