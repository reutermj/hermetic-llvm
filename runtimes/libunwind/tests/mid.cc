#include "runtimes/libunwind/tests/mid.h"

#include "runtimes/libunwind/tests/thrower.h"

void mid_function() { throw_from_shared_library(); }
