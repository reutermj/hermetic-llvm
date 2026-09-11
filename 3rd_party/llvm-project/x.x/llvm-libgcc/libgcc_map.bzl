# Generates libgcc.map the way libgcc/Makefile.in does, with libunwind and the
# compiler-rt builtins standing in for libgcc's objects: mkmap-symver.awk keeps
# the symbols of libgcc.map.in that nm finds in the objects, resolves %inherit
# and %exclude, drops the versions that end up empty, and makes every other
# symbol local.
#
# GCC's target fragments list some symbols under two versions, an older one
# kept for binary compatibility and the corrected one (config/i386/
# libgcc-glibc.ver: __divtc3 under GCC_4.0.0 and GCC_4.3.0). Linkers assign a
# symbol to the first version that names it; libgcc's objects get the
# corrected default because they also define the old version as a .symver
# alias, which claims the earlier entry. compiler-rt has no such aliases, so
# only the last entry of a symbol is kept, which is its default version.

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

# mkmap-symver.awk prints versions parents first, one "\tsymbol;" per line.
# The first pass over the map records the last version naming each symbol,
# the second drops the earlier entries.
_KEEP_LAST_ENTRY = """
awk '
    FNR == 1 { node = 0 }
    /^[^ \\t}].* \\{$/ { node++ }
    /^\\t[^*].*;$/ { if (NR == FNR) last[$0] = node; else if (last[$0] != node) next }
    NR != FNR { print }
' "$1" "$1"
"""

def _libraries(cc_info):
    files = []
    for linker_input in cc_info.linking_context.linker_inputs.to_list():
        for library in linker_input.libraries:
            archive = library.pic_static_library or library.static_library
            if archive:
                files.append(archive)
            else:
                files.extend(library.pic_objects or library.objects or [])
    return files

def _libgcc_map_impl(ctx):
    libraries = []
    for dep in ctx.attr.deps:
        libraries.extend(_libraries(dep[CcInfo]))
    output = ctx.actions.declare_file(ctx.label.name)

    # The libgcc.map recipe: SHLIB_NM_FLAGS is -pg.
    ctx.actions.run_shell(
        inputs = [ctx.file.map_in, ctx.file.mkmap] + libraries,
        outputs = [output],
        tools = [ctx.file._nm],
        arguments = [
            ctx.file._nm.path,
            ctx.file.mkmap.path,
            ctx.file.map_in.path,
            output.path,
        ] + [library.path for library in libraries],
        command = """set -eu
nm="$1"
mkmap="$2"
map_in="$3"
out="$4"
shift 4
{ "$nm" -p -g "$@"; echo %%; cat "$map_in"; } | awk -f "$mkmap" > "$out.mkmap"
keep_last_entry() {""" + _KEEP_LAST_ENTRY + """}
keep_last_entry "$out.mkmap" > "$out"
rm -f "$out.mkmap"
""",
        mnemonic = "LibgccMap",
    )

    return [DefaultInfo(files = depset([output]))]

libgcc_map = rule(
    implementation = _libgcc_map_impl,
    attrs = {
        "map_in": attr.label(allow_single_file = True, mandatory = True),
        "mkmap": attr.label(allow_single_file = True, mandatory = True),
        "deps": attr.label_list(providers = [CcInfo], mandatory = True),
        # The stage0 tool is a prebuilt file behind the alias, not a rule.
        "_nm": attr.label(
            default = "@llvm//tools:llvm-nm",
            allow_single_file = True,
            cfg = "exec",
        ),
    },
)
