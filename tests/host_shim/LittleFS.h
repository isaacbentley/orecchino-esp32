#pragma once
#include "Arduino.h"
class File { public: operator bool() const { return false; } size_t size() { return 0; } int read(uint8_t*, size_t) { return 0; } bool seek(size_t) { return false; } void close() {} };
struct MockFS { File open(const char*, const char*) { return File(); } size_t usedBytes() { return 0; } size_t totalBytes() { return 0; } };
extern MockFS LittleFS;
