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
    attr_reader :cpu, :vdp, :memory, :controller, :psg, :frame_count, :perf

    # Master System runs Z80 at ~3.58 MHz, VDP at ~10.7 MHz
    # Frame: 262 scanlines (NTSC), 313 scanlines (PAL)
    CYCLES_PER_FRAME = 59736  # Roughly for NTSC at ~3.58MHz
    CYCLES_PER_SCANLINE = 228

    def initialize
      @vdp = VDP.new
      @controller = Controller.new
      @psg = PSG.new
      @memory = Memory.new(@vdp, @controller, @psg)
      @cpu = Z80.new(@memory)
      @frame_count = 0
      @rom_loaded = false
      reset_perf
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
      @psg.reset
      @frame_count = 0
      reset_perf
    end

    def run_frame
      return unless @rom_loaded

      frame_started = monotonic_time
      cpu_started = frame_started
      cycles_this_frame = 0
      steps_this_frame = 0
      @vdp.begin_frame

      262.times do |scanline|
        target_cycles = (scanline + 1) * CYCLES_PER_SCANLINE

        while cycles_this_frame < target_cycles
          cycles = @cpu.step
          cycles = 4 if cycles <= 0
          cycles_this_frame += cycles
          steps_this_frame += 1

          if @vdp.irq_line && @cpu.iff1
            cycles_this_frame += @cpu.interrupt
          end
        end

        @vdp.step_scanline(scanline, render: false)
      end

      cpu_finished = monotonic_time
      @vdp.render_visible_frame
      vdp_finished = monotonic_time
      @frame_count += 1
      record_perf(cpu_finished - cpu_started, vdp_finished - cpu_finished, vdp_finished - frame_started, steps_this_frame)
    end

    def reset_perf
      @perf = {
        frames: 0,
        cpu_seconds: 0.0,
        vdp_seconds: 0.0,
        frame_seconds: 0.0,
        cpu_steps: 0,
        last_frame_ms: 0.0,
        last_cpu_ms: 0.0,
        last_vdp_ms: 0.0,
        last_cpu_steps: 0
      }
    end

    def perf_summary
      frames = [@perf[:frames], 1].max
      {
        frames: @perf[:frames],
        fps: @perf[:frame_seconds] > 0 ? @perf[:frames] / @perf[:frame_seconds] : 0.0,
        avg_frame_ms: (@perf[:frame_seconds] / frames) * 1000.0,
        avg_cpu_ms: (@perf[:cpu_seconds] / frames) * 1000.0,
        avg_vdp_ms: (@perf[:vdp_seconds] / frames) * 1000.0,
        avg_cpu_steps: @perf[:cpu_steps] / frames.to_f,
        last_frame_ms: @perf[:last_frame_ms],
        last_cpu_ms: @perf[:last_cpu_ms],
        last_vdp_ms: @perf[:last_vdp_ms],
        last_cpu_steps: @perf[:last_cpu_steps]
      }
    end

    private

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def record_perf(cpu_seconds, vdp_seconds, frame_seconds, cpu_steps)
      @perf[:frames] += 1
      @perf[:cpu_seconds] += cpu_seconds
      @perf[:vdp_seconds] += vdp_seconds
      @perf[:frame_seconds] += frame_seconds
      @perf[:cpu_steps] += cpu_steps
      @perf[:last_cpu_ms] = cpu_seconds * 1000.0
      @perf[:last_vdp_ms] = vdp_seconds * 1000.0
      @perf[:last_frame_ms] = frame_seconds * 1000.0
      @perf[:last_cpu_steps] = cpu_steps
    end

    def run
      window = EmulatorWindow.new(self)
      window.show
    end
  end
end
