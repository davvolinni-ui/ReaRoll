-- @description ReaRoll - MIDI piano roll
-- @version 0.7.2-test
-- @author Davvo
-- @link https://forum.cockos.com/showthread.php?t=311021
-- @about Testing release. Requires ReaImGui 0.10. See EULA.md before use.
-- @changelog
--   Fix Shape Apply staying disabled for valid single-item previews.
--   Keep Shape open if committing a preview fails.
--   Use native ReaImGui modifiers for drawing, selection and keyboard shortcuts.
--   Read physical wheel modifiers only over unfocused ReaRoll on Windows and macOS, when js_ReaScriptAPI is installed.
-- @provides
--   src/*.lua
--   src/ui/*.lua
--   [main] ReaRoll_Reset_Window.lua
--   EULA.md
--   THIRD_PARTY_NOTICES.md

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB('ReaRoll requires ReaImGui. Install it through ReaPack.', 'ReaRoll', 0)
  return
end

local source = debug.getinfo(1, 'S').source:sub(2)
local root = source:match('^(.*[\\/])') or './'
package.path = root .. '?.lua;' .. root .. '?/init.lua;' .. reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path

local ImGui = require 'imgui' '0.10'
local App = require 'src.app'
local app = App.new(ImGui)
reaper.atexit(function() app:shutdown() end)
reaper.defer(function() app:frame() end)
