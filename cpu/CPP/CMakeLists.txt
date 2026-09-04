cmake_minimum_required(VERSION 3.16)
project(rtsp_benchmark_cpp_cpu VERSION 1.0.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Optimization flags for software decoding benchmark
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
    add_compile_options(-O3 -Wall -Wextra)
elseif(MSVC)
    add_compile_options(/O2 /W3)
endif()

# macOS Homebrew prefix path hints
if(APPLE)
    list(APPEND CMAKE_PREFIX_PATH
        "/opt/homebrew/opt/qtbase"
        "/opt/homebrew/opt/qt"
        "/opt/homebrew"
        "/usr/local/opt/qtbase"
        "/usr/local/opt/qt"
        "/usr/local"
    )
endif()

# Qt6 Configuration
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# FFmpeg libraries (libavcodec, libavformat, libswscale, libavutil)
find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET libavcodec libavformat libswscale libavutil)

add_executable(rtsp-stress-test-cpp-cpu
    src/main.cpp
    src/config.h
    src/config.cpp
    src/platform.h
    src/platform.cpp
    src/stream_worker.h
    src/stream_worker.cpp
    src/video_widget.h
    src/video_widget.cpp
    src/telemetry.h
    src/telemetry.cpp
    src/main_window.h
    src/main_window.cpp
)

target_link_libraries(rtsp-stress-test-cpp-cpu PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    PkgConfig::FFMPEG
)

target_include_directories(rtsp-stress-test-cpp-cpu PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Install target
install(TARGETS rtsp-stress-test-cpp-cpu DESTINATION bin)
