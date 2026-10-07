#include <cstdio>
#include <type_traits>
#include <crtdbg.h>
#include "../src/image_core.cpp"

int main() {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
  _set_error_mode(_OUT_TO_STDERR);
  std::set_terminate([] { fputs("EXHAUSTED_STL unexpected terminate\n", stderr); fflush(stderr); _Exit(90); });
  static_assert(_ITERATOR_DEBUG_LEVEL == 0, "Test the DLL's exact Debug iterator mode");
  Budget budget(32ULL * 1024 * 1024, 0, nullptr, "");
  ActiveBudget active(&budget);
  budget.reserve(budget.limit);
  // All these real core containers must construct/move at an exhausted budget
  // without an implicit debugger proxy allocation inside a noexcept function.
  Info metadata;
  std::array<ProfileBytes, 256> chunks;
  ProfileBytes empty, moved(std::move(empty));
  Info moved_metadata(std::move(metadata));
  if (budget.used != budget.limit) return 2;
  try {
    chunks[1].assign(1, 17);
    return 3;
  } catch (const std::bad_alloc &) {
    fprintf(stderr, "EXHAUSTED_STL default/move=zero-alloc capacity=bad_alloc caught\n");
  }
  budget.used = 0;
  return 0;
}
