require 'tmpdir'

module AstralVerse
  class PsgPlayer
    BASE_FREQUENCY = 441.0
    SAMPLE_RATE = 44_100
    TONE_GAIN = 0.16
    NOISE_GAIN = 0.025

    def initialize(psg)
      @psg = psg
      @tone_sample = Gosu::Sample.new(tone_sample_path)
      @noise_sample = Gosu::Sample.new(noise_sample_path)
      @channels = Array.new(4)
    rescue StandardError => e
      warn "Audio disabled: #{e.message}"
      @disabled = true
    end

    def update
      return if @disabled || !@psg

      state = @psg.audible_state
      state[:tones].each_with_index do |tone, index|
        sync_channel(index, @tone_sample, tone[:frequency], tone[:volume])
      end

      noise = state[:noise]
      sync_channel(3, @noise_sample, noise[:frequency], noise[:volume], NOISE_GAIN)
    end

    def stop
      @channels&.each { |channel| channel&.stop }
    end

    private

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
  end
end
