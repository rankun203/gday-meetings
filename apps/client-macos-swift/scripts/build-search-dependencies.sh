#!/bin/bash
# Unmodified, checksum-pinned USearch and NumKong sources, compiled with CLT.
set -euo pipefail
client_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$client_dir/.build/native-search-$(uname -m)"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$client_dir/packaging/macos/Info.plist")"
signature="$(shasum -a 256 "$0" "$client_dir/Sources/USearchC/usearch.h" | shasum -a 256 | cut -d' ' -f1)-$(xcrun clang --version | head -1)-$(xcrun --sdk macosx --show-sdk-version)-$minimum"
verify() {
    local archive="$client_dir/ThirdParty/archives/$1.tar.gz"
    [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$2" ]] || {
        echo "Checksum mismatch: $archive" >&2; exit 1;
    }
}
verify usearch-2.26.4 505b9d340347b7cb4cae5880c1f3200da4e5a237fe16c3dd7855c29778989455
verify numkong-7.8.5 217d3df200d2f28bff61ab7ddda8168c12c9f86cf13838547b983c3cb0ac48a8
if [[ -f "$root/ready" && "$(cat "$root/ready")" == "$signature" && -f "$root/install/lib/libsemanticsearch.a" ]]; then exit 0; fi
mkdir -p "$root"
if ! mkdir "$root/lock" 2>/dev/null; then
    echo "Search dependency build is running (or has a stale lock: $root/lock)." >&2; exit 1
fi
pids=()
wait_batch() {
    local result=0 pid
    for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || result=1; done
    pids=()
    return "$result"
}
cleanup() {
    local result=$?
    wait_batch || true
    if (( result != 0 )); then
        for log in "$root"/*.log; do [[ ! -f "$log" ]] || tail -n 30 "$log"; done
    fi
    rmdir "$root/lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rm -rf "$root/src" "$root/objects"
mkdir -p "$root/src/usearch" "$root/src/numkong" "$root/objects" "$root/install/lib"
tar -xzf "$client_dir/ThirdParty/archives/usearch-2.26.4.tar.gz" -C "$root/src/usearch" --strip-components=1
tar -xzf "$client_dir/ThirdParty/archives/numkong-7.8.5.tar.gz" -C "$root/src/numkong" --strip-components=1
cmp "$client_dir/Sources/USearchC/usearch.h" "$root/src/usearch/c/usearch.h"
flags=(-O3 -DNDEBUG -isysroot "$(xcrun --sdk macosx --show-sdk-path)" "-mmacosx-version-min=$minimum"
    -DNK_DYNAMIC_DISPATCH=1 -DNK_NATIVE_F16=0 -DNK_NATIVE_BF16=0
    -I "$root/src/numkong/include" -I "$root/src/usearch/include")
for source in "$root/src/numkong/c/"*.c; do
    name="$(basename "$source" .c)"
    xcrun clang "${flags[@]}" -c "$source" -o "$root/objects/$name.o" > "$root/$name.log" 2>&1 &
    pids+=("$!")
    if (( ${#pids[@]} >= 4 )); then wait_batch; fi
done
wait_batch
xcrun clang++ "${flags[@]}" -std=c++11 -DUSEARCH_USE_NUMKONG=1 -c "$root/src/usearch/c/lib.cpp" -o "$root/objects/usearch.o" > "$root/usearch.log" 2>&1
xcrun ar rcs "$root/install/lib/libsemanticsearch.a" "$root/objects/"*.o
# Preserve warnings in successful builds, too.
for log in "$root"/*.log; do [[ ! -s "$log" ]] || cat "$log"; done
printf '%s' "$signature" > "$root/ready"
