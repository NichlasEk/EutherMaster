module MegaDrive
  class Emulator
    attr_reader :cpu, :bus, :frame_count, :rom_info, :perf, :render_version, :ym2612, :audio, :vdp

    CYCLES_PER_FRAME = 127_800

    def initialize
      build_audio
      build_video
      @bus = M68KBus.new(psg: @sms_psg, ym2612: @ym2612, vdp: @vdp)
      @cpu = M68K.new(@bus)
      @frame_count = 0
      @rom_loaded = false
      @render_version = 0
      reset_perf
    end

    def load_rom(path, info: nil)
      load_rom_data(File.binread(path).bytes, info: info)
    end

    def load_rom_data(data, info: nil)
      @rom_info = info
      build_audio
      build_video
      @bus = M68KBus.new(psg: @sms_psg, ym2612: @ym2612, vdp: @vdp)
      @bus.load(0, normalized_rom_bytes(data, info))
      @cpu = M68K.new(@bus)
      @rom_loaded = true
      @render_version += 1
      reset
    end

    def reset
      @sms_psg.reset
      @ym2612.reset
      @vdp.reset
      @cpu.reset if @rom_loaded
      @frame_count = 0
      reset_perf
    end

    def run_frame
      return unless @rom_loaded

      started = monotonic_time
      cycles = 0
      steps = 0
      @audio.begin_frame
      @vdp.request_vblank!
      while cycles < CYCLES_PER_FRAME
        begin
          step_cycles = @cpu.step
          cycles += step_cycles
          @ym2612.tick(step_cycles)
          steps += 1
        rescue NotImplementedError
          break
        end
      end
      @vdp.render_frame
      @frame_count += 1
      @render_version += 1
      record_perf(monotonic_time - started, steps)
    end

    def framebuffer
      @vdp.framebuffer
    end

    def psg = @audio
    def controller = nil
    def request_pause; end
    def rewire_after_snapshot_load = self

    def reset_perf
      @perf = { frames: 0, cpu_seconds: 0.0, frame_seconds: 0.0, cpu_steps: 0,
                last_frame_ms: 0.0, last_cpu_ms: 0.0, last_vdp_ms: 0.0, last_cpu_steps: 0 }
    end

    def perf_summary
      frames = [@perf[:frames], 1].max
      { frames: @perf[:frames],
        fps: @perf[:frame_seconds].positive? ? @perf[:frames] / @perf[:frame_seconds] : 0.0,
        avg_frame_ms: (@perf[:frame_seconds] / frames) * 1000.0,
        avg_cpu_ms: (@perf[:cpu_seconds] / frames) * 1000.0,
        avg_vdp_ms: 0.0,
        avg_cpu_steps: @perf[:cpu_steps] / frames.to_f,
        last_frame_ms: @perf[:last_frame_ms],
        last_cpu_ms: @perf[:last_cpu_ms],
        last_vdp_ms: 0.0,
        last_cpu_steps: @perf[:last_cpu_steps] }
    end

    private

    def build_audio
      @sms_psg = PSG.new
      @ym2612 = YM2612.new
      @audio = Audio.new(@sms_psg, @ym2612)
    end

    def build_video
      @vdp = VDP.new
    end

    def normalized_rom_bytes(data, info)
      bytes = data.is_a?(String) ? data.bytes : data.dup
      info&.copier_header && bytes.length > 512 ? bytes[512..] : bytes
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def record_perf(seconds, steps)
      @perf[:frames] += 1
      @perf[:cpu_seconds] += seconds
      @perf[:frame_seconds] += seconds
      @perf[:cpu_steps] += steps
      @perf[:last_frame_ms] = seconds * 1000.0
      @perf[:last_cpu_ms] = seconds * 1000.0
      @perf[:last_cpu_steps] = steps
    end
  end
end
