#include "OpusFileBridge.h"
#include <opus/opus.h>
#include <stdlib.h>

struct GdayOpusEncoder { OpusEncoder *encoder; };

GdayOpusEncoder *gday_opus_encoder_create(int channels, int *error) {
    int status = OPUS_BAD_ARG;
    GdayOpusEncoder *s = NULL;
    if (channels != 1 && channels != 2) goto fail;
    s = calloc(1, sizeof(*s));
    if (!s) { status = OPUS_ALLOC_FAIL; goto fail; }
    s->encoder = opus_encoder_create(48000, channels, OPUS_APPLICATION_VOIP, &status);
    if (!s->encoder) goto fail;
    status = opus_encoder_ctl(s->encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    if (status != OPUS_OK) goto fail;
    status = opus_encoder_ctl(s->encoder, OPUS_SET_DTX(1));
    if (status != OPUS_OK) goto fail;
    status = opus_encoder_ctl(s->encoder, OPUS_SET_COMPLEXITY(5));
    if (status != OPUS_OK) goto fail;
    status = opus_encoder_ctl(s->encoder, OPUS_SET_VBR(1));
    if (status != OPUS_OK) goto fail;
    status = opus_encoder_ctl(s->encoder, OPUS_SET_BITRATE(32000));
    if (status != OPUS_OK) goto fail;
    if (error) *error = OPUS_OK;
    return s;
fail:
    gday_opus_encoder_destroy(s);
    if (error) *error = status;
    return NULL;
}

void gday_opus_encoder_destroy(GdayOpusEncoder *s) {
    if (!s) return;
    if (s->encoder) opus_encoder_destroy(s->encoder);
    free(s);
}

int gday_opus_encoder_lookahead(GdayOpusEncoder *s) {
    if (!s) return OPUS_BAD_ARG;
    int samples = 0;
    int status = opus_encoder_ctl(s->encoder, OPUS_GET_LOOKAHEAD(&samples));
    return status == OPUS_OK ? samples : status;
}

int gday_opus_encoder_encode(GdayOpusEncoder *s, const float *interleaved,
                             int frames, unsigned char *packet, int capacity) {
    if (!s || !interleaved || !packet || capacity <= 0) return OPUS_BAD_ARG;
    switch (frames) {
        case 120: case 240: case 480: case 960: case 1920: case 2880: break;
        default: return OPUS_BAD_ARG;
    }
    return opus_encode_float(s->encoder, interleaved, frames, packet, capacity);
}

const char *gday_opus_encoder_error(int code) { return opus_strerror(code); }
