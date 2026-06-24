#!/bin/bash

usage() {
    printf '%s: [debug|small|fast|safe|glibc|strip|native|omit-fp|
             no-oom-check|config=<file>|trace|release|test...] \n' "$0"
}

CACHE_DIR=/tmp/zig-ziew

TEST=
declare -a FLAGS
for arg in "$@"; do
    case "$arg" in
        debug)        FLAGS+=(-Doptimize=Debug) ;;
        small)        FLAGS+=(-Doptimize=ReleaseSmall) ;;
        fast)         FLAGS+=(-Doptimize=ReleaseFast) ;;
        safe)         FLAGS+=(-Doptimize=ReleaseSafe) ;;
        glibc)        FLAGS+=(-Dglibc) ;;
        strip)        FLAGS+=(-Dstrip) ;;
        native)       FLAGS+=(-Dmarch=native) ;;
        omit-fp)      FLAGS+=(-Domit-frame-pointer) ;;
        no-oom-check) FLAGS+=(-Dmem-no-oom-check) ;;
        config=*)     FLAGS+=("-D$arg") ;;
        trace)        FLAGS+=(-Dmem-trace-allocations) ;;
        release)      FLAGS+=(-Doptimize=ReleaseSmall -Dstrip) ;;
        test)         TEST=1 ;;
        *)
            printf '%s: unknown option: %s\n' "$0" "'$arg'"
            usage
            exit 1
    esac
done

if [[ -n "$TEST" ]]; then
    set -x
    zig build --cache-dir "$CACHE_DIR" "${FLAGS[@]}" test
    set +x
else
    zig build \
        --summary none \
        --error-style minimal \
        --cache-dir "$CACHE_DIR" \
        -p . "${FLAGS[@]}"
fi
