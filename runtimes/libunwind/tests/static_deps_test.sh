#!/usr/bin/env bash
# Checks that only the C++ runtime is linked dynamically: the ELF depends on
# libgcc_s.so.1 but on no shared object of its cc_library dependencies, and it
# defines the functions of its direct and transitive cc_library dependencies
# itself. Optionally runs it.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <readelf> <elf> [run]" >&2
  exit 2
fi

readelf="$1"
elf="$2"
run="${3:-}"

if [[ ! -x "$readelf" ]]; then
  echo "FAIL: readelf $readelf is not executable" >&2
  exit 1
fi

status=0
needed="$("$readelf" -d "$elf" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
if ! grep -qxF "libgcc_s.so.1" <<<"$needed"; then
  echo "FAIL: $elf does not depend on libgcc_s.so.1" >&2
  status=1
fi
for soname in libunwind.so.1 libmid.so libthrower.so; do
  if grep -qxF "$soname" <<<"$needed"; then
    echo "FAIL: $elf depends on $soname" >&2
    status=1
  fi
done

# Demangled FUNC symbols that are defined (not UND) in the symbol tables.
defined="$("$readelf" --syms --demangle "$elf" | awk '$4 == "FUNC" && $7 != "UND" { print $8 }')"
for symbol in "mid_function()" "throw_from_shared_library()"; do
  if ! grep -qxF "$symbol" <<<"$defined"; then
    echo "FAIL: $elf does not define $symbol; it is not linked statically" >&2
    status=1
  fi
done

if [[ $status -ne 0 ]]; then
  echo "NEEDED:" >&2
  echo "$needed" >&2
  exit 1
fi

if [[ "$run" == "run" ]]; then
  output="$("$elf")"
  [[ "$output" == "exception caught" ]]
fi

echo "OK: $elf"
