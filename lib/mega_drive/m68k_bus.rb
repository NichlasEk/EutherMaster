module MegaDrive
  class M68KBus
    ADDRESS_MASK = 0x00FF_FFFF

    attr_reader :memory

    YM2612_BASE = 0x00A0_4000
    YM2612_MASK = 0x00FF_FFFC
    PSG_BASE = 0x00C0_0000
    PSG_MASK = 0x00FF_FFE0
    PSG_DATA_OFFSETS = [0x11, 0x13, 0x15, 0x17].freeze
    Z80_BUS_REQUEST = 0x00A1_1100
    Z80_RESET = 0x00A1_1200
    IO_VERSION_BASE = 0x00A1_0000
    IO_PORT_1_DATA_BASE = 0x00A1_0002
    IO_PORT_1_CONTROL_BASE = 0x00A1_0008
    VDP_BASE = 0x00C0_0000
    WORK_RAM_BASE = 0x00E0_0000
    WORK_RAM_MASK = 0x0000_FFFF

    attr_accessor :psg, :ym2612, :vdp, :controller

    def initialize(size: 0x0100_0000, psg: nil, ym2612: nil, vdp: nil, controller: nil)
      @memory = Array.new(size, 0)
      @work_ram = Array.new(WORK_RAM_MASK + 1, 0)
      @psg = psg
      @ym2612 = ym2612
      @vdp = vdp
      @controller = controller
      @vdp.bus = self if @vdp
      @rom = nil
      @z80_bus_requested = false
      @z80_reset_asserted = true
    end

    def load(address, bytes)
      bytes.each_with_index { |byte, index| write_byte(address + index, byte) }
    end

    def load_rom(bytes)
      @rom = bytes.map { |byte| byte & 0xFF }.freeze
      @rom = nil if @rom.empty?
    end

    def read_byte(address)
      address &= ADDRESS_MASK
      return @ym2612.read_register(address) if ym2612_address?(address)
      return 0xA0 if io_pair?(address, IO_VERSION_BASE)
      return @controller ? @controller.read_data : 0x7F if io_pair?(address, IO_PORT_1_DATA_BASE)
      return @controller ? @controller.read_control : 0x00 if io_pair?(address, IO_PORT_1_CONTROL_BASE)
      return z80_bus_request_status if z80_bus_request_address?(address)
      return @z80_reset_asserted ? 0 : 1 if z80_reset_address?(address)
      return @work_ram[address & WORK_RAM_MASK] if work_ram_address?(address)
      return @rom[address % @rom.length] if cartridge_rom_address?(address)

      @memory[address] & 0xFF
    end

    def read_word(address)
      address &= ADDRESS_MASK
      return @vdp.read_data if vdp_data_address?(address)
      return @vdp.read_control if vdp_control_address?(address)
      return read_byte(address) if io_address?(address)

      ((read_byte(address) << 8) | read_byte(address + 1)) & 0xFFFF
    end

    def read_long(address)
      ((read_word(address) << 16) | read_word(address + 2)) & 0xFFFF_FFFF
    end

    def write_byte(address, value)
      address &= ADDRESS_MASK
      value &= 0xFF

      if ym2612_address?(address)
        @ym2612.write_port(address & 0x03, value)
      elsif vdp_data_address?(address)
        @vdp.write_data_byte(address, value)
      elsif vdp_control_address?(address)
        @vdp.write_control_byte(address, value)
      elsif address == (IO_PORT_1_DATA_BASE | 1)
        @controller&.write_data(value)
      elsif io_pair?(address, IO_PORT_1_CONTROL_BASE)
        @controller&.write_control(value)
      elsif z80_bus_request_address?(address)
        @z80_bus_requested = (value & 0x01) != 0
      elsif z80_reset_address?(address)
        @z80_reset_asserted = (value & 0x01).zero?
      elsif psg_address?(address)
        @psg.write(value, port: address & 0x1F)
      elsif work_ram_address?(address)
        @work_ram[address & WORK_RAM_MASK] = value
      else
        @memory[address] = value
      end
    end

    def write_word(address, value)
      address &= ADDRESS_MASK
      value &= 0xFFFF
      if vdp_data_address?(address)
        @vdp.write_data(value)
        return
      elsif vdp_control_address?(address)
        @vdp.write_control(value)
        return
      end

      write_byte(address, (value >> 8) & 0xFF)
      write_byte(address + 1, value & 0xFF)
    end

    def write_long(address, value)
      write_word(address, (value >> 16) & 0xFFFF)
      write_word(address + 2, value & 0xFFFF)
    end

    def interrupt_level = @vdp&.irq_level || 0
    def acknowledge_interrupt(level)
      @vdp&.acknowledge_interrupt(level)
    end
    def reset? = false
    def halt? = false

    private

    def ym2612_address?(address)
      @ym2612 && (address & YM2612_MASK) == YM2612_BASE
    end

    def psg_address?(address)
      @psg && (address & PSG_MASK) == PSG_BASE && PSG_DATA_OFFSETS.include?(address & 0x1F)
    end

    def z80_bus_request_address?(address)
      (address & 0x00FF_FF00) == Z80_BUS_REQUEST && (address & 1).zero?
    end

    def z80_reset_address?(address)
      (address & 0x00FF_FF00) == Z80_RESET && (address & 1).zero?
    end

    def cartridge_rom_address?(address)
      @rom && address < 0x00A0_0000
    end

    def work_ram_address?(address)
      address >= WORK_RAM_BASE
    end

    def io_pair?(address, base)
      address == base || address == (base | 1)
    end

    def io_address?(address)
      io_pair?(address, IO_VERSION_BASE) ||
        io_pair?(address, IO_PORT_1_DATA_BASE) ||
        io_pair?(address, IO_PORT_1_CONTROL_BASE)
    end

    def z80_bus_request_status
      @z80_bus_requested ? 0 : 1
    end

    def vdp_data_address?(address)
      @vdp && (address & 0x00FF_FFE0) == VDP_BASE && [0x00, 0x02].include?(address & 0x1F)
    end

    def vdp_control_address?(address)
      @vdp && (address & 0x00FF_FFE0) == VDP_BASE && [0x04, 0x06].include?(address & 0x1F)
    end
  end
end
