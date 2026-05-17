module MegaDrive
  class VDP
    SMS_WIDTH = 256
    SMS_HEIGHT = 192
    VRAM_SIZE = 0x1_0000
    CRAM_SIZE = 0x40
    VSRAM_SIZE = 0x40
    NUM_REGISTERS = 0x20

    attr_reader :registers, :vram, :cram, :vsram, :framebuffer, :render_version
    attr_accessor :irq_level, :bus

    def initialize
      @registers = Array.new(NUM_REGISTERS, 0)
      @vram = Array.new(VRAM_SIZE, 0)
      @cram = Array.new(CRAM_SIZE, 0)
      @vsram = Array.new(VSRAM_SIZE, 0)
      @framebuffer = Array.new(SMS_WIDTH * SMS_HEIGHT, 0)
      @control_pending = false
      @control_latch = 0
      @address = 0
      @mode_write = false
      @location_bits = 0
      @dma_active = false
      @status = 0x3400
      @irq_level = 0
      @render_version = 0
      @video_dirty = true
    end

    def reset
      @registers.fill(0)
      @vram.fill(0)
      @cram.fill(0)
      @vsram.fill(0)
      @framebuffer.fill(0)
      @control_pending = false
      @control_latch = 0
      @address = 0
      @mode_write = false
      @location_bits = 0
      @dma_active = false
      @status = 0x3400
      @irq_level = 0
      @render_version = 0
      @video_dirty = true
    end

    def read_data
      @control_pending = false
      word = read_vram_word(@address)
      increment_address
      word
    end

    def read_control
      @control_pending = false
      @status
    end

    def write_data(value)
      @control_pending = false
      value &= 0xFFFF

      case memory_target
      when :cram
        index = (@address >> 1) & (CRAM_SIZE - 1)
        @video_dirty = true if @cram[index] != value
        @cram[index] = value
      when :vsram
        index = (@address >> 1) & (VSRAM_SIZE - 1)
        @vsram[index] = value
      else
        write_vram_word(@address, value)
      end

      increment_address
    end

    def write_control(value)
      value &= 0xFFFF

      if (value & 0xC000) == 0x8000
        register = (value >> 8) & 0x1F
        data = value & 0xFF
        @video_dirty = true if @registers[register] != data
        @registers[register] = data
        @control_pending = false
        return
      end

      if @control_pending
        @address = (@control_latch & 0x3FFF) | ((value & 0x0007) << 14)
        @location_bits = (@location_bits & 0x01) | ((value >> 3) & 0x06)
        @dma_active = dma_enabled? && (value & 0x0080) != 0
        @control_pending = false
        perform_dma if @dma_active
      else
        @control_latch = value
        @address = (@address & 0x1C000) | (value & 0x3FFF)
        @mode_write = (value & 0x4000) != 0
        @location_bits = (@location_bits & 0x06) | ((value >> 15) & 0x01)
        @control_pending = true
      end
    end

    def render_frame
      draw_scroll_planes if @video_dirty
    end

    def request_vblank!
      @status |= 0x0080
      @irq_level = 6
    end

    def acknowledge_interrupt(_level)
      @irq_level = 0
      @status &= ~0x0080
    end

    private

    def memory_target
      case @location_bits
      when 0x00 then :vram
      when 0x01 then @mode_write ? :cram : :invalid
      when 0x02 then :vsram
      else :invalid
      end
    end

    def dma_enabled?
      (@registers[1] & 0x10) != 0
    end

    def dma_length
      length = ((@registers[20] << 8) | @registers[19]) & 0xFFFF
      length.zero? ? 0x1_0000 : length
    end

    def dma_source_address
      source = (@registers[21] << 1) | (@registers[22] << 9) | ((@registers[23] & 0x3F) << 17)
      source |= 0x80_0000 if (@registers[23] & 0x40) != 0
      source & 0xFF_FFFE
    end

    def dma_mode
      @registers[23] & 0xC0
    end

    def perform_dma
      return unless @bus && dma_mode < 0x80

      source = dma_source_address
      dma_length.times do
        write_data(@bus.read_word(source))
        source = (source + 2) & 0xFF_FFFE
      end
      @dma_active = false
    end

    def read_vram_word(address)
      high = @vram[address & 0xFFFF] || 0
      low = @vram[(address + 1) & 0xFFFF] || 0
      ((high << 8) | low) & 0xFFFF
    end

    def write_vram_word(address, value)
      address &= 0xFFFF
      high = (value >> 8) & 0xFF
      low = value & 0xFF
      @video_dirty = true if @vram[address] != high || @vram[(address + 1) & 0xFFFF] != low
      @vram[address] = high
      @vram[(address + 1) & 0xFFFF] = low
    end

    def increment_address
      increment = @registers[15]
      increment = 2 if increment.zero?
      @address = (@address + increment) & 0xFFFF
    end

    def draw_scroll_planes
      backdrop = color_index(@registers[7] & 0x3F)
      @framebuffer.fill(backdrop)
      drew = false

      h_scroll_a, h_scroll_b, v_scroll_a, v_scroll_b = scroll_values
      drew |= draw_plane(plane_b_base, h_scroll_b, v_scroll_b)
      drew |= draw_plane(plane_a_base, h_scroll_a, v_scroll_a)
      draw_vram_activity_frame unless drew

      @video_dirty = false
      @render_version += 1
    end

    def draw_plane(nametable_base, h_scroll, v_scroll)
      return false if nametable_base.zero?

      width_cells, height_cells = plane_dimensions
      drew = false

      SMS_HEIGHT.times do |screen_y|
        scrolled_y = (screen_y + v_scroll) % (height_cells * 8)
        cell_y = scrolled_y / 8
        row_in_tile = scrolled_y & 7
        SMS_WIDTH.times do |screen_x|
          scrolled_x = (screen_x - h_scroll) % (width_cells * 8)
          cell_x = scrolled_x / 8
          column_in_tile = scrolled_x & 7
          entry = read_vram_word(nametable_base + ((cell_y * width_cells + cell_x) * 2))
          pixel = tile_pixel(entry, row_in_tile, column_in_tile)
          next if pixel.zero?

          @framebuffer[screen_y * SMS_WIDTH + screen_x] = color_index(((entry >> 9) & 0x30) | pixel)
          drew = true
        end
      end

      drew
    end

    def draw_vram_activity_frame
      @vram.each_with_index do |byte, index|
        next if byte.zero?

        pixel = ((index * 37) % @framebuffer.length)
        color = ((byte >> 2) ^ (index >> 5)) & 0x3F
        color = 1 if color.zero?
        @framebuffer[pixel] = color
        @framebuffer[pixel + 1] = color if (pixel % SMS_WIDTH) < SMS_WIDTH - 1
        @framebuffer[pixel + SMS_WIDTH] = color if pixel + SMS_WIDTH < @framebuffer.length
      end
    end

    def tile_pixel(entry, row, column)
      pattern = entry & 0x07FF
      row = 7 - row if (entry & 0x1000) != 0
      column = 7 - column if (entry & 0x0800) != 0
      address = (pattern * 32 + row * 4 + column / 2) & 0xFFFF
      byte = @vram[address] || 0
      column.even? ? (byte >> 4) & 0x0F : byte & 0x0F
    end

    def color_index(cram_index)
      cram_value = @cram[cram_index & (CRAM_SIZE - 1)] || 0
      return md_color_to_sms_index(cram_value) unless cram_value.zero?

      cram_index & 0x3F
    end

    def plane_dimensions
      h = case @registers[16] & 0x03
          when 1 then 64
          when 3 then 128
          else 32
          end
      v = case (@registers[16] >> 4) & 0x03
          when 1 then 64
          when 3 then 128
          else 32
          end
      [h, v]
    end

    def scroll_values
      hscroll_base = (@registers[13] & 0x3F) << 10
      h_scroll_a = read_vram_word(hscroll_base) & 0x03FF
      h_scroll_b = read_vram_word(hscroll_base + 2) & 0x03FF
      v_scroll_a = (@vsram[0] || 0) & 0x03FF
      v_scroll_b = (@vsram[1] || 0) & 0x03FF
      [h_scroll_a, h_scroll_b, v_scroll_a, v_scroll_b]
    end

    def plane_a_base
      (@registers[2] & 0x38) << 10
    end

    def plane_b_base
      (@registers[4] & 0x07) << 13
    end

    def md_color_to_sms_index(value)
      r = value & 0x00E
      g = (value >> 4) & 0x00E
      b = (value >> 8) & 0x00E
      ((r >> 1) | ((g >> 1) << 2) | ((b >> 1) << 4)) & 0x3F
    end
  end
end
