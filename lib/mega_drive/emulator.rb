module MegaDrive
  class Emulator
    attr_reader :cpu, :bus, :z80_cpu, :z80_bus, :frame_count, :rom_info, :perf, :render_version, :ym2612, :audio, :vdp, :controller

    CYCLES_PER_FRAME = 127_800
    M68K_CLOCK = 7_670_454
    Z80_CLOCK = 3_579_545
    AUDIO_CYCLES_PER_FRAME = 59_736
    Z80_BATCH_CYCLES = 32
    MAX_Z80_PENDING_CYCLES = AUDIO_CYCLES_PER_FRAME
    VBLANK_START_CYCLES = (CYCLES_PER_FRAME * MegaDrive::VDP::VBLANK_START_CYCLE).fdiv(AUDIO_CYCLES_PER_FRAME).ceil

    def initialize
      @timing_mode = :auto
      @region_mode = :auto
      build_audio
      build_video
      @controller = Controller.new
      build_buses
      @cpu = M68K.new(@bus)
      @frame_count = 0
      @rom_loaded = false
      @render_version = 0
      @z80_remainder = 0
      @z80_pending = 0
      reset_perf
    end

    def load_rom(path, info: nil)
      load_rom_data(File.binread(path).bytes, info: info)
    end

    def load_rom_data(data, info: nil)
      @rom_info = info
      build_audio
      build_video
      @controller = Controller.new
      build_buses
      @bus.load_rom(normalized_rom_bytes(data, info))
      apply_region_configuration
      @cpu = M68K.new(@bus)
      @rom_loaded = true
      @render_version += 1
      reset
    end

    def reset
      @sms_psg.reset
      @ym2612.reset
      @z80_bus.reset
      @z80_cpu.reset
      @vdp.reset
      @controller.reset
      @cpu.reset if @rom_loaded
      @frame_count = 0
      @z80_remainder = 0
      @z80_pending = 0
      reset_perf
      apply_region_configuration
    end

    def configure_region(timing: :auto, region: :auto)
      @timing_mode = normalize_timing_mode(timing)
      @region_mode = normalize_region_mode(region)
      apply_region_configuration
      self
    end

    def run_frame
      return unless @rom_loaded

      started = monotonic_time
      cycles = 0
      steps = 0
      z80_remainder = @z80_remainder || 0
      z80_pending = @z80_pending || 0
      vblank_requested = false
      @audio.begin_frame
      @bus.begin_frame
      while cycles < CYCLES_PER_FRAME
        begin
          @bus.frame_cycle = cycles * AUDIO_CYCLES_PER_FRAME / CYCLES_PER_FRAME
          @bus.ym_frame_cycle = cycles
          step_cycles = @cpu.step
          cycles += step_cycles
          @ym2612.tick(step_cycles)
          if !vblank_requested && cycles >= VBLANK_START_CYCLES
            @bus.frame_cycle = MegaDrive::VDP::VBLANK_START_CYCLE
            @vdp.request_vblank!
            vblank_requested = true
            cycles = VBLANK_START_CYCLES
          end
          z80_total = step_cycles * Z80_CLOCK + z80_remainder
          z80_cycles = z80_total / M68K_CLOCK
          z80_remainder = z80_total % M68K_CLOCK
          z80_pending = [z80_pending + z80_cycles, MAX_Z80_PENDING_CYCLES].min
          @bus.frame_cycle = cycles * AUDIO_CYCLES_PER_FRAME / CYCLES_PER_FRAME
          @bus.ym_frame_cycle = cycles
          while z80_pending >= Z80_BATCH_CYCLES
            ran = @bus.run_z80_cycles(Z80_BATCH_CYCLES)
            break unless ran.positive?

            z80_pending = [z80_pending - ran, 0].max
          end
          steps += 1
        rescue NotImplementedError
          break
        end
      end
      @bus.frame_cycle = AUDIO_CYCLES_PER_FRAME
      @bus.ym_frame_cycle = CYCLES_PER_FRAME
      @vdp.request_vblank! unless vblank_requested
      if z80_pending.positive?
        ran = @bus.run_z80_cycles(z80_pending)
        z80_pending = [z80_pending - ran, 0].max if ran.positive?
      end
      @z80_remainder = z80_remainder
      @z80_pending = z80_pending
      @z80_cpu.interrupt(0xFF) if @bus.z80_running?
      cpu_finished = monotonic_time
      @vdp.end_vblank!
      @vdp.render_frame
      frame_finished = monotonic_time
      @frame_count += 1
      @render_version += 1
      record_perf(cpu_finished - started, frame_finished - cpu_finished, frame_finished - started, steps)
    end

    def framebuffer
      @vdp.framebuffer
    end

    def psg = @audio
    def request_pause; end

    def rewire_after_snapshot_load
      @audio ||= Audio.new(@sms_psg, @ym2612)
      @z80_bus ||= Z80Bus.new(psg: @sms_psg, ym2612: @ym2612, m68k_bus: @bus)
      @z80_cpu ||= SmsEmulator::Z80.new(@z80_bus)
      @z80_bus.m68k_bus = @bus
      @bus.psg = @sms_psg
      @bus.ym2612 = @ym2612
      @bus.vdp = @vdp
      @bus.controller = @controller
      @bus.z80_bus = @z80_bus
      @bus.z80_cpu = @z80_cpu
      @vdp.bus = @bus
      apply_region_configuration
      self
    end

    def reset_perf
      @perf = { frames: 0, cpu_seconds: 0.0, vdp_seconds: 0.0, frame_seconds: 0.0, cpu_steps: 0,
                last_frame_ms: 0.0, last_cpu_ms: 0.0, last_vdp_ms: 0.0, last_cpu_steps: 0 }
    end

    def perf_summary
      @perf[:vdp_seconds] ||= 0.0
      @perf[:last_vdp_ms] ||= 0.0
      frames = [@perf[:frames], 1].max
      { frames: @perf[:frames],
        fps: @perf[:frame_seconds].positive? ? @perf[:frames] / @perf[:frame_seconds] : 0.0,
        avg_frame_ms: (@perf[:frame_seconds] / frames) * 1000.0,
        avg_cpu_ms: (@perf[:cpu_seconds] / frames) * 1000.0,
        avg_vdp_ms: (@perf[:vdp_seconds] / frames) * 1000.0,
        avg_cpu_steps: @perf[:cpu_steps] / frames.to_f,
        last_frame_ms: @perf[:last_frame_ms],
        last_cpu_ms: @perf[:last_cpu_ms],
        last_vdp_ms: @perf[:last_vdp_ms],
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

    def build_buses
      @bus = M68KBus.new(psg: @sms_psg, ym2612: @ym2612, vdp: @vdp, controller: @controller)
      @z80_bus = Z80Bus.new(psg: @sms_psg, ym2612: @ym2612, m68k_bus: @bus)
      @z80_cpu = SmsEmulator::Z80.new(@z80_bus)
      @bus.z80_bus = @z80_bus
      @bus.z80_cpu = @z80_cpu
      apply_region_configuration
    end

    def apply_region_configuration
      @bus.version_register = md_version_register if @bus
    end

    def md_version_register
      overseas = case @region_mode
                 when :jp then false
                 else true
                 end
      pal = case @timing_mode
            when :pal then true
            when :ntsc then false
            else @region_mode == :eu
            end
      0x80 | (pal ? 0x40 : 0) | (overseas ? 0x20 : 0)
    end

    def normalize_timing_mode(mode)
      value = mode.to_s.downcase.to_sym
      %i[auto ntsc pal].include?(value) ? value : :auto
    end

    def normalize_region_mode(mode)
      value = mode.to_s.downcase.to_sym
      %i[auto jp us eu].include?(value) ? value : :auto
    end

    def normalized_rom_bytes(data, info)
      bytes = data.is_a?(String) ? data.bytes : data.dup
      info&.copier_header && bytes.length > 512 ? bytes[512..] : bytes
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def record_perf(cpu_seconds, vdp_seconds, frame_seconds, steps)
      @perf[:vdp_seconds] ||= 0.0
      @perf[:frames] += 1
      @perf[:cpu_seconds] += cpu_seconds
      @perf[:vdp_seconds] += vdp_seconds
      @perf[:frame_seconds] += frame_seconds
      @perf[:cpu_steps] += steps
      @perf[:last_frame_ms] = frame_seconds * 1000.0
      @perf[:last_cpu_ms] = cpu_seconds * 1000.0
      @perf[:last_vdp_ms] = vdp_seconds * 1000.0
      @perf[:last_cpu_steps] = steps
    end
  end
end
