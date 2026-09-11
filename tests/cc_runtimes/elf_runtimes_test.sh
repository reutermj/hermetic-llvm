#!/usr/bin/env bash
# Checks how an ELF file links the C++ runtimes.
#
# Environment:
#   READELF              llvm-readelf
#   ELF                  the executable or shared object to inspect
#   EXPECTED_NEEDED      space-separated DT_NEEDED sonames that must be present
#   FORBIDDEN_NEEDED     space-separated DT_NEEDED sonames that must be absent
#   EXPECTED_UNDEFINED   space-separated dynamic symbols that must be undefined
#                        (resolved from a shared runtime at load time)
#   FORBIDDEN_UNDEFINED  space-separated dynamic symbols that must not be
#                        undefined (satisfied by a statically linked runtime)
#   RUN                  when "1", execute ELF and expect "exception caught"
set -euo pipefail

readelf="${READELF:?}"
elf="${ELF:?}"

if [[ ! -x "$readelf" ]]; then
  echo "FAIL: readelf $readelf is not executable" >&2
  exit 1
fi
if [[ ! -e "$elf" ]]; then
  echo "FAIL: $elf does not exist" >&2
  exit 1
fi

needed="$("$readelf" -d "$elf" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
undefined="$("$readelf" --dyn-syms "$elf" | awk '$7 == "UND" { sub(/@.*/, "", $8); print $8 }')"

status=0
for soname in ${EXPECTED_NEEDED:-}; do
  if ! grep -qxF "$soname" <<<"$needed"; then
    echo "FAIL: $elf lacks NEEDED $soname" >&2
    status=1
  fi
done
for soname in ${FORBIDDEN_NEEDED:-}; do
  if grep -qxF "$soname" <<<"$needed"; then
    echo "FAIL: $elf has NEEDED $soname" >&2
    status=1
  fi
done
for symbol in ${EXPECTED_UNDEFINED:-}; do
  if ! grep -qxF "$symbol" <<<"$undefined"; then
    echo "FAIL: $elf does not import $symbol" >&2
    status=1
  fi
done
for symbol in ${FORBIDDEN_UNDEFINED:-}; do
  if grep -qxF "$symbol" <<<"$undefined"; then
    echo "FAIL: $elf imports $symbol instead of linking it statically" >&2
    status=1
  fi
done

if [[ $status -ne 0 ]]; then
  echo "NEEDED:" >&2
  echo "$needed" >&2
  exit 1
fi

if [[ "${RUN:-0}" == "1" ]]; then
  output="$("$elf")"
  if [[ "$output" != "exception caught: thrown" ]]; then
    echo "FAIL: unexpected output from $elf: $output" >&2
    exit 1
  fi
fi

echo "OK: $elf"
