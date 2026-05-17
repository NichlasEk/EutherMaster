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
    VDP_BASE = 0x00C0_0000

    attr_accessor :psg, :ym2612, :vdp

    def initialize(size: 0x0100_0000, psg: nil, ym2612: nil, vdp: nil)
      @memory = Array.new(size, 0)
      @psg = psg
      @ym2612 = ym2612
      @vdp = vdp
      @z80_bus_requested = false
      @z80_reset_asserted = true
    end

    def load(address, bytes)
      bytes.each_with_index { |byte, index| write_byte(address + index, byte) }
    end

    def read_byte(address)
      address &= ADDRESS_MASK
      return @ym2612.read_register(address) if ym2612_address?(address)
      return z80_bus_request_status if z80_bus_request_address?(address)
      return @z80_reset_asserted ? 0 : 1 if z80_reset_address?(address)

      @memory[address] & 0xFF
    end

    def read_word(address)
      address &= ADDRESS_MASK
      return @vdp.read_data if vdp_data_address?(address)
      return @vdp.read_control if vdp_control_address?(address)

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
      elsif z80_bus_request_address?(address)
        @z80_bus_requested = (value & 0x01) != 0
      elsif z80_reset_address?(address)
        @z80_reset_asserted = (value & 0x01).zero?
      elsif psg_address?(address)
        @psg.write(value, port: address & 0x1F)
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
