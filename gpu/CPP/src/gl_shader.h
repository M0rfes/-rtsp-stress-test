#pragma once

#include <QOpenGLFunctions>
#include <QOpenGLShaderProgram>
#include <memory>
#include <string>

enum class VideoShaderType {
    NV12,
    YUV420P,
    RGBA
};

class VideoShaderProgram {
public:
    VideoShaderProgram() = default;
    ~VideoShaderProgram();

    bool init(QOpenGLFunctions* f, VideoShaderType type);
    void bind();
    void release();

    int programId() const;
    void setTextureUnits(int unit0, int unit1 = 1, int unit2 = 2);
    void setTextureSize(float width, float height);

private:
    std::unique_ptr<QOpenGLShaderProgram> m_program;
    int m_locTexY = -1;
    int m_locTexU = -1;
    int m_locTexV = -1;
    int m_locTexUV = -1;
    int m_locTexRGBA = -1;
    int m_locTexSize = -1;
    VideoShaderType m_type = VideoShaderType::NV12;
};
