require 'gosu'

module SmsEmulator
  class EmulatorWindow < Gosu::Window
    SCALE = 2
    WIDTH = VDP::SMS_WIDTH * SCALE
    HEIGHT = VDP::SMS_HEIGHT * SCALE

    def initialize(emulator)
      super(WIDTH, HEIGHT, false)
      self.caption = "SMS Emulator - Ruby"
      @emulator = emulator
      @last_update = Gosu.milliseconds
      @frame_time = 1000.0 / 60.0
      @pixel_buffer = nil
      @running = true
    end

    def update
      now = Gosu.milliseconds
      delta = now - @last_update

      if delta >= @frame_time && @running
        @emulator.run_frame
        @last_update = now
      end
    end

    def draw
      return unless @emulator.vdp.framebuffer

      unless @pixel_buffer
        @pixel_buffer = Gosu.record(VDP::SMS_WIDTH, VDP::SMS_HEIGHT) do
          # Will be redrawn dynamically below
        end
      end

      # Draw framebuffer scaled
      VDP::SMS_HEIGHT.times do |y|
        VDP::SMS_WIDTH.times do |x|
          color = @emulator.vdp.framebuffer[y * VDP::SMS_WIDTH + x]
          r = ((color >> 0) & 0x03) * 85
          g = ((color >> 2) & 0x03) * 85
          b = ((color >> 4) & 0x03) * 85
          Gosu.draw_rect(x * SCALE, y * SCALE, SCALE, SCALE, Gosu::Color.new(255, r, g, b))
        end
      end
    end

    def button_down(id)
      case id
      when Gosu::KB_ESCAPE
        close
      when Gosu::KB_SPACE
        @running = !@running
      when Gosu::KB_R
        @emulator.reset
      end

      # Map keyboard to controller
      ctrl = @emulator.controller
      case id
      when Gosu::KB_UP    then ctrl.press(Controller::BUTTON_UP)
      when Gosu::KB_DOWN  then ctrl.press(Controller::BUTTON_DOWN)
      when Gosu::KB_LEFT  then ctrl.press(Controller::BUTTON_LEFT)
      when Gosu::KB_RIGHT then ctrl.press(Controller::BUTTON_RIGHT)
      when Gosu::KB_Z     then ctrl.press(Controller::BUTTON_A)
      when Gosu::KB_X     then ctrl.press(Controller::BUTTON_B)
      end
    end

    def button_up(id)
      ctrl = @emulator.controller
      case id
      when Gosu::KB_UP    then ctrl.release(Controller::BUTTON_UP)
      when Gosu::KB_DOWN  then ctrl.release(Controller::BUTTON_DOWN)
      when Gosu::KB_LEFT  then ctrl.release(Controller::BUTTON_LEFT)
      when Gosu::KB_RIGHT then ctrl.release(Controller::BUTTON_RIGHT)
      when Gosu::KB_Z     then ctrl.release(Controller::BUTTON_A)
      when Gosu::KB_X     then ctrl.release(Controller::BUTTON_B)
      end
    end
  end

  class Emulator
    attr_reader :cpu, :vdp, :memory, :controller

    # Master System runs Z80 at ~3.58 MHz, VDP at ~10.7 MHz
    # Frame: 262 scanlines (NTSC), 313 scanlines (PAL)
    CYCLES_PER_FRAME = 59736  # Roughly for NTSC at ~3.58MHz
    CYCLES_PER_SCANLINE = 228

    def initialize
      @memory = Memory.new
      @cpu = Z80.new(@memory)
      @vdp = VDP.new
      @controller = Controller.new
      @frame_count = 0
      @rom_loaded = false
    end

    def load_rom(path)
      @memory.load_rom_file(path)
      @rom_loaded = true
      reset
    end

    def load_rom_data(data)
      @memory.load_rom(data)
      @rom_loaded = true
      reset
    end

    def reset
      @cpu.reset
      @vdp.reset
      @controller.reset
      @frame_count = 0
    end

    def run_frame
      return unless @rom_loaded

      cycles_this_frame = 0
      scanline = 0

      while cycles_this_frame < CYCLES_PER_FRAME
        cycles = @cpu.step
        cycles_this_frame += cycles

        # Update VDP / scanline timing
        scanline += (cycles / CYCLES_PER_SCANLINE)

        if scanline >= 262
          scanline = 0
          @vdp.irq_line = true
        end

        # Trigger VDP interrupt
        if @vdp.irq_line && @cpu.iff1
          @cpu.interrupt
        end
      end

      @frame_count += 1
    end

    def run
      window = EmulatorWindow.new(self)
      window.show
    end
  end
end
