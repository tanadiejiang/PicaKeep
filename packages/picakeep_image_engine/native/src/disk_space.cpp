#include "picakeep_image_engine.h"
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <limits>
#include <string>
#include <stdexcept>
#include <system_error>
#ifdef _WIN32
#include <windows.h>
#elif defined(__ANDROID__) || defined(__linux__)
#include <cerrno>
#include <sys/stat.h>
#include <sys/statvfs.h>
#endif

namespace {
int disk_error(int status, const std::string &message, uint8_t *error, uint64_t size) {
  if (error && size) {
    const size_t count = size_t(std::min<uint64_t>(size - 1, message.size()));
    memcpy(error, message.data(), count); error[count] = 0;
  }
  return status;
}
std::filesystem::path existing_directory(const char *path) {
  auto candidate = std::filesystem::u8path(path);
  if (!candidate.is_absolute()) throw std::invalid_argument("Disk query requires an absolute path");
  bool ascended = false;
  while (true) {
    std::error_code error;
    const auto status = std::filesystem::status(candidate, error);
    if (error && error != std::errc::no_such_file_or_directory)
      throw std::system_error(error);
    if (!error && std::filesystem::exists(status)) {
      if (std::filesystem::is_directory(status)) return candidate;
      // An existing target file lives on its resolved target's volume, which
      // may differ from the symlink's containing directory.
      if (std::filesystem::is_regular_file(status) && !ascended)
        return std::filesystem::canonical(candidate).parent_path();
      throw std::invalid_argument("Disk query has a non-directory ancestor");
    }
    const auto parent = candidate.parent_path();
    if (parent.empty() || parent == candidate)
      throw std::invalid_argument("Disk query has no existing ancestor directory");
    candidate = parent;
    ascended = true;
  }
}
}

extern "C" int pki_query_disk_space(const char *path, uint64_t *available_bytes,
  uint8_t *volume_id, uint64_t volume_id_size, uint8_t *error, uint64_t error_size) {
  if (available_bytes) *available_bytes = 0;
  if (volume_id && volume_id_size) volume_id[0] = 0;
  if (error && error_size) error[0] = 0;
  try {
    if (!path || !*path || !available_bytes || !volume_id || !volume_id_size)
      return disk_error(1, "Invalid disk space query", error, error_size);
    const auto directory = existing_directory(path);
    uint64_t available = 0; std::string identity;
#ifdef _WIN32
    const auto wide = directory.wstring();
    ULARGE_INTEGER free_to_caller{};
    if (!GetDiskFreeSpaceExW(wide.c_str(), &free_to_caller, nullptr, nullptr))
      return disk_error(1, "Cannot query available disk space (system " +
        std::to_string(GetLastError()) + ")", error, error_size);
    available = free_to_caller.QuadPart;
    wchar_t mount[32768]{}; wchar_t volume[128]{};
    if (!GetVolumePathNameW(wide.c_str(), mount, 32768) ||
        !GetVolumeNameForVolumeMountPointW(mount, volume, 128))
      return disk_error(4, "Cannot identify disk volume (system " +
        std::to_string(GetLastError()) + ")", error, error_size);
    identity = "windows-volume:";
    for (const wchar_t *p = volume; *p; ++p) {
      if (*p > 127) return disk_error(4, "Unsupported disk volume identity", error, error_size);
      char ch = char(*p); if (ch >= 'A' && ch <= 'Z') ch += 'a' - 'A';
      identity += ch;
    }
#elif defined(__ANDROID__) || defined(__linux__)
    struct statvfs space{}; struct stat attributes{};
    if (statvfs(directory.c_str(), &space) || stat(directory.c_str(), &attributes))
      return disk_error(1, "Cannot query disk space (system " +
        std::to_string(errno) + ")", error, error_size);
    const uint64_t block = uint64_t(space.f_frsize ? space.f_frsize : space.f_bsize);
    if (!block || uint64_t(space.f_bavail) > std::numeric_limits<uint64_t>::max() / block)
      return disk_error(1, "Disk space size is outside supported range", error, error_size);
    available = uint64_t(space.f_bavail) * block;
    identity = "posix-device:" + std::to_string(uint64_t(attributes.st_dev));
#else
    return disk_error(4, "Disk space query is unsupported on this platform", error, error_size);
#endif
    if (identity.size() >= volume_id_size)
      return disk_error(1, "Disk volume identity output is too small", error, error_size);
    memcpy(volume_id, identity.c_str(), identity.size() + 1);
    *available_bytes = available; return 0;
  } catch (const std::system_error &failure) {
    return disk_error(1, "Cannot inspect disk query ancestor (system " +
      std::to_string(failure.code().value()) + ")", error, error_size);
  } catch (const std::invalid_argument &failure) {
    return disk_error(1, failure.what(), error, error_size);
  } catch (...) { return disk_error(1, "Unexpected disk query error", error, error_size); }
}

extern "C" int pki_available_disk_bytes(const char *path, uint64_t *available_bytes,
  uint8_t *error, uint64_t error_size) {
  uint8_t volume_id[256]{};
  return pki_query_disk_space(path, available_bytes, volume_id, sizeof(volume_id), error, error_size);
}
