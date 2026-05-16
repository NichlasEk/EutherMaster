module SmsEmulator
  class PSG
    CLOCK = 3_579_545.0
    SAMPLE_RATE = 44_100
    PSG_CLOCK = CLOCK / 16.0
    TONE_CHANNELS = 3
    CHANNELS = 4
    MAX_PERIOD = 0x3FF
    INITIAL_LFSR = 0x8000

    VOLUME_TABLE = Array.new(16) do |level|
      level == 15 ? 0.0 : 10.0**(-level * 2.0 / 20.0)
    end.freeze

    attr_reader :tone_periods, :volumes, :noise_control, :writes, :write_log

    def initialize
      reset
    end

    def reset
      @tone_periods = Array.new(TONE_CHANNELS, MAX_PERIOD)
      @volumes = Array.new(CHANNELS, 15)
      @noise_control = 0
      @noise_reload = 0x10
      @latched_channel = 0
      @latched_volume = false
      @writes = 0
      @write_log = []
      @phases = Array.new(TONE_CHANNELS, 0.0)
      @noise_lfsr = INITIAL_LFSR
      @noise_phase = 0.0
      @noise_counter_output = -1.0
      @noise_output = -1.0
    end

    def write(value, port: nil, cycle: nil)
      value &= 0xFF
      @writes += 1
      log_write(value, port, cycle)

      if (value & 0x80) != 0
        @latched_channel = (value >> 5) & 0x03
        @latched_volume = (value & 0x10) != 0
        data = value & 0x0F

        if @latched_volume
          @volumes[@latched_channel] = data
        elsif @latched_channel == 3
          write_noise_control(data)
        else
          @tone_periods[@latched_channel] = (@tone_periods[@latched_channel] & 0x3F0) | data
        end
      elsif @latched_volume
        @volumes[@latched_channel] = value & 0x0F
      elsif @latched_channel == 3
        write_noise_control(value)
      else
        @tone_periods[@latched_channel] =
          (@tone_periods[@latched_channel] & 0x00F) | ((value & 0x3F) << 4)
      end
    end

    def tone_frequency(channel)
      period = @tone_periods[channel] || 0
      period = 1 if period <= 0

      CLOCK / (32.0 * period)
    end

    def channel_volume(channel)
      VOLUME_TABLE[@volumes[channel] || 15]
    end

    def noise_frequency
      case @noise_control & 0x03
      when 0 then PSG_CLOCK / (2.0 * 0x10)
      when 1 then PSG_CLOCK / (2.0 * 0x20)
      when 2 then PSG_CLOCK / (2.0 * 0x40)
      else PSG_CLOCK / (2.0 * [@tone_periods[2], 1].max)
      end
    end

    def white_noise?
      (@noise_control & 0x04) != 0
    end

    def audible_state
      {
        tones: TONE_CHANNELS.times.map do |channel|
          { frequency: tone_frequency(channel), volume: channel_volume(channel) }
        end,
        noise: {
          frequency: noise_frequency,
          volume: channel_volume(3),
          white: white_noise?
        }
      }
    end

    def render_samples(count, sample_rate = SAMPLE_RATE)
      samples = Array.new(count, 0.0)

      count.times do |index|
        mixed = 0.0

        TONE_CHANNELS.times do |channel|
          volume = channel_volume(channel)
          next if volume <= 0.0

          frequency = tone_frequency(channel)
          next if frequency <= 0.0

          @phases[channel] += frequency / sample_rate
          @phases[channel] -= 1.0 while @phases[channel] >= 1.0
          mixed += (@phases[channel] < 0.5 ? 0.0 : 1.0) * volume
        end

        noise_volume = channel_volume(3)
        if noise_volume > 0.0
          advance_noise(sample_rate)
          mixed += (@noise_output.positive? ? 1.0 : 0.0) * noise_volume
        end

        samples[index] = ((mixed / CHANNELS) - 0.5).clamp(-1.0, 1.0)
      end

      samples
    end

    private

    def log_write(value, port, cycle)
      @write_log << {
        index: @writes,
        port: port&.to_i&.then { |p| p & 0xFF },
        cycle: cycle&.to_i,
        value: value
      }
      @write_log.shift while @write_log.length > 512
    end

    def write_noise_control(value)
      @noise_control = value & 0x07
      @noise_reload = case @noise_control & 0x03
                      when 0 then 0x10
                      when 1 then 0x20
                      when 2 then 0x40
                      else nil
                      end
      reset_noise
    end

    def reset_noise
      @noise_lfsr = INITIAL_LFSR
      @noise_phase = 0.0
      @noise_counter_output = -1.0
      @noise_output = -1.0
    end

    def advance_noise(sample_rate)
      frequency = noise_frequency
      return if frequency <= 0.0

      @noise_phase += frequency / sample_rate
      while @noise_phase >= 1.0
        @noise_phase -= 1.0
        @noise_counter_output = -@noise_counter_output
        next unless @noise_counter_output.positive?

        @noise_output = (@noise_lfsr & 1).zero? ? -1.0 : 1.0
        if white_noise?
          feedback = ((@noise_lfsr & 0x0001) ^ ((@noise_lfsr >> 3) & 0x0001)) & 1
        else
          feedback = @noise_lfsr & 0x0001
        end
        @noise_lfsr = (@noise_lfsr >> 1) | (feedback << 15)
      end
    end
  end
end
