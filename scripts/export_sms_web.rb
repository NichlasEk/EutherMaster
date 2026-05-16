#!/usr/bin/env ruby

require 'fileutils'
require 'json'
require 'time'
require 'uri'

project_root = File.expand_path('..', __dir__)
destination = File.expand_path(ENV.fetch('SMS_WEB_EXPORT', '/home/nichlas/SMSWEB'))
rom_dir = File.join(destination, 'roms')

FileUtils.mkdir_p(destination)
FileUtils.mkdir_p(rom_dir)

FileUtils.rm_rf(File.join(destination, 'web'))
FileUtils.rm_rf(File.join(destination, 'lib', 'sms_emulator'))
FileUtils.mkdir_p(File.join(destination, 'lib'))

FileUtils.cp_r(File.join(project_root, 'web'), File.join(destination, 'web'))
FileUtils.cp_r(File.join(project_root, 'lib', 'sms_emulator'), File.join(destination, 'lib', 'sms_emulator'))

roms = Dir.children(rom_dir)
  .select { |name| File.file?(File.join(rom_dir, name)) && name.match?(/\.(sms|bin)\z/i) }
  .sort
  .first(4)
  .map do |name|
    encoded = URI.encode_www_form_component(name).gsub('+', '%20')
    {
      name: name,
      path: "/roms/#{encoded}",
      size: File.size(File.join(rom_dir, name))
    }
  end

manifest = {
  generated_at: Time.now.utc.iso8601,
  roms: roms
}

File.write(File.join(rom_dir, 'manifest.json'), JSON.pretty_generate(manifest))

puts "Exported SMS web bundle to #{destination}"
puts "ROM directory: #{rom_dir}"
puts "ROM buttons: #{roms.empty? ? 'none yet' : roms.map { |rom| rom[:name] }.join(', ')}"
