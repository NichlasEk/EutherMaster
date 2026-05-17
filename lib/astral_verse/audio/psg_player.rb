require 'tmpdir'
require 'fileutils'

module AstralVerse
  class PsgPlayer
    BASE_FREQUENCY = 441.0
    SAMPLE_RATE = 44_100
    FRAME_CYCLES = 59_736
    TONE_GAIN = 0.16
    NOISE_GAIN = 0.025
    STREAM_GAIN = 0.38
    AUDIO_OVERSUPPLY = ENV.fetch('ASTRAL_AUDIO_OVERSUPPLY', '1.0005').to_f
    PIPE_PREBUFFER_CHUNKS = ENV.fetch('ASTRAL_AUDIO_PREBUFFER_CHUNKS', '4').to_i.clamp(0, 12)

    def initialize(psg)
      @psg = psg
      @mode = ENV.fetch('ASTRAL_PSG_MODE', 'pipe')
      @sink = PcmSink.new(SAMPLE_RATE) if @mode == 'pipe'
      raise 'Only pipe PSG audio is supported in the SDL3 backend' unless @sink
      @channels = Array.new(4)
      @chunk_index = 0
      @dc_previous_input = 0.0
      @dc_previous_output = 0.0
      @sample_credit = 0.0
      @pipe_prebuffered = false
    rescue StandardError => e
      warn "Audio disabled: #{e.message}"
      @disabled = true
    end

    def update
      return if @disabled || !@psg

      return update_pipe if @sink
    end

    def stop
      @channels&.each { |channel| channel&.stop }
      @channels = Array.new(4)
      @sink&.close
      @sink = nil
    end

    private

    def update_pipe
      count = samples_for_frame
      prebuffer_pipe(count) unless @pipe_prebuffered
      samples = dc_block!(@psg.render_frame_samples(count, FRAME_CYCLES, SAMPLE_RATE))
      @sink.write_samples(samples, STREAM_GAIN)
    rescue IOError, Errno::EPIPE
      @sink&.close
      @sink = nil
      @disabled = true
    end

    def samples_for_frame
      @sample_credit += SAMPLE_RATE * FRAME_CYCLES / @psg.class::CLOCK * AUDIO_OVERSUPPLY
      count = @sample_credit.floor
      @sample_credit -= count
      count
    end

    def prebuffer_pipe(sample_count)
      PIPE_PREBUFFER_CHUNKS.times { @sink.write_samples(Array.new(sample_count, 0.0), STREAM_GAIN) }
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
  end
end
