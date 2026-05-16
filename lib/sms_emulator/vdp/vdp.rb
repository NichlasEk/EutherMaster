module SmsEmulator
  class VDP
    SMS_WIDTH = 256
    SMS_HEIGHT = 192
    SMS_HEIGHT_EXTENDED = 224  # Some modes

    # VDP registers
    NUM_REGISTERS = 11

    attr_reader :registers, :vram, :cram, :framebuffer, :render_version
    attr_accessor :irq_line

    def initialize
      @registers = Array.new(NUM_REGISTERS, 0)
      @vram = Array.new(0x4000, 0)    # 16KB VRAM
      @cram = Array.new(32, 0)        # 32 bytes Color RAM
      @framebuffer = Array.new(SMS_WIDTH * SMS_HEIGHT, 0)
      @irq_line = false
      @status = 0x00
      @addr_latch = nil
      @code_register = 0
      @v_counter = 0
      @h_counter = 0
      @line_counter = 0
      @write_pending = false
      @video_dirty = true
      @render_version = 0
    end

    def reset
      @registers.fill(0)
      @vram.fill(0)
      @cram.fill(0)
      @framebuffer.fill(0)
      @irq_line = false
      @status = 0x00
      @addr_latch = nil
      @code_register = 0
      @v_counter = 0
      @h_counter = 0
      @line_counter = 0
      @write_pending = false
      @video_dirty = true
      @render_version = 0
    end

    # CPU I/O port $BE - VDP data port (read/write)
    def read_data
      @write_pending = false
      value = @vram[@addr_latch || 0]
      increment_address
      value
    end

    def write_data(value)
      value &= 0xFF
      @write_pending = false

      if @code_register == 3
        # CRAM write
        cram_addr = @addr_latch & 0x1F
        @video_dirty = true if @cram[cram_addr] != value
        @cram[cram_addr] = value
      else
        vram_addr = @addr_latch || 0
        @video_dirty = true if @vram[vram_addr] != value
        @vram[vram_addr] = value
      end

      increment_address
    end

    # CPU I/O port $BF - VDP control port (write)
    # Also used to set VRAM address and register writes
    def write_control(value)
      if @write_pending
        # Second write: upper byte with command/register selector.
        @code_register = (value >> 6) & 0x03
        latched = @addr_latch || 0

        if @code_register == 2
          reg_num = value & 0x0F
          if reg_num < NUM_REGISTERS
            @video_dirty = true if @registers[reg_num] != (latched & 0xFF)
            @registers[reg_num] = latched & 0xFF
          end
          @addr_latch = 0
        else
          @addr_latch = (latched | ((value & 0x3F) << 8)) & 0x3FFF
        end
        @write_pending = false
      else
        # First write: lower address byte
        @addr_latch = value & 0xFF
        @write_pending = true
      end
    end

    def read_status
      @write_pending = false
      temp = @status
      @status &= 0x1F  # Clear interrupt flags
      @irq_line = false
      @line_counter = @registers[10] & 0xFF
      temp
    end

    # Read V counter ($7E)
    def read_v_counter
      @v_counter
    end

    # Read H counter ($7F)
    def read_h_counter
      @h_counter
    end

    def increment_address
      @addr_latch = (@addr_latch + 1) & 0x3FFF
    end

    # Render one scanline
    def render_scanline(scanline)
      return unless scanline < SMS_HEIGHT

      @v_counter = scanline
      unless display_enabled?
        backdrop = @cram[(@registers[7] & 0x0F) | 0x10] || 0
        SMS_WIDTH.times { |x| @framebuffer[scanline * SMS_WIDTH + x] = backdrop }
        return
      end

      render_background_scanline(scanline)
      render_sprite_scanline(scanline)
      blank_left_column(scanline) if left_column_blank?
    end

    def render_background_scanline(scanline)
      name_base = (@registers[2] & 0x0E) << 10
      y_scroll = (@registers[9] || 0) & 0xFF
      x_scroll = (@registers[8] || 0) & 0xFF
      source_y = (scanline + y_scroll) & 0xFF
      tile_row = (source_y / 8) & 0x1F
      row_in_tile = source_y & 7
      row_offset = scanline * SMS_WIDTH

      33.times do |screen_tile|
        screen_x = screen_tile * 8
        source_x = (screen_x - x_scroll) & 0xFF
        tile_col = (source_x / 8) & 0x1F
        first_col = source_x & 7
        entry_addr = (name_base + ((tile_row * 32 + tile_col) * 2)) & 0x3FFF
        entry = @vram[entry_addr] | ((@vram[(entry_addr + 1) & 0x3FFF] || 0) << 8)
        tile_index = entry & 0x01FF
        palette = (entry & 0x0800) != 0 ? 16 : 0
        h_flip = (entry & 0x0200) != 0
        v_flip = (entry & 0x0400) != 0
        py = v_flip ? 7 - row_in_tile : row_in_tile
        pattern_base = (tile_index * 32 + py * 4) & 0x3FFF
        b0 = @vram[pattern_base]
        b1 = @vram[(pattern_base + 1) & 0x3FFF]
        b2 = @vram[(pattern_base + 2) & 0x3FFF]
        b3 = @vram[(pattern_base + 3) & 0x3FFF]

        8.times do |pixel_in_tile|
          x = screen_x + pixel_in_tile
          next if x >= SMS_WIDTH

          col = (first_col + pixel_in_tile) & 7
          px = h_flip ? 7 - col : col
          bit = 7 - px
          color_index = ((b0 >> bit) & 1) |
            (((b1 >> bit) & 1) << 1) |
            (((b2 >> bit) & 1) << 2) |
            (((b3 >> bit) & 1) << 3)
          @framebuffer[row_offset + x] = @cram[(palette + color_index) & 0x1F] || 0
        end
      end
    end

    def render_sprite_scanline(scanline)
      sprite_height = sprite_16px? ? 16 : 8
      zoom = sprite_zoom? ? 2 : 1
      drawn_on_line = 0
      occupied = Array.new(SMS_WIDTH, false)

      64.times do |sprite_index|
        attr_addr = (sprite_attribute_base + sprite_index) & 0x3FFF
        y = @vram[attr_addr] || 0
        break if y == 0xD0

        y = (y + 1) & 0xFF
        y -= 256 if y > 240
        next unless scanline >= y && scanline < y + sprite_height * zoom

        drawn_on_line += 1
        @status |= 0x40 if drawn_on_line > 8
        next if drawn_on_line > 8

        entry_addr = (sprite_attribute_base + 0x80 + sprite_index * 2) & 0x3FFF
        x = @vram[entry_addr] || 0
        tile = @vram[(entry_addr + 1) & 0x3FFF] || 0
        x -= 8 if (@registers[0] & 0x08) != 0
        row = (scanline - y) / zoom
        tile &= 0xFE if sprite_16px?
        tile += 1 if row >= 8
        row &= 7
        tile = (tile + sprite_pattern_offset) & 0x1FF

        8.times do |col|
          color_index = pattern_pixel(tile, col, row)
          next if color_index == 0

          zoom.times do |zx|
            px = x + col * zoom + zx
            next if px.negative? || px >= SMS_WIDTH

            @status |= 0x20 if occupied[px]
            occupied[px] = true
            @framebuffer[scanline * SMS_WIDTH + px] = @cram[(16 + color_index) & 0x1F] || 0
          end
        end
      end
    end

    def render_frame
      begin_frame
      262.times { |scanline| step_scanline(scanline, render: true) }
    end

    def begin_frame
      @status &= 0x1F
      @irq_line = false
      @line_counter = @registers[10] & 0xFF
    end

    def step_scanline(scanline, render: true)
      @v_counter = scanline & 0xFF

      if scanline < SMS_HEIGHT
        render_scanline(scanline) if render
        clock_line_interrupt
      elsif scanline == SMS_HEIGHT
        @status |= 0x80
        @irq_line = true if frame_irq_enabled?
      end
    end

    def render_visible_frame
      return unless @video_dirty

      SMS_HEIGHT.times { |scanline| render_scanline(scanline) }
      @video_dirty = false
      @render_version += 1
    end

    def clock_line_interrupt
      if @line_counter.zero?
        @line_counter = @registers[10] & 0xFF
        @irq_line = true if line_irq_enabled?
      else
        @line_counter = (@line_counter - 1) & 0xFF
      end
    end

    def pattern_pixel(tile_index, x, y)
      base = (tile_index * 32 + y * 4) & 0x3FFF
      bit = 7 - x
      ((@vram[base] >> bit) & 1) |
        (((@vram[(base + 1) & 0x3FFF] >> bit) & 1) << 1) |
        (((@vram[(base + 2) & 0x3FFF] >> bit) & 1) << 2) |
        (((@vram[(base + 3) & 0x3FFF] >> bit) & 1) << 3)
    end

    def sprite_attribute_base
      (@registers[5] & 0x7E) << 7
    end

    def sprite_pattern_offset
      (@registers[6] & 0x04) != 0 ? 0x100 : 0
    end

    def sprite_16px?
      (@registers[1] & 0x02) != 0
    end

    def sprite_zoom?
      (@registers[1] & 0x01) != 0
    end

    def display_enabled?
      (@registers[1] & 0x40) != 0
    end

    def left_column_blank?
      (@registers[0] & 0x20) != 0
    end

    def frame_irq_enabled?
      (@registers[1] & 0x20) != 0
    end

    def line_irq_enabled?
      (@registers[0] & 0x10) != 0
    end

    def blank_left_column(scanline)
      backdrop = @cram[(@registers[7] & 0x0F) | 0x10] || 0
      8.times { |x| @framebuffer[scanline * SMS_WIDTH + x] = backdrop }
    end

    # Dump framebuffer to ChunkyPNG image (for debugging)
    def dump_framebuffer(path = 'debug_framebuffer.png')
      require 'chunky_png'
      png = ChunkyPNG::Image.new(SMS_WIDTH, SMS_HEIGHT)

      SMS_HEIGHT.times do |y|
        SMS_WIDTH.times do |x|
          color = @framebuffer[y * SMS_WIDTH + x]
          # SMS colors are 6-bit (GG is 12-bit)
          # Convert to 24-bit RGB roughly
          r = ((color >> 0) & 0x03) * 85
          g = ((color >> 2) & 0x03) * 85
          b = ((color >> 4) & 0x03) * 85
          png[x, y] = ChunkyPNG::Color.rgb(r, g, b)
        end
      end

      png.save(path)
    end

    def dump_vram_tiles(path = 'debug_tiles.png', num_tiles = 256)
      require 'chunky_png'
      tiles_x = 16
      tiles_y = (num_tiles + tiles_x - 1) / tiles_x
      tile_size = 8

      png = ChunkyPNG::Image.new(tiles_x * tile_size, tiles_y * tile_size)

      num_tiles.times do |tile_idx|
        base_addr = tile_idx * 32  # 4 bytes per 8 pixels * 8 lines = 32 bytes per tile
        tile_x = (tile_idx % tiles_x) * tile_size
        tile_y = (tile_idx / tiles_x) * tile_size

        8.times do |row|
          # 4 bytes per row in Mode 4
          b0 = @vram[base_addr + row * 4]     || 0
          b1 = @vram[base_addr + row * 4 + 1] || 0
          b2 = @vram[base_addr + row * 4 + 2] || 0
          b3 = @vram[base_addr + row * 4 + 3] || 0

          8.times do |col|
            bit = 7 - col
            pixel = ((b0 >> bit) & 1) |
                   (((b1 >> bit) & 1) << 1) |
                   (((b2 >> bit) & 1) << 2) |
                   (((b3 >> bit) & 1) << 3)

            gray = pixel * 17
            png[tile_x + col, tile_y + row] = ChunkyPNG::Color.rgb(gray, gray, gray)
          end
        end
      end

      png.save(path)
    end
  end
end
