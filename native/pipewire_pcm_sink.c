#include <errno.h>
#include <pipewire/pipewire.h>
#include <pthread.h>
#include <signal.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/props.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_RATE 44100
#define CHANNELS 1
#define RING_SAMPLES (SAMPLE_RATE * 8)
#define TARGET_LOW_SAMPLES (SAMPLE_RATE * 50 / 1000)
#define TARGET_SAMPLES (SAMPLE_RATE * 80 / 1000)
#define TARGET_HIGH_SAMPLES (SAMPLE_RATE * 120 / 1000)

struct sink_state {
  struct pw_thread_loop *loop;
  struct pw_stream *stream;
  struct spa_hook stream_listener;
  pthread_t input_thread;
  pthread_mutex_t lock;
  int16_t ring[RING_SAMPLES];
  size_t read_pos;
  size_t write_pos;
  size_t queued;
  uint64_t underruns;
  uint64_t overruns;
  int prebuffering;
  int running;
};

static void ring_write(struct sink_state *state, const int16_t *samples, size_t count) {
  pthread_mutex_lock(&state->lock);
  for (size_t i = 0; i < count; i++) {
    if (state->queued == RING_SAMPLES) {
      state->read_pos = (state->read_pos + 1) % RING_SAMPLES;
      state->queued--;
      state->overruns++;
    }
    state->ring[state->write_pos] = samples[i];
    state->write_pos = (state->write_pos + 1) % RING_SAMPLES;
    state->queued++;
  }
  pthread_mutex_unlock(&state->lock);
}

static size_t ring_read(struct sink_state *state, int16_t *samples, size_t count) {
  size_t copied = 0;
  pthread_mutex_lock(&state->lock);

  if (state->prebuffering && state->queued < TARGET_HIGH_SAMPLES) {
    pthread_mutex_unlock(&state->lock);
    return 0;
  }
  state->prebuffering = 0;

  while (copied < count && state->queued > 0) {
    samples[copied++] = state->ring[state->read_pos];
    state->read_pos = (state->read_pos + 1) % RING_SAMPLES;
    state->queued--;
  }
  if (copied < count) {
    state->underruns++;
  }

  pthread_mutex_unlock(&state->lock);
  return copied;
}

static void *input_loop(void *userdata) {
  struct sink_state *state = userdata;
  int16_t buffer[8192];

  while (state->running) {
    ssize_t bytes = read(STDIN_FILENO, buffer, sizeof(buffer));
    if (bytes > 0) {
      ring_write(state, buffer, (size_t)bytes / sizeof(int16_t));
    } else if (bytes == 0) {
      break;
    } else if (errno != EINTR) {
      break;
    }
  }

  state->running = 0;
  pw_thread_loop_signal(state->loop, false);
  return NULL;
}

static void on_process(void *userdata) {
  struct sink_state *state = userdata;
  struct pw_buffer *buffer = pw_stream_dequeue_buffer(state->stream);
  if (!buffer) {
    return;
  }

  struct spa_buffer *spa_buffer = buffer->buffer;
  if (!spa_buffer->datas[0].data || spa_buffer->datas[0].maxsize == 0) {
    pw_stream_queue_buffer(state->stream, buffer);
    return;
  }

  int16_t *dst = spa_buffer->datas[0].data;
  size_t max_frames = spa_buffer->datas[0].maxsize / sizeof(int16_t);
  size_t frames = buffer->requested ? buffer->requested : 1024;
  if (frames > max_frames) {
    frames = max_frames;
  }
  size_t copied = ring_read(state, dst, frames);
  if (copied < frames) {
    memset(dst + copied, 0, (frames - copied) * sizeof(int16_t));
  }

  spa_buffer->datas[0].chunk->offset = 0;
  spa_buffer->datas[0].chunk->stride = sizeof(int16_t) * CHANNELS;
  spa_buffer->datas[0].chunk->size = (uint32_t)(frames * sizeof(int16_t));
  pw_stream_queue_buffer(state->stream, buffer);
}

static const struct pw_stream_events stream_events = {
  PW_VERSION_STREAM_EVENTS,
  .process = on_process,
};

int main(int argc, char **argv) {
  struct sink_state state;
  memset(&state, 0, sizeof(state));
  state.running = 1;
  state.prebuffering = 1;
  pthread_mutex_init(&state.lock, NULL);

  pw_init(&argc, &argv);

  state.loop = pw_thread_loop_new("astral-pcm", NULL);
  if (!state.loop) {
    fprintf(stderr, "failed to create PipeWire loop\n");
    return 1;
  }

  state.stream = pw_stream_new_simple(
    pw_thread_loop_get_loop(state.loop),
    "AstralVerse PSG",
    pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio",
                      PW_KEY_MEDIA_CATEGORY, "Playback",
                      PW_KEY_MEDIA_ROLE, "Game",
                      NULL),
    &stream_events,
    &state);
  if (!state.stream) {
    fprintf(stderr, "failed to create PipeWire stream\n");
    return 1;
  }

  uint8_t params_buffer[1024];
  struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(params_buffer, sizeof(params_buffer));
  struct spa_audio_info_raw info = {
    .format = SPA_AUDIO_FORMAT_S16_LE,
    .rate = SAMPLE_RATE,
    .channels = CHANNELS,
    .position = { SPA_AUDIO_CHANNEL_MONO },
  };
  const struct spa_pod *params[1];
  params[0] = spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info);

  if (pw_stream_connect(state.stream,
                        PW_DIRECTION_OUTPUT,
                        PW_ID_ANY,
                        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
                        params,
                        1) < 0) {
    fprintf(stderr, "failed to connect PipeWire stream\n");
    return 1;
  }

  if (pw_thread_loop_start(state.loop) < 0) {
    fprintf(stderr, "failed to start PipeWire loop\n");
    return 1;
  }

  pthread_create(&state.input_thread, NULL, input_loop, &state);
  while (state.running) {
    usleep(10000);
  }

  pthread_join(state.input_thread, NULL);
  pw_thread_loop_stop(state.loop);
  pw_stream_destroy(state.stream);
  pw_thread_loop_destroy(state.loop);
  pthread_mutex_destroy(&state.lock);
  return 0;
}
