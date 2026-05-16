module SmsEmulator
  class Memory
    RAM_SIZE = 0x2000  # 8KB System RAM
    ROM_SIZE = 0xC000  # 48KB ROM space

    attr_reader :ram, :rom

    def initialize
      @ram = Array.new(RAM_SIZE, 0)
      @rom = Array.new(ROM_SIZE, 0)
      @cartridge = nil
    end

    def load_rom(data)
      @cartridge = data.dup
      size = [@cartridge.length, ROM_SIZE].min
      @rom[0, size] = @cartridge[0, size]
    end

    def load_rom_file(path)
      data = File.binread(path).bytes
      load_rom(data)
    end

    # Z80 memory map (simplified):
    # $0000-$BFFF : ROM / Cartridge
    # $C000-$DFFF : System RAM (8KB, mirrored at $E000)
    # $FFFC-$FFFF : Mapper registers
    def read_byte(addr)
      addr &= 0xFFFF

      case addr
      when 0x0000..0xBFFF
        @rom[addr] || 0
      when 0xC000..0xDFFF
        @ram[addr - 0xC000] || 0
      when 0xE000..0xFFFF
        @ram[addr - 0xE000] || 0
      else
        0
      end
    end

    def read_word(addr)
      lo = read_byte(addr)
      hi = read_byte(addr + 1)
      (hi << 8) | lo
    end

    def write_byte(addr, value)
      addr &= 0xFFFF
      value &= 0xFF

      case addr
      when 0x0000..0xBFFF
        # ROM is read-only (cartridge RAM could be here in some cases)
      when 0xC000..0xDFFF
        @ram[addr - 0xC000] = value
      when 0xE000..0xFFFF
        @ram[addr - 0xE000] = value
      end
    end

    def write_word(addr, value)
      write_byte(addr, value & 0xFF)
      write_byte(addr + 1, (value >> 8) & 0xFF)
    end
  end
end
