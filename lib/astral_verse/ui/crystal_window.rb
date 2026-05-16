require 'gosu'
require_relative '../audio/psg_player'

module AstralVerse
  class CrystalWindow < Gosu::Window
    MAGNIFY = 3
    DRAW_WIDTH = VisionSprite::POOL_WIDTH * MAGNIFY
    DRAW_HEIGHT = VisionSprite::POOL_HEIGHT * MAGNIFY
    TOOLBAR_HEIGHT = 36
    STATUS_BAR = 28
    MAX_CATCHUP_FRAMES = 4
    WIDTH = DRAW_WIDTH
    HEIGHT = DRAW_HEIGHT + TOOLBAR_HEIGHT + STATUS_BAR

    TOOLBAR_BUTTONS = [
      { label: "Open",  x: 8,   w: 86, action: :open_relic },
      { label: "Start", x: 102, w: 86, action: :start },
      { label: "Stop",  x: 196, w: 86, action: :stop },
      { label: "Save",  x: 290, w: 86, action: :save_state },
      { label: "Load",  x: 384, w: 86, action: :load_state },
      { label: "Full",  x: 478, w: 86, action: :fullscreen },
    ].freeze

    def initialize(stone)
      super(WIDTH, HEIGHT, resizable: true)
      self.caption = "AstralVerse Scrying Stone - Ruby"
      @stone = stone
      @last_vision = Gosu.milliseconds
      @vision_interval = 1000.0 / 60.0
      @running = false
      @closing = false
      @requesting_pick = false
      @requesting_start = false
      @font = Gosu::Font.new(16, name: "Courier New")
      @font_tool = Gosu::Font.new(14, name: "Courier New")
      @font_small = Gosu::Font.new(12, name: "Courier New")
      @frame_count = 0
      @hover_button = nil
      @fullscreen_shortcut_down = false
      @frame_image = nil
      @audio_player = PsgPlayer.new(@stone.emulator.psg)
      @status_flash = nil
      @status_flash_until = 0
      @framebuffer_object_id = nil
      @framebuffer_signature = nil
      @sms_palette_rgba = Array.new(64) do |value|
        r = ((value >> 0) & 0x03) * 85
        g = ((value >> 2) & 0x03) * 85
        b = ((value >> 4) & 0x03) * 85
        [r, g, b, 255].pack('C4')
      end
    end

    def update
      if @closing
        close
        return
      end

      now = Gosu.milliseconds
      delta = now - @last_vision

      if delta >= @vision_interval && @running
        if @stone.instance_variable_get(:@codex_present)
          frames_advanced = 0
          while now - @last_vision >= @vision_interval && frames_advanced < MAX_CATCHUP_FRAMES
            sync_game_input_state
            @stone.gaze_frame
            @audio_player&.update
            @frame_count += 1
            @last_vision += @vision_interval
            frames_advanced += 1
          end
          @last_vision = now if frames_advanced == MAX_CATCHUP_FRAMES && now - @last_vision >= @vision_interval
          refresh_frame_image if frames_advanced.positive?
        else
          # No ROM loaded, auto-stop
          @running = false
        end
      end

      # Track hover for toolbar buttons
      mx, my = mouse_x, mouse_y
      @hover_button = nil
      if my >= 0 && my <= TOOLBAR_HEIGHT
        TOOLBAR_BUTTONS.each do |btn|
          if mx >= btn[:x] && mx <= btn[:x] + btn[:w]
            @hover_button = btn[:action]
            break
          end
        end
      end
    end

    def draw
      viewport = screen_viewport
      Gosu.draw_rect(0, TOOLBAR_HEIGHT, width, content_height, Gosu::Color.new(255, 18, 12, 28))

      # Main framebuffer area
      if @stone.vision_sprite.scrying_pool && !@stone.vision_sprite.scrying_pool.empty? && @stone.instance_variable_get(:@codex_present)
        refresh_frame_image unless @frame_image
        @frame_image&.draw(viewport[:x], viewport[:y], 1, viewport[:scale], viewport[:scale])
      else
        # No ROM or blank screen
        if !@stone.instance_variable_get(:@codex_present)
          if armed_relic_path
            msg = "Armed: #{armed_relic_name(42)}"
            hint = "Click Start to run"
          else
            msg = "No relic armed"
            hint = "Click Open to select a ROM"
          end
          msg_x = width / 2 - @font.text_width(msg) / 2
          msg_y = TOOLBAR_HEIGHT + content_height / 2 - 30
          @font.draw_text(msg, msg_x, msg_y, 10, 1, 1, Gosu::Color.new(255, 180, 150, 220))

          hint_x = width / 2 - @font.text_width(hint) / 2
          @font.draw_text(hint, hint_x, msg_y + 26, 10, 1, 1, Gosu::Color.new(255, 120, 100, 160))
        else
          # ROM loaded but framebuffer empty
          msg = "Scrying pool is dark..."
          msg_x = width / 2 - @font.text_width(msg) / 2
          msg_y = TOOLBAR_HEIGHT + content_height / 2 - 20
          @font.draw_text(msg, msg_x, msg_y, 10, 1, 1, Gosu::Color.new(255, 150, 140, 190))
        end
      end

      # Draw toolbar
      draw_toolbar

      # Status bar at bottom
      bar_y = height - STATUS_BAR
      Gosu.draw_rect(0, bar_y, width, STATUS_BAR, Gosu::Color.new(255, 22, 16, 38))
      Gosu.draw_rect(0, bar_y, width, 1, Gosu::Color.new(255, 80, 60, 120))

      # Left: armed ROM info or status
      if armed_relic_path
        armed_name = armed_relic_name(23)
        status_text = "#{@running ? '▶' : '⏸'} Frame: #{@frame_count} | #{armed_name}"
        status_text = "#{status_text} | #{perf_label}" if @running
        status_color = if @running
          Gosu::Color.new(255, 100, 255, 100)
        elsif @stone.instance_variable_get(:@codex_present)
          Gosu::Color.new(255, 255, 200, 100)
        else
          Gosu::Color.new(255, 190, 170, 130)
        end
      else
        status_text = "⏹ No relic armed"
        status_color = Gosu::Color.new(255, 255, 100, 100)
      end
      @font_small.draw_text(status_text, 8, bar_y + 7, 10, 1, 1, status_color)

      # Right: controls hint
      hint = "ESC = Exit | Arrows+Z/X = Input"
      hint_w = @font_small.text_width(hint)
      @font_small.draw_text(hint, width - hint_w - 8, bar_y + 7, 10, 1, 1, Gosu::Color.new(255, 140, 130, 180))
    end

    def draw_toolbar
      # Toolbar background
      Gosu.draw_rect(0, 0, width, TOOLBAR_HEIGHT, Gosu::Color.new(255, 32, 24, 55))
      Gosu.draw_rect(0, TOOLBAR_HEIGHT - 1, width, 1, Gosu::Color.new(255, 90, 70, 140))

      # Armed ROM label (right side of toolbar)
      if @status_flash && Gosu.milliseconds < @status_flash_until
        label = @status_flash
      elsif armed_relic_path
        label = "💎 Armed: #{armed_relic_name(21)}"
      else
        label = "💎 Armed: None"
      end
      label_width = @font_tool.text_width(label)
      if width - 576 > label_width + 16
        label_x = width - label_width - 12
        @font_tool.draw_text(label, label_x, 9, 10, 1, 1, Gosu::Color.new(255, 180, 150, 100))
      end

      # Buttons
      TOOLBAR_BUTTONS.each do |btn|
        bx = btn[:x]
        by = 4
        bw = btn[:w]
        bh = TOOLBAR_HEIGHT - 8
        is_hover = (@hover_button == btn[:action])

        bg = if is_hover
          Gosu::Color.new(255, 90, 70, 140)
        else
          Gosu::Color.new(255, 50, 40, 85)
        end

        # Button shadow
        Gosu.draw_rect(bx + 1, by + 2, bw, bh, Gosu::Color.new(255, 20, 15, 40))
        # Button face
        Gosu.draw_rect(bx, by, bw, bh, bg)
        # Top highlight
        Gosu.draw_rect(bx, by, bw, 1, Gosu::Color.new(255, 120, 100, 180))
        # Bottom shadow
        Gosu.draw_rect(bx, by + bh - 1, bw, 1, Gosu::Color.new(255, 30, 25, 60))

        text = btn[:label]
        tw = @font_tool.text_width(text)
        @font_tool.draw_text(text, bx + (bw - tw) / 2, by + 7, 10, 1, 1,
          is_hover ? Gosu::Color::WHITE : Gosu::Color.new(255, 220, 210, 255))
      end
    end

    def button_down(id)
      if fullscreen_shortcut?(id)
        unless @fullscreen_shortcut_down
          toggle_fullscreen
          @fullscreen_shortcut_down = true
        end
        return
      end

      case id
      when Gosu::MsLeft
        mx, my = mouse_x, mouse_y
        if my >= 0 && my <= TOOLBAR_HEIGHT
          TOOLBAR_BUTTONS.each do |btn|
            if mx >= btn[:x] && mx <= btn[:x] + btn[:w]
              case btn[:action]
              when :open_relic
                @audio_player&.stop
                @requesting_pick = true
                @closing = true
                return
              when :start
                toggle_start
                return
              when :stop
                @running = false
                @audio_player&.stop
                @frame_count = 0
                return
              when :save_state
                save_state
                return
              when :load_state
                load_state
                return
              when :fullscreen
                toggle_fullscreen
                return
              end
            end
          end
        end
      when Gosu::KB_ESCAPE
        @audio_player&.stop
        @closing = true
        return
      when Gosu::KB_SPACE
        toggle_start
      when Gosu::KB_F5
        save_state
      when Gosu::KB_F9
        load_state
      when Gosu::KB_R
        @stone.attune
        @audio_player&.stop
        @frame_count = 0
      end

      # Game input only processed when running
      return unless @running
      touch = @stone.mystic_touch
      case id
      when Gosu::KB_UP    then touch.invoke(MysticTouch::GESTURE_NORTH)
      when Gosu::KB_DOWN  then touch.invoke(MysticTouch::GESTURE_SOUTH)
      when Gosu::KB_LEFT  then touch.invoke(MysticTouch::GESTURE_WEST)
      when Gosu::KB_RIGHT then touch.invoke(MysticTouch::GESTURE_EAST)
      when Gosu::KB_Z     then touch.invoke(MysticTouch::GESTURE_PRIMUS)
      when Gosu::KB_X     then touch.invoke(MysticTouch::GESTURE_SECUNDUS)
      end
    end

    def toggle_fullscreen
      self.fullscreen = !fullscreen?
    end

    def alt_down?
      button_down?(Gosu::KB_LEFT_ALT) || button_down?(Gosu::KB_RIGHT_ALT)
    end

    def shift_down?
      button_down?(Gosu::KB_LEFT_SHIFT) || button_down?(Gosu::KB_RIGHT_SHIFT)
    end

    def fullscreen_shortcut?(id)
      return true if id == Gosu::KB_F11

      fullscreen_shortcut_key?(id) && alt_down? && shift_down?
    end

    def fullscreen_shortcut_key?(id)
      [Gosu::KB_F11, Gosu::KB_RETURN, Gosu::KB_ENTER].include?(id)
    end

    def content_height
      [height - TOOLBAR_HEIGHT - STATUS_BAR, 1].max
    end

    def screen_viewport
      scale = [width.to_f / VisionSprite::POOL_WIDTH, content_height.to_f / VisionSprite::POOL_HEIGHT].min
      scale = [scale, 0.1].max
      draw_width = VisionSprite::POOL_WIDTH * scale
      draw_height = VisionSprite::POOL_HEIGHT * scale
      {
        x: (width - draw_width) / 2.0,
        y: TOOLBAR_HEIGHT + (content_height - draw_height) / 2.0,
        scale: scale
      }
    end

    def refresh_frame_image
      framebuffer = @stone.vision_sprite.scrying_pool
      return unless framebuffer && framebuffer.length >= VisionSprite::POOL_WIDTH * VisionSprite::POOL_HEIGHT

      signature = [framebuffer.object_id, @stone.emulator.vdp.render_version]
      return if @frame_image && @framebuffer_signature == signature

      rgba = String.new(capacity: VisionSprite::POOL_WIDTH * VisionSprite::POOL_HEIGHT * 4, encoding: Encoding::BINARY)
      framebuffer.each do |value|
        rgba << @sms_palette_rgba[(value || 0) & 0x3F]
      end
      @frame_image = Gosu::Image.from_blob(VisionSprite::POOL_WIDTH, VisionSprite::POOL_HEIGHT, rgba)
      @framebuffer_signature = signature
    end

    def toggle_start
      if !@stone.instance_variable_get(:@codex_present)
        # Try to load armed ROM
        if armed_relic_path
          begin
            @stone.absorb_codex(armed_relic_path)
            @running = true
          rescue => e
            puts "⚠️ Could not load armed relic: #{e.message}"
          end
        else
          @requesting_start = true
          @closing = true
        end
      else
        @running = !@running
        @audio_player&.stop unless @running
      end
    end

    def save_state
      path = @stone.save_snapshot
      flash_status("Saved #{File.basename(path)}")
    rescue => e
      flash_status("Save failed: #{e.message}")
    end

    def load_state
      was_running = @running
      @running = false
      @audio_player&.stop
      path = @stone.load_snapshot
      @audio_player = PsgPlayer.new(@stone.emulator.psg)
      @frame_count = @stone.emulator.frame_count
      @frame_image = nil
      @framebuffer_signature = nil
      refresh_frame_image
      @last_vision = Gosu.milliseconds
      @running = was_running
      flash_status("Loaded #{File.basename(path)}")
    rescue => e
      @running = false
      flash_status("Load failed: #{e.message}")
    end

    def flash_status(message)
      @status_flash = message
      @status_flash_until = Gosu.milliseconds + 2500
      puts message
    end

    def needs_pick?
      @requesting_pick
    end

    def needs_start?
      @requesting_start
    end

    def button_up(id)
      @fullscreen_shortcut_down = false if fullscreen_shortcut_key?(id)

      return unless @running
      touch = @stone.mystic_touch
      case id
      when Gosu::KB_UP    then touch.release(MysticTouch::GESTURE_NORTH)
      when Gosu::KB_DOWN  then touch.release(MysticTouch::GESTURE_SOUTH)
      when Gosu::KB_LEFT  then touch.release(MysticTouch::GESTURE_WEST)
      when Gosu::KB_RIGHT then touch.release(MysticTouch::GESTURE_EAST)
      when Gosu::KB_Z     then touch.release(MysticTouch::GESTURE_PRIMUS)
      when Gosu::KB_X     then touch.release(MysticTouch::GESTURE_SECUNDUS)
      end
    end

    def sync_game_input_state
      touch = @stone.mystic_touch
      touch.left_palm = 0xFF
      touch.right_palm = 0xFF

      touch.invoke(MysticTouch::GESTURE_NORTH) if button_down?(Gosu::KB_UP)
      touch.invoke(MysticTouch::GESTURE_SOUTH) if button_down?(Gosu::KB_DOWN)
      touch.invoke(MysticTouch::GESTURE_WEST) if button_down?(Gosu::KB_LEFT)
      touch.invoke(MysticTouch::GESTURE_EAST) if button_down?(Gosu::KB_RIGHT)

      primary_down = button_down?(Gosu::KB_Z) || button_down?(Gosu::KB_A) ||
        button_down?(Gosu::KB_RETURN) || button_down?(Gosu::KB_ENTER)
      secondary_down = button_down?(Gosu::KB_X) || button_down?(Gosu::KB_S)

      touch.invoke(MysticTouch::GESTURE_PRIMUS) if primary_down
      touch.invoke(MysticTouch::GESTURE_SECUNDUS) if secondary_down
    end

    def armed_relic_path
      loaded_path = @stone.crystal_vault.relic_path
      return loaded_path if loaded_path && File.exist?(loaded_path)

      AstralVerse::LastRelicCache.last_relic
    end

    def armed_relic_name(max_length)
      name = File.basename(armed_relic_path || "unknown")
      name.length > max_length ? "#{name[0...(max_length - 3)]}..." : name
    end

    def perf_label
      perf = @stone.emulator.perf_summary
      "emu %.1f fps cpu %.1fms vdp %.1fms" % [perf[:fps], perf[:avg_cpu_ms], perf[:avg_vdp_ms]]
    end
  end
end
