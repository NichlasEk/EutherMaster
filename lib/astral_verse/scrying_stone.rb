module AstralVerse
  class ScryingStone
    require 'fileutils'
    require 'time'
    require_relative '../sms_emulator'

    attr_reader :gem_heart, :vision_sprite, :crystal_vault, :mystic_touch, :emulator

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
      @vision_count = 0
      @codex_present = false
    end

    def absorb_codex(path)
      @crystal_vault.inscribe_codex_from_path(path)
      @emulator.load_rom(path)
      @codex_present = true
      attune
    end

    def absorb_codex_essence(essence)
      @crystal_vault.inscribe_codex(essence)
      @emulator.load_rom_data(essence)
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
        @vision_sprite.bind_scrying_pool(@emulator.vdp.framebuffer)
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
      require_relative 'ui/crystal_window'
      window = CrystalWindow.new(self)
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
      controller = @emulator.controller
      controller.port_a = @mystic_touch.left_palm
      controller.port_b = @mystic_touch.right_palm
    end
  end
end
