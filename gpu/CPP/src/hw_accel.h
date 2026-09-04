#pragma once

#include <string>
#include <memory>
#include <iostream>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/buffer.h>
#include <libavutil/pixfmt.h>
#include <libavutil/pixdesc.h>
}

enum class HwAccelType {
    None,
    Auto,
    Cuda,
    Vaapi,
    VideoToolbox,
    D3d11va
};

class HwAccelManager {
public:
    static std::shared_ptr<HwAccelManager> create(const std::string& typePreference = "auto", int streamCount = 1);

    ~HwAccelManager();

    bool isInitialized() const { return m_hwDeviceCtx != nullptr; }
    AVBufferRef* createDeviceRef();

    enum AVHWDeviceType hwDeviceType() const { return m_hwDeviceType; }
    enum AVPixelFormat hwPixFormat() const { return m_hwPixFormat; }
    std::string deviceName() const { return m_deviceName; }

    static enum AVPixelFormat getHwFormat(AVCodecContext* ctx, const enum AVPixelFormat* pix_fmts);

private:
    HwAccelManager() = default;

    bool initDevice(enum AVHWDeviceType type, const char* device = nullptr);

    AVBufferRef* m_hwDeviceCtx = nullptr;
    enum AVHWDeviceType m_hwDeviceType = AV_HWDEVICE_TYPE_NONE;
    enum AVPixelFormat m_hwPixFormat = AV_PIX_FMT_NONE;
    std::string m_deviceName = "None";
};
