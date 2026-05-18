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
      level = @bus.respond_to?(:interrupt_level) ? @bus.interrupt_level.to_i : 0
      return service_interrupt(level) if level.positive? && level > @interrupt_priority_mask
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
      when 0x4E73
        self.sr = pop_word
        @pc = pop_long & ADDRESS_MASK
        finish(20)
      when 0x4E75
        @pc = pop_long & ADDRESS_MASK
        finish(16)
      else
        return bit_operation(opcode) if bit_operation?(opcode)
        return move_from_sr(opcode) if (opcode & 0xFFC0) == 0x40C0
        return clr(opcode) if (opcode & 0xFF00) == 0x4200
        return move_to_status(opcode) if (opcode & 0xFFC0) == 0x46C0 || (opcode & 0xFFC0) == 0x44C0
        return neg(opcode) if (opcode & 0xFF00) == 0x4400
        return not_op(opcode) if (opcode & 0xFF00) == 0x4600 && ((opcode >> 6) & 0x03) != 0x03
        return swap(opcode) if (opcode & 0xFFF8) == 0x4840
        return move_usp(opcode) if (opcode & 0xFFF0) == 0x4E60
        return immediate_operation(opcode) if immediate_operation?(opcode)
        return add_sub(opcode, subtract: false) if (opcode & 0xF000) == 0xD000
        return add_sub(opcode, subtract: true) if (opcode & 0xF000) == 0x9000
        return divide(opcode, signed: false) if (opcode & 0xF1C0) == 0x80C0
        return divide(opcode, signed: true) if (opcode & 0xF1C0) == 0x81C0
        return logical_operation(opcode, :or) if (opcode & 0xF000) == 0x8000
        return multiply(opcode, signed: false) if (opcode & 0xF1C0) == 0xC0C0
        return multiply(opcode, signed: true) if (opcode & 0xF1C0) == 0xC1C0
        return exg(opcode) if exg_opcode?(opcode)
        return logical_operation(opcode, :and) if (opcode & 0xF000) == 0xC000
        return cmp(opcode) if (opcode & 0xF000) == 0xB000
        return shift_register(opcode) if (opcode & 0xF000) == 0xE000 && ((opcode >> 6) & 0x03) != 0x03
        return moveq(opcode) if (opcode & 0xF000) == 0x7000
        return branch(opcode) if (opcode & 0xF000) == 0x6000
        return dbcc(opcode) if (opcode & 0xF0F8) == 0x50C8
        return addq_subq(opcode) if (opcode & 0xF000) == 0x5000 && ((opcode >> 6) & 0x03) != 0x03
        return tst(opcode) if (opcode & 0xFF00) == 0x4A00
        return ext(opcode) if (opcode & 0xFFB8) == 0x4880
        return movem(opcode) if (opcode & 0xFB80) == 0x4880 || (opcode & 0xFB80) == 0x4C80
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

    def immediate_operation?(opcode)
      return false unless (opcode & 0xF000).zero?

      [0x0000, 0x0200, 0x0400, 0x0600, 0x0A00, 0x0C00].include?(opcode & 0x0F00)
    end

    def bit_operation?(opcode)
      (opcode & 0xF100) == 0x0100 || (opcode & 0xFF00) == 0x0800
    end

    def exg_opcode?(opcode)
      (opcode & 0xF100) == 0xC100 && [0x08, 0x09, 0x11].include?((opcode >> 3) & 0x1F)
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

    def shift_register(opcode)
      count = (opcode >> 9) & 0x07
      count = @d[count] & 0x3F if (opcode & 0x0020) != 0
      count = 8 if count.zero? && (opcode & 0x0020).zero?
      left = (opcode & 0x0100) != 0
      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][(opcode >> 6) & 0x03]
      type = (opcode >> 3) & 0x03
      reg = opcode & 0x07
      value = sized_value(@d[reg], size)
      mask = mask_for(size)
      sign = sign_bit_for(size)
      result = value
      carry = false
      overflow = false

      count.times do
        case type
        when 0 # ASL/ASR
          if left
            carry = (result & sign) != 0
            shifted = (result << 1) & mask
            overflow ||= ((result ^ shifted) & sign) != 0
            result = shifted
          else
            carry = (result & 0x01) != 0
            result = ((result >> 1) | (result & sign)) & mask
          end
          @ccr = (@ccr & ~FLAG_X) | (carry ? FLAG_X : 0)
        when 1 # LSL/LSR
          if left
            carry = (result & sign) != 0
            result = (result << 1) & mask
          else
            carry = (result & 0x01) != 0
            result = (result >> 1) & mask
          end
          @ccr = (@ccr & ~FLAG_X) | (carry ? FLAG_X : 0)
        when 2 # ROXL/ROXR
          extend = (@ccr & FLAG_X) != 0
          if left
            carry = (result & sign) != 0
            result = ((result << 1) | (extend ? 1 : 0)) & mask
          else
            carry = (result & 0x01) != 0
            result = ((result >> 1) | (extend ? sign : 0)) & mask
          end
          @ccr = (@ccr & ~FLAG_X) | (carry ? FLAG_X : 0)
        when 3 # ROL/ROR
          if left
            carry = (result & sign) != 0
            result = ((result << 1) | (carry ? 1 : 0)) & mask
          else
            carry = (result & 0x01) != 0
            result = ((result >> 1) | (carry ? sign : 0)) & mask
          end
        end
      end

      write_data_register(reg, size, result)
      if count.zero?
        set_nz_flags(result, size, keep_x: true)
      else
        extend = @ccr & FLAG_X
        @ccr = extend
        @ccr |= FLAG_C if carry
        @ccr |= FLAG_V if overflow
        @ccr |= FLAG_Z if result.zero?
        @ccr |= FLAG_N if (result & sign) != 0
      end
      finish(6 + (count * 2))
    end

    def bit_operation(opcode)
      immediate = (opcode & 0xFF00) == 0x0800
      operation = (opcode >> 6) & 0x03
      bit_number = immediate ? fetch_word : @d[(opcode >> 9) & 0x07]
      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      size = mode.zero? ? SIZE_LONG : SIZE_BYTE
      bit = bit_number & (mode.zero? ? 31 : 7)
      address = nil
      old = if mode.zero? || operation.zero?
              read_ea(mode, reg, size)
            else
              address = writable_memory_ea_address(mode, reg, size)
              read_sized(address, size)
            end
      bit_set = (old & (1 << bit)) != 0
      @ccr = (@ccr & ~FLAG_Z) | (bit_set ? 0 : FLAG_Z)

      result = case operation
               when 0 then old
               when 1 then old ^ (1 << bit)
               when 2 then old & ~(1 << bit)
               else old | (1 << bit)
               end
      if operation != 0
        mode.zero? ? write_ea(mode, reg, size, result) : write_sized(address, size, result)
      end
      finish(mode.zero? ? 6 : 10)
    end

    def move_to_status(opcode)
      ccr_only = (opcode & 0x0200).zero?
      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      value = read_ea(mode, reg, SIZE_WORD)
      ccr_only ? @ccr = value & 0x1F : self.sr = value
      finish(12)
    end

    def move_from_sr(opcode)
      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      write_ea(mode, reg, SIZE_WORD, sr)
      finish(mode.zero? ? 6 : 8)
    end

    def clr(opcode)
      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][(opcode >> 6) & 0x03]
      raise NotImplementedError, "M68K invalid CLR size at 0x#{((@pc - 2) & ADDRESS_MASK).to_s(16).upcase}" unless size

      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      write_ea(mode, reg, size, 0)
      @ccr = (@ccr & FLAG_X) | FLAG_Z
      finish(mode.zero? ? (size == SIZE_LONG ? 6 : 4) : (size == SIZE_LONG ? 12 : 8))
    end

    def neg(opcode)
      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][(opcode >> 6) & 0x03]
      raise NotImplementedError, "M68K invalid NEG size at 0x#{((@pc - 2) & ADDRESS_MASK).to_s(16).upcase}" unless size

      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      old, result = mutate_ea(mode, reg, size) { |value| -value }
      set_add_sub_flags(0, old, result, size, subtract: true)
      finish(mode.zero? ? (size == SIZE_LONG ? 6 : 4) : (size == SIZE_LONG ? 12 : 8))
    end

    def not_op(opcode)
      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][(opcode >> 6) & 0x03]
      raise NotImplementedError, "M68K invalid NOT size at 0x#{((@pc - 2) & ADDRESS_MASK).to_s(16).upcase}" unless size

      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      _old, result = mutate_ea(mode, reg, size) { |value| ~value }
      set_nz_flags(result, size, keep_x: true)
      finish(mode.zero? ? (size == SIZE_LONG ? 6 : 4) : (size == SIZE_LONG ? 12 : 8))
    end

    def swap(opcode)
      reg = opcode & 0x07
      value = @d[reg]
      @d[reg] = ((value << 16) | (value >> 16)) & 0xFFFF_FFFF
      set_nz_flags(@d[reg], SIZE_LONG, keep_x: true)
      finish(4)
    end

    def move_usp(opcode)
      reg = opcode & 0x07
      if (opcode & 0x0008).zero?
        write_address_register(reg, @usp)
      else
        @usp = read_address_register(reg) & 0xFFFF_FFFF
      end
      finish(4)
    end

    def add_sub(opcode, subtract:)
      reg = (opcode >> 9) & 0x07
      opmode = (opcode >> 6) & 0x07
      mode = (opcode >> 3) & 0x07
      ea_reg = opcode & 0x07

      if opmode == 0x03 || opmode == 0x07
        size = opmode == 0x03 ? SIZE_WORD : SIZE_LONG
        source = read_ea(mode, ea_reg, size)
        source = sign_extend(source, 16) if size == SIZE_WORD
        result = subtract ? read_address_register(reg) - source : read_address_register(reg) + source
        write_address_register(reg, result)
        return finish(size == SIZE_LONG ? 8 : 8)
      end

      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][opmode & 0x03]
      raise NotImplementedError, "M68K invalid #{subtract ? 'SUB' : 'ADD'} opmode #{opmode}" unless size

      if opmode < 0x04
        left = @d[reg]
        right = read_ea(mode, ea_reg, size)
        result = subtract ? left - right : left + right
        write_data_register(reg, size, result)
      else
        right = @d[reg]
        left, result = mutate_ea(mode, ea_reg, size) { |value| subtract ? value - right : value + right }
      end
      set_add_sub_flags(left, right, result, size, subtract: subtract)
      finish(size == SIZE_LONG ? 8 : 4)
    end

    def logical_operation(opcode, operation)
      reg = (opcode >> 9) & 0x07
      opmode = (opcode >> 6) & 0x07
      mode = (opcode >> 3) & 0x07
      ea_reg = opcode & 0x07
      raise NotImplementedError, "M68K #{operation.upcase} opmode #{opmode}" unless [0, 1, 2, 4, 5, 6, 7].include?(opmode)

      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][opmode & 0x03]
      if opmode < 4
        left = @d[reg]
        right = read_ea(mode, ea_reg, size)
        result = operation == :and ? left & right : left | right
        write_data_register(reg, size, result)
      else
        right = @d[reg]
        left, result = mutate_ea(mode, ea_reg, size) { |value| operation == :and ? value & right : value | right }
      end
      set_nz_flags(result, size, keep_x: true)
      finish(size == SIZE_LONG ? 8 : 4)
    end

    def divide(opcode, signed:)
      reg = (opcode >> 9) & 0x07
      mode = (opcode >> 3) & 0x07
      ea_reg = opcode & 0x07
      divisor = read_ea(mode, ea_reg, SIZE_WORD)
      divisor = sign_extend(divisor, 16) if signed
      dividend = @d[reg] & 0xFFFF_FFFF
      dividend = sign_extend(dividend, 32) if signed

      raise NotImplementedError, 'M68K divide by zero' if divisor.zero?

      if signed
        quotient_negative = dividend.negative? ^ divisor.negative?
        quotient = dividend.abs / divisor.abs
        quotient = -quotient if quotient_negative
        remainder = dividend - quotient * divisor
        overflow = quotient < -0x8000 || quotient > 0x7FFF
      else
        quotient = dividend / divisor
        remainder = dividend % divisor
        overflow = quotient > 0xFFFF
      end

      @ccr &= FLAG_X
      if overflow
        @ccr |= FLAG_V
      else
        write_data_register(reg, SIZE_LONG, ((remainder & 0xFFFF) << 16) | (quotient & 0xFFFF))
        @ccr |= FLAG_Z if (quotient & 0xFFFF).zero?
        @ccr |= FLAG_N if signed && (quotient & 0x8000) != 0
      end
      finish(140)
    end

    def multiply(opcode, signed:)
      reg = (opcode >> 9) & 0x07
      mode = (opcode >> 3) & 0x07
      ea_reg = opcode & 0x07
      source = read_ea(mode, ea_reg, SIZE_WORD)
      left = signed ? sign_extend(@d[reg] & 0xFFFF, 16) : (@d[reg] & 0xFFFF)
      right = signed ? sign_extend(source, 16) : source
      result = (left * right) & 0xFFFF_FFFF
      write_data_register(reg, SIZE_LONG, result)
      @ccr &= FLAG_X
      @ccr |= FLAG_Z if result.zero?
      @ccr |= FLAG_N if (result & 0x8000_0000) != 0
      finish(70)
    end

    def exg(opcode)
      rx = (opcode >> 9) & 0x07
      ry = opcode & 0x07
      mode = (opcode >> 3) & 0x1F
      case mode
      when 0x08
        @d[rx], @d[ry] = @d[ry], @d[rx]
      when 0x09
        left = read_address_register(rx)
        right = read_address_register(ry)
        write_address_register(rx, right)
        write_address_register(ry, left)
      when 0x11
        left = @d[rx]
        right = read_address_register(ry)
        @d[rx] = right
        write_address_register(ry, left)
      end
      finish(6)
    end

    def cmp(opcode)
      reg = (opcode >> 9) & 0x07
      opmode = (opcode >> 6) & 0x07
      mode = (opcode >> 3) & 0x07
      ea_reg = opcode & 0x07

      if opmode == 0x03 || opmode == 0x07
        size = opmode == 0x03 ? SIZE_WORD : SIZE_LONG
        left = read_address_register(reg)
        right = read_ea(mode, ea_reg, size)
        right = sign_extend(right, 16) if size == SIZE_WORD
        set_add_sub_flags(left, right, left - right, SIZE_LONG, subtract: true, affect_x: false)
      elsif opmode < 0x03
        size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][opmode]
        left = @d[reg]
        right = read_ea(mode, ea_reg, size)
        set_add_sub_flags(left, right, left - right, size, subtract: true, affect_x: false)
      else
        size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][opmode & 0x03]
        left, result = mutate_ea(mode, ea_reg, size) { |value| value ^ @d[reg] }
        set_nz_flags(result, size, keep_x: true)
      end
      finish(4)
    end

    def immediate_operation(opcode)
      operation = opcode & 0x0F00
      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][(opcode >> 6) & 0x03]
      raise NotImplementedError, "M68K invalid immediate size at 0x#{((@pc - 2) & ADDRESS_MASK).to_s(16).upcase}" unless size

      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      immediate = fetch_immediate(size)

      if mode == 7 && reg == 4
        immediate_to_status_register(operation, size, immediate)
        return finish(20)
      end

      if operation == 0x0C00
        left = read_ea(mode, reg, size)
        result = left - immediate
        set_add_sub_flags(left, immediate, result, size, subtract: true, affect_x: false)
      else
        left, result = mutate_ea(mode, reg, size) do |value|
          case operation
          when 0x0000 then value | immediate
          when 0x0200 then value & immediate
          when 0x0400 then value - immediate
          when 0x0600 then value + immediate
          when 0x0A00 then value ^ immediate
          end
        end
        if operation == 0x0400 || operation == 0x0600
          set_add_sub_flags(left, immediate, result, size, subtract: operation == 0x0400)
        else
          set_nz_flags(result, size, keep_x: true)
        end
      end
      finish(mode == 0 ? (size == SIZE_LONG ? 16 : 8) : (size == SIZE_LONG ? 28 : 16))
    end

    def immediate_to_status_register(operation, size, immediate)
      if size == SIZE_BYTE
        case operation
        when 0x0000 then @ccr = (@ccr | immediate) & 0x1F
        when 0x0200 then @ccr &= immediate & 0x1F
        when 0x0A00 then @ccr = (@ccr ^ immediate) & 0x1F
        else
          raise NotImplementedError, "M68K immediate CCR operation 0x#{operation.to_s(16)}"
        end
      elsif size == SIZE_WORD
        case operation
        when 0x0000 then self.sr = sr | immediate
        when 0x0200 then self.sr = sr & immediate
        when 0x0A00 then self.sr = sr ^ immediate
        else
          raise NotImplementedError, "M68K immediate SR operation 0x#{operation.to_s(16)}"
        end
      else
        raise NotImplementedError, "M68K invalid immediate status register size"
      end
    end

    def addq_subq(opcode)
      value = (opcode >> 9) & 0x07
      value = 8 if value.zero?
      subtract = (opcode & 0x0100) != 0
      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][(opcode >> 6) & 0x03]
      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      ea_size = mode == 1 ? SIZE_LONG : size
      if mode == 0 || mode == 1
        old = read_ea(mode, reg, ea_size)
        address = nil
      else
        address = writable_memory_ea_address(mode, reg, ea_size)
        old = read_sized(address, ea_size)
      end
      result = subtract ? old - value : old + value
      address ? write_sized(address, ea_size, result) : write_ea(mode, reg, ea_size, result)
      set_add_sub_flags(old, value, result, size, subtract: subtract) unless mode == 1
      finish(mode == 0 || mode == 1 ? 4 : 8)
    end

    def tst(opcode)
      size = [SIZE_BYTE, SIZE_WORD, SIZE_LONG][(opcode >> 6) & 0x03]
      raise NotImplementedError, "M68K invalid TST size at 0x#{((@pc - 2) & ADDRESS_MASK).to_s(16).upcase}" unless size

      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      value = read_ea(mode, reg, size)
      set_nz_flags(value, size, keep_x: true)
      finish(mode == 0 ? 4 : 8)
    end

    def ext(opcode)
      reg = opcode & 0x07
      if (opcode & 0x0040).zero?
        @d[reg] = (@d[reg] & 0xFFFF_0000) | (sign_extend(@d[reg] & 0xFF, 8) & 0xFFFF)
        set_nz_flags(@d[reg], SIZE_WORD, keep_x: true)
      else
        @d[reg] = sign_extend(@d[reg] & 0xFFFF, 16) & 0xFFFF_FFFF
        set_nz_flags(@d[reg], SIZE_LONG, keep_x: true)
      end
      finish(4)
    end

    def movem(opcode)
      memory_to_register = (opcode & 0x0400) != 0
      size = (opcode & 0x0040) != 0 ? SIZE_LONG : SIZE_WORD
      mode = (opcode >> 3) & 0x07
      reg = opcode & 0x07
      mask = fetch_word

      if memory_to_register
        address = effective_address(mode, reg, size)
        register_order.each_with_index do |target, bit|
          next if (mask & (1 << bit)).zero?

          value = read_sized(address, size)
          write_movem_register(target, size == SIZE_WORD ? sign_extend(value, 16) : value)
          address = (address + (size == SIZE_LONG ? 4 : 2)) & ADDRESS_MASK
        end
        write_address_register(reg, address) if mode == 3
      else
        address = effective_address(mode, reg, size)
        order = mode == 4 ? register_order.reverse : register_order
        order.each_with_index do |target, index|
          bit = mode == 4 ? index : register_order.index(target)
          next if (mask & (1 << bit)).zero?

          address = (address - (size == SIZE_LONG ? 4 : 2)) & ADDRESS_MASK if mode == 4
          write_sized(address, size, read_movem_register(target))
          address = (address + (size == SIZE_LONG ? 4 : 2)) & ADDRESS_MASK unless mode == 4
        end
        write_address_register(reg, address) if mode == 4
      end

      finish(12 + mask.digits(2).count(1) * (size == SIZE_LONG ? 8 : 4))
    end

    def branch(opcode)
      condition = (opcode >> 8) & 0x0F
      displacement = opcode & 0xFF
      base = @pc
      offset = displacement.zero? ? sign_extend(fetch_word, 16) : sign_extend(displacement, 8)
      target = (base + offset) & ADDRESS_MASK
      if condition == 1
        push_long(@pc)
        @pc = target
        return finish(displacement.zero? ? 18 : 18)
      end

      if condition_true?(condition)
        @pc = target
        finish(displacement.zero? ? 10 : 10)
      else
        finish(displacement.zero? ? 12 : 8)
      end
    end

    def dbcc(opcode)
      condition = (opcode >> 8) & 0x0F
      reg = opcode & 0x07
      displacement_base = @pc
      displacement = sign_extend(fetch_word, 16)
      return finish(12) if condition_true?(condition)

      counter = ((@d[reg] & 0xFFFF) - 1) & 0xFFFF
      @d[reg] = (@d[reg] & 0xFFFF_0000) | counter
      if counter != 0xFFFF
        @pc = (displacement_base + displacement) & ADDRESS_MASK
        finish(10)
      else
        finish(14)
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
      when 6
        read_sized(address_index_address(reg), size)
      when 7
        case reg
        when 0 then read_sized(sign_extend(fetch_word, 16) & ADDRESS_MASK, size)
        when 1 then read_sized(fetch_long, size)
        when 2 then read_sized(pc_displacement_address, size)
        when 3 then read_sized(pc_index_address, size)
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
      when 6
        write_sized(address_index_address(reg), size, value)
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
      when 3
        read_address_register(reg)
      when 4
        read_address_register(reg)
      when 5
        (read_address_register(reg) + sign_extend(fetch_word, 16)) & ADDRESS_MASK
      when 6
        address_index_address(reg)
      when 7
        case reg
        when 0 then sign_extend(fetch_word, 16) & ADDRESS_MASK
        when 1 then fetch_long
        when 2 then pc_displacement_address
        when 3 then pc_index_address
        else
          raise NotImplementedError, "M68K EA mode 7/#{reg}"
        end
      else
        raise NotImplementedError, "M68K EA mode #{mode}/#{reg}"
      end
    end

    def writable_memory_ea_address(mode, reg, size)
      case mode
      when 2
        read_address_register(reg)
      when 3
        address = read_address_register(reg)
        write_address_register(reg, address + increment_step(size, reg))
        address
      when 4
        address = read_address_register(reg) - increment_step(size, reg)
        write_address_register(reg, address)
        address
      when 5
        (read_address_register(reg) + sign_extend(fetch_word, 16)) & ADDRESS_MASK
      when 6
        address_index_address(reg)
      when 7
        case reg
        when 0 then sign_extend(fetch_word, 16) & ADDRESS_MASK
        when 1 then fetch_long
        else
          raise NotImplementedError, "M68K writable EA mode 7/#{reg}"
        end
      else
        raise NotImplementedError, "M68K writable EA mode #{mode}/#{reg}"
      end
    end

    def mutate_ea(mode, reg, size)
      if mode == 0 || mode == 1
        old = read_ea(mode, reg, size)
        result = yield(old)
        write_ea(mode, reg, size, result)
      else
        address = writable_memory_ea_address(mode, reg, size)
        old = read_sized(address, size)
        result = yield(old)
        write_sized(address, size, result)
      end
      [old, result]
    end

    def read_address_register(reg)
      reg == 7 ? sp : @a[reg]
    end

    def write_address_register(reg, value)
      value &= 0xFFFF_FFFF
      reg == 7 ? set_sp(value) : @a[reg] = value
    end

    def register_order
      @register_order ||= (0..7).map { |reg| [:d, reg] } + (0..7).map { |reg| [:a, reg] }
    end

    def read_movem_register(target)
      kind, reg = target
      kind == :d ? @d[reg] : read_address_register(reg)
    end

    def write_movem_register(target, value)
      kind, reg = target
      kind == :d ? @d[reg] = value & 0xFFFF_FFFF : write_address_register(reg, value)
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

    def push_word(value)
      set_sp(sp - 2)
      write_word(sp, value)
    end

    def pop_word
      value = read_word(sp)
      set_sp(sp + 2)
      value
    end

    def pop_long
      value = read_long(sp)
      set_sp(sp + 4)
      value
    end

    def service_interrupt(level)
      old_sr = sr
      @stopped = false
      @supervisor = true
      @interrupt_priority_mask = level & 0x07
      push_long(@pc)
      push_word(old_sr)
      @bus.acknowledge_interrupt(level) if @bus.respond_to?(:acknowledge_interrupt)
      @pc = read_long((24 + level) * 4) & ADDRESS_MASK
      finish(44)
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

    def pc_displacement_address
      base = @pc
      (base + sign_extend(fetch_word, 16)) & ADDRESS_MASK
    end

    def pc_index_address
      base = @pc
      extension = fetch_word
      brief_index_address(base, extension)
    end

    def address_index_address(reg)
      base = read_address_register(reg)
      extension = fetch_word
      brief_index_address(base, extension)
    end

    def brief_index_address(base, extension)
      index_reg = (extension >> 12) & 0x07
      index = if (extension & 0x8000) != 0
                read_address_register(index_reg)
              else
                @d[index_reg]
              end
      index = sign_extend(index, 16) if (extension & 0x0800).zero?
      displacement = sign_extend(extension & 0xFF, 8)
      (base + index + displacement) & ADDRESS_MASK
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

    def set_add_sub_flags(left, right, result, size, subtract:, affect_x: true)
      x = @ccr & FLAG_X
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
      @ccr = affect_x ? 0 : x
      @ccr |= FLAG_C if carry
      @ccr |= FLAG_X if affect_x && carry
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
