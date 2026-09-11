"""Link tests for the llvm-libgcc unwinder.

With --//config:experimental_use_llvm_libgcc, the dynamic unwinder is
libgcc_s.so.1 instead of libunwind.so.1. Whether a link uses the dynamic
unwinder at all is decided by the C++ runtimes toolchain from the target
platform (see //runtimes:cc_runtimes.bzl and //runtimes/unwindlib): always for
libstdc++, and for libc++ when the platform carries
//constraints/cxxstdlib/linkage:dynamic. That toolchain only exists on
Bazel >= 9, hence the macro.
"""

load("@bazel_lib//lib:transitions.bzl", "platform_transition_binary", "platform_transition_filegroup")
load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("@with_cfg.bzl", "with_cfg")
load("//3rd_party/gcc:version.bzl", "DEFAULT_GCC_VERSION", "libstdcxx_constraint_value")
load("//constraints/libc:libc_versions.bzl", "default_libc")
load("//runtimes:cc_runtimes.bzl", "bazel_supports_cc_runtimes_toolchain")

llvm_libgcc_cc_binary, _llvm_libgcc_cc_binary_internal = with_cfg(cc_binary).set(
    Label("//config:experimental_use_llvm_libgcc"),
    True,
).build()

llvm_libgcc_cc_shared_library, _llvm_libgcc_cc_shared_library_internal = with_cfg(
    cc_shared_library,
    extra_providers = [CcSharedLibraryInfo],
).set(
    Label("//config:experimental_use_llvm_libgcc"),
    True,
).build()

# --dynamic_mode=fully on top of the flag: the mode must not change what is
# linked statically either.
llvm_libgcc_dynamic_mode_fully_cc_binary, _llvm_libgcc_dynamic_mode_fully_cc_binary_internal = with_cfg(cc_binary).set(
    Label("//config:experimental_use_llvm_libgcc"),
    True,
).set(
    "dynamic_mode",
    "fully",
).build()

_ARCHS = [
    "x86_64",
    "aarch64",
]

_LINUX_ONLY = select({
    "@platforms//os:linux": [],
    "//conditions:default": ["@platforms//:incompatible"],
})

# (name, is_executable): the targets that must depend on libgcc_s.so.1 when the
# platform links the C++ runtime dynamically.
_CASES = [
    # The exception unwinds within the binary, through libgcc_s.so.1.
    ("throw_and_catch", True),
    # The genuinely cross-DSO case: thrown in libthrower_cc_shared.so, caught
    # in the binary.
    ("cross_dso_exception_dynamic_deps", True),
    # Shared objects from both rules get their unwinder from libgcc_s.so.1
    # instead of carrying one of their own.
    ("libthrower_shared.so", False),
    ("libthrower_cc_shared", False),
]

def libgcc_s_link_tests():
    if not bazel_supports_cc_runtimes_toolchain():
        return

    platforms = {}
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
        platforms[("libcxx_dynamic", arch)] = ":linux_{}_libcxx_dynamic".format(arch)
        platforms[("libstdcxx", arch)] = "//runtimes/libstdcxx/tests:linux_{}_{}".format(
            arch,
            libstdcxx_constraint_value(DEFAULT_GCC_VERSION),
        )

    cc_library(
        name = "thrower",
        srcs = ["thrower.cc"],
        hdrs = ["thrower.h"],
    )

    llvm_libgcc_cc_binary(
        name = "throw_and_catch",
        srcs = ["throw_and_catch.cc"],
        target_compatible_with = _LINUX_ONLY,
        deps = [":thrower"],
    )

    llvm_libgcc_cc_binary(
        name = "libthrower_shared.so",
        srcs = ["thrower.cc"],
        linkshared = True,
        target_compatible_with = _LINUX_ONLY,
        deps = [":thrower"],
    )

    llvm_libgcc_cc_shared_library(
        name = "libthrower_cc_shared",
        shared_lib_name = "libthrower_cc_shared.so",
        target_compatible_with = _LINUX_ONLY,
        deps = [":thrower"],
    )

    llvm_libgcc_cc_binary(
        name = "cross_dso_exception_dynamic_deps",
        srcs = ["throw_and_catch.cc"],
        dynamic_deps = [":libthrower_cc_shared"],
        target_compatible_with = _LINUX_ONLY,
        deps = [":thrower"],
    )

    # Only the C++ runtime is dynamic: direct and transitive cc_library
    # dependencies are linked statically whatever linkstatic and
    # --dynamic_mode say. The binary depends on :mid, which depends on
    # :thrower; both must end up inside the artifact.
    cc_library(
        name = "mid",
        srcs = ["mid.cc"],
        hdrs = ["mid.h"],
        deps = [":thrower"],
    )

    llvm_libgcc_cc_binary(
        name = "static_deps",
        srcs = ["static_deps_main.cc"],
        target_compatible_with = _LINUX_ONLY,
        deps = [":mid"],
    )

    llvm_libgcc_cc_binary(
        name = "static_deps_linkstatic_false",
        srcs = ["static_deps_main.cc"],
        linkstatic = False,
        target_compatible_with = _LINUX_ONLY,
        deps = [":mid"],
    )

    llvm_libgcc_dynamic_mode_fully_cc_binary(
        name = "static_deps_dynamic_mode_fully",
        srcs = ["static_deps_main.cc"],
        linkstatic = False,
        target_compatible_with = _LINUX_ONLY,
        deps = [":mid"],
    )

    llvm_libgcc_cc_shared_library(
        name = "libstatic_deps_cc_shared",
        shared_lib_name = "libstatic_deps_cc_shared.so",
        target_compatible_with = _LINUX_ONLY,
        deps = [":mid"],
    )

    for (target, is_executable) in [
        ("static_deps", True),
        ("static_deps_linkstatic_false", True),
        ("static_deps_dynamic_mode_fully", True),
        ("libstatic_deps_cc_shared", False),
    ]:
        for arch in _ARCHS:
            transitioned = "{}_libstdcxx_{}".format(target, arch)
            if is_executable:
                platform_transition_binary(
                    name = transitioned,
                    binary = ":" + target,
                    target_platform = platforms[("libstdcxx", arch)],
                )
            else:
                platform_transition_filegroup(
                    name = transitioned,
                    srcs = [":" + target],
                    target_platform = platforms[("libstdcxx", arch)],
                )

            sh_test(
                name = "static_deps_{}_test".format(transitioned),
                srcs = ["static_deps_test.sh"],
                args = [
                    "$(rootpath @llvm//tools:llvm-readelf)",
                    "$(rootpath :{})".format(transitioned),
                ] + (["run"] if is_executable else []),
                data = [
                    ":" + transitioned,
                    "@llvm//tools:llvm-readelf",
                ],
                target_compatible_with = [
                    "@platforms//os:linux",
                ] + ([
                    "@platforms//cpu:" + arch,
                ] if is_executable else []),
            )

    # The default platform links libc++ statically, so nothing depends on
    # libgcc_s.so.1 (or libunwind.so.1) even with the flag.
    sh_test(
        name = "static_unwinder_libcxx_test",
        srcs = ["static_cpp_runtime_binary_test.sh"],
        args = [
            "$(rootpath @llvm//tools:llvm-readelf)",
            "$(rootpath :throw_and_catch)",
            "libgcc_s.so.1",
            "libunwind.so.1",
        ],
        data = [
            ":throw_and_catch",
            "@llvm//tools:llvm-readelf",
        ],
        target_compatible_with = _LINUX_ONLY,
    )

    for (target, is_executable) in _CASES:
        for (cxxstdlib, arch), platform in platforms.items():
            transitioned = "{}_{}_{}".format(target, cxxstdlib, arch)
            if is_executable:
                platform_transition_binary(
                    name = transitioned,
                    binary = ":" + target,
                    target_platform = platform,
                )
            else:
                platform_transition_filegroup(
                    name = transitioned,
                    srcs = [":" + target],
                    target_platform = platform,
                )

            # Executables built for the host's architecture are also run.
            sh_test(
                name = "libgcc_s_{}_test".format(transitioned),
                srcs = ["libgcc_s_link_test.sh" if is_executable else "libgcc_s_shared_object_test.sh"],
                args = [
                    "$(rootpath @llvm//tools:llvm-readelf)",
                    "$(rootpath :{})".format(transitioned),
                ] + (["run"] if is_executable else []),
                data = [
                    ":" + transitioned,
                    "@llvm//tools:llvm-readelf",
                ],
                target_compatible_with = [
                    "@platforms//os:linux",
                ] + ([
                    "@platforms//cpu:" + arch,
                ] if is_executable else []),
            )
