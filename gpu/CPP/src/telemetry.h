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
    float m_aggregateFps = 0.0f;

    // Previous frame counts per stream to calculate delta per 1s tick
    std::vector<uint64_t> m_prevFrames;
    uint64_t m_accumulatedActiveStreams = 0;
    uint32_t m_activeStreamsSampleCount = 0;
};
