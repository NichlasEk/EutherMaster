module SmsEmulator
  class Memory
    RAM_SIZE = 0x2000  # 8KB System RAM
    ROM_SIZE = 0xC000  # 48KB ROM space

    attr_reader :ram, :rom, :cartridge

    def initialize(vdp = nil, controller = nil, psg = nil)
      @ram = Array.new(RAM_SIZE, 0)
      @rom = Array.new(ROM_SIZE, 0)
      @cartridge = nil
      @vdp = vdp
      @controller = controller
      @psg = psg
      @mapper = [0, 0, 1, 2]
    end

    attr_accessor :vdp, :controller, :psg, :io_cycle

    def load_rom(data)
      @cartridge = data.dup
      @mapper = [0, 0, 1, 2]
      @ram.fill(0)
      sync_mapper_ram
      @rom.fill(0)
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
        read_rom(addr)
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
      return write_mapper(addr, value) if (0xFFFC..0xFFFF).cover?(addr)

      case addr
      when 0x0000..0xBFFF
        # ROM is read-only here.
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

    def read_io(port)
      port &= 0xFF

      case [port & 0x80 != 0, port & 0x40 != 0, port & 0x01 != 0]
      when [false, false, false], [false, false, true]
        0xFF
      when [false, true, false]
        @vdp ? @vdp.read_v_counter : 0xFF
      when [false, true, true]
        @vdp ? @vdp.read_h_counter : 0xFF
      when [true, false, false]
        @vdp ? @vdp.read_data : 0xFF
      when [true, false, true]
        @vdp ? @vdp.read_status : 0xFF
      when [true, true, false]
        @controller ? @controller.read_port_a : 0xFF
      when [true, true, true]
        @controller ? @controller.read_port_misc : 0xFF
      end
    end

    def write_io(port, value)
      port &= 0xFF
      value &= 0xFF

      case [port & 0x80 != 0, port & 0x40 != 0, port & 0x01 != 0]
      when [false, false, true]
        @controller&.write_control(value)
      when [false, true, false], [false, true, true]
        @psg&.write(value, port: port, cycle: @io_cycle)
      when [true, false, false]
        @vdp&.write_data(value)
      when [true, false, true]
        @vdp&.write_control(value)
      end
    end

    private

    def read_rom(addr)
      return @rom[addr] || 0 unless @cartridge && @cartridge.length > ROM_SIZE

      case addr
      when 0x0000..0x03FF
        @cartridge[addr] || 0
      when 0x0400..0x3FFF
        read_bank(@mapper[1], addr - 0x0000)
      when 0x4000..0x7FFF
        read_bank(@mapper[2], addr - 0x4000)
      when 0x8000..0xBFFF
        read_bank(@mapper[3], addr - 0x8000)
      end
    end

    def read_bank(bank, offset)
      return 0 unless @cartridge && !@cartridge.empty?

      bank_count = (@cartridge.length + 0x3FFF) / 0x4000
      @cartridge[((bank % bank_count) * 0x4000 + offset) % @cartridge.length] || 0
    end

    def write_mapper(addr, value)
      case addr
      when 0xFFFC then @mapper[0] = value
      when 0xFFFD then @mapper[1] = value
      when 0xFFFE then @mapper[2] = value
      when 0xFFFF then @mapper[3] = value
      end
      @ram[addr - 0xE000] = value
    end

    def sync_mapper_ram
      @mapper.each_with_index do |value, index|
        @ram[0x1FFC + index] = value
      end
    end
  end
end
