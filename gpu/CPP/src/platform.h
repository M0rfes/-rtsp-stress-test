#pragma once

#include <string>

constexpr int kNofileTarget = 10240;
constexpr int kStreamStaggerMs = 20;

void raiseFileDescriptorLimit();
std::string platformName();
void applyCpuPlatformHints();
void applyGpuPlatformHints();
void logPlatformPath(bool gpu);
