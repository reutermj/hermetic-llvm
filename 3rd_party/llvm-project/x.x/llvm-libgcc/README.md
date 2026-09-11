# llvm-libgcc: a version-matched libgcc_s.so.1

This package builds `libgcc_s.so.1` out of libunwind and the compiler-rt
builtins, exporting the symbol versions of the `libgcc_s` that ships with the
GCC release selected through `//constraints/cxxstdlib`. It is enabled with
`--@llvm//config:experimental_use_llvm_libgcc=True` and replaces `libunwind.so.1`
as the dynamic unwinder of Linux glibc targets.

This document is the context and the walkthrough of the method. The user-facing
summary is the "Unwinder: libunwind or libgcc_s" section of the top-level
README.

## Why

The toolchain is a zero-sysroot cross toolchain: every target-specific library
is built from source and linked in place of a distribution's copy. For the C++
runtime that model is complete. glibc is selected by version
(`//constraints/libc:gnu.<version>`), libstdc++ by GCC version
(`//constraints/cxxstdlib:libstdcxx.<version>`), and an executable's
`GLIBC_*`, `GLIBCXX_*` and `CXXABI_*` requirements track those choices. The
unwinder was the exception.

Dynamically linked binaries depended on `libunwind.so.1`, where every GCC-built
binary and every distribution library depends on `libgcc_s.so.1`. Both export
the same `_Unwind_*` ABI, but with two differences that matter once a binary
meets libraries it did not build itself:

- **Symbol versions.** A GCC-built object imports `_Unwind_Resume@GCC_3.0`,
  `__udivti3@GCC_3.0`, `_Unwind_GetIPInfo@GCC_4.2.0`, and so on. The toolchain's
  `libunwind.so.1` defined no versions at all, so a prebuilt distribution
  library could not be linked against it (14 unresolved versioned references
  for a trivial C++ shared object built with the host `g++`).
- **The name.** glibc itself and third-party libraries name `libgcc_s.so.1`
  as their dependency. When such a library was loaded next to a binary built
  with this toolchain, the dynamic loader silently satisfied that dependency
  from the host: `LD_DEBUG=libs` showed `/lib/x86_64-linux-gnu/libgcc_s.so.1`
  loaded alongside the hermetic `libunwind.so.1`, two unwinders in one process
  and a hole in the hermeticity that looked like success. This is the
  "cross-talk" scenario upstream llvm-libgcc was created to remove.

The `-lgcc_s` stub (`//config:experimental_stub_libgcc`) only makes the
linker flag a no-op; it provides no library.

## What upstream llvm-libgcc does

`llvm-project/llvm-libgcc/CMakeLists.txt` builds libunwind as a shared library
with the compiler-rt builtins linked in (`COMPILER_RT_BUILTINS_HIDE_SYMBOLS=OFF`
so they are exported), applies a version script, and installs
`libgcc_s.so.1` as a symlink to `libunwind.so.1`. Its version script,
`gcc_s.ver.in`, is a hand-maintained snapshot: the intersection of the symbols
of compiler-rt, libunwind and one particular `libgcc_s.so.1` at generation time
(`generate_version_script.py`). It stops at `GCC_7.0.0` (`GCC_4.8.0` on x86),
covers x86_64, i386, aarch64 and arm-gnueabihf, and is the same for every GCC
release.

That was the first implementation here, and it exposed two properties of the
template worth knowing when reading upstream: it repeats version nodes under
different `#if` blocks (`GCC_3.0` five times for x86_64), which lld turns into
one version definition per repetition, and it leaves unlisted symbols exported
without a version. Both were corrected locally before the approach was replaced.

The snapshot cannot be version-matched. `GCC_12.0.0` (the `_Float16` helpers),
`GCC_13.0.0` (`__bf16`) and `GCC_4.7.0` are missing, so a library built with
GCC 12 that imports `__extendhfsf2@GCC_12.0.0` fails to load, and there is no
way to pair a libstdc++ 8 platform with a `libgcc_s` of the same era.

## How GCC builds the map for libgcc_s.so

GCC already has the machinery; the implementation reproduces it. From
`libgcc/Makefile.in`:

```make
libgcc-std.ver: $(srcdir)/libgcc-std.ver.in
	sed -e 's/__PFX__/$(LIBGCC_VER_GNU_PREFIX)/g' \
	    -e 's/__FIXPTPFX__/$(LIBGCC_VER_FIXEDPOINT_GNU_PREFIX)/g' < $< > $@

libgcc.map.in: $(SHLIB_MAPFILES)
	{ cat $(SHLIB_MAPFILES) \
	    | sed -e '/^[ 	]*#/d' \
		  -e 's/^%\(if\|else\|elif\|endif\|define\)/#\1/' \
	    | $(gcc_compile_bare) -E -xassembler-with-cpp -; \
	} > tmp-$@

libgcc.map: $(SHLIB_MKMAP) libgcc.map.in $(libgcc-s-objects)
	{ $(NM) $(SHLIB_NM_FLAGS) $(libgcc-s-objects); echo %%; \
	  cat libgcc.map.in; \
	} | $(AWK) -f $(SHLIB_MKMAP) $(SHLIB_MKMAP_OPTS) > tmp-$@
```

`SHLIB_MAPFILES` is assembled by the `tmake_file` fragments `libgcc/config.host`
selects for the target:

| Fragment | Effect | Selected for |
| --- | --- | --- |
| `t-slibgcc-elf-ver` | `SHLIB_MAPFILES = libgcc-std.ver` | every `*-*-linux*` |
| `t-linux` | `+= config/libgcc-glibc.ver` | every `*-*-linux*` |
| `i386/t-linux` | `= libgcc-std.ver config/i386/libgcc-glibc.ver` (replaces the two above) | x86 |
| `aarch64/t-softfp` | `+= config/aarch64/libgcc-softfp.ver` | aarch64, GCC 11 and later |

`libgcc-std.ver.in` carries no conditionals, only `%inherit` lines. The
target fragments carry the `%ifdef __x86_64__`-style conditionals, all on
predefined target macros, which is why a plain `clang -E` with the target
triple is enough. The prefixes are `__` for both targets here
(`t-fixedpoint-gnu-prefix` changes one of them for ARM), and `SHLIB_NM_FLAGS`
is `-pg`.

`mkmap-symver.awk` is the important part. It reads `nm` output first, then the
map, and:

- keeps only the symbols `nm` found in the objects (so the map is an
  intersection with what the library defines),
- resolves `%inherit CHILD PARENT` into `} PARENT;` dependencies,
- applies `%exclude { ... }` (symbols glibc historically re-exported are
  excluded from earlier nodes and re-listed under `GLIBC_2.0`),
- drops a version node that ends up with no symbols and re-parents its
  children onto its parent,
- prints `local: *;` in the base node.

Everything the first implementation did by hand, GCC's awk does, with the
exact semantics of the release the script belongs to.

## The implementation

The GCC side lives in the per-version `@gcc_<version>` repositories; the LLVM
side in this overlay package. The `@gcc` trampoline selects the repository by
`//constraints/cxxstdlib`, exactly as it does for libstdc++, with
`DEFAULT_GCC_VERSION` when no constraint is set.

### 1. Fetch the inputs

`3rd_party/gcc/extension/gcc.bzl` extracts GCC archives sparsely. The map
inputs were added to `_GCC_ARCHIVE_INCLUDES`: `libgcc/libgcc-std.ver.in`,
`libgcc/mkmap-symver.awk`, `libgcc/config/libgcc-glibc.ver`,
`libgcc/config/i386/libgcc-glibc.ver`, and, for GCC 11 and later
(`libgcc_has_aarch64_softfp_ver` in `version.bzl`),
`libgcc/config/aarch64/libgcc-softfp.ver`. Archive checksums are unchanged;
only the extraction filter grew.

### 2. `@gcc//:libgcc.map.in`

`3rd_party/gcc/libgcc/libgcc_map_in.bzl` is the `libgcc-std.ver` and
`libgcc.map.in` recipes: the prefix substitution, the concatenation with the
target's mapfiles, the comment strip and `%if`-to-`#if` rewrite (spelled as
five portable `sed` expressions instead of GNU `\|`), then the preprocessor.
The preprocessor run uses `cc_common` with the `preprocess_assemble` action,
like the libstdc++ version script rule, so the command line carries the
toolchain's target and sysroot flags and the `__x86_64__` / `__aarch64__`
conditionals resolve for the platform being built.

`gcc.BUILD.bazel` instantiates it once per repository with the `SHLIB_MAPFILES`
of the table above as a `select` on the target CPU. The trampoline exposes it
and `libgcc/mkmap-symver.awk` as `@gcc//:libgcc.map.in` and
`@gcc//:libgcc_mkmap_symver`.

### 3. `libgcc.map`: the awk, fed with our objects

`libgcc_map.bzl` here is the `libgcc.map` recipe. Where GCC passes
`$(libgcc-s-objects)` to `nm`, this rule takes the `CcInfo` of
`//libunwind` and `//compiler-rt:builtins`, collects their archives from the
linking context, and runs `llvm-nm -p -g` on them. Because the rule is a
dependency of the shared library and sits under the same configuration
transition, these are the very objects that get linked; nothing is compiled
twice. The output of `awk -f mkmap-symver.awk` is the map GCC would produce
for a libgcc made of these objects: `GCC_12.0.0` contains the five `_Float16`
helpers compiler-rt implements, `GCC_4.7.0` disappears because compiler-rt has
no `__clrsb*`, and aarch64 gets `GLIBC_2.0` as its base node with
`__register_frame@@GLIBC_2.0`, as the distribution library has.

One post-pass follows the awk, for a reason found empirically. GCC's
`config/i386/libgcc-glibc.ver` lists `__divtc3`, `__multc3`, `__powitf2`,
`__gttf2`, `__lttf2` and `__netf2` under two nodes each, an older one kept for
binary compatibility and the corrected one ("We corrected the default version
to GCC_4.3.0"). Both GNU ld and lld assign a symbol to the *first* node that
names it (lld warns "attempt to reassign symbol"). GCC still ends up with
`__divtc3@@GCC_4.3.0` because its objects also define the old version as a
`.symver` alias, which claims the earlier entry. compiler-rt has no such
aliases, so the pass keeps only the last entry of each symbol, its intended
default. The result matches the distribution library symbol for symbol.

### 4. `libgcc_s.so.1`

`cc_runtime_stage1_libgcc_shared_library` in
`toolchain/runtimes/cc_runtime_shared_library.bzl` is the stage1 shared
library builder with one extra setting: `//config:compiler_rt_builtins_hide_symbols`
off, which appends `-fvisibility=default` to the builtins (the Bazel spelling
of `COMPILER_RT_BUILTINS_HIDE_SYMBOLS=OFF`). Hidden symbols can never be
exported, whatever the version script says, so this is a real recompile of
the builtins for this library only; the archive every binary links statically
is unchanged.

The library links `//libunwind` and `//compiler-rt:builtins` with
`-Wl,--version-script=libgcc.map`, `-lm` (as upstream), and
`-Wl,-soname,libgcc_s.so.1`. The soname is the one deliberate departure from
upstream, which keeps `libunwind.so.1` and adds symlinks: a binary should
record the dependency GCC-built binaries record. lld's default
`--no-undefined-version` is left on, so a map naming a symbol the objects do
not define is a build error rather than a silent gap.

### 5. Wiring

`//runtimes/unwindlib` is the unwinder runtime group, next to
`//runtimes/cxxstdlib`: its `unwinder.shared` alias resolves to
`libgcc_s.shared` when `//config:experimental_use_llvm_libgcc` is set and to
`libunwind.shared` otherwise. On Bazel 9 it is wrapped as
`unwinder_shared_runtime`, the shared unwinder that the C++ runtimes toolchain
(`//runtimes/cxxstdlib:cc_runtimes`, see `//runtimes:cc_runtimes.bzl`) hands
to every C++ target whose platform links the C++ runtime dynamically:
libstdc++ platforms always, libc++ platforms with the
`//constraints/cxxstdlib/linkage:dynamic` constraint. Platforms that link
libc++ statically keep the static libunwind. On Bazel 8, where the
`cc_toolchain` `dynamic_runtime_lib` attribute is still in charge, the alias is
listed there and the linking mode of the consuming target decides. Either way
`-lgcc`, `-lgcc_eh` and `-lgcc_s` keep resolving to the empty stubs in
`unwindlib_library_search_directory`, so no link acquires a `libgcc_s.so.1`
dependency that rules_cc does not also place in runfiles with an rpath.
`libstdc++.so.6` and `libc++abi.so.1` only import `_Unwind_*` and carry no
unwinder `NEEDED` entry of their own, so they did not need relinking.

### 6. Tests

`//runtimes/libunwind/tests` builds `libgcc_s.so.1` for the latest patch
release of every GCC major on x86_64 and aarch64 (libgcc's version scripts
only change between majors) and checks each against expectations derived from
the version nodes of that release (`libgcc_s_expectations.bzl`): the soname,
one definition per version, the versions and versioned symbols the release
must have, the versions it must not have yet (`GCC_12.0.0` before GCC 12,
`GCC_11.0` on aarch64 before GCC 11), and that every exported symbol carries a
version. A throw-and-catch binary, the same binary catching across a DSO
boundary through a `cc_shared_library` in `dynamic_deps`, and the shared
objects of both `cc_binary(linkshared = True)` and `cc_shared_library` are
built for libstdc++ and for dynamically linked libc++ on both architectures,
inspected for their `NEEDED` entries, and run on the host's architecture. A
binary on the default (static libc++) platform is checked to depend on
neither `libgcc_s.so.1` nor `libunwind.so.1`, and a binary over a chain of
`cc_library` dependencies is checked, under every `linkstatic` and
`--dynamic_mode` setting, to link those statically while depending on
`libgcc_s.so.1`.

## What it produces

Measured on the x86_64 build for GCC 12.5 against Debian 12's
`libgcc_s.so.1`, which is GCC 12:

| | Count |
| --- | --- |
| Symbols exported by both | 127, all with the identical default version |
| Only in the distribution library | 22: `__clrsb*`, `__register_frame_info*`, `__emutls_register_common`, `__negtf2`, and `_Float16` helpers compiler-rt lacks (`__divhc3`, `__fixhfti`, ...) |
| Only in ours | 64 32-bit helpers (`__divdi3`, `__adddf3`, ...) compiler-rt builds for every target; 64-bit libgcc compiles the same sources as their `ti` counterparts |

Selecting a libstdc++ platform selects the matching library: GCC 8.5 and 11.5
produce a `libgcc_s.so.1` whose newest node is `GCC_7.0.0`, GCC 17 one with
`GCC_12.0.0` and `GCC_13.0.0`. A shared object built by the host `g++`
(`NEEDED libgcc_s.so.1`, importing `_Unwind_Resume@GCC_3.0`) links into a
toolchain binary, runs, and throws across the boundary, with
`LD_DEBUG=libs` showing only the hermetic `libgcc_s.so.1` loaded.

An executable itself needs very little of this: its only import from
`libgcc_s.so.1` is `_Unwind_Resume@GCC_3.0`, since the arithmetic builtins are
linked statically from compiler-rt. The version matching matters for the
libraries an executable is combined with.

## Limits and follow-ups

- x86_64 and aarch64 glibc only: those are the targets `libgcc.map.in`
  declares mapfiles for. Adding a target means reading its `config.host`
  entry and fragments and extending the `select`; `libgcc_s.shared` is
  `target_compatible_with` the same set.
- `__cpu_indicator_init` and `__cpu_model` are named by the map but declared
  hidden in compiler-rt (`lib/builtins/cpu_model/x86.c`), so they stay local.
  GCC exports them only as a non-default version for binaries linked against
  GCC 4.8.
- compiler-rt has no compatibility `.symver` aliases, so the older versions of
  the six corrected symbols (`__divtc3@GCC_4.0.0`, `__gttf2@GCC_3.0`, ...)
  are absent; only their defaults exist.
- `config/aarch64/libgcc-softfp.ver` upstream names its node `GCC_11.0` but
  inherits `GCC_13.0.0` from `GCC_11.0.0`, which makes `GCC_13.0.0` a second
  base node. The awk reproduces what GCC itself produces from that file.
- `libgcc.a` and `libgcc_eh.a` are not provided, and `-lgcc_s` still resolves
  to the stub rather than to this library.
- Whether a target links the unwinder dynamically at all is a property of
  the target platform, not of the target: with the C++ runtimes toolchain the
  runtimes are dependencies rules_cc adds to every C++ target, and each is
  linked the only way it is provided. A libc++ platform without the
  `linkage:dynamic` constraint never depends on `libgcc_s.so.1`. On Bazel 8
  the `cc_toolchain` runtime libraries follow the linking mode of the
  consuming target instead, so `cc_shared_library` and the default
  `linkstatic` keep the static libunwind there.
- The version nodes and symbol order in the map follow awk's array iteration
  order, as in GCC; they are deterministic for a given awk but can differ
  between execution platforms.

## Inspecting the result

```sh
# The map for the GCC version a platform selects.
bazel build --platforms=... @llvm-project//llvm-libgcc:libgcc.map
# The library, then its versions, parents and exports.
bazel build --platforms=... //runtimes/unwindlib:libgcc_s.shared
llvm-readelf --version-info bazel-bin/.../libgcc_s.so.1
llvm-nm -D --defined-only --with-symbol-versions bazel-bin/.../libgcc_s.so.1
# What a binary actually requires from it.
llvm-readelf --version-info bazel-bin/app | sed -n '/Version needs/,$p'
```
