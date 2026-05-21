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
    Z80_RAM_BASE = 0x00A0_0000
    Z80_RAM_END = 0x00A0_1FFF
    Z80_BANK_REGISTER_BASE = 0x00A0_6000
    IO_VERSION_BASE = 0x00A1_0000
    IO_PORT_1_DATA_BASE = 0x00A1_0002
    IO_PORT_2_DATA_BASE = 0x00A1_0004
    IO_EXPANSION_DATA_BASE = 0x00A1_0006
    IO_PORT_1_CONTROL_BASE = 0x00A1_0008
    IO_PORT_2_CONTROL_BASE = 0x00A1_000A
    IO_EXPANSION_CONTROL_BASE = 0x00A1_000C
    VDP_BASE = 0x00C0_0000
    VDP_HV_COUNTER = 0x00C0_0008
    WORK_RAM_BASE = 0x00E0_0000
    WORK_RAM_MASK = 0x0000_FFFF
    Z80_TO_M68K_CYCLE_RATIO = 7_670_454.0 / 3_579_545.0
    M68K_TO_Z80_CYCLE_RATIO = 3_579_545.0 / 7_670_454.0

    attr_accessor :psg, :ym2612, :vdp, :controller, :controller_b, :z80_bus, :z80_cpu, :frame_cycle, :ym_frame_cycle, :version_register, :trace_pc
    attr_reader :sram_path, :cartridge_override

    def initialize(size: 0x0100_0000, psg: nil, ym2612: nil, vdp: nil, controller: nil, controller_b: nil, z80_bus: nil, z80_cpu: nil)
      @memory = Array.new(size, 0)
      @work_ram = Array.new(WORK_RAM_MASK + 1, 0)
      @psg = psg
      @ym2612 = ym2612
      @vdp = vdp
      @controller = controller
      @controller_b = controller_b
      @z80_bus = z80_bus
      @z80_cpu = z80_cpu
      @vdp.bus = self if @vdp
      @rom = nil
      @cartridge_override = nil
      @z80_bus_requested = false
      @z80_reset_asserted = true
      @frame_cycle = 0
      @ym_frame_cycle = 0
      @version_register = 0xA0
      @trace_sram = ENV['ASTRAL_TRACE_SRAM'] == '1'
      @trace_md_ram = ENV['ASTRAL_TRACE_MD_RAM'] == '1'
      reset_sram
    end

    def load(address, bytes)
      bytes.each_with_index { |byte, index| write_byte(address + index, byte) }
    end

    def load_rom(bytes)
      @rom = bytes.map { |byte| byte & 0xFF }.freeze
      @rom = nil if @rom.empty?
      @cartridge_override = nil
      reset_sram
    end

    def configure_cartridge_override(rom_bytes, rom_path: nil)
      @cartridge_override = if PapriumBusOverride.paprium_rom?(rom_bytes)
                              PapriumBusOverride.new(rom_bytes, source_path: rom_path)
                            end
    end

    def reset_cartridge_override
      @cartridge_override&.reset
    end

    def configure_sram(rom_bytes, rom_path: nil)
      reset_sram
      @sram_rom_path = rom_path
      @sram_rom_limit = self.class.declared_rom_limit(rom_bytes) || @rom&.length
      info = self.class.parse_sram_header(rom_bytes)
      trace_sram("configure path=#{rom_path.inspect} header=#{info.inspect}")
      unless info
        configure_default_sram
        @sram_enabled = initial_sram_enabled?(start: @sram_start, eeprom: false)
        trace_sram("configured default start=#{hex24(@sram_start)} end=#{hex24(@sram_end)} access=#{@sram_access} enabled=#{@sram_enabled} path=#{@sram_path.inspect}")
        return
      end

      allocate_sram(info)
      @sram_enabled = initial_sram_enabled?(info)
      trace_sram("configured start=#{hex24(@sram_start)} end=#{hex24(@sram_end)} access=#{@sram_access} enabled=#{@sram_enabled} path=#{@sram_path.inspect}")
    end

    def flush_sram
      return unless @sram_dirty && @sram && @sram_path

      File.binwrite(@sram_path, @sram.pack('C*'))
      trace_sram("flush path=#{@sram_path.inspect} bytes=#{@sram.length}")
      @sram_dirty = false
    end

    def read_byte(address)
      address &= ADDRESS_MASK
      if ym2612_address?(address)
        @ym2612.sync_to_cycle(@ym_frame_cycle)
        return @ym2612.read_register(address)
      end
      return read_vdp_data_byte(address) if vdp_data_address?(address)
      return read_vdp_control_byte(address) if vdp_control_address?(address)
      return read_vdp_hv_counter_byte(address) if vdp_hv_counter_address?(address)
      return @version_register if io_pair?(address, IO_VERSION_BASE)
      return @controller ? @controller.read_data : 0x7F if io_pair?(address, IO_PORT_1_DATA_BASE)
      return @controller_b ? @controller_b.read_data : 0xFF if io_pair?(address, IO_PORT_2_DATA_BASE)
      return 0xFF if io_pair?(address, IO_EXPANSION_DATA_BASE)
      return @controller ? @controller.read_control : 0x00 if io_pair?(address, IO_PORT_1_CONTROL_BASE)
      return @controller_b ? @controller_b.read_control : 0x00 if io_pair?(address, IO_PORT_2_CONTROL_BASE)
      return 0x00 if io_pair?(address, IO_EXPANSION_CONTROL_BASE)
      return sram_lock_read_byte if sram_lock_address?(address)
      trace_sram("read8 ctrl #{hex24(address)} -> open") if sram_control_range?(address)
      return z80_bus_request_status if z80_bus_request_address?(address)
      return @z80_reset_asserted ? 0 : 1 if z80_reset_address?(address)
      return can_access_z80_bus? ? read_z80_ram(address) : 0xFF if z80_ram_mirror_address?(address)
      if @cartridge_override
        override = @cartridge_override.read_byte(address)
        return override unless override.nil?
      end
      return read_sram_byte(address) if sram_address?(address)
      trace_sram("read8 default-sram-window #{hex24(address)} mapped=#{@sram_enabled}") if default_sram_window?(address)
      if work_ram_address?(address)
        value = @work_ram[address & WORK_RAM_MASK]
        trace_sram("read8 ram #{hex24(address)} -> #{hex8(value)}") if trace_ram_address?(address)
        return value
      end
      return @rom[address % @rom.length] if cartridge_rom_address?(address)

      @memory[address] & 0xFF
    end

    def read_word(address)
      address &= ADDRESS_MASK
      return @vdp.read_data if vdp_data_address?(address)
      return @vdp.read_control if vdp_control_address?(address)
      return @vdp.read_hv_counter if vdp_hv_counter_address?(address)
      return can_access_z80_bus? ? mirrored_z80_word(address) : 0xFFFF if z80_ram_mirror_address?(address)
      if @cartridge_override
        override = @cartridge_override.read_word(address)
        return override unless override.nil?
      end
      if sram_lock_span_address?(address, 2)
        value = @sram_enabled ? 0x0101 : 0x0000
        trace_sram("read16 lock #{hex24(address)} -> #{hex16(value)}")
        return value
      end
      trace_sram("read16 ctrl #{hex24(address)} -> open") if sram_control_range?(address)
      return ((read_byte(address) << 8) | read_byte(address + 1)) & 0xFFFF if sram_address?(address)
      trace_sram("read16 default-sram-window #{hex24(address)} mapped=#{@sram_enabled}") if default_sram_window?(address)
      if work_ram_address?(address)
        value = read_work_ram_word(address)
        trace_sram("read16 ram #{hex24(address)} -> #{hex16(value)}") if trace_ram_address?(address)
        return value
      end
      return read_rom_word(address) if cartridge_rom_address?(address)
      return read_byte(address) if io_address?(address)

      ((read_byte(address) << 8) | read_byte(address + 1)) & 0xFFFF
    end

    def read_long(address)
      address &= ADDRESS_MASK
      if sram_lock_span_address?(address, 4)
        value = @sram_enabled ? 0x0101_0101 : 0x0000_0000
        trace_sram("read32 lock #{hex24(address)} -> #{hex32(value)}")
        return value
      end
      trace_sram("read32 ctrl #{hex24(address)} -> open") if sram_control_range?(address)

      ((read_word(address) << 16) | read_word(address + 2)) & 0xFFFF_FFFF
    end

    def write_byte(address, value)
      address &= ADDRESS_MASK
      value &= 0xFF

      if ym2612_address?(address)
        @ym2612.sync_to_cycle(@ym_frame_cycle)
        @ym2612.write_port(address & 0x03, value, cycle: @ym_frame_cycle)
      elsif vdp_data_address?(address)
        @vdp.write_data_byte(address, value)
      elsif vdp_control_address?(address)
        @vdp.write_control_byte(address, value)
      elsif address == (IO_PORT_1_DATA_BASE | 1)
        @controller&.write_data(value)
      elsif address == (IO_PORT_2_DATA_BASE | 1)
        @controller_b&.write_data(value)
      elsif io_pair?(address, IO_PORT_1_CONTROL_BASE)
        @controller&.write_control(value)
      elsif io_pair?(address, IO_PORT_2_CONTROL_BASE)
        @controller_b&.write_control(value)
      elsif io_pair?(address, IO_EXPANSION_DATA_BASE) || io_pair?(address, IO_EXPANSION_CONTROL_BASE)
        # No expansion device is attached. Writes are accepted but do not affect reads.
      elsif sram_lock_address?(address)
        trace_sram("write8 lock #{hex24(address)} <= #{hex8(value)}")
        set_sram_enabled((value & 0x01) != 0)
      elsif sram_control_range?(address)
        trace_sram("write8 ctrl #{hex24(address)} <= #{hex8(value)} ignored")
      elsif z80_bus_request_address?(address)
        @z80_bus_requested = (value & 0x01) != 0
      elsif z80_reset_address?(address)
        @z80_reset_asserted = (value & 0x01).zero?
        if @z80_reset_asserted
          @z80_cpu&.reset
        end
      elsif z80_ram_mirror_address?(address)
        return unless can_access_z80_bus?

        write_z80_ram(address, value)
      elsif z80_bank_register_address?(address)
        @z80_bus&.write_byte(0x6000, value)
      elsif @cartridge_override&.write_byte(address, value)
        # Handled by cartridge-specific hardware.
      elsif sram_address?(address)
        write_sram_byte(address, value)
      elsif default_sram_window?(address)
        trace_sram("write8 default-sram-window #{hex24(address)} <= #{hex8(value)} mapped=#{@sram_enabled}")
      elsif psg_address?(address)
        @psg.write(value, port: address & 0x1F, cycle: @frame_cycle)
      elsif work_ram_address?(address)
        trace_sram("write8 ram #{hex24(address)} <= #{hex8(value)}") if trace_ram_address?(address)
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
      elsif sram_lock_span_address?(address, 2)
        trace_sram("write16 lock #{hex24(address)} <= #{hex16(value)}")
        set_sram_enabled((value & 0x01) != 0)
        return
      elsif sram_control_range?(address)
        trace_sram("write16 ctrl #{hex24(address)} <= #{hex16(value)} ignored")
      elsif default_sram_window?(address)
        trace_sram("write16 default-sram-window #{hex24(address)} <= #{hex16(value)} mapped=#{@sram_enabled}")
      elsif z80_ram_mirror_address?(address)
        return unless can_access_z80_bus?

        write_z80_ram(address & ~1, (value >> 8) & 0xFF)
        return
      elsif @cartridge_override&.write_word(address, value)
        return
      elsif work_ram_address?(address)
        offset = address & WORK_RAM_MASK
        trace_sram("write16 ram #{hex24(address)} <= #{hex16(value)}") if trace_ram_address?(address)
        @work_ram[offset] = (value >> 8) & 0xFF
        @work_ram[(offset + 1) & WORK_RAM_MASK] = value & 0xFF
        return
      end

      write_byte(address, (value >> 8) & 0xFF)
      write_byte(address + 1, value & 0xFF)
    end

    def write_long(address, value)
      address &= ADDRESS_MASK
      value &= 0xFFFF_FFFF
      if z80_ram_mirror_address?(address)
        return unless can_access_z80_bus?

        aligned = address & ~1
        write_z80_ram(aligned, (value >> 24) & 0xFF)
        write_z80_ram(aligned + 2, (value >> 8) & 0xFF)
        return
      end
      if sram_lock_span_address?(address & ADDRESS_MASK, 4)
        trace_sram("write32 lock #{hex24(address)} <= #{hex32(value)}")
        set_sram_enabled((value & 0x01) != 0)
        return
      end
      trace_sram("write32 ctrl #{hex24(address)} <= #{hex32(value)} ignored") if sram_control_range?(address & ADDRESS_MASK)

      write_word(address, (value >> 16) & 0xFFFF)
      write_word(address + 2, value & 0xFFFF)
    end

    def work_ram_fast_address?(address, bytes = 1)
      address &= ADDRESS_MASK
      address >= WORK_RAM_BASE && ((address + bytes - 1) & ADDRESS_MASK) >= WORK_RAM_BASE
    end

    def read_work_ram_word_fast(address)
      offset = address & WORK_RAM_MASK
      ((@work_ram[offset] << 8) | @work_ram[(offset + 1) & WORK_RAM_MASK]) & 0xFFFF
    end

    def read_work_ram_long_fast(address)
      offset = address & WORK_RAM_MASK
      ((@work_ram[offset] << 24) |
        (@work_ram[(offset + 1) & WORK_RAM_MASK] << 16) |
        (@work_ram[(offset + 2) & WORK_RAM_MASK] << 8) |
        @work_ram[(offset + 3) & WORK_RAM_MASK]) & 0xFFFF_FFFF
    end

    def write_work_ram_word_fast(address, value)
      offset = address & WORK_RAM_MASK
      @work_ram[offset] = (value >> 8) & 0xFF
      @work_ram[(offset + 1) & WORK_RAM_MASK] = value & 0xFF
    end

    def write_work_ram_long_fast(address, value)
      offset = address & WORK_RAM_MASK
      @work_ram[offset] = (value >> 24) & 0xFF
      @work_ram[(offset + 1) & WORK_RAM_MASK] = (value >> 16) & 0xFF
      @work_ram[(offset + 2) & WORK_RAM_MASK] = (value >> 8) & 0xFF
      @work_ram[(offset + 3) & WORK_RAM_MASK] = value & 0xFF
    end

    def interrupt_level = @vdp&.irq_level || 0
    def acknowledge_interrupt(level)
      @vdp&.acknowledge_interrupt(level)
    end
    def reset? = false
    def halt? = false

    def z80_running?
      @z80_cpu && @z80_bus && !@z80_reset_asserted && !@z80_bus_requested
    end

    def run_z80_cycles(cycles)
      return 0 unless z80_running?

      budget = cycles.to_i
      ran = 0
      start_frame_cycle = @frame_cycle.to_f
      start_ym_cycle = @ym_frame_cycle.to_f
      while ran < budget
        @z80_bus.frame_cycle = start_frame_cycle + ran
        @z80_bus.ym_frame_cycle = start_ym_cycle + (ran * Z80_TO_M68K_CYCLE_RATIO)
        step_cycles = @z80_cpu.step
        break unless step_cycles.positive?

        ran += step_cycles
      end
      @z80_bus.frame_cycle = start_frame_cycle + ran
      @z80_bus.ym_frame_cycle = start_ym_cycle + (ran * Z80_TO_M68K_CYCLE_RATIO)
      ran
    rescue NotImplementedError
      0
    end

    def begin_frame
      @frame_cycle = 0
      @ym_frame_cycle = 0
      if @z80_bus
        @z80_bus.frame_cycle = 0
        @z80_bus.ym_frame_cycle = 0
      end
    end

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

    def vdp_hv_counter_address?(address)
      @vdp && (address & 0x00FF_FFFE) == VDP_HV_COUNTER
    end

    def read_vdp_hv_counter_byte(address)
      word = @vdp.read_hv_counter
      address.even? ? ((word >> 8) & 0xFF) : (word & 0xFF)
    end

    def read_vdp_data_byte(address)
      word = @vdp.read_data
      address.even? ? ((word >> 8) & 0xFF) : (word & 0xFF)
    end

    def read_vdp_control_byte(address)
      word = @vdp.read_control
      address.even? ? ((word >> 8) & 0xFF) : (word & 0xFF)
    end

    def z80_ram_mirror_address?(address)
      @z80_bus && address >= Z80_RAM_BASE && address < YM2612_BASE
    end

    def z80_bank_register_address?(address)
      @z80_bus && (address & 0x00FF_FF00) == Z80_BANK_REGISTER_BASE
    end

    def cartridge_rom_address?(address)
      @rom && address < 0x00A0_0000
    end

    def sram_lock_address?(address)
      address == 0x00A1_30F1
    end

    def sram_lock_span_address?(address, bytes)
      address <= 0x00A1_30F1 && ((address + bytes - 1) & ADDRESS_MASK) >= 0x00A1_30F1
    end

    def sram_control_range?(address)
      (address & 0x00FF_FF00) == 0x00A1_3000
    end

    def sram_lock_read_byte
      value = @sram_enabled ? 0x01 : 0x00
      trace_sram("read8 lock -> #{hex8(value)}")
      value
    end

    def set_sram_enabled(enabled)
      configure_default_sram unless @sram
      previous = @sram_enabled
      @sram_enabled = enabled
      trace_sram("lock #{previous} -> #{@sram_enabled} configured=#{!@sram.nil?} path=#{@sram_path.inspect}")
      flush_sram if previous && !enabled
    end

    def sram_address?(address)
      @sram && @sram_enabled && address >= @sram_start && address <= @sram_end
    end

    def default_sram_window?(address)
      @trace_sram && address >= 0x20_0000 && address <= 0x20_FFFF
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
        io_pair?(address, IO_PORT_2_DATA_BASE) ||
        io_pair?(address, IO_EXPANSION_DATA_BASE) ||
        io_pair?(address, IO_PORT_1_CONTROL_BASE) ||
        io_pair?(address, IO_PORT_2_CONTROL_BASE) ||
        io_pair?(address, IO_EXPANSION_CONTROL_BASE)
    end

    def z80_bus_request_status
      @z80_bus_requested ? 0 : 1
    end

    def can_access_z80_bus?
      @z80_bus_requested
    end

    def read_z80_ram(address)
      @z80_bus.read_byte(address & 0x1FFF)
    end

    def mirrored_z80_word(address)
      value = read_z80_ram((address & 1).zero? ? address : address + 1)
      (value << 8) | value
    end

    def read_rom_word(address)
      length = @rom.length
      ((@rom[address % length] << 8) | @rom[(address + 1) % length]) & 0xFFFF
    end

    def read_work_ram_word(address)
      offset = address & WORK_RAM_MASK
      ((@work_ram[offset] << 8) | @work_ram[(offset + 1) & WORK_RAM_MASK]) & 0xFFFF
    end

    def write_z80_ram(address, value)
      @z80_bus.write_byte(address & 0x1FFF, value)
    end

    def reset_sram
      @sram = nil
      @sram_start = 0
      @sram_end = 0
      @sram_access = :word
      @sram_enabled = false
      @sram_dirty = false
      @sram_path = nil
      @sram_rom_path = nil
    end

    def configure_default_sram
      @sram_rom_path ||= @rom_path if defined?(@rom_path)
      allocate_sram(start: 0x20_0001, end: 0x20_FFFF, access: :word, eeprom: false)
      trace_sram("default start=#{hex24(@sram_start)} end=#{hex24(@sram_end)} path=#{@sram_path.inspect}")
    end

    def allocate_sram(info)
      @sram_start = info[:start]
      @sram_end = info[:end]
      @sram_access = info[:access]
      shift = @sram_access == :word ? 0 : 1
      size = ((@sram_end - @sram_start) >> shift) + 1
      return if size <= 0 || size > 0x20_0000

      @sram = Array.new(size, 0xFF)
      @sram_path = @sram_rom_path && !@sram_rom_path.empty? ? File.join(File.dirname(@sram_rom_path), "#{File.basename(@sram_rom_path, '.*')}.srm") : nil
      load_sram_file
    end

    def initial_sram_enabled?(info)
      return true if info[:eeprom]
      return false unless @rom

      rom_limit = @sram_rom_limit || @rom.length
      info[:start] >= rom_limit
    end

    def read_sram_byte(address)
      index = sram_index(address)
      unless index && index >= 0 && index < @sram.length
        trace_sram("read8 sram #{hex24(address)} invalid index=#{index.inspect}")
        return 0xFF
      end

      value = @sram[index] & 0xFF
      trace_sram("read8 sram #{hex24(address)}[#{hex(index)}] -> #{hex8(value)}")
      value
    end

    def write_sram_byte(address, value)
      index = sram_index(address)
      unless index && index >= 0 && index < @sram.length
        trace_sram("write8 sram #{hex24(address)} invalid index=#{index.inspect} <= #{hex8(value)}")
        return
      end
      return if @sram[index] == value

      @sram[index] = value
      @sram_dirty = true
      trace_sram("write8 sram #{hex24(address)}[#{hex(index)}] <= #{hex8(value)}")
    end

    def sram_index(address)
      case @sram_access
      when :word
        address - @sram_start
      when :byte_even
        return nil unless address.even?

        (address - @sram_start) >> 1
      else
        return nil if address.even?

        (address - @sram_start) >> 1
      end
    end

    def load_sram_file
      return unless @sram_path && File.exist?(@sram_path)

      bytes = File.binread(@sram_path).bytes
      bytes.first(@sram.length).each_with_index { |byte, index| @sram[index] = byte & 0xFF }
      @sram_dirty = false
    rescue SystemCallError
      @sram_dirty = false
    end

    def self.parse_sram_header(bytes)
      return nil unless bytes && bytes.length >= 0x1BC
      return nil unless bytes[0x1B0] == 'R'.ord && bytes[0x1B1] == 'A'.ord

      type = bytes[0x1B2].to_i
      flags = bytes[0x1B3].to_i
      eeprom = type == 0xE8 && flags == 0x40
      access = case type
               when 0xA0, 0xE0 then :word
               when 0xB0, 0xF0 then :byte_even
               when 0xB8, 0xF8 then :byte_odd
               when 0xE8 then :word
               else
                 return nil
               end
      battery = [0xE0, 0xF0, 0xF8].include?(type)
      return nil unless battery || eeprom

      start = read_header_long(bytes, 0x1B4)
      finish = read_header_long(bytes, 0x1B8)
      if eeprom && (finish < start || start < 0x20_0000 || finish > 0x3F_FFFF)
        start = 0x20_0001
        finish = 0x20_FFFF
      end
      return nil if finish < start || start < 0x20_0000 || finish > 0x3F_FFFF

      { start: start, end: finish, access: access, eeprom: eeprom }
    end

    def self.read_header_long(bytes, offset)
      ((bytes[offset].to_i << 24) |
        (bytes[offset + 1].to_i << 16) |
        (bytes[offset + 2].to_i << 8) |
        bytes[offset + 3].to_i) & 0xFFFF_FFFF
    end

    def self.declared_rom_limit(bytes)
      return nil unless bytes && bytes.length >= 0x1A8

      start = read_header_long(bytes, 0x1A0)
      finish = read_header_long(bytes, 0x1A4)
      return nil unless start.zero? && finish.positive? && finish < 0xA0_0000

      finish + 1
    end

    def trace_sram(message)
      return unless @trace_sram
      @trace_sram_count ||= 0
      return if @trace_sram_count >= 100_000
      @trace_sram_count += 1

      @trace_sram_io ||= begin
        Dir.mkdir('logs') unless Dir.exist?('logs')
        File.open('logs/md_sram_trace.log', 'w')
      end
      pc = @trace_pc ? " pc=#{hex24(@trace_pc)}" : ''
      @trace_sram_io.puts("[#{Process.clock_gettime(Process::CLOCK_MONOTONIC).round(6)}]#{pc} #{message}")
      @trace_sram_io.flush
    rescue SystemCallError
      @trace_sram = false
    end

    def trace_sram_enabled? = @trace_sram

    def hex8(value) = "0x%02X" % (value & 0xFF)
    def hex16(value) = "0x%04X" % (value & 0xFFFF)
    def hex24(value) = "0x%06X" % (value & ADDRESS_MASK)
    def hex32(value) = "0x%08X" % (value & 0xFFFF_FFFF)
    def hex(value) = "0x%X" % value

    def trace_ram_address?(address)
      return false unless @trace_sram && @trace_md_ram

      logical = address & ADDRESS_MASK
      logical <= 0x00FF_0040 || (logical >= 0x00FF_3900 && logical <= 0x00FF_4700)
    end

    def vdp_data_address?(address)
      @vdp && (address & 0x00FF_FFE0) == VDP_BASE && [0x00, 0x01, 0x02, 0x03].include?(address & 0x1F)
    end

    def vdp_control_address?(address)
      @vdp && (address & 0x00FF_FFE0) == VDP_BASE && [0x04, 0x05, 0x06, 0x07].include?(address & 0x1F)
    end
  end
end
