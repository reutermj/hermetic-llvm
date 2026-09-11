# Generates libgcc.map.in the way libgcc/Makefile.in does: libgcc-std.ver is
# instantiated from libgcc-std.ver.in, concatenated with the target's other
# SHLIB_MAPFILES, stripped of comments, and run through the target C
# preprocessor with the %if/%else/%elif/%endif/%define markers turned into
# preprocessor directives. The result is the input of mkmap-symver.awk.

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

# The libgcc-std.ver and libgcc.map.in recipes, up to the preprocessor run.
_CONCATENATE_COMMAND = """set -eu
out="$1"
gnu_prefix="$2"
fixedpoint_gnu_prefix="$3"
std_ver_in="$4"
shift 4

{
    sed -e "s/__PFX__/${gnu_prefix}/g" \\
        -e "s/__FIXPTPFX__/${fixedpoint_gnu_prefix}/g" "${std_ver_in}"
    if [ "$#" -gt 0 ]; then
        cat "$@"
    fi
} | sed -e '/^[ \t]*#/d' \\
        -e 's/^%if/#if/' \\
        -e 's/^%else/#else/' \\
        -e 's/^%elif/#elif/' \\
        -e 's/^%endif/#endif/' \\
        -e 's/^%define/#define/' \\
    > "$out"
"""

def _libgcc_map_in_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )
    source_placeholder = "__libgcc_map_in_source__.ver"
    output_placeholder = "__libgcc_map_in_output__.ver"
    concatenated = ctx.actions.declare_file(ctx.label.name + ".ver")
    output = ctx.actions.declare_file(ctx.label.name)

    ctx.actions.run_shell(
        inputs = [ctx.file.std_ver_in] + ctx.files.mapfiles,
        outputs = [concatenated],
        arguments = [
            concatenated.path,
            ctx.attr.gnu_prefix,
            ctx.attr.fixedpoint_gnu_prefix,
            ctx.file.std_ver_in.path,
        ] + [mapfile.path for mapfile in ctx.files.mapfiles],
        command = _CONCATENATE_COMMAND,
        mnemonic = "LibgccMapInConcatenate",
    )

    preprocess_action = ACTION_NAMES.preprocess_assemble
    variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        source_file = source_placeholder,
        output_file = output_placeholder,
        # -xassembler-with-cpp as in libgcc/Makefile.in; -P only drops the
        # line markers that mkmap-symver.awk would skip as comments anyway.
        user_compile_flags = [
            "-x",
            "assembler-with-cpp",
            "-E",
            "-P",
        ],
    )
    raw_command_line = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = preprocess_action,
        variables = variables,
    )
    command_line = [
        arg
        for arg in raw_command_line
        # The cc action template is compile-shaped. This action only
        # preprocesses the version script, so keep the cc_common-derived
        # target and include flags but drop the compile-only marker.
        if arg != "-c"
    ]
    env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = preprocess_action,
        variables = variables,
    )
    compiler = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = preprocess_action,
    )

    preprocessor_args = ctx.actions.args()
    for arg in command_line:
        if arg == source_placeholder:
            preprocessor_args.add(concatenated)
        elif arg == output_placeholder:
            preprocessor_args.add(output)
        else:
            preprocessor_args.add(arg)

    ctx.actions.run(
        executable = compiler,
        inputs = depset(
            direct = [concatenated],
            transitive = [cc_toolchain.all_files],
        ),
        outputs = [output],
        arguments = [preprocessor_args],
        env = env,
        mnemonic = "LibgccMapInPreprocess",
        toolchain = CC_TOOLCHAIN_TYPE,
    )

    return [DefaultInfo(files = depset([output]))]

libgcc_map_in = rule(
    implementation = _libgcc_map_in_impl,
    attrs = {
        "std_ver_in": attr.label(allow_single_file = True, mandatory = True),
        "mapfiles": attr.label_list(allow_files = True),
        # LIBGCC_VER_GNU_PREFIX and LIBGCC_VER_FIXEDPOINT_GNU_PREFIX from
        # libgcc/Makefile.in; t-fixedpoint-gnu-prefix targets use __gnu_.
        "gnu_prefix": attr.string(default = "__"),
        "fixedpoint_gnu_prefix": attr.string(default = "__"),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)
