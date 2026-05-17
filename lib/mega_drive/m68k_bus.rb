module MegaDrive
  class M68KBus
    ADDRESS_MASK = 0x00FF_FFFF

    attr_reader :memory

    YM2612_BASE = 0x00A0_4000
    YM2612_MASK = 0x00FF_FFFC
    PSG_BASE = 0x00C0_0000
    PSG_MASK = 0x00FF_FFE0
    PSG_DATA_OFFSETS = [0x11, 0x13, 0x15, 0x17].freeze

    attr_accessor :psg, :ym2612

    def initialize(size: 0x0100_0000, psg: nil, ym2612: nil)
      @memory = Array.new(size, 0)
      @psg = psg
      @ym2612 = ym2612
    end

    def load(address, bytes)
      bytes.each_with_index { |byte, index| write_byte(address + index, byte) }
    end

    def read_byte(address)
      address &= ADDRESS_MASK
      return @ym2612.read_register(address) if ym2612_address?(address)

      @memory[address] & 0xFF
    end

    def read_word(address)
      address &= ADDRESS_MASK
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
      elsif psg_address?(address)
        @psg.write(value, port: address & 0x1F)
      else
        @memory[address] = value
      end
    end

    def write_word(address, value)
      address &= ADDRESS_MASK
      write_byte(address, (value >> 8) & 0xFF)
      write_byte(address + 1, value & 0xFF)
    end

    def write_long(address, value)
      write_word(address, (value >> 16) & 0xFFFF)
      write_word(address + 2, value & 0xFFFF)
    end

    def interrupt_level = 0
    def acknowledge_interrupt(_level); end
    def reset? = false
    def halt? = false

    private

    def ym2612_address?(address)
      @ym2612 && (address & YM2612_MASK) == YM2612_BASE
    end

    def psg_address?(address)
      @psg && (address & PSG_MASK) == PSG_BASE && PSG_DATA_OFFSETS.include?(address & 0x1F)
    end
  end
end
