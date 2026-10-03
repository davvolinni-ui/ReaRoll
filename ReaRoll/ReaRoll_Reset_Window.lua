-- @description ReaRoll - Reset Window
-- @version 0.6.2-test
-- @author Davvo
-- @noindex
-- @about Reopens a hidden or off-screen ReaRoll window without clearing preferences.

reaper.SetExtState('ReaRoll','window_rescue','1',false)
reaper.MB('Window recovery requested.\n\nIf ReaRoll is already running, its window will reopen now. If it is not running, launch ReaRoll next.','ReaRoll',0)
