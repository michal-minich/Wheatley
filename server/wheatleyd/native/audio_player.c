#define _POSIX_C_SOURCE 200809L

#include "../vendor/miniaudio/miniaudio.h"

#include <math.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef enum
{
    player_target_play,
    player_target_pause,
    player_target_stop,
} player_target;

typedef struct
{
    ma_decoder decoder;
    ma_uint32 channels;
    ma_uint32 sample_rate;
    atomic_int target;
    atomic_bool done;
    float gain;
    float playback_gain;
    float fade_step;
    ma_bool32 loop;
    ma_uint64 decoded_frames;
    ma_uint64 tail_frames;
    ma_uint64 drain_frames;
    ma_uint64 paused_cursor;
    ma_uint64 resumed_cursor;
    ma_bool32 finishing;
    ma_bool32 has_paused_cursor;
    ma_bool32 has_resumed_cursor;
} player;

static volatile sig_atomic_t pending_signal;

static void sleep_milliseconds(long milliseconds)
{
    struct timespec duration;
    duration.tv_sec = milliseconds / 1000;
    duration.tv_nsec = (milliseconds % 1000) * 1000000L;
    nanosleep(&duration, NULL);
}

static void receive_signal(int signal_number)
{
    pending_signal = signal_number;
}

static int player_init(
    player* value,
    const char* path,
    float playback_gain,
    ma_bool32 loop
)
{
    ma_decoder_config decoder_config;
    ma_result result;

    memset(value, 0, sizeof(*value));
    decoder_config = ma_decoder_config_init(ma_format_f32, 0, 0);
    result = ma_decoder_init_file(path, &decoder_config, &value->decoder);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "wheatley-audio-player: cannot decode %s: %s\n", path, ma_result_description(result));
        return 1;
    }

    value->channels = value->decoder.outputChannels;
    value->sample_rate = value->decoder.outputSampleRate;
    value->gain = loop ? 0.0f : 1.0f;
    value->playback_gain = playback_gain;
    value->loop = loop;
    value->fade_step = 1.0f / (0.035f * (float)value->sample_rate);
    value->drain_frames = value->sample_rate / 8;
    atomic_init(&value->target, player_target_play);
    atomic_init(&value->done, 0);
    return 0;
}

static void player_uninit(player* value)
{
    ma_decoder_uninit(&value->decoder);
}

static void player_finish(player* value)
{
    value->finishing = MA_TRUE;
}

static void player_add_tail(player* value, ma_uint64 frames)
{
    if (!value->finishing) return;
    value->tail_frames += frames;
    if (value->tail_frames >= value->drain_frames) {
        atomic_store_explicit(&value->done, 1, memory_order_release);
    }
}

static ma_uint64 fade_frame_count(const player* value, ma_uint64 available)
{
    ma_uint64 frames = (ma_uint64)ceilf(value->gain / value->fade_step);
    return frames < available ? frames : available;
}

static void apply_gain(player* value, float* output, ma_uint64 frames, player_target target)
{
    ma_uint64 frame;
    ma_uint32 channel;

    for (frame = 0; frame < frames; frame += 1) {
        float sample_gain;
        if (target == player_target_play) {
            value->gain += value->fade_step;
            if (value->gain > 1.0f) value->gain = 1.0f;
            sample_gain = value->gain;
        } else {
            sample_gain = value->gain;
            value->gain -= value->fade_step;
            if (value->gain < 0.0f) value->gain = 0.0f;
        }

        for (channel = 0; channel < value->channels; channel += 1) {
            output[frame * value->channels + channel] *= sample_gain * value->playback_gain;
        }
    }
}

static void player_render(player* value, float* output, ma_uint32 frame_count)
{
    player_target target;
    ma_uint64 requested_frames;
    ma_uint64 frames_read = 0;
    ma_result result;
    ma_bool32 empty_loop_retry = MA_FALSE;

    memset(output, 0, (size_t)frame_count * value->channels * sizeof(*output));
    if (atomic_load_explicit(&value->done, memory_order_acquire)) return;
    if (value->finishing) {
        player_add_tail(value, frame_count);
        return;
    }

    target = (player_target)atomic_load_explicit(&value->target, memory_order_acquire);
    if (target != player_target_play && value->gain <= 0.0f) {
        if (target == player_target_pause && !value->has_paused_cursor) {
            value->paused_cursor = value->decoded_frames;
            value->has_paused_cursor = MA_TRUE;
        }
        if (target == player_target_stop) {
            player_finish(value);
            player_add_tail(value, frame_count);
        }
        return;
    }

    if (
        target == player_target_play
        && value->gain <= 0.0f
        && value->has_paused_cursor
        && !value->has_resumed_cursor
    ) {
        value->resumed_cursor = value->decoded_frames;
        value->has_resumed_cursor = MA_TRUE;
    }

    requested_frames = target == player_target_play
        ? frame_count
        : fade_frame_count(value, frame_count);
    while (frames_read < requested_frames) {
        ma_uint64 chunk_frames = 0;
        result = ma_decoder_read_pcm_frames(
            &value->decoder,
            output + frames_read * value->channels,
            requested_frames - frames_read,
            &chunk_frames
        );
        frames_read += chunk_frames;
        if (chunk_frames > 0) empty_loop_retry = MA_FALSE;
        if (frames_read >= requested_frames) break;
        if (
            value->loop
            && target == player_target_play
            && ma_decoder_seek_to_pcm_frame(&value->decoder, 0) == MA_SUCCESS
        ) {
            if (chunk_frames == 0 && empty_loop_retry) break;
            empty_loop_retry = chunk_frames == 0;
            continue;
        }
        if (result != MA_SUCCESS || chunk_frames == 0) break;
    }

    apply_gain(value, output, frames_read, target);
    value->decoded_frames += frames_read;

    if (frames_read < requested_frames) {
        player_finish(value);
        player_add_tail(value, frame_count - frames_read);
        return;
    }

    if (target == player_target_pause && value->gain <= 0.0f && !value->has_paused_cursor) {
        value->paused_cursor = value->decoded_frames;
        value->has_paused_cursor = MA_TRUE;
    }
    if (target == player_target_stop && value->gain <= 0.0f) {
        player_finish(value);
        player_add_tail(value, frame_count - requested_frames);
    }
}

static void device_callback(ma_device* device, void* output, const void* input, ma_uint32 frame_count)
{
    player_render((player*)device->pUserData, (float*)output, frame_count);
    (void)input;
}

static void apply_pending_signal(player* value)
{
    sig_atomic_t signal_number = pending_signal;
    if (signal_number == 0) return;
    pending_signal = 0;

    if (signal_number == SIGURG) {
        atomic_store_explicit(&value->target, player_target_pause, memory_order_release);
    } else if (signal_number == SIGCONT) {
        atomic_store_explicit(&value->target, player_target_play, memory_order_release);
    } else {
        atomic_store_explicit(&value->target, player_target_stop, memory_order_release);
    }
}

static int play_file(
    const char* path,
    ma_bool32 null_backend,
    ma_bool32 loop,
    float playback_gain
)
{
    player value;
    ma_context context;
    ma_context* context_pointer = NULL;
    ma_device_config device_config;
    ma_device device;
    ma_result result;

    /* SIGURG is ignored and SIGCONT is harmless before these handlers are
       installed, so an early pause/resume command cannot terminate playback. */
    signal(SIGURG, receive_signal);
    signal(SIGCONT, receive_signal);
    signal(SIGTERM, receive_signal);
    signal(SIGINT, receive_signal);

    if (player_init(&value, path, playback_gain, loop) != 0) return 1;

    if (null_backend) {
        ma_backend backend = ma_backend_null;
        result = ma_context_init(&backend, 1, NULL, &context);
        if (result != MA_SUCCESS) {
            fprintf(stderr, "wheatley-audio-player: cannot initialize null backend: %s\n", ma_result_description(result));
            player_uninit(&value);
            return 1;
        }
        context_pointer = &context;
    }

    device_config = ma_device_config_init(ma_device_type_playback);
    device_config.playback.format = ma_format_f32;
    device_config.playback.channels = value.channels;
    device_config.sampleRate = value.sample_rate;
    device_config.periodSizeInMilliseconds = 10;
    device_config.periods = 3;
    device_config.dataCallback = device_callback;
    device_config.pUserData = &value;
    result = ma_device_init(context_pointer, &device_config, &device);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "wheatley-audio-player: cannot open playback device: %s\n", ma_result_description(result));
        if (context_pointer != NULL) ma_context_uninit(&context);
        player_uninit(&value);
        return 1;
    }

    result = ma_device_start(&device);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "wheatley-audio-player: cannot start playback device: %s\n", ma_result_description(result));
        ma_device_uninit(&device);
        if (context_pointer != NULL) ma_context_uninit(&context);
        player_uninit(&value);
        return 1;
    }

    while (!atomic_load_explicit(&value.done, memory_order_acquire)) {
        apply_pending_signal(&value);
        sleep_milliseconds(5);
    }

    ma_device_uninit(&device);
    if (context_pointer != NULL) ma_context_uninit(&context);
    player_uninit(&value);
    return 0;
}

static unsigned long parse_milliseconds(const char* text, const char* label)
{
    char* end;
    unsigned long value = strtoul(text, &end, 10);
    if (text[0] == '\0' || end[0] != '\0') {
        fprintf(stderr, "wheatley-audio-player: %s must be a non-negative integer\n", label);
        exit(2);
    }
    return value;
}

static float parse_gain(const char* text)
{
    char* end;
    float value = strtof(text, &end);
    if (text[0] == '\0' || end[0] != '\0' || !isfinite(value) || value < 0.0f || value > 4.0f) {
        fprintf(stderr, "wheatley-audio-player: gain must be between 0 and 4\n");
        exit(2);
    }
    return value;
}

static int render_file(
    const char* output_path,
    const char* input_path,
    unsigned long pause_milliseconds,
    unsigned long resume_milliseconds
)
{
    player value;
    ma_encoder_config encoder_config;
    ma_encoder encoder;
    float* buffer;
    ma_uint64 output_frames = 0;
    ma_uint64 pause_frame;
    ma_uint64 resume_frame;
    ma_uint64 frames_written;
    float previous_sample = 0.0f;
    float maximum_delta = 0.0f;
    ma_bool32 has_previous_sample = MA_FALSE;
    ma_bool32 pause_sent = MA_FALSE;
    ma_bool32 resume_sent = MA_FALSE;
    const ma_uint32 block_frames = 160;

    if (resume_milliseconds <= pause_milliseconds) {
        fprintf(stderr, "wheatley-audio-player: resume_ms must be greater than pause_ms\n");
        return 2;
    }
    if (player_init(&value, input_path, 1.0f, MA_FALSE) != 0) return 1;

    encoder_config = ma_encoder_config_init(
        ma_encoding_format_wav,
        ma_format_f32,
        value.channels,
        value.sample_rate
    );
    if (ma_encoder_init_file(output_path, &encoder_config, &encoder) != MA_SUCCESS) {
        fprintf(stderr, "wheatley-audio-player: cannot create %s\n", output_path);
        player_uninit(&value);
        return 1;
    }

    buffer = (float*)malloc((size_t)block_frames * value.channels * sizeof(*buffer));
    if (buffer == NULL) {
        fprintf(stderr, "wheatley-audio-player: out of memory\n");
        ma_encoder_uninit(&encoder);
        player_uninit(&value);
        return 1;
    }

    pause_frame = pause_milliseconds * value.sample_rate / 1000;
    resume_frame = resume_milliseconds * value.sample_rate / 1000;
    while (!atomic_load_explicit(&value.done, memory_order_acquire)) {
        ma_uint64 sample_count;
        ma_uint64 sample;
        if (!pause_sent && output_frames >= pause_frame) {
            atomic_store_explicit(&value.target, player_target_pause, memory_order_release);
            pause_sent = MA_TRUE;
        }
        if (!resume_sent && output_frames >= resume_frame) {
            atomic_store_explicit(&value.target, player_target_play, memory_order_release);
            resume_sent = MA_TRUE;
        }

        player_render(&value, buffer, block_frames);
        if (ma_encoder_write_pcm_frames(&encoder, buffer, block_frames, &frames_written) != MA_SUCCESS) {
            fprintf(stderr, "wheatley-audio-player: failed writing %s\n", output_path);
            free(buffer);
            ma_encoder_uninit(&encoder);
            player_uninit(&value);
            return 1;
        }

        sample_count = frames_written * value.channels;
        for (sample = 0; sample < sample_count; sample += 1) {
            float delta;
            if (!has_previous_sample) {
                previous_sample = buffer[sample];
                has_previous_sample = MA_TRUE;
                continue;
            }
            delta = fabsf(buffer[sample] - previous_sample);
            if (delta > maximum_delta) maximum_delta = delta;
            previous_sample = buffer[sample];
        }
        output_frames += frames_written;
    }

    printf(
        "{\"sample_rate\":%u,\"channels\":%u,\"decoded_frames\":%llu,"
        "\"output_frames\":%llu,\"paused_cursor_frames\":%llu,"
        "\"resumed_cursor_frames\":%llu,\"max_sample_delta\":%.9f}\n",
        value.sample_rate,
        value.channels,
        (unsigned long long)value.decoded_frames,
        (unsigned long long)output_frames,
        (unsigned long long)value.paused_cursor,
        (unsigned long long)value.resumed_cursor,
        maximum_delta
    );

    free(buffer);
    ma_encoder_uninit(&encoder);
    player_uninit(&value);
    return 0;
}

int main(int argc, char** argv)
{
    const char* backend = getenv("WHEATLEY_AUDIO_PLAYER_BACKEND");
    if (argc == 3 && strcmp(argv[1], "--null") == 0) {
        return play_file(argv[2], MA_TRUE, MA_FALSE, 1.0f);
    }
    if (argc == 6 && strcmp(argv[1], "--render") == 0) {
        return render_file(
            argv[2],
            argv[3],
            parse_milliseconds(argv[4], "pause_ms"),
            parse_milliseconds(argv[5], "resume_ms")
        );
    }
    if (argc == 2) {
        return play_file(
            argv[1],
            backend != NULL && strcmp(backend, "null") == 0,
            MA_FALSE,
            1.0f
        );
    }
    if (
        argc == 5
        && strcmp(argv[1], "--loop") == 0
        && strcmp(argv[2], "--gain") == 0
    ) {
        return play_file(
            argv[4],
            backend != NULL && strcmp(backend, "null") == 0,
            MA_TRUE,
            parse_gain(argv[3])
        );
    }

    fprintf(
        stderr,
        "Usage: wheatley-audio-player [--null] AUDIO\n"
        "       wheatley-audio-player --loop --gain GAIN AUDIO\n"
        "       wheatley-audio-player --render OUTPUT.wav INPUT.wav PAUSE_MS RESUME_MS\n"
    );
    return 2;
}
