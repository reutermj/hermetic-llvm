load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_cc//cc/private:graph_node_info.bzl", "GraphNodeInfo")  # buildifier: disable=bzl-visibility
load("@rules_cc//cc/private/rules_impl:cc_shared_library.bzl", "graph_structure_aspect")  # buildifier: disable=bzl-visibility

def _reset_sanitizers_impl(settings, attr):
    return {
        "//command_line_option:copt": settings["//command_line_option:copt"] + attr.copts,
        "//command_line_option:cxxopt": settings["//command_line_option:cxxopt"] + attr.cxxopts,
        "//command_line_option:platforms": str(attr.platform) if attr.platform else settings["//command_line_option:platforms"],
        "@llvm-project//third-party:llvm_enable_zstd": False if attr.disable_zstd else settings["@llvm-project//third-party:llvm_enable_zstd"],
        "//config:ubsan": False,
        "//config:cfi": False,
        "//config:msan": False,
        "//config:dfsan": False,
        "//config:nsan": False,
        "//config:safestack": False,
        "//config:rtsan": False,
        "//config:tysan": False,
        "//config:tsan": False,
        "//config:asan": False,
        "//config:lsan": False,
        "//config:xray": False,
        "//config:host_ubsan": False,
        "//config:host_cfi": False,
        "//config:host_msan": False,
        "//config:host_dfsan": False,
        "//config:host_nsan": False,
        "//config:host_safestack": False,
        "//config:host_rtsan": False,
        "//config:host_tysan": False,
        "//config:host_tsan": False,
        "//config:host_asan": False,
        "//config:host_lsan": False,
        "//config:host_xray": False,

        # we are compiling sanitizers, so we want all runtimes except sanitizers.
        # TODO(cerisier): Should this be exressed with a dedicated stage ?
        "//toolchain:runtime_stage": "complete",
    }

_reset_sanitizers = transition(
    implementation = _reset_sanitizers_impl,
    inputs = [
        "//command_line_option:copt",
        "//command_line_option:cxxopt",
        "//command_line_option:platforms",
        "@llvm-project//third-party:llvm_enable_zstd",
    ],
    outputs = [
        "//command_line_option:copt",
        "//command_line_option:cxxopt",
        "//command_line_option:platforms",
        "@llvm-project//third-party:llvm_enable_zstd",
        "//config:ubsan",
        "//config:cfi",
        "//config:msan",
        "//config:dfsan",
        "//config:nsan",
        "//config:safestack",
        "//config:rtsan",
        "//config:tysan",
        "//config:tsan",
        "//config:asan",
        "//config:lsan",
        "//config:xray",
        "//config:host_ubsan",
        "//config:host_cfi",
        "//config:host_msan",
        "//config:host_dfsan",
        "//config:host_nsan",
        "//config:host_safestack",
        "//config:host_rtsan",
        "//config:host_tysan",
        "//config:host_tsan",
        "//config:host_asan",
        "//config:host_lsan",
        "//config:host_xray",
        "//toolchain:runtime_stage",
    ],
)

def _without_cc_runtimes(cc_info, cc_runtimes):
    """Drops the linker inputs the C++ runtimes toolchain added to the dep.

    The dep is compiled at runtime_stage = complete for its headers, but the
    result is linked into the runtimes themselves (libc++ is added explicitly
    by cc_internal_symbolizer_object), so the runtimes rules_cc adds as
    dependencies of every C++ target on Bazel >= 9 must not come along. The
    toolchain target is evaluated in the dep's configuration, so its list is
    exactly what the dep received. See //runtimes:cc_runtimes.bzl.
    """
    excluded = {runtime.label: True for runtime in cc_runtimes[platform_common.ToolchainInfo].cc_runtimes_info.runtimes}
    if not excluded:
        return cc_info
    linker_inputs = [
        linker_input
        for linker_input in cc_info.linking_context.linker_inputs.to_list()
        if linker_input.owner not in excluded
    ]
    return CcInfo(
        compilation_context = cc_info.compilation_context,
        linking_context = cc_common.create_linking_context(
            linker_inputs = depset(linker_inputs, order = "topological"),
        ),
    )

def _cc_unsanitized_library_impl(ctx):
    # It's a list because it's transitioned.
    dep = ctx.attr.dep[0]

    providers = [
        dep[DefaultInfo],
        _without_cc_runtimes(dep[CcInfo], ctx.attr._cc_runtimes[0]),
    ]

    if GraphNodeInfo in dep:
        providers.append(dep[GraphNodeInfo])

    if OutputGroupInfo in dep:
        providers.append(dep[OutputGroupInfo])

    if InstrumentedFilesInfo in dep:
        providers.append(dep[InstrumentedFilesInfo])

    return providers

cc_unsanitized_library = rule(
    implementation = _cc_unsanitized_library_impl,
    attrs = {
        "copts": attr.string_list(),
        "cxxopts": attr.string_list(),
        "dep": attr.label(
            cfg = _reset_sanitizers,
            providers = [CcInfo],
            aspects = [graph_structure_aspect],
        ),
        "disable_zstd": attr.bool(),
        "platform": attr.label(),
        "_cc_runtimes": attr.label(
            default = "//runtimes/cxxstdlib:cc_runtimes",
            cfg = _reset_sanitizers,
            providers = [platform_common.ToolchainInfo],
        ),
    },
)
