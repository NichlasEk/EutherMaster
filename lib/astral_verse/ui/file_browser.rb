require 'gosu'

module AstralVerse
  module UI
    class FileBrowser < Gosu::Window
      WIDTH = 1400
      HEIGHT = 900
      LINE_HEIGHT = 36
      HEADER_HEIGHT = 100
      FOOTER_HEIGHT = 60
      MARGIN = 40
      SIDEBAR_WIDTH = 260

      ROM_EXTENSIONS = ['.sms', '.gg', '.bin', '.rom'].freeze

      COLORS = {
        bg:           Gosu::Color.new(255, 12, 8, 25),
        bg_panel:     Gosu::Color.new(255, 22, 16, 40),
        header:       Gosu::Color.new(255, 35, 25, 60),
        sidebar:      Gosu::Color.new(255, 18, 13, 35),
        highlight:    Gosu::Color.new(255, 70, 50, 120),
        highlight_file: Gosu::Color.new(255, 50, 80, 50),
        text:         Gosu::Color.new(255, 230, 220, 255),
        dim_text:     Gosu::Color.new(255, 140, 130, 170),
        accent:       Gosu::Color.new(255, 180, 140, 255),
        folder:       Gosu::Color.new(255, 255, 200, 100),
        file_rom:     Gosu::Color.new(255, 150, 255, 150),
        file_other:   Gosu::Color.new(255, 180, 180, 200),
        footer:       Gosu::Color.new(255, 25, 18, 45),
        border:       Gosu::Color.new(255, 90, 70, 140),
      }

      attr_reader :selected_path

      def initialize(start_dir = Dir.home)
        super(WIDTH, HEIGHT, false)
        self.caption = "AstralVerse — Relic Explorer"
        @current_dir = File.expand_path(start_dir)
        @entries = scan_directory(@current_dir)
        @selected = 0
        @scroll = 0
        @visible_count = ((HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 20) / LINE_HEIGHT).to_i
        @chosen = false
        @show_hidden = false

        # Scrolling state
        @scroll_dragging = false
        @scroll_drag_start_y = 0
        @scroll_drag_start_scroll = 0

        # Key repeat for faster scrolling
        @key_held = {}
        @key_repeat_timer = 0
        @key_repeat_delay = 30   # ms before repeat starts
        @key_repeat_interval = 15 # ms between repeats when held

        @font_title = Gosu::Font.new(32, name: "Courier New")
        @font_path   = Gosu::Font.new(16, name: "Courier New")
        @font_item   = Gosu::Font.new(18, name: "Courier New")
        @font_small  = Gosu::Font.new(13, name: "Courier New")
        @font_button = Gosu::Font.new(16, name: "Courier New")
        @bg_anim = 0.0

        @bookmarks = {
          'Home' => Dir.home,
          'Desktop' => File.join(Dir.home, 'Desktop'),
          'Documents' => File.join(Dir.home, 'Documents'),
          'Downloads' => File.join(Dir.home, 'Downloads'),
          'Project' => File.expand_path('.'),
        }
      end

      def scan_directory(dir)
        return [] unless Dir.exist?(dir)

        all = Dir.entries(dir)
        all.reject! { |e| e.start_with?('.') } unless @show_hidden

        dirs = all.select { |e| File.directory?(File.join(dir, e)) }
                 .sort_by(&:downcase)
                 .map { |e| { name: e, path: File.join(dir, e), type: :dir, size: '-' } }

        files = all.select { |e| File.file?(File.join(dir, e)) }
                   .sort_by(&:downcase)
                   .map do |e|
          path = File.join(dir, e)
          size = File.size(path)
          {
            name: e,
            path: path,
            type: rom_file?(e) ? :rom : :file,
            size: format_size(size),
            size_raw: size
          }
        end

        # Add ".." for parent directory if not at root
        parent = File.dirname(dir)
        if parent != dir
          dirs.unshift(name: '..', path: parent, type: :parent, size: '-')
        end

        dirs + files
      end

      def rom_file?(filename)
        ROM_EXTENSIONS.any? { |ext| filename.downcase.end_with?(ext) }
      end

      def format_size(bytes)
        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)} KB"
        else
          "#{(bytes / (1024.0 * 1024.0)).round(2)} MB"
        end
      end

      def update
        @bg_anim += 0.015
        now = Gosu.milliseconds

        # Handle scrollbar dragging
        if @scroll_dragging
          update_scroll_from_drag(mouse_y)
        end

        # Key repeat logic for held arrow keys
        if @key_held[Gosu::KB_UP] || @key_held[Gosu::KB_DOWN]
          if @key_repeat_timer == 0
            # First press already handled in button_down, start timer
            @key_repeat_timer = now
          elsif now - @key_repeat_timer > @key_repeat_delay
            # Repeat firing
            interval = now - (@last_repeat_time || now)
            if interval >= @key_repeat_interval
              delta = @key_held[Gosu::KB_UP] ? -1 : 1
              # When repeating, move faster: 3 lines at a time
              move_selection(delta * 3)
              @last_repeat_time = now
            end
          end
        else
          @key_repeat_timer = 0
          @last_repeat_time = nil
        end

        # Double-click timeout
        if @pending_click_time && (now - @pending_click_time) > 300
          @pending_click_time = nil
        end
      end

      def draw
        draw_background
        draw_sidebar
        draw_header
        draw_file_list
        draw_footer
      end

      def draw_background
        Gosu.draw_rect(0, 0, WIDTH, HEIGHT, COLORS[:bg])

        # Animated particles
        30.times do |i|
          x = ((Math.sin(@bg_anim + i * 0.4) * 0.5 + 0.5) * WIDTH).to_i
          y = ((Math.cos(@bg_anim * 0.6 + i * 0.25) * 0.5 + 0.5) * HEIGHT).to_i
          alpha = (60 + Math.sin(@bg_anim + i * 0.7) * 30).to_i
          color = Gosu::Color.new(alpha, 50 + i * 3, 30, 90 + i * 2)
          Gosu.draw_rect(x, y, 2, 2, color)
        end
      end

      def draw_sidebar
        Gosu.draw_rect(0, 0, SIDEBAR_WIDTH, HEIGHT, COLORS[:sidebar])

        title = "► Quick Paths"
        @font_small.draw_text(title, 15, 15, 1, 1, 1, COLORS[:accent])
        Gosu.draw_rect(10, 35, SIDEBAR_WIDTH - 20, 1, COLORS[:border])

        y = 50
        @bookmarks.each_with_index do |(label, path), i|
          color = (i == @bookmark_selected) ? COLORS[:highlight] : COLORS[:dim_text]
          @font_small.draw_text("📁 #{label}", 20, y, 1, 1, 1, color)
          y += 24
        end

        Gosu.draw_rect(SIDEBAR_WIDTH, 0, 2, HEIGHT, COLORS[:border])
      end

      def draw_header
        Gosu.draw_rect(SIDEBAR_WIDTH, 0, WIDTH - SIDEBAR_WIDTH, HEADER_HEIGHT, COLORS[:header])

        title = "A S T R A L   E X P L O R E R"
        title_x = SIDEBAR_WIDTH + (WIDTH - SIDEBAR_WIDTH) / 2 - @font_title.text_width(title) / 2
        @font_title.draw_text(title, title_x, 18, 1, 1, 1, COLORS[:accent])

        # Current path
        path_display = @current_dir.length > 70 ? "..." + @current_dir[-67..-1] : @current_dir
        @font_path.draw_text("📂 #{path_display}", SIDEBAR_WIDTH + 20, 55, 1, 1, 1, COLORS[:dim_text])

        Gosu.draw_rect(SIDEBAR_WIDTH, HEADER_HEIGHT - 2, WIDTH - SIDEBAR_WIDTH, 2, COLORS[:border])
      end

      def draw_file_list
        list_top = HEADER_HEIGHT + 10
        list_left = SIDEBAR_WIDTH + 20
        list_width = WIDTH - SIDEBAR_WIDTH - 40
        list_height = HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 20

        Gosu.draw_rect(list_left, list_top, list_width, list_height, COLORS[:bg_panel])

        start_idx = @scroll
        end_idx = [@scroll + @visible_count, @entries.length].min

        if @entries.empty?
          msg = "This realm is empty..."
          msg_x = list_left + list_width / 2 - @font_item.text_width(msg) / 2
          msg_y = list_top + list_height / 2
          @font_item.draw_text(msg, msg_x, msg_y, 1, 1, 1, COLORS[:dim_text])
          return
        end

        # Column headers
        @font_small.draw_text("Name", list_left + 10, list_top + 5, 1, 1, 1, COLORS[:dim_text])
        @font_small.draw_text("Size", list_left + list_width - 120, list_top + 5, 1, 1, 1, COLORS[:dim_text])
        @font_small.draw_text("Type", list_left + list_width - 220, list_top + 5, 1, 1, 1, COLORS[:dim_text])
        Gosu.draw_rect(list_left + 10, list_top + 22, list_width - 20, 1, COLORS[:border])

        (start_idx...end_idx).each do |i|
          entry = @entries[i]
          y = list_top + 28 + (i - start_idx) * LINE_HEIGHT
          x = list_left + 10
          w = list_width - 20

          bg_color = if i == @selected
            entry[:type] == :rom ? COLORS[:highlight_file] : COLORS[:highlight]
          else
            Gosu::Color::NONE
          end

          Gosu.draw_rect(x - 5, y, w + 10, LINE_HEIGHT - 2, bg_color) if bg_color != Gosu::Color::NONE

          # Icon + Name
          icon = case entry[:type]
                 when :dir, :parent then "📁"
                 when :rom then "💎"
                 else "📄"
                 end

          name_color = case entry[:type]
                       when :dir, :parent then COLORS[:folder]
                       when :rom then COLORS[:file_rom]
                       else COLORS[:file_other]
                       end

          display_name = truncate_name(entry[:name], 45)
          @font_item.draw_text("#{icon} #{display_name}", x + 5, y + 5, 1, 1, 1, name_color)

          # Type
          type_str = case entry[:type]
                     when :dir then "Folder"
                     when :parent then "Parent"
                     when :rom then "ROM"
                     else "File"
                     end
          @font_small.draw_text(type_str, list_left + list_width - 220, y + 8, 1, 1, 1, COLORS[:dim_text])

          # Size
          @font_small.draw_text(entry[:size], list_left + list_width - 120, y + 8, 1, 1, 1, COLORS[:dim_text])
        end

        # Scroll indicator
        if @entries.length > @visible_count
          ratio = @visible_count.to_f / @entries.length
          bar_h = ratio * list_height
          bar_y = list_top + (@scroll.to_f / @entries.length) * list_height
          # Draw track
          Gosu.draw_rect(list_left + list_width + 5, list_top.to_i, 6, list_height, COLORS[:bg])
          # Draw thumb (wider if dragging)
          thumb_w = @scroll_dragging ? 10 : 6
          thumb_x = list_left + list_width + 5 - (thumb_w - 6) / 2
          thumb_color = @scroll_dragging ? COLORS[:accent] : COLORS[:border]
          Gosu.draw_rect(thumb_x, bar_y.to_i, thumb_w, [bar_h, 20].max.to_i, thumb_color)
        end
      end

      def truncate_name(name, max_len)
        return name if name.length <= max_len
        name[0..max_len-4] + "..."
      end

      def draw_footer
        y = HEIGHT - FOOTER_HEIGHT
        Gosu.draw_rect(0, y, WIDTH, FOOTER_HEIGHT, COLORS[:footer])
        Gosu.draw_rect(0, y, WIDTH, 2, COLORS[:border])

        # Left side: controls
        left_hint = "🖱️ Click = Select | Double-Click = Open | ESC = Cancel"
        @font_small.draw_text(left_hint, 20, y + 15, 1, 1, 1, COLORS[:dim_text])

        # Right side: ROM count
        rom_count = @entries.count { |e| e[:type] == :rom }
        right_text = "#{rom_count} ROM(s) found | ↑↓ Navigate"
        @font_small.draw_text(right_text, WIDTH - @font_small.text_width(right_text) - 20, y + 15, 1, 1, 1, COLORS[:dim_text])
      end

      # MOUSE SUPPORT
      def mouse_x; super; end
      def mouse_y; super; end

      def button_down(id)
        case id
        when Gosu::MsLeft
          # Check if clicking on scrollbar
          if hit_scrollbar?(mouse_x, mouse_y)
            @scroll_dragging = true
            @scroll_drag_start_y = mouse_y
            @scroll_drag_start_scroll = @scroll
            return
          end

          now = Gosu.milliseconds
          if @pending_click_time && (now - @pending_click_time) < 300
            handle_mouse_click(mouse_x, mouse_y, :double)
            @pending_click_time = nil
          else
            handle_mouse_click(mouse_x, mouse_y, :single)
            @pending_click_time = now
          end
        when Gosu::KB_ESCAPE
          @selected_path = nil
          @chosen = true
          close
        when Gosu::KB_RETURN, Gosu::KB_SPACE
          activate_selected
        when Gosu::KB_UP
          @key_held[Gosu::KB_UP] = true
          move_selection(-1)
        when Gosu::KB_DOWN
          @key_held[Gosu::KB_DOWN] = true
          move_selection(1)
        when Gosu::KB_LEFT
          go_up
        when Gosu::KB_PAGE_UP
          move_selection(-@visible_count)
        when Gosu::KB_PAGE_DOWN
          move_selection(@visible_count)
        when Gosu::KB_HOME
          @selected = 0
          @scroll = 0
        when Gosu::KB_END
          @selected = [@entries.length - 1, 0].max
          adjust_scroll
        when Gosu::KB_H
          toggle_hidden
        end
      end

      def button_up(id)
        case id
        when Gosu::MsLeft
          @scroll_dragging = false
        when Gosu::KB_UP
          @key_held[Gosu::KB_UP] = false
          @key_repeat_timer = 0
          @last_repeat_time = nil
        when Gosu::KB_DOWN
          @key_held[Gosu::KB_DOWN] = false
          @key_repeat_timer = 0
          @last_repeat_time = nil
        end
      end

      def wheel_up
        move_selection(-3)
      end

      def wheel_down
        move_selection(3)
      end

      # Scrollbar hit testing
      def hit_scrollbar?(mx, my)
        return false if @entries.length <= @visible_count
        list_top = HEADER_HEIGHT + 10
        list_height = HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 20
        list_left = SIDEBAR_WIDTH + 20
        list_width = WIDTH - SIDEBAR_WIDTH - 40
        track_x = list_left + list_width + 5
        track_w = 6
        mx >= track_x && mx <= track_x + track_w && my >= list_top && my <= list_top + list_height
      end

      def update_scroll_from_drag(y)
        return unless @entries.length > @visible_count
        list_top = HEADER_HEIGHT + 10
        list_height = HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 20
        ratio = (y - list_top).to_f / list_height
        ratio = [ratio, 0.0].max
        ratio = [ratio, 1.0].min
        max_scroll = [@entries.length - @visible_count, 0].max
        @scroll = (ratio * max_scroll).round
        @scroll = [@scroll, 0].max
        @scroll = [@scroll, max_scroll].min
        @selected = @scroll
      end

      def handle_mouse_click(mx, my, click_type)
        # Sidebar bookmarks
        if mx < SIDEBAR_WIDTH && my > 50
          idx = ((my - 50) / 24.0).floor
          if idx >= 0 && idx < @bookmarks.length
            nav_path = @bookmarks.values.to_a[idx]
            navigate_to(nav_path)
            return
          end
        end

        # File list area
        list_top = HEADER_HEIGHT + 10
        list_left = SIDEBAR_WIDTH + 20
        list_width = WIDTH - SIDEBAR_WIDTH - 40
        list_height = HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 20

        return unless mx >= list_left && mx <= list_left + list_width
        return unless my >= list_top + 28 && my <= list_top + list_height

        # Calculate which row was clicked
        row = ((my - (list_top + 28)) / LINE_HEIGHT).floor + @scroll

        if row >= 0 && row < @entries.length
          @selected = row

          if click_type == :double
            activate_selected
          end
        end
      end

      def move_selection(delta)
        return if @entries.empty?
        @selected = (@selected + delta).clamp(0, @entries.length - 1)
        adjust_scroll
      end

      def adjust_scroll
        if @selected < @scroll
          @scroll = @selected
        elsif @selected >= @scroll + @visible_count
          @scroll = @selected - @visible_count + 1
        end
        @scroll = [@scroll, 0].max
        max_scroll = [@entries.length - @visible_count, 0].max
        @scroll = [@scroll, max_scroll].min
      end

      def activate_selected
        return if @entries.empty?
        entry = @entries[@selected]

        case entry[:type]
        when :dir, :parent
          navigate_to(entry[:path])
        when :rom
          pick_file(entry[:path])
        else
          # For non-ROM files, just show info
          puts "⚠️ Not a ROM file: #{entry[:name]}"
        end
      end

      def navigate_to(path)
        @current_dir = path
        @entries = scan_directory(@current_dir)
        @selected = 0
        @scroll = 0
      end

      def go_up
        parent = File.dirname(@current_dir)
        navigate_to(parent) if parent != @current_dir
      end

      def pick_file(path)
        @selected_path = path
        @chosen = true
        close
      end

      def toggle_hidden
        @show_hidden = !@show_hidden
        @entries = scan_directory(@current_dir)
        @selected = 0
        @scroll = 0
      end

      def needs_cursor?
        true
      end
    end
  end
end
