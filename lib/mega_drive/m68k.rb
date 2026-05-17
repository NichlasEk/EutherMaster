module MegaDrive
  class M68K
    ADDRESS_MASK = 0x00FF_FFFF
    RESET_CYCLES = 132

    FLAG_C = 0x01
    FLAG_V = 0x02
    FLAG_Z = 0x04
    FLAG_N = 0x08
    FLAG_X = 0x10

    SIZE_BYTE = :byte
    SIZE_WORD = :word
    SIZE_LONG = :long

    attr_reader :bus, :d, :pc, :usp, :ssp, :cycles, :total_cycles
    attr_accessor :stopped

    def initialize(bus)
      @bus = bus
      power_on
    end

    def power_on
      @d = Array.new(8, 0)
      @a = Array.new(7, 0)
      @usp = 0
      @ssp = 0
      @pc = 0
      @ccr = 0
      @interrupt_priority_mask = 7
      @supervisor = true
      @trace = false
      @stopped = false
      @cycles = 0
      @total_cycles = 0
    end

    def reset
      @supervisor = true
      @trace = false
      @interrupt_priority_mask = 7
      @stopped = false
      @ssp = read_long(0)
      @pc = read_long(4) & ADDRESS_MASK
      finish(RESET_CYCLES)
    end

    def a
      out = @a.dup
      out << sp
      out
    end

    def sr
      ((@trace ? 0x8000 : 0) |
        (@supervisor ? 0x2000 : 0) |
        ((@interrupt_priority_mask & 0x07) << 8) |
        (@ccr & 0x1F)) & 0xFFFF
    end

    def sr=(value)
      value &= 0xFFFF
      old_sp = sp
      @trace = (value & 0x8000) != 0
      new_supervisor = (value & 0x2000) != 0
      @interrupt_priority_mask = (value >> 8) & 0x07
      @ccr = value & 0x1F
      if new_supervisor != @supervisor
        @supervisor ? @ssp = old_sp : @usp = old_sp
        @supervisor = new_supervisor
        set_sp(@supervisor ? @ssp : @usp)
      end
    end

    def flag_c? = (@ccr & FLAG_C) != 0
    def flag_v? = (@ccr & FLAG_V) != 0
    def flag_z? = (@ccr & FLAG_Z) != 0
    def flag_n? = (@ccr & FLAG_N) != 0
    def flag_x? = (@ccr & FLAG_X) != 0
    def supervisor? = @supervisor

    def step
      if @bus.respond_to?(:reset?) && @bus.reset?
        return reset
      end
      return finish(1) if @bus.respond_to?(:halt?) && @bus.halt?
      return finish(4) if @stopped

      opcode = fetch_word
      execute_opcode(opcode)
    end

    private

    def execute_opcode(opcode)
      case opcode
      when 0x4E71
        finish(4)
      when 0x4E70
        finish(132)
      when 0x4E72
        self.sr = fetch_word
        @stopped = true
        finish(4)
      when 0x4E75
        @pc = pop_long & ADDRESS_MASK
        finish(16)
      else
        return moveq(opcode) if (opcode & 0xF000) == 0x7000
        return branch(opcode) if (opcode & 0xF000) == 0x6000
        return addq_subq(opcode) if (opcode & 0xF000) == 0x5000 && ((opcode >> 6) & 0x03) != 0x03
        return lea(opcode) if (opcode & 0xF1C0) == 0x41C0
        return jump_or_jsr(opcode) if (opcode & 0xFF80) == 0x4E80 || (opcode & 0xFF80) == 0x4EC0
        return move(opcode) if move_opcode?(opcode)

        raise NotImplementedError, "M68K opcode 0x#{opcode.to_s(16).upcase.rjust(4, '0')} at 0x#{((@pc - 2) & ADDRESS_MASK).to_s(16).upcase}"
      end
    end

    def move_opcode?(opcode)
      top = (opcode >> 12) & 0x0F
      top == 0x1 || top == 0x2 || top == 0x3
    end

    def move(opcode)
      size = case (opcode >> 12) & 0x0F
             when 0x1 then SIZE_BYTE
             when 0x2 then SIZE_LONG
             else SIZE_WORD
             end
      dest_reg = (opcode >> 9) & 0x07
      dest_mode = (opcode >> 6) & 0x07
      source_mode = (opcode >> 3) & 0x07
      source_reg = opcode & 0x07
      source = read_ea(source_mode, source_reg, size)
      write_ea(dest_mode, dest_reg, size, source)
      set_nz_flags(source, size, keep_x: true) unless dest_mode == 1
      finish(size == SIZE_LONG ? 8 : 4)
    end

    def moveq(opcode)
      reg = (opcode >> 9) & 0x07
      imm = sign_extend(opcode & 0xFF, 8)
      @d[reg] = imm & 0xFFFF_FFFF
      set_nz_flags(@d[reg], SIZE_LONG, keep_x: true)
      finish(4)
    end

    def addq_subq(opcode)
      value = (opcode >> 9) & 0x07
      value = 8 if value.zero?
      subtract = (opcode & 0x0100) != 0
      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][(opcode >> 6) & 0x03]
      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      old = read_ea(mode, reg, mode == 1 ? SIZE_LONG : size)
      result = subtract ? old - value : old + value
      write_ea(mode, reg, mode == 1 ? SIZE_LONG : size, result)
      set_add_sub_flags(old, value, result, size, subtract: subtract) unless mode == 1
      finish(mode == 0 || mode == 1 ? 4 : 8)
    end

    def branch(opcode)
      condition = (opcode >> 8) & 0x0F
      displacement = opcode & 0xFF
      offset = if displacement.zero?
                 sign_extend(fetch_word, 16)
               else
                 sign_extend(displacement, 8)
               end
      if condition == 1
        push_long(@pc)
        @pc = (@pc + offset) & ADDRESS_MASK
        return finish(displacement.zero? ? 18 : 18)
      end

      if condition_true?(condition)
        @pc = (@pc + offset) & ADDRESS_MASK
        finish(displacement.zero? ? 10 : 10)
      else
        finish(displacement.zero? ? 12 : 8)
      end
    end

    def lea(opcode)
      dest = (opcode >> 9) & 0x07
      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      @a[dest] = effective_address(mode, reg, SIZE_LONG) & 0xFFFF_FFFF
      finish(4)
    end

    def jump_or_jsr(opcode)
      subroutine = (opcode & 0xFFC0) == 0x4E80
      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      target = effective_address(mode, reg, SIZE_WORD)
      push_long(@pc) if subroutine
      @pc = target & ADDRESS_MASK
      finish(subroutine ? 16 : 8)
    end

    def condition_true?(condition)
      case condition
      when 0x0 then true
      when 0x1 then false
      when 0x2 then !flag_c? && !flag_z?
      when 0x3 then flag_c? || flag_z?
      when 0x4 then !flag_c?
      when 0x5 then flag_c?
      when 0x6 then !flag_z?
      when 0x7 then flag_z?
      when 0x8 then !flag_v?
      when 0x9 then flag_v?
      when 0xA then !flag_n?
      when 0xB then flag_n?
      when 0xC then flag_n? == flag_v?
      when 0xD then flag_n? != flag_v?
      when 0xE then !flag_z? && flag_n? == flag_v?
      when 0xF then flag_z? || flag_n? != flag_v?
      end
    end

    def read_ea(mode, reg, size)
      case mode
      when 0
        sized_value(@d[reg], size)
      when 1
        sized_value(read_address_register(reg), size)
      when 2
        read_sized(read_address_register(reg), size)
      when 3
        address = read_address_register(reg)
        value = read_sized(address, size)
        write_address_register(reg, address + increment_step(size, reg))
        value
      when 4
        address = read_address_register(reg) - increment_step(size, reg)
        write_address_register(reg, address)
        read_sized(address, size)
      when 5
        read_sized((read_address_register(reg) + sign_extend(fetch_word, 16)) & ADDRESS_MASK, size)
      when 7
        case reg
        when 0 then read_sized(sign_extend(fetch_word, 16) & ADDRESS_MASK, size)
        when 1 then read_sized(fetch_long, size)
        when 4 then fetch_immediate(size)
        else
          raise NotImplementedError, "M68K source EA mode 7/#{reg}"
        end
      else
        raise NotImplementedError, "M68K source EA mode #{mode}/#{reg}"
      end
    end

    def write_ea(mode, reg, size, value)
      case mode
      when 0
        write_data_register(reg, size, value)
      when 1
        write_address_register(reg, size == SIZE_WORD ? sign_extend(value, 16) : value)
      when 2
        write_sized(read_address_register(reg), size, value)
      when 3
        address = read_address_register(reg)
        write_sized(address, size, value)
        write_address_register(reg, address + increment_step(size, reg))
      when 4
        address = read_address_register(reg) - increment_step(size, reg)
        write_address_register(reg, address)
        write_sized(address, size, value)
      when 5
        write_sized((read_address_register(reg) + sign_extend(fetch_word, 16)) & ADDRESS_MASK, size, value)
      when 7
        case reg
        when 0 then write_sized(sign_extend(fetch_word, 16) & ADDRESS_MASK, size, value)
        when 1 then write_sized(fetch_long, size, value)
        else
          raise NotImplementedError, "M68K dest EA mode 7/#{reg}"
        end
      else
        raise NotImplementedError, "M68K dest EA mode #{mode}/#{reg}"
      end
    end

    def effective_address(mode, reg, size)
      case mode
      when 2
        read_address_register(reg)
      when 5
        (read_address_register(reg) + sign_extend(fetch_word, 16)) & ADDRESS_MASK
      when 7
        case reg
        when 0 then sign_extend(fetch_word, 16) & ADDRESS_MASK
        when 1 then fetch_long
        else
          raise NotImplementedError, "M68K EA mode 7/#{reg}"
        end
      else
        raise NotImplementedError, "M68K EA mode #{mode}/#{reg}"
      end
    end

    def read_address_register(reg)
      reg == 7 ? sp : @a[reg]
    end

    def write_address_register(reg, value)
      value &= 0xFFFF_FFFF
      reg == 7 ? set_sp(value) : @a[reg] = value
    end

    def sp
      @supervisor ? @ssp : @usp
    end

    def set_sp(value)
      value &= 0xFFFF_FFFF
      @supervisor ? @ssp = value : @usp = value
    end

    def push_long(value)
      set_sp(sp - 4)
      write_long(sp, value)
    end

    def pop_long
      value = read_long(sp)
      set_sp(sp + 4)
      value
    end

    def fetch_word
      value = read_word(@pc)
      @pc = (@pc + 2) & ADDRESS_MASK
      value
    end

    def fetch_long
      ((fetch_word << 16) | fetch_word) & 0xFFFF_FFFF
    end

    def fetch_immediate(size)
      case size
      when SIZE_BYTE then fetch_word & 0xFF
      when SIZE_WORD then fetch_word
      else fetch_long
      end
    end

    def read_sized(address, size)
      case size
      when SIZE_BYTE then read_byte(address)
      when SIZE_WORD then read_word(address)
      else read_long(address)
      end
    end

    def write_sized(address, size, value)
      case size
      when SIZE_BYTE then write_byte(address, value)
      when SIZE_WORD then write_word(address, value)
      else write_long(address, value)
      end
    end

    def write_data_register(reg, size, value)
      case size
      when SIZE_BYTE
        @d[reg] = (@d[reg] & 0xFFFF_FF00) | (value & 0xFF)
      when SIZE_WORD
        @d[reg] = (@d[reg] & 0xFFFF_0000) | (value & 0xFFFF)
      else
        @d[reg] = value & 0xFFFF_FFFF
      end
    end

    def sized_value(value, size)
      case size
      when SIZE_BYTE then value & 0xFF
      when SIZE_WORD then value & 0xFFFF
      else value & 0xFFFF_FFFF
      end
    end

    def increment_step(size, reg)
      return 2 if size == SIZE_BYTE && reg == 7

      case size
      when SIZE_BYTE then 1
      when SIZE_WORD then 2
      else 4
      end
    end

    def set_nz_flags(value, size, keep_x:)
      x = @ccr & FLAG_X
      value = sized_value(value, size)
      @ccr = keep_x ? x : 0
      @ccr |= FLAG_Z if value.zero?
      @ccr |= FLAG_N if negative?(value, size)
    end

    def set_add_sub_flags(left, right, result, size, subtract:)
      mask = mask_for(size)
      sign = sign_bit_for(size)
      left &= mask
      right &= mask
      result &= mask
      if subtract
        carry = right > left
        overflow = ((left ^ right) & (left ^ result) & sign) != 0
      else
        carry = left + right > mask
        overflow = (~(left ^ right) & (left ^ result) & sign) != 0
      end
      @ccr = 0
      @ccr |= FLAG_C | FLAG_X if carry
      @ccr |= FLAG_V if overflow
      @ccr |= FLAG_Z if result.zero?
      @ccr |= FLAG_N if (result & sign) != 0
    end

    def negative?(value, size)
      (value & sign_bit_for(size)) != 0
    end

    def mask_for(size)
      case size
      when SIZE_BYTE then 0xFF
      when SIZE_WORD then 0xFFFF
      else 0xFFFF_FFFF
      end
    end

    def sign_bit_for(size)
      case size
      when SIZE_BYTE then 0x80
      when SIZE_WORD then 0x8000
      else 0x8000_0000
      end
    end

    def sign_extend(value, bits)
      sign = 1 << (bits - 1)
      mask = (1 << bits) - 1
      value &= mask
      (value & sign) != 0 ? value - (1 << bits) : value
    end

    def read_byte(address)
      @bus.read_byte(address & ADDRESS_MASK) & 0xFF
    end

    def read_word(address)
      @bus.read_word(address & ADDRESS_MASK) & 0xFFFF
    end

    def read_long(address)
      @bus.respond_to?(:read_long) ? @bus.read_long(address & ADDRESS_MASK) & 0xFFFF_FFFF : ((read_word(address) << 16) | read_word(address + 2))
    end

    def write_byte(address, value)
      @bus.write_byte(address & ADDRESS_MASK, value & 0xFF)
    end

    def write_word(address, value)
      @bus.write_word(address & ADDRESS_MASK, value & 0xFFFF)
    end

    def write_long(address, value)
      if @bus.respond_to?(:write_long)
        @bus.write_long(address & ADDRESS_MASK, value & 0xFFFF_FFFF)
      else
        write_word(address, (value >> 16) & 0xFFFF)
        write_word(address + 2, value & 0xFFFF)
      end
    end

    def finish(cycles)
      @cycles = cycles
      @total_cycles += cycles
      cycles
    end
  end
end
