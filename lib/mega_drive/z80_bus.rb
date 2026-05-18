module MegaDrive
  class Z80Bus
    RAM_SIZE = 0x2000
    RAM_MASK = RAM_SIZE - 1

    attr_reader :ram
    attr_accessor :frame_cycle, :m68k_bus

    def initialize(psg:, ym2612:, m68k_bus: nil)
      @ram = Array.new(RAM_SIZE, 0)
      @psg = psg
      @ym2612 = ym2612
      @m68k_bus = m68k_bus
      @bank_register = 0
      @frame_cycle = 0
    end

    def reset
      @ram.fill(0)
      @bank_register = 0
      @frame_cycle = 0
    end

    def read_byte(address)
      address &= 0xFFFF
      case address
      when 0x0000..0x3FFF
        @ram[address & RAM_MASK]
      when 0x4000..0x5FFF
        @ym2612.read_register(address)
      when 0x8000..0xFFFF
        @m68k_bus ? @m68k_bus.read_byte(banked_68k_address(address)) : 0xFF
      else
        0xFF
      end
    end

    def write_byte(address, value)
      address &= 0xFFFF
      value &= 0xFF
      case address
      when 0x0000..0x3FFF
        @ram[address & RAM_MASK] = value
      when 0x4000..0x5FFF
        @ym2612.write_port(address & 0x03, value, cycle: @frame_cycle)
      when 0x6000..0x7EFF
        @bank_register = ((@bank_register >> 1) | ((value & 1) << 8)) & 0x1FF
      when 0x7F00..0x7FFF
        @psg.write(value, port: address & 0xFF, cycle: @frame_cycle)
      when 0x8000..0xFFFF
        @m68k_bus&.write_byte(banked_68k_address(address), value)
      end
    end

    def read_io(port)
      read_byte(port & 0xFFFF)
    end

    def write_io(port, value)
      write_byte(port & 0xFFFF, value)
    end

    private

    def banked_68k_address(address)
      ((@bank_register << 15) | (address & 0x7FFF)) & 0x3F_FFFF
    end
  end
end
