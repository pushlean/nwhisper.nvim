-- nwhisper.lua
local M = {}
local job_id = nil

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

  M.whisper_endpoint = whisper_endpoint
  M.audio_device = audio_device
end

return M
