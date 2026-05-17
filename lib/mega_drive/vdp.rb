module MegaDrive
  class VDP
    SMS_WIDTH = 256
    SMS_HEIGHT = 192
    VRAM_SIZE = 0x1_0000
    CRAM_SIZE = 0x40
    VSRAM_SIZE = 0x40
    NUM_REGISTERS = 0x20

    attr_reader :registers, :vram, :cram, :vsram, :framebuffer, :render_version
    attr_accessor :irq_level

    def initialize
      @registers = Array.new(NUM_REGISTERS, 0)
      @vram = Array.new(VRAM_SIZE, 0)
      @cram = Array.new(CRAM_SIZE, 0)
      @vsram = Array.new(VSRAM_SIZE, 0)
      @framebuffer = Array.new(SMS_WIDTH * SMS_HEIGHT, 0)
      @control_pending = false
      @control_latch = 0
      @address = 0
      @code = 0
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
      @code = 0
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
        @address = (@control_latch & 0x3FFF) | ((value & 0x0003) << 14)
        @code = ((@control_latch >> 14) & 0x03) | ((value >> 2) & 0x3C)
        @control_pending = false
      else
        @control_latch = value
        @address = (@address & 0xC000) | (value & 0x3FFF)
        @code = (@code & 0x3C) | ((value >> 14) & 0x03)
        @control_pending = true
      end
    end

    def render_frame
      draw_activity_frame if @video_dirty
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
      case @code
      when 0x03 then :cram
      when 0x05 then :vsram
      else :vram
      end
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

    def draw_activity_frame
      bg = md_color_to_sms_index(@cram[0] || 0)
      @framebuffer.fill(bg)

      if @cram.all?(&:zero?)
        draw_vram_activity_frame
        @video_dirty = false
        @render_version += 1
        return
      end

      y = 16
      CRAM_SIZE.times do |index|
        color = md_color_to_sms_index(@cram[index] || 0)
        x0 = (index % 16) * 16
        y0 = y + (index / 16) * 16
        12.times do |dy|
          row = (y0 + dy) * SMS_WIDTH + x0
          12.times { |dx| @framebuffer[row + dx] = color }
        end
      end

      @video_dirty = false
      @render_version += 1
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
        index += 1
      end
    end

    def md_color_to_sms_index(value)
      r = value & 0x00E
      g = (value >> 4) & 0x00E
      b = (value >> 8) & 0x00E
      ((r >> 1) | ((g >> 1) << 2) | ((b >> 1) << 4)) & 0x3F
    end
  end
end
