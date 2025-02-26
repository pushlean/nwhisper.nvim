# nwhisper Plugin

## Overview
The nwhisper plugin allows you to stream audio from your microphone and send it to a Whisper endpoint for transcription. The transcribed text is then displayed in your Neovim buffer.

## Installation with LazyVim

1. **Add the plugin to your `plugins.lua` file:**

   Open your `lua/plugins.lua` file and add the following entry:

   ```lua
   return {
     -- Other plugins...
     {
       'your-username/nwhisper',  -- Replace with the actual repository path
       config = function()
         require('nwhisper').setup({
           start_key = '<leader>as',  -- Keybinding to start streaming
           stop_key = '<leader>ap',   -- Keybinding to stop streaming
           whisper_endpoint = 'http://localhost:9001/transcribe',  -- Whisper endpoint URL
           audio_device = '"Microphone (Realtek High Definition Audio)"'  -- Audio device name
         })
       end,
     },
     -- Other plugins...
   }
   ```

2. **Install the plugin:**

   Run `:Lazy sync` in Neovim to install the plugin.

## Configuration

You can customize the keybindings and other settings by modifying the configuration table in your `init.lua` or `plugins.lua` file:

```lua
require('nwhisper').setup({
  start_key = '<leader>as',  -- Keybinding to start streaming
  stop_key = '<leader>ap',   -- Keybinding to stop streaming
  whisper_endpoint = 'http://localhost:9001/transcribe',  -- Whisper endpoint URL
  audio_device = '"Microphone (Realtek High Definition Audio)"'  -- Audio device name
})
```

## Usage

- **Start Streaming:** Press `<leader>as` to start streaming audio and sending it to the Whisper endpoint.
- **Stop Streaming:** Press `<leader>ap` to stop the audio stream.

## Dependencies

- `ffmpeg`: Ensure that `ffmpeg` is installed on your system.
- `curl`: Ensure that `curl` is installed on your system.
