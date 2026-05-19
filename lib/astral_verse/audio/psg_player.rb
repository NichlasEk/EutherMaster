require 'tmpdir'
require 'fileutils'
require_relative '../sdl3'

module AstralVerse
  class PsgPlayer
    BASE_FREQUENCY = 441.0
    SAMPLE_RATE = 44_100
    FRAME_CYCLES = 59_736
    TONE_GAIN = 0.16
    NOISE_GAIN = 0.025
    STREAM_GAIN = 0.38
    AUDIO_OVERSUPPLY = ENV.fetch('ASTRAL_AUDIO_OVERSUPPLY', '1.0').to_f
    PIPE_PREBUFFER_CHUNKS = ENV.fetch('ASTRAL_AUDIO_PREBUFFER_CHUNKS', '4').to_i.clamp(0, 12)
    ASYNC_AUDIO = ENV.fetch('ASTRAL_ASYNC_AUDIO', '0') == '1'
    MAX_ASYNC_JOBS = ENV.fetch('ASTRAL_AUDIO_MAX_JOBS', '8').to_i.clamp(2, 24)
    DROP_STALE_AUDIO_JOBS = ENV.fetch('ASTRAL_AUDIO_DROP_STALE', '0') == '1'
    CLOSE_SENTINEL = Object.new.freeze

    attr_accessor :volume

    def initialize(psg)
      @psg = psg
      @volume = 1.0
      @mode = ENV.fetch('ASTRAL_PSG_MODE', 'sdl')
      @sink = SdlSink.new(SAMPLE_RATE) if @mode == 'sdl'
      @sink = PcmSink.new(SAMPLE_RATE) if @mode == 'pipe'
      raise 'Only sdl and pipe PSG audio modes are supported' unless @sink
      @channels = Array.new(4)
      @chunk_index = 0
      @dc_previous_input = 0.0
      @dc_previous_output = 0.0
      @sample_credit = 0.0
      @pipe_prebuffered = false
      @sink_mutex = Mutex.new
      setup_async_audio
    rescue StandardError => e
      warn "Audio disabled: #{e.message}"
      @disabled = true
    end

    def update
      return if @disabled || !@psg

      ensure_sink
      return enqueue_audio_job if @async_audio

      return update_pipe if @sink
    end

    def cushion(frames = 1)
      return if @disabled

      ensure_sink
      return unless @sink && @sink.respond_to?(:cushion_frames)

      @sink_mutex.synchronize { @sink&.cushion_frames(frames.to_i.clamp(0, 8)) }
    end

    def stop
      @channels&.each { |channel| channel&.stop }
      @channels = Array.new(4)
      stop_async_audio
      @sink&.close
      @sink = nil
    end

    private

    def ensure_sink
      return if @sink

      @sink = SdlSink.new(SAMPLE_RATE) if @mode == 'sdl'
      @sink = PcmSink.new(SAMPLE_RATE) if @mode == 'pipe'
    rescue StandardError => e
      warn "Audio disabled: #{e.message}"
      @disabled = true
    end

    def setup_async_audio
      return unless ASYNC_AUDIO && @psg.respond_to?(:capture_frame_job)

      @async_renderer = @psg.respond_to?(:async_renderer) ? @psg.async_renderer : @psg.class.new
      @audio_jobs = Queue.new
      @async_audio = true
      @audio_worker = Thread.new { audio_worker_loop }
      @audio_worker.abort_on_exception = false
    end

    def stop_async_audio
      return unless @audio_jobs

      @async_audio = false
      @audio_jobs << CLOSE_SENTINEL
      @audio_worker&.join(0.35)
      @audio_jobs = nil
      @audio_worker = nil
      @async_renderer = nil
    end

    def enqueue_audio_job
      count = samples_for_frame
      return if count <= 0

      prebuffer_pipe(count) unless @pipe_prebuffered
      drop_stale_audio_jobs
      @audio_jobs << [@psg.capture_frame_job(count, audio_frame_cycles, SAMPLE_RATE), @volume.to_f.clamp(0.0, 1.0)]
    rescue IOError, Errno::EPIPE
      @sink&.close
      @sink = nil
      @disabled = true
    end

    def audio_worker_loop
      loop do
        item = @audio_jobs.pop
        break if item.equal?(CLOSE_SENTINEL)

        if DROP_STALE_AUDIO_JOBS
          item = latest_audio_job(item)
          break if item.equal?(CLOSE_SENTINEL)
        end

        job, volume = item
        samples = @async_renderer.render_frame_job(job)
        samples = dc_block!(samples)
        @sink_mutex.synchronize { @sink&.write_samples(samples, STREAM_GAIN * volume) }
        Thread.pass
      end
    rescue IOError, Errno::EPIPE
      @disabled = true
    rescue StandardError => e
      warn "Audio worker disabled: #{e.message}"
      @disabled = true
    end

    def drop_stale_audio_jobs
      return unless DROP_STALE_AUDIO_JOBS

      while @audio_jobs.length >= MAX_ASYNC_JOBS - 1
        @audio_jobs.pop(true)
      end
    rescue ThreadError
      nil
    end

    def latest_audio_job(item)
      latest = item
      loop do
        candidate = @audio_jobs.pop(true)
        return candidate if candidate.equal?(CLOSE_SENTINEL)

        latest = candidate
      end
    rescue ThreadError
      latest
    end

    def update_pipe
      count = samples_for_frame
      return if count <= 0

      prebuffer_pipe(count) unless @pipe_prebuffered
      samples = dc_block!(@psg.render_frame_samples(count, audio_frame_cycles, SAMPLE_RATE))
      @sink_mutex.synchronize { @sink.write_samples(samples, STREAM_GAIN * @volume.to_f.clamp(0.0, 1.0)) }
    rescue IOError, Errno::EPIPE
      @sink&.close
      @sink = nil
      @disabled = true
    end

    def samples_for_frame
      frame_samples = SAMPLE_RATE * audio_frame_cycles / audio_clock
      @sample_credit += frame_samples * AUDIO_OVERSUPPLY
      count = @sample_credit.floor
      @sample_credit -= count
      count
    end

    def audio_clock
      @psg.respond_to?(:clock) ? @psg.clock : @psg.class::CLOCK
    end

    def audio_frame_cycles
      @psg.respond_to?(:frame_cycles) ? @psg.frame_cycles : FRAME_CYCLES
    end

    def prebuffer_pipe(sample_count)
      @sink_mutex.synchronize do
        PIPE_PREBUFFER_CHUNKS.times { @sink.write_samples(Array.new(sample_count, 0.0), STREAM_GAIN) }
      end
      @pipe_prebuffered = true
    end

    def dc_block!(samples)
      samples.each_index do |index|
        sample = samples[index]
        output = sample - @dc_previous_input + 0.995 * @dc_previous_output
        @dc_previous_input = sample
        @dc_previous_output = output
        samples[index] = output.clamp(-1.0, 1.0)
      end
      samples
    end

    def sync_channel(index, sample, frequency, volume, gain = TONE_GAIN, pitch: true)
      channel = @channels[index]
      audible = volume.positive? && frequency.positive?

      unless audible
        channel&.volume = 0.0
        return
      end

      unless channel&.playing?
        channel = sample.play(0.0, 1.0, true)
        @channels[index] = channel
      end

      channel.speed = pitch ? (frequency / BASE_FREQUENCY).clamp(0.05, 8.0) : 1.0
      channel.volume = (volume * gain).clamp(0.0, 1.0)
    end

    def tone_sample_path
      path = File.join(Dir.tmpdir, 'astral_verse_psg_square_v2.wav')
      write_wav(path, square_wave) unless File.exist?(path)
      path
    end

    def noise_sample_path
      path = File.join(Dir.tmpdir, 'astral_verse_psg_noise_v2.wav')
      write_wav(path, noise_wave) unless File.exist?(path)
      path
    end

    def chunk_sample_path
      @chunk_index = (@chunk_index + 1) & 7
      File.join(Dir.tmpdir, "astral_verse_psg_frame_#{@chunk_index}.wav")
    end

    def square_wave
      Array.new(100) { |index| index < 50 ? 9_000 : -9_000 }
    end

    def noise_wave
      seed = 0xACE1
      Array.new(SAMPLE_RATE / 4) do
        bit = ((seed >> 0) ^ (seed >> 2) ^ (seed >> 3) ^ (seed >> 5)) & 1
        seed = (seed >> 1) | (bit << 15)
        (seed & 1).zero? ? -5_000 : 5_000
      end
    end

    def write_wav(path, samples)
      data = samples.pack('s<*')
      header = +"RIFF"
      header << [36 + data.bytesize].pack('V')
      header << "WAVEfmt "
      header << [16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16].pack('VvvVVvv')
      header << "data"
      header << [data.bytesize].pack('V')
      File.binwrite(path, header << data)
    end

    class PcmSink
      MAX_PENDING_CHUNKS = 24
      DEFAULT_LATENCY_MS = 120
      CLOSE_SENTINEL = Object.new.freeze

      def initialize(sample_rate)
        @sample_rate = sample_rate
        @pid, @io = spawn_sink
        @queue = Queue.new
        @closed = false
        @failed = false
        @writer_thread = Thread.new { writer_loop }
        @writer_thread.abort_on_exception = false
      end

      def write_samples(samples, gain)
        raise IOError, 'PCM sink closed' if @closed || @failed

        drop_stale_chunks
        @queue << [samples, gain]
      end

      def close
        return if @closed

        @closed = true
        @queue << CLOSE_SENTINEL if @queue
        @writer_thread&.join(0.25)
        @io&.close
      rescue IOError
        # Already closed.
      ensure
        if @pid
          begin
            Process.kill('TERM', @pid)
            Process.detach(@pid)
          rescue Errno::ESRCH, Errno::ECHILD
            nil
          end
        end
        @io = nil
        @pid = nil
      end

      private

      def writer_loop
        loop do
          item = @queue.pop
          break if item.equal?(CLOSE_SENTINEL)

          samples, gain = item
          data = samples.map { |sample| (sample * gain * 32_000).clamp(-32_768, 32_767).to_i }.pack('s<*')
          @io.write(data)
        end
      rescue IOError, Errno::EPIPE
        @failed = true
      end

      def drop_stale_chunks
        while @queue.length >= MAX_PENDING_CHUNKS
          @queue.pop(true)
        end
      rescue ThreadError
        nil
      end

      def spawn_sink
        command = if (native = native_sink_command)
                    native
                  elsif executable?('pw-cat')
                    latency = ENV.fetch('ASTRAL_AUDIO_LATENCY_MS', DEFAULT_LATENCY_MS.to_s)
                    ['pw-cat', '--playback', '--raw', '--rate', @sample_rate.to_s,
                     '--channels', '1', '--format', 's16', '--latency', "#{latency}ms", '-']
                  elsif executable?('aplay')
                    ['aplay', '-q', '-t', 'raw', '-f', 'S16_LE', '-r', @sample_rate.to_s, '-c', '1', '-']
                  end
        raise 'No PCM audio sink found' unless command

        reader, writer = IO.pipe
        reader.binmode
        writer.binmode
        pid = Process.spawn(*command, in: reader, out: File::NULL, err: File::NULL)
        reader.close
        [pid, writer]
      rescue StandardError
        reader&.close rescue nil
        writer&.close rescue nil
        raise
      end

      def native_sink_command
        root = File.expand_path('../../..', __dir__)
        source = File.join(root, 'native', 'pipewire_pcm_sink.c')
        binary = File.join(root, 'tmp', 'pipewire_pcm_sink')
        return nil unless File.exist?(source) && executable?('pkg-config') && executable?('cc')
        return [binary] if File.executable?(binary) && File.mtime(binary) >= File.mtime(source)

        FileUtils.mkdir_p(File.dirname(binary))
        cflags = `pkg-config --cflags --libs libpipewire-0.3`.split
        return nil unless $?.success?

        system('cc', source, '-o', binary, *cflags, '-pthread', out: File::NULL, err: File::NULL)
        File.executable?(binary) ? [binary] : nil
      end

      def executable?(name)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, name)
          File.file?(path) && File.executable?(path)
        end
      end
    end

    class SdlSink
      BYTES_PER_SAMPLE = 2
      PREBUFFER_MS = ENV.fetch('ASTRAL_SDL_AUDIO_PREBUFFER_MS', '140').to_i.clamp(20, 350)
      LOW_WATER_MS = ENV.fetch('ASTRAL_SDL_AUDIO_LOW_WATER_MS', '120').to_i.clamp(20, 300)
      MAX_QUEUE_MS = ENV.fetch('ASTRAL_SDL_AUDIO_MAX_QUEUE_MS', '320').to_i.clamp(80, 800)

      def initialize(sample_rate)
        @sample_rate = sample_rate
        @stream = open_stream
        @closed = false
        @last_pcm = 0
        @last_pcm_frame = []
        prebuffer_silence
        SDL3.check(SDL3.resume_audio_stream_device(@stream), 'SDL_ResumeAudioStreamDevice')
      end

      def write_samples(samples, gain)
        raise IOError, 'SDL audio stream closed' if @closed

        queued = SDL3.get_audio_stream_queued(@stream)
        if queued > max_queue_bytes
          SDL3.clear_audio_stream(@stream)
          queued = 0
        end
        pcm = samples.map { |sample| (sample * gain * 32_000).clamp(-32_768, 32_767).to_i }
        @last_pcm = pcm[-1] || @last_pcm
        @last_pcm_frame = pcm unless pcm.empty?
        pad_samples = low_water_samples - (queued / BYTES_PER_SAMPLE) - pcm.length
        if pad_samples.positive?
          data = (pcm + loop_pcm(pad_samples)).pack('s<*')
        else
          data = pcm.pack('s<*')
        end
        SDL3.check(SDL3.put_audio_stream_data(@stream, FFI::MemoryPointer.from_string(data), data.bytesize), 'SDL_PutAudioStreamData')
      end

      def cushion_frames(frames)
        return if @closed || frames <= 0

        queued = SDL3.get_audio_stream_queued(@stream)
        return if queued >= low_water_samples * BYTES_PER_SAMPLE

        samples = [low_water_samples - (queued / BYTES_PER_SAMPLE), frame_samples * frames].min
        return if samples <= 0

        data = loop_pcm(samples).pack('s<*')
        SDL3.check(SDL3.put_audio_stream_data(@stream, FFI::MemoryPointer.from_string(data), data.bytesize), 'SDL_PutAudioStreamData cushion')
      end

      def queued_samples
        SDL3.get_audio_stream_queued(@stream) / BYTES_PER_SAMPLE
      end

      def close
        return if @closed

        @closed = true
        SDL3.destroy_audio_stream(@stream) if @stream && !@stream.null?
      end

      private

      def open_stream
        spec = SDL3::AudioSpec.new
        spec[:format] = SDL3::AUDIO_S16
        spec[:channels] = 1
        spec[:freq] = @sample_rate
        SDL3.check(SDL3.open_audio_device_stream(SDL3::AUDIO_DEVICE_DEFAULT_PLAYBACK, spec, nil, nil), 'SDL_OpenAudioDeviceStream')
      end

      def prebuffer_silence
        samples = (@sample_rate * PREBUFFER_MS / 1000.0).round
        data = Array.new(samples, 0).pack('s<*')
        SDL3.check(SDL3.put_audio_stream_data(@stream, FFI::MemoryPointer.from_string(data), data.bytesize), 'SDL_PutAudioStreamData prebuffer')
      end

      def max_queue_bytes
        (@sample_rate * MAX_QUEUE_MS / 1000.0).round * BYTES_PER_SAMPLE
      end

      def low_water_samples
        (@sample_rate * LOW_WATER_MS / 1000.0).round
      end

      def frame_samples
        (@sample_rate / 60.0).round
      end

      def loop_pcm(samples)
        frame = @last_pcm_frame
        return Array.new(samples, @last_pcm) if frame.empty?

        output = Array.new(samples)
        index = 0
        frame_index = 0
        frame_length = frame.length
        while index < samples
          output[index] = frame[frame_index]
          frame_index += 1
          frame_index = 0 if frame_index >= frame_length
          index += 1
        end
        output
      end
    end
  end
end
