module MegaDrive
  class Audio
    CLOCK = 3_584_160.0
    SAMPLE_RATE = 44_100
    PSG_GAIN = 0.35
    YM_GAIN = 0.75
    YM_FRAME_CYCLE_RATIO = MegaDrive::YM2612::CLOCK / CLOCK

    def initialize(psg, ym2612)
      @psg = psg
      @ym2612 = ym2612
    end

    def begin_frame
      @psg.begin_frame
      @ym2612.begin_frame
    end

    def render_frame_samples(count, frame_cycles, sample_rate = SAMPLE_RATE)
      psg_samples = @psg.render_frame_samples(count, frame_cycles, sample_rate)
      ym_samples = @ym2612.render_frame_samples(count, frame_cycles * YM_FRAME_CYCLE_RATIO, sample_rate)

      Array.new(count) do |index|
        ym_l, ym_r = ym_samples[index]
        psg = psg_samples[index].to_f
        (((ym_l + ym_r) * 0.5 * YM_GAIN) + (psg * PSG_GAIN)).clamp(-1.0, 1.0)
      end
    end
  end
end
