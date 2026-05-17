require 'ffi'

module AstralVerse
  module SDL3
    extend FFI::Library
    ffi_lib 'SDL3'

    INIT_VIDEO = 0x00000020
    INIT_AUDIO = 0x00000010
    INIT_EVENTS = 0x00004000

    WINDOW_FULLSCREEN = 0x0000000000000001
    WINDOW_RESIZABLE = 0x0000000000000020
    WINDOW_HIGH_PIXEL_DENSITY = 0x0000000000002000

    PIXELFORMAT_RGBA32 = 0x16762004
    TEXTUREACCESS_STREAMING = 1
    SCALEMODE_NEAREST = 0
    RENDERER_VSYNC_DISABLED = 0
    AUDIO_S16 = 0x8010
    AUDIO_DEVICE_DEFAULT_PLAYBACK = 0xFFFFFFFF

    EVENT_QUIT = 0x100
    EVENT_KEY_DOWN = 0x300
    EVENT_KEY_UP = 0x301
    EVENT_MOUSE_MOTION = 0x400
    EVENT_MOUSE_BUTTON_DOWN = 0x401
    EVENT_MOUSE_WHEEL = 0x403

    BUTTON_LEFT = 1

    K_RETURN = 0x0000000d
    K_ESCAPE = 0x0000001b
    K_SPACE = 0x00000020
    K_A = 0x00000061
    K_R = 0x00000072
    K_S = 0x00000073
    K_X = 0x00000078
    K_Z = 0x0000007a
    K_F5 = 0x4000003e
    K_F9 = 0x40000042
    K_F11 = 0x40000044
    K_RIGHT = 0x4000004f
    K_LEFT = 0x40000050
    K_DOWN = 0x40000051
    K_UP = 0x40000052

    class FRect < FFI::Struct
      layout :x, :float,
        :y, :float,
        :w, :float,
        :h, :float
    end

    class Color < FFI::Struct
      layout :r, :uint8,
        :g, :uint8,
        :b, :uint8,
        :a, :uint8
    end

    class AudioSpec < FFI::Struct
      layout :format, :uint32,
        :channels, :int,
        :freq, :int
    end

    class Surface < FFI::Struct
      layout :flags, :uint32,
        :format, :uint32,
        :w, :int,
        :h, :int,
        :pitch, :int,
        :pixels, :pointer,
        :refcount, :int,
        :reserved, :pointer
    end

    attach_function :init, :SDL_Init, [:uint32], :bool
    attach_function :quit, :SDL_Quit, [], :void
    attach_function :get_error, :SDL_GetError, [], :string
    attach_function :get_ticks, :SDL_GetTicks, [], :uint64
    attach_function :delay, :SDL_Delay, [:uint32], :void

    attach_function :create_window, :SDL_CreateWindow, [:string, :int, :int, :uint64], :pointer
    attach_function :destroy_window, :SDL_DestroyWindow, [:pointer], :void
    attach_function :set_window_fullscreen, :SDL_SetWindowFullscreen, [:pointer, :bool], :bool
    attach_function :get_window_size, :SDL_GetWindowSize, [:pointer, :pointer, :pointer], :bool

    attach_function :create_renderer, :SDL_CreateRenderer, [:pointer, :string], :pointer
    attach_function :destroy_renderer, :SDL_DestroyRenderer, [:pointer], :void
    attach_function :set_render_vsync, :SDL_SetRenderVSync, [:pointer, :int], :bool
    attach_function :get_render_output_size, :SDL_GetRenderOutputSize, [:pointer, :pointer, :pointer], :bool
    attach_function :set_render_draw_color, :SDL_SetRenderDrawColor, [:pointer, :uint8, :uint8, :uint8, :uint8], :bool
    attach_function :render_clear, :SDL_RenderClear, [:pointer], :bool
    attach_function :render_present, :SDL_RenderPresent, [:pointer], :bool
    attach_function :render_fill_rect, :SDL_RenderFillRect, [:pointer, FRect.by_ref], :bool

    attach_function :create_texture, :SDL_CreateTexture, [:pointer, :uint32, :int, :int, :int], :pointer
    attach_function :destroy_texture, :SDL_DestroyTexture, [:pointer], :void
    attach_function :update_texture, :SDL_UpdateTexture, [:pointer, :pointer, :pointer, :int], :bool
    attach_function :render_texture, :SDL_RenderTexture, [:pointer, :pointer, :pointer, FRect.by_ref], :bool
    attach_function :create_texture_from_surface, :SDL_CreateTextureFromSurface, [:pointer, :pointer], :pointer
    attach_function :set_texture_scale_mode, :SDL_SetTextureScaleMode, [:pointer, :int], :bool
    attach_function :destroy_surface, :SDL_DestroySurface, [:pointer], :void

    attach_function :poll_event, :SDL_PollEvent, [:pointer], :bool
    attach_function :hide_cursor, :SDL_HideCursor, [], :bool
    attach_function :show_cursor, :SDL_ShowCursor, [], :bool

    attach_function :open_audio_device_stream, :SDL_OpenAudioDeviceStream, [:uint32, AudioSpec.by_ref, :pointer, :pointer], :pointer
    attach_function :resume_audio_stream_device, :SDL_ResumeAudioStreamDevice, [:pointer], :bool
    attach_function :destroy_audio_stream, :SDL_DestroyAudioStream, [:pointer], :void
    attach_function :put_audio_stream_data, :SDL_PutAudioStreamData, [:pointer, :pointer, :int], :bool
    attach_function :get_audio_stream_queued, :SDL_GetAudioStreamQueued, [:pointer], :int
    attach_function :clear_audio_stream, :SDL_ClearAudioStream, [:pointer], :bool

    def self.check(pointer_or_bool, label)
      ok = pointer_or_bool.is_a?(FFI::Pointer) ? !pointer_or_bool.null? : pointer_or_bool
      raise "#{label}: #{get_error}" unless ok

      pointer_or_bool
    end
  end

  module SDL3TTF
    extend FFI::Library
    ffi_lib 'SDL3_ttf'

    attach_function :init, :TTF_Init, [], :bool
    attach_function :quit, :TTF_Quit, [], :void
    attach_function :open_font, :TTF_OpenFont, [:string, :float], :pointer
    attach_function :close_font, :TTF_CloseFont, [:pointer], :void
    attach_function :get_string_size, :TTF_GetStringSize, [:pointer, :string, :size_t, :pointer, :pointer], :bool
    attach_function :render_text_blended, :TTF_RenderText_Blended, [:pointer, :string, :size_t, SDL3::Color.by_value], :pointer
  end
end
