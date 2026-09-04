#pragma once

#include <QMainWindow>
#include <QGridLayout>
#include <QLabel>
#include <QTimer>
#include <vector>
#include <memory>
#include "config.h"
#include "hw_accel.h"
#include "stream_worker.h"
#include "video_widget.h"
#include "telemetry.h"

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(const AppConfig& config,
                        std::shared_ptr<HwAccelManager> hwAccel,
                        QWidget* parent = nullptr);
    ~MainWindow() override;

protected:
    void closeEvent(QCloseEvent* event) override;

private slots:
    void onRenderTick();
    void onTelemetryTick();

private:
    void setupUi();
    void startWorkers();
    void stopWorkers();
    void updateHud();

    AppConfig m_config;
    std::shared_ptr<HwAccelManager> m_hwAccel;
    std::unique_ptr<TelemetryManager> m_telemetry;

    std::vector<StreamWorker*> m_workers;
    std::vector<VideoWidget*> m_videoWidgets;

    // Timers
    QTimer* m_renderTimer = nullptr;
    QTimer* m_telemetryTimer = nullptr;

    // UI Elements
    QWidget* m_centralWidget = nullptr;
    QGridLayout* m_gridLayout = nullptr;

    // HUD labels
    QLabel* m_streamsLabel = nullptr;
    QLabel* m_fpsLabel = nullptr;
    QLabel* m_countdownLabel = nullptr;
    QLabel* m_acceptableBucketsLabel = nullptr;
    QLabel* m_unacceptableBucketsLabel = nullptr;
    QLabel* m_modeLabel = nullptr;
};
