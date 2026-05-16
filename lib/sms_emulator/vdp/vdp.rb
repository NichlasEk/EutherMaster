module SmsEmulator
  class VDP
    SMS_WIDTH = 256
    SMS_HEIGHT = 192
    SMS_HEIGHT_EXTENDED = 224  # Some modes

    # VDP registers
    NUM_REGISTERS = 11

    attr_reader :registers, :vram, :cram, :framebuffer
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
      @write_pending = false
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
      @write_pending = false
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
        @cram[cram_addr] = value
      else
        @vram[@addr_latch || 0] = value
      end

      increment_address
    end

    # CPU I/O port $BF - VDP control port (write)
    # Also used to set VRAM address and register writes
    def write_control(value)
      if @write_pending
        # Second write: upper byte with command
        @code_register = (value >> 6) & 0x03
        addr_high = value & 0x3F
        @addr_latch = (@addr_latch || 0) | (addr_high << 8)

        if @code_register == 0 || @code_register == 1 || @code_register == 2 || @code_register == 3
          # VRAM/CRAM access mode set
        elsif @code_register == 2
          # VDP register write
          reg_num = (value >> 8) & 0x0F
          if reg_num < NUM_REGISTERS
            @registers[reg_num] = @addr_latch & 0xFF
          end
          @addr_latch = 0
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

      # Simple placeholder: fill with background color
      bg_color = @cram[0] || 0
      SMS_WIDTH.times do |x|
        @framebuffer[scanline * SMS_WIDTH + x] = bg_color
      end

      # TODO: Sprite rendering, tilemap rendering
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
