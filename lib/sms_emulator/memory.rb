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
      @bank_count = 1
      @bank_offsets = [0, 0, 0x4000, 0x8000]
    end

    attr_accessor :vdp, :controller, :psg, :io_cycle

    def load_rom(data)
      @cartridge = data.dup
      @mapper = [0, 0, 1, 2]
      @bank_count = [(@cartridge.length + 0x3FFF) / 0x4000, 1].max
      sync_bank_offsets
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

      if addr < 0xC000
        read_rom(addr)
      elsif addr < 0xE000
        @ram[addr - 0xC000] || 0
      else
        @ram[addr - 0xE000] || 0
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
      return write_mapper(addr, value) if addr >= 0xFFFC

      if addr < 0xC000
        # ROM is read-only here.
      elsif addr < 0xE000
        @ram[addr - 0xC000] = value
      else
        @ram[addr - 0xE000] = value
      end
    end

    def write_word(addr, value)
      write_byte(addr, value & 0xFF)
      write_byte(addr + 1, (value >> 8) & 0xFF)
    end

    def read_io(port)
      port &= 0xFF

      if (port & 0x80) == 0
        return 0xFF if (port & 0x40) == 0

        (port & 0x01).zero? ? (@vdp ? @vdp.read_v_counter : 0xFF) : (@vdp ? @vdp.read_h_counter : 0xFF)
      elsif (port & 0x40) == 0
        (port & 0x01).zero? ? (@vdp ? @vdp.read_data : 0xFF) : (@vdp ? @vdp.read_status : 0xFF)
      else
        (port & 0x01).zero? ? (@controller ? @controller.read_port_a : 0xFF) : (@controller ? @controller.read_port_misc : 0xFF)
      end
    end

    def write_io(port, value)
      port &= 0xFF
      value &= 0xFF

      if (port & 0x80) == 0
        if (port & 0x40) == 0
          @controller&.write_control(value) if (port & 0x01) != 0
        else
          @psg&.write(value, port: port, cycle: @io_cycle)
        end
      elsif (port & 0x40) == 0
        (port & 0x01).zero? ? @vdp&.write_data(value) : @vdp&.write_control(value)
      end
    end

    private

    def read_rom(addr)
      return @rom[addr] || 0 unless @cartridge && @cartridge.length > ROM_SIZE

      if addr < 0x0400
        @cartridge[addr] || 0
      elsif addr < 0x4000
        read_bank_offset(@bank_offsets[1], addr)
      elsif addr < 0x8000
        read_bank_offset(@bank_offsets[2], addr - 0x4000)
      else
        read_bank_offset(@bank_offsets[3], addr - 0x8000)
      end
    end

    def read_bank_offset(bank_offset, offset)
      return 0 unless @cartridge && !@cartridge.empty?

      @cartridge[(bank_offset + offset) % @cartridge.length] || 0
    end

    def write_mapper(addr, value)
      index = addr - 0xFFFC
      case addr
      when 0xFFFC then @mapper[0] = value
      when 0xFFFD then @mapper[1] = value
      when 0xFFFE then @mapper[2] = value
      when 0xFFFF then @mapper[3] = value
      end
      @bank_offsets[index] = (value % @bank_count) * 0x4000
      @ram[addr - 0xE000] = value
    end

    def sync_mapper_ram
      @mapper.each_with_index do |value, index|
        @ram[0x1FFC + index] = value
      end
    end

    def sync_bank_offsets
      @mapper.each_with_index do |value, index|
        @bank_offsets[index] = (value % @bank_count) * 0x4000
      end
    end
  end
end
