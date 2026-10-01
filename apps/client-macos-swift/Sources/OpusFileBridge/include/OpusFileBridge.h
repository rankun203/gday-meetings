#ifndef GDAY_OPUS_FILE_BRIDGE_H
#define GDAY_OPUS_FILE_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct GdayOpusFile GdayOpusFile;
GdayOpusFile *gday_opus_open(const char *path, int *error);
void gday_opus_close(GdayOpusFile *file);
int gday_opus_channels(GdayOpusFile *file);
int64_t gday_opus_frames(GdayOpusFile *file);
int64_t gday_opus_position(GdayOpusFile *file);
uint64_t gday_opus_bytes_read(GdayOpusFile *file);
int gday_opus_seek(GdayOpusFile *file, int64_t frame);
int gday_opus_read(GdayOpusFile *file, float *samples, int capacity);

// One encoder per 48 kHz track, with 1 or 2 channels. Uses VOIP, voice signal,
// DTX, complexity 5, VBR, and 32000 bits/second total (also for stereo).
// Returns NULL on failure. Optional error receives OPUS_OK or a libopus error.
// The caller owns the encoder and must serialize all access, including destroy.
typedef struct GdayOpusEncoder GdayOpusEncoder;
GdayOpusEncoder *gday_opus_encoder_create(int channels, int *error);
// Releases the encoder; NULL is allowed. Does not flush or write a file.
void gday_opus_encoder_destroy(GdayOpusEncoder *encoder);
// Returns encoder delay in samples per channel at 48 kHz, or a negative error.
int gday_opus_encoder_lookahead(GdayOpusEncoder *encoder);
// Input contains frames * channels floats, normally in [-1, 1]. Stereo is
// interleaved L, R. frames counts samples per channel: 120, 240, 480, 960,
// 1920, or 2880. Use 960 (20 ms) for speech recording and DTX.
// Buffers belong to the caller and are only borrowed during this call.
// packet has capacity writable bytes (4000 recommended). Returns packet length
// or a negative libopus error. Keep short DTX packets in saved audio to retain
// timing. The caller handles buffering, end padding, Ogg wrapping, and pre-skip.
int gday_opus_encoder_encode(GdayOpusEncoder *encoder, const float *interleaved,
                             int frames, unsigned char *packet, int capacity);
// Returns a static message owned by libopus; do not free it.
const char *gday_opus_encoder_error(int code);

// Single producer / single consumer. All tracks share one pair of cursors.
// No locks, allocation, decoding or file I/O on the render thread.
typedef struct GdayPlaybackRing GdayPlaybackRing;
GdayPlaybackRing *gday_playback_create(uint32_t tracks, uint32_t capacity);
void gday_playback_destroy(GdayPlaybackRing *ring);
uint32_t gday_playback_available(GdayPlaybackRing *ring);
uint32_t gday_playback_free(GdayPlaybackRing *ring);
void gday_playback_write_track(GdayPlaybackRing *ring, uint32_t track, const float *left, const float *right, uint32_t frames);
void gday_playback_commit(GdayPlaybackRing *ring, uint32_t frames);
void gday_playback_set_audible(GdayPlaybackRing *ring, uint32_t mask);
uint32_t gday_playback_render(GdayPlaybackRing *ring, float *left, float *right, uint32_t frames);
uint64_t gday_playback_consumed(GdayPlaybackRing *ring);
uint64_t gday_playback_underruns(GdayPlaybackRing *ring);
// Reset only with both engine and producer stopped.
void gday_playback_reset(GdayPlaybackRing *ring);
#endif
