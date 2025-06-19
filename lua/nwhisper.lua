-- nwhisper.lua
local M = {}
local job_id = nil
local record_job_id = nil
local record_temp_file = nil

--- Detect operating system
local function is_windows()
  return package.config:sub(1,1) == '\\'
end

--- List available audio devices (uses ffmpeg on Windows, arecord on Linux).
M.list_audio_devices = function()
  local cmd
  local is_win = is_windows()
  
  if is_win then
    cmd = 'ffmpeg -list_devices true -f dshow -i dummy 2>&1'
  else
    -- Use arecord to list ALSA capture devices on Linux
    cmd = 'arecord -l 2>&1'
  end
  
  -- Use vim.fn.system instead of io.popen for better compatibility with Neovim
  print("Executing command: " .. cmd)
  local result = vim.fn.system(cmd)
  
  if vim.v.shell_error ~= 0 then
    print("Command executed with non-zero exit code: " .. vim.v.shell_error)
    -- This is expected as ffmpeg will exit with an error when listing devices
  end
  
  local devices = {}
  
  if is_win then
    -- Windows parsing (DirectShow)
    for line in result:gmatch("[^\r\n]+") do
      -- Look for lines with "(audio)" which indicate audio devices
      if line:find("%(audio%)") then
        -- Extract the device name which is in quotes before "(audio)"
        local device_name = line:match("\"([^\"]+)\"")
        if device_name then
          print("Found Windows audio device: " .. device_name)
          table.insert(devices, device_name)
        end
      end
    end
  else
    -- Linux parsing (arecord -l)
    -- Example line: "card 2: Webcam [C922 Pro Stream Webcam], device 0: USB Audio [USB Audio]"
    for line in result:gmatch("[^\r\n]+") do
      local card_id = line:match("^card%s+(%d+):")
      local device_id = line:match("device%s+(%d+):")
      if card_id and device_id then
        local device_str = string.format("hw:%s,%s", card_id, device_id)
        print("Found Linux ALSA device: " .. device_str)
        table.insert(devices, device_str)
      end
    end
  end

  if #devices == 0 then
    print("No audio devices found. Trying alternative method...")
    
    -- No additional fallback necessary on Linux; arecord should always be present.
    -- If no devices were parsed, users may need to install ALSA utilities.
    if not is_win and #devices == 0 then
      print("arecord did not return any capture devices. Ensure ALSA utilities are installed and the system has capture devices.")
    end
  else
    print("Found " .. #devices .. " audio devices")
  end

  return devices
end

--- Record a short audio clip and send to Whisper endpoint for transcription.
M.record_and_transcribe = function()
  -- Toggle behaviour: if we are not currently recording, start; otherwise stop and transcribe
  if not record_job_id then
    -- Start recording (indefinitely until stopped)
    record_temp_file = os.tmpname() .. ".wav"

    local cmd

    if is_windows() then
      -- Windows uses dshow. Omitting the -t option records until the process is stopped
      cmd = string.format(
        'ffmpeg -y -loglevel quiet -f dshow -i audio="%s" -ac 1 -ar 16000 -acodec pcm_s16le "%s"',
        M.audio_device,
        record_temp_file
      )
    else
      -- Determine whether to use PulseAudio or ALSA
      local input_format = "pulse"
      if M.audio_device:find("card") or M.audio_device:find("hw:") then
        input_format = "alsa"
      end

      cmd = string.format(
        'ffmpeg -y -loglevel quiet -f %s -i "%s" -ac 1 -ar 16000 -acodec pcm_s16le "%s"',
        input_format,
        M.audio_device,
        record_temp_file
      )
    end

    print("Starting audio recording. Invoke the same command again to stop and transcribe…")
    record_job_id = vim.fn.jobstart(cmd, { detach = true })

    if record_job_id <= 0 then
      print("Failed to start recording")
      record_job_id = nil
    else
      print("Recording started (job ID: " .. record_job_id .. ")")
    end
    return
  end

  -- We are currently recording → stop and transcribe
  print("Stopping recording and starting transcription…")
  vim.fn.jobstop(record_job_id)
  record_job_id = nil

  local temp_file = record_temp_file
  record_temp_file = nil
  
  -- Build URL for the transcription API (using HTTP POST, not WebSocket)
  local url = string.format(
    "%s/v1/audio/transcriptions",
    M.whisper_endpoint
  )
  
  -- Use -sS to disable the progress meter (which is written to stderr) while still
  -- showing an error message if the request fails. This keeps the `result` value
  -- clean, containing only the transcription text returned by the server.
  local curl_cmd = string.format(
    'curl -sS -X POST %s -F "file=@%s" -F "model=whisper-1" -F "response_format=text"',
    url, temp_file
  )
  
  print("Executing transcription command: " .. curl_cmd)
  local result = vim.fn.system(curl_cmd)
  print("Transcription result: " .. result)
  
  -- Insert the transcribed text at the current cursor position. If the result
  -- contains newlines we should respect them, so we split the string into
  -- individual lines before inserting.
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  -- `vim.split` returns a table which can directly be supplied to
  -- nvim_buf_set_text. Use a plain "\n" delimiter so we do not interpret lua
  -- patterns, then trim a potential trailing blank line that appears when the
  -- string ends in a newline.
  local lines = vim.split(result, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  vim.api.nvim_buf_set_text(0, cursor_pos[1] - 1, cursor_pos[2], cursor_pos[1] - 1, cursor_pos[2], lines)
  
  -- Clean up temporary file
  os.remove(temp_file)
  
  return result
end

--- Start audio streaming and send to Whisper endpoint using WebSockets.
M.start_streaming = function()
  -- Keep track of the last inserted text and position
  local last_text = ""
  local start_line = 0
  local start_col = 0
  
  -- Build WebSocket URL with query parameters
  local ws_url = string.format(
    "ws://%s/v1/audio/transcriptions?model=%s&language=%s&response_format=%s&temperature=%s",
    M.whisper_endpoint:gsub("^http://", ""),
    "Systran/faster-whisper-large-v3",
    "en",
    "json",
    "0"
  )
  
  -- Create a single command that captures audio directly to PCM and pipes it to the WebSocket
  local cmd
  if is_windows() then
    -- For Windows, use ffmpeg to capture audio directly to PCM and pipe to websocat
    cmd = string.format(
      'ffmpeg -loglevel quiet -f dshow -i audio="%s" -ac 1 -ar 16000 -f s16le - | ' ..
      'websocat --binary "%s"',
      M.audio_device, ws_url
    )
  else
    -- For Linux, use ffmpeg to capture audio directly to PCM and pipe to websocat
    local input_format = "pulse"
    if M.audio_device:find("card") or M.audio_device:find("hw:") then
      input_format = "alsa"
    end
    
    cmd = string.format(
      'ffmpeg -loglevel quiet -f %s -i "%s" -ac 1 -ar 16000 -f s16le - | ' ..
      'websocat --binary "%s"',
      input_format, M.audio_device, ws_url
    )
  end
  
  print("Starting WebSocket streaming: " .. cmd)
  
  -- Get the current cursor position to start inserting text
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  start_line = cursor_pos[1] - 1
  start_col = cursor_pos[2]
  
  job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and #line > 0 then
            print("Received: " .. line)
            
            -- Try to parse JSON response
            if line:match("^{") then
              local json_text = line:match('"text"%s*:%s*"([^"]*)"')
              if json_text then
                -- Replace the previous text with the new text
                if #last_text > 0 then
                  -- Delete the previous text
                  vim.api.nvim_buf_set_text(0, start_line, start_col, start_line, start_col + #last_text, {""})
                end
                
                -- Insert the new text
                vim.api.nvim_buf_set_text(0, start_line, start_col, start_line, start_col, {json_text})
                
                -- Update the last inserted text
                last_text = json_text
              end
            else
              -- If not JSON, try to use the line as is
              -- Replace the previous text with the new text
              if #last_text > 0 then
                -- Delete the previous text
                vim.api.nvim_buf_set_text(0, start_line, start_col, start_line, start_col + #last_text, {""})
              end
              
              -- Insert the new text
              vim.api.nvim_buf_set_text(0, start_line, start_col, start_line, start_col, {line})
              
              -- Update the last inserted text
              last_text = line
            end
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and #line > 0 then
            print("WebSocket error: " .. line)
          end
        end
      end
    end,
    on_exit = function()
      print("WebSocket streaming stopped")
      job_id = nil
    end,
  })
  
  if job_id <= 0 then
    print("Failed to start WebSocket streaming")
  else
    print("WebSocket streaming started")
  end
end

--- Stop the audio streaming process.
M.stop_streaming = function()
  if job_id then
    vim.fn.jobstop(job_id)
    job_id = nil
  end
end

--- Select an audio device using Telescope.
M.select_audio_device = function()
  local devices = M.list_audio_devices()
  
  -- Use the standard Telescope picker instead of fzf which might not be available
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  
  pickers.new({}, {
    prompt_title = "Select Audio Device",
    finder = finders.new_table({
      results = devices,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()[1]
        M.audio_device = selection
        print("Selected audio device: " .. M.audio_device)
      end)
      return true
    end,
  }):find()
end

--- Setup default keybindings and configurations for starting and stopping the streaming process.
-- This function should be called in the user's init.lua to configure the plugin.
M.setup = function(config)
  config = config or {}
  local start_key = config.start_key or '<leader>as'
  local stop_key = config.stop_key or '<leader>ap'
  local select_key = config.select_key or '<leader>ad'
  local record_key = config.record_key or '<leader>ar'
  local whisper_endpoint = config.whisper_endpoint or 'http://192.168.178.188:8000'
  local audio_device = config.audio_device or '"Microphone (Realtek High Definition Audio)"'

  -- Use vim.keymap.set (newer API) instead of vim.api.nvim_set_keymap
  vim.keymap.set('n', start_key, function() require("nwhisper").start_streaming() end, { desc = 'Start audio streaming' })
  vim.keymap.set('n', stop_key, function() require("nwhisper").stop_streaming() end, { desc = 'Stop audio streaming' })
  vim.keymap.set('n', select_key, function() require("nwhisper").select_audio_device() end, { desc = 'Select audio device' })
  vim.keymap.set('n', record_key, function() require("nwhisper").record_and_transcribe() end, { desc = 'Record and transcribe audio' })

  M.whisper_endpoint = whisper_endpoint
  M.audio_device = audio_device
end

return M
