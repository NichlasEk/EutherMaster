module AstralVerse
  class ScryingStone
    require 'fileutils'
    require 'time'
    require_relative 'rom_detector'
    require_relative '../sms_emulator'
    require_relative '../mega_drive'

    attr_reader :gem_heart, :vision_sprite, :crystal_vault, :mystic_touch, :emulator, :rom_info

    # Master System pulses: GemHeart ~3.58 MHz, VisionSprite ~10.7 MHz
    # One full vision: 262 astral threads (NTSC), 313 (PAL)
    PULSES_PER_VISION = 59736
    PULSES_PER_THREAD = 228
    SNAPSHOT_VERSION = 1

    def initialize
      @crystal_vault = CrystalVault.new
      @gem_heart = GemHeart.new(@crystal_vault)
      @vision_sprite = VisionSprite.new
      @mystic_touch = MysticTouch.new
      @emulator = SmsEmulator::Emulator.new
      @rom_info = nil
      @vision_count = 0
      @codex_present = false
    end

    def absorb_codex(path)
      info = RomDetector.detect_file(path)
      raise "Unsupported ROM type" unless info

      @crystal_vault.inscribe_codex_from_path(path)
      @rom_info = info
      @emulator = build_emulator(info)
      if info.mega_drive?
        @emulator.load_rom(path, info: info)
      else
        @emulator.load_rom(path)
      end
      @codex_present = true
      attune
    end

    def absorb_codex_essence(essence)
      info = RomDetector.detect(essence) ||
        RomDetector::Info.new(system: :sms, format: :sms_family, path: nil, name: nil, header_offset: nil, copier_header: false)

      @crystal_vault.inscribe_codex(essence)
      @rom_info = info
      @emulator = build_emulator(info)
      if info.mega_drive?
        @emulator.load_rom_data(essence, info: info)
      else
        @emulator.load_rom_data(essence)
      end
      @codex_present = true
      attune
    end

    def attune
      @gem_heart.attune
      @vision_sprite.attune
      @mystic_touch.attune
      @emulator.reset if @codex_present
      @vision_count = 0
    end

    def gaze_frame
      return unless @codex_present

      if @emulator
        sync_controller
        @emulator.run_frame
        framebuffer = @emulator.respond_to?(:vdp) ? @emulator.vdp.framebuffer : @emulator.framebuffer
        @vision_sprite.bind_scrying_pool(framebuffer)
        @vision_count += 1
        return
      end

      pulses_this_vision = 0
      thread = 0

      while pulses_this_vision < PULSES_PER_VISION
        pulses = @gem_heart.weave_incantation
        break if pulses <= 0
        pulses_this_vision += pulses

        thread += (pulses / PULSES_PER_THREAD)

        if thread >= 262
          thread = 0
          @vision_sprite.omen_line = true
        end

        if @vision_sprite.omen_line && @gem_heart.ear_open_1
          @gem_heart.divine_whisper
        end
      end

      @vision_count += 1
    end

    def awaken
      require_relative 'ui/sdl_app'
      window = UI::SDLApp.new(self)
      window.show
    end

    def save_snapshot(path = self.class.default_snapshot_path)
      raise "No relic loaded" unless @codex_present

      FileUtils.mkdir_p(File.dirname(path))
      payload = {
        version: SNAPSHOT_VERSION,
        saved_at: Time.now.utc.iso8601,
        relic_path: @crystal_vault.relic_path,
        codex_present: @codex_present,
        rom_info: @rom_info,
        vision_count: @vision_count,
        emulator: @emulator,
        mystic_touch: @mystic_touch,
        scrying_pool: @vision_sprite.scrying_pool.dup
      }
      File.binwrite(path, Marshal.dump(payload))
      path
    end

    def load_snapshot(path = self.class.default_snapshot_path)
      payload = Marshal.load(File.binread(path))
      unless payload.is_a?(Hash) && payload[:version] == SNAPSHOT_VERSION
        raise "Unsupported snapshot format"
      end

      relic_path = payload[:relic_path]
      @crystal_vault.inscribe_codex_from_path(relic_path) if relic_path && File.exist?(relic_path)
      @emulator = payload.fetch(:emulator)
      @emulator.rewire_after_snapshot_load if @emulator.respond_to?(:rewire_after_snapshot_load)
      @rom_info = payload[:rom_info]
      @mystic_touch = payload.fetch(:mystic_touch)
      @codex_present = payload.fetch(:codex_present)
      @vision_count = payload.fetch(:vision_count)
      @vision_sprite.scrying_pool.replace(payload.fetch(:scrying_pool))
      path
    end

    def self.default_snapshot_path
      File.expand_path(File.join('snapshots', 'quick.state'), Dir.pwd)
    end

    def sync_controller
      return unless @emulator.respond_to?(:controller) && @emulator.controller

      controller = @emulator.controller
      controller.port_a = @mystic_touch.left_palm
      controller.port_b = @mystic_touch.right_palm
    end

    def build_emulator(info)
      info.mega_drive? ? MegaDrive::Emulator.new : SmsEmulator::Emulator.new
    end
  end
end
