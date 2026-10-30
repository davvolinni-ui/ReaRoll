-- @description ReaRoll - MIDI piano roll
-- @version 0.7.3-test
-- @author Davvo
-- @link https://forum.cockos.com/showthread.php?t=311021
-- @about Testing release. Requires ReaImGui 0.10. See EULA.md before use.
-- @changelog
--   Fix notes moving upward when clicked or held near the ruler.
--   Start drag auto-scroll only beyond the note grid after movement toward that edge.
--   Keep all visible rows and time positions usable without triggering auto-scroll.
--   Increase scroll speed with distance outside the grid and stop on re-entry.
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
