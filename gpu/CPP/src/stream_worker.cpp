#include "stream_worker.h"

#include <iostream>
#include <chrono>

static int ffmpeg_interrupt_callback(void* opaque) {
    auto* worker = static_cast<StreamWorker*>(opaque);
    return (worker && worker->isInterrupted()) ? 1 : 0;
}

StreamWorker::StreamWorker(int streamId, const std::string& rtspUrl,
                           std::shared_ptr<HwAccelManager> hwAccel,
                           QObject* parent)
    : QThread(parent)
    , m_streamId(streamId)
    , m_rtspUrl(rtspUrl)
    , m_hwAccel(hwAccel)
{
    setObjectName(QString("StreamWorker-%1").arg(streamId));
    if (m_hwAccel && m_hwAccel->isInitialized()) {
        m_hwDeviceName = m_hwAccel->deviceName();
    }
}

StreamWorker::~StreamWorker() {
    stopWorker();
    if (m_consumedFrame) {
        av_frame_free(&m_consumedFrame);
        m_consumedFrame = nullptr;
    }
    AVFrame* shared = m_sharedFrame.exchange(nullptr);
    if (shared) {
        av_frame_free(&shared);
    }
}

void StreamWorker::stopWorker() {
    m_stopRequested.store(true, std::memory_order_release);
    requestInterruption();
    if (isRunning()) {
        wait(2000);
        if (isRunning()) {
            terminate();
            wait(500);
        }
    }
}

bool StreamWorker::isInterrupted() const {
    return m_stopRequested.load(std::memory_order_relaxed) || isInterruptionRequested();
}

AVFrame* StreamWorker::acquireFrame(bool* outIsNew) {
    bool isNew = m_hasNewFrame.exchange(false, std::memory_order_acq_rel);
    if (isNew) {
        AVFrame* newFrame = m_sharedFrame.exchange(nullptr, std::memory_order_acq_rel);
        if (newFrame) {
            if (m_consumedFrame) {
                av_frame_free(&m_consumedFrame);
            }
            m_consumedFrame = newFrame;
        }
    }
    if (outIsNew) {
        *outIsNew = isNew;
    }
    return m_consumedFrame;
}

void StreamWorker::run() {
    AVPacket* pkt = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();

    while (!isInterrupted()) {
        AVFormatContext* fmtCtx = avformat_alloc_context();
        if (!fmtCtx) {
            msleep(500);
            continue;
        }

        fmtCtx->interrupt_callback.callback = ffmpeg_interrupt_callback;
        fmtCtx->interrupt_callback.opaque = this;

        AVDictionary* opts = nullptr;
        av_dict_set(&opts, "rtsp_transport", "tcp", 0);
        av_dict_set(&opts, "stimeout", "5000000", 0);       // 5 sec timeout (in us)
        av_dict_set(&opts, "max_delay", "500000", 0);        // 500 ms max delay (in us)
        av_dict_set(&opts, "buffer_size", "4194304", 0);     // 4MB socket buffer

        int ret = avformat_open_input(&fmtCtx, m_rtspUrl.c_str(), nullptr, &opts);
        av_dict_free(&opts);

        if (ret < 0) {
            m_isConnected.store(false, std::memory_order_release);
            avformat_close_input(&fmtCtx);
            if (!isInterrupted()) {
                msleep(1000);
            }
            continue;
        }

        if (avformat_find_stream_info(fmtCtx, nullptr) < 0) {
            m_isConnected.store(false, std::memory_order_release);
            avformat_close_input(&fmtCtx);
            if (!isInterrupted()) {
                msleep(1000);
            }
            continue;
        }

        int videoStreamIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        if (videoStreamIdx < 0) {
            m_isConnected.store(false, std::memory_order_release);
            avformat_close_input(&fmtCtx);
            if (!isInterrupted()) {
                msleep(1000);
            }
            continue;
        }

        AVCodecParameters* codecPar = fmtCtx->streams[videoStreamIdx]->codecpar;
        const AVCodec* codec = avcodec_find_decoder(codecPar->codec_id);
        if (!codec) {
            std::cerr << "[Stream " << m_streamId << "] Codec not found for ID: " << codecPar->codec_id << std::endl;
            m_isConnected.store(false, std::memory_order_release);
            avformat_close_input(&fmtCtx);
            if (!isInterrupted()) {
                msleep(1000);
            }
            continue;
        }

        AVCodecContext* codecCtx = avcodec_alloc_context3(codec);
        if (!codecCtx) {
            m_isConnected.store(false, std::memory_order_release);
            avformat_close_input(&fmtCtx);
            if (!isInterrupted()) {
                msleep(1000);
            }
            continue;
        }

        if (avcodec_parameters_to_context(codecCtx, codecPar) < 0) {
            m_isConnected.store(false, std::memory_order_release);
            avcodec_free_context(&codecCtx);
            avformat_close_input(&fmtCtx);
            if (!isInterrupted()) {
                msleep(1000);
            }
            continue;
        }

        // Attach GPU hardware acceleration
        if (m_hwAccel && m_hwAccel->isInitialized()) {
            AVBufferRef* hwRef = m_hwAccel->createDeviceRef();
            if (hwRef) {
                codecCtx->hw_device_ctx = hwRef;
                codecCtx->opaque = m_hwAccel.get();
                codecCtx->get_format = HwAccelManager::getHwFormat;
                m_hwDeviceName = m_hwAccel->deviceName();
            }
        }

        codecCtx->thread_count = 1;
        codecCtx->flags |= AV_CODEC_FLAG_LOW_DELAY;
        codecCtx->flags2 |= AV_CODEC_FLAG2_FAST;

        if (avcodec_open2(codecCtx, codec, nullptr) < 0) {
            std::cerr << "[Stream " << m_streamId << "] Failed to open codec context with hwaccel." << std::endl;
            m_isConnected.store(false, std::memory_order_release);
            avcodec_free_context(&codecCtx);
            avformat_close_input(&fmtCtx);
            if (!isInterrupted()) {
                msleep(1000);
            }
            continue;
        }

        // Bitstream filter to ensure Annex B start codes and in-band SPS/PPS
        const AVBitStreamFilter* bsf = av_bsf_get_by_name("h264_mp4toannexb");
        AVBSFContext* bsfCtx = nullptr;
        if (bsf) {
            if (av_bsf_alloc(bsf, &bsfCtx) == 0) {
                avcodec_parameters_copy(bsfCtx->par_in, codecPar);
                av_bsf_init(bsfCtx);
            }
        }
        AVPacket* filteredPkt = av_packet_alloc();

        m_isConnected.store(true, std::memory_order_release);

        // Demuxing and decoding loop
        while (!isInterrupted()) {
            ret = av_read_frame(fmtCtx, pkt);
            if (ret < 0) {
                break;
            }

            if (pkt->stream_index == videoStreamIdx) {
                if (bsfCtx) {
                    if (av_bsf_send_packet(bsfCtx, pkt) == 0) {
                        while (av_bsf_receive_packet(bsfCtx, filteredPkt) == 0) {
                            avcodec_send_packet(codecCtx, filteredPkt);
                            av_packet_unref(filteredPkt);

                            while (avcodec_receive_frame(codecCtx, frame) == 0) {
                                int w = frame->width;
                                int h = frame->height;
                                if (w > 0 && h > 0) {
                                    m_width.store(w, std::memory_order_relaxed);
                                    m_height.store(h, std::memory_order_relaxed);

                                    if (m_hwAccel && m_hwAccel->isInitialized() &&
                                        frame->format == m_hwAccel->hwPixFormat()) {
                                        m_isHwAccelerated.store(true, std::memory_order_relaxed);
                                    }

                                    // Zero-copy reference-counted frame clone
                                    AVFrame* clone = av_frame_clone(frame);
                                    if (clone) {
                                        AVFrame* old = m_sharedFrame.exchange(clone, std::memory_order_acq_rel);
                                        if (old) {
                                            av_frame_free(&old);
                                        }
                                        m_hasNewFrame.store(true, std::memory_order_release);
                                        m_decodedFrames.fetch_add(1, std::memory_order_relaxed);
                                    }
                                }
                                av_frame_unref(frame);
                            }
                        }
                    }
                } else {
                    int sendRet = avcodec_send_packet(codecCtx, pkt);
                    if (sendRet >= 0) {
                        while (avcodec_receive_frame(codecCtx, frame) == 0) {
                            int w = frame->width;
                            int h = frame->height;
                            if (w > 0 && h > 0) {
                                m_width.store(w, std::memory_order_relaxed);
                                m_height.store(h, std::memory_order_relaxed);

                                if (m_hwAccel && m_hwAccel->isInitialized() &&
                                    frame->format == m_hwAccel->hwPixFormat()) {
                                    m_isHwAccelerated.store(true, std::memory_order_relaxed);
                                }

                                AVFrame* clone = av_frame_clone(frame);
                                if (clone) {
                                    AVFrame* old = m_sharedFrame.exchange(clone, std::memory_order_acq_rel);
                                    if (old) {
                                        av_frame_free(&old);
                                    }
                                    m_hasNewFrame.store(true, std::memory_order_release);
                                    m_decodedFrames.fetch_add(1, std::memory_order_relaxed);
                                }
                            }
                            av_frame_unref(frame);
                        }
                    }
                }
                av_packet_unref(pkt);
            } else {
                av_packet_unref(pkt);
            }
        }

        if (bsfCtx) {
            av_bsf_free(&bsfCtx);
        }
        av_packet_free(&filteredPkt);

        m_isConnected.store(false, std::memory_order_release);
        avcodec_free_context(&codecCtx);
        avformat_close_input(&fmtCtx);

        if (!isInterrupted()) {
            msleep(500);
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
}
