-- nwhisper.lua
local M = {}
local job_id = nil

--- List available audio devices using ffmpeg.
M.list_audio_devices = function()
  local cmd = 'ffmpeg -list_devices true -f dshow -i dummy'
  local handle = io.popen(cmd)
  local result = handle:read("*a")
  handle:close()

  local devices = {}
  for line in result:gmatch("[^\r\n]+") do
    if line:find("Alternative name") then
      table.insert(devices, line:match(": \"(.+)\""))
    end
  end

  return devices
end

--- Start audio streaming and send to Whisper endpoint.
M.start_streaming = function()
  local cmd = string.format('ffmpeg -f dshow -i audio=%s -f wav pipe:1 | curl -X POST %s --data-binary @-', M.audio_device, M.whisper_endpoint)
  job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          local cursor_pos = vim.api.nvim_win_get_cursor(0)
          vim.api.nvim_buf_set_text(0, cursor_pos[1] - 1, cursor_pos[2], cursor_pos[1] - 1, cursor_pos[2], {line})
        end
      end
    end,
    on_stderr = function(_, data)
      print(vim.inspect(data))
    end,
    on_exit = function()
      job_id = nil
    end,
  })
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
  require('telescope.builtin').find_files({
    prompt_title = "Select Audio Device",
    results_title = "Available Audio Devices",
    finder = require'telescope.finders'.new_table({results = devices}),
    attach_mappings = function(prompt_bufnr, map)
      local actions = require 'telescope.actions'
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry().value
        M.audio_device = selection
        print("Selected audio device: " .. M.audio_device)
      end)
      return true
    end,
  })
end

--- Setup default keybindings and configurations for starting and stopping the streaming process.
-- This function should be called in the user's init.lua to configure the plugin.
M.setup = function(config)
  config = config or {}
  local start_key = config.start_key or '<leader>as'
  local stop_key = config.stop_key or '<leader>ap'
  local whisper_endpoint = config.whisper_endpoint or 'http://localhost:9001/transcribe'
  local audio_device = config.audio_device or '"Microphone (Realtek High Definition Audio)"'

  vim.api.nvim_set_keymap('n', start_key, ':lua require("nwhisper").start_streaming()<CR>', { noremap = true, silent = true })
  vim.api.nvim_set_keymap('n', stop_key, ':lua require("nwhisper").stop_streaming()<CR>', { noremap = true, silent = true })
  vim.api.nvim_set_keymap('n', '<leader>ad', ':lua require("nwhisper").select_audio_device()<CR>', { noremap = true, silent = true })

  M.whisper_endpoint = whisper_endpoint
  M.audio_device = audio_device
end

return M
