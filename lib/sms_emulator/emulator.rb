module SmsEmulator
  class Emulator
    attr_reader :cpu, :vdp, :memory, :controller, :psg, :frame_count, :perf
    attr_accessor :fast_idle_enabled

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
      @fast_idle_enabled = false
      @pause_requested = false
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

    def rewire_after_snapshot_load
      @memory.vdp = @vdp
      @memory.controller = @controller
      @memory.psg = @psg
      @cpu.instance_variable_set(:@memory, @memory)
      self
    end

    def reset
      @cpu.reset
      @vdp.reset
      @controller.reset
      @psg.reset
      @pause_requested = false
      @frame_count = 0
      reset_perf
    end

    def request_pause
      @pause_requested = true
    end

    def run_frame
      return unless @rom_loaded

      frame_started = monotonic_time
      cpu_started = frame_started
      cycles_this_frame = 0
      steps_this_frame = 0
      if @pause_requested
        cycles_this_frame += @cpu.nmi
        steps_this_frame += 1
        @pause_requested = false
      end
      @vdp.begin_frame
      @psg.begin_frame

      262.times do |scanline|
        target_cycles = (scanline + 1) * CYCLES_PER_SCANLINE

        if @fast_idle_enabled
          while cycles_this_frame < target_cycles
            if @vdp.irq_line && @cpu.iff1
              cycles_this_frame += @cpu.interrupt
              steps_this_frame += 1
              next
            end

            @memory.io_cycle = cycles_this_frame
            cycles = @cpu.fast_forward_idle_loop(target_cycles - cycles_this_frame)
            cycles = @cpu.run_cycles(target_cycles - cycles_this_frame) if cycles <= 0
            cycles = 4 if cycles <= 0
            cycles_this_frame += cycles
            steps_this_frame += @cpu.last_run_steps || 1

            if @vdp.irq_line && @cpu.iff1
              cycles_this_frame += @cpu.interrupt
            end
          end
        else
          while cycles_this_frame < target_cycles
            if @vdp.irq_line && @cpu.iff1
              cycles_this_frame += @cpu.interrupt
              steps_this_frame += 1
              next
            end

            @memory.io_cycle = cycles_this_frame
            cycles = @cpu.run_cycles(target_cycles - cycles_this_frame)
            cycles = 4 if cycles <= 0
            cycles_this_frame += cycles
            steps_this_frame += @cpu.last_run_steps || 1

            if @vdp.irq_line && @cpu.iff1
              cycles_this_frame += @cpu.interrupt
            end
          end
        end

        @vdp.step_scanline(scanline, render: true)
      end

      cpu_finished = monotonic_time
      @vdp.finish_frame_render
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
      if defined?(Process::CLOCK_MONOTONIC)
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elsif defined?(JS)
        JS.global[:performance].call(:now).to_f / 1000.0
      else
        Time.now.to_f
      end
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
      require_relative '../astral_verse/scrying_stone'
      stone = AstralVerse::ScryingStone.new
      stone.instance_variable_set(:@emulator, self)
      stone.instance_variable_set(:@codex_present, true)
      stone.awaken
    end
  end
end
