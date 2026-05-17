module SmsEmulator
  class Z80
    attr_accessor :a, :b, :c, :d, :e, :f, :h, :l
    attr_accessor :pc, :sp, :ix, :iy, :i, :r
    attr_accessor :halted, :iff1, :iff2, :im
    attr_reader :memory, :cycles, :total_cycles, :last_run_steps

    FLAG_C = 0x01
    FLAG_N = 0x02
    FLAG_P = 0x04
    FLAG_3 = 0x08
    FLAG_H = 0x10
    FLAG_5 = 0x20
    FLAG_Z = 0x40
    FLAG_S = 0x80
    FLAG_YX = FLAG_3 | FLAG_5

    REG8 = [:b, :c, :d, :e, :h, :l, nil, :a].freeze
    RP = [:bc, :de, :hl, :sp].freeze
    RP2 = [:bc, :de, :hl, :af].freeze
    PARITY = Array.new(256) { |value| value.to_s(2).count('1').even? ? FLAG_P : 0 }.freeze
    SZ_FLAGS = Array.new(256) { |value| (value & 0x80 != 0 ? FLAG_S : 0) | (value == 0 ? FLAG_Z : 0) }.freeze
    INC8_FLAGS = Array.new(256) do |value|
      res = (value + 1) & 0xFF
      SZ_FLAGS[res] | (res & FLAG_YX) | (value == 0x7F ? FLAG_P : 0) | ((value & 0x0F) == 0x0F ? FLAG_H : 0)
    end.freeze
    DEC8_FLAGS = Array.new(256) do |value|
      res = (value - 1) & 0xFF
      SZ_FLAGS[res] | (res & FLAG_YX) | (value == 0x80 ? FLAG_P : 0) | ((value & 0x0F) == 0 ? FLAG_H : 0) | FLAG_N
    end.freeze

    def initialize(memory)
      @memory = memory
      reset
    end

    def reset
      @a = @b = @c = @d = @e = @f = @h = @l = 0
      @a_alt = @f_alt = @b_alt = @c_alt = @d_alt = @e_alt = @h_alt = @l_alt = 0
      @pc = 0
      @sp = 0xDFF0
      @ix = @iy = 0
      @i = @r = 0
      @halted = false
      @iff1 = @iff2 = false
      @ei_pending = false
      @ei_pending_done = false
      @im = 0
      @cycles = 0
      @total_cycles = 0
      @last_run_steps = 0
    end

    def af = ((@a << 8) | @f)
    def af=(v)
      @a = (v >> 8) & 0xFF
      @f = v & 0xFF
    end

    def bc = ((@b << 8) | @c)
    def bc=(v)
      @b = (v >> 8) & 0xFF
      @c = v & 0xFF
    end

    def de = ((@d << 8) | @e)
    def de=(v)
      @d = (v >> 8) & 0xFF
      @e = v & 0xFF
    end

    def hl = ((@h << 8) | @l)
    def hl=(v)
      @h = (v >> 8) & 0xFF
      @l = v & 0xFF
    end

    def flag_z? = (@f & FLAG_Z) != 0
    def flag_c? = (@f & FLAG_C) != 0
    def flag_s? = (@f & FLAG_S) != 0
    def flag_p? = (@f & FLAG_P) != 0
    def flag_h? = (@f & FLAG_H) != 0
    def flag_n? = (@f & FLAG_N) != 0

    def step
      if @halted
        finish(4)
        return @cycles
      end

      @cycles = 0
      @opcode_counts[read_byte(@pc)] += 1 if @opcode_counts
      execute_opcode(fetch_opcode)
      @iff1 = @iff2 = true if @ei_pending_done
      @ei_pending_done = @ei_pending
      @ei_pending = false
      @total_cycles += @cycles
      @cycles
    end

    def enable_opcode_counts!
      @opcode_counts = Array.new(256, 0)
      @cb_opcode_counts = Array.new(256, 0)
      @ed_opcode_counts = Array.new(256, 0)
    end

    def opcode_counts
      @opcode_counts || Array.new(256, 0)
    end

    def cb_opcode_counts
      @cb_opcode_counts || Array.new(256, 0)
    end

    def ed_opcode_counts
      @ed_opcode_counts || Array.new(256, 0)
    end

    def run_cycles(max_cycles)
      return 0 if max_cycles <= 0

      return run_cycles_bus(max_cycles) if @memory.respond_to?(:fast_cpu_bus?)
      direct = @memory.respond_to?(:direct_cpu_memory) ? @memory.direct_cpu_memory : nil
      return run_cycles_direct(max_cycles, direct) if direct

      ran = 0
      steps = 0
      while ran < max_cycles
        ran += step
        steps += 1
      end
      @last_run_steps = steps
      ran
    end

    def run_cycles_bus(max_cycles)
      if @halted
        cycles = max_cycles
        @cycles = cycles
        @total_cycles += cycles
        @last_run_steps = (cycles + 3) / 4
        return cycles
      end

      total = 0
      steps = 0
      memory = @memory
      counts = @opcode_counts

      while total < max_cycles && !@halted
        opcode = memory.read_byte(@pc) & 0xFF
        @pc = (@pc + 1) & 0xFFFF
        @r = ((@r + 1) & 0x7F) | (@r & 0x80)
        counts[opcode] += 1 if counts

        case opcode
        when 0x00
          @cycles = 4
        when 0x04
          old = @b
          @b = (old + 1) & 0xFF
          @f = INC8_FLAGS[old] | (@f & FLAG_C)
          @cycles = 4
        when 0x05
          old = @b
          @b = (old - 1) & 0xFF
          @f = DEC8_FLAGS[old] | (@f & FLAG_C)
          @cycles = 4
        when 0x06
          @b = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @cycles = 7
        when 0x0C
          old = @c
          @c = (old + 1) & 0xFF
          @f = INC8_FLAGS[old] | (@f & FLAG_C)
          @cycles = 4
        when 0x0E
          @c = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @cycles = 7
        when 0x0F
          old = @a
          @a = ((old >> 1) | ((old & 1) << 7)) & 0xFF
          @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | (@a & FLAG_YX) | (old & FLAG_C)
          @cycles = 4
        when 0x10
          @b = (@b - 1) & 0xFF
          disp = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          if @b != 0
            @pc = (@pc + (disp >= 0x80 ? disp - 0x100 : disp)) & 0xFFFF
            @cycles = 13
          else
            @cycles = 8
          end
        when 0x11
          @e = memory.read_byte(@pc) & 0xFF
          @d = memory.read_byte((@pc + 1) & 0xFFFF) & 0xFF
          @pc = (@pc + 2) & 0xFFFF
          @cycles = 10
        when 0x13
          value = (((@d << 8) | @e) + 1) & 0xFFFF
          @d = (value >> 8) & 0xFF
          @e = value & 0xFF
          @cycles = 6
        when 0x16
          @d = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @cycles = 7
        when 0x1A
          @a = memory.read_byte((@d << 8) | @e) & 0xFF
          @cycles = 7
        when 0x1E
          @e = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @cycles = 7
        when 0x18
          disp = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @pc = (@pc + (disp >= 0x80 ? disp - 0x100 : disp)) & 0xFFFF
          @cycles = 12
        when 0x19
          left = (@h << 8) | @l
          right = (@d << 8) | @e
          res = left + right
          result = res & 0xFFFF
          @h = result >> 8
          @l = result & 0xFF
          @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | ((res >> 8) & FLAG_YX) |
            ((((left & 0x0FFF) + (right & 0x0FFF)) & 0x1000) != 0 ? FLAG_H : 0) |
            (res > 0xFFFF ? FLAG_C : 0)
          @cycles = 11
        when 0x20
          disp = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          if (@f & FLAG_Z).zero?
            @pc = (@pc + (disp >= 0x80 ? disp - 0x100 : disp)) & 0xFFFF
            @cycles = 12
          else
            @cycles = 7
          end
        when 0x21
          @l = memory.read_byte(@pc) & 0xFF
          @h = memory.read_byte((@pc + 1) & 0xFFFF) & 0xFF
          @pc = (@pc + 2) & 0xFFFF
          @cycles = 10
        when 0x23
          value = (((@h << 8) | @l) + 1) & 0xFFFF
          @h = (value >> 8) & 0xFF
          @l = value & 0xFF
          @cycles = 6
        when 0x26
          @h = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @cycles = 7
        when 0x28
          disp = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          if (@f & FLAG_Z) != 0
            @pc = (@pc + (disp >= 0x80 ? disp - 0x100 : disp)) & 0xFFFF
            @cycles = 12
          else
            @cycles = 7
          end
        when 0x29
          left = (@h << 8) | @l
          res = left + left
          result = res & 0xFFFF
          @h = result >> 8
          @l = result & 0xFF
          @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | ((res >> 8) & FLAG_YX) |
            ((((left & 0x0FFF) + (left & 0x0FFF)) & 0x1000) != 0 ? FLAG_H : 0) |
            (res > 0xFFFF ? FLAG_C : 0)
          @cycles = 11
        when 0x2D
          old = @l
          @l = (old - 1) & 0xFF
          @f = DEC8_FLAGS[old] | (@f & FLAG_C)
          @cycles = 4
        when 0x2E
          @l = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @cycles = 7
        when 0x2F
          @a ^= 0xFF
          @f = (@f & (FLAG_S | FLAG_Z | FLAG_P | FLAG_C)) | (@a & FLAG_YX) | FLAG_H | FLAG_N
          @cycles = 4
        when 0x30
          disp = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          if (@f & FLAG_C).zero?
            @pc = (@pc + (disp >= 0x80 ? disp - 0x100 : disp)) & 0xFFFF
            @cycles = 12
          else
            @cycles = 7
          end
        when 0x38
          disp = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          if (@f & FLAG_C) != 0
            @pc = (@pc + (disp >= 0x80 ? disp - 0x100 : disp)) & 0xFFFF
            @cycles = 12
          else
            @cycles = 7
          end
        when 0x3A
          addr = (memory.read_byte(@pc) & 0xFF) | ((memory.read_byte((@pc + 1) & 0xFFFF) & 0xFF) << 8)
          @pc = (@pc + 2) & 0xFFFF
          @a = memory.read_byte(addr) & 0xFF
          @cycles = 13
        when 0x32
          addr = (memory.read_byte(@pc) & 0xFF) | ((memory.read_byte((@pc + 1) & 0xFFFF) & 0xFF) << 8)
          @pc = (@pc + 2) & 0xFFFF
          memory.write_byte(addr, @a)
          @cycles = 13
        when 0x3E
          @a = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @cycles = 7
        when 0x4F
          @c = @a
          @cycles = 4
        when 0x77
          memory.write_byte((@h << 8) | @l, @a)
          @cycles = 7
        when 0x78
          @a = @b
          @cycles = 4
        when 0x79
          @a = @c
          @cycles = 4
        when 0x7E
          @a = memory.read_byte((@h << 8) | @l) & 0xFF
          @cycles = 7
        when 0xA6
          @a &= memory.read_byte((@h << 8) | @l) & 0xFF
          @f = szp(@a) | (@a & FLAG_YX) | FLAG_H
          @cycles = 7
        when 0xAF
          @a = 0
          @f = FLAG_Z | FLAG_P
          @cycles = 4
        when 0xB0
          @a |= @b
          @f = szp(@a) | (@a & FLAG_YX)
          @cycles = 4
        when 0xB7
          @f = szp(@a) | (@a & FLAG_YX)
          @cycles = 4
        when 0xC3
          @pc = (memory.read_byte(@pc) & 0xFF) | ((memory.read_byte((@pc + 1) & 0xFFFF) & 0xFF) << 8)
          @cycles = 10
        when 0xCD
          addr = (memory.read_byte(@pc) & 0xFF) | ((memory.read_byte((@pc + 1) & 0xFFFF) & 0xFF) << 8)
          @pc = (@pc + 2) & 0xFFFF
          @sp = (@sp - 1) & 0xFFFF
          memory.write_byte(@sp, @pc >> 8)
          @sp = (@sp - 1) & 0xFFFF
          memory.write_byte(@sp, @pc)
          @pc = addr
          @cycles = 17
        when 0xC2
          addr = (memory.read_byte(@pc) & 0xFF) | ((memory.read_byte((@pc + 1) & 0xFFFF) & 0xFF) << 8)
          @pc = (@pc + 2) & 0xFFFF
          @pc = addr if (@f & FLAG_Z).zero?
          @cycles = 10
        when 0xC8
          if (@f & FLAG_Z) != 0
            lo = memory.read_byte(@sp) & 0xFF
            @sp = (@sp + 1) & 0xFFFF
            hi = memory.read_byte(@sp) & 0xFF
            @sp = (@sp + 1) & 0xFFFF
            @pc = (hi << 8) | lo
            @cycles = 11
          else
            @cycles = 5
          end
        when 0xD3
          port = ((@a << 8) | (memory.read_byte(@pc) & 0xFF)) & 0xFFFF
          @pc = (@pc + 1) & 0xFFFF
          write_io(port, @a)
          @cycles = 11
        when 0xD9
          @b, @b_alt = @b_alt, @b
          @c, @c_alt = @c_alt, @c
          @d, @d_alt = @d_alt, @d
          @e, @e_alt = @e_alt, @e
          @h, @h_alt = @h_alt, @h
          @l, @l_alt = @l_alt, @l
          @cycles = 4
        when 0xE6
          @a &= memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @f = szp(@a) | (@a & FLAG_YX) | FLAG_H
          @cycles = 7
        when 0xC9
          lo = memory.read_byte(@sp) & 0xFF
          @sp = (@sp + 1) & 0xFFFF
          hi = memory.read_byte(@sp) & 0xFF
          @sp = (@sp + 1) & 0xFFFF
          @pc = (hi << 8) | lo
          @cycles = 10
        when 0xFE
          value = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          res = @a - value
          @f = flags_sub(@a, value, res, 0)
          @f = (@f & ~FLAG_YX) | (value & FLAG_YX)
          @cycles = 7
        when 0xFB
          @ei_pending = true
          @cycles = 4
        when 0xCB
          cb = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @r = ((@r + 1) & 0x7F) | (@r & 0x80)
          @cb_opcode_counts[cb] += 1 if @cb_opcode_counts
          case cb
          when 0x11 # RL C
            old = @c
            @c = ((old << 1) | ((@f & FLAG_C).zero? ? 0 : 1)) & 0xFF
            @f = szp(@c) | (@c & FLAG_YX) | (old >> 7)
            @cycles = 8
          when 0x17 # RL A
            old = @a
            @a = ((old << 1) | ((@f & FLAG_C).zero? ? 0 : 1)) & 0xFF
            @f = szp(@a) | (@a & FLAG_YX) | (old >> 7)
            @cycles = 8
          when 0x1A # RR D
            old = @d
            @d = ((old >> 1) | ((@f & FLAG_C).zero? ? 0 : 0x80)) & 0xFF
            @f = szp(@d) | (@d & FLAG_YX) | (old & FLAG_C)
            @cycles = 8
          when 0x1B # RR E
            old = @e
            @e = ((old >> 1) | ((@f & FLAG_C).zero? ? 0 : 0x80)) & 0xFF
            @f = szp(@e) | (@e & FLAG_YX) | (old & FLAG_C)
            @cycles = 8
          when 0x23 # SLA E
            old = @e
            @e = (old << 1) & 0xFF
            @f = szp(@e) | (@e & FLAG_YX) | (old >> 7)
            @cycles = 8
          when 0x3F # SRL A
            old = @a
            @a = old >> 1
            @f = szp(@a) | (@a & FLAG_YX) | (old & FLAG_C)
            @cycles = 8
          when 0x16 # RL (HL)
            address = (@h << 8) | @l
            old = memory.read_byte(address) & 0xFF
            value = ((old << 1) | ((@f & FLAG_C).zero? ? 0 : 1)) & 0xFF
            memory.write_byte(address, value)
            @f = szp(value) | (value & FLAG_YX) | (old >> 7)
            @cycles = 15
          when 0x26 # SLA (HL)
            address = (@h << 8) | @l
            old = memory.read_byte(address) & 0xFF
            value = (old << 1) & 0xFF
            memory.write_byte(address, value)
            @f = szp(value) | (value & FLAG_YX) | (old >> 7)
            @cycles = 15
          when 0x43 # BIT 0,E
            @f = (@f & FLAG_C) | FLAG_H | (@e & FLAG_YX)
            @f |= FLAG_Z | FLAG_P if (@e & 0x01) == 0
            @cycles = 8
          when 0x46 # BIT 0,(HL)
            address = (@h << 8) | @l
            value = memory.read_byte(address) & 0xFF
            @f = (@f & FLAG_C) | FLAG_H | ((address >> 8) & FLAG_YX)
            @f |= FLAG_Z | FLAG_P if (value & 0x01) == 0
            @cycles = 15
          when 0x67 # BIT 4,A
            @f = (@f & FLAG_C) | FLAG_H | (@a & FLAG_YX)
            @f |= FLAG_Z | FLAG_P if (@a & 0x10) == 0
            @cycles = 8
          when 0x6E # BIT 5,(HL)
            address = (@h << 8) | @l
            value = memory.read_byte(address) & 0xFF
            @f = (@f & FLAG_C) | FLAG_H | ((address >> 8) & FLAG_YX)
            @f |= FLAG_Z | FLAG_P if (value & 0x20) == 0
            @cycles = 15
          when 0x7A # BIT 7,D
            @f = (@f & FLAG_C) | FLAG_H | (@d & FLAG_YX)
            if (@d & 0x80) == 0
              @f |= FLAG_Z | FLAG_P
            else
              @f |= FLAG_S
            end
            @cycles = 8
          when 0x7E # BIT 7,(HL)
            address = (@h << 8) | @l
            value = memory.read_byte(address) & 0xFF
            @f = (@f & FLAG_C) | FLAG_H | ((address >> 8) & FLAG_YX)
            if (value & 0x80) == 0
              @f |= FLAG_Z | FLAG_P
            else
              @f |= FLAG_S
            end
            @cycles = 15
          when 0x7F # BIT 7,A
            @f = (@f & FLAG_C) | FLAG_H | (@a & FLAG_YX)
            if (@a & 0x80) == 0
              @f |= FLAG_Z | FLAG_P
            else
              @f |= FLAG_S
            end
            @cycles = 8
          else
            execute_cb(cb, nil, nil)
          end
        when 0xED
          ed = memory.read_byte(@pc) & 0xFF
          @pc = (@pc + 1) & 0xFFFF
          @r = ((@r + 1) & 0x7F) | (@r & 0x80)
          @ed_opcode_counts[ed] += 1 if @ed_opcode_counts
          case ed
          when 0xA0
            hl_value = (@h << 8) | @l
            de_value = (@d << 8) | @e
            bc_value = (@b << 8) | @c
            value = memory.read_byte(hl_value) & 0xFF
            memory.write_byte(de_value, value)
            hl_value = (hl_value + 1) & 0xFFFF
            de_value = (de_value + 1) & 0xFFFF
            bc_value = (bc_value - 1) & 0xFFFF
            @h = hl_value >> 8
            @l = hl_value & 0xFF
            @d = de_value >> 8
            @e = de_value & 0xFF
            @b = bc_value >> 8
            @c = bc_value & 0xFF
            n = (@a + value) & 0xFF
            @f = (@f & (FLAG_S | FLAG_Z | FLAG_C)) | (bc_value != 0 ? FLAG_P : 0) | (n & FLAG_3) | ((n << 4) & FLAG_5)
            @cycles = 16
          when 0xA3
            hl_value = (@h << 8) | @l
            value = memory.read_byte(hl_value) & 0xFF
            @b = (@b - 1) & 0xFF
            memory.write_io((@b << 8) | @c, value)
            hl_value = (hl_value + 1) & 0xFFFF
            @h = hl_value >> 8
            @l = hl_value & 0xFF
            @f = (@b == 0 ? FLAG_Z : 0) | (@b & FLAG_S) | FLAG_N | (@b & FLAG_YX)
            @cycles = 16
          when 0xAB
            hl_value = (@h << 8) | @l
            value = memory.read_byte(hl_value) & 0xFF
            @b = (@b - 1) & 0xFF
            memory.write_io((@b << 8) | @c, value)
            hl_value = (hl_value - 1) & 0xFFFF
            @h = hl_value >> 8
            @l = hl_value & 0xFF
            @f = (@b == 0 ? FLAG_Z : 0) | (@b & FLAG_S) | FLAG_N | (@b & FLAG_YX)
            @cycles = 16
          when 0xB0
            hl_value = (@h << 8) | @l
            de_value = (@d << 8) | @e
            bc_value = (@b << 8) | @c
            value = memory.read_byte(hl_value) & 0xFF
            memory.write_byte(de_value, value)
            hl_value = (hl_value + 1) & 0xFFFF
            de_value = (de_value + 1) & 0xFFFF
            bc_value = (bc_value - 1) & 0xFFFF
            @h = (hl_value >> 8) & 0xFF
            @l = hl_value & 0xFF
            @d = (de_value >> 8) & 0xFF
            @e = de_value & 0xFF
            @b = (bc_value >> 8) & 0xFF
            @c = bc_value & 0xFF
            n = (@a + value) & 0xFF
            @f = (@f & (FLAG_S | FLAG_Z | FLAG_C)) | (bc_value != 0 ? FLAG_P : 0) | (n & FLAG_3) | ((n << 4) & FLAG_5)
            @pc = (@pc - 2) & 0xFFFF if bc_value != 0
            @cycles = bc_value == 0 ? 16 : 21
          when 0xB3
            hl_value = (@h << 8) | @l
            value = memory.read_byte(hl_value) & 0xFF
            @b = (@b - 1) & 0xFF
            write_io((@b << 8) | @c, value)
            hl_value = (hl_value + 1) & 0xFFFF
            @h = (hl_value >> 8) & 0xFF
            @l = hl_value & 0xFF
            @f = (@b == 0 ? FLAG_Z : 0) | (@b & FLAG_S) | FLAG_N | (@b & FLAG_YX)
            @pc = (@pc - 2) & 0xFFFF if @b != 0
            @cycles = @b == 0 ? 16 : 21
          else
            execute_ed(ed)
          end
        else
          @cycles = 0
          execute_opcode(opcode)
        end

        @iff1 = @iff2 = true if @ei_pending_done
        @ei_pending_done = @ei_pending
        @ei_pending = false
        total += @cycles
        steps += 1
      end

      @total_cycles += total
      @last_run_steps = steps
      total
    end

    def run_cycles_direct(max_cycles, mem)
      a = @a; b = @b; c = @c; d = @d; e = @e; f = @f; h = @h; l = @l
      pc = @pc; sp = @sp; r = @r
      total = 0
      steps = 0
      counts = @opcode_counts
      sz = SZ_FLAGS
      inc_flags = INC8_FLAGS
      dec_flags = DEC8_FLAGS

      while total < max_cycles
        opcode = mem[pc] & 0xFF
        pc = (pc + 1) & 0xFFFF
        r = ((r + 1) & 0x7F) | (r & 0x80)
        counts[opcode] += 1 if counts

        case opcode
        when 0x00 # NOP
          total += 4
        when 0x3E # LD A,n
          a = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          total += 7
        when 0x06 # LD B,n
          b = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          total += 7
        when 0x0E # LD C,n
          c = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          total += 7
        when 0x16 # LD D,n
          d = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          total += 7
        when 0x1E # LD E,n
          e = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          total += 7
        when 0x26 # LD H,n
          h = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          total += 7
        when 0x2E # LD L,n
          l = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          total += 7
        when 0x7F then total += 4 # LD A,A
        when 0x78 then a = b; total += 4
        when 0x79 then a = c; total += 4
        when 0x7A then a = d; total += 4
        when 0x7B then a = e; total += 4
        when 0x7C then a = h; total += 4
        when 0x7D then a = l; total += 4
        when 0x47 then b = a; total += 4
        when 0x4F then c = a; total += 4
        when 0x57 then d = a; total += 4
        when 0x5F then e = a; total += 4
        when 0x67 then h = a; total += 4
        when 0x6F then l = a; total += 4
        when 0x04
          carry = f & FLAG_C; b = (b + 1) & 0xFF; f = inc_flags[(b - 1) & 0xFF] | carry; total += 4
        when 0x0C
          carry = f & FLAG_C; c = (c + 1) & 0xFF; f = inc_flags[(c - 1) & 0xFF] | carry; total += 4
        when 0x14
          carry = f & FLAG_C; d = (d + 1) & 0xFF; f = inc_flags[(d - 1) & 0xFF] | carry; total += 4
        when 0x1C
          carry = f & FLAG_C; e = (e + 1) & 0xFF; f = inc_flags[(e - 1) & 0xFF] | carry; total += 4
        when 0x24
          carry = f & FLAG_C; h = (h + 1) & 0xFF; f = inc_flags[(h - 1) & 0xFF] | carry; total += 4
        when 0x2C
          carry = f & FLAG_C; l = (l + 1) & 0xFF; f = inc_flags[(l - 1) & 0xFF] | carry; total += 4
        when 0x3C
          carry = f & FLAG_C; a = (a + 1) & 0xFF; f = inc_flags[(a - 1) & 0xFF] | carry; total += 4
        when 0x05
          carry = f & FLAG_C; old = b; b = (b - 1) & 0xFF; f = dec_flags[old] | carry; total += 4
        when 0x0D
          carry = f & FLAG_C; old = c; c = (c - 1) & 0xFF; f = dec_flags[old] | carry; total += 4
        when 0x15
          carry = f & FLAG_C; old = d; d = (d - 1) & 0xFF; f = dec_flags[old] | carry; total += 4
        when 0x1D
          carry = f & FLAG_C; old = e; e = (e - 1) & 0xFF; f = dec_flags[old] | carry; total += 4
        when 0x25
          carry = f & FLAG_C; old = h; h = (h - 1) & 0xFF; f = dec_flags[old] | carry; total += 4
        when 0x2D
          carry = f & FLAG_C; old = l; l = (l - 1) & 0xFF; f = dec_flags[old] | carry; total += 4
        when 0x3D
          carry = f & FLAG_C; old = a; a = (a - 1) & 0xFF; f = dec_flags[old] | carry; total += 4
        when 0xAF # XOR A
          a = 0
          f = FLAG_Z | FLAG_P
          total += 4
        when 0xA8 # XOR B
          a ^= b; f = sz[a] | PARITY[a] | (a & FLAG_YX); total += 4
        when 0xA9
          a ^= c; f = sz[a] | PARITY[a] | (a & FLAG_YX); total += 4
        when 0xAA
          a ^= d; f = sz[a] | PARITY[a] | (a & FLAG_YX); total += 4
        when 0xAB
          a ^= e; f = sz[a] | PARITY[a] | (a & FLAG_YX); total += 4
        when 0xAC
          a ^= h; f = sz[a] | PARITY[a] | (a & FLAG_YX); total += 4
        when 0xAD
          a ^= l; f = sz[a] | PARITY[a] | (a & FLAG_YX); total += 4
        when 0xB7 # OR A
          f = sz[a] | PARITY[a] | (a & FLAG_YX)
          total += 4
        when 0xFE # CP n
          value = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          res = a - value
          out = res & 0xFF
          f = sz[out] | FLAG_N | (value & FLAG_YX)
          f |= FLAG_H if ((a ^ value ^ out) & 0x10) != 0
          f |= FLAG_C if res < 0
          f |= FLAG_P if ((a ^ value) & (a ^ out) & 0x80) != 0
          total += 7
        when 0x18 # JR e
          disp = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          pc = (pc + (disp >= 0x80 ? disp - 0x100 : disp)) & 0xFFFF
          total += 12
        when 0x20 # JR NZ,e
          disp = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          if (f & FLAG_Z).zero?
            pc = (pc + (disp >= 0x80 ? disp - 0x100 : disp)) & 0xFFFF
            total += 12
          else
            total += 7
          end
        when 0x28 # JR Z,e
          disp = mem[pc] & 0xFF
          pc = (pc + 1) & 0xFFFF
          if (f & FLAG_Z) != 0
            pc = (pc + (disp >= 0x80 ? disp - 0x100 : disp)) & 0xFFFF
            total += 12
          else
            total += 7
          end
        when 0xC3 # JP nn
          pc = (mem[pc] & 0xFF) | ((mem[(pc + 1) & 0xFFFF] & 0xFF) << 8)
          total += 10
        when 0x21 # LD HL,nn
          l = mem[pc] & 0xFF
          h = mem[(pc + 1) & 0xFFFF] & 0xFF
          pc = (pc + 2) & 0xFFFF
          total += 10
        when 0x31 # LD SP,nn
          sp = (mem[pc] & 0xFF) | ((mem[(pc + 1) & 0xFFFF] & 0xFF) << 8)
          pc = (pc + 2) & 0xFFFF
          total += 10
        else
          @a = a; @b = b; @c = c; @d = d; @e = e; @f = f; @h = h; @l = l
          @pc = pc; @sp = sp; @r = r; @cycles = 0
          execute_opcode(opcode)
          total += @cycles
          a = @a; b = @b; c = @c; d = @d; e = @e; f = @f; h = @h; l = @l
          pc = @pc; sp = @sp; r = @r
        end
        steps += 1
      end

      @a = a; @b = b; @c = c; @d = d; @e = e; @f = f; @h = h; @l = l
      @pc = pc; @sp = sp; @r = r
      @cycles = total
      @total_cycles += total
      @last_run_steps = steps
      total
    end

    def fast_forward_idle_loop(max_cycles)
      return 0 if max_cycles < 29
      return 0 unless read_byte(@pc) == 0x3A && read_byte(@pc + 3) == 0xB7 &&
        read_byte(@pc + 4) == 0x20 && read_byte(@pc + 5) == 0xFA

      addr = read_byte(@pc + 1) | (read_byte(@pc + 2) << 8)
      return 0 if read_byte(addr) == 0

      iterations = max_cycles / 29
      skipped = iterations * 29
      @a = read_byte(addr)
      @f = sz_flags(@a) | (@a & FLAG_YX)
      @r = (@r + (iterations * 2)) & 0x7F
      @cycles = skipped
      @total_cycles += skipped
      skipped
    end

    def execute_opcode(opcode)
      case opcode
      when 0xCB then execute_cb(fetch_opcode, nil, nil)
      when 0xED then execute_ed(fetch_opcode)
      when 0xDD then execute_index(:ix)
      when 0xFD then execute_index(:iy)
      else execute_base(opcode, nil)
      end
    end

    def execute_index(index)
      opcode = fetch_opcode
      return execute_index(index) if opcode == 0xDD || opcode == 0xFD
      return execute_ddfd_cb(index) if opcode == 0xCB
      return execute_opcode(opcode) if opcode == 0xED

      execute_base(opcode, index)
    end

    def execute_base(opcode, index)
      if opcode >= 0x40 && opcode <= 0x7F
        return halt if opcode == 0x76
        unless index
          case opcode
          when 0x77
            @memory.write_byte((@h << 8) | @l, @a)
            return finish(7)
          when 0x7E
            @a = @memory.read_byte((@h << 8) | @l) & 0xFF
            return finish(7)
          when 0x78
            @a = @b
            return finish(4)
          when 0x79
            @a = @c
            return finish(4)
          when 0x4F
            @c = @a
            return finish(4)
          end
        end
        dst = (opcode >> 3) & 7
        src = opcode & 7
        if index && (dst == 6 || src == 6)
          execute_indexed_ld(dst, src, index)
        else
          write_reg8(dst, read_reg8(src, index), index)
        end
        return finish(ld_r_r_cycles(dst, src, index))
      end

      if opcode >= 0x80 && opcode <= 0xBF
        unless index
          case opcode
          when 0xA6
            @a &= @memory.read_byte((@h << 8) | @l) & 0xFF
            @f = szp(@a) | (@a & FLAG_YX) | FLAG_H
            return finish(7)
          when 0xB0
            @a |= @b
            @f = szp(@a) | (@a & FLAG_YX)
            return finish(4)
          when 0x91
            res = @a - @c
            @f = flags_sub(@a, @c, res, 0)
            @a = res & 0xFF
            return finish(4)
          end
        end
        op = (opcode >> 3) & 7
        src = opcode & 7
        alu(op, read_reg8(src, index))
        return finish(src == 6 ? (index ? 19 : 7) : (index && uses_index_reg?(src) ? 8 : 4))
      end

      case opcode
      when 0x00 then finish(4)
      when 0x01, 0x11, 0x21, 0x31
        set_rp((opcode >> 4) & 3, fetch_word, index)
        finish(index && opcode == 0x21 ? 14 : 10)
      when 0x02 then write_byte(bc, @a); finish(7)
      when 0x12 then write_byte(de, @a); finish(7)
      when 0x0A then @a = read_byte(bc); finish(7)
      when 0x1A then @a = read_byte(de); finish(7)
      when 0x03, 0x13, 0x23, 0x33
        rp = (opcode >> 4) & 3
        if !index && opcode == 0x13
          value = (((@d << 8) | @e) + 1) & 0xFFFF
          @d = (value >> 8) & 0xFF
          @e = value & 0xFF
        elsif !index && opcode == 0x23
          value = (((@h << 8) | @l) + 1) & 0xFFFF
          @h = (value >> 8) & 0xFF
          @l = value & 0xFF
        else
          set_rp(rp, (get_rp(rp, index) + 1) & 0xFFFF, index)
        end
        finish(index && opcode == 0x23 ? 10 : 6)
      when 0x0B, 0x1B, 0x2B, 0x3B
        rp = (opcode >> 4) & 3
        set_rp(rp, (get_rp(rp, index) - 1) & 0xFFFF, index)
        finish(index && opcode == 0x2B ? 10 : 6)
      when 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C
        r = (opcode >> 3) & 7
        if index && r == 6
          addr = indexed_addr(index)
          write_byte(addr, inc8(read_byte(addr)))
        else
          write_reg8(r, inc8(read_reg8(r, index)), index)
        end
        finish(r == 6 ? (index ? 23 : 11) : (index && uses_index_reg?(r) ? 8 : 4))
      when 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D
        r = (opcode >> 3) & 7
        if index && r == 6
          addr = indexed_addr(index)
          write_byte(addr, dec8(read_byte(addr)))
        else
          write_reg8(r, dec8(read_reg8(r, index)), index)
        end
        finish(r == 6 ? (index ? 23 : 11) : (index && uses_index_reg?(r) ? 8 : 4))
      when 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x36, 0x3E
        r = (opcode >> 3) & 7
        if index && r == 6
          addr = indexed_addr(index)
          write_byte(addr, fetch_byte)
        else
          write_reg8(r, fetch_byte, index)
        end
        finish(r == 6 ? (index ? 19 : 10) : (index && uses_index_reg?(r) ? 11 : 7))
      when 0x07 then @a = rlc_a(@a); finish(4)
      when 0x0F then @a = rrc_a(@a); finish(4)
      when 0x17 then @a = rl_a(@a); finish(4)
      when 0x1F then @a = rr_a(@a); finish(4)
      when 0x08 then ex_af; finish(4)
      when 0x09, 0x19, 0x29, 0x39
        target = index ? get_index(index) : hl
        result = add16(target, get_rp((opcode >> 4) & 3, index))
        index ? set_index(index, result) : self.hl = result
        finish(index ? 15 : 11)
      when 0x10
        @b = (@b - 1) & 0xFF
        if @b != 0
          jr(fetch_byte)
          finish(13)
        else
          fetch_byte
          finish(8)
        end
      when 0x18 then jr(fetch_byte); finish(12)
      when 0x20, 0x28, 0x30, 0x38
        cond = case opcode
               when 0x20 then (@f & FLAG_Z).zero?
               when 0x28 then (@f & FLAG_Z) != 0
               when 0x30 then (@f & FLAG_C).zero?
               else (@f & FLAG_C) != 0
               end
        disp = fetch_byte
        jr(disp) if cond
        finish(cond ? 12 : 7)
      when 0x22
        write_word(fetch_word, index ? get_index(index) : hl)
        finish(index ? 20 : 16)
      when 0x2A
        value = read_word(fetch_word)
        index ? set_index(index, value) : self.hl = value
        finish(index ? 20 : 16)
      when 0x27 then daa; finish(4)
      when 0x2F then @a ^= 0xFF; @f = (@f & (FLAG_S | FLAG_Z | FLAG_P | FLAG_C)) | (@a & FLAG_YX) | FLAG_H | FLAG_N; finish(4)
      when 0x32 then write_byte(fetch_word, @a); finish(13)
      when 0x3A then @a = read_byte(fetch_word); finish(13)
      when 0x37 then @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | (@a & FLAG_YX) | FLAG_C; finish(4)
      when 0x3F
        old_c = @f & FLAG_C
        @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | (@a & FLAG_YX) | (old_c != 0 ? FLAG_H : 0) | (old_c != 0 ? 0 : FLAG_C)
        finish(4)
      when 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8
        ret_cond(condition_met((opcode >> 3) & 7))
      when 0xC1, 0xD1, 0xE1, 0xF1
        set_rp2((opcode >> 4) & 3, pop_word, index)
        finish(index && opcode == 0xE1 ? 14 : 10)
      when 0xC2, 0xCA, 0xD2, 0xDA, 0xE2, 0xEA, 0xF2, 0xFA
        jp_cond(condition_met((opcode >> 3) & 7))
      when 0xC3 then @pc = fetch_word; finish(10)
      when 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC
        call_cond(condition_met((opcode >> 3) & 7))
      when 0xC5, 0xD5, 0xE5, 0xF5
        push_word(get_rp2((opcode >> 4) & 3, index))
        finish(index && opcode == 0xE5 ? 15 : 11)
      when 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE
        alu((opcode >> 3) & 7, fetch_byte)
        finish(7)
      when 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF
        push_word(@pc)
        @pc = opcode & 0x38
        finish(11)
      when 0xC9 then @pc = pop_word; finish(10)
      when 0xCD
        addr = fetch_word
        push_word(@pc)
        @pc = addr
        finish(17)
      when 0xD3
        port = ((@a << 8) | fetch_byte) & 0xFFFF
        write_io(port, @a)
        finish(11)
      when 0xDB
        port = ((@a << 8) | fetch_byte) & 0xFFFF
        @a = read_io(port)
        finish(11)
      when 0xD9 then exx; finish(4)
      when 0xE3
        value = pop_word
        push_word(index ? get_index(index) : hl)
        index ? set_index(index, value) : self.hl = value
        finish(index ? 23 : 19)
      when 0xE9
        @pc = index ? get_index(index) : hl
        finish(index ? 8 : 4)
      when 0xEB then old = de; self.de = hl; self.hl = old; finish(4)
      when 0xF3 then @iff1 = @iff2 = false; @ei_pending = @ei_pending_done = false; finish(4)
      when 0xF9 then @sp = index ? get_index(index) : hl; finish(index ? 10 : 6)
      when 0xFB then @ei_pending = true; finish(4)
      else
        finish(4)
      end
    end

    def execute_cb(opcode, index, addr)
      @cb_opcode_counts[opcode] += 1 if @cb_opcode_counts && !index && !addr
      unless index || addr
        case opcode
        when 0x11 # RL C
          old = @c
          @c = ((old << 1) | ((@f & FLAG_C).zero? ? 0 : 1)) & 0xFF
          @f = szp(@c) | (@c & FLAG_YX) | (old >> 7)
          return finish(8)
        when 0x17 # RL A
          old = @a
          @a = ((old << 1) | ((@f & FLAG_C).zero? ? 0 : 1)) & 0xFF
          @f = szp(@a) | (@a & FLAG_YX) | (old >> 7)
          return finish(8)
        when 0x1A # RR D
          old = @d
          @d = ((old >> 1) | ((@f & FLAG_C).zero? ? 0 : 0x80)) & 0xFF
          @f = szp(@d) | (@d & FLAG_YX) | (old & FLAG_C)
          return finish(8)
        when 0x1B # RR E
          old = @e
          @e = ((old >> 1) | ((@f & FLAG_C).zero? ? 0 : 0x80)) & 0xFF
          @f = szp(@e) | (@e & FLAG_YX) | (old & FLAG_C)
          return finish(8)
        when 0x23 # SLA E
          old = @e
          @e = (old << 1) & 0xFF
          @f = szp(@e) | (@e & FLAG_YX) | (old >> 7)
          return finish(8)
        when 0x3F # SRL A
          old = @a
          @a = old >> 1
          @f = szp(@a) | (@a & FLAG_YX) | (old & FLAG_C)
          return finish(8)
        when 0x16 # RL (HL)
          address = (@h << 8) | @l
          old = @memory.read_byte(address) & 0xFF
          value = ((old << 1) | ((@f & FLAG_C).zero? ? 0 : 1)) & 0xFF
          @memory.write_byte(address, value)
          @f = szp(value) | (value & FLAG_YX) | (old >> 7)
          return finish(15)
        when 0x26 # SLA (HL)
          address = (@h << 8) | @l
          old = @memory.read_byte(address) & 0xFF
          value = (old << 1) & 0xFF
          @memory.write_byte(address, value)
          @f = szp(value) | (value & FLAG_YX) | (old >> 7)
          return finish(15)
        end
      end
      x = opcode >> 6
      y = (opcode >> 3) & 7
      z = opcode & 7
      value = addr ? read_byte(addr) : read_reg8(z, index)

      case x
      when 0
        result = rotate_shift(y, value)
        addr ? write_byte(addr, result) : write_reg8(z, result, index)
      when 1
        bit_test(y, value, addr)
        result = value
      when 2
        result = value & ~(1 << y)
        addr ? write_byte(addr, result) : write_reg8(z, result, index)
      when 3
        result = value | (1 << y)
        addr ? write_byte(addr, result) : write_reg8(z, result, index)
      end

      write_reg8(z, result, nil) if addr && x != 1 && z != 6
      finish(addr ? 23 : (z == 6 ? 15 : 8))
    end

    def execute_ddfd_cb(index)
      disp = fetch_byte
      opcode = fetch_opcode
      addr = (get_index(index) + signed8(disp)) & 0xFFFF
      execute_cb(opcode, nil, addr)
    end

    def execute_indexed_ld(dst, src, index)
      addr = indexed_addr(index)

      if dst == 6
        write_byte(addr, read_reg8(src, nil))
      else
        write_reg8(dst, read_byte(addr), nil)
      end
    end

    def execute_ed(opcode)
      @ed_opcode_counts[opcode] += 1 if @ed_opcode_counts
      case opcode
      when 0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x78
        reg = (opcode >> 3) & 7
        value = read_io(bc)
        write_reg8(reg, value, nil)
        set_szp_flags(value, @f & FLAG_C)
        finish(12)
      when 0x70
        value = read_io(bc)
        set_szp_flags(value, @f & FLAG_C)
        finish(12)
      when 0x41, 0x49, 0x51, 0x59, 0x61, 0x69, 0x79
        write_io(bc, read_reg8((opcode >> 3) & 7, nil))
        finish(12)
      when 0x71
        write_io(bc, 0)
        finish(12)
      when 0x42, 0x52, 0x62, 0x72 then sbc_hl(get_rp((opcode >> 4) & 3, nil)); finish(15)
      when 0x4A, 0x5A, 0x6A, 0x7A then adc_hl(get_rp((opcode >> 4) & 3, nil)); finish(15)
      when 0x43, 0x53, 0x63, 0x73
        write_word(fetch_word, get_rp((opcode >> 4) & 3, nil))
        finish(20)
      when 0x4B, 0x5B, 0x6B, 0x7B
        set_rp((opcode >> 4) & 3, read_word(fetch_word), nil)
        finish(20)
      when 0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C then neg; finish(8)
      when 0x45, 0x55, 0x65, 0x75 then @pc = pop_word; @iff1 = @iff2; finish(14)
      when 0x4D, 0x5D, 0x6D, 0x7D then @pc = pop_word; @iff1 = @iff2; finish(14)
      when 0x46, 0x4E, 0x66, 0x6E then @im = 0; finish(8)
      when 0x56, 0x76 then @im = 1; finish(8)
      when 0x5E, 0x7E then @im = 2; finish(8)
      when 0x47 then @i = @a; finish(9)
      when 0x4F then @r = @a; finish(9)
      when 0x57 then @a = @i; set_ldair_flags; finish(9)
      when 0x5F then @a = @r; set_ldair_flags; finish(9)
      when 0x67 then rrd; finish(18)
      when 0x6F then rld; finish(18)
      when 0xA0 then ldi(1); finish(16)
      when 0xA8 then ldi(-1); finish(16)
      when 0xB0
        hl_value = (@h << 8) | @l
        de_value = (@d << 8) | @e
        bc_value = (@b << 8) | @c
        value = @memory.read_byte(hl_value) & 0xFF
        @memory.write_byte(de_value, value)
        hl_value = (hl_value + 1) & 0xFFFF
        de_value = (de_value + 1) & 0xFFFF
        bc_value = (bc_value - 1) & 0xFFFF
        @h = (hl_value >> 8) & 0xFF
        @l = hl_value & 0xFF
        @d = (de_value >> 8) & 0xFF
        @e = de_value & 0xFF
        @b = (bc_value >> 8) & 0xFF
        @c = bc_value & 0xFF
        n = (@a + value) & 0xFF
        @f = (@f & (FLAG_S | FLAG_Z | FLAG_C)) | (bc_value != 0 ? FLAG_P : 0) | (n & FLAG_3) | ((n << 4) & FLAG_5)
        @pc = (@pc - 2) & 0xFFFF if bc_value != 0
        finish(bc_value == 0 ? 16 : 21)
      when 0xB8 then block_ldi(-1); finish(bc == 0 ? 16 : 21)
      when 0xA1 then cpi(1); finish(16)
      when 0xA9 then cpi(-1); finish(16)
      when 0xB1 then block_cpi(1); finish((bc == 0 || flag_z?) ? 16 : 21)
      when 0xB9 then block_cpi(-1); finish((bc == 0 || flag_z?) ? 16 : 21)
      when 0xA2 then ini(1); finish(16)
      when 0xAA then ini(-1); finish(16)
      when 0xB2 then block_ini(1); finish(@b == 0 ? 16 : 21)
      when 0xBA then block_ini(-1); finish(@b == 0 ? 16 : 21)
      when 0xA3 then outi(1); finish(16)
      when 0xAB then outi(-1); finish(16)
      when 0xB3
        hl_value = (@h << 8) | @l
        value = @memory.read_byte(hl_value) & 0xFF
        @b = (@b - 1) & 0xFF
        write_io((@b << 8) | @c, value)
        hl_value = (hl_value + 1) & 0xFFFF
        @h = (hl_value >> 8) & 0xFF
        @l = hl_value & 0xFF
        @f = (@b == 0 ? FLAG_Z : 0) | (@b & FLAG_S) | FLAG_N | (@b & FLAG_YX)
        @pc = (@pc - 2) & 0xFFFF if @b != 0
        finish(@b == 0 ? 16 : 21)
      when 0xBB then block_outi(-1); finish(@b == 0 ? 16 : 21)
      else finish(8)
      end
    end

    def fetch_byte
      byte = read_byte(@pc)
      @pc = (@pc + 1) & 0xFFFF
      byte
    end

    def fetch_opcode
      byte = fetch_byte
      @r = ((@r + 1) & 0x7F) | (@r & 0x80)
      byte
    end

    def fetch_word = (fetch_byte | (fetch_byte << 8))
    def read_byte(addr) = @memory.read_byte(addr & 0xFFFF) & 0xFF
    def write_byte(addr, value) = @memory.write_byte(addr & 0xFFFF, value & 0xFF)
    def read_word(addr) = (read_byte(addr) | (read_byte(addr + 1) << 8))
    def write_word(addr, value) = (write_byte(addr, value); write_byte(addr + 1, value >> 8))

    def read_io(port)
      if @memory.respond_to?(:read_io)
        @memory.read_io(port & 0xFFFF) & 0xFF
      elsif @memory.respond_to?(:input)
        @memory.input(port & 0xFFFF) & 0xFF
      else
        0xFF
      end
    end

    def write_io(port, value)
      if @memory.respond_to?(:write_io)
        @memory.write_io(port & 0xFFFF, value & 0xFF)
      elsif @memory.respond_to?(:output)
        @memory.output(port & 0xFFFF, value & 0xFF)
      end
    end

    def push_word(value)
      @sp = (@sp - 1) & 0xFFFF
      write_byte(@sp, value >> 8)
      @sp = (@sp - 1) & 0xFFFF
      write_byte(@sp, value)
    end

    def pop_word
      lo = read_byte(@sp)
      @sp = (@sp + 1) & 0xFFFF
      hi = read_byte(@sp)
      @sp = (@sp + 1) & 0xFFFF
      (hi << 8) | lo
    end

    def read_reg8(reg, index = nil)
      case reg
      when 0 then @b
      when 1 then @c
      when 2 then @d
      when 3 then @e
      when 4 then index ? (get_index(index) >> 8) & 0xFF : @h
      when 5 then index ? get_index(index) & 0xFF : @l
      when 6 then read_byte(index ? indexed_addr(index) : hl)
      when 7 then @a
      end
    end

    def write_reg8(reg, value, index = nil)
      value &= 0xFF
      case reg
      when 0 then @b = value
      when 1 then @c = value
      when 2 then @d = value
      when 3 then @e = value
      when 4 then index ? set_index(index, (get_index(index) & 0x00FF) | (value << 8)) : @h = value
      when 5 then index ? set_index(index, (get_index(index) & 0xFF00) | value) : @l = value
      when 6 then write_byte(index ? indexed_addr(index) : hl, value)
      when 7 then @a = value
      end
    end

    def get_rp(rp, index)
      case rp
      when 0 then bc
      when 1 then de
      when 2 then index ? get_index(index) : hl
      when 3 then @sp
      end
    end

    def set_rp(rp, value, index)
      value &= 0xFFFF
      case rp
      when 0 then self.bc = value
      when 1 then self.de = value
      when 2 then index ? set_index(index, value) : self.hl = value
      when 3 then @sp = value
      end
    end

    def get_rp2(rp, index)
      case rp
      when 0 then bc
      when 1 then de
      when 2 then index ? get_index(index) : hl
      when 3 then af
      end
    end

    def set_rp2(rp, value, index)
      case rp
      when 0 then self.bc = value
      when 1 then self.de = value
      when 2 then index ? set_index(index, value) : self.hl = value
      when 3 then self.af = value
      end
    end

    def get_index(index) = (index == :ix ? @ix : @iy)
    def set_index(index, value) = (index == :ix ? @ix = value & 0xFFFF : @iy = value & 0xFFFF)
    def indexed_addr(index) = (get_index(index) + signed8(fetch_byte)) & 0xFFFF
    def uses_index_reg?(reg) = reg == 4 || reg == 5

    def alu(op, value)
      case op
      when 0 then add_a(value)
      when 1 then adc_a(value)
      when 2 then sub_a(value)
      when 3 then sbc_a(value)
      when 4 then and_a(value)
      when 5 then xor_a(value)
      when 6 then or_a(value)
      when 7 then cp_a(value)
      end
    end

    def add_a(value)
      res = @a + value
      @f = flags_add(@a, value, res, 0)
      @a = res & 0xFF
    end

    def adc_a(value)
      c = flag_c? ? 1 : 0
      res = @a + value + c
      @f = flags_add(@a, value, res, c)
      @a = res & 0xFF
    end

    def sub_a(value)
      res = @a - value
      @f = flags_sub(@a, value, res, 0)
      @a = res & 0xFF
    end

    def sbc_a(value)
      c = flag_c? ? 1 : 0
      res = @a - value - c
      @f = flags_sub(@a, value, res, c)
      @a = res & 0xFF
    end

    def and_a(value)
      @a &= value
      @f = szp(@a) | (@a & FLAG_YX) | FLAG_H
    end

    def xor_a(value)
      @a ^= value
      @f = szp(@a) | (@a & FLAG_YX)
    end

    def or_a(value)
      @a |= value
      @f = szp(@a) | (@a & FLAG_YX)
    end

    def cp_a(value)
      res = @a - value
      @f = flags_sub(@a, value, res, 0)
      @f = (@f & ~FLAG_YX) | (value & FLAG_YX)
    end

    def flags_add(left, right, res, carry)
      value = res & 0xFF
      sz = sz_flags(value) | (value & FLAG_YX)
      h = (((left & 0x0F) + (right & 0x0F) + carry) & 0x10) != 0 ? FLAG_H : 0
      c = res > 0xFF ? FLAG_C : 0
      pv = ((left ^ ~right) & (left ^ value) & 0x80) != 0 ? FLAG_P : 0
      sz | h | pv | c
    end

    def flags_sub(left, right, res, carry)
      value = res & 0xFF
      sz = sz_flags(value) | (value & FLAG_YX)
      h = ((left ^ right ^ value) & 0x10) != 0 ? FLAG_H : 0
      c = res < 0 ? FLAG_C : 0
      pv = ((left ^ right) & (left ^ value) & 0x80) != 0 ? FLAG_P : 0
      sz | h | pv | FLAG_N | c
    end

    def inc8(value)
      res = (value + 1) & 0xFF
      carry = @f & FLAG_C
      @f = INC8_FLAGS[value & 0xFF] | carry
      res
    end

    def dec8(value)
      res = (value - 1) & 0xFF
      carry = @f & FLAG_C
      @f = DEC8_FLAGS[value & 0xFF] | carry
      res
    end

    def add16(left, right)
      res = left + right
      @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | ((res >> 8) & FLAG_YX) |
           ((((left & 0x0FFF) + (right & 0x0FFF)) & 0x1000) != 0 ? FLAG_H : 0) |
           (res > 0xFFFF ? FLAG_C : 0)
      res & 0xFFFF
    end

    def adc_hl(value)
      old = hl
      c = flag_c? ? 1 : 0
      res = old + value + c
      self.hl = res
      @f = ((hl & 0x8000) != 0 ? FLAG_S : 0) | (hl == 0 ? FLAG_Z : 0) | ((hl >> 8) & FLAG_YX) |
           ((((old & 0x0FFF) + (value & 0x0FFF) + c) & 0x1000) != 0 ? FLAG_H : 0) |
           (((old ^ ~value) & (old ^ hl) & 0x8000) != 0 ? FLAG_P : 0) |
           (res > 0xFFFF ? FLAG_C : 0)
    end

    def sbc_hl(value)
      old = hl
      c = flag_c? ? 1 : 0
      res = old - value - c
      self.hl = res
      @f = ((hl & 0x8000) != 0 ? FLAG_S : 0) | (hl == 0 ? FLAG_Z : 0) | ((hl >> 8) & FLAG_YX) |
           (((old ^ value ^ hl) & 0x1000) != 0 ? FLAG_H : 0) |
           (((old ^ value) & (old ^ hl) & 0x8000) != 0 ? FLAG_P : 0) |
           FLAG_N | (res < 0 ? FLAG_C : 0)
    end

    def rotate_shift(op, value)
      case op
      when 0 then result = ((value << 1) | (value >> 7)) & 0xFF; c = value >> 7
      when 1 then result = ((value >> 1) | ((value & 1) << 7)) & 0xFF; c = value & 1
      when 2 then old_c = flag_c? ? 1 : 0; result = ((value << 1) | old_c) & 0xFF; c = value >> 7
      when 3 then old_c = flag_c? ? 0x80 : 0; result = ((value >> 1) | old_c) & 0xFF; c = value & 1
      when 4 then result = (value << 1) & 0xFF; c = value >> 7
      when 5 then result = ((value >> 1) | (value & 0x80)) & 0xFF; c = value & 1
      when 6 then result = ((value << 1) | 1) & 0xFF; c = value >> 7
      when 7 then result = (value >> 1) & 0xFF; c = value & 1
      end
      @f = szp(result) | (result & FLAG_YX) | (c != 0 ? FLAG_C : 0)
      result
    end

    def rlc_a(value)
      result = ((value << 1) | (value >> 7)) & 0xFF
      @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | (result & FLAG_YX) | (value >> 7)
      result
    end

    def rrc_a(value)
      result = ((value >> 1) | ((value & 1) << 7)) & 0xFF
      @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | (result & FLAG_YX) | (value & FLAG_C)
      result
    end

    def rl_a(value)
      result = ((value << 1) | (flag_c? ? 1 : 0)) & 0xFF
      @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | (result & FLAG_YX) | (value & 0x80 != 0 ? FLAG_C : 0)
      result
    end

    def rr_a(value)
      result = ((value >> 1) | (flag_c? ? 0x80 : 0)) & 0xFF
      @f = (@f & (FLAG_S | FLAG_Z | FLAG_P)) | (result & FLAG_YX) | (value & FLAG_C)
      result
    end

    def bit_test(bit, value, addr = nil)
      mask = 1 << bit
      yx = addr ? ((addr >> 8) & FLAG_YX) : (value & FLAG_YX)
      @f = (@f & FLAG_C) | FLAG_H | yx
      @f |= FLAG_Z | FLAG_P if (value & mask) == 0
      @f |= FLAG_S if bit == 7 && (value & mask) != 0
    end

    def daa
      old_a = @a
      adjust = 0
      adjust |= 0x06 if flag_h? || (!flag_n? && (@a & 0x0F) > 9)
      adjust |= 0x60 if flag_c? || (!flag_n? && @a > 0x99)
      carry = flag_c? || (!flag_n? && old_a > 0x99)
      @a = flag_n? ? (@a - adjust) & 0xFF : (@a + adjust) & 0xFF
      @f = (@f & FLAG_N) | szp(@a) | (@a & FLAG_YX) | (carry ? FLAG_C : 0) |
           (((old_a ^ @a) & 0x10) != 0 ? FLAG_H : 0)
    end

    def neg
      value = @a
      @a = (-@a) & 0xFF
      @f = flags_sub(0, value, -value, 0)
    end

    def rrd
      mem = read_byte(hl)
      write_byte(hl, ((@a & 0x0F) << 4) | (mem >> 4))
      @a = (@a & 0xF0) | (mem & 0x0F)
      @f = (@f & FLAG_C) | szp(@a) | (@a & FLAG_YX)
    end

    def rld
      mem = read_byte(hl)
      write_byte(hl, ((mem << 4) & 0xF0) | (@a & 0x0F))
      @a = (@a & 0xF0) | (mem >> 4)
      @f = (@f & FLAG_C) | szp(@a) | (@a & FLAG_YX)
    end

    def ldi(delta)
      value = read_byte(hl)
      write_byte(de, value)
      self.hl = (hl + delta) & 0xFFFF
      self.de = (de + delta) & 0xFFFF
      self.bc = (bc - 1) & 0xFFFF
      n = (@a + value) & 0xFF
      @f = (@f & (FLAG_S | FLAG_Z | FLAG_C)) | (bc != 0 ? FLAG_P : 0) | (n & FLAG_3) | ((n << 4) & FLAG_5)
    end

    def block_ldi(delta)
      ldi(delta)
      @pc = (@pc - 2) & 0xFFFF if bc != 0
    end

    def cpi(delta)
      value = read_byte(hl)
      res = (@a - value) & 0xFF
      self.hl = (hl + delta) & 0xFFFF
      self.bc = (bc - 1) & 0xFFFF
      @f = (@f & FLAG_C) | sz_flags(res) | FLAG_N | (((@a ^ value ^ res) & 0x10) != 0 ? FLAG_H : 0) | (bc != 0 ? FLAG_P : 0)
      n = (res - (flag_h? ? 1 : 0)) & 0xFF
      @f = (@f & ~FLAG_YX) | (n & FLAG_3) | ((n << 4) & FLAG_5)
    end

    def block_cpi(delta)
      cpi(delta)
      @pc = (@pc - 2) & 0xFFFF if bc != 0 && !flag_z?
    end

    def ini(delta)
      value = read_io(bc)
      write_byte(hl, value)
      self.hl = (hl + delta) & 0xFFFF
      @b = (@b - 1) & 0xFF
      @f = (@b == 0 ? FLAG_Z : 0) | (@b & FLAG_S) | FLAG_N | (@b & FLAG_YX)
    end

    def block_ini(delta)
      ini(delta)
      @pc = (@pc - 2) & 0xFFFF if @b != 0
    end

    def outi(delta)
      value = read_byte(hl)
      @b = (@b - 1) & 0xFF
      write_io(bc, value)
      self.hl = (hl + delta) & 0xFFFF
      @f = (@b == 0 ? FLAG_Z : 0) | (@b & FLAG_S) | FLAG_N | (@b & FLAG_YX)
    end

    def block_outi(delta)
      outi(delta)
      @pc = (@pc - 2) & 0xFFFF if @b != 0
    end

    def halt
      @halted = true
      finish(4)
    end

    def ret_cond(cond)
      if cond
        @pc = pop_word
        finish(11)
      else
        finish(5)
      end
    end

    def jp_cond(cond)
      addr = fetch_word
      @pc = addr if cond
      finish(10)
    end

    def call_cond(cond)
      addr = fetch_word
      if cond
        push_word(@pc)
        @pc = addr
        finish(17)
      else
        finish(10)
      end
    end

    def jr(disp)
      @pc = (@pc + signed8(disp)) & 0xFFFF
    end

    def interrupt(vector = 0xFF)
      return 0 unless @iff1

      @iff1 = @iff2 = false
      @halted = false
      push_word(@pc)
      @pc = case @im
            when 2 then read_word((@i << 8) | vector)
            else 0x0038
            end
      @cycles = @im == 2 ? 19 : 13
      @total_cycles += @cycles
      @cycles
    end

    def nmi
      @iff2 = @iff1
      @iff1 = false
      @halted = false
      push_word(@pc)
      @pc = 0x0066
      @cycles = 11
      @total_cycles += @cycles
      @cycles
    end

    def ex_af
      @a, @a_alt = @a_alt, @a
      @f, @f_alt = @f_alt, @f
    end

    def exx
      @b, @b_alt = @b_alt, @b
      @c, @c_alt = @c_alt, @c
      @d, @d_alt = @d_alt, @d
      @e, @e_alt = @e_alt, @e
      @h, @h_alt = @h_alt, @h
      @l, @l_alt = @l_alt, @l
    end

    def set_ldair_flags
      @f = (@f & FLAG_C) | sz_flags(@a) | (@a & FLAG_YX) | (@iff2 ? FLAG_P : 0)
    end

    def set_szp_flags(value, carry = 0)
      @f = szp(value) | (value & FLAG_YX) | carry
    end

    def sz_flags(value)
      SZ_FLAGS[value & 0xFF]
    end

    def szp(value)
      sz_flags(value) | PARITY[value & 0xFF]
    end

    def parity(value)
      (PARITY[value & 0xFF] & FLAG_P) != 0
    end

    def condition_met(condition)
      case condition
      when 0 then (@f & FLAG_Z) == 0
      when 1 then (@f & FLAG_Z) != 0
      when 2 then (@f & FLAG_C) == 0
      when 3 then (@f & FLAG_C) != 0
      when 4 then (@f & FLAG_P) == 0
      when 5 then (@f & FLAG_P) != 0
      when 6 then (@f & FLAG_S) == 0
      when 7 then (@f & FLAG_S) != 0
      end
    end

    def signed8(value)
      value >= 0x80 ? value - 0x100 : value
    end

    def finish(cycles)
      @cycles = cycles
    end

    def ld_r_r_cycles(dst, src, index)
      return 19 if index && (dst == 6 || src == 6)
      return 7 if dst == 6 || src == 6
      return 8 if index && (uses_index_reg?(dst) || uses_index_reg?(src))
      4
    end
  end
end
