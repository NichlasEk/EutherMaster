require 'open3'

module MegaDrive
  class PapriumBusOverride
    DUAL_PORT_BYTES = 0x2000
    SDRAM_BYTES = 0x200000
    SCALE_STAMP_BYTES = 64 * 32
    NVRAM_WORDS = 0x800 / 2
    MAX_VRAM_SLOTS = 64
    OBJECTS_COUNT = 64

    SAT_OFFSET = 0x0B00
    OBJ_OFFSET = 0x0F80
    DMA_COMMANDS_OFFSET = 0x1400
    NETWORK_DATA_OFFSET = 0x1C00
    COMMAND_ARGS_OFFSET = 0x1E10
    DMA_TOTAL_OFFSET = 0x1F10
    DMA_BUDGET_OFFSET = 0x1F12
    DMA_REMAINING_OFFSET = 0x1F14
    DMA_COMMANDS_COUNT_OFFSET = 0x1F16
    SAT_COUNT_OFFSET = 0x1F18
    REG_STATUS1_OFFSET = 0x1FE4
    REG_STATUS2_OFFSET = 0x1FE6
    REG_COMMAND_OFFSET = 0x1FEA

    STATUS2_BUSY = 0x4000
    STATUS2_EEPROM_ERROR1 = 0x0100
    STATUS2_EEPROM_ERROR2 = 0x0200
    STATUS2_MW_DATA_IN = 0x0020
    AUDIO_SAMPLE_RATE = ENV.fetch('ASTRAL_PAPRIUM_MP3_RATE', '22050').to_i.clamp(11_025, 44_100)
    MUSIC_GAIN = ENV.fetch('ASTRAL_PAPRIUM_MUSIC_GAIN', '0.55').to_f.clamp(0.0, 1.5)

    TRACK_FILES = {
      0x01 => "02 90's Acid Dub Character Select.mp3",
      0x02 => "08 90's Dance.mp3",
      0x03 => "42 1988 Commercial.mp3",
      0x04 => "05 Asian Chill.mp3",
      0x05 => "31 Bad Dudes vs Paprium.mp3",
      0x06 => "43 Blade FM.mp3",
      0x07 => "03 Bone Crusher.mp3",
      0x0B => "26 Club Shuffle.mp3",
      0x0C => "23 Continue.mp3",
      0x0E => "07 Cool Groove.mp3",
      0x0F => "36 Cyberpunk Ninja.mp3",
      0x10 => "35 Cyberpunk Funk.mp3",
      0x11 => "30 Cyber Interlude.mp3",
      0x12 => "21 Cyborg Invasion.mp3",
      0x13 => "44 Dark Alley.mp3",
      0x14 => "29 Dark & Power Mad.mp3",
      0x15 => "24 Intro.mp3",
      0x16 => "27 Dark Rock.mp3",
      0x17 => "04 Drumbass Boss.mp3",
      0x18 => "45 Dubstep Groove.mp3",
      0x19 => "15 Electro Acid Funk.mp3",
      0x1B => "28 Evolve.mp3",
      0x1C => "33 Funk Enhanced Mix.mp3",
      0x1D => "41 Game Over.mp3",
      0x1E => "46 Gothic.mp3",
      0x20 => "13 Hard Rock.mp3",
      0x21 => "22 Hardcore BP1.mp3",
      0x22 => "11 Hardcore BP2.mp3",
      0x23 => "38 Hardcore BP3.mp3",
      0x24 => "40 Score.mp3",
      0x25 => "47 House.mp3",
      0x26 => "17 Indie Shuffle.mp3",
      0x27 => "25 Indie Break Beat.mp3",
      0x28 => "16 Jazzy Shuffle.mp3",
      0x2A => "19 Neo Metal.mp3",
      0x2B => "14 Neon Rider.mp3",
      0x2E => "09 Retro Beat.mp3",
      0x2F => "20 Sadness.mp3",
      0x31 => "18 Slow Asian Beat.mp3",
      0x32 => "48 Slow Mood.mp3",
      0x33 => "49 Smooth Coords.mp3",
      0x34 => "10 Spiral.mp3",
      0x35 => "12 Stage Clear.mp3",
      0x36 => "32 Summer Breeze.mp3",
      0x37 => "06 Techno Beats.mp3",
      0x38 => "50 Tension.mp3",
      0x39 => "01 Theme of Paprium.mp3",
      0x3A => "39 Ending.mp3",
      0x3B => "34 Transe.mp3",
      0x3C => "37 Urban.mp3",
      0x3D => "51 Water.mp3",
      0x3E => "52 Waterfront Beat.mp3"
    }.freeze

    def self.paprium_rom?(bytes)
      return false unless bytes && bytes.length >= 0x190

      serial = bytes[0x183, 14].pack('C*')
      serial.include?('T-574120-00')
    end

    def initialize(rom_bytes, source_path: nil)
      @rom_words = to_words(rom_bytes)
      @dual_port = Array.new(DUAL_PORT_BYTES / 2, 0)
      @sdram = Array.new(SDRAM_BYTES / 2, 0)
      @scale_stamp = Array.new(SCALE_STAMP_BYTES, 0)
      @nvram = Array.new(NVRAM_WORDS, 0)
      @vram_slots = Array.new(MAX_VRAM_SLOTS) { new_vram_slot }
      @object_handles = Array.new(OBJECTS_COUNT) { new_object_handle }
      @draw_list = Array.new(OBJECTS_COUNT, 0)
      @save_path = build_save_path(source_path)
      @source_path = source_path
      @music_mutex = Mutex.new
      @trace = ENV['ASTRAL_TRACE_PAPRIUM'] == '1'
      load_nvram
      reset
    end

    def reset
      decode_and_patch_once
      restore_boot_dual_port
      apply_version_patches
      @sdram.fill(0)
      @scale_stamp.fill(0)
      reset_runtime_state
      reset_audio_state
      set_word(REG_COMMAND_OFFSET, 0)
      set_word(REG_STATUS1_OFFSET, 0)
      set_word(REG_STATUS2_OFFSET, 7)
    end

    def mix_music_into(samples, count, sample_rate = AUDIO_SAMPLE_RATE)
      return samples if count <= 0

      @music_mutex.synchronize do
        mix_decoded_music_into_locked(samples, count, sample_rate)
      end
      samples
    end

    def capture_audio_samples(count, sample_rate = AUDIO_SAMPLE_RATE)
      return nil if count <= 0

      @music_mutex.synchronize do
        output = Array.new(count, 0.0)
        mixed = mix_decoded_music_into_locked(output, count, sample_rate)
        mixed ? output : nil
      end
    end

    def marshal_dump
      {
        rom_words: @rom_words,
        dual_port: @dual_port,
        sdram: @sdram,
        scale_stamp: @scale_stamp,
        nvram: @nvram,
        vram_slots: @vram_slots,
        object_handles: @object_handles,
        draw_list: @draw_list,
        draw_list_count: @draw_list_count,
        sdram_pointer_word: @sdram_pointer_word,
        sdram_window_enabled: @sdram_window_enabled,
        vram_max_slot: @vram_max_slot,
        block_unpack_addr: @block_unpack_addr,
        anim_data_base_addr: @anim_data_base_addr,
        anim_max_index: @anim_max_index,
        bgm_tracks_base_addr: @bgm_tracks_base_addr,
        bgm_unpack_addr: @bgm_unpack_addr,
        sfx_base_addr: @sfx_base_addr,
        gfx_blocks_base_addr: @gfx_blocks_base_addr,
        decoded: @decoded,
        save_path: @save_path,
        source_path: @source_path,
        audio_bgm_volume: @audio_bgm_volume,
        audio_config: @audio_config
      }
    end

    def marshal_load(data)
      data.each { |key, value| instance_variable_set(:"@#{key}", value) }
      @music_mutex = Mutex.new
      @trace = ENV['ASTRAL_TRACE_PAPRIUM'] == '1'
      @music_pcm_data = ''.b
      @music_sample_position = 0.0
      @requested_music_track = 0
      @music_loading = false
      @music_generation = 0
    end

    def read_byte(address)
      address &= 0x00FF_FFFF
      return nil unless handles?(address)

      offset = address & 0x003F_FFFF
      if offset < DUAL_PORT_BYTES
        return raw_read_byte(@dual_port, offset ^ 1)
      end

      if offset >= 0xC000 && offset < 0x10000 && @sdram_window_enabled
        word = read_sdram_window_word(false)
        return offset.even? ? ((word >> 8) & 0xFF) : (word & 0xFF)
      end

      return cpu_read_byte(@rom_words, offset) if offset < 0x400000

      0xFF
    end

    def read_word(address)
      address &= 0x00FF_FFFF
      return nil unless handles?(address)

      offset = address & 0x003F_FFFE
      if offset < DUAL_PORT_BYTES
        return read_paprium_register_word(offset)
      end

      if offset >= 0xC000 && offset < 0x10000 && @sdram_window_enabled
        return read_sdram_window_word(true)
      end

      return read_word_from(@rom_words, offset) if offset < 0x400000

      0xFFFF
    end

    def write_byte(address, value)
      address &= 0x00FF_FFFF
      return false unless handles?(address)

      offset = address & 0x003F_FFFF
      if offset < DUAL_PORT_BYTES
        raw_write_byte(@dual_port, offset ^ 1, value & 0xFF)
        process_command if (offset & 0xFFFE) == REG_COMMAND_OFFSET
      end
      true
    end

    def write_word(address, value)
      address &= 0x00FF_FFFF
      return false unless handles?(address)

      offset = address & 0x003F_FFFE
      if offset < DUAL_PORT_BYTES
        set_word(offset, value)
        process_command if offset == REG_COMMAND_OFFSET
      end
      true
    end

    private

    def handles?(address)
      address <= 0x003F_FFFF
    end

    def reset_runtime_state
      @vram_slots = Array.new(MAX_VRAM_SLOTS) { new_vram_slot }
      @object_handles = Array.new(OBJECTS_COUNT) { new_object_handle }
      @draw_list.fill(0)
      @draw_list_count = 0
      @sdram_pointer_word = 0
      @sdram_window_enabled = false
      @vram_max_slot = 0
      @block_unpack_addr = 0
      @anim_data_base_addr = 0
      @anim_max_index = Array.new(256, 0)
      @bgm_tracks_base_addr = 0
      @bgm_unpack_addr = 0
      @sfx_base_addr = 0
    end

    def reset_audio_state
      @music_mutex.synchronize do
        @music_pcm_data = ''.b
        @music_sample_position = 0.0
        @requested_music_track = 0
        @music_loading = false
        @music_generation = @music_generation.to_i + 1
        @audio_bgm_volume = 0x100
        @audio_config = 0
      end
    end

    def mix_decoded_music_into_locked(samples, count, sample_rate)
      return false if @music_pcm_data.nil? || @music_pcm_data.empty? || @requested_music_track.to_i.zero?

      frames = @music_pcm_data.bytesize / 2
      return false if frames <= 0

      volume = ((@audio_bgm_volume.to_i / 256.0) * MUSIC_GAIN).clamp(0.0, 1.5)
      return false if volume <= 0.0

      step = sample_rate == AUDIO_SAMPLE_RATE ? 1.0 : AUDIO_SAMPLE_RATE.to_f / sample_rate.to_f
      position = @music_sample_position.to_f
      index = 0
      while index < count
        frame = position.to_i % frames
        byte = frame * 2
        lo = @music_pcm_data.getbyte(byte).to_i
        hi = @music_pcm_data.getbyte(byte + 1).to_i
        raw = lo | (hi << 8)
        raw -= 0x10000 if raw >= 0x8000
        samples[index] = (samples[index].to_f + ((raw / 32768.0) * volume)).clamp(-1.0, 1.0)
        position += step
        index += 1
      end
      @music_sample_position = position % frames
      true
    end

    def new_vram_slot
      { block_num: 0, usage: 0, age: 0 }
    end

    def new_object_handle
      { anim_offset: 0, current_anim: 0, counter: 0 }
    end

    def read_paprium_register_word(offset)
      case offset
      when REG_STATUS1_OFFSET
        0xFFBB
      when REG_STATUS2_OFFSET
        0xFFFF & ~(1 << 14) & ~(1 << 8) & ~(1 << 9)
      when REG_COMMAND_OFFSET
        0x7FFF
      else
        get_word(offset)
      end
    end

    def read_sdram_window_word(side_effects)
      index = [[@sdram_pointer_word, 0].max, @sdram.length - 1].min
      value = @sdram[index] & 0xFFFF
      @sdram_pointer_word += 1 if side_effects && @sdram_pointer_word < @sdram.length - 1
      value
    end

    def process_command
      command = get_word(REG_COMMAND_OFFSET)
      id = command >> 8
      arg = command & 0xFF

      case id
      when 0x00
        if arg == 0xAA
          set_word(REG_COMMAND_OFFSET, 0x00FF)
          return
        elsif arg == 0x55
          set_word(REG_COMMAND_OFFSET, 0)
          return
        end
      when 0x81
        @sdram_window_enabled = true
      when 0x83, 0x95, 0x96, 0xA4, 0xB1, 0xB6, 0xD6
        # Accepted by the cartridge helper but no host-side action is needed here.
      when 0x84
        @sdram_window_enabled = false
      when 0x88
        @music_mutex.synchronize { @audio_config = arg }
      when 0x8C
        unpack(bgm_addr(arg & 0x7F), @bgm_unpack_addr) if @bgm_tracks_base_addr != 0
        request_music_track(arg & 0x7F)
      when 0xAD
        obj_add(arg)
      when 0xAE
        obj_frame_start
      when 0xAF
        obj_frame_end
      when 0xB0
        obj_reset
      when 0xC6
        setup_data(
          swap_shorts(get_command_arg_long(0)),
          swap_shorts(get_command_arg_long(1)),
          swap_shorts(get_command_arg_long(2)),
          swap_shorts(get_command_arg_long(3)),
          swap_shorts(get_command_arg_long(4)),
          swap_shorts(get_command_arg_long(5)),
          swap_shorts(get_command_arg_long(6))
        )
      when 0xC9
        @music_mutex.synchronize { @audio_bgm_volume = arg & 0xFF }
      when 0xDA
        source = ((get_command_arg(1) << 16) | get_command_arg(2)) & 0xFFFF_FFFF
        dest = get_command_arg(0)
        unpack(source, dest)
        @sdram_pointer_word = dest >> 1
        set_word(REG_STATUS1_OFFSET, get_word(REG_STATUS1_OFFSET) & ~0x0004)
        set_word(REG_STATUS2_OFFSET, get_word(REG_STATUS2_OFFSET) & ~STATUS2_BUSY)
      when 0xDB
        @sdram_pointer_word = swap_shorts(get_command_arg_long(0)) >> 1
      when 0xDF
        load_eeprom_block(arg)
      when 0xE0
        save_eeprom_block(arg)
      when 0xE7
        set_word(REG_STATUS2_OFFSET, get_word(REG_STATUS2_OFFSET) | STATUS2_MW_DATA_IN)
        set_word(NETWORK_DATA_OFFSET + 0x10, (get_command_arg(0) + 16) & 0xFFFF)
      when 0xEC
        vram_set_budget(get_command_arg(1))
      when 0xF2
        block = get_command_arg(0)
        unpack(block_addr(block), 0x9000)
        unpack(block_addr(block), 0x9200)
        @sdram_pointer_word = 0x9000 >> 1
      when 0xF4
        unpack(swap_shorts(get_command_arg_long(0)), 0, true)
      when 0xF5
        stamp_rescale(get_command_arg(0), get_command_arg(1), get_command_arg(2), get_command_arg(3))
      else
        warn format('[PAPRIUM] unhandled command 0x%04X', command) if @trace
      end

      set_word(REG_COMMAND_OFFSET, 0)
    end

    def request_music_track(track)
      track &= 0x7F
      file_name = TRACK_FILES[track]
      if track.zero? || !file_name
        reset_audio_state
        return
      end

      generation = nil
      @music_mutex.synchronize do
        return if @requested_music_track == track && (!@music_pcm_data.empty? || @music_loading)

        @requested_music_track = track
        @music_pcm_data = ''.b
        @music_sample_position = 0.0
        @music_loading = true
        @music_generation += 1
        generation = @music_generation
      end

      source_path = @source_path
      Thread.new do
        decoded = ''.b
        begin
          decoded = decode_music_file(source_path, file_name)
        rescue StandardError => e
          warn "[PAPRIUM] MP3 decode failed track=0x#{track.to_s(16).upcase} #{file_name}: #{e.message}" if @trace
        end

        @music_mutex.synchronize do
          if generation == @music_generation
            @music_pcm_data = decoded || ''.b
            @music_sample_position = 0.0
            @music_loading = false
            @requested_music_track = 0 if @music_pcm_data.empty?
          end
        end
      end
    end

    def decode_music_file(source_path, file_name)
      local_path = find_music_file(source_path, file_name)
      if local_path
        output, status = Open3.capture2('ffmpeg', '-v', 'error', '-i', local_path,
                                        '-f', 's16le', '-ac', '1', '-ar', AUDIO_SAMPLE_RATE.to_s, 'pipe:1',
                                        binmode: true)
        return status.success? ? output.b : ''.b
      end

      bytes = extract_music_bytes(source_path, file_name)
      return ''.b unless bytes && !bytes.empty?

      output, status = Open3.capture2('ffmpeg', '-v', 'error', '-i', 'pipe:0',
                                      '-f', 's16le', '-ac', '1', '-ar', AUDIO_SAMPLE_RATE.to_s, 'pipe:1',
                                      stdin_data: bytes, binmode: true)
      status.success? ? output.b : ''.b
    end

    def find_music_file(source_path, file_name)
      return nil if source_path.nil? || source_path.empty?

      base = File.dirname(source_path)
      parent = File.dirname(base)
      candidates = [
        File.join(base, 'paprium', file_name),
        File.join(base, 'PAPRIUM', 'paprium', file_name),
        File.join(base, file_name),
        File.join(parent, 'PAPRIUM', 'paprium', file_name),
        File.join(parent, 'Paprium', 'paprium', file_name)
      ]
      candidates.find { |path| File.file?(path) }
    end

    def extract_music_bytes(source_path, file_name)
      return nil unless source_path && File.file?(source_path)
      return nil unless ['.zip', '.7z'].include?(File.extname(source_path).downcase)

      listing, status = Open3.capture2('7z', 'l', '-slt', source_path, binmode: true)
      return nil unless status.success?

      entry = nil
      listing.each_line do |line|
        next unless line.start_with?('Path = ')

        path = line.sub('Path = ', '').strip
        if File.basename(path).casecmp(file_name).zero?
          entry = path
          break
        end
      end
      return nil unless entry

      data, extract_status = Open3.capture2('7z', 'x', '-so', source_path, entry, binmode: true)
      extract_status.success? ? data.b : nil
    end

    def setup_data(bgm_file, unk1_file, smp_file, unk2_file, sfx_file, anm_file, blk_file)
      unpack_addr = 0x10000
      @bgm_tracks_base_addr = bgm_file
      smp_file
      unpack_addr += unpack(unk1_file, unpack_addr)
      unpack_addr = (unpack_addr + 1) & 0xFFFF_FFFE
      unpack_addr += unpack(unk2_file, unpack_addr)
      unpack_addr = (unpack_addr + 1) & 0xFFFF_FFFE
      @sfx_base_addr = sfx_file
      @anim_data_base_addr = unpack_addr
      unpack_addr += unpack(anm_file, unpack_addr)
      unpack_addr = (unpack_addr + 1) & 0xFFFF_FFFE

      object_count = [read_sdram_u32(@anim_data_base_addr), 255].min
      @anim_max_index.fill(0)
      1.upto(object_count) do |obj|
        anim_offset = read_anim_u32(obj)
        anim_count = 0
        while anim_count < 0x400 && read_anim_u32((anim_offset >> 2) + anim_count) != 0xFFFF_FFFF
          anim_count += 1
        end
        @anim_max_index[obj - 1] = anim_count.zero? ? 0 : anim_count - 1
      end

      @gfx_blocks_base_addr = blk_file
      @bgm_unpack_addr = unpack_addr
      warn format('[PAPRIUM] setup bgm=0x%06X anm=0x%06X blk=0x%06X unpackEnd=0x%06X', bgm_file, anm_file, blk_file, unpack_addr) if @trace
    end

    def unpack(source_addr, dest_addr, scale_stamp = false)
      initial_dest = dest_addr
      first = rom_packed_byte(source_addr)
      source_addr += 1

      if first == 0x80
        loop do
          code = rom_packed_byte(source_addr)
          source_addr += 1
          break if code.zero?

          count = code & 0x3F
          case code >> 6
          when 0
            count.times do
              packed_write_byte(dest_addr, rom_packed_byte(source_addr), scale_stamp)
              dest_addr += 1
              source_addr += 1
            end
          when 1
            data = rom_packed_byte(source_addr)
            source_addr += 1
            count.times do
              packed_write_byte(dest_addr, data, scale_stamp)
              dest_addr += 1
            end
          when 2
            copy_addr = dest_addr - rom_packed_byte(source_addr)
            source_addr += 1
            count.times do
              packed_write_byte(dest_addr, packed_read_byte(copy_addr, scale_stamp), scale_stamp)
              dest_addr += 1
              copy_addr += 1
            end
          when 3
            count.times do
              packed_write_byte(dest_addr, 0, scale_stamp)
              dest_addr += 1
            end
          end
        end
      elsif first == 0x81
        loop do
          code = rom_packed_byte(source_addr)
          source_addr += 1
          break if code == 0x11

          copy_addr = 0
          case code >> 4
          when 0
            copy_size = 0
            literal_size = code != 0 ? 3 + (code & 0x1F) : 0x12 + rom_packed_byte(source_addr)
            source_addr += 1 if code.zero?
          when 1
            copy_size = 2 + (code & 0x7)
            if copy_size == 2
              copy_size = 9 + rom_packed_byte(source_addr)
              source_addr += 1
            end
            literal_size = rom_packed_byte(source_addr) & 0x3
            copy_addr = dest_addr - 0x4000 - (((rom_packed_byte(source_addr + 1) << 8) + rom_packed_byte(source_addr)) >> 2)
            source_addr += 2
          when 2, 3
            copy_size = code & 0x1F
            if copy_size != 0
              copy_size += 2
            else
              copy_size = 0x21
              while rom_packed_byte(source_addr).zero?
                source_addr += 1
                copy_size += 0xFF
              end
              copy_size += rom_packed_byte(source_addr)
              source_addr += 1
            end
            literal_size = rom_packed_byte(source_addr) & 0x3
            copy_addr = dest_addr - 1 - (((rom_packed_byte(source_addr + 1) << 8) + rom_packed_byte(source_addr)) >> 2)
            source_addr += 2
          else
            copy_size = (code >> 5) + 1
            literal_size = code & 0x3
            copy_addr = dest_addr - 1 - (((code >> 2) & 0x7) + (rom_packed_byte(source_addr) << 3))
            source_addr += 1
          end

          copy_size.times do
            packed_write_byte(dest_addr, packed_read_byte(copy_addr, scale_stamp), scale_stamp)
            dest_addr += 1
            copy_addr += 1
          end
          literal_size.times do
            packed_write_byte(dest_addr, rom_packed_byte(source_addr), scale_stamp)
            dest_addr += 1
            source_addr += 1
          end
        end
      else
        warn format('[PAPRIUM] unknown packer 0x%02X at 0x%06X', first, source_addr - 1) if @trace
      end

      (dest_addr - initial_dest) & 0xFFFF_FFFF
    end

    def vram_set_budget(blocks)
      @vram_max_slot = [blocks, 0x35].min
      vram_reset_blocks(@vram_max_slot)
    end

    def vram_reset_blocks(first)
      first = [[first, 0].max, MAX_VRAM_SLOTS].min
      first.upto(MAX_VRAM_SLOTS - 1) { |idx| @vram_slots[idx] = new_vram_slot }
    end

    def vram_find_block(num)
      0.upto(@vram_max_slot - 1) do |x|
        return ((x + (x <= 0x30 ? 1 : 0x4B)) << 4) & 0xFFFF if @vram_slots[x][:block_num] == num
      end
      0
    end

    def vram_load_block(num)
      return 0 if num.zero?

      0.upto(@vram_max_slot - 1) do |x|
        slot = @vram_slots[x]
        if slot[:block_num] == num
          slot[:usage] += 1
          slot[:age] = 0
          return ((x + (x <= 0x30 ? 1 : 0x4B)) << 4) & 0xFFFF
        end
      end
      return 0 if get_word(DMA_REMAINING_OFFSET) < 0x110

      block_index = -1
      max_age = 0
      0.upto(@vram_max_slot - 1) do |x|
        slot = @vram_slots[x]
        if slot[:usage].zero? && slot[:age] > max_age
          max_age = slot[:age]
          block_index = x
        end
      end
      return 0 if block_index.negative?

      slot = @vram_slots[block_index]
      slot[:block_num] = num
      slot[:usage] += 1
      slot[:age] = 0
      unpack(block_addr(num), @block_unpack_addr)
      @block_unpack_addr += 0x200

      dma = dma_entry_offset(inc_dma_commands_count)
      set_word(dma + 0x00, 0x8F02)
      set_word(dma + 0x02, 0x9401)
      set_word(dma + 0x04, 0x9300)
      set_word(dma + 0x06, 0x9700)
      set_word(dma + 0x08, 0x9660)
      set_word(dma + 0x0A, 0x9500)
      set_word(DMA_REMAINING_OFFSET, get_word(DMA_REMAINING_OFFSET) - 0x110)
      translated = block_index + (block_index <= 0x30 ? 1 : 0x4B)
      command = (((translated << 25) | (translated >> 5)) & 0x3FFF_0003) | 0x4000_0080
      set_word(dma + 0x0C, command >> 16)
      set_word(dma + 0x0E, command)
      (translated << 4) & 0xFFFF
    end

    def obj_reset
      vram_reset_blocks(0)
      (OBJ_OFFSET / 2).upto(((OBJ_OFFSET + 0x400) / 2) - 1) { |idx| @dual_port[idx] = 0 }
      @draw_list_count = 0
    end

    def obj_add(num)
      return unless @draw_list_count < @draw_list.length

      @draw_list[@draw_list_count] = num & 0xFF
      @draw_list_count += 1
    end

    def obj_frame_start
      @draw_list_count = 0
      @vram_slots.each { |slot| slot[:usage] = 0 }
    end

    def obj_frame_end
      @block_unpack_addr = 0x9000
      set_word(DMA_REMAINING_OFFSET, get_word(DMA_BUDGET_OFFSET) - get_word(DMA_TOTAL_OFFSET))
      0.upto(@draw_list_count - 1) { |idx| obj_render(@draw_list[idx]) }
      @vram_slots.each { |slot| slot[:age] += 1 if slot[:usage].zero? }
      close_sprite_table
      @sdram_pointer_word = 0x9000 >> 1
    end

    def close_sprite_table
      sat_count = get_word(SAT_COUNT_OFFSET)
      if sat_count.zero?
        sat = sat_entry_offset(0)
        set_word(sat + 0x00, 0x0010)
        set_word(sat + 0x02, 0x0000)
        set_word(sat + 0x04, 0x0000)
        set_word(sat + 0x06, 0x0010)
        set_word(SAT_COUNT_OFFSET, 1)
        sat_count = 1
      else
        prev = sat_entry_offset(sat_count - 1)
        set_word(prev + 0x02, get_word(prev + 0x02) & 0xFF00)
      end

      dma = dma_entry_offset(inc_dma_commands_count)
      set_word(dma + 0x00, 0x8F02)
      word_size = (get_word(SAT_COUNT_OFFSET) * 4) & 0xFFFF
      set_word(dma + 0x02, 0x9400 + (word_size >> 8))
      set_word(dma + 0x04, 0x9300 + (word_size & 0xFF))
      sat_addr = SAT_OFFSET / 2
      set_word(dma + 0x06, 0x9700 + ((sat_addr >> 16) & 0xFF))
      set_word(dma + 0x08, 0x9600 + ((sat_addr >> 8) & 0xFF))
      set_word(dma + 0x0A, 0x9500 + (sat_addr & 0xFF))
      set_word(dma + 0x0C, 0x7000)
      set_word(dma + 0x0E, 0x0083)
    end

    def obj_render(obj_slot)
      return if obj_slot >= OBJECTS_COUNT || @anim_data_base_addr.zero?

      obj = obj_entry_offset(obj_slot)
      obj_id = get_word(obj + 0x04)
      anim = get_word(obj + 0x00)
      return if (anim & 0xFF) > @anim_max_index[obj_id & 0xFF].to_i

      handle = @object_handles[obj_slot]
      previous_offset = handle[:anim_offset]
      previous_counter = handle[:counter]
      anim_counter = get_word(obj + 0x0A)

      if (obj_id & 0x8000) != 0 || anim != handle[:current_anim] || anim_counter != handle[:counter]
        if (obj_id & 0x8000) != 0
          previous_offset = 0
          previous_counter = 1
        end
        offset = read_anim_u32((obj_id & 0xFF) + 1)
        offset = read_anim_u32((offset >> 2) + (anim & 0xFF))
        data_offset = read_anim_u32(offset >> 2) & 0x00FF_FFFF
        handle[:anim_offset] = offset
        handle[:current_anim] = anim
        handle[:counter] = anim_counter
      else
        offset = handle[:anim_offset]
        return if offset.zero?

        data_offset = read_anim_u32(offset >> 2)
        if (data_offset & 0x8000_0000) != 0
          offset += 4
        else
          next_anim = get_word(obj + 0x02)
          if next_anim != 0xFFFF
            set_word(obj + 0x00, next_anim)
            set_word(obj + 0x02, 0xFFFF)
            obj_render(obj_slot)
            return
          end
          offset = read_anim_u32((offset + 4) >> 2) & 0x00FF_FFFF
        end
        return if offset.zero?

        handle[:anim_offset] = offset
        data_offset = read_anim_u32(offset >> 2) & 0x00FF_FFFF
        set_word(obj + 0x0A, anim_counter + 1)
        handle[:counter] += 1
      end

      sprite_base = @anim_data_base_addr + data_offset
      count = raw_sdram_byte(sprite_base + 1)
      pos_x = signed16(get_word(obj + 0x0C))
      pos_y = signed16(get_word(obj + 0x0E))
      attrs_obj = get_word(obj + 0x08)
      blocks_available = true

      0.upto(count - 1) do |i|
        spr = sprite_base + 2 + (i * 8)
        block_num = read_sdram_word_at_raw_struct(spr + 4)
        next if block_num.zero?

        blocks_available = false if vram_load_block(block_num).zero?
      end

      unless blocks_available
        return if previous_offset.zero?

        handle[:anim_offset] = previous_offset
        handle[:counter] = previous_counter
        set_word(obj + 0x0A, previous_counter)
        data_offset = read_anim_u32(previous_offset >> 2) & 0x00FF_FFFF
        sprite_base = @anim_data_base_addr + data_offset
        count = raw_sdram_byte(sprite_base + 1)
      end

      0.upto(count - 1) do |i|
        spr = sprite_base + 2 + (i * 8)
        rel_y = signed8(raw_sdram_byte(spr))
        rel_x = signed8(raw_sdram_byte(spr + 1))
        flip_rel_x = signed8(raw_sdram_byte(spr + 2))
        size = raw_sdram_byte(spr + 3)
        block_num = read_sdram_word_at_raw_struct(spr + 4)
        offset_tile = raw_sdram_byte(spr + 6)
        attrs = raw_sdram_byte(spr + 7)

        pos_x += (attrs_obj & 0x0800) != 0 ? flip_rel_x : rel_x
        pos_y += rel_y
        next if block_num.zero?

        width = (((size >> 2) & 0x3) + 1) * 8
        height = ((size & 0x3) + 1) * 8
        next if pos_x >= 448 || pos_y >= 368 || pos_x < 128 - width || pos_y < 128 - height

        sat_count = get_word(SAT_COUNT_OFFSET)
        break if sat_count >= 144

        next_count = sat_count + 1
        set_word(SAT_COUNT_OFFSET, next_count)
        sat = sat_entry_offset(sat_count)
        set_word(sat + 0x06, pos_x & 0x01FF)
        set_word(sat + 0x00, pos_y & 0x03FF)
        set_word(sat + 0x02, ((size & 0x0F) << 8) | (next_count & 0xFF))
        set_word(sat + 0x04, (((attrs & 0xF8) << 8) ^ attrs_obj ^ (vram_find_block(block_num) + offset_tile)))
      end

      set_word(obj + 0x04, obj_id & 0x7FFF)
    end

    def stamp_rescale(window_start, window_end, factor, stamp_offset)
      scaled = Array.new(128 * 32, 0)
      offset = stamp_offset.to_f
      adder = factor / 64.0
      y = window_start
      while y < window_end && y < 128
        src_y = [[offset.to_i, 0].max, 63].min
        32.times { |x| scaled[(y * 32) + x] = @scale_stamp[(src_y * 32) + x] || 0 }
        y += 1
        offset += adder
      end

      32.times do |s|
        column = ((s & 0xFE) << 4) + ((s & 1) << 9)
        32.times do |yy|
          word = ((((scaled[(((s << 2) + 0) * 32) + (yy ^ 1)].to_i & 0xF0) |
                    (scaled[(((s << 2) + 1) * 32) + (yy ^ 1)].to_i & 0x0F)) << 8) |
                  ((scaled[(((s << 2) + 2) * 32) + (yy ^ 1)].to_i & 0xF0) |
                    (scaled[(((s << 2) + 3) * 32) + (yy ^ 1)].to_i & 0x0F)))
          set_word(0x200 + ((column + yy) * 2), word)
        end
      end
    end

    def load_eeprom_block(block)
      dest = get_command_arg(0)
      case block
      when 1, 2, 3
        copy_words(@nvram, (0x200 + block * 0x200) / 2, @dual_port, dest / 2, 0x100 / 2)
      when 4
        copy_words(@nvram, 0, @dual_port, dest / 2, 0x200 / 2)
      end
    end

    def save_eeprom_block(block)
      src = get_command_arg(1)
      case block
      when 1, 2, 3
        copy_words(@dual_port, src / 2, @nvram, (0x200 + block * 0x200) / 2, 0x100 / 2)
      when 4
        copy_words(@dual_port, src / 2, @nvram, 0, 0x200 / 2)
      end
      set_word(REG_STATUS2_OFFSET, get_word(REG_STATUS2_OFFSET) & ~STATUS2_EEPROM_ERROR1 & ~STATUS2_EEPROM_ERROR2)
      save_nvram
    end

    def block_addr(num)
      (@gfx_blocks_base_addr + swap_shorts(read_rom_u32_at_raw_struct(@gfx_blocks_base_addr + (num * 4)))) & 0xFFFF_FFFF
    end

    def bgm_addr(num)
      (@bgm_tracks_base_addr + swap_shorts(read_rom_u32_at_raw_struct(@bgm_tracks_base_addr + (num * 4)))) & 0xFFFF_FFFF
    end

    def read_anim_u32(index)
      read_sdram_u32(@anim_data_base_addr + (index * 4))
    end

    def read_sdram_u32(byte_addr)
      ((read_sdram_word(byte_addr + 2) << 16) | read_sdram_word(byte_addr)) & 0xFFFF_FFFF
    end

    def read_sdram_word(byte_addr)
      index = byte_addr >> 1
      index >= 0 && index < @sdram.length ? (@sdram[index] & 0xFFFF) : 0
    end

    def read_sdram_word_at_raw_struct(byte_addr)
      (raw_sdram_byte(byte_addr) | (raw_sdram_byte(byte_addr + 1) << 8)) & 0xFFFF
    end

    def read_rom_u32_at_raw_struct(byte_addr)
      (rom_raw_byte(byte_addr) |
        (rom_raw_byte(byte_addr + 1) << 8) |
        (rom_raw_byte(byte_addr + 2) << 16) |
        (rom_raw_byte(byte_addr + 3) << 24)) & 0xFFFF_FFFF
    end

    def get_command_arg(index)
      get_word(COMMAND_ARGS_OFFSET + (index * 2))
    end

    def get_command_arg_long(index)
      offset = COMMAND_ARGS_OFFSET + (index * 4)
      (get_word(offset) | (get_word(offset + 2) << 16)) & 0xFFFF_FFFF
    end

    def inc_dma_commands_count
      count = get_word(DMA_COMMANDS_COUNT_OFFSET)
      set_word(DMA_COMMANDS_COUNT_OFFSET, count + 1)
      count
    end

    def dma_entry_offset(index) = DMA_COMMANDS_OFFSET + (index * 16)
    def sat_entry_offset(index) = SAT_OFFSET + (index * 8)
    def obj_entry_offset(index) = OBJ_OFFSET + (index * 16)

    def get_word(byte_offset)
      index = byte_offset >> 1
      index >= 0 && index < @dual_port.length ? (@dual_port[index] & 0xFFFF) : 0
    end

    def set_word(byte_offset, value)
      index = byte_offset >> 1
      return unless index >= 0 && index < @dual_port.length

      @dual_port[index] = value & 0xFFFF
    end

    def decode_and_patch_once
      return if @decoded || @rom_words.length < 0x800000 / 2

      if @rom_words[0x8000 / 2] != 0
        key1 = @rom_words[0x8000 / 2]
        key2 = @rom_words[0xBD000 / 2]
        (0x2000 / 2).upto((0x10000 / 2) - 1) do |addr|
          @rom_words[addr] = (@rom_words[addr] ^ (key1 | bitswap_paprium(addr & 0xFF))) & 0xFFFF
        end
        (0x10000 / 2).upto((0x800000 / 2) - 1) do |addr|
          @rom_words[addr] = (@rom_words[addr] ^ (key2 | bitswap_paprium(addr & 0xFF))) & 0xFFFF
        end
      end

      warn format('[PAPRIUM] unknown version 0x%04X', @rom_words[0x1000A / 2]) if @trace && @rom_words.length > 0x1000A / 2 && @rom_words[0x1000A / 2] != 0x2E7F
      @decoded = true
    end

    def restore_boot_dual_port
      count = [@dual_port.length, @rom_words.length].min
      0.upto(count - 1) { |idx| @dual_port[idx] = @rom_words[idx] & 0xFFFF }
    end

    def apply_version_patches
      return if @rom_words.length <= 0x81104 / 2 || @rom_words[0x1000A / 2] != 0x2E7F

      set_word(0x1D1C, 0x0004)
      set_word(0x1D2C, get_word(0x1D2C) | 0x0100)
      set_word(0x1560, 0x4EF9)
      set_word(0x1562, 0x0001)
      set_word(0x1564, 0x0100)
      @rom_words[0x81104 / 2] = 0x4E71
    end

    def bitswap_paprium(value)
      bits = [15, 1, 14, 6, 13, 2, 12, 0, 11, 3, 10, 4, 9, 7, 8, 5]
      result = 0
      bits.each_with_index { |bit, index| result |= ((value >> bit) & 1) << (15 - index) }
      result & 0xFFFF
    end

    def rom_packed_byte(logical_byte_addr)
      rom_raw_byte(logical_byte_addr ^ 1)
    end

    def rom_raw_byte(raw_byte_addr)
      index = raw_byte_addr >> 1
      return 0xFF unless index >= 0 && index < @rom_words.length

      value = @rom_words[index] & 0xFFFF
      raw_byte_addr.even? ? (value & 0xFF) : ((value >> 8) & 0xFF)
    end

    def packed_read_byte(logical_byte_addr, scale_stamp)
      raw = logical_byte_addr ^ 1
      return raw < @scale_stamp.length ? @scale_stamp[raw] : 0 if scale_stamp

      raw_read_byte(@sdram, raw)
    end

    def packed_write_byte(logical_byte_addr, value, scale_stamp)
      raw = logical_byte_addr ^ 1
      if scale_stamp
        @scale_stamp[raw] = value & 0xFF if raw < @scale_stamp.length
      else
        raw_write_byte(@sdram, raw, value)
      end
    end

    def raw_sdram_byte(raw_byte_addr)
      raw_read_byte(@sdram, raw_byte_addr)
    end

    def cpu_read_byte(words, byte_address)
      raw_read_byte(words, byte_address ^ 1)
    end

    def raw_read_byte(words, raw_byte_address)
      index = raw_byte_address >> 1
      return 0xFF unless index >= 0 && index < words.length

      value = words[index] & 0xFFFF
      raw_byte_address.even? ? (value & 0xFF) : ((value >> 8) & 0xFF)
    end

    def raw_write_byte(words, raw_byte_address, value)
      index = raw_byte_address >> 1
      return unless index >= 0 && index < words.length

      old = words[index] & 0xFFFF
      words[index] = if raw_byte_address.even?
                       (old & 0xFF00) | (value & 0xFF)
                     else
                       (old & 0x00FF) | ((value & 0xFF) << 8)
                     end
    end

    def read_word_from(words, byte_offset)
      index = byte_offset >> 1
      index >= 0 && index < words.length ? (words[index] & 0xFFFF) : 0xFFFF
    end

    def to_words(rom_bytes)
      word_count = [0x800000 / 2, (rom_bytes.length + 1) / 2].max
      Array.new(word_count) do |idx|
        pos = idx * 2
        hi = pos < rom_bytes.length ? rom_bytes[pos].to_i : 0xFF
        lo = pos + 1 < rom_bytes.length ? rom_bytes[pos + 1].to_i : 0xFF
        ((hi << 8) | lo) & 0xFFFF
      end
    end

    def swap_shorts(value)
      (((value & 0xFFFF0000) >> 16) | ((value & 0x0000FFFF) << 16)) & 0xFFFF_FFFF
    end

    def copy_words(source, source_index, dest, dest_index, count)
      return if source_index.negative? || dest_index.negative? || count <= 0

      copy = [count, source.length - source_index, dest.length - dest_index].min
      return unless copy.positive?

      0.upto(copy - 1) { |idx| dest[dest_index + idx] = source[source_index + idx] & 0xFFFF }
    end

    def load_nvram
      return unless @save_path && File.exist?(@save_path)

      data = File.binread(@save_path).bytes
      words = [@nvram.length, data.length / 2].min
      0.upto(words - 1) { |idx| @nvram[idx] = ((data[idx * 2] << 8) | data[idx * 2 + 1]) & 0xFFFF }
    rescue SystemCallError
    end

    def save_nvram
      return unless @save_path

      bytes = @nvram.flat_map { |word| [(word >> 8) & 0xFF, word & 0xFF] }
      File.binwrite(@save_path, bytes.pack('C*'))
    rescue SystemCallError
    end

    def build_save_path(source_path)
      return nil if source_path.nil? || source_path.empty?

      File.join(File.dirname(source_path), "#{File.basename(source_path, '.*')}.paprium.srm")
    end

    def signed8(value)
      value &= 0xFF
      value >= 0x80 ? value - 0x100 : value
    end

    def signed16(value)
      value &= 0xFFFF
      value >= 0x8000 ? value - 0x10000 : value
    end
  end
end
