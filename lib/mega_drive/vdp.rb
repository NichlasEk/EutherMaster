module MegaDrive
  class VDP
    DEFAULT_WIDTH = 256
    DEFAULT_HEIGHT = 224
    VRAM_SIZE = 0x1_0000
    CRAM_SIZE = 0x40
    VSRAM_SIZE = 0x40
    NUM_REGISTERS = 0x20
    LINE_CYCLES = 228
    VISIBLE_LINES = 224
    TOTAL_LINES = 262
    FRAME_CYCLES = LINE_CYCLES * TOTAL_LINES
    VBLANK_START_CYCLE = LINE_CYCLES * VISIBLE_LINES

    attr_reader :registers, :vram, :cram, :vsram, :framebuffer, :render_version,
                :screen_width, :screen_height
    attr_accessor :irq_level, :bus

    def initialize
      @registers = Array.new(NUM_REGISTERS, 0)
      @vram = Array.new(VRAM_SIZE, 0)
      @cram = Array.new(CRAM_SIZE, 0)
      @vsram = Array.new(VSRAM_SIZE, 0)
      @screen_width = DEFAULT_WIDTH
      @screen_height = DEFAULT_HEIGHT
      @framebuffer = Array.new(@screen_width * @screen_height, 0)
      @control_pending = false
      @control_latch = 0
      @address = 0
      @mode_write = false
      @location_bits = 0
      @code = 0
      @dma_active = false
      @status = 0x3400
      @irq_level = 0
      @render_version = 0
      @video_dirty = true
      @palette_version = -1
      @palette_rgba = nil
      @sharp_palette_rgba = nil
      @pattern_row_cache = Array.new(0x800 * 8)
      @pattern_row_cache_packed = true
      @sprite_pixel_cache = nil
      @sprite_occupancy_stamp = 0
      @vblank_counter_pending = false
    end

    def reset
      @registers.fill(0)
      @vram.fill(0)
      @cram.fill(0)
      @vsram.fill(0)
      @screen_width = DEFAULT_WIDTH
      @screen_height = DEFAULT_HEIGHT
      @framebuffer = Array.new(@screen_width * @screen_height, 0)
      @control_pending = false
      @control_latch = 0
      @address = 0
      @mode_write = false
      @location_bits = 0
      @code = 0
      @dma_active = false
      @status = 0x3400
      @irq_level = 0
      @render_version = 0
      @video_dirty = true
      @palette_version = -1
      @palette_rgba = nil
      @sharp_palette_rgba = nil
      @pattern_row_cache = Array.new(0x800 * 8)
      @pattern_row_cache_packed = true
      @sprite_pixel_cache = nil
      @sprite_occupancy_stamp = 0
      @vblank_counter_pending = false
    end

    def read_data
      @control_pending = false
      word = case memory_target
             when :cram
               @cram[(@address >> 1) & (CRAM_SIZE - 1)] || 0
             when :vsram
               @vsram[(@address >> 1) & (VSRAM_SIZE - 1)] || 0
             else
               read_vram_word(@address)
             end
      increment_address
      word
    end

    def read_control
      @control_pending = false
      status = @status
      status = vblank? ? (status | 0x0008) : (status & ~0x0008)
      hblank_status? ? (status | 0x0004) : (status & ~0x0004)
    end

    def read_hv_counter
      v = v_counter
      if @vblank_counter_pending
        v = 0xE0
        @vblank_counter_pending = false
      end
      ((v << 8) | h_counter) & 0xFFFF
    end

    def write_data(value)
      @control_pending = false
      value &= 0xFFFF

      if @dma_active && dma_mode == 0x80
        perform_vram_fill(value)
        return
      end

      case memory_target
      when :cram
        index = (@address >> 1) & (CRAM_SIZE - 1)
        value &= 0x0FFF
        @video_dirty = true if @cram[index] != value
        @cram[index] = value
        @palette_version = -1
      when :vsram
        index = (@address >> 1) & (VSRAM_SIZE - 1)
        value &= 0x07FF
        @video_dirty = true if @vsram[index] != value
        @vsram[index] = value
      else
        write_vram_word(@address, value)
      end

      increment_address
    end

    def write_data_byte(address, value)
      write_data((value & 0xFF) * 0x0101)
    end

    def write_control(value)
      value &= 0xFFFF

      if @control_pending
        @address = (@control_latch & 0x3FFF) | ((value & 0x0007) << 14)
        @location_bits = (@location_bits & 0x01) | ((value >> 3) & 0x06)
        @dma_active = dma_enabled? && (value & 0x0080) != 0
        @control_pending = false
        perform_dma if @dma_active
      else
        @control_latch = value
        @address = (@address & 0x1C000) | (value & 0x3FFF)

        if (value & 0xC000) == 0x8000
          register = (value >> 8) & 0x1F
          data = value & 0xFF
          @video_dirty = true if @registers[register] != data
          @registers[register] = data
          @control_pending = false
        else
          @mode_write = (value & 0x4000) != 0
          @location_bits = (@location_bits & 0x06) | ((value >> 15) & 0x01)
          @control_pending = true
        end
      end
    end

    def write_control_byte(address, value)
      write_control((value & 0xFF) * 0x0101)
    end

    def render_frame
      return unless @video_dirty

      draw_scroll_planes
    end

    def request_vblank!
      @status |= 0x0080
      @vblank_counter_pending = true
      @irq_level = 6
    end

    def end_vblank!
      @status &= ~0x0080
    end

    def acknowledge_interrupt(_level)
      @irq_level = 0
    end

    def palette_rgba
      rebuild_palettes if @palette_version != @render_version || !@palette_rgba
      @palette_rgba
    end

    def sharp_palette_rgba
      rebuild_palettes if @palette_version != @render_version || !@sharp_palette_rgba
      @sharp_palette_rgba
    end

    private

    def rebuild_palettes
      @palette_rgba = Array.new(CRAM_SIZE) { |index| md_color_rgba(@cram[index] || 0) }
      @sharp_palette_rgba = Array.new(CRAM_SIZE) do |index|
        rgba = @palette_rgba[index].bytes
        [sharp_channel(rgba[0]), sharp_channel(rgba[1]), sharp_channel(rgba[2]), 255].pack('C4')
      end
      @palette_version = @render_version
    end

    def md_color_rgba(value)
      levels = [0, 52, 87, 116, 144, 172, 206, 255]
      r = levels[(value >> 1) & 0x07]
      g = levels[(value >> 5) & 0x07]
      b = levels[(value >> 9) & 0x07]
      [r, g, b, 255].pack('C4')
    end

    def sharp_channel(value)
      value = 127.5 + (value - 127.5) * 1.35
      value.round.clamp(0, 255)
    end

    def memory_target
      case [@location_bits & 0x07, @mode_write]
      when [0x00, true], [0x00, false]
        :vram
      when [0x01, true], [0x04, false]
        :cram
      when [0x02, true], [0x02, false]
        :vsram
      when [0x06, false]
        :vram
      else
        :invalid
      end
    end

    def hblank?
      cycle = @bus&.respond_to?(:frame_cycle) ? @bus.frame_cycle.to_i : 0
      (cycle % LINE_CYCLES) >= 170
    end

    def vblank?
      cycle = @bus&.respond_to?(:frame_cycle) ? @bus.frame_cycle.to_i : 0
      cycle >= VBLANK_START_CYCLE
    end

    def hblank_status?
      hblank? || vblank?
    end

    def v_counter
      cycle = @bus&.respond_to?(:frame_cycle) ? @bus.frame_cycle.to_i : 0
      (cycle / LINE_CYCLES).clamp(0, TOTAL_LINES - 1) & 0xFF
    end

    def h_counter
      cycle = @bus&.respond_to?(:frame_cycle) ? @bus.frame_cycle.to_i : 0
      ((cycle % LINE_CYCLES) * 342 / LINE_CYCLES).clamp(0, 0xFF)
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
      return unless @bus
      return perform_vram_copy if dma_mode == 0xC0
      return unless dma_mode < 0x80

      source = dma_source_address
      length = dma_length
      length.times do
        write_data(@bus.read_word(source))
        increment_dma_source_address
        decrement_dma_length
        source = dma_source_address
      end
      @dma_active = false
    end

    def perform_vram_fill(value)
      byte = (value >> 8) & 0xFF
      dma_length.times do
        write_memory_byte((@address ^ 1) & 0xFFFF, byte)
        increment_dma_source_address
        increment_address
      end
      @dma_active = false
    end

    def perform_vram_copy
      source = dma_source_address
      dma_length.times do
        write_vram_word(@address, read_vram_word(source & 0xFFFF))
        increment_dma_source_address
        source = (source + 2) & 0xFFFF
        increment_address
      end
      @dma_active = false
    end

    def increment_dma_source_address
      source = dma_source_address
      source = (source & ~0x1FFFF) | ((source + 2) & 0x1FFFF)
      @registers[21] = (source >> 1) & 0xFF
      @registers[22] = (source >> 9) & 0xFF
      @registers[23] = (@registers[23] & 0xC0) | ((source >> 17) & 0x3F)
    end

    def decrement_dma_length
      length = (((@registers[20] << 8) | @registers[19]) - 1) & 0xFFFF
      @registers[19] = length & 0xFF
      @registers[20] = (length >> 8) & 0xFF
    end

    def write_memory_byte(address, byte)
      byte &= 0xFF
      case memory_target
      when :cram
        index = (address >> 1) & (CRAM_SIZE - 1)
        old = @cram[index] || 0
        value = address.even? ? ((byte << 8) | (old & 0x00FF)) : ((old & 0xFF00) | byte)
        value &= 0x0FFF
        @video_dirty = true if @cram[index] != value
        @cram[index] = value
        @palette_version = -1
      when :vsram
        index = (address >> 1) & (VSRAM_SIZE - 1)
        old = @vsram[index] || 0
        value = address.even? ? ((byte << 8) | (old & 0x00FF)) : ((old & 0xFF00) | byte)
        value &= 0x07FF
        @video_dirty = true if @vsram[index] != value
        @vsram[index] = value
      else
        address &= 0xFFFF
        @video_dirty = true if @vram[address] != byte
        @vram[address] = byte
        invalidate_pattern_row(address)
      end
    end

    def read_vram_word(address)
      high = @vram[address & 0xFFFF] || 0
      low = @vram[(address ^ 1) & 0xFFFF] || 0
      ((high << 8) | low) & 0xFFFF
    end

    def write_vram_word(address, value)
      address &= 0xFFFF
      high = (value >> 8) & 0xFF
      low = value & 0xFF
      low_address = (address ^ 1) & 0xFFFF
      @video_dirty = true if @vram[address] != high || @vram[low_address] != low
      @vram[address] = high
      @vram[low_address] = low
      invalidate_pattern_row(address)
      invalidate_pattern_row(low_address)
    end

    def increment_address
      increment = @registers[15]
      increment = 2 if increment.zero?
      @address = (@address + increment) & 0xFFFF
    end

    def draw_scroll_planes
      ensure_framebuffer_size
      backdrop = color_index(@registers[7] & 0x3F)
      drew = !display_enabled?
      rendered_display = false

      if display_enabled?
        rendered_display = true
        prepare_render_cache
        drew = if fast_scroll_renderer?
                 draw_scroll_planes_fast
               else
                 @framebuffer.fill(backdrop)
                 draw_scroll_planes_generic
               end
      else
        @framebuffer.fill(backdrop)
      end

      draw_vram_activity_frame unless drew || rendered_display

      @video_dirty = false
      @render_version += 1
    end

    def draw_scroll_planes_generic
      sprites = sprite_pixels
      height = @screen_height
      width = @screen_width
      drew = false
      height.times do |screen_y|
        source_y = @source_y_cache[screen_y]
        row_offset = screen_y * width
        width.times do |screen_x|
          source_x = @source_x_cache[screen_x]
          scroll_b = plane_pixel(:b, source_x, source_y)
          scroll_a = if @window_enabled_cache
                       window_pixel(source_x, source_y) || plane_pixel(:a, source_x, source_y)
                     else
                       plane_pixel(:a, source_x, source_y)
                     end
          sprite = sprites[row_offset + screen_x]
          pixel = resolve_pixel(sprite, scroll_a, scroll_b)
          next unless pixel

          @framebuffer[row_offset + screen_x] = pixel & 0x3F
          drew = true
        end
      end
      drew
    end

    def fast_scroll_renderer?
      !@window_enabled_cache &&
        @source_x_cache&.length == @screen_width &&
        @source_y_cache&.length == @screen_height &&
        @source_x_cache[0] == 0 &&
        @source_x_cache[-1] == @screen_width - 1 &&
        @source_y_cache[0] == 0 &&
        @source_y_cache[-1] == @screen_height - 1
    end

    def draw_scroll_planes_fast
      vram = @vram
      framebuffer = @framebuffer
      pattern_cache = @pattern_row_cache
      width = @screen_width
      height = @screen_height
      width_cells, height_cells = @plane_dimensions_cache
      map_width = width_cells * 8
      map_height = height_cells * 8
      map_width_mask = map_width - 1
      map_height_mask = map_height - 1
      plane_a = plane_a_base
      plane_b = plane_b_base
      h_scroll_a = @h_scroll_a_cache
      h_scroll_b = @h_scroll_b_cache
      v_scroll_a = @v_scroll_a_cache
      v_scroll_b = @v_scroll_b_cache
      v_scroll_a_single = @v_scroll_a_single_cache
      v_scroll_b_single = @v_scroll_b_single_cache
      drew = false
      backdrop = color_index(@registers[7] & 0x3F)

      screen_y = 0
      while screen_y < height
        row_offset = screen_y * width
        ha = h_scroll_a[screen_y]
        hb = h_scroll_b[screen_y]
        sy_a_row = ((screen_y + v_scroll_a_single) & map_height_mask) if v_scroll_a_single
        sy_b_row = ((screen_y + v_scroll_b_single) & map_height_mask) if v_scroll_b_single
        screen_x = 0
        while screen_x < width
          column = screen_x >> 4
          sy_b = sy_b_row || ((screen_y + v_scroll_b[column]) & map_height_mask)
          sx_b = (screen_x - hb) & map_width_mask
          cell_y_b = sy_b >> 3
          cell_x_b = sx_b >> 3
          address_b = (plane_b + ((2 * (cell_y_b * width_cells + cell_x_b)) & 0x1FFF)) & 0xFFFF
          entry_b = ((vram[address_b] || 0) << 8) | (vram[(address_b ^ 1) & 0xFFFF] || 0)
          row_b = sy_b & 7
          row_b = 7 - row_b if (entry_b & 0x1000) != 0
          col_b = sx_b & 7
          col_b = 7 - col_b if (entry_b & 0x0800) != 0
          key_b = ((entry_b & 0x07FF) << 3) | row_b
          packed_b = pattern_cache[key_b]
          unless packed_b
            tile_b = (entry_b & 0x07FF) * 32 + row_b * 4
            packed_b = ((vram[tile_b & 0xFFFF] || 0) << 24) |
                       ((vram[(tile_b + 1) & 0xFFFF] || 0) << 16) |
                       ((vram[(tile_b + 2) & 0xFFFF] || 0) << 8) |
                       (vram[(tile_b + 3) & 0xFFFF] || 0)
            pattern_cache[key_b] = packed_b
          end
          step_b = (entry_b & 0x0800) != 0 ? -1 : 1
          limit_b = step_b.positive? ? 8 - col_b : col_b + 1
          attr_b = ((entry_b & 0x8000) != 0 ? 0x100 : 0) | ((entry_b >> 9) & 0x30)

          sy_a = sy_a_row || ((screen_y + v_scroll_a[column]) & map_height_mask)
          sx_a = (screen_x - ha) & map_width_mask
          cell_y_a = sy_a >> 3
          cell_x_a = sx_a >> 3
          address_a = (plane_a + ((2 * (cell_y_a * width_cells + cell_x_a)) & 0x1FFF)) & 0xFFFF
          entry_a = ((vram[address_a] || 0) << 8) | (vram[(address_a ^ 1) & 0xFFFF] || 0)
          row_a = sy_a & 7
          row_a = 7 - row_a if (entry_a & 0x1000) != 0
          col_a = sx_a & 7
          col_a = 7 - col_a if (entry_a & 0x0800) != 0
          key_a = ((entry_a & 0x07FF) << 3) | row_a
          packed_a = pattern_cache[key_a]
          unless packed_a
            tile_a = (entry_a & 0x07FF) * 32 + row_a * 4
            packed_a = ((vram[tile_a & 0xFFFF] || 0) << 24) |
                       ((vram[(tile_a + 1) & 0xFFFF] || 0) << 16) |
                       ((vram[(tile_a + 2) & 0xFFFF] || 0) << 8) |
                       (vram[(tile_a + 3) & 0xFFFF] || 0)
            pattern_cache[key_a] = packed_a
          end
          step_a = (entry_a & 0x0800) != 0 ? -1 : 1
          limit_a = step_a.positive? ? 8 - col_a : col_a + 1
          attr_a = ((entry_a & 0x8000) != 0 ? 0x100 : 0) | ((entry_a >> 9) & 0x30)

          run = width - screen_x
          column_run = 16 - (screen_x & 15)
          run = column_run if column_run < run
          run = limit_a if limit_a < run
          run = limit_b if limit_b < run

          run_index = 0
          index = row_offset + screen_x
          shift_a = (7 - col_a) * 4
          shift_b = (7 - col_b) * 4
          shift_step_a = -4 * step_a
          shift_step_b = -4 * step_b
          if packed_a.zero? && packed_b.zero?
            while run_index < run
              framebuffer[index] = backdrop
              index += 1
              run_index += 1
            end
          elsif packed_a.zero?
            while run_index < run
              color_b = (packed_b >> shift_b) & 0x0F
              framebuffer[index] = color_b.zero? ? backdrop : (attr_b | color_b)
              shift_b += shift_step_b
              index += 1
              run_index += 1
            end
            drew = true
          elsif packed_b.zero? || (attr_a & 0x100) != 0
            while run_index < run
              color_a = (packed_a >> shift_a) & 0x0F
              framebuffer[index] = color_a.zero? ? backdrop : (attr_a | color_a)
              shift_a += shift_step_a
              index += 1
              run_index += 1
            end
            drew = true
          else
            while run_index < run
              color_b = (packed_b >> shift_b) & 0x0F
              color_a = (packed_a >> shift_a) & 0x0F

              if color_a != 0
                if color_b == 0 || (attr_b & 0x100).zero?
                  framebuffer[index] = attr_a | color_a
                else
                  framebuffer[index] = attr_b | color_b
                end
                drew = true
              elsif color_b != 0
                framebuffer[index] = attr_b | color_b
                drew = true
              else
                framebuffer[index] = backdrop
              end

              shift_a += shift_step_a
              shift_b += shift_step_b
              index += 1
              run_index += 1
            end
          end
          screen_x += run
        end
        screen_y += 1
      end

      draw_sprites_over_scroll_fast(framebuffer)
      drew
    end

    def draw_sprites_over_scroll_fast(framebuffer)
      vram = @vram
      width = @screen_width
      height = @screen_height
      pixel_count = width * height
      occupied = @sprite_occupied_cache
      if !occupied || occupied.length != pixel_count
        occupied = Array.new(pixel_count, 0)
        @sprite_occupied_cache = occupied
      end
      stamp = ((@sprite_occupancy_stamp || 0) + 1) & 0x3FFF_FFFF
      if stamp.zero?
        occupied.fill(0)
        stamp = 1
      end
      @sprite_occupancy_stamp = stamp

      base = sprite_table_base
      sprite = 0
      80.times do
        address = base + sprite * 8
        y = (((vram[address & 0xFFFF] || 0) << 8) | (vram[(address ^ 1) & 0xFFFF] || 0)) & 0x03FF
        size_address = (address + 2) & 0xFFFF
        size_link = ((vram[size_address] || 0) << 8) | (vram[(size_address ^ 1) & 0xFFFF] || 0)
        attr_address = (address + 4) & 0xFFFF
        attr = ((vram[attr_address] || 0) << 8) | (vram[(attr_address ^ 1) & 0xFFFF] || 0)
        x_address = (address + 6) & 0xFFFF
        x = (((vram[x_address] || 0) << 8) | (vram[(x_address ^ 1) & 0xFFFF] || 0)) & 0x01FF
        draw_sprite_over_scroll_fast(framebuffer, occupied, stamp, x - 0x80, y - 0x80,
          ((size_link >> 10) & 0x03) + 1, ((size_link >> 8) & 0x03) + 1, attr)
        link = size_link & 0x7F
        break if link.zero? || link == sprite

        sprite = link
      end
    end

    def draw_sprite_over_scroll_fast(framebuffer, occupied, stamp, screen_x, screen_y, h_cells, v_cells, attr)
      vram = @vram
      pattern_cache = @pattern_row_cache
      pattern = attr & 0x07FF
      h_flip = (attr & 0x0800) != 0
      v_flip = (attr & 0x1000) != 0
      palette = (attr >> 9) & 0x30
      priority = (attr & 0x8000) != 0
      width = @screen_width
      height = @screen_height

      sprite_height = v_cells * 8
      sprite_width = h_cells * 8
      sy = screen_y.negative? ? -screen_y : 0
      sy_end = [sprite_height, height - screen_y].min
      sx_start = screen_x.negative? ? -screen_x : 0
      sx_end = [sprite_width, width - screen_x].min
      return if sy >= sy_end || sx_start >= sx_end

      while sy < sy_end
        y = screen_y + sy
        row_offset = y * width
        tile_y = sy >> 3
        row = sy & 7
        tile_y = v_cells - 1 - tile_y if v_flip
        row = 7 - row if v_flip

        sx = sx_start
        while sx < sx_end
          x = screen_x + sx
          tile_x = sx >> 3
          col = sx & 7
          tile_x = h_cells - 1 - tile_x if h_flip
          col = 7 - col if h_flip
          tile = pattern + tile_x * v_cells + tile_y
          key = (tile << 3) | row
          packed = pattern_cache[key]
          unless packed
            tile_address = (tile * 32 + row * 4) & 0xFFFF
            packed = ((vram[tile_address] || 0) << 24) |
                     ((vram[(tile_address + 1) & 0xFFFF] || 0) << 16) |
                     ((vram[(tile_address + 2) & 0xFFFF] || 0) << 8) |
                     (vram[(tile_address + 3) & 0xFFFF] || 0)
            pattern_cache[key] = packed
          end
          pixel = (packed >> ((7 - col) * 4)) & 0x0F
          if pixel != 0
            index = row_offset + x
            unless occupied[index] == stamp
              current = framebuffer[index] || 0
              if priority || (current & 0x100).zero?
                framebuffer[index] = (priority ? 0x100 : 0) | palette | pixel
              end
              occupied[index] = stamp
            end
          end
          sx += 1
        end
        sy += 1
      end
    end

    def plane_pixel(plane, source_x, source_y)
      nametable_base = plane == :a ? plane_a_base : plane_b_base

      h_scroll = plane == :a ? @h_scroll_a_cache[source_y] : @h_scroll_b_cache[source_y]
      v_scroll = plane == :a ? @v_scroll_a_cache[source_x / 16] : @v_scroll_b_cache[source_x / 16]
      width_cells, height_cells = @plane_dimensions_cache
      scrolled_y = (source_y + v_scroll) % (height_cells * 8)
      scrolled_x = (source_x - h_scroll) % (width_cells * 8)
      cell_y = scrolled_y / 8
      cell_x = scrolled_x / 8
      entry = read_name_table_word(nametable_base, width_cells, cell_y, cell_x)
      pixel = tile_pixel(entry, scrolled_y & 7, scrolled_x & 7)
      encode_pixel(entry, pixel)
    end

    def window_pixel(source_x, source_y)
      range = @window_range_cache[source_y]
      return nil unless range && source_x >= range[0] && source_x < range[1]

      h_cell = source_x / 8
      v_cell = source_y / 8
      entry = read_name_table_word(window_base, window_width_cells, v_cell, h_cell)
      pixel = tile_pixel(entry, source_y & 7, source_x & 7)
      encode_pixel(entry, pixel)
    end

    def resolve_pixel(sprite, scroll_a, scroll_b)
      sprite_priority = sprite && (sprite & 0x100) != 0
      a_priority = scroll_a && (scroll_a & 0x100) != 0
      b_priority = scroll_b && (scroll_b & 0x100) != 0

      if sprite_priority
        if a_priority || !b_priority
          return sprite if sprite && (sprite & 0x0F) != 0
          return scroll_a if scroll_a && (scroll_a & 0x0F) != 0
          return scroll_b if scroll_b && (scroll_b & 0x0F) != 0
        else
          return sprite if sprite && (sprite & 0x0F) != 0
          return scroll_b if scroll_b && (scroll_b & 0x0F) != 0
          return scroll_a if scroll_a && (scroll_a & 0x0F) != 0
        end
      elsif a_priority
        return scroll_a if scroll_a && (scroll_a & 0x0F) != 0
        if b_priority
          return scroll_b if scroll_b && (scroll_b & 0x0F) != 0
          return sprite if sprite && (sprite & 0x0F) != 0
        else
          return sprite if sprite && (sprite & 0x0F) != 0
          return scroll_b if scroll_b && (scroll_b & 0x0F) != 0
        end
      elsif b_priority
        return scroll_b if scroll_b && (scroll_b & 0x0F) != 0
        return sprite if sprite && (sprite & 0x0F) != 0
        return scroll_a if scroll_a && (scroll_a & 0x0F) != 0
      else
        return sprite if sprite && (sprite & 0x0F) != 0
        return scroll_a if scroll_a && (scroll_a & 0x0F) != 0
        return scroll_b if scroll_b && (scroll_b & 0x0F) != 0
      end

      nil
    end

    def draw_vram_activity_frame
      width = @screen_width
      @vram.each_with_index do |byte, index|
        next if byte.zero?

        pixel = ((index * 37) % @framebuffer.length)
        color = ((byte >> 2) ^ (index >> 5)) & 0x3F
        color = 1 if color.zero?
        @framebuffer[pixel] = color
        @framebuffer[pixel + 1] = color if (pixel % width) < width - 1
        @framebuffer[pixel + width] = color if pixel + width < @framebuffer.length
      end
    end

    def sprite_pixels
      pixel_count = @screen_width * @screen_height
      pixels = @sprite_pixel_cache
      if pixels&.length == pixel_count
        pixels.fill(nil)
      else
        pixels = Array.new(pixel_count)
        @sprite_pixel_cache = pixels
      end
      base = sprite_table_base
      sprite = 0
      80.times do
        address = base + sprite * 8
        y = read_vram_word(address) & 0x03FF
        size_link = read_vram_word(address + 2)
        attr = read_vram_word(address + 4)
        x = read_vram_word(address + 6) & 0x01FF
        h_cells = (((size_link >> 10) & 0x03) + 1)
        v_cells = (((size_link >> 8) & 0x03) + 1)
        link = size_link & 0x7F
        draw_sprite(pixels, x - 0x80, y - 0x80, h_cells, v_cells, attr)
        break if link.zero? || link == sprite

        sprite = link
      end
      pixels
    end

    def draw_sprite(target, screen_x, screen_y, h_cells, v_cells, attr)
      pattern = attr & 0x07FF
      h_flip = (attr & 0x0800) != 0
      v_flip = (attr & 0x1000) != 0
      palette = (attr >> 9) & 0x30
      priority = (attr & 0x8000) != 0

      (v_cells * 8).times do |sy|
        y = screen_y + sy
        next if y.negative? || y >= @screen_height

        tile_y = sy / 8
        row = sy & 7
        tile_y = v_cells - 1 - tile_y if v_flip
        row = 7 - row if v_flip

        (h_cells * 8).times do |sx|
          x = screen_x + sx
          next if x.negative? || x >= @screen_width

          tile_x = sx / 8
          col = sx & 7
          tile_x = h_cells - 1 - tile_x if h_flip
          col = 7 - col if h_flip
          tile = pattern + tile_x * v_cells + tile_y
          pixel = pattern_pixel(tile, row, col)
          next if pixel.zero?

          index = y * @screen_width + x
          target[index] ||= encode_raw_pixel(palette | pixel, priority)
        end
      end
    end

    def tile_pixel(entry, row, column)
      pattern = entry & 0x07FF
      row = 7 - row if (entry & 0x1000) != 0
      column = 7 - column if (entry & 0x0800) != 0
      (pattern_row(pattern, row) >> ((7 - column) * 4)) & 0x0F
    end

    def pattern_pixel(pattern, row, column)
      (pattern_row(pattern, row) >> ((7 - column) * 4)) & 0x0F
    end

    def pattern_row(pattern, row)
      key = (pattern << 3) | row
      cached = @pattern_row_cache[key]
      return cached if cached

      address = (pattern * 32 + row * 4) & 0xFFFF
      b0 = @vram[address] || 0
      b1 = @vram[(address + 1) & 0xFFFF] || 0
      b2 = @vram[(address + 2) & 0xFFFF] || 0
      b3 = @vram[(address + 3) & 0xFFFF] || 0
      @pattern_row_cache[key] =
        ((b0 & 0xFF) << 24) |
        ((b1 & 0xFF) << 16) |
        ((b2 & 0xFF) << 8) |
        (b3 & 0xFF)
    end

    def color_index(cram_index)
      cram_index & 0x3F
    end

    def prepare_render_cache
      width = active_width
      height = active_height
      @source_x_cache = source_cache(@source_x_cache, @screen_width, width)
      @source_y_cache = source_cache(@source_y_cache, @screen_height, height)
      @plane_dimensions_cache = plane_dimensions
      @h_scroll_a_cache = Array.new(height) { |y| h_scroll_value(:a, y) }
      @h_scroll_b_cache = Array.new(height) { |y| h_scroll_value(:b, y) }
      columns = (width + 15) / 16
      @v_scroll_a_cache = Array.new(columns) { |column| v_scroll_value_for_column(:a, column) }
      @v_scroll_b_cache = Array.new(columns) { |column| v_scroll_value_for_column(:b, column) }
      @v_scroll_a_single_cache = single_value(@v_scroll_a_cache)
      @v_scroll_b_single_cache = single_value(@v_scroll_b_cache)
      @window_range_cache = Array.new(height) { |y| window_range(y) }
      @window_enabled_cache = @window_range_cache.any? { |range| range && range[1] > range[0] }
      unless @pattern_row_cache_packed && @pattern_row_cache&.length == 0x800 * 8
        @pattern_row_cache = Array.new(0x800 * 8)
        @pattern_row_cache_packed = true
      end
    end

    def invalidate_pattern_row(address)
      @pattern_row_cache[address >> 2] = nil if @pattern_row_cache
    end

    def single_value(values)
      first = values[0]
      index = 1
      while index < values.length
        return nil if values[index] != first

        index += 1
      end
      first
    end

    def source_cache(cache, output_size, input_size)
      return cache if cache&.length == output_size && cache.instance_variable_get(:@input_size) == input_size

      values = Array.new(output_size) { |index| index * input_size / output_size }
      values.instance_variable_set(:@input_size, input_size)
      values
    end

    def ensure_framebuffer_size
      width = active_width
      height = active_height
      return if @screen_width == width && @screen_height == height && @framebuffer.length == width * height

      @screen_width = width
      @screen_height = height
      @framebuffer = Array.new(width * height, 0)
      @source_x_cache = nil
      @source_y_cache = nil
    end

    def encode_pixel(entry, color_id)
      return nil if color_id.zero?

      encode_raw_pixel(((entry >> 9) & 0x30) | color_id, (entry & 0x8000) != 0)
    end

    def encode_raw_pixel(cram_index, priority)
      (priority ? 0x100 : 0) | (cram_index & 0x3F)
    end

    def encoded_color(pixel)
      pixel & 0x3F
    end

    def pixel_color_id(pixel)
      pixel ? (pixel & 0x0F) : 0
    end

    def pixel_priority(pixel)
      pixel ? (pixel & 0x100) != 0 : false
    end

    def read_name_table_word(base, width_cells, row, column)
      relative = (2 * (row * width_cells + column)) & 0x1FFF
      read_vram_word(base + relative)
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

    def h_scroll_value(plane, source_y)
      hscroll_base = (@registers[13] & 0x3F) << 10
      line = source_y & 0xFF
      offset = case @registers[11] & 0x03
               when 0 then 0
               when 2 then 32 * (line / 8)
               when 3 then 4 * line
               else 4 * (line & 0x07)
               end
      read_vram_word(hscroll_base + offset + (plane == :a ? 0 : 2)) & 0x03FF
    end

    def v_scroll_value(plane, source_x)
      v_scroll_value_for_column(plane, source_x / 16)
    end

    def v_scroll_value_for_column(plane, column)
      if (@registers[11] & 0x04).zero?
        return (@vsram[plane == :a ? 0 : 1] || 0) & 0x03FF
      end

      index = column * 2 + (plane == :a ? 0 : 1)
      (@vsram[index] || 0) & 0x03FF
    end

    def plane_a_base
      (@registers[2] & 0x38) << 10
    end

    def window_base
      base = (@registers[3] & 0x3E) << 10
      active_width == 320 ? (base & 0xF000) : (base & 0xF800)
    end

    def plane_b_base
      (@registers[4] & 0x07) << 13
    end

    def sprite_table_base
      base = (@registers[5] & 0x7F) << 9
      active_width == 320 ? (base & 0xFC00) : base
    end

    def active_width
      ((@registers[12] & 0x81) != 0) ? 320 : 256
    end

    def active_height
      224
    end

    def display_enabled?
      (@registers[1] & 0x40) != 0
    end

    def window_width_cells
      active_width == 320 ? 64 : 32
    end

    def window_range(source_y)
      x = (@registers[17] & 0x1F) * 16
      y = @registers[18] & 0x1F
      in_vertical = if (@registers[18] & 0x80) != 0
                      (source_y / 8) >= y
                    else
                      (source_y / 8) < y
                    end
      return [0, active_width] if in_vertical

      if (@registers[17] & 0x80) != 0
        [x, active_width]
      else
        [0, x]
      end
    end

  end
end
