module MegaDrive
  class YM2612
    CLOCK = 7_670_454.0
    CHANNELS = 6
    OPERATORS = 4
    SAMPLE_RATE = 44_100
    TWO_PI = Math::PI * 2.0
    SINE_SIZE = 2048
    SINE_MASK = SINE_SIZE - 1
    SINE_INDEX_SCALE = SINE_SIZE / TWO_PI
    MODULATION_DEPTH = 8.0
    WRITE_BUSY_CYCLES = 1_344
    TIMER_TICK_CYCLES = 72

    VOLUME_TABLE = Array.new(128) { |tl| 10.0**(-(tl * 0.75) / 20.0) }.freeze
    SINE_TABLE = Array.new(SINE_SIZE) { |i| Math.sin(i * TWO_PI / SINE_SIZE) }.freeze
    ATTACK_STEPS = Array.new(32) { |rate| rate.zero? ? 0.0 : 0.00035 * (2.0**(rate / 4.0)) }.freeze
    DECAY_STEPS = Array.new(32) { |rate| rate.zero? ? 0.0 : 0.000006 * (2.0**(rate / 4.0)) }.freeze
    RELEASE_STEPS = Array.new(16) { |rate| 0.00002 * (2.0**((rate + 1) / 3.0)) }.freeze
    SUSTAIN_TARGETS = Array.new(16) { |level| level >= 15 ? 0.0 : 10.0**(-(level * 3.0) / 20.0) }.freeze
    MULTIPLE_RATIOS = [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 10.0, 12.0, 12.0, 15.0, 15.0].freeze
    CARRIER_OPERATORS = [
      [3],
      [3],
      [3],
      [3],
      [1, 3],
      [1, 2, 3],
      [1, 2, 3],
      [0, 1, 2, 3]
    ].freeze

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
      @timer_a_enabled = false
      @timer_b_enabled = false
      @last_status_read = 0
      @key_mask = Array.new(CHANNELS, 0)
      @fnum = Array.new(CHANNELS, 0)
      @block = Array.new(CHANNELS, 0)
      @operator_fnum = Array.new(CHANNELS * OPERATORS, 0)
      @operator_block = Array.new(CHANNELS * OPERATORS, 0)
      @algorithm = Array.new(CHANNELS, 0)
      @feedback = Array.new(CHANNELS, 0)
      @pan_l = Array.new(CHANNELS, true)
      @pan_r = Array.new(CHANNELS, true)
      @total_level = Array.new(CHANNELS * OPERATORS, 127)
      @multiple = Array.new(CHANNELS * OPERATORS, 1)
      @multiple_ratio = Array.new(CHANNELS * OPERATORS, 1.0)
      @detune = Array.new(CHANNELS * OPERATORS, 0)
      @attack_rate = Array.new(CHANNELS * OPERATORS, 0)
      @decay_rate = Array.new(CHANNELS * OPERATORS, 0)
      @sustain_rate = Array.new(CHANNELS * OPERATORS, 0)
      @sustain_level = Array.new(CHANNELS * OPERATORS, 15)
      @release_rate = Array.new(CHANNELS * OPERATORS, 0)
      @phase = Array.new(CHANNELS * OPERATORS, 0.0)
      @envelope = Array.new(CHANNELS * OPERATORS, 0.0)
      @envelope_stage = Array.new(CHANNELS * OPERATORS, :off)
      @operator_output = Array.new(CHANNELS * OPERATORS, 0.0)
      @operator_last_output = Array.new(CHANNELS * OPERATORS, 0.0)
      @dac_enabled = false
      @dac_sample = 0.0
      @writes = 0
      @write_log = []
      @frame_start_state = capture_render_state
      @frame_writes = []
    end

    def begin_frame
      ensure_operator_state!
      @frame_start_state = capture_render_state
      @frame_writes = []
    end

    def read_register(address = 0)
      offset = address.to_i & 0x03
      return @last_status_read unless offset.zero?

      value = @status & 0x03
      value |= 0x80 if @busy_cycles.positive?
      @last_status_read = value
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
      @busy_cycles = WRITE_BUSY_CYCLES
      apply_register(port, reg, value)
    end

    def tick(cycles)
      cycles = cycles.to_i
      @busy_cycles = [@busy_cycles - cycles, 0].max
      tick_timers(cycles)
    end

    def render_frame_samples(count, frame_cycles, sample_rate = SAMPLE_RATE)
      ensure_operator_state!
      writes = @frame_writes || []
      write_index = 0
      live_state = capture_render_state
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

      rendered_phase = @phase.dup
      rendered_envelope = @envelope.dup
      restore_render_state(live_state)
      @phase = rendered_phase
      @envelope = rendered_envelope
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
        old_control = @timer_control
        @timer_control = value
        @status &= ~0x01 if (value & 0x10) != 0
        @status &= ~0x02 if (value & 0x20) != 0
        timer_a_load = (value & 0x01) != 0
        timer_b_load = (value & 0x02) != 0
        old_timer_a_load = (old_control & 0x01) != 0
        old_timer_b_load = (old_control & 0x02) != 0
        @timer_a_enabled = timer_a_load
        @timer_b_enabled = timer_b_load
        load_timer_a if timer_a_load && !old_timer_a_load
        load_timer_b if timer_b_load && !old_timer_b_load
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
      when 0xA8..0xAA
        write_special_operator_frequency(port, reg, value, high: false)
      when 0xAC..0xAE
        write_special_operator_frequency(port, reg, value, high: true)
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

      ensure_operator_state!
      old = @key_mask[channel]
      mask = (value >> 4) & 0x0F
      @key_mask[channel] = mask

      OPERATORS.times do |op|
        bit = 1 << op
        idx = channel * OPERATORS + op
        if (mask & bit) != 0 && (old & bit).zero?
          @phase[idx] = 0.0
          @operator_output[idx] = 0.0
          @operator_last_output[idx] = 0.0
          @envelope[idx] = 0.0
          @envelope_stage[idx] = :attack
        elsif (mask & bit).zero? && (old & bit) != 0
          @envelope_stage[idx] = :release unless @envelope_stage[idx] == :off
        end
      end
    end

    def tick_timers(cycles)
      if @timer_a_enabled
        @timer_a_counter -= cycles
        while @timer_a_counter <= 0
          @status |= 0x01 if (@timer_control & 0x04) != 0
          @timer_a_counter += timer_a_period
        end
      end

      return unless @timer_b_enabled

      @timer_b_counter -= cycles
      while @timer_b_counter <= 0
        @status |= 0x02 if (@timer_control & 0x08) != 0
        @timer_b_counter += timer_b_period
      end
    end

    def load_timer_a
      @timer_a_counter = timer_a_period
    end

    def load_timer_b
      @timer_b_counter = timer_b_period
    end

    def timer_a_period
      [(1024 - (@timer_a_latch & 0x3FF)) * TIMER_TICK_CYCLES, TIMER_TICK_CYCLES].max
    end

    def timer_b_period
      [(256 - (@timer_b_latch & 0xFF)) * 16 * TIMER_TICK_CYCLES, 16 * TIMER_TICK_CYCLES].max
    end

    def write_operator_register(port, reg, value)
      ensure_operator_state!
      slot = reg & 0x03
      return if slot == 3

      channel = channel_index(port, slot)
      return unless channel

      op = operator_index(reg)
      idx = channel * OPERATORS + op
      case reg & 0xF0
      when 0x30
        @multiple[idx] = value & 0x0F
        @multiple_ratio[idx] = MULTIPLE_RATIOS[@multiple[idx]]
        @detune[idx] = (value >> 4) & 0x07
      when 0x40
        @total_level[idx] = value & 0x7F
      when 0x50
        @attack_rate[idx] = value & 0x1F
      when 0x60
        @decay_rate[idx] = value & 0x1F
      when 0x70
        @sustain_rate[idx] = value & 0x1F
      when 0x80
        @sustain_level[idx] = (value >> 4) & 0x0F
        @release_rate[idx] = value & 0x0F
      end
    end

    def write_special_operator_frequency(port, reg, value, high:)
      channel = port * 3 + 2
      op = special_frequency_operator(reg)
      idx = channel * OPERATORS + op
      if high
        @operator_fnum[idx] = (@operator_fnum[idx] & 0x0FF) | ((value & 0x07) << 8)
        @operator_block[idx] = (value >> 3) & 0x07
      else
        @operator_fnum[idx] = (@operator_fnum[idx] & 0x700) | value
      end
    end

    def special_frequency_operator(reg)
      case reg & 0x0F
      when 0x08, 0x0C then 2
      when 0x09, 0x0D then 0
      else 1
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
        next unless channel_active?(channel)

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

      base_index = channel * OPERATORS
      feedback = if @feedback[channel].positive?
                   (@operator_output[base_index] + @operator_last_output[base_index]) * (2.0**(@feedback[channel] - 7))
                 else
                   0.0
                 end

      sample = case @algorithm[channel]
               when 0
                 o0 = operator_sample(base_index, operator_frequency(channel, 0, base), sample_rate, feedback)
                 o1 = operator_sample(base_index + 1, operator_frequency(channel, 1, base), sample_rate, o0 * 2.0)
                 o2 = operator_sample(base_index + 2, operator_frequency(channel, 2, base), sample_rate, o1 * 2.0)
                 operator_sample(base_index + 3, base, sample_rate, o2 * 2.0)
               when 1
                 o0 = operator_sample(base_index, operator_frequency(channel, 0, base), sample_rate, feedback)
                 o1 = operator_sample(base_index + 1, operator_frequency(channel, 1, base), sample_rate)
                 o2 = operator_sample(base_index + 2, operator_frequency(channel, 2, base), sample_rate, (o0 + o1) * 1.5)
                 operator_sample(base_index + 3, base, sample_rate, o2 * 2.0)
               when 2
                 o0 = operator_sample(base_index, operator_frequency(channel, 0, base), sample_rate, feedback)
                 o1 = operator_sample(base_index + 1, operator_frequency(channel, 1, base), sample_rate)
                 o2 = operator_sample(base_index + 2, operator_frequency(channel, 2, base), sample_rate, o1 * 2.0)
                 operator_sample(base_index + 3, base, sample_rate, (o0 + o2) * 1.5)
               when 3
                 o0 = operator_sample(base_index, operator_frequency(channel, 0, base), sample_rate, feedback)
                 o1 = operator_sample(base_index + 1, operator_frequency(channel, 1, base), sample_rate, o0 * 2.0)
                 o2 = operator_sample(base_index + 2, operator_frequency(channel, 2, base), sample_rate)
                 operator_sample(base_index + 3, base, sample_rate, (o1 + o2) * 1.5)
               when 4
                 o0 = operator_sample(base_index, operator_frequency(channel, 0, base), sample_rate, feedback)
                 o1 = operator_sample(base_index + 1, operator_frequency(channel, 1, base), sample_rate, o0 * 2.0)
                 o2 = operator_sample(base_index + 2, operator_frequency(channel, 2, base), sample_rate)
                 o3 = operator_sample(base_index + 3, base, sample_rate, o2 * 2.0)
                 (o1 + o3) * 0.5
               when 5
                 mod = operator_sample(base_index, operator_frequency(channel, 0, base), sample_rate, feedback)
                 o1 = operator_sample(base_index + 1, operator_frequency(channel, 1, base), sample_rate, mod * 2.0)
                 o2 = operator_sample(base_index + 2, operator_frequency(channel, 2, base), sample_rate, mod * 2.0)
                 o3 = operator_sample(base_index + 3, base, sample_rate, mod * 2.0)
                 (o1 + o2 + o3) / 3.0
               when 6
                 o0 = operator_sample(base_index, operator_frequency(channel, 0, base), sample_rate, feedback)
                 o1 = operator_sample(base_index + 1, operator_frequency(channel, 1, base), sample_rate, o0 * 2.0)
                 o2 = operator_sample(base_index + 2, operator_frequency(channel, 2, base), sample_rate)
                 o3 = operator_sample(base_index + 3, base, sample_rate)
                 (o1 + o2 + o3) / 3.0
               else
                 o0 = operator_sample(base_index, operator_frequency(channel, 0, base), sample_rate, feedback)
                 o1 = operator_sample(base_index + 1, operator_frequency(channel, 1, base), sample_rate)
                 o2 = operator_sample(base_index + 2, operator_frequency(channel, 2, base), sample_rate)
                 o3 = operator_sample(base_index + 3, base, sample_rate)
                 (o0 + o1 + o2 + o3) * 0.25
               end

      sample.clamp(-1.0, 1.0)
    end

    def channel_frequency(channel)
      fnum = @fnum[channel]
      return 0.0 if fnum.zero?

      # Approximate OPN2 pitch conversion. Good enough for early audible state.
      440.0 * (fnum / 0x26A.to_f) * (2.0**(@block[channel] - 4))
    end

    def operator_frequency(channel, op, fallback)
      return fallback if op == 3 || (@timer_control & 0xC0).zero?

      idx = channel * OPERATORS + op
      fnum = @operator_fnum[idx]
      return fallback if fnum.zero?

      440.0 * (fnum / 0x26A.to_f) * (2.0**(@operator_block[idx] - 4))
    end

    def operator_sample(idx, base, sample_rate, modulation = 0.0)
      @operator_last_output[idx] = @operator_output[idx]
      advance_envelope(idx)
      return @operator_output[idx] = 0.0 if @envelope_stage[idx] == :off && @envelope[idx] <= 0.0001

      phase = @phase[idx] + (base * @multiple_ratio[idx] / sample_rate)
      phase -= phase.to_i if phase >= 1.0
      @phase[idx] = phase
      amp = VOLUME_TABLE[@total_level[idx]] * @envelope[idx]
      @operator_output[idx] = SINE_TABLE[((phase * SINE_SIZE) + (modulation * MODULATION_DEPTH * SINE_INDEX_SCALE)).to_i & SINE_MASK] * amp
    end

    def advance_envelope(idx)
      case @envelope_stage[idx]
      when :attack
        rate = @attack_rate[idx]
        if rate >= 31
          @envelope[idx] = 1.0
        elsif rate.positive?
          @envelope[idx] += (1.0 - @envelope[idx]) * ATTACK_STEPS[rate]
        end
        if @envelope[idx] >= 0.995 || rate >= 31
          @envelope[idx] = 1.0
          @envelope_stage[idx] = :decay
        end
      when :decay
        sustain = sustain_target(idx)
        if @envelope[idx] > sustain
          @envelope[idx] = [@envelope[idx] - DECAY_STEPS[@decay_rate[idx]], sustain].max
        else
          @envelope_stage[idx] = :sustain
        end
      when :sustain
        rate = @sustain_rate[idx]
        @envelope[idx] = [@envelope[idx] - DECAY_STEPS[rate] * 0.35, 0.0].max if rate.positive?
      when :release
        @envelope[idx] = [@envelope[idx] - RELEASE_STEPS[@release_rate[idx]], 0.0].max
        @envelope_stage[idx] = :off if @envelope[idx] <= 0.0001
      else
        @envelope[idx] = 0.0
      end
    end

    def sustain_target(idx)
      SUSTAIN_TARGETS[@sustain_level[idx]]
    end

    def channel_active?(channel)
      return true if channel == 5 && @dac_enabled
      return true unless @key_mask[channel].zero?

      base = channel * OPERATORS
      OPERATORS.times.any? { |op| @envelope_stage[base + op] != :off && @envelope[base + op] > 0.0001 }
    end

    def ensure_operator_state!
      count = CHANNELS * OPERATORS
      @attack_rate ||= Array.new(count, 0)
      @decay_rate ||= Array.new(count, 0)
      @sustain_rate ||= Array.new(count, 0)
      @sustain_level ||= Array.new(count, 15)
      @release_rate ||= Array.new(count, 0)
      @multiple_ratio ||= Array.new(count) { |idx| MULTIPLE_RATIOS[@multiple[idx] || 1] }
      @detune ||= Array.new(count, 0)
      @operator_fnum ||= Array.new(count, 0)
      @operator_block ||= Array.new(count, 0)
      @envelope_stage ||= Array.new(count, :off)
      @operator_output ||= Array.new(count, 0.0)
      @operator_last_output ||= Array.new(count, 0.0)
    end

    def capture_render_state
      ensure_operator_state!
      {
        registers: @registers.map(&:dup),
        key_mask: @key_mask.dup,
        fnum: @fnum.dup,
        block: @block.dup,
        operator_fnum: @operator_fnum.dup,
        operator_block: @operator_block.dup,
        algorithm: @algorithm.dup,
        feedback: @feedback.dup,
        pan_l: @pan_l.dup,
        pan_r: @pan_r.dup,
        total_level: @total_level.dup,
        multiple: @multiple.dup,
        multiple_ratio: @multiple_ratio.dup,
        detune: @detune.dup,
        attack_rate: @attack_rate.dup,
        decay_rate: @decay_rate.dup,
        sustain_rate: @sustain_rate.dup,
        sustain_level: @sustain_level.dup,
        release_rate: @release_rate.dup,
        phase: @phase.dup,
        envelope: @envelope.dup,
        envelope_stage: @envelope_stage.dup,
        operator_output: @operator_output.dup,
        operator_last_output: @operator_last_output.dup,
        dac_enabled: @dac_enabled,
        dac_sample: @dac_sample,
        timer_a_counter: @timer_a_counter,
        timer_b_counter: @timer_b_counter,
        timer_control: @timer_control,
        timer_a_enabled: @timer_a_enabled,
        timer_b_enabled: @timer_b_enabled,
        status: @status,
        busy_cycles: @busy_cycles,
        last_status_read: @last_status_read
      }
    end

    def restore_render_state(state)
      @registers = state[:registers].map(&:dup)
      @key_mask = state[:key_mask].dup
      @fnum = state[:fnum].dup
      @block = state[:block].dup
      @operator_fnum = state[:operator_fnum]&.dup || Array.new(CHANNELS * OPERATORS, 0)
      @operator_block = state[:operator_block]&.dup || Array.new(CHANNELS * OPERATORS, 0)
      @algorithm = state[:algorithm].dup
      @feedback = state[:feedback].dup
      @pan_l = state[:pan_l].dup
      @pan_r = state[:pan_r].dup
      @total_level = state[:total_level].dup
      @multiple = state[:multiple].dup
      @multiple_ratio = state[:multiple_ratio]&.dup || Array.new(CHANNELS * OPERATORS) { |idx| MULTIPLE_RATIOS[@multiple[idx] || 1] }
      @detune = state[:detune]&.dup || Array.new(CHANNELS * OPERATORS, 0)
      @attack_rate = state[:attack_rate]&.dup || Array.new(CHANNELS * OPERATORS, 0)
      @decay_rate = state[:decay_rate]&.dup || Array.new(CHANNELS * OPERATORS, 0)
      @sustain_rate = state[:sustain_rate]&.dup || Array.new(CHANNELS * OPERATORS, 0)
      @sustain_level = state[:sustain_level]&.dup || Array.new(CHANNELS * OPERATORS, 15)
      @release_rate = state[:release_rate]&.dup || Array.new(CHANNELS * OPERATORS, 0)
      @phase = state[:phase].dup
      @envelope = state[:envelope].dup
      @envelope_stage = state[:envelope_stage]&.dup || Array.new(CHANNELS * OPERATORS, :off)
      @operator_output = state[:operator_output]&.dup || Array.new(CHANNELS * OPERATORS, 0.0)
      @operator_last_output = state[:operator_last_output]&.dup || Array.new(CHANNELS * OPERATORS, 0.0)
      @dac_enabled = state[:dac_enabled]
      @dac_sample = state[:dac_sample]
      @timer_a_counter = state[:timer_a_counter] || 0
      @timer_b_counter = state[:timer_b_counter] || 0
      @timer_control = state[:timer_control] || 0
      @timer_a_enabled = state.key?(:timer_a_enabled) ? state[:timer_a_enabled] : ((@timer_control & 0x01) != 0)
      @timer_b_enabled = state.key?(:timer_b_enabled) ? state[:timer_b_enabled] : ((@timer_control & 0x02) != 0)
      @status = state[:status] || @status
      @busy_cycles = state[:busy_cycles] || @busy_cycles
      @last_status_read = state[:last_status_read] || 0
    end
  end
end
