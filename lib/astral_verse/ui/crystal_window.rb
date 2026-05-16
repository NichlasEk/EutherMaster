require 'gosu'

module AstralVerse
  class CrystalWindow < Gosu::Window
    MAGNIFY = 2
    DRAW_WIDTH = VisionSprite::POOL_WIDTH * MAGNIFY
    DRAW_HEIGHT = VisionSprite::POOL_HEIGHT * MAGNIFY
    TOOLBAR_HEIGHT = 28
    STATUS_BAR = 24
    WIDTH = DRAW_WIDTH
    HEIGHT = DRAW_HEIGHT + TOOLBAR_HEIGHT + STATUS_BAR

    TOOLBAR_BUTTONS = [
      { label: "📂 Open", x: 8,  w: 80, action: :open_relic },
      { label: "⏯ Pause", x: 96, w: 80, action: :toggle_pause },
      { label: "↻ Reset", x: 184, w: 80, action: :reset },
    ].freeze

    def initialize(stone)
      super(WIDTH, HEIGHT, false)
      self.caption = "AstralVerse Scrying Stone - Ruby"
      @stone = stone
      @last_vision = Gosu.milliseconds
      @vision_interval = 1000.0 / 60.0
      @awake = true
      @closing = false
      @requesting_new_rom = false
      @font = Gosu::Font.new(14, name: "Courier New")
      @font_tool = Gosu::Font.new(12, name: "Courier New")
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

      if delta >= @vision_interval && @awake
        @stone.gaze_frame
        @frame_count += 1
        @last_vision = now
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
      if @stone.vision_sprite.scrying_pool && !@stone.vision_sprite.scrying_pool.empty?
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
        Gosu.draw_rect(0, draw_area_top, DRAW_WIDTH, DRAW_HEIGHT, Gosu::Color.new(255, 20, 10, 30))
        msg = "Scrying pool is dark..."
        msg_x = DRAW_WIDTH / 2 - @font.text_width(msg) / 2
        msg_y = draw_area_top + DRAW_HEIGHT / 2 - 30
        @font.draw_text(msg, msg_x, msg_y, 10, 1, 1, Gosu::Color.new(255, 150, 140, 190))
        sub = "ROM loaded: #{@stone.instance_variable_get(:@codex_present) ? 'Yes' : 'No'}"
        sub_x = DRAW_WIDTH / 2 - @font.text_width(sub) / 2
        @font.draw_text(sub, sub_x, msg_y + 24, 10, 1, 1, Gosu::Color.new(255, 100, 90, 140))
      end

      # Toolbar at top
      Gosu.draw_rect(0, 0, WIDTH, TOOLBAR_HEIGHT, Gosu::Color.new(255, 35, 25, 60))
      Gosu.draw_rect(0, TOOLBAR_HEIGHT, WIDTH, 1, Gosu::Color.new(255, 80, 60, 120))

      TOOLBAR_BUTTONS.each do |btn|
        bx = btn[:x]
        by = 4
        bw = btn[:w]
        bh = TOOLBAR_HEIGHT - 8
        is_hover = (@hover_button == btn[:action])
        is_pause = (btn[:action] == :toggle_pause && !@awake)

        bg = if is_hover || is_pause
          Gosu::Color.new(255, 80, 60, 130)
        else
          Gosu::Color.new(255, 50, 40, 80)
        end

        Gosu.draw_rect(bx, by, bw, bh, bg)
        Gosu.draw_rect(bx, by, bw, 1, Gosu::Color.new(255, 100, 80, 160))
        Gosu.draw_rect(bx, by + bh - 1, bw, 1, Gosu::Color.new(255, 100, 80, 160))

        text = btn[:label].dup
        text.sub!("Pause", "Play") if is_pause && btn[:action] == :toggle_pause
        tw = @font_tool.text_width(text)
        @font_tool.draw_text(text, bx + (bw - tw) / 2, by + 6, 10, 1, 1, Gosu::Color.new(255, 220, 210, 255))
      end

      # Status bar at bottom
      bar_y = DRAW_HEIGHT + TOOLBAR_HEIGHT
      Gosu.draw_rect(0, bar_y, WIDTH, STATUS_BAR, Gosu::Color.new(255, 25, 15, 40))
      Gosu.draw_rect(0, bar_y, WIDTH, 1, Gosu::Color.new(255, 80, 60, 120))

      status = @awake ? "● LIVE" : "○ PAUSED"
      status_color = @awake ? Gosu::Color.new(255, 100, 255, 100) : Gosu::Color.new(255, 255, 200, 100)
      left_text = "#{status} | Frame: #{@frame_count} | PC: 0x%04X | Amber: 0x%02X" % [
        @stone.gem_heart.prophecy_scroll, @stone.gem_heart.amber
      ]
      @font.draw_text(left_text, 8, bar_y + 5, 10, 1, 1, status_color)

      hint = "ESC = Exit | Arrows+Z/X = Input"
      hint_w = @font.text_width(hint)
      @font.draw_text(hint, WIDTH - hint_w - 8, bar_y + 5, 10, 1, 1, Gosu::Color.new(255, 140, 130, 180))
    end

    def button_down(id)
      case id
      when Gosu::MsLeft
        # Check toolbar clicks
        mx, my = mouse_x, mouse_y
        if my >= 0 && my <= TOOLBAR_HEIGHT
          TOOLBAR_BUTTONS.each do |btn|
            if mx >= btn[:x] && mx <= btn[:x] + btn[:w]
              case btn[:action]
              when :open_relic
                open_relic_picker
                return
              when :toggle_pause
                @awake = !@awake
                return
              when :reset
                @stone.attune
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
        @awake = !@awake
      when Gosu::KB_R
        @stone.attune
        @frame_count = 0
      end

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

    def open_relic_picker
      @requesting_new_rom = true
      @closing = true
    end

    def needs_pick?
      @requesting_new_rom
    end

    def button_up(id)
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
