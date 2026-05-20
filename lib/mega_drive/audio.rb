module MegaDrive
  class Audio
    CLOCK = MegaDrive::PSG::CLOCK
    SAMPLE_RATE = 44_100
    PSG_GAIN = 0.35
    YM_GAIN = 0.75
    PSG_FILTER_ALPHA = ENV.fetch('ASTRAL_MD_PSG_FILTER', '0.38').to_f.clamp(0.05, 1.0)
    YM_FRAME_CYCLES = 127_800.0
    YM_RENDER_RATE = ENV.fetch('ASTRAL_MD_YM_RATE', '22050').to_i.clamp(11_025, SAMPLE_RATE)

    attr_accessor :frame_cycles, :ym_frame_cycles, :paprium_audio

    def initialize(psg, ym2612)
      @psg = psg
      @ym2612 = ym2612
      @frame_cycles = MegaDrive::PSG::CLOCK / 60.0
      @ym_frame_cycles = YM_FRAME_CYCLES
      @psg_filter_state = 0.0
    end

    def begin_frame
      @psg.begin_frame
      @ym2612.begin_frame
    end

    def render_frame_samples(count, frame_cycles, sample_rate = SAMPLE_RATE)
      psg_samples = @psg.render_frame_samples(count, frame_cycles, sample_rate)
      filter_psg_samples!(psg_samples)
      ym_samples = render_ym_samples(count, sample_rate)

      Array.new(count) do |index|
        psg = psg_samples[index].to_f
        ((ym_samples[index] * YM_GAIN) + (psg * PSG_GAIN)).clamp(-1.0, 1.0)
      end.tap { |samples| @paprium_audio&.mix_music_into(samples, count, sample_rate) }
    end

    def capture_frame_job(count, frame_cycles, sample_rate = SAMPLE_RATE)
      {
        count: count,
        frame_cycles: frame_cycles,
        sample_rate: sample_rate,
        psg: @psg.capture_frame_job,
        ym2612: @ym2612.capture_frame_job,
        paprium: @paprium_audio&.capture_audio_samples(count, sample_rate)
      }
    end

    def async_renderer
      self.class.new(@psg.class.new, @ym2612.class.new)
    end

    def render_frame_job(job)
      count = job[:count]
      sample_rate = job[:sample_rate] || SAMPLE_RATE
      psg_samples = @psg.render_frame_job(job[:psg], count, job[:frame_cycles], sample_rate)
      filter_psg_samples!(psg_samples)
      ym_samples = render_ym_job_samples(job[:ym2612], count, sample_rate)

      Array.new(count) do |index|
        psg = psg_samples[index].to_f
        ((ym_samples[index] * YM_GAIN) + (psg * PSG_GAIN)).clamp(-1.0, 1.0)
      end.tap { |samples| mix_paprium_job_samples!(samples, job[:paprium]) }
    end

    def filter_psg_samples!(samples)
      state = @psg_filter_state || 0.0
      alpha = PSG_FILTER_ALPHA
      index = 0
      while index < samples.length
        state += (samples[index].to_f - state) * alpha
        samples[index] = state
        index += 1
      end
      @psg_filter_state = state
      samples
    end

    def clock
      CLOCK
    end

    private

    def mix_paprium_job_samples!(samples, paprium_samples)
      return samples unless paprium_samples

      limit = [samples.length, paprium_samples.length].min
      index = 0
      while index < limit
        samples[index] = (samples[index].to_f + paprium_samples[index].to_f).clamp(-1.0, 1.0)
        index += 1
      end
      samples
    end

    def render_ym_samples(count, sample_rate)
      ym_rate = [YM_RENDER_RATE, sample_rate].min
      return @ym2612.render_frame_mono_samples(count, @ym_frame_cycles, sample_rate) if ym_rate == sample_rate

      ym_count = [(count * ym_rate / sample_rate.to_f).ceil, 1].max
      upsample(@ym2612.render_frame_mono_samples(ym_count, @ym_frame_cycles, ym_rate), count)
    end

    def render_ym_job_samples(job, count, sample_rate)
      ym_rate = [YM_RENDER_RATE, sample_rate].min
      return @ym2612.render_frame_mono_job(job, count, @ym_frame_cycles, sample_rate) if ym_rate == sample_rate

      ym_count = [(count * ym_rate / sample_rate.to_f).ceil, 1].max
      upsample(@ym2612.render_frame_mono_job(job, ym_count, @ym_frame_cycles, ym_rate), count)
    end

    def upsample(samples, count)
      return samples if samples.length == count
      return Array.new(count, samples[0] || 0.0) if samples.length == 1

      output = Array.new(count, 0.0)
      scale = (samples.length - 1).to_f / [count - 1, 1].max
      index = 0
      while index < count
        position = index * scale
        left = position.to_i
        right = left + 1
        right = left if right >= samples.length
        fraction = position - left
        output[index] = samples[left] + (samples[right] - samples[left]) * fraction
        index += 1
      end
      output
    end

  end
end
