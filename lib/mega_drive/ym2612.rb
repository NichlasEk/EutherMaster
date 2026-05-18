module MegaDrive
  class YM2612
    CLOCK = 7_670_454.0
    CHANNELS = 6
    OPERATORS = 4
    SAMPLE_RATE = 44_100
    TWO_PI = Math::PI * 2.0

    VOLUME_TABLE = Array.new(128) { |tl| 10.0**(-tl / 20.0) }.freeze

    attr_reader :registers, :status, :writes, :write_log

    def initialize
      reset
    end

    def reset
      @registers = Array.new(2) { Array.new(0x100, 0) }
      @address = [0, 0]
      @status = 0
      @busy_cycles = 0
      @timer_a_latch = 0
      @timer_b_latch = 0
      @timer_a_counter = 0
      @timer_b_counter = 0
      @timer_control = 0
      @key_mask = Array.new(CHANNELS, 0)
      @fnum = Array.new(CHANNELS, 0)
      @block = Array.new(CHANNELS, 0)
      @algorithm = Array.new(CHANNELS, 0)
      @feedback = Array.new(CHANNELS, 0)
      @pan_l = Array.new(CHANNELS, true)
      @pan_r = Array.new(CHANNELS, true)
      @total_level = Array.new(CHANNELS * OPERATORS, 127)
      @multiple = Array.new(CHANNELS * OPERATORS, 1)
      @phase = Array.new(CHANNELS * OPERATORS, 0.0)
      @envelope = Array.new(CHANNELS * OPERATORS, 0.0)
      @dac_enabled = false
      @dac_sample = 0.0
      @writes = 0
      @write_log = []
      @frame_start_state = capture_render_state
      @frame_writes = []
    end

    def begin_frame
      @frame_start_state = capture_render_state
      @frame_writes = []
    end

    def read_register(_address = 0)
      value = @status & 0x03
      value |= 0x80 if @busy_cycles.positive?
      value
    end

    def write_address_1(value)
      @address[0] = value & 0xFF
    end

    def write_address_2(value)
      @address[1] = value & 0xFF
    end

    def write_data(value, port: 0, cycle: nil)
      port &= 1
      reg = @address[port]
      write_register(port, reg, value, cycle: cycle)
    end

    def write_port(offset, value, cycle: nil)
      case offset & 0x03
      when 0 then write_address_1(value)
      when 1 then write_data(value, port: 0, cycle: cycle)
      when 2 then write_address_2(value)
      when 3 then write_data(value, port: 1, cycle: cycle)
      end
    end

    def write_register(port, reg, value, cycle: nil, log: true)
      port &= 1
      reg &= 0xFF
      value &= 0xFF
      @registers[port][reg] = value
      @writes += 1 if log
      @write_log << { index: @writes, port: port, reg: reg, value: value, cycle: cycle&.to_i } if log
      @write_log.shift while @write_log.length > 512
      @frame_writes << { port: port, reg: reg, value: value, cycle: cycle.to_i } if log && @frame_writes
      @busy_cycles = 32
      apply_register(port, reg, value)
    end

    def tick(cycles)
      cycles = cycles.to_i
      @busy_cycles = [@busy_cycles - cycles, 0].max
      tick_timers(cycles)
    end

    def render_frame_samples(count, frame_cycles, sample_rate = SAMPLE_RATE)
      writes = @frame_writes || []
      write_index = 0
      restore_render_state(@frame_start_state || capture_render_state)
      samples = Array.new(count) { [0.0, 0.0] }

      count.times do |sample_index|
        cycle = (sample_index * frame_cycles / count.to_f).floor
        while write_index < writes.length && writes[write_index][:cycle] <= cycle
          write = writes[write_index]
          write_register(write[:port], write[:reg], write[:value], log: false)
          write_index += 1
        end
        samples[sample_index] = render_sample(sample_rate)
      end

      samples
    end

    private

    def apply_register(port, reg, value)
      case reg
      when 0x24
        @timer_a_latch = (@timer_a_latch & 0x003) | (value << 2)
      when 0x25
        @timer_a_latch = (@timer_a_latch & 0x3FC) | (value & 0x03)
      when 0x26
        @timer_b_latch = value
      when 0x27
        @timer_control = value
        @status &= ~0x01 if (value & 0x10) != 0
        @status &= ~0x02 if (value & 0x20) != 0
        load_timer_a if (value & 0x01) != 0
        load_timer_b if (value & 0x02) != 0
      when 0x28
        write_key_on(value)
      when 0x2A
        @dac_sample = ((value - 0x80) / 128.0).clamp(-1.0, 1.0)
      when 0x2B
        @dac_enabled = (value & 0x80) != 0
      when 0x30..0x9F
        write_operator_register(port, reg, value)
      when 0xA0..0xA2
        channel = channel_index(port, reg & 0x03)
        @fnum[channel] = (@fnum[channel] & 0x700) | value if channel
      when 0xA4..0xA6
        channel = channel_index(port, reg & 0x03)
        if channel
          @fnum[channel] = (@fnum[channel] & 0x0FF) | ((value & 0x07) << 8)
          @block[channel] = (value >> 3) & 0x07
        end
      when 0xB0..0xB2
        channel = channel_index(port, reg & 0x03)
        if channel
          @algorithm[channel] = value & 0x07
          @feedback[channel] = (value >> 3) & 0x07
        end
      when 0xB4..0xB6
        channel = channel_index(port, reg & 0x03)
        if channel
          @pan_l[channel] = (value & 0x80) != 0
          @pan_r[channel] = (value & 0x40) != 0
          @pan_l[channel] = @pan_r[channel] = true unless @pan_l[channel] || @pan_r[channel]
        end
      end
    end

    def write_key_on(value)
      channel = (value & 0x03) + ((value & 0x04) != 0 ? 3 : 0)
      return unless channel < CHANNELS

      old = @key_mask[channel]
      mask = (value >> 4) & 0x0F
      @key_mask[channel] = mask
      if old.zero? && mask.positive?
        OPERATORS.times do |op|
          idx = channel * OPERATORS + op
          @phase[idx] = 0.0
          @envelope[idx] = 1.0
        end
      end
    end

    def tick_timers(cycles)
      if (@timer_control & 0x04) != 0
        @timer_a_counter -= cycles
        if @timer_a_counter <= 0
          @status |= 0x01
          load_timer_a
        end
      end

      return if (@timer_control & 0x08).zero?

      @timer_b_counter -= cycles
      return unless @timer_b_counter <= 0

      @status |= 0x02
      load_timer_b
    end

    def load_timer_a
      @timer_a_counter = [(1024 - (@timer_a_latch & 0x3FF)) * 18, 18].max
    end

    def load_timer_b
      @timer_b_counter = [(256 - (@timer_b_latch & 0xFF)) * 288, 288].max
    end

    def write_operator_register(port, reg, value)
      slot = reg & 0x03
      return if slot == 3

      channel = channel_index(port, slot)
      return unless channel

      op = operator_index(reg)
      idx = channel * OPERATORS + op
      case reg & 0xF0
      when 0x30
        @multiple[idx] = [value & 0x0F, 1].max
      when 0x40
        @total_level[idx] = value & 0x7F
      end
    end

    def channel_index(port, slot)
      return nil if slot > 2

      port * 3 + slot
    end

    def operator_index(reg)
      case (reg >> 2) & 0x03
      when 0 then 0
      when 1 then 2
      when 2 then 1
      else 3
      end
    end

    def render_sample(sample_rate)
      left = 0.0
      right = 0.0

      CHANNELS.times do |channel|
        next if @key_mask[channel].zero?

        sample = channel_sample(channel, sample_rate)
        sample = @dac_sample if channel == 5 && @dac_enabled
        left += sample if @pan_l[channel]
        right += sample if @pan_r[channel]
      end

      [(left / CHANNELS).clamp(-1.0, 1.0), (right / CHANNELS).clamp(-1.0, 1.0)]
    end

    def channel_sample(channel, sample_rate)
      base = channel_frequency(channel)
      return 0.0 if base <= 0.0

      sample = 0.0
      carriers = @algorithm[channel] >= 4 ? [0, 1, 2, 3] : [3]
      carriers.each do |op|
        idx = channel * OPERATORS + op
        next if (@key_mask[channel] & (1 << op)).zero?

        @phase[idx] += base * @multiple[idx] / sample_rate
        @phase[idx] -= 1.0 while @phase[idx] >= 1.0
        amp = VOLUME_TABLE[@total_level[idx]]
        sample += Math.sin(@phase[idx] * TWO_PI) * amp * @envelope[idx]
        @envelope[idx] *= 0.99998
      end
      sample / carriers.length
    end

    def channel_frequency(channel)
      fnum = @fnum[channel]
      return 0.0 if fnum.zero?

      # Approximate OPN2 pitch conversion. Good enough for early audible state.
      440.0 * (fnum / 0x26A.to_f) * (2.0**(@block[channel] - 4))
    end

    def capture_render_state
      {
        registers: @registers.map(&:dup),
        key_mask: @key_mask.dup,
        fnum: @fnum.dup,
        block: @block.dup,
        algorithm: @algorithm.dup,
        feedback: @feedback.dup,
        pan_l: @pan_l.dup,
        pan_r: @pan_r.dup,
        total_level: @total_level.dup,
        multiple: @multiple.dup,
        phase: @phase.dup,
        envelope: @envelope.dup,
        dac_enabled: @dac_enabled,
        dac_sample: @dac_sample,
        timer_a_counter: @timer_a_counter,
        timer_b_counter: @timer_b_counter,
        timer_control: @timer_control,
        status: @status,
        busy_cycles: @busy_cycles
      }
    end

    def restore_render_state(state)
      @registers = state[:registers].map(&:dup)
      @key_mask = state[:key_mask].dup
      @fnum = state[:fnum].dup
      @block = state[:block].dup
      @algorithm = state[:algorithm].dup
      @feedback = state[:feedback].dup
      @pan_l = state[:pan_l].dup
      @pan_r = state[:pan_r].dup
      @total_level = state[:total_level].dup
      @multiple = state[:multiple].dup
      @phase = state[:phase].dup
      @envelope = state[:envelope].dup
      @dac_enabled = state[:dac_enabled]
      @dac_sample = state[:dac_sample]
      @timer_a_counter = state[:timer_a_counter] || 0
      @timer_b_counter = state[:timer_b_counter] || 0
      @timer_control = state[:timer_control] || 0
      @status = state[:status] || @status
      @busy_cycles = state[:busy_cycles] || @busy_cycles
    end
  end
end
