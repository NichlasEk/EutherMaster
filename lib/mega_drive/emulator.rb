module MegaDrive
  class Emulator
    attr_reader :cpu, :bus, :z80_cpu, :z80_bus, :frame_count, :rom_info, :perf, :render_version, :ym2612, :audio, :vdp, :controller, :controller_b

    LINES_PER_FRAME = 262
    PAL_LINES_PER_FRAME = 313
    VBLANK_LINE = 224
    LINE_M68K_CYCLES = 488
    LINE_Z80_CYCLES = 228
    CYCLES_PER_FRAME = LINE_M68K_CYCLES * LINES_PER_FRAME
    M68K_CLOCK = 7_670_454
    Z80_CLOCK = 3_579_545
    AUDIO_CYCLES_PER_FRAME = Z80_CLOCK / 60.0
    Z80_BATCH_CYCLES = 32
    MAX_Z80_PENDING_CYCLES = AUDIO_CYCLES_PER_FRAME

    def initialize
      @timing_mode = :auto
      @region_mode = :auto
      @detected_timing_mode = nil
      @detected_region_mode = nil
      build_audio
      build_video
      @controller = Controller.new
      @controller_b = Controller.new
      build_buses
      @cpu = M68K.new(@bus)
      @frame_count = 0
      @rom_loaded = false
      @render_version = 0
      @z80_remainder = 0
      @z80_pending = 0
      @z80_irq_asserted = false
      reset_perf
    end

    def load_rom(path, info: nil)
      load_rom_data(File.binread(path).bytes, info: info, path: path)
    end

    def load_rom_data(data, info: nil, path: nil)
      @bus&.flush_sram
      @rom_info = info
      rom_bytes = normalized_rom_bytes(data, info)
      @detected_region_mode, @detected_timing_mode = detect_header_region_modes(rom_bytes, nil)
      build_audio
      build_video
      @controller = Controller.new
      @controller_b = Controller.new
      build_buses
      @bus.load_rom(rom_bytes)
      @bus.configure_cartridge_override(rom_bytes, rom_path: path || info&.path)
      @audio.paprium_audio = @bus.cartridge_override
      @bus.configure_sram(rom_bytes, rom_path: path || info&.path)
      apply_region_configuration
      @cpu = M68K.new(@bus)
      @rom_loaded = true
      @render_version += 1
      reset
    end

    def reset
      @bus.flush_sram
      @sms_psg.reset
      @ym2612.reset
      @bus.reset_cartridge_override
      @audio.paprium_audio = @bus.cartridge_override
      @z80_bus.reset
      @z80_cpu.reset
      @vdp.reset
      @controller.reset
      @controller_b.reset
      @cpu.reset if @rom_loaded
      @frame_count = 0
      @z80_remainder = 0
      @z80_pending = 0
      @z80_irq_asserted = false
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
      z80_pending = @z80_pending || 0
      z80_clock = 0.0
      vblank_requested = false
      next_line = 1
      lines_per_frame = current_lines_per_frame
      cycles_per_frame = current_m68k_frame_cycles
      line_z80_cycles = current_z80_line_cycles
      audio_cycles_per_frame = current_z80_frame_cycles
      @audio.begin_frame
      @bus.begin_frame
      @vdp.begin_frame_snapshots if @vdp.respond_to?(:begin_frame_snapshots)
      @vdp.capture_line(0) if @vdp.respond_to?(:capture_line)
      while cycles < cycles_per_frame
        begin
          current_line = [cycles / LINE_M68K_CYCLES, lines_per_frame - 1].min
          @bus.frame_cycle = current_line * line_z80_cycles
          @bus.ym_frame_cycle = cycles
          step_cycles = @cpu.step
          cycles += step_cycles
          z80_clock = cycles * M68KBus::M68K_TO_Z80_CYCLE_RATIO
          z80_pending += step_cycles * M68KBus::M68K_TO_Z80_CYCLE_RATIO
          @bus.frame_cycle = z80_clock
          @bus.ym_frame_cycle = cycles
          z80_pending = drain_z80_pending(z80_pending)
          if @vdp.memory_to_vram_dma_active?
            dma_wait_cycles = @vdp.drain_memory_to_vram_dma
            cycles += dma_wait_cycles
            z80_pending += dma_wait_cycles * M68KBus::M68K_TO_Z80_CYCLE_RATIO
            z80_clock = cycles * M68KBus::M68K_TO_Z80_CYCLE_RATIO
            @bus.frame_cycle = z80_clock
            @bus.ym_frame_cycle = cycles
          end
          steps += 1
        rescue NotImplementedError
          break
        end

        while next_line <= lines_per_frame && cycles >= next_line * LINE_M68K_CYCLES
          @vdp.tick_line_interrupt(next_line - 1) if @vdp.respond_to?(:tick_line_interrupt)
          line_m68k_cycle = next_line * LINE_M68K_CYCLES
          if !vblank_requested && next_line >= VBLANK_LINE
            @bus.frame_cycle = next_line * line_z80_cycles
            @bus.ym_frame_cycle = line_m68k_cycle
            @vdp.request_vblank!
            vblank_requested = true
          end

          @bus.frame_cycle = next_line * line_z80_cycles
          @bus.ym_frame_cycle = line_m68k_cycle
          @vdp.capture_line(next_line) if @vdp.respond_to?(:capture_line)
          next_line += 1
        end
      end

      while next_line <= lines_per_frame
        @vdp.tick_line_interrupt(next_line - 1) if @vdp.respond_to?(:tick_line_interrupt)
        line_m68k_cycle = next_line * LINE_M68K_CYCLES
        if !vblank_requested && next_line >= VBLANK_LINE
          @bus.frame_cycle = next_line * line_z80_cycles
          @bus.ym_frame_cycle = line_m68k_cycle
          @vdp.request_vblank!
          vblank_requested = true
        end
        @bus.frame_cycle = next_line * line_z80_cycles
        @bus.ym_frame_cycle = line_m68k_cycle
        @vdp.capture_line(next_line) if @vdp.respond_to?(:capture_line)
        next_line += 1
      end
      @bus.frame_cycle = audio_cycles_per_frame
      @bus.ym_frame_cycle = cycles_per_frame
      @vdp.request_vblank! unless vblank_requested
      remaining_z80 = audio_cycles_per_frame - z80_clock
      z80_pending += remaining_z80 if remaining_z80.positive?
      if z80_pending.positive?
        z80_pending = drain_z80_pending(z80_pending, allow_partial: true)
      end
      @z80_remainder = 0
      @z80_pending = z80_pending
      @z80_irq_asserted = true
      cpu_finished = monotonic_time
      @vdp.end_vblank!
      @vdp.render_frame
      recover_sonic2_interlace_wait!
      frame_finished = monotonic_time
      @frame_count += 1
      @render_version += 1
      @bus.flush_sram
      record_perf(cpu_finished - started, frame_finished - cpu_finished, frame_finished - started, steps)
    end

    def framebuffer
      @vdp.framebuffer
    end

    def psg = @audio
    def request_pause; end

    def frame_rate
      effective_timing_mode == :pal ? 50.0 : 60.0
    end

    def frame_cycles
      current_z80_frame_cycles
    end

    def audio_frame_cycles
      current_z80_frame_cycles
    end

    def drain_z80_pending(pending, allow_partial: false)
      return 0 unless @bus.z80_running?

      target_frame_cycle = @bus.frame_cycle.to_f
      target_ym_cycle = @bus.ym_frame_cycle.to_f
      pending -= service_z80_interrupt if @z80_irq_asserted
      while pending >= Z80_BATCH_CYCLES || (allow_partial && pending.positive?)
        cycles = pending >= Z80_BATCH_CYCLES ? Z80_BATCH_CYCLES : pending
        @bus.frame_cycle = target_frame_cycle - pending
        @bus.ym_frame_cycle = target_ym_cycle - (pending * M68KBus::Z80_TO_M68K_CYCLE_RATIO)
        ran = @bus.run_z80_cycles(cycles)
        break unless ran.positive?

        pending -= ran
      end
      @bus.frame_cycle = target_frame_cycle
      @bus.ym_frame_cycle = target_ym_cycle
      pending
    end

    def service_z80_interrupt
      cycles = @z80_cpu.interrupt(0xFF)
      @z80_irq_asserted = false if cycles.positive?
      cycles
    end

    def rewire_after_snapshot_load
      @z80_irq_asserted = false if @z80_irq_asserted.nil?
      @audio ||= Audio.new(@sms_psg, @ym2612)
      @z80_bus ||= Z80Bus.new(psg: @sms_psg, ym2612: @ym2612, m68k_bus: @bus)
      @z80_cpu ||= SmsEmulator::Z80.new(@z80_bus)
      @z80_bus.m68k_bus = @bus
      @bus.psg = @sms_psg
      @bus.ym2612 = @ym2612
      @bus.vdp = @vdp
      @bus.controller = @controller
      @controller_b ||= Controller.new
      @bus.controller_b = @controller_b
      @bus.z80_bus = @z80_bus
      @bus.z80_cpu = @z80_cpu
      @bus.reset_cartridge_override if @bus.respond_to?(:reset_cartridge_override)
      @audio.paprium_audio = @bus.cartridge_override if @audio.respond_to?(:paprium_audio=)
      @vdp.bus = @bus
      @vdp.after_snapshot_load if @vdp.respond_to?(:after_snapshot_load)
      recover_sonic2_interlace_wait!
      apply_region_configuration
      self
    end

    def reset_perf
      @perf = { frames: 0, cpu_seconds: 0.0, vdp_seconds: 0.0, frame_seconds: 0.0, cpu_steps: 0,
                last_frame_ms: 0.0, last_cpu_ms: 0.0, last_vdp_ms: 0.0, last_cpu_steps: 0 }
    end

    def recover_sonic2_interlace_wait!
      return unless sonic2_rom?
      return unless @vdp.respond_to?(:send) && @vdp.send(:interlace_mode_2?)

      pc = @cpu.pc & 0x00FF_FFFF
      return unless pc == 0x016A04 || pc == 0x016A08
      return if @bus.read_word(0x00FF_F644).zero?

      @bus.write_word(0x00FF_F644, 0)
    end

    def sonic2_rom?
      name = @rom_info&.respond_to?(:name) ? @rom_info.name.to_s.downcase : ''
      path = @rom_info&.respond_to?(:path) ? @rom_info.path.to_s.downcase : ''
      identity = "#{name} #{path}"
      identity.include?('sonic2') || identity.include?('sonic 2') || identity.include?('sonic the hedgehog 2')
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
      @bus = M68KBus.new(psg: @sms_psg, ym2612: @ym2612, vdp: @vdp, controller: @controller, controller_b: @controller_b)
      @z80_bus = Z80Bus.new(psg: @sms_psg, ym2612: @ym2612, m68k_bus: @bus)
      @z80_cpu = SmsEmulator::Z80.new(@z80_bus)
      @bus.z80_bus = @z80_bus
      @bus.z80_cpu = @z80_cpu
      apply_region_configuration
    end

    def apply_region_configuration
      @bus.version_register = md_version_register if @bus
      if @audio
        @audio.frame_cycles = audio_frame_cycles
        @audio.ym_frame_cycles = current_m68k_frame_cycles
      end
    end

    def md_version_register
      overseas = case effective_region_mode
                 when :jp then false
                 else true
                 end
      pal = effective_timing_mode == :pal
      0x80 | (pal ? 0x40 : 0) | (overseas ? 0x20 : 0)
    end

    def effective_timing_mode
      @timing_mode == :auto ? (@detected_timing_mode || :ntsc) : @timing_mode
    end

    def effective_region_mode
      @region_mode == :auto ? (@detected_region_mode || :us) : @region_mode
    end

    def current_lines_per_frame
      effective_timing_mode == :pal ? PAL_LINES_PER_FRAME : LINES_PER_FRAME
    end

    def current_z80_frame_cycles
      Z80_CLOCK / frame_rate
    end

    def current_z80_line_cycles
      current_z80_frame_cycles / current_lines_per_frame
    end

    def current_m68k_frame_cycles
      LINE_M68K_CYCLES * current_lines_per_frame
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
      return deinterleave_smd_bytes(bytes) if info&.smd_interleaved

      info&.copier_header && bytes.length > 512 ? bytes[512..] : bytes
    end

    def deinterleave_smd_bytes(bytes)
      body = bytes[512..] || []
      out = []
      body.each_slice(0x4000) do |block|
        half = block.length / 2
        half.times do |index|
          out << block[half + index].to_i
          out << block[index].to_i
        end
      end
      out
    end

    def detect_header_region_modes(data, info)
      bytes = data.is_a?(String) ? data.bytes : data
      header_offset = info&.header_offset || mega_drive_header_offset(bytes)
      return [nil, nil] unless header_offset

      field = bytes[header_offset + 0xF0, 3]
      return [nil, nil] unless field && field.any?

      chars = field.map { |byte| byte.to_i.chr.upcase }
      old_jp = chars.include?('J')
      old_us = chars.include?('U')
      old_eu = chars.include?('E')
      if old_jp || old_us || old_eu
        return [:us, :ntsc] if old_us
        return [:jp, :ntsc] if old_jp
        return [:eu, :pal]
      end

      first = chars.first
      return [nil, nil] unless first&.match?(/\A[0-9A-F]\z/)

      value = first.to_i(16)
      return [:us, :ntsc] if (value & 0x04) != 0
      return [:jp, :ntsc] if (value & 0x01) != 0
      return [:eu, :pal] if (value & 0x08) != 0
      return [:jp, :pal] if (value & 0x02) != 0

      [nil, nil]
    end

    def mega_drive_header_offset(bytes)
      return 0x100 if bytes.length >= 0x104 && bytes[0x100, 4].pack('C*') == 'SEGA'
      return 0x300 if bytes.length >= 0x304 && bytes[0x300, 4].pack('C*') == 'SEGA'

      nil
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
