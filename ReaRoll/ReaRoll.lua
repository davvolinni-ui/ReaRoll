-- @description ReaRoll - MIDI piano roll
-- @version 0.7.5-test
-- @author Davvo
-- @link https://forum.cockos.com/showthread.php?t=311021
-- @about Testing release. Requires ReaImGui 0.10. See EULA.md before use.
-- @changelog
--   Customize wheel scrolling, zoom, note values and divisions for each modifier combination and wheel axis.
--   Show the four REAPER navigation gestures and Shift-wheel together, with per-binding direction reversal.
--   Apply REAPER's default wheel navigation when selecting the REAPER input preset.
--   Display Command and Option labels on macOS; preserve saved custom bindings until a preset is selected.
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
