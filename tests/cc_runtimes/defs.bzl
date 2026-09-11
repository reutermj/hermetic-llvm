"""Tests for the C++ runtimes toolchain (see //runtimes:cc_runtimes.bzl).

Declared through a macro because the runtimes toolchain, and therefore the
behaviour under test, only exists on Bazel >= 9.
"""

load("@bazel_lib//lib:transitions.bzl", "platform_transition_binary", "platform_transition_filegroup")
load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("//3rd_party/gcc:version.bzl", "DEFAULT_GCC_VERSION", "libstdcxx_constraint_value")
load("//constraints/libc:libc_versions.bzl", "default_libc")
load("//runtimes:cc_runtimes.bzl", "bazel_supports_cc_runtimes_toolchain")

_ARCHS = [
    "x86_64",
    "aarch64",
]

_LIBSTDCXX = "libstdcxx"
_LIBCXX = "libcxx"
_LIBCXX_DYNAMIC = "libcxx_dynamic"

# Target platforms per C++ standard library. libstdc++ platforms come from the
# libstdc++ test package, libc++ platforms are the repository defaults, and the
# dynamic libc++ platforms are declared by the macro below.
_PLATFORMS = {
    (_LIBSTDCXX, arch): "//runtimes/libstdcxx/tests:linux_{}_{}".format(arch, libstdcxx_constraint_value(DEFAULT_GCC_VERSION))
    for arch in _ARCHS
} | {
    (_LIBCXX, arch): "@llvm//platforms:linux_{}".format(arch)
    for arch in _ARCHS
} | {
    (_LIBCXX_DYNAMIC, arch): ":linux_{}_libcxx_dynamic".format(arch)
    for arch in _ARCHS
}

_LIBSTDCXX_SHARED = "libstdc++.so.6 libunwind.so.1"
_LIBCXX_SHARED = "libc++.so.1 libc++abi.so.1 libunwind.so.1"

# Expected DT_NEEDED entries per C++ standard library. The runtimes toolchain
# exposes libstdc++ (and its unwinder) as shared libraries and libc++ as either
# static archives or shared libraries depending on the platform's
# //constraints/cxxstdlib/linkage, so the linkage is the same for every rule
# and every linkstatic value.
_NEEDED_EXPECTATIONS = {
    _LIBSTDCXX: {
        "EXPECTED_NEEDED": _LIBSTDCXX_SHARED,
        "FORBIDDEN_NEEDED": "libc++.so.1 libc++abi.so.1",
    },
    _LIBCXX: {
        "FORBIDDEN_NEEDED": _LIBSTDCXX_SHARED + " " + _LIBCXX_SHARED,
    },
    _LIBCXX_DYNAMIC: {
        "EXPECTED_NEEDED": _LIBCXX_SHARED,
        "FORBIDDEN_NEEDED": "libstdc++.so.6",
    },
}

# Runtime symbols the target references itself: imported from a shared C++
# runtime, satisfied by the static libc++abi.
_SHARED_RUNTIME_SYMBOLS = {
    "EXPECTED_UNDEFINED": "__cxa_throw __gxx_personality_v0",
}

_SYMBOL_EXPECTATIONS = {
    _LIBSTDCXX: _SHARED_RUNTIME_SYMBOLS,
    _LIBCXX: {
        "FORBIDDEN_UNDEFINED": "__cxa_throw __gxx_personality_v0",
    },
    _LIBCXX_DYNAMIC: _SHARED_RUNTIME_SYMBOLS,
}

# (target, is_executable, check_symbols)
_CASES = [
    # cc_binary with the default linkstatic = True.
    ("throw_and_catch", True, True),
    # cc_binary with linkstatic = False.
    ("throw_and_catch_dynamic", True, True),
    # cc_binary linking the thrower through dynamic_deps: the runtimes must
    # survive the dynamic_deps filtering. The runtime symbols it references may
    # resolve from libthrower.so, which precedes the runtimes on the link line,
    # so only the NEEDED entries are checked.
    ("throw_and_catch_dynamic_deps", True, False),
    # cc_shared_library, which has no linkstatic attribute.
    ("libthrower.so", False, True),
]

def cc_runtimes_tests():
    if not bazel_supports_cc_runtimes_toolchain():
        return

    for arch in _ARCHS:
        native.platform(
            name = "linux_{}_libcxx_dynamic".format(arch),
            constraint_values = [
                "@platforms//cpu:" + arch,
                "@platforms//os:linux",
                "//constraints/cxxstdlib:libcxx",
                "//constraints/cxxstdlib/linkage:dynamic",
                "//constraints/libc:" + default_libc("linux", arch),
            ],
        )

    cc_library(
        name = "thrower",
        srcs = ["thrower.cc"],
        hdrs = ["thrower.h"],
    )

    cc_shared_library(
        name = "libthrower.so",
        shared_lib_name = "libthrower.so",
        deps = [":thrower"],
    )

    cc_binary(
        name = "throw_and_catch",
        srcs = ["main.cc"],
        deps = [":thrower"],
    )

    cc_binary(
        name = "throw_and_catch_dynamic",
        srcs = ["main.cc"],
        linkstatic = False,
        deps = [":thrower"],
    )

    cc_binary(
        name = "throw_and_catch_dynamic_deps",
        srcs = ["main.cc"],
        dynamic_deps = [":libthrower.so"],
        deps = [":thrower"],
    )

    for (target, is_executable, check_symbols) in _CASES:
        for cxxstdlib in [_LIBSTDCXX, _LIBCXX, _LIBCXX_DYNAMIC]:
            for arch in _ARCHS:
                transitioned = "{}_{}_{}".format(target, cxxstdlib, arch)
                if is_executable:
                    platform_transition_binary(
                        name = transitioned,
                        binary = ":" + target,
                        target_platform = _PLATFORMS[(cxxstdlib, arch)],
                    )
                else:
                    platform_transition_filegroup(
                        name = transitioned,
                        srcs = [":" + target],
                        target_platform = _PLATFORMS[(cxxstdlib, arch)],
                    )

                # Run the executables built for the host's architecture; that
                # also checks that the shared runtimes reach runfiles.
                sh_test(
                    name = transitioned + "_test",
                    srcs = ["elf_runtimes_test.sh"],
                    data = [
                        ":" + transitioned,
                        "@llvm//tools:llvm-readelf",
                    ],
                    env = {
                        "ELF": "$(rootpath :{})".format(transitioned),
                        "READELF": "$(rootpath @llvm//tools:llvm-readelf)",
                    } | _NEEDED_EXPECTATIONS[cxxstdlib] | (_SYMBOL_EXPECTATIONS[cxxstdlib] if check_symbols else {}) | ({
                        "RUN": "1",
                    } if is_executable else {}),
                    target_compatible_with = [
                        "@platforms//os:linux",
                    ] + ([
                        "@platforms//cpu:" + arch,
                    ] if is_executable else []),
                )
