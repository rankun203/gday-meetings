#!/bin/bash
# Exercise the real pinned sources in disposable directories, including failure.
set -euo pipefail
client_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gday-audio-build-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
script="$client_dir/scripts/build-audio-dependencies.sh"

for jobs in 1 4; do
    root="$scratch/jobs-$jobs"
    GDAY_AUDIO_BUILD_ROOT="$root" GDAY_AUDIO_BUILD_JOBS="$jobs" bash "$script" > "$scratch/jobs-$jobs.log" 2>&1
    [[ -f "$root/ready" && ! -e "$root/lock" ]]
    for library in ogg opus opusfile; do
        [[ -s "$root/install/lib/lib$library.a" ]]
    done
    before="$(stat -f %m "$root/install/lib/libopus.a")"
    GDAY_AUDIO_BUILD_ROOT="$root" GDAY_AUDIO_BUILD_JOBS="$jobs" bash "$script" > "$scratch/cached.log" 2>&1
    [[ ! -s "$scratch/cached.log" && "$before" == "$(stat -f %m "$root/install/lib/libopus.a")" ]]
done

# A failed independent job must be reported, wait for its sibling, release the
# lock, and never build the dependent decoder or publish a ready stamp.
fixture="$scratch/client"
mkdir -p "$fixture/scripts" "$fixture/ThirdParty/archives"
cp "$script" "$fixture/scripts/"
ln -s "$client_dir/ThirdParty/archives/libogg-1.3.6.tar.gz" "$fixture/ThirdParty/archives/"
printf 'Invalid archive\n' > "$fixture/ThirdParty/archives/opus-1.6.1.tar.gz"
root="$scratch/failure"
if GDAY_AUDIO_BUILD_ROOT="$root" GDAY_AUDIO_BUILD_JOBS=4 bash "$fixture/scripts/build-audio-dependencies.sh" > "$scratch/failure.log" 2>&1; then
    echo 'Expected checksum failure.' >&2
    exit 1
fi
[[ ! -e "$root/ready" && ! -e "$root/lock" && ! -e "$root/build-opusfile-0.12" ]]
[[ -s "$root/install/lib/libogg.a" ]]
grep -q 'Checksum mismatch:' "$scratch/failure.log"
for jobs in 0 invalid; do
    if GDAY_AUDIO_BUILD_ROOT="$scratch/invalid-$jobs" GDAY_AUDIO_BUILD_JOBS="$jobs" bash "$script" > "$scratch/invalid.log" 2>&1; then
        echo 'Expected invalid job count to fail.' >&2
        exit 1
    fi
done
printf 'Audio build scheduling, cache, and failure checks passed.\n'
