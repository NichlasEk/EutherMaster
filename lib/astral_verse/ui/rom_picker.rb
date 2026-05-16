require 'gosu'

module AstralVerse
  module UI
    class RomPicker < Gosu::Window
      WIDTH = 900
      HEIGHT = 600
      LINE_HEIGHT = 32
      HEADER_HEIGHT = 80
      FOOTER_HEIGHT = 40
      MARGIN = 40

      COLORS = {
        bg:           Gosu::Color.new(255, 15, 10, 30),
        bg_alt:       Gosu::Color.new(255, 25, 18, 45),
        header:       Gosu::Color.new(255, 40, 30, 70),
        highlight:    Gosu::Color.new(255, 80, 60, 130),
        text:         Gosu::Color.new(255, 220, 210, 255),
        dim_text:     Gosu::Color.new(255, 150, 140, 190),
        accent:       Gosu::Color.new(255, 180, 140, 255),
        footer:       Gosu::Color.new(255, 30, 20, 50),
        border:       Gosu::Color.new(255, 100, 80, 160),
      }

      attr_reader :selected_rom

      def initialize(rom_dir = 'assets/roms')
        super(WIDTH, HEIGHT, false)
        self.caption = "AstralVerse — Testground Relic Vault"
        @rom_dir = rom_dir
        @relics = scan_relics
        @selected = 0
        @scroll = 0
        @visible_count = ((HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT) / LINE_HEIGHT).to_i - 1
        @chosen = false
        @font_title = Gosu::Font.new(28, name: "Courier New")
        @font_item  = Gosu::Font.new(18, name: "Courier New")
        @font_small = Gosu::Font.new(14, name: "Courier New")
        @bg_anim = 0.0
      end

      def scan_relics
        dir = File.expand_path(@rom_dir)
        return [] unless Dir.exist?(dir)

        entries = Dir.entries(dir)
                   .select { |f| f.end_with?('.sms', '.gg', '.bin', '.rom') }
                   .map do |f|
          path = File.join(dir, f)
          size = File.size(path)
          {
            name: f,
            path: path,
            size: size,
            size_str: format_size(size)
          }
        end
        entries.sort_by { |r| r[:name].downcase }
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
        @bg_anim += 0.02
      end

      def draw
        draw_background
        draw_header
        draw_relic_list
        draw_footer
        draw_scrollbar if @relics.length > @visible_count
      end

      def draw_background
        Gosu.draw_rect(0, 0, WIDTH, HEIGHT, COLORS[:bg])

        # Mystiska partiklar/ränder
        20.times do |i|
          x = ((Math.sin(@bg_anim + i * 0.5) * 0.5 + 0.5) * WIDTH).to_i
          y = ((Math.cos(@bg_anim * 0.7 + i * 0.3) * 0.5 + 0.5) * HEIGHT).to_i
          alpha = (80 + Math.sin(@bg_anim + i) * 40).to_i
          color = Gosu::Color.new(alpha, 60 + i * 5, 40, 100 + i * 3)
          Gosu.draw_rect(x, y, 2, 2, color)
        end
      end

      def draw_header
        Gosu.draw_rect(0, 0, WIDTH, HEADER_HEIGHT, COLORS[:header])

        # Titel
        title = "A S T R A L V E R S E"
        title_x = WIDTH / 2 - @font_title.text_width(title) / 2
        @font_title.draw_text(title, title_x, 15, 1, 1, 1, COLORS[:accent])

        # Undertitel
        subtitle = "Testground Relic Vault"
        sub_x = WIDTH / 2 - @font_small.text_width(subtitle) / 2
        @font_small.draw_text(subtitle, sub_x, 50, 1, 1, 1, COLORS[:dim_text])

        # Linje
        Gosu.draw_rect(MARGIN, HEADER_HEIGHT - 2, WIDTH - MARGIN * 2, 2, COLORS[:border])
      end

      def draw_relic_list
        list_top = HEADER_HEIGHT + 10
        list_height = HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 20
        Gosu.draw_rect(MARGIN, list_top, WIDTH - MARGIN * 2, list_height, COLORS[:bg_alt])

        start_idx = @scroll
        end_idx = [@scroll + @visible_count, @relics.length].min

        if @relics.empty?
          msg = "No relics found in #{@rom_dir}"
          msg_x = WIDTH / 2 - @font_item.text_width(msg) / 2
          msg_y = list_top + list_height / 2
          @font_item.draw_text(msg, msg_x, msg_y, 1, 1, 1, COLORS[:dim_text])

          hint = "Place .sms / .gg / .bin / .rom files in #{@rom_dir}/"
          hint_x = WIDTH / 2 - @font_small.text_width(hint) / 2
          @font_small.draw_text(hint, hint_x, msg_y + 30, 1, 1, 1, COLORS[:dim_text])
          return
        end

        (start_idx...end_idx).each do |i|
          relic = @relics[i]
          y = list_top + 5 + (i - start_idx) * LINE_HEIGHT
          x = MARGIN + 10
          w = WIDTH - MARGIN * 2 - 20

          if i == @selected
            Gosu.draw_rect(x - 5, y, w + 10, LINE_HEIGHT - 2, COLORS[:highlight])
          end

          # Index
          @font_small.draw_text("%2d." % (i + 1), x, y + 8, 1, 1, 1, COLORS[:dim_text])

          # Namn
          @font_item.draw_text(relic[:name], x + 30, y + 6, 1, 1, 1, COLORS[:text])

          # Storlek (högerjusterad)
          size_x = x + w - @font_small.text_width(relic[:size_str]) - 10
          @font_small.draw_text(relic[:size_str], size_x, y + 9, 1, 1, 1, COLORS[:dim_text])
        end
      end

      def draw_footer
        y = HEIGHT - FOOTER_HEIGHT
        Gosu.draw_rect(0, y, WIDTH, FOOTER_HEIGHT, COLORS[:footer])
        Gosu.draw_rect(MARGIN, y, WIDTH - MARGIN * 2, 2, COLORS[:border])

        if @relics.empty?
          hint = "ESC = Quit"
        else
          hint = "↑↓ = Navigate  |  ENTER = Select  |  ESC = Quit"
        end

        hint_x = WIDTH / 2 - @font_small.text_width(hint) / 2
        @font_small.draw_text(hint, hint_x, y + 12, 1, 1, 1, COLORS[:dim_text])
      end

      def draw_scrollbar
        list_top = HEADER_HEIGHT + 10
        list_height = HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 20
        track_x = WIDTH - MARGIN + 5
        track_w = 6

        # Track
        Gosu.draw_rect(track_x, list_top, track_w, list_height, COLORS[:bg])

        # Thumb
        ratio = @visible_count.to_f / @relics.length
        thumb_h = [ratio * list_height, 20].max
        thumb_y = list_top + (@scroll.to_f / @relics.length) * list_height
        Gosu.draw_rect(track_x, thumb_y.to_i, track_w, thumb_h.to_i, COLORS[:border])
      end

      def button_down(id)
        case id
        when Gosu::KB_ESCAPE
          @selected_rom = nil
          @chosen = true
          close
        when Gosu::KB_RETURN, Gosu::KB_SPACE
          pick_selected
        when Gosu::KB_UP
          move_selection(-1)
        when Gosu::KB_DOWN
          move_selection(1)
        when Gosu::KB_PAGE_UP
          move_selection(-@visible_count)
        when Gosu::KB_PAGE_DOWN
          move_selection(@visible_count)
        when Gosu::KB_HOME
          @selected = 0
          @scroll = 0
        when Gosu::KB_END
          @selected = [@relics.length - 1, 0].max
          adjust_scroll
        end
      end

      def move_selection(delta)
        return if @relics.empty?
        @selected = (@selected + delta).clamp(0, @relics.length - 1)
        adjust_scroll
      end

      def adjust_scroll
        if @selected < @scroll
          @scroll = @selected
        elsif @selected >= @scroll + @visible_count
          @scroll = @selected - @visible_count + 1
        end
        @scroll = [@scroll, 0].max
        max_scroll = [@relics.length - @visible_count, 0].max
        @scroll = [@scroll, max_scroll].min
      end

      def pick_selected
        return if @relics.empty?
        @selected_rom = @relics[@selected]
        @chosen = true
        close
      end

      def needs_cursor?
        true
      end
    end
  end
end
