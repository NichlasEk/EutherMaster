require_relative '../sdl3'
require_relative '../audio/psg_player'
require_relative '../last_relic_cache'

module AstralVerse
  module UI
    class SDLApp
      SMS_W = VisionSprite::POOL_WIDTH
      SMS_H = VisionSprite::POOL_HEIGHT
      MAGNIFY = 3
      TOOLBAR_H = 36
      STATUS_H = 28
      WIDTH = SMS_W * MAGNIFY
      HEIGHT = SMS_H * MAGNIFY + TOOLBAR_H + STATUS_H
      FRAME_MS = 1000.0 / 60.0
      MAX_CATCHUP_FRAMES = 4

      ROM_EXTENSIONS = AstralVerse::RomDetector::ROM_EXTENSIONS
      FONT_CANDIDATES = [
        ENV['ASTRAL_FONT'],
        '/usr/share/fonts/noto/NotoSansMono-Regular.ttf',
        '/usr/share/fonts/TTF/DejaVuSansMono.ttf',
        '/usr/share/fonts/dejavu/DejaVuSansMono.ttf'
      ].compact.freeze

      TOOLBAR_BUTTONS = [
        { label: 'Open', x: 4, w: 62, action: :open },
        { label: 'Start', x: 72, w: 62, action: :start },
        { label: 'Stop', x: 140, w: 62, action: :stop },
        { label: 'Save', x: 208, w: 62, action: :save },
        { label: 'Load', x: 276, w: 62, action: :load },
        { label: 'Full', x: 344, w: 62, action: :fullscreen },
        { label: 'Mask', x: 412, w: 74, action: :debug_mask },
        { label: 'Keys', x: 494, w: 60, action: :key_bindings }
      ].freeze
      VOLUME_SLIDER = { x: 560, y: 4, w: 90, h: TOOLBAR_H - 8 }.freeze
      SCANLINE_CONTROL = { x: 656, y: 4, w: 108, h: TOOLBAR_H - 8 }.freeze
      TIMING_SELECT = { x: 770, y: 4, w: 78, h: TOOLBAR_H - 8 }.freeze
      REGION_SELECT = { x: 854, y: 4, w: 78, h: TOOLBAR_H - 8 }.freeze
      TIMING_OPTIONS = [
        [:pal, 'PAL'],
        [:ntsc, 'NTSC'],
        [:auto, 'AUTO']
      ].freeze
      REGION_OPTIONS = [
        [:jp, 'JP'],
        [:us, 'US'],
        [:eu, 'EU'],
        [:auto, 'Auto']
      ].freeze
      INPUT_ACTIONS = [
        { id: :up, label: 'Up', gesture: MysticTouch::GESTURE_NORTH, default: SDL3::K_UP, pad_default: SDL3::GAMEPAD_BUTTON_DPAD_UP },
        { id: :down, label: 'Down', gesture: MysticTouch::GESTURE_SOUTH, default: SDL3::K_DOWN, pad_default: SDL3::GAMEPAD_BUTTON_DPAD_DOWN },
        { id: :left, label: 'Left', gesture: MysticTouch::GESTURE_WEST, default: SDL3::K_LEFT, pad_default: SDL3::GAMEPAD_BUTTON_DPAD_LEFT },
        { id: :right, label: 'Right', gesture: MysticTouch::GESTURE_EAST, default: SDL3::K_RIGHT, pad_default: SDL3::GAMEPAD_BUTTON_DPAD_RIGHT },
        { id: :button_1, label: 'Button 1', gesture: MysticTouch::GESTURE_PRIMUS, default: SDL3::K_Z, pad_default: SDL3::GAMEPAD_BUTTON_SOUTH },
        { id: :button_2, label: 'Button 2', gesture: MysticTouch::GESTURE_SECUNDUS, default: SDL3::K_X, pad_default: SDL3::GAMEPAD_BUTTON_EAST },
        { id: :button_3, label: 'Button 3', gesture: MysticTouch::GESTURE_TERTIUS, default: SDL3::K_C, pad_default: SDL3::GAMEPAD_BUTTON_WEST },
        { id: :pause, label: 'Pause', gesture: MysticTouch::GESTURE_START, special: :pause, default: SDL3::K_P, pad_default: SDL3::GAMEPAD_BUTTON_START },
        { id: :reset, label: 'Reset', special: :reset, default: SDL3::K_R, pad_default: SDL3::GAMEPAD_BUTTON_BACK }
      ].freeze
      INPUT_ACTION_BY_ID = INPUT_ACTIONS.each_with_object({}) { |action, map| map[action[:id]] = action }.freeze
      INPUT_KEY_ALIASES = INPUT_ACTIONS.each_with_object({}) do |action, aliases|
        keys = [action[:default]]
        keys << SDL3::K_RETURN if action[:id] == :pause
        aliases[action[:id]] = keys.compact.uniq
      end.freeze

      COLORS = {
        bg: [18, 12, 28, 255],
        panel: [22, 16, 40, 255],
        toolbar: [32, 24, 55, 255],
        button: [50, 40, 85, 255],
        hover: [90, 70, 140, 255],
        border: [90, 70, 140, 255],
        text: [220, 210, 255, 255],
        dim: [170, 160, 205, 255],
        good: [100, 255, 100, 255],
        warn: [255, 200, 100, 255],
        rom: [120, 255, 120, 255],
        folder: [255, 220, 120, 255]
      }.freeze

      attr_reader :selected_path

      def initialize(stone)
        @stone = stone
        @running = false
        @closing = false
        @mode = :game
        @keys = {}
        @input_dirty = true
        @input_port_a = 0xFF
        @key_bindings = load_key_bindings
        @controller_bindings = load_controller_bindings
        rebuild_key_lookup
        rebuild_controller_lookup
        @pad_buttons = {}
        @gamepads = {}
        @keybindings_open = false
        @binding_capture = nil
        @frame_count = 0
        @last_vision = now_ms
        @next_draw = 0.0
        @status_label_cache = nil
        @status_label_until = 0.0
        @frame_rgba = String.new(capacity: SMS_W * SMS_H * 4, encoding: Encoding::BINARY)
        @palette_rgba = Array.new(64) do |value|
          [((value >> 0) & 0x03) * 85, ((value >> 2) & 0x03) * 85, ((value >> 4) & 0x03) * 85, 255].pack('C4')
        end
        @sharp_palette_rgba = Array.new(64) do |value|
          r = sharp_channel(((value >> 0) & 0x03) * 85)
          g = sharp_channel(((value >> 2) & 0x03) * 85)
          b = sharp_channel(((value >> 4) & 0x03) * 85)
          [r, g, b, 255].pack('C4')
        end
        @audio_player = nil
        @volume = ENV.fetch('ASTRAL_VOLUME', LastRelicCache.volume.to_s).to_f.clamp(0.0, 1.0)
        @dragging_volume = false
        @scanlines = LastRelicCache.scanlines?
        @scanline_strength = LastRelicCache.scanline_strength
        @dragging_scanline_strength = false
        @sharp_pixels = LastRelicCache.sharp_pixels?
        @autostart = LastRelicCache.autostart?
        @timing_mode = LastRelicCache.timing_mode.to_sym
        @region_mode = LastRelicCache.region_mode.to_sym
        @open_select = nil
        @fullscreen = false
        @debug_mask = LastRelicCache.debug_mask?
        @mouse_visible_until = 0
        @last_mouse = [0.0, 0.0]
        @browser_dir = LastRelicCache.last_dir
        @browser_entries = []
        @browser_selected = 0
        @browser_scroll = 0
        @status_flash = nil
        @status_flash_until = 0
      end

      def show
        init_sdl
        @audio_player = build_audio_player
        open_window
        open_existing_gamepads
        autostart_loaded_relic
        loop_once while !@closing
      ensure
        @audio_player&.stop
        LastRelicCache.save_volume(@volume)
        close_window
        SDL3TTF.quit if @ttf_ready
        SDL3.quit if @sdl_ready
      end

      private

      def init_sdl
        SDL3.check(SDL3.init(SDL3::INIT_VIDEO | SDL3::INIT_AUDIO | SDL3::INIT_EVENTS | SDL3::INIT_GAMEPAD), 'SDL_Init')
        @sdl_ready = true
        SDL3.check(SDL3TTF.init, 'TTF_Init')
        @ttf_ready = true
        @font_path = FONT_CANDIDATES.find { |path| File.file?(path) }
        raise 'No usable TTF font found' unless @font_path
        @fonts = {}
        @text_cache = {}
      end

      def open_window
        flags = SDL3::WINDOW_RESIZABLE | SDL3::WINDOW_HIGH_PIXEL_DENSITY
        @window = SDL3.check(SDL3.create_window('AstralVerse SDL3', WIDTH, HEIGHT, flags), 'SDL_CreateWindow')
        @renderer = SDL3.check(SDL3.create_renderer(@window, nil), 'SDL_CreateRenderer')
        SDL3.set_render_vsync(@renderer, SDL3::RENDERER_VSYNC_DISABLED)
        SDL3.set_render_draw_blend_mode(@renderer, SDL3::BLENDMODE_BLEND)
        @screen_texture = SDL3.check(SDL3.create_texture(@renderer, SDL3::PIXELFORMAT_RGBA32,
          SDL3::TEXTUREACCESS_STREAMING, SMS_W, SMS_H), 'SDL_CreateTexture')
        @screen_texture_width = SMS_W
        @screen_texture_height = SMS_H
        SDL3.set_texture_scale_mode(@screen_texture, SDL3::SCALEMODE_NEAREST)
        @event = FFI::MemoryPointer.new(:uint8, 128)
        @size_w_ptr = FFI::MemoryPointer.new(:int)
        @size_h_ptr = FFI::MemoryPointer.new(:int)
        @rect = SDL3::FRect.new
        @frame_pixels = FFI::MemoryPointer.new(:uint8, SMS_W * SMS_H * 4)
        @text_size_w = FFI::MemoryPointer.new(:int)
        @text_size_h = FFI::MemoryPointer.new(:int)
        @text_size_cache = {}
        @render_width = WIDTH
        @render_height = HEIGHT
        @last_uploaded_render_version = nil
        refresh_output_size
      end

      def close_window
        close_gamepads
        @text_cache&.each_value { |texture| SDL3.destroy_texture(texture[:ptr]) }
        @fonts&.each_value { |font| SDL3TTF.close_font(font) }
        SDL3.destroy_texture(@screen_texture) if @screen_texture && !@screen_texture.null?
        SDL3.destroy_renderer(@renderer) if @renderer && !@renderer.null?
        SDL3.destroy_window(@window) if @window && !@window.null?
      end

      def loop_once
        poll_events
        update_game if @mode == :game
        now = now_ms
        if now >= @next_draw
          draw
          @next_draw = now + FRAME_MS
        end
        sleep_ms = [[@next_draw - now, 1.0].min, 0.0].max
        SDL3.delay(sleep_ms.ceil)
      end

      def poll_events
        while SDL3.poll_event(@event)
          type = @event.read_uint32
          case type
          when SDL3::EVENT_QUIT
            @closing = true
          when SDL3::EVENT_KEY_DOWN
            handle_key(@event.get_uint32(28), true, @event.get_uint8(37) != 0)
          when SDL3::EVENT_KEY_UP
            handle_key(@event.get_uint32(28), false, false)
          when SDL3::EVENT_MOUSE_BUTTON_DOWN
            handle_click(@event.get_uint8(24), @event.get_float32(28), @event.get_float32(32))
          when SDL3::EVENT_MOUSE_BUTTON_UP
            if @event.get_uint8(24) == SDL3::BUTTON_LEFT
              if @dragging_volume
                @dragging_volume = false
                LastRelicCache.save_volume(@volume)
              end
              if @dragging_scanline_strength
                @dragging_scanline_strength = false
                LastRelicCache.save_scanline_strength(@scanline_strength)
              end
            end
          when SDL3::EVENT_MOUSE_MOTION
            handle_mouse_motion(@event.get_float32(28), @event.get_float32(32))
          when SDL3::EVENT_MOUSE_WHEEL
            handle_wheel(@event.get_float32(28))
          when SDL3::EVENT_GAMEPAD_BUTTON_DOWN
            handle_gamepad_button(@event.get_uint8(20), true)
          when SDL3::EVENT_GAMEPAD_BUTTON_UP
            handle_gamepad_button(@event.get_uint8(20), false)
          when SDL3::EVENT_GAMEPAD_ADDED
            open_gamepad(@event.get_uint32(16))
          when SDL3::EVENT_GAMEPAD_REMOVED
            close_gamepad(@event.get_uint32(16))
          end
        end
      end

      def handle_key(key, down, repeat)
        if @binding_capture&.[](:type) == :keyboard
          capture_binding_key(key) if down && !repeat
          return
        end

        previous = @keys[key]
        @keys[key] = down
        @input_dirty = true if previous != down && @key_to_action[key]
        return if repeat && down

        if down
          case key
          when SDL3::K_F11
            toggle_fullscreen
            return
          when SDL3::K_ESCAPE
            if @mode == :browser
              @mode = :game
            elsif @keybindings_open
              @keybindings_open = false
              @binding_capture = nil
            elsif @fullscreen
              toggle_fullscreen
            else
              @closing = true
            end
            return
          end
        end

        @mode == :browser ? handle_browser_key(key, down) : handle_game_key(key, down)
      end

      def handle_gamepad_button(button, down)
        if @binding_capture&.[](:type) == :controller
          capture_controller_button(button) if down
          return
        end

        previous = @pad_buttons[button]
        @pad_buttons[button] = down
        action_id = @controller_to_action[button]
        @input_dirty = true if previous != down && action_id
        return unless down

        case INPUT_ACTION_BY_ID[action_id]&.[](:special)
        when :pause
          @stone.emulator.request_pause
        when :reset
          reset_game
        end
      end

      def handle_game_key(key, down)
        return unless down

        action_id = @key_to_action[key]
        case INPUT_ACTION_BY_ID[action_id]&.[](:special)
        when :pause
          @stone.emulator.request_pause
          return
        when :reset
          reset_game
          return
        end
        return if action_id

        case key
        when SDL3::K_SPACE
          toggle_start
        when SDL3::K_F5
          save_state
        when SDL3::K_F9
          load_state
        end
      end

      def handle_browser_key(key, down)
        return unless down

        case key
        when SDL3::K_UP
          move_browser(-1)
        when SDL3::K_DOWN
          move_browser(1)
        when SDL3::K_LEFT
          navigate_browser(File.dirname(@browser_dir))
        when SDL3::K_RETURN, SDL3::K_SPACE
          activate_browser_entry
        end
      end

      def handle_click(button, x, y)
        return unless button == SDL3::BUTTON_LEFT

        if @mode == :browser
          click_browser(x, y)
        elsif @keybindings_open
          click_keybindings(x, y)
        elsif !@fullscreen
          return if click_select_option(x, y)

          if @open_select && y > TOOLBAR_H
            @open_select = nil
            return
          end

          return unless y <= TOOLBAR_H

          if volume_slider_hit?(x, y)
            @dragging_volume = true
            set_volume_from_x(x)
            return
          end
          if scanline_checkbox_hit?(x, y)
            @scanlines = !@scanlines
            LastRelicCache.save_scanlines(@scanlines)
            return
          end
          if sharp_pixels_hit?(x, y)
            @sharp_pixels = !@sharp_pixels
            @last_uploaded_render_version = nil
            LastRelicCache.save_sharp_pixels(@sharp_pixels)
            return
          end
          if scanline_slider_hit?(x, y)
            @dragging_scanline_strength = true
            set_scanline_strength_from_x(x)
            return
          end
          if select_hit?(TIMING_SELECT, x, y)
            @open_select = @open_select == :timing ? nil : :timing
            return
          end
          if select_hit?(REGION_SELECT, x, y)
            @open_select = @open_select == :region ? nil : :region
            return
          end

          TOOLBAR_BUTTONS.each do |btn|
            next unless x >= btn[:x] && x <= btn[:x] + btn[:w]

            handle_toolbar(btn[:action])
            break
          end
        end
      end

      def handle_mouse_motion(x, y)
        if @dragging_volume
          @last_mouse = [x, y]
          set_volume_from_x(x)
          return
        end
        if @dragging_scanline_strength
          @last_mouse = [x, y]
          set_scanline_strength_from_x(x)
          return
        end

        previous_mouse = @last_mouse
        @last_mouse = [x, y]
        return unless @fullscreen

        return if previous_mouse == [x, y]

        @mouse_visible_until = now_ms + 1400
        SDL3.show_cursor
      end

      def handle_wheel(y)
        return unless @mode == :browser

        move_browser(y.positive? ? -3 : 3)
      end

      def handle_toolbar(action)
        case action
        when :open
          open_browser
        when :start
          toggle_start
        when :stop
          @running = false
          @audio_player&.stop
          @frame_count = 0
        when :save
          save_state
        when :load
          load_state
        when :fullscreen
          toggle_fullscreen
        when :debug_mask
          @debug_mask = !@debug_mask
          LastRelicCache.save_debug_mask(@debug_mask)
        when :key_bindings
          @keybindings_open = !@keybindings_open
          @binding_capture = nil unless @keybindings_open
        end
      end

      def update_game
        now = now_ms
        if @fullscreen && now >= @mouse_visible_until
          SDL3.hide_cursor
        end

        delta = now - @last_vision
        return unless delta >= FRAME_MS && @running

        if @stone.instance_variable_get(:@codex_present)
          frames = 0
          while now - @last_vision >= FRAME_MS && frames < MAX_CATCHUP_FRAMES
            sync_game_input_state
            @stone.gaze_frame
            @audio_player&.update
            @frame_count += 1
            @last_vision += FRAME_MS
            frames += 1
          end
          @last_vision = now if frames == MAX_CATCHUP_FRAMES && now - @last_vision >= FRAME_MS
        else
          @running = false
        end
      end

      def draw
        refresh_output_size
        clear(*COLORS[:bg])
        @mode == :browser ? draw_browser : draw_game
        SDL3.render_present(@renderer)
      end

      def draw_game
        viewport = screen_viewport
        fill_rect(0, content_top, window_width, content_height, @fullscreen ? [0, 0, 0, 255] : COLORS[:bg])
        if @stone.instance_variable_get(:@codex_present) && @stone.vision_sprite.scrying_pool&.any?
          update_screen_texture
          render_texture(@screen_texture, viewport[:x], viewport[:y], viewport[:w], viewport[:h])
          draw_scanlines(viewport) if @scanlines && @scanline_strength.positive?
          draw_sms_debug_mask(viewport) if @debug_mask
        else
          msg = armed_relic_path ? "Armed: #{armed_relic_name(42)}" : 'No ROM armed'
          hint = armed_relic_path ? 'Click Start to run' : 'Click Open to select a ROM'
          text_center(msg, window_width / 2, content_top + content_height / 2 - 22, 18, COLORS[:text])
          text_center(hint, window_width / 2, content_top + content_height / 2 + 6, 14, COLORS[:dim])
        end
        return if @fullscreen

        draw_toolbar
        draw_status
        draw_keybindings_menu if @keybindings_open
      end

      def draw_toolbar
        fill_rect(0, 0, window_width, TOOLBAR_H, COLORS[:toolbar])
        fill_rect(0, TOOLBAR_H - 1, window_width, 1, COLORS[:border])
        mx, my = @last_mouse
        TOOLBAR_BUTTONS.each do |btn|
          hover = my <= TOOLBAR_H && mx >= btn[:x] && mx <= btn[:x] + btn[:w]
          fill_rect(btn[:x], 4, btn[:w], TOOLBAR_H - 8, hover ? COLORS[:hover] : COLORS[:button])
          if btn[:action] == :debug_mask
            draw_checkbox(btn[:x] + 8, 12, @debug_mask)
            text(btn[:label], btn[:x] + 28, 11, 14, COLORS[:text])
          else
            text_center(btn[:label], btn[:x] + btn[:w] / 2, 11, 14, COLORS[:text], y_center: false)
          end
        end
        draw_volume_slider
        draw_scanline_control
        draw_select(TIMING_SELECT, selected_option_label(TIMING_OPTIONS, @timing_mode), @open_select == :timing)
        draw_select(REGION_SELECT, selected_option_label(REGION_OPTIONS, @region_mode), @open_select == :region)
        draw_open_select_menu
      end

      def draw_volume_slider
        slider = VOLUME_SLIDER
        hover = @last_mouse[1] <= TOOLBAR_H && volume_slider_hit?(@last_mouse[0], @last_mouse[1])
        fill_rect(slider[:x], slider[:y], slider[:w], slider[:h], hover ? COLORS[:hover] : COLORS[:button])
        text('Vol', slider[:x] + 7, slider[:y] + 7, 12, COLORS[:text])
        track_x = slider[:x] + 36
        track_y = slider[:y] + slider[:h] / 2 - 2
        track_w = slider[:w] - 46
        fill_rect(track_x, track_y, track_w, 4, [18, 12, 28, 255])
        fill_rect(track_x, track_y, track_w * @volume, 4, COLORS[:good])
        knob_x = track_x + track_w * @volume
        fill_rect(knob_x - 3, slider[:y] + 6, 6, slider[:h] - 12, COLORS[:text])
      end

      def draw_scanline_control
        control = SCANLINE_CONTROL
        hover = @last_mouse[1] <= TOOLBAR_H &&
          (@last_mouse[0] >= control[:x] && @last_mouse[0] <= control[:x] + control[:w])
        fill_rect(control[:x], control[:y], control[:w], control[:h], hover ? COLORS[:hover] : COLORS[:button])
        draw_checkbox(control[:x] + 6, control[:y] + 8, @scanlines)
        text('SL', control[:x] + 23, control[:y] + 7, 12, COLORS[:text])
        track_x = scanline_track_x
        track_y = control[:y] + control[:h] / 2 - 2
        track_w = scanline_track_w
        fill_rect(track_x, track_y, track_w, 4, [18, 12, 28, 255])
        fill_rect(track_x, track_y, track_w * @scanline_strength, 4, COLORS[:good])
        knob_x = track_x + track_w * @scanline_strength
        fill_rect(knob_x - 3, control[:y] + 6, 6, control[:h] - 12, COLORS[:text])
        sharp_x = control[:x] + 74
        draw_checkbox(sharp_x, control[:y] + 8, @sharp_pixels)
        text('Sh', sharp_x + 17, control[:y] + 7, 12, COLORS[:text])
      end

      def draw_select(bounds, label, open)
        hover = @last_mouse[1] <= TOOLBAR_H && select_hit?(bounds, @last_mouse[0], @last_mouse[1])
        fill_rect(bounds[:x], bounds[:y], bounds[:w], bounds[:h], hover || open ? COLORS[:hover] : COLORS[:button])
        text(label, bounds[:x] + 9, bounds[:y] + 7, 12, COLORS[:text])
        arrow_x = bounds[:x] + bounds[:w] - 13
        arrow_y = bounds[:y] + bounds[:h] / 2 - 1
        fill_rect(arrow_x, arrow_y, 7, 2, COLORS[:text])
        fill_rect(arrow_x + 2, arrow_y + 3, 3, 2, COLORS[:text])
      end

      def draw_open_select_menu
        return unless @open_select

        bounds = @open_select == :timing ? TIMING_SELECT : REGION_SELECT
        options = @open_select == :timing ? TIMING_OPTIONS : REGION_OPTIONS
        selected = @open_select == :timing ? @timing_mode : @region_mode
        options.each_with_index do |(value, label), index|
          y = TOOLBAR_H + index * 26
          active = value == selected
          fill_rect(bounds[:x], y, bounds[:w], 25, active ? COLORS[:hover] : COLORS[:panel])
          fill_rect(bounds[:x], y, bounds[:w], 1, COLORS[:border])
          text(label, bounds[:x] + 9, y + 6, 12, active ? COLORS[:good] : COLORS[:text])
        end
        fill_rect(bounds[:x], TOOLBAR_H + options.length * 26 - 1, bounds[:w], 1, COLORS[:border])
        fill_rect(bounds[:x], TOOLBAR_H, 1, options.length * 26, COLORS[:border])
        fill_rect(bounds[:x] + bounds[:w] - 1, TOOLBAR_H, 1, options.length * 26, COLORS[:border])
      end

      def draw_keybindings_menu
        panel_w = [520, window_width - 32].min
        row_h = 30
        panel_h = 54 + INPUT_ACTIONS.length * row_h
        x = [[window_width - panel_w - 12, 12].max, window_width - panel_w].min
        y = TOOLBAR_H + 10
        fill_rect(x, y, panel_w, panel_h, [22, 16, 40, 245])
        fill_rect(x, y, panel_w, 1, COLORS[:border])
        fill_rect(x, y + panel_h - 1, panel_w, 1, COLORS[:border])
        fill_rect(x, y, 1, panel_h, COLORS[:border])
        fill_rect(x + panel_w - 1, y, 1, panel_h, COLORS[:border])
        text('Key Bindings', x + 14, y + 12, 16, COLORS[:text])
        text('ESC closes', x + panel_w - 92, y + 14, 12, COLORS[:dim])
        keyboard_x = x + panel_w - 248
        controller_x = x + panel_w - 126
        text('Keyboard', keyboard_x, y + 34, 11, COLORS[:dim])
        text('Pad', controller_x, y + 34, 11, COLORS[:dim])

        INPUT_ACTIONS.each_with_index do |action, index|
          row_y = y + 52 + index * row_h
          hover = @last_mouse[0] >= x + 8 && @last_mouse[0] <= x + panel_w - 8 &&
            @last_mouse[1] >= row_y && @last_mouse[1] <= row_y + row_h - 3
          active_keyboard = @binding_capture == { type: :keyboard, action: action[:id] }
          active_controller = @binding_capture == { type: :controller, action: action[:id] }
          fill_rect(x + 8, row_y, panel_w - 16, row_h - 3, hover ? [42, 32, 70, 255] : COLORS[:panel])
          text(action[:label], x + 18, row_y + 7, 13, COLORS[:text])
          key_value = active_keyboard ? 'press...' : key_name(@key_bindings[action[:id]])
          pad_value = active_controller ? 'press...' : controller_button_name(@controller_bindings[action[:id]])
          fill_rect(keyboard_x - 6, row_y + 4, 104, row_h - 11, active_keyboard ? COLORS[:hover] : COLORS[:button])
          fill_rect(controller_x - 6, row_y + 4, 104, row_h - 11, active_controller ? COLORS[:hover] : COLORS[:button])
          text(key_value, keyboard_x, row_y + 7, 12, active_keyboard ? COLORS[:good] : COLORS[:text])
          text(pad_value, controller_x, row_y + 7, 12, active_controller ? COLORS[:good] : COLORS[:text])
        end
      end

      def draw_checkbox(x, y, checked)
        fill_rect(x, y, 12, 12, [18, 12, 28, 255])
        fill_rect(x, y, 12, 1, COLORS[:border])
        fill_rect(x, y + 11, 12, 1, COLORS[:border])
        fill_rect(x, y, 1, 12, COLORS[:border])
        fill_rect(x + 11, y, 1, 12, COLORS[:border])
        fill_rect(x + 3, y + 3, 6, 6, COLORS[:good]) if checked
      end

      def draw_sms_debug_mask(viewport)
        pixel_width = viewport[:w] / screen_width.to_f
        fill_rect(viewport[:x], viewport[:y], pixel_width * 8, viewport[:h], [0, 0, 0, 255])
      end

      def draw_scanlines(viewport)
        pixel_h = viewport[:h] / screen_height.to_f
        line_h = [[pixel_h * 0.22, 1.0].max, pixel_h * 0.5].min
        alpha = (170 * @scanline_strength).round.clamp(0, 170)
        y = viewport[:y] + pixel_h - line_h
        while y < viewport[:y] + viewport[:h]
          fill_rect(viewport[:x], y, viewport[:w], line_h, [0, 0, 0, alpha])
          y += pixel_h
        end
      end

      def draw_status
        y = window_height - STATUS_H
        fill_rect(0, y, window_width, STATUS_H, [22, 16, 38, 255])
        label = cached_status_label
        text(label, 6, y + 7, 12, @running ? COLORS[:good] : COLORS[:warn])
        hint = 'ESC = Exit | Keys = Bindings'
        text(hint, window_width - text_size(hint, 12)[0] - 8, y + 7, 12, COLORS[:dim])
      end

      def draw_browser
        scale = browser_scale
        sidebar = [280 * scale, window_width * 0.28].min
        header = 120 * scale
        footer = 52 * scale
        row_h = 52 * scale
        fill_rect(0, 0, sidebar, window_height, [18, 13, 35, 255])
        fill_rect(sidebar, 0, window_width - sidebar, header, [35, 25, 60, 255])
        text_center('A S T R A L  E X P L O R E R', sidebar + (window_width - sidebar) / 2, 18 * scale, (40 * scale).to_i, COLORS[:text], y_center: false)
        text(truncate_to_width(@browser_dir, window_width - sidebar - 60 * scale, (22 * scale).to_i), sidebar + 24 * scale, 68 * scale, (22 * scale).to_i, COLORS[:dim])
        draw_browser_sidebar(scale, sidebar)

        list_x = sidebar + 20 * scale
        list_y = header + 10 * scale
        list_w = window_width - list_x - 20 * scale
        list_h = window_height - header - footer - 20 * scale
        fill_rect(list_x, list_y, list_w, list_h, COLORS[:panel])
        text('Name', list_x + 12 * scale, list_y + 8 * scale, (16 * scale).to_i, COLORS[:dim])
        row_top = list_y + 34 * scale
        visible = [(list_h - 34 * scale) / row_h, 1].max.floor
        @browser_scroll = @browser_selected - visible + 1 if @browser_selected >= @browser_scroll + visible
        @browser_scroll = @browser_selected if @browser_selected < @browser_scroll
        @browser_scroll = @browser_scroll.clamp(0, [@browser_entries.length - visible, 0].max)

        (@browser_scroll...[@browser_scroll + visible, @browser_entries.length].min).each do |idx|
          entry = @browser_entries[idx]
          y = row_top + (idx - @browser_scroll) * row_h
          fill_rect(list_x + 4 * scale, y, list_w - 8 * scale, row_h - 2 * scale, entry[:type] == :rom ? [50, 80, 50, 255] : COLORS[:hover]) if idx == @browser_selected
          color = entry[:type] == :rom ? COLORS[:rom] : (entry[:type] == :file ? COLORS[:dim] : COLORS[:folder])
          prefix = entry[:type] == :dir || entry[:type] == :parent ? '[D]' : (entry[:rom]&.label || '[F]')
          name = "#{prefix} #{entry[:name]}"
          text(truncate_to_width(name, list_w - 220 * scale, (24 * scale).to_i), list_x + 14 * scale, y + 10 * scale, (24 * scale).to_i, color)
          text(entry[:size], list_x + list_w - 130 * scale, y + 14 * scale, (16 * scale).to_i, COLORS[:dim]) if list_w > 500 * scale
        end

        fy = window_height - footer
        fill_rect(0, fy, window_width, footer, [25, 18, 45, 255])
        text('Click = Select | Double-Click/Enter = Open | ESC = Back', 12 * scale, fy + 16 * scale, (16 * scale).to_i, COLORS[:dim])
      end

      def draw_browser_sidebar(scale, sidebar)
        text('Quick Paths', 18 * scale, 24 * scale, (18 * scale).to_i, COLORS[:text])
        [['ROM Dir', LastRelicCache.rom_dir], ['Home', Dir.home], ['Project', File.expand_path('.')], ['Downloads', File.join(Dir.home, 'Downloads')]].compact.each_with_index do |(label, path), i|
          y = (70 + i * 34) * scale
          color = path && File.expand_path(path) == @browser_dir ? COLORS[:text] : COLORS[:dim]
          text(label, 18 * scale, y, (16 * scale).to_i, color)
        end
        fill_rect(sidebar, 0, 2, window_height, COLORS[:border])
      end

      def click_browser(x, y)
        scale = browser_scale
        sidebar = [280 * scale, window_width * 0.28].min
        if x < sidebar && y > 60 * scale
          paths = [LastRelicCache.rom_dir, Dir.home, File.expand_path('.'), File.join(Dir.home, 'Downloads')].compact
          idx = ((y - 70 * scale) / (34 * scale)).floor
          navigate_browser(paths[idx]) if paths[idx] && Dir.exist?(paths[idx])
          return
        end

        header = 120 * scale
        row_h = 52 * scale
        row_top = header + 44 * scale
        row = @browser_scroll + ((y - row_top) / row_h).floor
        return unless row >= 0 && row < @browser_entries.length

        if @browser_selected == row && now_ms - (@last_browser_click || 0) < 350
          @browser_selected = row
          activate_browser_entry
        else
          @browser_selected = row
          @last_browser_click = now_ms
        end
      end

      def open_browser
        @mode = :browser
        navigate_browser(LastRelicCache.last_dir)
      end

      def scan_directory(dir)
        entries = Dir.entries(dir).reject { |name| name.start_with?('.') }
        dirs = entries.select { |name| File.directory?(File.join(dir, name)) }.sort_by(&:downcase)
        files = entries.select { |name| File.file?(File.join(dir, name)) }.sort_by(&:downcase)
        result = []
        parent = File.dirname(dir)
        result << { name: '..', path: parent, type: :parent, size: '-' } if parent != dir
        dirs.each { |name| result << { name: name, path: File.join(dir, name), type: :dir, size: '-' } }
        files.each do |name|
          path = File.join(dir, name)
          rom = detect_rom(path)
          result << { name: name, path: path, type: rom ? :rom : :file, size: format_size(File.size(path)), rom: rom }
        end
        result
      rescue SystemCallError
        []
      end

      def navigate_browser(path)
        return unless path && Dir.exist?(path)

        @browser_dir = File.expand_path(path)
        @browser_entries = scan_directory(@browser_dir)
        @browser_selected = 0
        @browser_scroll = 0
      end

      def move_browser(delta)
        return if @browser_entries.empty?

        @browser_selected = (@browser_selected + delta).clamp(0, @browser_entries.length - 1)
      end

      def activate_browser_entry
        entry = @browser_entries[@browser_selected]
        return unless entry

        case entry[:type]
        when :dir, :parent
          navigate_browser(entry[:path])
        when :rom
          LastRelicCache.save_relic(entry[:path])
          LastRelicCache.save_rom_dir(File.dirname(entry[:path]))
          @selected_path = entry[:path]
          @mode = :game
          load_selected_relic(entry[:path], autostart: @autostart)
        end
      end

      def load_selected_relic(path, autostart: false)
        was_running = @running
        @running = false
        @audio_player&.stop
        @stone.absorb_codex(path)
        apply_console_region
        @audio_player = build_audio_player
        @frame_count = 0
        @last_vision = now_ms
        @running = autostart || was_running
        flash_status("Armed #{system_label} #{File.basename(path)}")
      rescue => e
        flash_status("Open failed: #{e.message}")
      end

      def toggle_start
        path = armed_relic_path
        unless path
          open_browser
          return
        end

        load_selected_relic(path, autostart: true)
        @running = true if @stone.instance_variable_get(:@codex_present)
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
        apply_console_region
        @audio_player = build_audio_player
        @frame_count = @stone.emulator.frame_count
        @last_vision = now_ms
        @running = was_running
        flash_status("Loaded #{File.basename(path)}")
      rescue => e
        @running = false
        flash_status("Load failed: #{e.message}")
      end

      def sync_game_input_state
        return unless @input_dirty

        keys = @keys
        pad_buttons = @pad_buttons
        port = 0xFF
        INPUT_ACTIONS.each do |action|
          gesture = action[:gesture]
          next unless gesture

          port &= ~gesture if action_pressed?(action[:id], keys, pad_buttons)
        end

        @input_port_a = port
        touch = @stone.mystic_touch
        touch.left_palm = port
        touch.right_palm = 0xFF
        @input_dirty = false
      end

      def load_key_bindings
        saved = LastRelicCache.key_bindings
        INPUT_ACTIONS.each_with_object({}) do |action, bindings|
          raw = saved[action[:id]]
          key = raw.nil? ? action[:default] : raw.to_i
          bindings[action[:id]] = key.positive? ? key : action[:default]
        end
      end

      def rebuild_key_lookup
        @key_to_action = {}
        @key_bindings.each { |action, key| @key_to_action[key] = action if key && key.positive? }
        INPUT_KEY_ALIASES.each do |action, keys|
          keys.each { |key| @key_to_action[key] ||= action if key && key.positive? }
        end
      end

      def action_pressed?(action_id, keys, pad_buttons)
        bound_key = @key_bindings[action_id]
        return true if bound_key && keys[bound_key]

        (INPUT_KEY_ALIASES[action_id] || []).any? { |key| keys[key] } ||
          pad_buttons[@controller_bindings[action_id]]
      end

      def load_controller_bindings
        saved = LastRelicCache.controller_bindings
        INPUT_ACTIONS.each_with_object({}) do |action, bindings|
          raw = saved[action[:id]]
          button = raw.nil? ? action[:pad_default] : raw.to_i
          bindings[action[:id]] = button >= 0 ? button : action[:pad_default]
        end
      end

      def rebuild_controller_lookup
        @controller_to_action = {}
        @controller_bindings.each { |action, button| @controller_to_action[button] = action if button && button >= 0 }
      end

      def capture_binding_key(key)
        if key == SDL3::K_ESCAPE
          @binding_capture = nil
          return
        end

        @key_bindings.each_key do |action|
          @key_bindings[action] = 0 if @key_bindings[action] == key
        end
        @key_bindings[@binding_capture[:action]] = key
        @keys.clear
        @input_dirty = true
        @binding_capture = nil
        rebuild_key_lookup
        LastRelicCache.save_key_bindings(@key_bindings)
      end

      def capture_controller_button(button)
        @controller_bindings.each_key do |action|
          @controller_bindings[action] = -1 if @controller_bindings[action] == button
        end
        @controller_bindings[@binding_capture[:action]] = button
        @pad_buttons.clear
        @input_dirty = true
        @binding_capture = nil
        rebuild_controller_lookup
        LastRelicCache.save_controller_bindings(@controller_bindings)
      end

      def click_keybindings(x, y)
        panel_w = [520, window_width - 32].min
        row_h = 30
        panel_h = 54 + INPUT_ACTIONS.length * row_h
        panel_x = [[window_width - panel_w - 12, 12].max, window_width - panel_w].min
        panel_y = TOOLBAR_H + 10
        unless x >= panel_x && x <= panel_x + panel_w && y >= panel_y && y <= panel_y + panel_h
          @keybindings_open = false
          @binding_capture = nil
          return
        end

        row = ((y - panel_y - 52) / row_h).floor
        return unless row >= 0 && row < INPUT_ACTIONS.length

        keyboard_x = panel_x + panel_w - 248
        controller_x = panel_x + panel_w - 126
        action = INPUT_ACTIONS[row][:id]
        if x >= keyboard_x - 6 && x <= keyboard_x + 98
          @binding_capture = { type: :keyboard, action: action }
        elsif x >= controller_x - 6 && x <= controller_x + 98
          @binding_capture = { type: :controller, action: action }
        end
      end

      def reset_game
        @keys.clear
        @pad_buttons.clear
        @input_dirty = true
        @stone.attune
        @audio_player&.stop
        @frame_count = 0
      end

      def open_existing_gamepads
        count_ptr = FFI::MemoryPointer.new(:int)
        ids = SDL3.get_gamepads(count_ptr)
        count = count_ptr.read_int
        count.times { |index| open_gamepad(ids.get_uint32(index * 4)) } if ids && !ids.null?
        SDL3.free(ids) if ids && !ids.null?
      end

      def open_gamepad(instance_id)
        return if @gamepads[instance_id]

        gamepad = SDL3.open_gamepad(instance_id)
        @gamepads[instance_id] = gamepad if gamepad && !gamepad.null?
      end

      def close_gamepad(instance_id)
        gamepad = @gamepads.delete(instance_id)
        SDL3.close_gamepad(gamepad) if gamepad && !gamepad.null?
        @pad_buttons.clear
        @input_dirty = true
      end

      def close_gamepads
        @gamepads.each_value { |gamepad| SDL3.close_gamepad(gamepad) if gamepad && !gamepad.null? }
        @gamepads.clear
      end

      def toggle_fullscreen
        @fullscreen = !@fullscreen
        SDL3.set_window_fullscreen(@window, @fullscreen)
        @mouse_visible_until = 0
        SDL3.hide_cursor if @fullscreen
        SDL3.show_cursor unless @fullscreen
      end

      def build_audio_player
        player = PsgPlayer.new(@stone.emulator.psg)
        player.volume = @volume
        player
      end

      def apply_console_region
        emulator = @stone.emulator
        return unless emulator.respond_to?(:configure_region)

        emulator.configure_region(timing: @timing_mode, region: @region_mode)
      end

      def autostart_loaded_relic
        return unless @stone.instance_variable_get(:@codex_present)
        return unless @autostart

        apply_console_region
        @running = true
        @last_vision = now_ms
      end

      def volume_slider_hit?(x, y)
        slider = VOLUME_SLIDER
        x >= slider[:x] && x <= slider[:x] + slider[:w] && y >= slider[:y] && y <= slider[:y] + slider[:h]
      end

      def set_volume_from_x(x)
        slider = VOLUME_SLIDER
        track_x = slider[:x] + 36
        track_w = slider[:w] - 46
        @volume = ((x - track_x) / track_w.to_f).clamp(0.0, 1.0)
        @audio_player.volume = @volume if @audio_player
      end

      def scanline_checkbox_hit?(x, y)
        control = SCANLINE_CONTROL
        x >= control[:x] && x <= control[:x] + 42 && y >= control[:y] && y <= control[:y] + control[:h]
      end

      def scanline_slider_hit?(x, y)
        control = SCANLINE_CONTROL
        x >= scanline_track_x - 4 && x <= scanline_track_x + scanline_track_w + 4 &&
          y >= control[:y] && y <= control[:y] + control[:h]
      end

      def sharp_pixels_hit?(x, y)
        control = SCANLINE_CONTROL
        x >= control[:x] + 70 && x <= control[:x] + control[:w] &&
          y >= control[:y] && y <= control[:y] + control[:h]
      end

      def select_hit?(bounds, x, y)
        x >= bounds[:x] && x <= bounds[:x] + bounds[:w] &&
          y >= bounds[:y] && y <= bounds[:y] + bounds[:h]
      end

      def click_select_option(x, y)
        return false unless @open_select

        bounds = @open_select == :timing ? TIMING_SELECT : REGION_SELECT
        options = @open_select == :timing ? TIMING_OPTIONS : REGION_OPTIONS
        return false unless x >= bounds[:x] && x <= bounds[:x] + bounds[:w] && y >= TOOLBAR_H

        index = ((y - TOOLBAR_H) / 26).floor
        return false unless index >= 0 && index < options.length

        value = options[index][0]
        if @open_select == :timing
          @timing_mode = value
          LastRelicCache.save_timing_mode(value)
        else
          @region_mode = value
          LastRelicCache.save_region_mode(value)
        end
        @open_select = nil
        apply_console_region
        flash_status("MD region #{selected_option_label(TIMING_OPTIONS, @timing_mode)} #{selected_option_label(REGION_OPTIONS, @region_mode)}")
        true
      end

      def selected_option_label(options, selected)
        options.find { |value, _label| value == selected }&.[](1) || options.first[1]
      end

      def scanline_track_x
        SCANLINE_CONTROL[:x] + 43
      end

      def scanline_track_w
        25
      end

      def set_scanline_strength_from_x(x)
        @scanline_strength = ((x - scanline_track_x) / scanline_track_w.to_f).clamp(0.0, 1.0)
      end

      def update_screen_texture
        render_version = emulator_render_version
        return if @last_uploaded_render_version == render_version

        framebuffer = @stone.vision_sprite.scrying_pool
        width = screen_width
        height = screen_height
        ensure_screen_texture(width, height)
        @frame_rgba.clear
        if @sharp_pixels
          append_edge_sharpened_frame(framebuffer, width, height)
        else
          append_raw_frame(framebuffer, width, height)
        end
        @frame_pixels.put_bytes(0, @frame_rgba)
        SDL3.update_texture(@screen_texture, nil, @frame_pixels, width * 4)
        @last_uploaded_render_version = render_version
      end

      def ensure_screen_texture(width, height)
        return if @screen_texture_width == width && @screen_texture_height == height

        SDL3.destroy_texture(@screen_texture) if @screen_texture && !@screen_texture.null?
        @screen_texture = SDL3.check(SDL3.create_texture(@renderer, SDL3::PIXELFORMAT_RGBA32,
          SDL3::TEXTUREACCESS_STREAMING, width, height), 'SDL_CreateTexture')
        SDL3.set_texture_scale_mode(@screen_texture, SDL3::SCALEMODE_NEAREST)
        @screen_texture_width = width
        @screen_texture_height = height
        @frame_pixels = FFI::MemoryPointer.new(:uint8, width * height * 4)
        @frame_rgba = String.new(capacity: width * height * 4, encoding: Encoding::BINARY)
      end

      def emulator_render_version
        emulator = @stone.emulator
        if emulator.respond_to?(:vdp)
          emulator.vdp.render_version
        elsif emulator.respond_to?(:render_version)
          emulator.render_version
        else
          @frame_count
        end
      end

      def append_raw_frame(framebuffer, width, height)
        pixel_count = width * height
        index = 0
        palette = active_palette_rgba
        while index < pixel_count
          @frame_rgba << palette[(framebuffer[index] || 0) & 0x3F]
          index += 1
        end
      end

      def append_edge_sharpened_frame(framebuffer, width, height)
        normal = active_palette_rgba
        sharp = active_sharp_palette_rgba
        last_x = width - 1
        last_y = height - 1
        y = 0
        while y < height
          row = y * width
          x = 0
          while x < width
            index = row + x
            color = (framebuffer[index] || 0) & 0x3F
            edge = (x < last_x && ((framebuffer[index + 1] || 0) & 0x3F) != color) ||
              (y < last_y && ((framebuffer[index + width] || 0) & 0x3F) != color)
            @frame_rgba << (edge ? sharp[color] : normal[color])
            x += 1
          end
          y += 1
        end
      end

      def active_palette_rgba
        vdp = @stone.emulator.respond_to?(:vdp) ? @stone.emulator.vdp : nil
        vdp&.respond_to?(:palette_rgba) ? vdp.palette_rgba : @palette_rgba
      end

      def active_sharp_palette_rgba
        vdp = @stone.emulator.respond_to?(:vdp) ? @stone.emulator.vdp : nil
        vdp&.respond_to?(:sharp_palette_rgba) ? vdp.sharp_palette_rgba : @sharp_palette_rgba
      end

      def sharp_channel(value)
        value = 127.5 + (value - 127.5) * 1.35
        value.round.clamp(0, 255)
      end

      def screen_viewport
        width = screen_width
        height = screen_height
        scale = [window_width.to_f / width, content_height.to_f / height].min
        scale = [scale, 0.1].max
        w = width * scale
        h = height * scale
        { x: (window_width - w) / 2.0, y: content_top + (content_height - h) / 2.0, w: w, h: h }
      end

      def screen_width
        vdp = @stone.emulator&.respond_to?(:vdp) ? @stone.emulator.vdp : nil
        vdp&.respond_to?(:screen_width) ? vdp.screen_width : SMS_W
      end

      def screen_height
        vdp = @stone.emulator&.respond_to?(:vdp) ? @stone.emulator.vdp : nil
        vdp&.respond_to?(:screen_height) ? vdp.screen_height : SMS_H
      end

      def content_top
        @fullscreen ? 0 : TOOLBAR_H
      end

      def content_height
        [window_height - content_top - (@fullscreen ? 0 : STATUS_H), 1].max
      end

      def clear(r, g, b, a)
        SDL3.set_render_draw_color(@renderer, r, g, b, a)
        SDL3.render_clear(@renderer)
      end

      def fill_rect(x, y, w, h, color)
        SDL3.set_render_draw_color(@renderer, *color)
        @rect[:x], @rect[:y], @rect[:w], @rect[:h] = x.to_f, y.to_f, w.to_f, h.to_f
        SDL3.render_fill_rect(@renderer, @rect)
      end

      def render_texture(texture, x, y, w, h)
        @rect[:x], @rect[:y], @rect[:w], @rect[:h] = x.to_f, y.to_f, w.to_f, h.to_f
        SDL3.render_texture(@renderer, texture, nil, @rect)
      end

      def text(str, x, y, size, color)
        texture = text_texture(str, size, color)
        render_texture(texture[:ptr], x, y, texture[:w], texture[:h])
      end

      def text_center(str, cx, y, size, color, y_center: true)
        w, h = text_size(str, size)
        text(str, cx - w / 2.0, y_center ? y - h / 2.0 : y, size, color)
      end

      def text_size(str, size)
        key = [str, size]
        return @text_size_cache[key] if @text_size_cache[key]

        font = font(size)
        SDL3TTF.get_string_size(font, str, str.bytesize, @text_size_w, @text_size_h)
        @text_size_cache[key] = [@text_size_w.read_int, @text_size_h.read_int]
      end

      def text_texture(str, size, color)
        key = [str, size, color]
        return @text_cache[key] if @text_cache[key]

        sdl_color = SDL3::Color.new
        sdl_color[:r], sdl_color[:g], sdl_color[:b], sdl_color[:a] = color
        surface_ptr = SDL3TTF.render_text_blended(font(size), str, str.bytesize, sdl_color)
        SDL3.check(surface_ptr, 'TTF_RenderText_Blended')
        surface = SDL3::Surface.new(surface_ptr)
        width = surface[:w]
        height = surface[:h]
        texture_ptr = SDL3.check(SDL3.create_texture_from_surface(@renderer, surface_ptr), 'SDL_CreateTextureFromSurface')
        SDL3.destroy_surface(surface_ptr)
        @text_cache[key] = { ptr: texture_ptr, w: width, h: height }
      end

      def key_name(key)
        return '-' if key.nil? || key.to_i <= 0

        case key
        when SDL3::K_UP then 'Up'
        when SDL3::K_DOWN then 'Down'
        when SDL3::K_LEFT then 'Left'
        when SDL3::K_RIGHT then 'Right'
        when SDL3::K_RETURN then 'Enter'
        when SDL3::K_SPACE then 'Space'
        when SDL3::K_ESCAPE then 'Esc'
        when SDL3::K_F5 then 'F5'
        when SDL3::K_F9 then 'F9'
        when SDL3::K_F11 then 'F11'
        else
          key.between?(32, 126) ? key.chr.upcase : "0x#{key.to_s(16).upcase}"
        end
      end

      def controller_button_name(button)
        return '-' if button.nil? || button.to_i < 0

        case button
        when SDL3::GAMEPAD_BUTTON_SOUTH then 'South'
        when SDL3::GAMEPAD_BUTTON_EAST then 'East'
        when SDL3::GAMEPAD_BUTTON_WEST then 'West'
        when SDL3::GAMEPAD_BUTTON_NORTH then 'North'
        when SDL3::GAMEPAD_BUTTON_BACK then 'Back'
        when SDL3::GAMEPAD_BUTTON_START then 'Start'
        when SDL3::GAMEPAD_BUTTON_LEFT_SHOULDER then 'L'
        when SDL3::GAMEPAD_BUTTON_RIGHT_SHOULDER then 'R'
        when SDL3::GAMEPAD_BUTTON_DPAD_UP then 'D-Up'
        when SDL3::GAMEPAD_BUTTON_DPAD_DOWN then 'D-Down'
        when SDL3::GAMEPAD_BUTTON_DPAD_LEFT then 'D-Left'
        when SDL3::GAMEPAD_BUTTON_DPAD_RIGHT then 'D-Right'
        else "B#{button}"
        end
      end

      def font(size)
        size = [size.to_i, 10].max
        @fonts[size] ||= SDL3.check(SDL3TTF.open_font(@font_path, size.to_f), "TTF_OpenFont #{size}")
      end

      def truncate_to_width(str, max_width, size)
        return str if text_size(str, size)[0] <= max_width

        out = str.dup
        out = out[0...-1] while out.length > 1 && text_size("#{out}...", size)[0] > max_width
        "#{out}..."
      end

      def window_width
        @render_width
      end

      def window_height
        @render_height
      end

      def refresh_output_size
        SDL3.get_render_output_size(@renderer, @size_w_ptr, @size_h_ptr)
        @render_width = @size_w_ptr.read_int
        @render_height = @size_h_ptr.read_int
      end

      def now_ms
        SDL3.get_ticks
      rescue StandardError
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      end

      def browser_scale
        Math.sqrt((window_width / 1024.0) * (window_height / 680.0)).clamp(0.72, 1.65)
      end

      def armed_relic_path
        loaded = @stone.crystal_vault.relic_path
        return loaded if loaded && File.exist?(loaded)

        LastRelicCache.last_relic
      end

      def armed_relic_name(max_length)
        name = File.basename(armed_relic_path || 'unknown')
        name.length > max_length ? "#{name[0...(max_length - 3)]}..." : name
      end

      def system_label
        @stone.rom_info&.label || 'ROM'
      end

      def status_label
        if @status_flash && now_ms < @status_flash_until
          @status_flash
        elsif armed_relic_path
          label = "#{@running ? 'Run' : 'Stop'} Frame: #{@frame_count} | #{system_label} | #{armed_relic_name(28)}"
          label = "#{label} | #{perf_label}" if @running
          label
        else
          'No ROM armed'
        end
      end

      def cached_status_label
        now = now_ms
        if @status_label_cache && now < @status_label_until
          return @status_label_cache
        end

        @status_label_cache = status_label
        @status_label_until = now + 250
        @status_label_cache
      end

      def flash_status(message)
        @status_flash = message
        @status_flash_until = now_ms + 2500
        @status_label_cache = nil
        puts message
      end

      def perf_label
        perf = @stone.emulator.perf_summary
        'emu %.1f fps cpu %.1fms vdp %.1fms' % [perf[:fps], perf[:avg_cpu_ms], perf[:avg_vdp_ms]]
      end

      def rom_file?(filename)
        ROM_EXTENSIONS.any? { |ext| filename.downcase.end_with?(ext) }
      end

      def detect_rom(path)
        return nil unless rom_file?(path)

        RomDetector.detect_file(path)
      end

      def format_size(bytes)
        return "#{bytes} B" if bytes < 1024
        return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024

        "#{(bytes / (1024.0 * 1024.0)).round(2)} MB"
      end
    end
  end
end
