#include "picakeep_image_engine.h"
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <initializer_list>
#include <cstring>
#ifdef _WIN32
#include <windows.h>
#include <dbghelp.h>
#include <crtdbg.h>

void fatal_stack() {
  try { if (auto failure = std::current_exception()) std::rethrow_exception(failure); }
  catch (const std::exception &failure) { fprintf(stderr, "TERMINATE_EXCEPTION %s\n", failure.what()); }
  catch (...) { fprintf(stderr, "TERMINATE_EXCEPTION unknown\n"); }
  const auto process = GetCurrentProcess();
  SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME);
  SymInitialize(process, nullptr, TRUE);
  void *frames[64]{};
  auto count = CaptureStackBackTrace(0, 64, frames, nullptr);
  for (USHORT index = 0; index < count; ++index) {
    char storage[sizeof(SYMBOL_INFO) + 1024]{};
    auto *symbol = reinterpret_cast<SYMBOL_INFO *>(storage);
    symbol->SizeOfStruct = sizeof(SYMBOL_INFO); symbol->MaxNameLen = 1023;
    DWORD64 delta = 0; IMAGEHLP_LINE64 line{}; line.SizeOfStruct = sizeof(line);
    DWORD line_delta = 0;
    const auto address = reinterpret_cast<DWORD64>(frames[index]);
    if (SymFromAddr(process, address, &delta, symbol))
      fprintf(stderr, "STACK %u %s+%llu", index, symbol->Name, delta);
    else fprintf(stderr, "STACK %u 0x%llx", index, address);
    if (SymGetLineFromAddr64(process, address, &line_delta, &line))
      fprintf(stderr, " %s:%lu", line.FileName, line.LineNumber);
    fputc('\n', stderr);
  }
  fflush(stderr); _Exit(90);
}
#endif

int main(int argc, char **argv) {
  if (argc != 4 && argc != 5) return 2;
#ifdef _WIN32
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
  _set_error_mode(_OUT_TO_STDERR);
  for (int kind : {_CRT_WARN, _CRT_ERROR, _CRT_ASSERT}) {
    _CrtSetReportMode(kind, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(kind, _CRTDBG_FILE_STDERR);
  }
  std::set_terminate(fatal_stack);
#endif
  fprintf(stderr, "BEGIN_PREPARED_BUDGET_PROBE memory=%s\n", argv[3]);
  if (!strcmp(argv[3], "probe")) {
    pki_metadata metadata{}; uint8_t error[512]{};
    const int status = pki_probe(argv[1], &metadata, error, 512);
    fprintf(stderr, "PROBE status=%d message=%s\n", status, error);
    return status == 0 || status == 3 ? 0 : 3;
  }
  if (!strcmp(argv[3], "encode")) {
    uint8_t rgba[4] = {17, 29, 43, 255};
    for (uint32_t format = 1; format <= 3; ++format) {
      pki_encode_request request{}; pki_encoded_result result{}; uint8_t error[512]{};
      request.width = request.height = 1; request.stride = 4; request.input_bytes = 4;
      request.format = format; request.quality = 90; request.lossless = 1;
      request.memory_budget = 4; request.output_limit = 4096;
      const int status = pki_encode_rgba(rgba, &request, &result, error, 512);
      fprintf(stderr, "ENCODE format=%u status=%d message=%s\n", format, status, error);
      pki_encoded_release(&result);
      if (status != 3) return 3;
    }
    return 0;
  }
  pki_request request{}; pki_result result{}; uint8_t error[512]{};
  request.x = 31; request.y = 73; request.width = request.output_width = 129;
  request.height = request.output_height = 137;
  request.memory_budget = strtoull(argv[3], nullptr, 10);
  const auto decode = argc == 5 ? pki_decode_region : pki_decode_prepared_region;
  const int status = decode(argv[1], argv[2], &request, &result, error, 512);
  fprintf(stderr, "END_PREPARED_BUDGET_PROBE status=%d message=%s pixels=%p\n",
      status, error, result.pixels);
  pki_release(&result);
  return status == 3 ? 0 : 3;
}
