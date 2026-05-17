module SmsEmulator
  class Memory
    RAM_SIZE = 0x2000  # 8KB System RAM
    ROM_SIZE = 0xC000  # 48KB ROM space

    attr_reader :ram, :rom, :cartridge
    attr_reader :mapper_type

    def initialize(vdp = nil, controller = nil, psg = nil)
      @ram = Array.new(RAM_SIZE, 0)
      @rom = Array.new(ROM_SIZE, 0)
      @cart_ram = Array.new(0x8000, 0)
      @cartridge = nil
      @mapper_type = :sega
      @codemasters_ram_enabled = false
      @vdp = vdp
      @controller = controller
      @psg = psg
      @mapper = [0, 0, 1, 2]
      @bank_count = 1
      @bank_offsets = [0, 0, 0x4000, 0x8000]
    end

    attr_accessor :vdp, :controller, :psg, :io_cycle

    def load_rom(data)
      @cartridge = strip_copier_header(data)
      @mapper_type = forced_mapper_type || detect_mapper_type(@cartridge)
      @codemasters_ram_enabled = false
      @mapper = @mapper_type == :codemasters ? [0, 0, 1, 0] : [0, 0, 1, 2]
      @bank_count = [(@cartridge.length + 0x3FFF) / 0x4000, 1].max
      sync_bank_offsets
      @ram.fill(0)
      @cart_ram.fill(0)
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
      return write_mapper(addr, value) if @mapper_type == :sega && addr >= 0xFFFC

      if addr < 0xC000
        write_cartridge(addr, value)
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

    def strip_copier_header(data)
      bytes = data.dup
      return bytes unless bytes.length > 0x4000 && (bytes.length % 0x4000) == 512

      bytes[512..] || []
    end

    def read_rom(addr)
      return @rom[addr] || 0 unless @cartridge && @cartridge.length > ROM_SIZE

      if codemasters_family? && @codemasters_ram_enabled && addr >= 0xA000
        return @cart_ram[addr & 0x1FFF] || 0
      end

      if korean_6000_ram? && addr >= 0x6000 && addr <= 0x7FFF
        return @cart_ram[(addr - 0x6000) & 0x1FFF] || 0
      end

      if @mapper_type == :sega && addr < 0x0400
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

    def write_cartridge(addr, value)
      case @mapper_type
      when :codemasters
        write_codemasters_mapper(addr, value)
      when :korean_a000
        write_korean_a000_mapper(addr, value)
      when :korean_6000_ram
        if addr >= 0x6000 && addr <= 0x7FFF
          @cart_ram[(addr - 0x6000) & 0x1FFF] = value
        else
          write_korean_6000_ram_mapper(addr, value, wide: false)
        end
      when :korean_6000_ram_wide
        if addr >= 0x6000 && addr <= 0x7FFF
          @cart_ram[(addr - 0x6000) & 0x1FFF] = value
        else
          write_korean_6000_ram_mapper(addr, value, wide: true)
        end
      end
    end

    def write_codemasters_mapper(addr, value)
      bank = (value & 0x7F) % @bank_count

      if addr == 0x0000
        set_bank(1, bank)
      elsif addr == 0x4000
        set_bank(2, bank)
        @codemasters_ram_enabled = (value & 0x80) != 0
      elsif addr == 0x8000
        set_bank(3, bank)
      elsif @codemasters_ram_enabled && addr >= 0xA000 && addr <= 0xBFFF
        @cart_ram[addr & 0x1FFF] = value
      end
    end

    def write_korean_a000_mapper(addr, value)
      return unless addr >= 0xA000 && addr <= 0xBFFF

      set_bank(3, (value & 0x7F) % @bank_count)
    end

    def write_korean_6000_ram_mapper(addr, value, wide:)
      bank = (value & 0x7F) % @bank_count

      if wide ? addr <= 0x3FFF : addr == 0x0000
        set_bank(1, bank)
      elsif wide ? (addr <= 0x7FFF) : addr == 0x4000
        set_bank(2, bank)
      elsif addr >= 0xA000 && addr <= 0xBFFF
        if @codemasters_ram_enabled
          @cart_ram[addr & 0x1FFF] = value
        else
          set_bank(3, bank)
          @codemasters_ram_enabled = (value & 0x80) != 0
        end
      end
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

    def set_bank(index, bank)
      @mapper[index] = bank
      @bank_offsets[index] = (bank % @bank_count) * 0x4000
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

    def codemasters_family?
      [:codemasters, :korean_a000, :korean_6000_ram, :korean_6000_ram_wide].include?(@mapper_type)
    end

    def korean_6000_ram?
      @mapper_type == :korean_6000_ram || @mapper_type == :korean_6000_ram_wide
    end

    def forced_mapper_type
      raw = ENV['EUTHERDRIVE_SMS_FORCE_MAPPER']
      return nil if raw.nil? || raw.strip.empty?

      case raw.strip.downcase
      when 'sega' then :sega
      when 'codemasters' then :codemasters
      when 'koreana000', 'korean_a000' then :korean_a000
      when 'korean6000ram', 'korean_6000_ram' then :korean_6000_ram
      when 'korean6000ramwide', 'korean_6000_ram_wide' then :korean_6000_ram_wide
      end
    end

    def detect_mapper_type(bytes)
      return :sega if bytes.length < 32 * 1024
      return :sega if bytes.length <= 0x7FE7

      return :codemasters if codemasters_checksum?(bytes)
      return :korean_a000 if looks_like_korean_a000_mapper?(bytes)
      return :korean_6000_ram if looks_like_korean_6000_ram_mapper?(bytes)
      return :sega if looks_like_sega_mapper?(bytes)
      return :codemasters if !sms_header?(bytes) && looks_like_codemasters_mapper?(bytes)

      :sega
    end

    def codemasters_checksum?(bytes)
      expected = bytes[0x7FE6] | (bytes[0x7FE7] << 8)
      checksum = 0
      address = 0
      while address + 1 < bytes.length
        unless address >= 0x7FF0 && address <= 0x7FFF
          checksum = (checksum + (bytes[address] | (bytes[address + 1] << 8))) & 0xFFFF
        end
        address += 2
      end
      checksum == expected
    end

    def sms_header?(bytes)
      [0x1FF0, 0x3FF0, 0x7FF0, 0x0FF0].any? do |offset|
        offset + 8 <= bytes.length && bytes[offset, 8].pack('C*') == 'TMR SEGA'
      end
    end

    def mapper_write_counts(bytes)
      counts = Hash.new(0)
      (0...(bytes.length - 2)).each do |index|
        next unless bytes[index] == 0x32

        addr = bytes[index + 1] | (bytes[index + 2] << 8)
        counts[addr] += 1
      end
      counts
    end

    def looks_like_codemasters_mapper?(bytes)
      counts = mapper_write_counts(bytes)
      triplet = counts[0x0000] >= 2 && counts[0x4000] >= 2 && counts[0x8000] >= 2
      triplet || (counts[0xA000] >= 8 && counts[0x8000] >= 2)
    end

    def looks_like_sega_mapper?(bytes)
      counts = mapper_write_counts(bytes)
      counts.values_at(0xFFFC, 0xFFFD, 0xFFFE, 0xFFFF).compact.sum >= 2
    end

    def looks_like_korean_a000_mapper?(bytes)
      counts = mapper_write_counts(bytes)
      writes_to_a000 = counts[0xA000]
      mid_rom = bytes.length >= 256 * 1024
      big_rom = bytes.length >= 512 * 1024
      huge_rom = bytes.length >= 1024 * 1024

      return true if writes_to_a000 >= 16
      return true if writes_to_a000 >= 8 && mid_rom
      return true if writes_to_a000 >= 6 && big_rom
      return true if huge_rom && writes_to_a000 >= 2

      writes_to_a000 >= 4 && (counts[0x0000] > 0 || counts[0x4000] > 0) && big_rom
    end

    def looks_like_korean_6000_ram_mapper?(bytes)
      counts = mapper_write_counts(bytes)
      writes_to_6000 = counts.sum { |addr, count| addr >= 0x6000 && addr <= 0x7FFF ? count : 0 }

      writes_to_6000 >= 16 && counts[0xA000] > 0 && bytes.length >= 512 * 1024
    end
  end
end
