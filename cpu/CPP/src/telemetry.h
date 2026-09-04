#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include <mutex>
#include "stream_worker.h"

struct FpsBuckets {
    uint32_t fps_25_to_30 = 0;
    uint32_t fps_20_to_24 = 0;
    uint32_t fps_10_to_19 = 0;
    uint32_t fps_5_to_9 = 0;
    uint32_t fps_under_5 = 0;

    void reset() {
        fps_25_to_30 = 0;
        fps_20_to_24 = 0;
        fps_10_to_19 = 0;
        fps_5_to_9 = 0;
        fps_under_5 = 0;
    }

    uint32_t totalStreamSeconds() const {
        return fps_25_to_30 + fps_20_to_24 + fps_10_to_19 + fps_5_to_9 + fps_under_5;
    }

    void addSample(uint32_t fps) {
        if (fps >= 25) {
            fps_25_to_30++;
        } else if (fps >= 20) {
            fps_20_to_24++;
        } else if (fps >= 10) {
            fps_10_to_19++;
        } else if (fps >= 5) {
            fps_5_to_9++;
        } else {
            fps_under_5++;
        }
    }
};

class TelemetryManager {
public:
    TelemetryManager(const std::string& logPath, const std::string& machineId, int activeStreams);
    ~TelemetryManager() = default;

    // Called on 1-second timer tick
    void tick(const std::vector<StreamWorker*>& workers);

    // Getters for UI display
    FpsBuckets currentWindowBuckets() const;
    int secondsRemaining() const;
    float aggregateFps() const;
    int activeStreamsCount() const;
    int liveStreamsCount() const;

private:
    void flushWindow();

    std::string m_logPath;
    std::string m_machineId;
    int m_activeStreams;
    int m_liveStreams = 0;

    mutable std::mutex m_mutex;
    FpsBuckets m_windowBuckets;
    int m_secondsInWindow = 0;
    int64_t m_accumulatedActiveStreams = 0;
    int m_activeStreamsSampleCount = 0;
    uint64_t m_accumulatedUiFrames = 0;
    uint64_t m_accumulatedDecodedFrames = 0;
    float m_aggregateFps = 0.0f;

    std::vector<uint64_t> m_prevPaintedFrames;
    std::vector<uint64_t> m_prevDecodedFrames;
};
