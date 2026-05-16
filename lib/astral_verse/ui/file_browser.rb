require 'gosu'

module AstralVerse
  module UI
    class FileBrowser < Gosu::Window
      INITIAL_WIDTH = 1024
      INITIAL_HEIGHT = 680
      LINE_HEIGHT = 72
      HEADER_HEIGHT = 140
      FOOTER_HEIGHT = 80
      MARGIN = 40
      SIDEBAR_WIDTH = 280
      FULLSCREEN_BUTTON = { w: 110, h: 32, margin: 18 }.freeze

      ROM_EXTENSIONS = ['.sms', '.gg', '.bin', '.rom'].freeze

      COLORS = {
        bg:           Gosu::Color.new(255, 12, 8, 25),
        bg_panel:     Gosu::Color.new(255, 22, 16, 40),
        header:       Gosu::Color.new(255, 35, 25, 60),
        sidebar:      Gosu::Color.new(255, 18, 13, 35),
        highlight:    Gosu::Color.new(255, 70, 50, 120),
        highlight_file: Gosu::Color.new(255, 50, 80, 50),
        text:         Gosu::Color.new(255, 255, 255, 255),      # Pure white - max contrast
        dim_text:     Gosu::Color.new(255, 200, 200, 220),      # Light gray
        accent:       Gosu::Color.new(255, 220, 180, 255),     # Bright purple-white
        folder:       Gosu::Color.new(255, 255, 220, 120),      # Bright yellow
        file_rom:     Gosu::Color.new(255, 120, 255, 120),      # Bright green
        file_other:   Gosu::Color.new(255, 220, 220, 240),     # Light gray-white
        footer:       Gosu::Color.new(255, 25, 18, 45),
        border:       Gosu::Color.new(255, 90, 70, 140),
      }

      attr_reader :selected_path

      def initialize(start_dir = Dir.home)
        super(INITIAL_WIDTH, INITIAL_HEIGHT, resizable: true)
        self.caption = "AstralVerse — Relic Explorer"
        @current_dir = File.expand_path(start_dir)
        @entries = scan_directory(@current_dir)
        @selected = 0
        @scroll = 0
        @visible_count = visible_row_count
        @chosen = false
        @closing = false
        @show_hidden = false
        @fullscreen_shortcut_down = false

        # Scrolling state
        @scroll_dragging = false
        @scroll_drag_offset_y = 0

        # Key repeat for faster scrolling
        @key_held = {}
        @key_repeat_timer = 0
        @key_repeat_delay = 30   # ms before repeat starts
        @key_repeat_interval = 15 # ms between repeats when held

        @font_title = Gosu::Font.new(56, name: "Courier New")
        @font_path   = Gosu::Font.new(28, name: "Courier New")
        @font_item   = Gosu::Font.new(32, name: "Courier New")
        @font_small  = Gosu::Font.new(22, name: "Courier New")
        @font_button = Gosu::Font.new(24, name: "Courier New")
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
      rescue SystemCallError
        []
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
        if @closing
          close
          return
        end

        refresh_visible_count

        @bg_anim += 0.015
        now = Gosu.milliseconds

        # Handle scrollbar dragging
        if @scroll_dragging
          if button_down?(Gosu::MsLeft)
            update_scroll_from_drag(pointer_position.last)
          else
            @scroll_dragging = false
          end
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
        Gosu.draw_rect(0, 0, window_width, window_height, COLORS[:bg])

        # Animated particles
        30.times do |i|
          x = ((Math.sin(@bg_anim + i * 0.4) * 0.5 + 0.5) * window_width).to_i
          y = ((Math.cos(@bg_anim * 0.6 + i * 0.25) * 0.5 + 0.5) * window_height).to_i
          alpha = (60 + Math.sin(@bg_anim + i * 0.7) * 30).to_i
          color = Gosu::Color.new(alpha, 50 + i * 3, 30, 90 + i * 2)
          Gosu.draw_rect(x, y, 2, 2, color)
        end
      end

      def draw_sidebar
        Gosu.draw_rect(0, 0, sidebar_width, window_height, COLORS[:sidebar])

        title = "► Quick Paths"
        @font_small.draw_text(title, 20, 25, 1, 1, 1, COLORS[:accent])
        Gosu.draw_rect(15, 56, sidebar_width - 30, 2, COLORS[:border])

        y = 80
        @bookmarks.each do |label, path|
          expanded_path = File.expand_path(path)
          available = Dir.exist?(expanded_path)
          color = if expanded_path == @current_dir
            COLORS[:accent]
          elsif available
            COLORS[:dim_text]
          else
            Gosu::Color.new(255, 110, 100, 130)
          end
          @font_small.draw_text("📁 #{label}", 20, y, 1, 1, 1, color)
          y += 36
        end

        Gosu.draw_rect(sidebar_width, 0, 2, window_height, COLORS[:border])
      end

      def draw_header
        Gosu.draw_rect(sidebar_width, 0, window_width - sidebar_width, HEADER_HEIGHT, COLORS[:header])

        title = "A S T R A L   E X P L O R E R"
        title_x = sidebar_width + (window_width - sidebar_width) / 2 - @font_title.text_width(title) / 2
        @font_title.draw_text(title, title_x, 18, 1, 1, 1, COLORS[:accent])

        # Current path
        path_display = @current_dir.length > 70 ? "..." + @current_dir[-67..-1] : @current_dir
        @font_path.draw_text("📂 #{path_display}", sidebar_width + 25, 72, 1, 1, 1, COLORS[:dim_text])
        draw_fullscreen_button

        Gosu.draw_rect(sidebar_width, HEADER_HEIGHT - 2, window_width - sidebar_width, 2, COLORS[:border])
      end

      def draw_fullscreen_button
        button = fullscreen_button_rect
        label = fullscreen? ? "⛶ Window" : "⛶ Full"
        mx, my = pointer_position
        hover = mx >= button[:x] && mx <= button[:x] + button[:w] &&
                my >= button[:y] && my <= button[:y] + button[:h]
        color = hover ? COLORS[:highlight] : Gosu::Color.new(255, 50, 40, 85)

        Gosu.draw_rect(button[:x], button[:y], button[:w], button[:h], color)
        Gosu.draw_rect(button[:x], button[:y], button[:w], 1, COLORS[:border])
        text_x = button[:x] + (button[:w] - @font_small.text_width(label)) / 2
        @font_small.draw_text(label, text_x, button[:y] + 6, 2, 1, 1, COLORS[:text])
      end

      def draw_file_list
        layout = file_list_layout
        list_top = layout[:top]
        list_left = layout[:left]
        list_width = layout[:width]
        list_height = layout[:height]

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
        @font_small.draw_text("Name", list_left + 15, list_top + 8, 1, 1, 1, COLORS[:dim_text])
        @font_small.draw_text("Size", list_left + list_width - 140, list_top + 8, 1, 1, 1, COLORS[:dim_text])
        @font_small.draw_text("Type", list_left + list_width - 260, list_top + 8, 1, 1, 1, COLORS[:dim_text])
        Gosu.draw_rect(list_left + 15, list_top + 32, list_width - 30, 1, COLORS[:border])

        (start_idx...end_idx).each do |i|
          entry = @entries[i]
          y = layout[:row_top] + (i - start_idx) * LINE_HEIGHT
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

          name_max_width = list_width - 310
          display_name = truncate_name_to_width("#{icon} #{entry[:name]}", @font_item, name_max_width)
           @font_item.draw_text(display_name, x + 8, y + 10, 1, 1, 1, name_color)

           # Type
           type_str = case entry[:type]
                      when :dir then "Folder"
                      when :parent then "Parent"
                      when :rom then "ROM"
                      else "File"
                      end
           @font_small.draw_text(type_str, list_left + list_width - 260, y + 14, 1, 1, 1, COLORS[:dim_text])

           # Size
           @font_small.draw_text(entry[:size], list_left + list_width - 140, y + 14, 1, 1, 1, COLORS[:dim_text])
        end

        if @entries.length > @visible_count
          @scrollbar_track, @scrollbar_thumb = scrollbar_geometry(list_top, list_height)

          # Draw track
          Gosu.draw_rect(@scrollbar_track[:x], @scrollbar_track[:y], @scrollbar_track[:w], @scrollbar_track[:h], Gosu::Color.new(255, 50, 40, 80))
          Gosu.draw_rect(@scrollbar_track[:x], @scrollbar_track[:y], @scrollbar_track[:w], 2, COLORS[:border])
          Gosu.draw_rect(@scrollbar_track[:x], @scrollbar_track[:y] + @scrollbar_track[:h] - 2, @scrollbar_track[:w], 2, COLORS[:border])
          
          # Draw thumb
          thumb_bg = @scroll_dragging ? Gosu::Color.new(255, 180, 160, 255) : Gosu::Color.new(255, 120, 100, 200)
          Gosu.draw_rect(@scrollbar_thumb[:x], @scrollbar_thumb[:y].to_i, @scrollbar_thumb[:w], @scrollbar_thumb[:h].to_i, thumb_bg)
          Gosu.draw_rect(@scrollbar_thumb[:x], @scrollbar_thumb[:y].to_i, @scrollbar_thumb[:w], 2, Gosu::Color::WHITE)
          Gosu.draw_rect(@scrollbar_thumb[:x], @scrollbar_thumb[:y].to_i + @scrollbar_thumb[:h].to_i - 2, @scrollbar_thumb[:w], 2, Gosu::Color::WHITE)
        else
          @scrollbar_track = nil
          @scrollbar_thumb = nil
        end
      end

      def truncate_name(name, max_len)
        return name if name.length <= max_len
        name[0..max_len-4] + "..."
      end

      def truncate_name_to_width(name, font, max_width)
        return name if font.text_width(name) <= max_width

        ellipsis = "..."
        truncated = name.dup
        truncated = truncated[0...-1] while truncated.length > 1 && font.text_width("#{truncated}#{ellipsis}") > max_width
        "#{truncated}#{ellipsis}"
      end

      def draw_footer
        y = window_height - FOOTER_HEIGHT
        Gosu.draw_rect(0, y, window_width, FOOTER_HEIGHT, COLORS[:footer])
        Gosu.draw_rect(0, y, window_width, 2, COLORS[:border])

        # Left side: controls
        left_hint = "🖱️ Click = Select | Double-Click = Open | ESC = Cancel"
        @font_small.draw_text(left_hint, 25, y + 22, 1, 1, 1, COLORS[:dim_text])

        # Right side: ROM count
        rom_count = @entries.count { |e| e[:type] == :rom }
        right_text = "#{rom_count} ROM(s) found | ↑↓ Navigate"
        @font_small.draw_text(right_text, window_width - @font_small.text_width(right_text) - 25, y + 22, 1, 1, 1, COLORS[:dim_text])
      end

      # MOUSE SUPPORT
      def mouse_x; super; end
      def mouse_y; super; end

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
          mx, my = pointer_position
          if hit_fullscreen_button?(mx, my)
            toggle_fullscreen
            return
          end

          scrollbar_hit = hit_scrollbar?(mx, my)
          if scrollbar_hit
            @scroll_drag_offset_y = scrollbar_hit == :thumb ? my - @scrollbar_thumb[:y] : @scrollbar_thumb[:h] / 2.0
            @scroll_dragging = true
            update_scroll_from_drag(my)
            return
          end

          now = Gosu.milliseconds
          clicked_row = row_at(mx, my)
          if clicked_row && @pending_click_time && @pending_click_row == clicked_row && (now - @pending_click_time) < 300
            handle_mouse_click(mx, my, :double)
            @pending_click_time = nil
            @pending_click_row = nil
          else
            handle_mouse_click(mx, my, :single)
            @pending_click_time = clicked_row ? now : nil
            @pending_click_row = clicked_row
          end
        when Gosu::KB_ESCAPE
          @selected_path = nil
          @chosen = true
          @closing = true
        when Gosu::KB_RETURN, Gosu::KB_ENTER
          activate_selected
        when Gosu::KB_SPACE
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
        when Gosu::MsWheelUp
          move_selection(-3)
        when Gosu::MsWheelDown
          move_selection(3)
        end
      end

      def button_up(id)
        @fullscreen_shortcut_down = false if fullscreen_shortcut_key?(id)

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

      def needs_cursor?
        true
      end

      def hit_scrollbar?(mx, my)
        return false unless @scrollbar_track && @scrollbar_thumb
        thumb_hit = mx >= @scrollbar_thumb[:x] && mx <= @scrollbar_thumb[:x] + @scrollbar_thumb[:w] &&
                    my >= @scrollbar_thumb[:y] && my <= @scrollbar_thumb[:y] + @scrollbar_thumb[:h]
        return :thumb if thumb_hit

        track_hit = mx >= @scrollbar_track[:x] && mx <= @scrollbar_track[:x] + @scrollbar_track[:w] &&
                    my >= @scrollbar_track[:y] && my <= @scrollbar_track[:y] + @scrollbar_track[:h]
        track_hit ? :track : false
      end

      def update_scroll_from_drag(y)
        return unless @entries.length > @visible_count

        max_scroll = max_scroll_index
        layout = file_list_layout
        track = @scrollbar_track || scrollbar_geometry(layout[:top], layout[:height]).first
        thumb = @scrollbar_thumb || scrollbar_geometry(layout[:top], layout[:height]).last
        travel = [track[:h] - thumb[:h], 1].max
        thumb_y = (y - @scroll_drag_offset_y).clamp(track[:y], track[:y] + travel)

        @scroll = (((thumb_y - track[:y]) / travel.to_f) * max_scroll).round.clamp(0, max_scroll)
        @selected = @scroll
      end

      def handle_mouse_click(mx, my, click_type)
        # Sidebar bookmarks - use actual draw positions
        if mx < sidebar_width && my > 80
          idx = ((my - 80) / 36.0).floor
          if idx >= 0 && idx < @bookmarks.length
            nav_path = @bookmarks.values.to_a[idx]
            navigate_to(nav_path) if Dir.exist?(File.expand_path(nav_path))
            return
          end
        end

        row = row_at(mx, my)
        return unless row

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
        max_scroll = max_scroll_index
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
        return unless Dir.exist?(File.expand_path(path))

        @current_dir = File.expand_path(path)
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
        @closing = true
      end

      def toggle_hidden
        @show_hidden = !@show_hidden
        @entries = scan_directory(@current_dir)
        @selected = 0
        @scroll = 0
      end

      def max_scroll_index
        [@entries.length - @visible_count, 0].max
      end

      def scrollbar_geometry(list_top, list_height)
        track = { x: window_width - 55, y: list_top, w: 40, h: list_height }
        ratio = @visible_count.to_f / @entries.length
        thumb_h = [(ratio * list_height).round, 40].max
        thumb_h = [thumb_h, list_height].min
        travel = [list_height - thumb_h, 0].max
        thumb_y = list_top + (@scroll.to_f / max_scroll_index) * travel

        [track, { x: track[:x], y: thumb_y, w: track[:w], h: thumb_h }]
      end

      def file_list_layout
        list_top = HEADER_HEIGHT + 10
        list_height = [window_height - HEADER_HEIGHT - FOOTER_HEIGHT - 20, LINE_HEIGHT].max
        left = sidebar_width + 20
        {
          top: list_top,
          left: left,
          width: [window_width - left - 20, 120].max,
          height: list_height,
          row_top: list_top + 40,
          row_bottom: list_top + list_height
        }
      end

      def row_at(mx, my)
        layout = file_list_layout
        return nil unless mx >= layout[:left] && mx <= layout[:left] + layout[:width]
        return nil unless my >= layout[:row_top] && my < layout[:row_bottom]

        visible_row = ((my - layout[:row_top]) / LINE_HEIGHT).floor
        return nil if visible_row.negative? || visible_row >= @visible_count

        @scroll + visible_row
      end

      def pointer_position
        [mouse_x, mouse_y]
      end

      def fullscreen_button_rect
        {
          x: window_width - FULLSCREEN_BUTTON[:w] - FULLSCREEN_BUTTON[:margin],
          y: FULLSCREEN_BUTTON[:margin],
          w: FULLSCREEN_BUTTON[:w],
          h: FULLSCREEN_BUTTON[:h]
        }
      end

      def hit_fullscreen_button?(mx, my)
        button = fullscreen_button_rect
        mx >= button[:x] && mx <= button[:x] + button[:w] &&
          my >= button[:y] && my <= button[:y] + button[:h]
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

      def window_width
        [width, 1].max
      end

      def window_height
        [height, 1].max
      end

      def sidebar_width
        [SIDEBAR_WIDTH, (window_width * 0.28).to_i].min
      end

      def visible_row_count
        [((window_height - HEADER_HEIGHT - FOOTER_HEIGHT - 20) / LINE_HEIGHT).floor, 1].max
      end

      def refresh_visible_count
        new_count = visible_row_count
        return if new_count == @visible_count

        @visible_count = new_count
        adjust_scroll
      end
    end
  end
end
