require_relative '../sms_emulator/audio/psg'

module MegaDrive
  class PSG < SmsEmulator::PSG
    CLOCK = 3_579_545.0
  end
end
