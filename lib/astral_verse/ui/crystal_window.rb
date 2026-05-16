require 'gosu'

module AstralVerse
  class CrystalWindow < Gosu::Window
    MAGNIFY = 2
    DRAW_WIDTH = VisionSprite::POOL_WIDTH * MAGNIFY
    DRAW_HEIGHT = VisionSprite::POOL_HEIGHT * MAGNIFY
    TOOLBAR_HEIGHT = 32
    STATUS_BAR = 28
    WIDTH = DRAW_WIDTH
    HEIGHT = DRAW_HEIGHT + TOOLBAR_HEIGHT + STATUS_BAR

    TOOLBAR_BUTTONS = [
      { label: "📂 Open",  x: 8,   w: 80, action: :open_relic },
      { label: "▶ Start",  x: 96,  w: 80, action: :start },
      { label: "⏹ Stop",   x: 184, w: 80, action: :stop },
    ].freeze

    def initialize(stone)
      super(WIDTH, HEIGHT, false)
      self.caption = "AstralVerse Scrying Stone - Ruby"
      @stone = stone
      @last_vision = Gosu.milliseconds
      @vision_interval = 1000.0 / 60.0
      @running = false
      @closing = false
      @requesting_pick = false
      @requesting_start = false
      @font = Gosu::Font.new(14, name: "Courier New")
      @font_tool = Gosu::Font.new(13, name: "Courier New")
      @font_small = Gosu::Font.new(11, name: "Courier New")
      @frame_count = 0
      @hover_button = nil
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
          @stone.gaze_frame
          @frame_count += 1
          @last_vision = now
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
      draw_area_top = TOOLBAR_HEIGHT

      # Main framebuffer area
      if @stone.vision_sprite.scrying_pool && !@stone.vision_sprite.scrying_pool.empty? && @stone.instance_variable_get(:@codex_present)
        VisionSprite::POOL_HEIGHT.times do |thread|
          VisionSprite::POOL_WIDTH.times do |rune|
            idx = thread * VisionSprite::POOL_WIDTH + rune
            next if idx >= @stone.vision_sprite.scrying_pool.length
            aura = @stone.vision_sprite.scrying_pool[idx] || 0
            r = ((aura >> 0) & 0x03) * 85
            g = ((aura >> 2) & 0x03) * 85
            b = ((aura >> 4) & 0x03) * 85
            Gosu.draw_rect(rune * MAGNIFY, draw_area_top + thread * MAGNIFY, MAGNIFY, MAGNIFY, Gosu::Color.new(255, r, g, b))
          end
        end
      else
        # No ROM or blank screen
        Gosu.draw_rect(0, draw_area_top, DRAW_WIDTH, DRAW_HEIGHT, Gosu::Color.new(255, 18, 12, 28))

        if !@stone.instance_variable_get(:@codex_present)
          # No ROM armed
          msg = "No relic armed"
          msg_x = DRAW_WIDTH / 2 - @font.text_width(msg) / 2
          msg_y = draw_area_top + DRAW_HEIGHT / 2 - 30
          @font.draw_text(msg, msg_x, msg_y, 10, 1, 1, Gosu::Color.new(255, 180, 150, 220))

          hint = "Click Open to select a ROM"
          hint_x = DRAW_WIDTH / 2 - @font.text_width(hint) / 2
          @font.draw_text(hint, hint_x, msg_y + 26, 10, 1, 1, Gosu::Color.new(255, 120, 100, 160))
        else
          # ROM loaded but framebuffer empty
          msg = "Scrying pool is dark..."
          msg_x = DRAW_WIDTH / 2 - @font.text_width(msg) / 2
          msg_y = draw_area_top + DRAW_HEIGHT / 2 - 20
          @font.draw_text(msg, msg_x, msg_y, 10, 1, 1, Gosu::Color.new(255, 150, 140, 190))
        end
      end

      # Draw toolbar
      draw_toolbar

      # Status bar at bottom
      bar_y = DRAW_HEIGHT + TOOLBAR_HEIGHT
      Gosu.draw_rect(0, bar_y, WIDTH, STATUS_BAR, Gosu::Color.new(255, 22, 16, 38))
      Gosu.draw_rect(0, bar_y, WIDTH, 1, Gosu::Color.new(255, 80, 60, 120))

      # Left: armed ROM info or status
      if @stone.instance_variable_get(:@codex_present)
        armed_name = File.basename(@stone.crystal_vault.relic_path || "unknown")
        armed_name = armed_name[0..20] + "..." if armed_name.length > 23
        status_text = "#{@running ? '▶' : '⏸'} Frame: #{@frame_count} | #{armed_name}"
        status_color = @running ? Gosu::Color.new(255, 100, 255, 100) : Gosu::Color.new(255, 255, 200, 100)
      else
        status_text = "⏹ No relic armed"
        status_color = Gosu::Color.new(255, 255, 100, 100)
      end
      @font_small.draw_text(status_text, 8, bar_y + 7, 10, 1, 1, status_color)

      # Right: controls hint
      hint = "ESC = Exit | Arrows+Z/X = Input"
      hint_w = @font_small.text_width(hint)
      @font_small.draw_text(hint, WIDTH - hint_w - 8, bar_y + 7, 10, 1, 1, Gosu::Color.new(255, 140, 130, 180))
    end

    def draw_toolbar
      # Toolbar background
      Gosu.draw_rect(0, 0, WIDTH, TOOLBAR_HEIGHT, Gosu::Color.new(255, 32, 24, 55))
      Gosu.draw_rect(0, TOOLBAR_HEIGHT - 1, WIDTH, 1, Gosu::Color.new(255, 90, 70, 140))

      # Armed ROM label (right side of toolbar)
      if @stone.instance_variable_get(:@codex_present)
        armed = File.basename(@stone.crystal_vault.relic_path || "unknown")
        armed = armed[0..18] + "..." if armed.length > 21
        label = "💎 Armed: #{armed}"
      else
        label = "💎 Armed: None"
      end
      label_x = WIDTH - @font_tool.text_width(label) - 12
      @font_tool.draw_text(label, label_x, 9, 10, 1, 1, Gosu::Color.new(255, 180, 150, 100))

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
      case id
      when Gosu::MsLeft
        mx, my = mouse_x, mouse_y
        if my >= 0 && my <= TOOLBAR_HEIGHT
          TOOLBAR_BUTTONS.each do |btn|
            if mx >= btn[:x] && mx <= btn[:x] + btn[:w]
              case btn[:action]
              when :open_relic
                @requesting_pick = true
                @closing = true
                return
              when :start
                toggle_start
                return
              when :stop
                @running = false
                @frame_count = 0
                return
              end
            end
          end
        end
      when Gosu::KB_ESCAPE
        @closing = true
        return
      when Gosu::KB_SPACE
        toggle_start
      when Gosu::KB_R
        @stone.attune
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

    def toggle_start
      if !@stone.instance_variable_get(:@codex_present)
        # Try to load armed ROM
        if AstralVerse::LastRelicCache.last_relic && File.exist?(AstralVerse::LastRelicCache.last_relic)
          begin
            @stone.absorb_codex(AstralVerse::LastRelicCache.last_relic)
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
      end
    end

    def needs_pick?
      @requesting_pick
    end

    def needs_start?
      @requesting_start
    end

    def button_up(id)
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
  end
end
