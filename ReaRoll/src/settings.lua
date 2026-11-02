-- @noindex
local M={section='ReaRoll'}
local defaults={smooth_scroll=true,scroll_glide_ms=200,follow_playback=true,follow_style='page',grid_qn=.25,length_qn=.25,length_follow_grid=true,velocity=100,channel=0,start_qn=0,visible_qn=8,low_pitch=48,row_height=14,empty_item_bars=4,lane_height=126,lane_open=true,lane_tools_open=true,lane_target='velocity',lane_pin_1='cc1',lane_pin_2='cc11',lane_refs_expanded=false,cc_number=1,pitch_bend_range=2,mode='smart',chord_name='Major',chord_diatonic=true,chord_size=3,chord_inversion=0,chord_drag_length=false,harmony_listen=true,inherit_length=true,prevent_overlaps=true,midi_preview_enabled=true,snap_enabled=true,snap_mode='absolute',fold_enabled=false,fold_offset=0,scale_enabled=false,scale_snap=false,scale_root=0,scale_name='Major',scale_opacity=.16,ghost_enabled=false,ghost_mode='track',ui_scale=1,uniform_note_color=false,strum_qn=.03,flam_qn=.04,human_time=8,human_velocity=6,note_playback_animation=true,playhead_smooth=true,playhead_style='Glow',playhead_color=0x42A5F5FF,playhead_color_custom=false,playhead_width=2.4,playhead_opacity=.95,playhead_glow=.72,playhead_trail=.34,playhead_shadow=.25,playhead_pulse=.35,playhead_scan=false,playhead_scan_amount=.55,playhead_scan_direction='down',playhead_wave=false,playhead_wave_amount=.45,playhead_rainbow=false,playhead_cycle=false,playhead_cycle_speed=.18,playhead_sparks=false,playhead_spark_amount=.45,playhead_matrix=false,playhead_matrix_amount=.55,reaper_action_1='',reaper_action_2='',reaper_action_3='',reaper_action_4=''}
defaults.grid_type='' -- Infer existing saved triplet/dotted values on upgrade.
defaults.note_mouse_info=true
defaults.tooltips_enabled=true
defaults.cc_follows_notes=true
defaults.tooltip_delay=.45
defaults.edit_all_channels=true
defaults.edit_channel_scope_version=1
defaults.edit_channel_scope_legacy=''
defaults.inspector_open=false
defaults.chord_follow_track=false
defaults.note_color_mode='track'
defaults.lane_stack_enabled=false
defaults.lane_stack_targets='velocity,cc1,cc11'
defaults.paint_every=1
defaults.note_expression_overlay=false
defaults.mpe_pitch_edit=false
defaults.mpe_enabled=false
defaults.mpe_mode_version=1
defaults.mpe_mode_legacy=''
defaults.mpe_zone='lower'
defaults.mpe_members=15
defaults.mpe_pitch_bend_range=48
defaults.slide_linear=false
defaults.slide_replace=false
defaults.phrase_scope='active'
defaults.scale_view_only=false
defaults.input_note_display=true
for slot=1,8 do defaults['groove_slot_'..slot]='' end
function M.load()
  local s={}
  for k,v in pairs(defaults) do
    local raw=reaper.GetExtState(M.section,k)
    if raw=='' then s[k]=v elseif type(v)=='number' then s[k]=tonumber(raw) or v elseif type(v)=='boolean' then s[k]=raw=='1' else s[k]=raw end
  end
  if reaper.GetExtState(M.section,'edit_channel_scope_version')=='' then s.edit_channel_scope_legacy=reaper.GetExtState(M.section,'edit_all_channels');s.edit_all_channels=true end
  if reaper.GetExtState(M.section,'mpe_mode_version')=='' then
    s.mpe_mode_legacy=reaper.GetExtState(M.section,'mpe_enabled')
    s.mpe_enabled=false;s.mpe_pitch_edit=false
  end
  if s.mode=='slide'then s.mode='smart'end -- Retain old slide MIDI; ordinary drawing is the default workflow.
  s.mpe_mode_version=1
  s.edit_channel_scope_version=1
  s.adaptive_grid=reaper.GetExtState(M.section,'adaptive_grid')=='1'
  s.grid_type=require('src.grid').kind(s)
  if reaper.GetExtState(M.section,'snap_mode')=='' then s.snap_mode=s.snap_enabled and 'absolute' or 'off' end
  if s.snap_mode~='absolute' and s.snap_mode~='relative' then s.snap_mode='off' end; s.snap_enabled=s.snap_mode~='off'
  if s.lane_target=='cc1' then s.lane_target='cc'; s.cc_number=1 elseif s.lane_target=='cc11' then s.lane_target='cc'; s.cc_number=11 elseif s.lane_target=='cc64' then s.lane_target='cc'; s.cc_number=64 end
  return s
end
function M.save(s)
  s.snap_enabled=s.snap_mode~='off'
  reaper.SetExtState(M.section,'adaptive_grid',s.adaptive_grid and '1' or '0',true)
  for k in pairs(defaults) do local v=s[k]; if type(v)=='boolean' then v=v and '1' or '0' end; reaper.SetExtState(M.section,k,tostring(v),true) end
end
return M
