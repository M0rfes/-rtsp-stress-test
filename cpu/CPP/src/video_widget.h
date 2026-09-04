#pragma once

#include <QWidget>
#include <QPainter>
#include <QPaintEvent>
#include "stream_worker.h"

class VideoWidget : public QWidget {
    Q_OBJECT

public:
    explicit VideoWidget(int streamId, StreamWorker* worker, QWidget* parent = nullptr);
    ~VideoWidget() override = default;

    int streamId() const { return m_streamId; }

protected:
    void paintEvent(QPaintEvent* event) override;

private:
    int m_streamId;
    StreamWorker* m_worker;
};
