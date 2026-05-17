module AstralVerse
  module RomDetector
    HEADER_READ_SIZE = 0x8200
    SMS_SIGNATURE = 'TMR SEGA'.bytes.freeze
    SMS_EXTENSIONS = ['.sms'].freeze
    GG_EXTENSIONS = ['.gg'].freeze
    MD_EXTENSIONS = ['.md', '.gen', '.smd'].freeze
    GENERIC_ROM_EXTENSIONS = ['.bin', '.rom'].freeze
    ROM_EXTENSIONS = (SMS_EXTENSIONS + GG_EXTENSIONS + MD_EXTENSIONS + GENERIC_ROM_EXTENSIONS).freeze

    Info = Struct.new(:system, :format, :path, :name, :header_offset, :copier_header, keyword_init: true) do
      def master_system? = system == :sms
      def game_gear? = system == :game_gear
      def mega_drive? = system == :mega_drive
      def sms_family? = master_system? || game_gear?

      def label
        case system
        when :mega_drive then 'MD'
        when :game_gear then 'GG'
        when :sms then 'SMS'
        else 'ROM'
        end
      end
    end

    module_function

    def rom_extension?(filename)
      ROM_EXTENSIONS.include?(File.extname(filename).downcase)
    end

    def detect_file(path)
      detect(File.binread(path, HEADER_READ_SIZE).bytes, path: path)
    rescue SystemCallError
      nil
    end

    def detect(data, path: nil)
      bytes = data.is_a?(String) ? data.bytes : data
      ext = path ? File.extname(path).downcase : ''
      name = path ? File.basename(path) : nil

      md_offset = mega_drive_header_offset(bytes)
      if md_offset
        return Info.new(system: :mega_drive, format: :mega_drive, path: path, name: name,
          header_offset: md_offset, copier_header: md_offset >= 0x300)
      end

      sms_offset = sms_header_offset(bytes)
      if sms_offset
        return Info.new(system: sms_system_from_header(bytes, sms_offset, ext), format: :sms_family,
          path: path, name: name, header_offset: sms_offset, copier_header: [0x81F0, 0x41F0, 0x21F0].include?(sms_offset))
      end

      system = system_from_extension(ext)
      return nil unless system

      Info.new(system: system, format: system == :mega_drive ? :mega_drive : :sms_family,
        path: path, name: name, header_offset: nil, copier_header: false)
    end

    def system_from_extension(ext)
      return :mega_drive if MD_EXTENSIONS.include?(ext)
      return :game_gear if GG_EXTENSIONS.include?(ext)
      return :sms if SMS_EXTENSIONS.include?(ext)

      nil
    end

    def mega_drive_header_offset(bytes)
      return 0x100 if sega_text_at?(bytes, 0x100)
      return 0x300 if sega_text_at?(bytes, 0x300)

      nil
    end

    def sega_text_at?(bytes, offset)
      bytes.length >= offset + 4 && bytes[offset, 4].pack('C*') == 'SEGA'
    end

    def sms_header_offset(bytes)
      [0x7FF0, 0x3FF0, 0x1FF0, 0x81F0, 0x41F0, 0x21F0].find do |offset|
        bytes.length >= offset + SMS_SIGNATURE.length && bytes[offset, SMS_SIGNATURE.length] == SMS_SIGNATURE
      end
    end

    def sms_system_from_header(bytes, offset, ext)
      return :game_gear if GG_EXTENSIONS.include?(ext)
      return :sms if SMS_EXTENSIONS.include?(ext)

      region = ((bytes[offset + 15] || 0) >> 4) & 0x0F
      [0x5, 0x6, 0x7].include?(region) ? :game_gear : :sms
    end
  end
end
