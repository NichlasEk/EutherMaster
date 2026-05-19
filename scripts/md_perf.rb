#!/usr/bin/env ruby

if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable) && !RubyVM::YJIT.enabled?
  RubyVM::YJIT.enable
end

require 'optparse'
require_relative '../lib/astral_verse'
require_relative '../lib/astral_verse/audio/psg_player'

options = {
  frames: 600,
  warmup: 60,
  hotspots: true,
  opcodes: true,
  audio_render: true
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} ROM_PATH [--state PATH] [--frames N] [--warmup N]"
  opts.on('--state PATH', 'Load a GemShard state instead of cold boot') { |value| options[:state] = value }
  opts.on('--frames N', Integer, 'Measured frames') { |value| options[:frames] = value }
  opts.on('--warmup N', Integer, 'Warmup frames before measuring') { |value| options[:warmup] = value }
  opts.on('--[no-]hotspots', 'Collect M68K PC hotspots') { |value| options[:hotspots] = value }
  opts.on('--[no-]opcodes', 'Collect M68K opcode hotspots') { |value| options[:opcodes] = value }
  opts.on('--[no-]audio-render', 'Include audio sample rendering in wall timing') { |value| options[:audio_render] = value }
end
parser.parse!

rom_path = ARGV[0]
state_path = options[:state]
if state_path
  abort "State not found: #{state_path}" unless File.exist?(state_path)
elsif !rom_path || !File.exist?(rom_path)
  abort parser.to_s
end

stone = AstralVerse::ScryingStone.new
if state_path
  stone.load_snapshot(state_path)
  rom_path ||= stone.crystal_vault.relic_path || state_path
else
  stone.absorb_codex(rom_path)
end

unless stone.emulator.is_a?(MegaDrive::Emulator)
  abort "Loaded emulator is #{stone.emulator.class}, expected MegaDrive::Emulator"
end

pc_hits = Hash.new(0)
opcode_hits = Hash.new(0)
if options[:hotspots] || options[:opcodes]
  cpu = stone.emulator.cpu
  class << cpu
    attr_accessor :md_perf_pc_hits, :md_perf_opcode_hits
    alias md_perf_original_step step unless method_defined?(:md_perf_original_step)

    def step
      pc = @pc
      @md_perf_pc_hits[pc] += 1 if @md_perf_pc_hits
      if @md_perf_opcode_hits && @bus
        begin
          @md_perf_opcode_hits[@bus.read_word(pc) & 0xFFFF] += 1
        rescue StandardError
          nil
        end
      end
      md_perf_original_step
    end
  end
  cpu.md_perf_pc_hits = options[:hotspots] ? pc_hits : nil
  cpu.md_perf_opcode_hits = options[:opcodes] ? opcode_hits : nil
end

def render_audio_frame(emulator, audio_credit)
  audio = emulator.psg
  audio_frame_cycles = audio.respond_to?(:frame_cycles) ? audio.frame_cycles : AstralVerse::PsgPlayer::FRAME_CYCLES
  audio_clock = audio.respond_to?(:clock) ? audio.clock : audio.class::CLOCK
  audio_credit += AstralVerse::PsgPlayer::SAMPLE_RATE * audio_frame_cycles / audio_clock
  sample_count = audio_credit.floor
  audio_credit -= sample_count
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  audio.render_frame_samples(sample_count, audio_frame_cycles, AstralVerse::PsgPlayer::SAMPLE_RATE)
  [audio_credit, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, sample_count]
end

options[:warmup].times { stone.gaze_frame }
stone.emulator.reset_perf
pc_hits.clear
opcode_hits.clear

audio_credit = 0.0
audio_seconds = 0.0
audio_samples = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
options[:frames].times do
  stone.gaze_frame
  next unless options[:audio_render]

  audio_credit, seconds, samples = render_audio_frame(stone.emulator, audio_credit)
  audio_seconds += seconds
  audio_samples += samples
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
perf = stone.emulator.perf_summary
target_fps = stone.emulator.frame_rate
wall_fps = options[:frames] / elapsed

puts "ROM: #{File.basename(rom_path)}"
puts "State: #{state_path}" if state_path
puts "Warmup frames: #{options[:warmup]}"
puts "Measured frames: #{options[:frames]}"
puts "Target: %.2f fps" % target_fps
puts "Wall FPS: %.2f" % wall_fps
puts "Headroom: %.2f fps" % (wall_fps - target_fps)
puts "Emu FPS: %.2f" % perf[:fps]
puts "Avg frame: %.2f ms" % perf[:avg_frame_ms]
puts "Avg CPU: %.2f ms" % perf[:avg_cpu_ms]
puts "Avg VDP: %.2f ms" % perf[:avg_vdp_ms]
puts "Avg CPU steps/frame: %.0f" % perf[:avg_cpu_steps]
if options[:audio_render]
  realtime = audio_seconds.positive? ? (audio_samples.to_f / AstralVerse::PsgPlayer::SAMPLE_RATE) / audio_seconds : 0.0
  puts "Avg audio render: %.2f ms" % ((audio_seconds / options[:frames]) * 1000.0)
  puts "Audio render realtime: %.1fx" % realtime
end

cpu = stone.emulator.cpu
stack_pointer = cpu.respond_to?(:sp) ? cpu.sp : cpu.a[7]
puts "PC: %06X  SP: %06X  Cycles: %d" % [cpu.pc, stack_pointer, cpu.total_cycles]
puts "VDP regs: #{stone.emulator.vdp.registers.map { |value| '%02X' % value }.join(' ')}"

if options[:hotspots]
  puts "M68K PC hotspots:"
  pc_hits.sort_by { |_pc, count| -count }.first(24).each do |pc, count|
    puts "  %06X  %d" % [pc, count]
  end
end

if options[:opcodes]
  puts "M68K opcode hotspots:"
  opcode_hits.sort_by { |_opcode, count| -count }.first(24).each do |opcode, count|
    puts "  %04X  %d" % [opcode, count]
  end
end
