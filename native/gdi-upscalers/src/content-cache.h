/* SPDX-License-Identifier: LGPL-2.1-or-later */
#pragma once

#include <CommonCrypto/CommonDigest.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <list>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace wgdi {

using Digest = std::array<uint8_t, CC_SHA256_DIGEST_LENGTH>;

class Hasher {
public:
    Hasher() { CC_SHA256_Init(&context); }
    void update(const void *data, size_t length)
    {
        if (length) CC_SHA256_Update(&context, data, CC_LONG(length));
    }
    void update(const std::string &text) { update(text.data(), text.size()); }
    void update(uint64_t value)
    {
        const uint8_t bytes[8] = {uint8_t(value), uint8_t(value >> 8), uint8_t(value >> 16),
            uint8_t(value >> 24), uint8_t(value >> 32), uint8_t(value >> 40),
            uint8_t(value >> 48), uint8_t(value >> 56)};
        update(bytes, sizeof(bytes));
    }
    Digest digest()
    {
        Digest out;
        CC_SHA256_Final(out.data(), &context);
        return out;
    }

private:
    CC_SHA256_CTX context;
};

inline std::string hex_digest(const uint8_t *bytes, size_t length)
{
    static const char digits[] = "0123456789abcdef";
    std::string out(length * 2, '0');
    for (size_t i = 0; i < length; ++i) {
        out[i * 2] = digits[bytes[i] >> 4];
        out[i * 2 + 1] = digits[bytes[i] & 15];
    }
    return out;
}

inline std::string hex_digest(const Digest &digest)
{
    return hex_digest(digest.data(), digest.size());
}

inline std::optional<Digest> hash_file(const std::string &path) noexcept
{
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) return std::nullopt;
    Hasher hasher;
    std::array<uint8_t, 65536> chunk;
    size_t read;
    while ((read = std::fread(chunk.data(), 1, chunk.size(), file)))
        hasher.update(chunk.data(), read);
    const bool failed = std::ferror(file);
    std::fclose(file);
    if (failed) return std::nullopt;
    return hasher.digest();
}

inline std::optional<Digest> hash_directory(const std::string &root) noexcept
try {
    namespace fs = std::filesystem;
    std::error_code error;
    const fs::file_status status = fs::symlink_status(root, error);
    if (error || !fs::is_directory(status)) return std::nullopt;
    std::vector<std::string> relative;
    fs::recursive_directory_iterator it(root, error);
    const fs::recursive_directory_iterator end;
    for (; it != end && !error; it.increment(error)) {
        std::error_code entryError;
        const fs::file_status entry = it->symlink_status(entryError);
        if (entryError) return std::nullopt;
        if (fs::is_regular_file(entry))
            relative.push_back(it->path().lexically_relative(root).generic_string());
    }
    if (error) return std::nullopt;
    std::sort(relative.begin(), relative.end());
    Hasher hasher;
    for (const std::string &name : relative) {
        const std::string full = root + "/" + name;
        std::error_code sizeError;
        const uint64_t size = fs::file_size(full, sizeError);
        if (sizeError) return std::nullopt;
        hasher.update(name);
        hasher.update(uint64_t(0));
        hasher.update(size);
        const auto digest = hash_file(full);
        if (!digest) return std::nullopt;
        hasher.update(digest->data(), digest->size());
    }
    return hasher.digest();
} catch (...) {
    return std::nullopt;
}

inline std::string cache_namespace(const char *prefix, const char *game)
{
    Hasher hasher;
    hasher.update("wgdi-cache-ns-v1", 15);
    hasher.update(uint64_t(0));
    const std::string prefixText = prefix ? prefix : "";
    const std::string gameText = game ? game : "";
    hasher.update(prefixText);
    hasher.update(uint64_t(0));
    hasher.update(gameText);
    const Digest digest = hasher.digest();
    return hex_digest(digest.data(), 12);
}

inline std::string default_cache_root()
{
    const char *home = std::getenv("HOME");
    return std::string(home ? home : "/tmp") +
        "/Library/Caches/com.isaacmarovitz.Whisky/GDIUpscaler";
}

class ContentCache {
public:
    enum class Mode { off, memory, persistent };
    struct Stats {
        uint64_t memoryHits = 0, diskHits = 0, misses = 0, stores = 0;
    };

    static constexpr uint64_t kMaxField = 512ull << 20;
    static constexpr uint64_t kMaxMemoryMb = 4096;
    static constexpr uint64_t kMaxDiskMb = 65536;

    ContentCache() = default;
    ~ContentCache() { if (lockFd_ >= 0) close(lockFd_); }
    ContentCache(const ContentCache &) = delete;
    ContentCache &operator=(const ContentCache &) = delete;
    struct FdGuard {
        int fd;
        ~FdGuard() { if (fd >= 0) close(fd); }
    };
    struct DirGuard {
        DIR *dir;
        ~DirGuard() { if (dir) closedir(dir); }
    };
    struct LockGuard {
        ContentCache &cache;
        bool held;
        explicit LockGuard(ContentCache &c) : cache(c), held(cache.acquire_lock() >= 0) {}
        ~LockGuard() { if (held) cache.release_lock(); }
    };
    ContentCache(Mode mode, uint64_t memoryBytes, uint64_t diskBytes, std::string directory) noexcept
        : mode_(mode), memoryLimit_(memoryBytes), diskLimit_(diskBytes),
          directory_(std::move(directory))
    {
        if (mode_ != Mode::persistent || !diskLimit_ || directory_.empty()) return;
        try {
            struct stat info;
            if (lstat(directory_.c_str(), &info)) {
                std::error_code error;
                std::filesystem::create_directories(directory_, error);
                if (error) { diskBroken_ = true; return; }
                chmod(directory_.c_str(), 0700);
            } else if (S_ISLNK(info.st_mode) || !S_ISDIR(info.st_mode)) {
                diskBroken_ = true;
                return;
            }
            {
                LockGuard guard(*this);
                if (!guard.held) return;
                sync_locked();
                if (diskBytes_ > diskLimit_ && advance_generation())
                    prune_locked("", 0);
            }
        } catch (...) {
            indexReady_ = false;
        }
    }

    bool active() const { return mode_ != Mode::off; }
    Mode mode() const { return mode_; }

    bool get(const Digest &scope, const void *input, size_t inputLen,
             void *output, size_t outputLen) noexcept
    try {
        if (mode_ == Mode::off) { ++stats_.misses; return false; }
        if (!input || !output || !inputLen || !outputLen ||
            inputLen > kMaxField || outputLen > kMaxField) {
            ++stats_.misses;
            return false;
        }
        const Digest key = entry_key(scope, input, inputLen);
        if (memoryLimit_) {
            const auto it = entries_.find(key);
            if (it != entries_.end() && it->second.output.size() == outputLen &&
                it->second.inputLength == inputLen) {
                lru_.splice(lru_.begin(), lru_, it->second.lru);
                std::memcpy(output, it->second.output.data(), outputLen);
                ++stats_.memoryHits;
                return true;
            }
        }
        if (diskReady()) {
            std::vector<uint8_t> stored;
            void *target = output;
            if (memoryLimit_) {
                stored.resize(outputLen);
                target = stored.data();
            }
            if (disk_get(key, inputLen, target, outputLen)) {
                if (memoryLimit_) {
                    try { memory_put(key, inputLen, stored.data(), outputLen); }
                    catch (...) { }
                    std::memcpy(output, stored.data(), outputLen);
                }
                ++stats_.diskHits;
                return true;
            }
        }
        ++stats_.misses;
        return false;
    } catch (...) {
        return false;
    }

    void put(const Digest &scope, const void *input, size_t inputLen,
             const void *output, size_t outputLen) noexcept
    try {
        if (mode_ == Mode::off) return;
        if (!input || !output || !inputLen || !outputLen ||
            inputLen > kMaxField || outputLen > kMaxField) return;
        const Digest key = entry_key(scope, input, inputLen);
        if (memoryLimit_) memory_put(key, inputLen, output, outputLen);
        if (diskReady()) disk_put(key, inputLen, output, outputLen);
        ++stats_.stores;
    } catch (...) {
    }

    const Stats &stats() const { return stats_; }
    size_t memory_entries() const { return entries_.size(); }
    uint64_t memory_bytes() const { return memoryBytes_; }
    uint64_t disk_bytes() const { return diskBytes_; }
    size_t disk_entries() const { return index_.size(); }
    bool disk_ready() const { return diskReady(); }
    const std::string &directory() const { return directory_; }

private:
    struct DigestHash {
        size_t operator()(const Digest &digest) const
        {
            size_t value = 0;
            std::memcpy(&value, digest.data(), sizeof(value));
            return value;
        }
    };
    struct MemoryEntry {
        std::vector<uint8_t> output;
        uint64_t inputLength;
        std::list<Digest>::iterator lru;
    };
    struct DiskEntry {
        uint64_t bytes;
        int64_t mtime;
    };

    static constexpr uint32_t kMagic = 0x57474443u;
    static constexpr uint32_t kVersion = 2;
    static constexpr size_t kHeaderBytes = 4 + 4 + 32 + 8 + 8 + 32;
    static constexpr size_t kEntryOverhead = 256;

    static int64_t now_ns()
    {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return int64_t(ts.tv_sec) * 1000000000 + ts.tv_nsec;
    }

    bool diskReady() const
    {
        return mode_ == Mode::persistent && diskLimit_ && !directory_.empty() && !diskBroken_;
    }

    static Digest entry_key(const Digest &scope, const void *input, size_t inputLen)
    {
        Hasher hasher;
        hasher.update(scope.data(), scope.size());
        hasher.update(input, inputLen);
        return hasher.digest();
    }

    static void store_u32(uint8_t *p, uint32_t v)
    {
        p[0] = uint8_t(v); p[1] = uint8_t(v >> 8); p[2] = uint8_t(v >> 16); p[3] = uint8_t(v >> 24);
    }
    static void store_u64(uint8_t *p, uint64_t v)
    {
        for (unsigned i = 0; i < 8; ++i) p[i] = uint8_t(v >> (i * 8));
    }
    static uint32_t load_u32(const uint8_t *p)
    {
        return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
    }
    static uint64_t load_u64(const uint8_t *p)
    {
        uint64_t v = 0;
        for (unsigned i = 0; i < 8; ++i) v |= uint64_t(p[i]) << (i * 8);
        return v;
    }

    void memory_put(const Digest &key, size_t inputLen,
                    const void *output, size_t outputLen)
    {
        const auto *out = static_cast<const uint8_t *>(output);
        const uint64_t bytes = outputLen + kEntryOverhead;
        if (bytes > memoryLimit_) return;
        MemoryEntry entry;
        entry.output.assign(out, out + outputLen);
        entry.inputLength = inputLen;
        const auto existing = entries_.find(key);
        if (existing != entries_.end()) {
            memoryBytes_ -= existing->second.output.size() + kEntryOverhead;
            lru_.erase(existing->second.lru);
            entries_.erase(existing);
        }
        lru_.push_front(key);
        entry.lru = lru_.begin();
        try {
            entries_.emplace(key, std::move(entry));
        } catch (...) {
            lru_.pop_front();
            throw;
        }
        memoryBytes_ += bytes;
        while (memoryBytes_ > memoryLimit_ && !lru_.empty()) {
            const Digest &oldest = lru_.back();
            const auto it = entries_.find(oldest);
            memoryBytes_ -= it->second.output.size() + kEntryOverhead;
            entries_.erase(it);
            lru_.pop_back();
        }
    }

    std::string record_path(const Digest &key) const
    {
        return directory_ + "/" + hex_digest(key) + ".bin";
    }

    static bool record_name(const std::string &name)
    {
        if (name.size() != 68 || name.compare(64, 4, ".bin")) return false;
        for (size_t i = 0; i < 64; ++i) {
            const char c = name[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        }
        return true;
    }

    bool owned_regular(const std::string &path, struct stat *info) const
    {
        struct stat local;
        if (!info) info = &local;
        return !lstat(path.c_str(), info) && S_ISREG(info->st_mode) && info->st_uid == geteuid();
    }

    int open_lock()
    {
        if (lockFd_ >= 0) return lockFd_;
        const int fd = open((directory_ + "/.lock").c_str(),
                            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) return -1;
        struct stat info;
        if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != geteuid()) {
            close(fd);
            return -1;
        }
        lockFd_ = fd;
        return fd;
    }

    int acquire_lock()
    {
        const int fd = open_lock();
        if (fd < 0) return -1;
        if (flock(fd, LOCK_EX | LOCK_NB)) return -1;
        return fd;
    }

    void release_lock()
    {
        if (lockFd_ >= 0) flock(lockFd_, LOCK_UN);
    }

    uint64_t read_generation()
    {
        uint8_t bytes[8] = {};
        pread(lockFd_, bytes, sizeof(bytes), 0);
        return load_u64(bytes);
    }

    bool advance_generation()
    {
        uint8_t bytes[8];
        store_u64(bytes, generation_ + 1);
        if (pwrite(lockFd_, bytes, sizeof(bytes), 0) != (ssize_t)sizeof(bytes)) return false;
        ++generation_;
        return true;
    }

    void sync_locked()
    {
        const uint64_t fileGeneration = read_generation();
        if (indexReady_ && fileGeneration == generation_) return;
        index_.clear();
        diskBytes_ = 0;
        {
            DirGuard dir{opendir(directory_.c_str())};
            if (dir.dir) {
                struct dirent *item;
                while ((item = readdir(dir.dir))) {
                    const std::string name = item->d_name;
                    if (!record_name(name)) continue;
                    struct stat info;
                    if (!owned_regular(directory_ + "/" + name, &info)) continue;
                    index_[name.substr(0, 64)] = DiskEntry{uint64_t(info.st_size),
                        int64_t(info.st_mtimespec.tv_sec) * 1000000000 + info.st_mtimespec.tv_nsec};
                    diskBytes_ += uint64_t(info.st_size);
                }
            }
        }
        indexReady_ = true;
        generation_ = fileGeneration;
    }

    bool prune_locked(const std::string &except, uint64_t reserve)
    {
        if (diskBytes_ + reserve <= diskLimit_) return true;
        std::vector<std::pair<int64_t, std::string>> ordered;
        ordered.reserve(index_.size());
        for (const auto &[name, entry] : index_) ordered.emplace_back(entry.mtime, name);
        std::sort(ordered.begin(), ordered.end());
        for (const auto &[mtime, name] : ordered) {
            if (diskBytes_ + reserve <= diskLimit_) break;
            if (name == except) continue;
            const auto it = index_.find(name);
            if (it == index_.end()) continue;
            const std::string path = directory_ + "/" + name + ".bin";
            if (!unlink(path.c_str())) {
                diskBytes_ -= it->second.bytes;
                index_.erase(it);
            }
        }
        return diskBytes_ + reserve <= diskLimit_;
    }

    static std::vector<uint8_t> build_record(const Digest &key, size_t inputLen,
                                             const void *output, size_t outputLen)
    {
        std::vector<uint8_t> record(kHeaderBytes + outputLen);
        uint8_t *p = record.data();
        store_u32(p, kMagic); store_u32(p + 4, kVersion);
        std::memcpy(p + 8, key.data(), key.size());
        store_u64(p + 40, inputLen); store_u64(p + 48, outputLen);
        Hasher hasher;
        hasher.update(output, outputLen);
        const Digest outputDigest = hasher.digest();
        std::memcpy(p + 56, outputDigest.data(), outputDigest.size());
        std::memcpy(p + kHeaderBytes, output, outputLen);
        return record;
    }

    void disk_put(const Digest &key, size_t inputLen,
                  const void *output, size_t outputLen)
    {
        const uint64_t bytes = kHeaderBytes + uint64_t(outputLen);
        if (bytes > diskLimit_) return;
        LockGuard guard(*this);
        if (!guard.held) return;
        try {
            sync_locked();
            const std::string name = hex_digest(key);
            const auto existing = index_.find(name);
            const uint64_t previous = existing == index_.end() ? 0 : existing->second.bytes;
            const uint64_t need = bytes > previous ? bytes - previous : 0;
            if (!advance_generation()) return;
            if (!prune_locked(name, need)) return;
            const auto record = build_record(key, inputLen, output, outputLen);
            {
                const std::string final = directory_ + "/" + name + ".bin";
                std::string temp = directory_ + "/.tmpXXXXXX";
                FdGuard fd{mkstemp(temp.data())};
                if (fd.fd < 0) return;
                struct TempGuard {
                    const char *path;
                    ~TempGuard() { unlink(path); }
                } cleanup{temp.c_str()};
                fchmod(fd.fd, 0600);
                size_t written = 0;
                while (written < record.size()) {
                    const ssize_t n = write(fd.fd, record.data() + written, record.size() - written);
                    if (n <= 0) break;
                    written += size_t(n);
                }
                if (written != record.size() || rename(temp.c_str(), final.c_str()))
                    return;
            }
            index_[name] = DiskEntry{bytes, now_ns()};
            diskBytes_ -= previous;
            diskBytes_ += bytes;
        } catch (...) {
            indexReady_ = false;
        }
    }

    bool disk_get(const Digest &key, size_t inputLen,
                  void *output, size_t outputLen)
    {
        const std::string path = record_path(key);
        FdGuard fd{open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)};
        if (fd.fd < 0) return false;
        bool ok = false;
        struct stat info;
        if (!fstat(fd.fd, &info) && S_ISREG(info.st_mode) && info.st_uid == geteuid() &&
            uint64_t(info.st_size) >= kHeaderBytes && uint64_t(info.st_size) <= kMaxField + kHeaderBytes) {
            std::array<uint8_t, kHeaderBytes> header;
            if (pread(fd.fd, header.data(), header.size(), 0) == ssize_t(header.size()) &&
                load_u32(header.data()) == kMagic && load_u32(header.data() + 4) == kVersion &&
                !std::memcmp(header.data() + 8, key.data(), key.size()) &&
                load_u64(header.data() + 40) == inputLen && load_u64(header.data() + 48) == outputLen &&
                uint64_t(info.st_size) == kHeaderBytes + outputLen) {
                std::vector<uint8_t> storedOutput(outputLen);
                if (pread(fd.fd, storedOutput.data(), outputLen, kHeaderBytes) == ssize_t(outputLen)) {
                    Hasher hasher;
                    hasher.update(storedOutput.data(), outputLen);
                    const Digest actual = hasher.digest();
                    Digest expected;
                    std::memcpy(expected.data(), header.data() + 56, expected.size());
                    if (actual == expected) {
                        std::memcpy(output, storedOutput.data(), outputLen);
                        ok = true;
                    }
                }
            }
        }
        if (ok) {
            const std::string name = hex_digest(key);
            const auto it = index_.find(name);
            if (indexReady_ && it != index_.end()) it->second.mtime = now_ns();
            struct timespec times[2] = {{0, UTIME_OMIT}, {0, UTIME_NOW}};
            futimens(fd.fd, times);
        }
        return ok;
    }

    Mode mode_ = Mode::memory;
    uint64_t memoryLimit_ = 0, diskLimit_ = 0;
    std::string directory_;
    bool diskBroken_ = false;
    std::unordered_map<Digest, MemoryEntry, DigestHash> entries_;
    std::list<Digest> lru_;
    uint64_t memoryBytes_ = 0;
    std::unordered_map<std::string, DiskEntry> index_;
    uint64_t diskBytes_ = 0;
    bool indexReady_ = false;
    uint64_t generation_ = 0;
    int lockFd_ = -1;
    Stats stats_;
};

inline ContentCache::Mode cache_mode(const char *value)
{
    if (value && !std::strcmp(value, "off")) return ContentCache::Mode::off;
    if (value && !std::strcmp(value, "persistent")) return ContentCache::Mode::persistent;
    return ContentCache::Mode::memory;
}

inline std::optional<uint64_t> cache_limit_bytes(const char *value, uint64_t maxMb)
{
    if (!value || !*value) return std::nullopt;
    uint64_t mb = 0;
    for (const char *p = value; *p; ++p) {
        if (*p < '0' || *p > '9' || mb > (UINT64_MAX - 9) / 10) return std::nullopt;
        mb = mb * 10 + uint64_t(*p - '0');
    }
    if (mb > maxMb) mb = maxMb;
    if (mb > (UINT64_MAX >> 20)) return std::nullopt;
    return mb << 20;
}

inline ContentCache content_cache_from_environment() noexcept
try {
    const char *base = std::getenv("WINE_GDI_CACHE_DIRECTORY");
    const std::string root = base && base[0] == '/' ? base : default_cache_root();
    return ContentCache(
        cache_mode(std::getenv("WINE_GDI_CACHE_MODE")),
        cache_limit_bytes(std::getenv("WINE_GDI_CACHE_MEMORY_MB"),
                        ContentCache::kMaxMemoryMb).value_or(256ull << 20),
        cache_limit_bytes(std::getenv("WINE_GDI_CACHE_DISK_MB"),
                        ContentCache::kMaxDiskMb).value_or(4ull << 30),
        root + "/" + cache_namespace(std::getenv("WINEPREFIX"), std::getenv("WINE_GDI_CACHE_GAME")));
} catch (...) {
    return ContentCache();
}

}
