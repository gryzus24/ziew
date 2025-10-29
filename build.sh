#!/bin/sh

usage() {
    printf '%s: <debug|small|fast> <install|test> [args...]\n' "$0"
}

OPT=
case "$1" in
    debug)
        ;;
    small)
        OPT=-Doptimize=ReleaseSmall
        ;;
    fast)
        OPT=-Doptimize=ReleaseFast
        ;;
    *)
        usage
        exit 1
esac
shift

CACHE_DIR=/tmp/zig-ziew
case "$1" in
    install)
        shift
        zig build \
            --summary none \
            --cache-dir "$CACHE_DIR" \
            -p . $OPT "$@"
        ;;
    test)
        shift
        set -x
        zig build --cache-dir "$CACHE_DIR" $OPT "$@" test
        set +x
        ;;
    *)
        usage
        exit 1
        ;;
esac
