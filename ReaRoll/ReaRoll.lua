-- @description ReaRoll - compact sketching piano roll
-- @version 0.6.1-test
-- @author Davvo
-- @link https://forum.cockos.com/showthread.php?t=311021
-- @about Testing release. Requires ReaImGui 0.10. See EULA.md before use.
-- @changelog
--   Add harmony tools and chord palettes.
--   Expand arpeggiator and phrase editing tools.
--   Preserve explicit note-on/off pairs when editing overlapping notes.
--   Improve playback following, zoom focus, and timeline navigation.
--   Refine controller lane tools, tooltips, toolbar, and MIDI audition controls.
-- @provides
--   src/*.lua
--   src/ui/*.lua
--   [main] ReaRoll_Reset_Window.lua
--   EULA.md

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
