-- @description ReaRoll - MIDI piano roll
-- @version 0.7.6-test
-- @author Davvo
-- @link https://forum.cockos.com/showthread.php?t=311021
-- @about Testing release. Requires ReaImGui 0.10. See EULA.md before use.
-- @changelog
--   Add Straight, Triplet and Dotted grid divisions through 1/128, including Auto grid.
--   Combine grid, rhythm and note length in one compact toolbar control with wheel support.
--   Keep Follow grid, Fixed and Learn from notes directly accessible; shorten fixed-length choices.
--   Fix beat/bar lines and shading splitting dotted or coarse grid cells when zoomed out.
--   Fix native macOS Command-wheel detection when key swapping is disabled; live Mac confirmation remains pending.
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
