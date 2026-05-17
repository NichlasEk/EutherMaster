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

      ROM_EXTENSIONS = ['.sms', '.gg', '.bin', '.rom'].freeze
      FONT_CANDIDATES = [
        ENV['ASTRAL_FONT'],
        '/usr/share/fonts/noto/NotoSansMono-Regular.ttf',
        '/usr/share/fonts/TTF/DejaVuSansMono.ttf',
        '/usr/share/fonts/dejavu/DejaVuSansMono.ttf'
      ].compact.freeze

      TOOLBAR_BUTTONS = [
        { label: 'Open', x: 8, w: 86, action: :open },
        { label: 'Start', x: 102, w: 86, action: :start },
        { label: 'Stop', x: 196, w: 86, action: :stop },
        { label: 'Save', x: 290, w: 86, action: :save },
        { label: 'Load', x: 384, w: 86, action: :load },
        { label: 'Full', x: 478, w: 86, action: :fullscreen }
      ].freeze

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
        @frame_count = 0
        @last_vision = now_ms
        @frame_rgba = String.new(capacity: SMS_W * SMS_H * 4, encoding: Encoding::BINARY)
        @palette_rgba = Array.new(64) do |value|
          [((value >> 0) & 0x03) * 85, ((value >> 2) & 0x03) * 85, ((value >> 4) & 0x03) * 85, 255].pack('C4')
        end
        @audio_player = PsgPlayer.new(@stone.emulator.psg)
        @fullscreen = false
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
        open_window
        loop_once while !@closing
      ensure
        @audio_player&.stop
        close_window
        SDL3TTF.quit if @ttf_ready
        SDL3.quit if @sdl_ready
      end

      private

      def init_sdl
        SDL3.check(SDL3.init(SDL3::INIT_VIDEO | SDL3::INIT_EVENTS), 'SDL_Init')
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
        @screen_texture = SDL3.check(SDL3.create_texture(@renderer, SDL3::PIXELFORMAT_RGBA32,
          SDL3::TEXTUREACCESS_STREAMING, SMS_W, SMS_H), 'SDL_CreateTexture')
        SDL3.set_texture_scale_mode(@screen_texture, SDL3::SCALEMODE_NEAREST)
      end

      def close_window
        @text_cache&.each_value { |texture| SDL3.destroy_texture(texture[:ptr]) }
        @fonts&.each_value { |font| SDL3TTF.close_font(font) }
        SDL3.destroy_texture(@screen_texture) if @screen_texture && !@screen_texture.null?
        SDL3.destroy_renderer(@renderer) if @renderer && !@renderer.null?
        SDL3.destroy_window(@window) if @window && !@window.null?
      end

      def loop_once
        poll_events
        update_game if @mode == :game
        draw
        SDL3.delay(1)
      end

      def poll_events
        event = FFI::MemoryPointer.new(:uint8, 128)
        while SDL3.poll_event(event)
          type = event.read_uint32
          case type
          when SDL3::EVENT_QUIT
            @closing = true
          when SDL3::EVENT_KEY_DOWN
            handle_key(event.get_uint32(28), true, event.get_uint8(37) != 0)
          when SDL3::EVENT_KEY_UP
            handle_key(event.get_uint32(28), false, false)
          when SDL3::EVENT_MOUSE_BUTTON_DOWN
            handle_click(event.get_uint8(24), event.get_float32(28), event.get_float32(32))
          when SDL3::EVENT_MOUSE_MOTION
            handle_mouse_motion(event.get_float32(28), event.get_float32(32))
          when SDL3::EVENT_MOUSE_WHEEL
            handle_wheel(event.get_float32(28))
          end
        end
      end

      def handle_key(key, down, repeat)
        @keys[key] = down
        return if repeat && down

        if down
          case key
          when SDL3::K_F11
            toggle_fullscreen
            return
          when SDL3::K_ESCAPE
            if @mode == :browser
              @mode = :game
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

      def handle_game_key(key, down)
        return unless down

        case key
        when SDL3::K_SPACE
          toggle_start
        when SDL3::K_F5
          save_state
        when SDL3::K_F9
          load_state
        when SDL3::K_R
          @stone.attune
          @audio_player&.stop
          @frame_count = 0
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
        elsif !@fullscreen && y <= TOOLBAR_H
          TOOLBAR_BUTTONS.each do |btn|
            next unless x >= btn[:x] && x <= btn[:x] + btn[:w]

            handle_toolbar(btn[:action])
            break
          end
        end
      end

      def handle_mouse_motion(x, y)
        return unless @fullscreen

        return if @last_mouse == [x, y]

        @last_mouse = [x, y]
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
        else
          msg = armed_relic_path ? "Armed: #{armed_relic_name(42)}" : 'No ROM armed'
          hint = armed_relic_path ? 'Click Start to run' : 'Click Open to select a ROM'
          text_center(msg, window_width / 2, content_top + content_height / 2 - 22, 18, COLORS[:text])
          text_center(hint, window_width / 2, content_top + content_height / 2 + 6, 14, COLORS[:dim])
        end
        return if @fullscreen

        draw_toolbar
        draw_status
      end

      def draw_toolbar
        fill_rect(0, 0, window_width, TOOLBAR_H, COLORS[:toolbar])
        fill_rect(0, TOOLBAR_H - 1, window_width, 1, COLORS[:border])
        mx, my = @last_mouse
        TOOLBAR_BUTTONS.each do |btn|
          hover = my <= TOOLBAR_H && mx >= btn[:x] && mx <= btn[:x] + btn[:w]
          fill_rect(btn[:x], 4, btn[:w], TOOLBAR_H - 8, hover ? COLORS[:hover] : COLORS[:button])
          text_center(btn[:label], btn[:x] + btn[:w] / 2, 11, 14, COLORS[:text], y_center: false)
        end
      end

      def draw_status
        y = window_height - STATUS_H
        fill_rect(0, y, window_width, STATUS_H, [22, 16, 38, 255])
        label = status_label
        text(label, 6, y + 7, 12, @running ? COLORS[:good] : COLORS[:warn])
        hint = 'ESC = Exit | Arrows+Z/X = Input'
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
          name = "#{entry[:type] == :dir || entry[:type] == :parent ? '[D]' : '[F]'} #{entry[:name]}"
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
          result << { name: name, path: path, type: rom_file?(name) ? :rom : :file, size: format_size(File.size(path)) }
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
          load_selected_relic(entry[:path])
        end
      end

      def load_selected_relic(path)
        was_running = @running
        @running = false
        @audio_player&.stop
        @stone.absorb_codex(path)
        @audio_player = PsgPlayer.new(@stone.emulator.psg)
        @frame_count = 0
        @last_vision = now_ms
        @running = was_running
        flash_status("Armed #{File.basename(path)}")
      rescue => e
        flash_status("Open failed: #{e.message}")
      end

      def toggle_start
        if !@stone.instance_variable_get(:@codex_present)
          armed_relic_path ? load_selected_relic(armed_relic_path) : open_browser
          @running = true if @stone.instance_variable_get(:@codex_present)
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
        @last_vision = now_ms
        @running = was_running
        flash_status("Loaded #{File.basename(path)}")
      rescue => e
        @running = false
        flash_status("Load failed: #{e.message}")
      end

      def sync_game_input_state
        touch = @stone.mystic_touch
        touch.left_palm = 0xFF
        touch.right_palm = 0xFF
        touch.invoke(MysticTouch::GESTURE_NORTH) if @keys[SDL3::K_UP]
        touch.invoke(MysticTouch::GESTURE_SOUTH) if @keys[SDL3::K_DOWN]
        touch.invoke(MysticTouch::GESTURE_WEST) if @keys[SDL3::K_LEFT]
        touch.invoke(MysticTouch::GESTURE_EAST) if @keys[SDL3::K_RIGHT]
        touch.invoke(MysticTouch::GESTURE_PRIMUS) if @keys[SDL3::K_Z] || @keys[SDL3::K_A] || @keys[SDL3::K_RETURN]
        touch.invoke(MysticTouch::GESTURE_SECUNDUS) if @keys[SDL3::K_X] || @keys[SDL3::K_S]
      end

      def toggle_fullscreen
        @fullscreen = !@fullscreen
        SDL3.set_window_fullscreen(@window, @fullscreen)
        @mouse_visible_until = 0
        SDL3.hide_cursor if @fullscreen
        SDL3.show_cursor unless @fullscreen
      end

      def update_screen_texture
        framebuffer = @stone.vision_sprite.scrying_pool
        @frame_rgba.clear
        framebuffer.first(SMS_W * SMS_H).each { |value| @frame_rgba << @palette_rgba[(value || 0) & 0x3F] }
        SDL3.update_texture(@screen_texture, nil, FFI::MemoryPointer.from_string(@frame_rgba), SMS_W * 4)
      end

      def screen_viewport
        scale = [window_width.to_f / SMS_W, content_height.to_f / SMS_H].min
        scale = [scale, 0.1].max
        w = SMS_W * scale
        h = SMS_H * scale
        { x: (window_width - w) / 2.0, y: content_top + (content_height - h) / 2.0, w: w, h: h }
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
        rect = SDL3::FRect.new
        rect[:x], rect[:y], rect[:w], rect[:h] = x.to_f, y.to_f, w.to_f, h.to_f
        SDL3.render_fill_rect(@renderer, rect)
      end

      def render_texture(texture, x, y, w, h)
        rect = SDL3::FRect.new
        rect[:x], rect[:y], rect[:w], rect[:h] = x.to_f, y.to_f, w.to_f, h.to_f
        SDL3.render_texture(@renderer, texture, nil, rect)
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
        font = font(size)
        w = FFI::MemoryPointer.new(:int)
        h = FFI::MemoryPointer.new(:int)
        SDL3TTF.get_string_size(font, str, str.bytesize, w, h)
        [w.read_int, h.read_int]
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
        ptr = FFI::MemoryPointer.new(:int)
        SDL3.get_render_output_size(@renderer, ptr, nil)
        ptr.read_int
      end

      def window_height
        ptr = FFI::MemoryPointer.new(:int)
        SDL3.get_render_output_size(@renderer, nil, ptr)
        ptr.read_int
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

      def status_label
        if @status_flash && now_ms < @status_flash_until
          @status_flash
        elsif armed_relic_path
          label = "#{@running ? 'Run' : 'Stop'} Frame: #{@frame_count} | #{armed_relic_name(28)}"
          label = "#{label} | #{perf_label}" if @running
          label
        else
          'No ROM armed'
        end
      end

      def flash_status(message)
        @status_flash = message
        @status_flash_until = now_ms + 2500
        puts message
      end

      def perf_label
        perf = @stone.emulator.perf_summary
        'emu %.1f fps cpu %.1fms vdp %.1fms' % [perf[:fps], perf[:avg_cpu_ms], perf[:avg_vdp_ms]]
      end

      def rom_file?(filename)
        ROM_EXTENSIONS.any? { |ext| filename.downcase.end_with?(ext) }
      end

      def format_size(bytes)
        return "#{bytes} B" if bytes < 1024
        return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024

        "#{(bytes / (1024.0 * 1024.0)).round(2)} MB"
      end
    end
  end
end
