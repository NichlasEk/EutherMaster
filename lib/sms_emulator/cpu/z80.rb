module SmsEmulator
  class Z80
    # 8-bit registers: A, B, C, D, E, F, H, L
    # 16-bit registers: AF, BC, DE, HL, SP, IX, IY, PC
    attr_accessor :a, :b, :c, :d, :e, :f, :h, :l
    attr_accessor :pc, :sp, :ix, :iy, :i, :r
    attr_accessor :halted, :iff1, :iff2, :im
    attr_reader :memory, :cycles, :total_cycles

    FLAG_C  = 0x01  # Carry
    FLAG_N  = 0x02  # Add/Subtract
    FLAG_P  = 0x04  # Parity/Overflow
    FLAG_3  = 0x08  # Unused (copy of bit 3)
    FLAG_H  = 0x10  # Half Carry
    FLAG_5  = 0x20  # Unused (copy of bit 5)
    FLAG_Z  = 0x40  # Zero
    FLAG_S  = 0x80  # Sign

    def initialize(memory)
      @memory = memory
      reset
    end

    def reset
      @a = @b = @c = @d = @e = @f = @h = @l = 0
      @a_alt = @f_alt = @b_alt = @c_alt = @d_alt = @e_alt = @h_alt = @l_alt = 0
      @pc = 0
      @sp = 0xDFF0  # Stack pointer initialized near top of RAM
      @ix = @iy = 0
      @i = @r = 0
      @halted = false
      @iff1 = @iff2 = false
      @im = 0
      @cycles = 0
      @total_cycles = 0
    end

    # 16-bit register helpers
    def af; (@a << 8) | @f; end
    def af=(v); @a = (v >> 8) & 0xFF; @f = v & 0xFF; end
    def bc; (@b << 8) | @c; end
    def bc=(v); @b = (v >> 8) & 0xFF; @c = v & 0xFF; end
    def de; (@d << 8) | @e; end
    def de=(v); @d = (v >> 8) & 0xFF; @e = v & 0xFF; end
    def hl; (@h << 8) | @l; end
    def hl=(v); @h = (v >> 8) & 0xFF; @l = v & 0xFF; end

    def flag_z?; (@f & FLAG_Z) != 0; end
    def flag_c?; (@f & FLAG_C) != 0; end
    def flag_s?; (@f & FLAG_S) != 0; end
    def flag_p?; (@f & FLAG_P) != 0; end
    def flag_h?; (@f & FLAG_H) != 0; end
    def flag_n?; (@f & FLAG_N) != 0; end

    def set_flag(mask, value)
      if value
        @f |= mask
      else
        @f &= ~mask
      end
    end

    def step
      return 0 if @halted

      opcode = fetch_byte
      @cycles = 0

      case opcode
      when 0x00 # NOP
        @cycles = 4
      when 0x3E # LD A, n
        @a = fetch_byte
        @cycles = 7
      when 0x06 # LD B, n
        @b = fetch_byte
        @cycles = 7
      when 0x0E # LD C, n
        @c = fetch_byte
        @cycles = 7
      when 0x16 # LD D, n
        @d = fetch_byte
        @cycles = 7
      when 0x1E # LD E, n
        @e = fetch_byte
        @cycles = 7
      when 0x26 # LD H, n
        @h = fetch_byte
        @cycles = 7
      when 0x2E # LD L, n
        @l = fetch_byte
        @cycles = 7
      when 0x32 # LD (nn), A
        addr = fetch_word
        @memory.write_byte(addr, @a)
        @cycles = 13
      when 0x3A # LD A, (nn)
        addr = fetch_word
        @a = @memory.read_byte(addr)
        @cycles = 13
      when 0xC3 # JP nn
        @pc = fetch_word
        @cycles = 10
      when 0xCD # CALL nn
        addr = fetch_word
        push_word(@pc)
        @pc = addr
        @cycles = 17
      when 0xC9 # RET
        @pc = pop_word
        @cycles = 10
      when 0xAF # XOR A
        @a = 0
        set_flag(FLAG_Z, true)
        set_flag(FLAG_C, false)
        set_flag(FLAG_S, false)
        set_flag(FLAG_H, false)
        set_flag(FLAG_N, false)
        @cycles = 4
      when 0x76 # HALT
        @halted = true
        @cycles = 4
      else
        # Unimplemented - treat as NOP for now
        @cycles = 4
      end

      @total_cycles += @cycles
      @cycles
    end

    def fetch_byte
      byte = @memory.read_byte(@pc)
      @pc = (@pc + 1) & 0xFFFF
      byte
    end

    def fetch_word
      lo = fetch_byte
      hi = fetch_byte
      (hi << 8) | lo
    end

    def push_word(value)
      @sp = (@sp - 1) & 0xFFFF
      @memory.write_byte(@sp, (value >> 8) & 0xFF)
      @sp = (@sp - 1) & 0xFFFF
      @memory.write_byte(@sp, value & 0xFF)
    end

    def pop_word
      lo = @memory.read_byte(@sp)
      @sp = (@sp + 1) & 0xFFFF
      hi = @memory.read_byte(@sp)
      @sp = (@sp + 1) & 0xFFFF
      (hi << 8) | lo
    end

    def interrupt(mode = 0)
      return unless @iff1
      @iff1 = false
      @iff2 = false
      @halted = false
      @total_cycles += 13
    end
  end
end
