#include "gl_shader.h"
#include <iostream>

static const char* VS_SOURCE = R"(
attribute vec2 aPosition;
attribute vec2 aTexCoord;
varying vec2 vTexCoord;

void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = aTexCoord;
}
)";

static const char* FS_NV12_SOURCE = R"(
#ifdef GL_ES
precision mediump float;
#endif
varying vec2 vTexCoord;
uniform sampler2D texY;
uniform sampler2D texUV;

void main() {
    float y = texture2D(texY, vTexCoord).r;
    vec2 uv = texture2D(texUV, vTexCoord).rg;

    // Standard BT.709 Hardware Color Conversion
    float u = uv.r - 0.5;
    float v = uv.g - 0.5;

    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
}
)";

static const char* FS_YUV420P_SOURCE = R"(
#ifdef GL_ES
precision mediump float;
#endif
varying vec2 vTexCoord;
uniform sampler2D texY;
uniform sampler2D texU;
uniform sampler2D texV;

void main() {
    float y = texture2D(texY, vTexCoord).r;
    float u = texture2D(texU, vTexCoord).r - 0.5;
    float v = texture2D(texV, vTexCoord).r - 0.5;

    // Standard BT.709 Hardware Color Conversion
    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
}
)";

static const char* FS_RGBA_SOURCE = R"(
#ifdef GL_ES
precision mediump float;
#endif
varying vec2 vTexCoord;
uniform sampler2D texRGBA;

void main() {
    gl_FragColor = texture2D(texRGBA, vTexCoord);
}
)";

VideoShaderProgram::~VideoShaderProgram() = default;

bool VideoShaderProgram::init(QOpenGLFunctions* /*f*/, VideoShaderType type) {
    m_type = type;
    m_program = std::make_unique<QOpenGLShaderProgram>();

    if (!m_program->addShaderFromSourceCode(QOpenGLShader::Vertex, VS_SOURCE)) {
        std::cerr << "[GLShader] Vertex shader compilation failed:\n"
                  << m_program->log().toStdString() << std::endl;
        return false;
    }

    const char* fsCode = nullptr;
    switch (type) {
        case VideoShaderType::NV12:
            fsCode = FS_NV12_SOURCE;
            break;
        case VideoShaderType::YUV420P:
            fsCode = FS_YUV420P_SOURCE;
            break;
        case VideoShaderType::RGBA:
            fsCode = FS_RGBA_SOURCE;
            break;
    }

    if (!m_program->addShaderFromSourceCode(QOpenGLShader::Fragment, fsCode)) {
        std::cerr << "[GLShader] Fragment shader compilation failed:\n"
                  << m_program->log().toStdString() << std::endl;
        return false;
    }

    m_program->bindAttributeLocation("aPosition", 0);
    m_program->bindAttributeLocation("aTexCoord", 1);

    if (!m_program->link()) {
        std::cerr << "[GLShader] Program link failed:\n"
                  << m_program->log().toStdString() << std::endl;
        return false;
    }

    switch (type) {
        case VideoShaderType::NV12:
            m_locTexY = m_program->uniformLocation("texY");
            m_locTexUV = m_program->uniformLocation("texUV");
            break;
        case VideoShaderType::YUV420P:
            m_locTexY = m_program->uniformLocation("texY");
            m_locTexU = m_program->uniformLocation("texU");
            m_locTexV = m_program->uniformLocation("texV");
            break;
        case VideoShaderType::RGBA:
            m_locTexRGBA = m_program->uniformLocation("texRGBA");
            break;
    }

    return true;
}

void VideoShaderProgram::bind() {
    if (m_program) {
        m_program->bind();
    }
}

void VideoShaderProgram::release() {
    if (m_program) {
        m_program->release();
    }
}

int VideoShaderProgram::programId() const {
    return m_program ? m_program->programId() : 0;
}

void VideoShaderProgram::setTextureUnits(int unit0, int unit1, int unit2) {
    if (!m_program) return;
    switch (m_type) {
        case VideoShaderType::NV12:
            if (m_locTexY >= 0) m_program->setUniformValue(m_locTexY, unit0);
            if (m_locTexUV >= 0) m_program->setUniformValue(m_locTexUV, unit1);
            break;
        case VideoShaderType::YUV420P:
            if (m_locTexY >= 0) m_program->setUniformValue(m_locTexY, unit0);
            if (m_locTexU >= 0) m_program->setUniformValue(m_locTexU, unit1);
            if (m_locTexV >= 0) m_program->setUniformValue(m_locTexV, unit2);
            break;
        case VideoShaderType::RGBA:
            if (m_locTexRGBA >= 0) m_program->setUniformValue(m_locTexRGBA, unit0);
            break;
    }
}

void VideoShaderProgram::setTextureSize(float width, float height) {
    if (!m_program) return;
    if (m_locTexSize >= 0) {
        m_program->setUniformValue(m_locTexSize, width, height);
    }
}
