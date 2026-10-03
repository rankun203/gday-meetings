#!/bin/bash
# Static, checksum-pinned Xiph libraries; only CLT tools are required.
set -euo pipefail
client_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${GDAY_AUDIO_BUILD_ROOT:-$client_dir/.build/native-audio-$(uname -m)}"
prefix="$root/install"
signature="$(shasum -a 256 "$0" | cut -d' ' -f1)-$(xcrun clang --version | head -1)-$(xcrun --sdk macosx --show-sdk-version)"
if [[ -f "$root/ready" && "$(cat "$root/ready")" == "$signature" && -f "$prefix/lib/libopusfile.a" ]]; then exit 0; fi
jobs="${GDAY_AUDIO_BUILD_JOBS:-$(/usr/sbin/sysctl -n hw.activecpu 2>/dev/null || printf '4')}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo 'GDAY_AUDIO_BUILD_JOBS must be a positive integer.' >&2
    exit 1
fi
mkdir -p "$root"
if ! mkdir "$root/lock" 2>/dev/null; then
    echo "Audio dependency build already running (or stale lock: $root/lock)." >&2
    exit 1
fi
dependency_pids=()
wait_for_builds() {
    local result=0 pid
    for pid in "$@"; do
        if wait "$pid"; then :; else result=1; fi
    done
    return "$result"
}
cleanup() {
    local result=$?
    # Keep the lock until every dependency has stopped, including on failure.
    wait_for_builds ${dependency_pids[@]+"${dependency_pids[@]}"} || true
    if (( result != 0 )); then
        for log in "$root"/*.log; do
            [[ -f "$log" ]] || continue
            echo "Audio build log: $log" >&2
            tail -n 30 "$log" >&2
        done
    fi
    rmdir "$root/lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export CC="$(xcrun --find clang)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=14.2
export CFLAGS="-O2 -isysroot $SDKROOT -mmacosx-version-min=14.2"
export LDFLAGS="-isysroot $SDKROOT -mmacosx-version-min=14.2"
build_library() {
    local name="$1" checksum="$2" library_jobs="$3"
    shift 3
    local archive="$client_dir/ThirdParty/archives/$name.tar.gz"
    if [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" != "$checksum" ]]; then
        echo "Checksum mismatch: $archive. Restore the checked-in archive before retrying." >&2; exit 1
    fi
    # A changed compiler/SDK/script must not reuse objects from an older build.
    /bin/rm -rf "$root/build-$name" "$root/sources/$name"
    mkdir -p "$root/sources"
    tar -xzf "$archive" -C "$root/sources"
    mkdir -p "$root/build-$name"
    (
        cd "$root/build-$name"
        if [[ "$name" == opusfile-* ]]; then
            # Upstream's four-file local decoder target; avoid the old libtool
            # wrapper and unused opusurl target. macOS provides lrintf in libSystem.
            local unit object_pids=()
            for unit in info internal opusfile stream; do
                "$CC" -O2 -isysroot "$SDKROOT" -mmacosx-version-min=14.2 -DOP_HAVE_LRINTF=1 \
                    -I"$prefix/include" -I"$prefix/include/opus" -I"$root/sources/$name/include" \
                    -c "$root/sources/$name/src/$unit.c" -o "$unit.o" &
                object_pids+=("$!")
                if (( ${#object_pids[@]} >= library_jobs )); then
                    wait_for_builds ${object_pids[@]+"${object_pids[@]}"}
                    object_pids=()
                fi
            done
            wait_for_builds ${object_pids[@]+"${object_pids[@]}"}
            /usr/bin/ar -crs libopusfile-local.a info.o internal.o opusfile.o stream.o
            mkdir -p "$prefix/lib" "$prefix/include/opus"
            cp libopusfile-local.a "$prefix/lib/libopusfile.a"
            cp "$root/sources/$name/include/opusfile.h" "$prefix/include/opus/"
        else
            "$root/sources/$name/configure" --prefix="$prefix" --disable-shared --enable-static "$@"
            /usr/bin/make -j"$library_jobs"
            /usr/bin/make install
        fi
    )
    mkdir -p "$prefix/licenses"
    cp "$root/sources/$name/COPYING" "$prefix/licenses/$name.txt"
}
# Ogg and Opus have no dependency on each other. Share the CPU budget;
# opusfile needs both installed headers and must run after they succeed.
if (( jobs > 1 )); then
    ogg_jobs=$(( jobs / 4 ))
    (( ogg_jobs > 0 )) || ogg_jobs=1
    opus_jobs=$(( jobs - ogg_jobs ))
else
    ogg_jobs=1
    opus_jobs=1
fi
printf 'Building audio dependencies (%s jobs). Logs: %s/*.log\n' "$jobs" "$root"
build_library libogg-1.3.6 83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638 "$ogg_jobs" > "$root/ogg.log" 2>&1 &
dependency_pids+=("$!")
if (( jobs == 1 )); then wait_for_builds ${dependency_pids[@]+"${dependency_pids[@]}"}; dependency_pids=(); fi
build_library opus-1.6.1 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1 "$opus_jobs" --disable-doc --disable-extra-programs > "$root/opus.log" 2>&1 &
dependency_pids+=("$!")
wait_for_builds ${dependency_pids[@]+"${dependency_pids[@]}"}
dependency_pids=()
build_library opusfile-0.12 118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b "$jobs" > "$root/opusfile.log" 2>&1
printf '%s' "$signature" > "$root/ready"
