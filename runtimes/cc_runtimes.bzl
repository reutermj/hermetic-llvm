"""Support for the rules_cc C++ runtimes toolchain.

rules_cc resolves a second toolchain type next to the C++ toolchain,
`@bazel_tools//tools/cpp:cc_runtimes_toolchain_type`. Its `ToolchainInfo`
carries a `cc_runtimes_info` value with two fields: `runtimes`, a list of
targets providing `CcInfo`, and `copts`. rules_cc adds those targets as
ordinary dependencies of every `cc_library`, `cc_binary`, `cc_test`,
`cc_import` and `cc_shared_library`, and prepends `copts` to every compilation.

This changes how a runtime's linkage is chosen. With the `cc_toolchain`
attributes `static_runtime_lib` and `dynamic_runtime_lib`, rules_cc picks one
of the two sets from the linking mode of the consuming rule, which only
`cc_binary` (`linkstatic`) and `--dynamic_mode` influence; `cc_shared_library`
always links the static set. With the runtimes toolchain each runtime is a
`CcInfo` dependency, so the choice follows what the runtime target provides: a
runtime exposing only a shared library is always linked dynamically (libstdc++),
one exposing both follows the usual static/dynamic rules (libc++). The
toolchain is resolved per target platform, so the policy is global and
platform-driven rather than per target.

The toolchain type only exists in Bazel >= 9 and is only consulted by the
Starlark C++ rules (Bazel 8 keeps its native rules), hence
`bazel_supports_cc_runtimes_toolchain()`: when it is false, the toolchain keeps
supplying the Linux C++ runtimes through `static_runtime_lib` and
`dynamic_runtime_lib`.
"""

load("@bazel_features//:features.bzl", "bazel_features")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

CC_RUNTIMES_TOOLCHAIN_TYPE = "@bazel_tools//tools/cpp:cc_runtimes_toolchain_type"

def bazel_supports_cc_runtimes_toolchain():
    """Returns whether the running Bazel resolves the C++ runtimes toolchain type.

    The toolchain type was added to @bazel_tools together with the move of the
    C++ rules into rules_cc for Bazel 9, and only those Starlark rules consult
    it, so "cc_common lives in rules_cc" is the condition that matters.
    """
    return bazel_features.cc.cc_common_is_in_rules_cc

CcRuntimesInfo = provider(
    doc = "Value of the cc_runtimes_info field of the C++ runtimes toolchain's ToolchainInfo.",
    fields = {
        "runtimes": "List of targets providing CcInfo that rules_cc adds as dependencies of every C++ target.",
        "copts": "List of compiler options that rules_cc prepends to every C++ compilation.",
    },
)

def _cc_runtimes_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            cc_runtimes_info = CcRuntimesInfo(
                runtimes = ctx.attr.runtimes,
                copts = ctx.attr.copts,
            ),
        ),
    ]

cc_runtimes_toolchain = rule(
    implementation = _cc_runtimes_toolchain_impl,
    doc = "Implementation of `@bazel_tools//tools/cpp:cc_runtimes_toolchain_type`.",
    attrs = {
        "runtimes": attr.label_list(
            providers = [CcInfo],
            doc = "Targets linked into every C++ target, in link order.",
        ),
        "copts": attr.string_list(
            doc = "Compiler options prepended to every C++ compilation.",
        ),
    },
)

def _library_file(ctx, attr_name, matches):
    files = [f for f in getattr(ctx.files, attr_name) if matches(f.basename)]
    if not files:
        return None
    if len(files) != 1:
        fail("{}: {} must provide exactly one library, got {}".format(
            ctx.label,
            attr_name,
            [f.path for f in files],
        ))
    return files[0]

def _is_static_library(basename):
    return basename.endswith(".a") or basename.endswith(".lib")

def _is_shared_library(basename):
    return basename.endswith(".so") or ".so." in basename or basename.endswith(".dylib") or basename.endswith(".dll")

def _cc_runtime_import_impl(ctx):
    static_library = _library_file(ctx, "static_library", _is_static_library)
    shared_library = _library_file(ctx, "shared_library", _is_shared_library)
    if static_library == None and shared_library == None:
        fail("{}: at least one of static_library and shared_library is required".format(ctx.label))

    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    library = cc_common.create_library_to_link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        static_library = static_library,
        dynamic_library = shared_library,
        # Place the shared library directly in the solib directory under its
        # own name (its soname) instead of a per-target mangled subdirectory,
        # so every runtime shares the single solib rpath entry.
        dynamic_library_symlink_path = shared_library.basename if shared_library else "",
    )
    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset([library]),
    )
    return [
        DefaultInfo(files = depset([f for f in [static_library, shared_library] if f != None])),
        CcInfo(linking_context = cc_common.create_linking_context(linker_inputs = depset([linker_input]))),
    ]

cc_runtime_import = rule(
    implementation = _cc_runtime_import_impl,
    doc = """Exposes prebuilt runtime libraries as a `CcInfo` dependency.

Like `cc_import`, but this rule does not itself consult the C++ runtimes
toolchain, so its targets can be listed in one without creating a dependency
cycle. The static library, when given, serves static links; the shared library
serves dynamic links, or every link when no static library is given.""",
    attrs = {
        "static_library": attr.label(
            allow_files = True,
            doc = "Static archive of the runtime (a `.a`/`.lib` file).",
        ),
        "shared_library": attr.label(
            allow_files = True,
            doc = "Shared library of the runtime (a `.so`, versioned `.so.N`, `.dylib` or `.dll` file).",
        ),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)
