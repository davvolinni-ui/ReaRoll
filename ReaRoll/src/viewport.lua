-- @noindex
local U=require 'src.util'; local V={}; V.__index=V
function V.new(settings) return setmetatable({s=settings},V) end
function V:toggle_follow()
  if self.follow_suspended then self.s.follow_playback=true; self.follow_suspended=false
  elseif not self.s.follow_playback then self.s.follow_playback=true; self.s.follow_style='page'
  elseif self.s.follow_style~='continuous' then self.s.follow_style='continuous'
  else self.s.follow_playback=false end
  self.follow_last_start=nil
end
function V:follow_label()
  if not self.s.follow_playback then return 'Off' end
  local label=self.s.follow_style=='continuous' and 'Continuous' or 'Page'
  return self.follow_suspended and label..' (paused)' or label
end
function V:check_follow_navigation()
  local s=self.s
  if self.follow_last_start and (math.abs(s.start_qn-self.follow_last_start)>1e-7
    or s.low_pitch~=self.follow_last_pitch or s.fold_offset~=self.follow_last_fold) then
    if self.follow_origin then self.follow_suspended=true end
  end
end
function V:remember_follow_view()
  local s=self.s
  self.follow_last_start=s.start_qn; self.follow_last_pitch=s.low_pitch; self.follow_last_fold=s.fold_offset
end
function V:update_follow(state,qn)
  local s=self.s
  local active=(state&1)~=0
  local paused=(state&2)~=0
  if self.follow_take~=self.take then
    self.follow_take=self.take; self.follow_state=0; self.follow_origin=nil
    self.follow_last_start=nil; self.follow_suspended=false
  end
  self:check_follow_navigation()
  local previous=self.follow_state or 0
  if active and previous==0 then
    self.follow_origin=s.start_qn; self.follow_suspended=false
  end
  if state==0 and previous~=0 then
    if s.follow_playback and not self.follow_suspended and self.follow_origin then
      s.start_qn=self.follow_origin
    end
    self.follow_origin=nil
  elseif active and not paused and s.follow_playback and not self.follow_suspended and qn then
    local span=s.visible_qn
    if s.follow_style=='continuous' then
      s.start_qn=U.clamp(qn-span*.35,self.min_qn or 0,self.max_start or math.huge)
    elseif qn<s.start_qn or qn>=s.start_qn+span*.9 then
      s.start_qn=U.clamp(qn-span*.1,self.min_qn or 0,self.max_start or math.huge)
    end
  end
  self.follow_state=state
  self:remember_follow_view()
end
local function time_bounds(self)
  local context=math.max(8,(self.s.visible_qn or 8)*.75)
  self.min_qn=math.max(0,(self.item_qn or 0)-context)
  self.timeline_end=self.item_end_qn and self.item_end_qn+context or math.huge
  self.max_start=self.item_end_qn and math.max(self.min_qn,self.timeline_end-self.s.visible_qn) or math.huge
end
local function time_metrics(self)
  self.ppq0=reaper.MIDI_GetPPQPosFromProjQN(self.take,self.s.start_qn)
  self.ppq1=reaper.MIDI_GetPPQPosFromProjQN(self.take,self.s.start_qn+self.s.visible_qn)
  self.ppq_per_qn=(self.ppq1-self.ppq0)/self.s.visible_qn
  self.px_per_qn=self.w/self.s.visible_qn
end
local function anchor_pitch_view(self,anchor)
  local rows=self:rows(); local r=(anchor.mouse_y-self.y)/self.s.row_height
  local key=self.fold and 'fold_offset' or 'low_pitch'
  local wanted=anchor.value+r-(self.fold and rows or rows-1)
  self.s[key]=U.clamp(math.floor(wanted+.5),0,math.max(0,(self.fold and #self.fold or 128)-rows))
  anchor.last_offset=self.s[key]; anchor.last_height=self.s.row_height
end
function V:set_geometry(x,y,w,h,take,item_qn,item_end_qn)
  self:check_follow_navigation()
  if self.take and self.take~=take then self.pitch_zoom_anchor=nil; self.pitch_zoom_pending=nil; self.time_zoom_anchor=nil end
  if self.h and math.abs(h-self.h)>.5 and not self.pitch_zoom_pending then
    local old_rows=math.max(1,math.floor(self.h/self.s.row_height))
    self.s.row_height=U.clamp(h/old_rows,8,32)
  end
  self.x,self.y,self.w,self.h,self.take=x,y,w,h,take
  self.item_qn,self.item_end_qn=item_qn,item_end_qn
  -- Keep some project timeline visible around the active item. Besides making
  -- item boundaries legible, this gives drawing gestures room to extend the
  -- item instead of trapping the viewport inside it.
  time_bounds(self)
  self.s.start_qn=U.clamp(self.s.start_qn,self.min_qn,self.max_start)
  time_metrics(self)
  self.s.low_pitch=U.clamp(self.s.low_pitch,0,math.max(0,128-self:rows()))
  if self.pitch_zoom_pending and self.pitch_zoom_anchor then anchor_pitch_view(self,self.pitch_zoom_anchor) end
  self.pitch_zoom_pending=nil
  self:remember_follow_view()
end
function V:set_fold(notes)
  if not self.s.fold_enabled then self.fold,self.fold_index=nil,nil; return end
  local seen,pitches={},{}
  for _,n in ipairs(notes or {}) do if not seen[n.pitch] then seen[n.pitch]=true; pitches[#pitches+1]=n.pitch end end
  if #pitches==0 then self.fold,self.fold_index=nil,nil; return end
  table.sort(pitches); self.fold=pitches; self.fold_index={}
  for i,p in ipairs(pitches) do self.fold_index[p]=i end
  self.s.fold_offset=U.clamp(self.s.fold_offset or 0,0,math.max(0,#pitches-self:rows()))
end
function V:x_from_ppq(p) return self.x+((p-self.ppq0)/self.ppq_per_qn)*self.px_per_qn end
function V:ppq_from_x(x) return self.ppq0+((x-self.x)/self.px_per_qn)*self.ppq_per_qn end
function V:qn_from_x(x) return self.s.start_qn+(x-self.x)/self.px_per_qn end
function V:x_from_qn(q) return self.x+(q-self.s.start_qn)*self.px_per_qn end
function V:rows() local capacity=math.min(128,math.max(1,math.floor(self.h/self.s.row_height))); return self.fold and math.min(capacity,math.max(1,#self.fold)) or capacity end
function V:pitch_at_row(r) if self.fold and #self.fold>0 then return self.fold[(self.s.fold_offset or 0)+self:rows()-r] end; return self.s.low_pitch+self:rows()-1-r end
function V:y_from_pitch_unclipped(p)
  if self.fold then local i=self.fold_index and self.fold_index[p]; if not i then return nil end; local o=self.s.fold_offset or 0; return self.y+(o+self:rows()-i)*self.s.row_height end
  return self.y+(self.s.low_pitch+self:rows()-1-p)*self.s.row_height
end
function V:y_from_pitch(p)
  if self.fold then local i=self.fold_index and self.fold_index[p]; local o=self.s.fold_offset or 0; if not i or i<=o or i>o+self:rows() then return nil end
  elseif p<self.s.low_pitch or p>self:high_pitch() then return nil end
  return self:y_from_pitch_unclipped(p)
end
function V:pitch_from_y(y) local r=U.clamp(math.floor((y-self.y)/self.s.row_height),0,self:rows()-1); return U.clamp(self:pitch_at_row(r) or 60,0,127) end
function V:is_pitch_visible(p) return self:y_from_pitch(p)~=nil end
function V:high_pitch() if self.fold and #self.fold>0 then return self.fold[math.min(#self.fold,(self.s.fold_offset or 0)+self:rows())] end; return U.clamp(self.s.low_pitch+self:rows()-1,0,127) end
function V:zoom_time(factor,mx)
  self:check_follow_navigation()
  local r=U.clamp((mx-self.x)/self.w,0,1)
  local requested=U.clamp(self.s.visible_qn*factor,1/16,256)
  if math.abs(requested-self.s.visible_qn)<.000001 then return end
  local anchor=self.time_zoom_anchor
  if not anchor or math.abs(anchor.ratio-r)>1e-9
    or math.abs(anchor.last_start-self.s.start_qn)>1e-9
    or math.abs(anchor.last_visible-self.s.visible_qn)>1e-9 then
    anchor={ratio=r,qn=self.s.start_qn+r*self.s.visible_qn}
    self.time_zoom_anchor=anchor
  end
  self.s.visible_qn=requested; time_bounds(self)
  -- Keep the original focus even when an edge prevents placing it under the
  -- pointer temporarily. Deriving it again from the clamped view causes every
  -- zoom-out/zoom-in cycle to walk farther into the item.
  self.s.start_qn=U.clamp(anchor.qn-r*requested,self.min_qn,self.max_start)
  anchor.last_start=self.s.start_qn; anchor.last_visible=requested
  time_metrics(self)
  self:remember_follow_view()
end
function V:zoom_time_at(factor,qn,ratio)
  self:check_follow_navigation()
  local requested=U.clamp(self.s.visible_qn*factor,1/16,256)
  if math.abs(requested-self.s.visible_qn)<.000001 then return end
  self.s.visible_qn=requested; time_bounds(self)
  self.s.start_qn=U.clamp(qn-U.clamp(ratio,0,1)*requested,self.min_qn,self.max_start)
  self.time_zoom_anchor=nil
  time_metrics(self)
  self:remember_follow_view()
end
function V:zoom_pitch(factor,my,anchor_pitch)
  self:check_follow_navigation()
  local old_height=self.s.row_height; local requested=U.clamp(old_height*factor,8,32)
  -- Do nothing at a zoom limit. Recalculating the anchor while the height is
  -- unchanged caused repeated wheel input to walk the viewport unexpectedly.
  if math.abs(requested-old_height)<.000001 then return end
  my=U.clamp(my,self.y,self.y+self.h)
  local key=self.fold and 'fold_offset' or 'low_pitch'
  local offset=self.s[key] or 0
  local anchor=self.pitch_zoom_anchor
  if not anchor or anchor.mouse_y~=my or anchor.viewport_y~=self.y
    or anchor.folded~=(self.fold~=nil) or anchor.last_offset~=offset
    or math.abs(anchor.last_height-old_height)>.000001 or anchor.explicit_pitch~=anchor_pitch then
    local r=(my-self.y)/old_height
    anchor={mouse_y=my,viewport_y=self.y,folded=self.fold~=nil,explicit_pitch=anchor_pitch,
      value=offset+(self.fold and self:rows() or self:rows()-1)-r}
    self.pitch_zoom_anchor=anchor
  end
  self.s.row_height=requested; anchor_pitch_view(self,anchor)
  self.pitch_zoom_pending=true
  self:remember_follow_view()
end
function V:scroll_pitch(delta)
  self.pitch_zoom_anchor=nil; self.pitch_zoom_pending=nil
  self.pitch_remainder=(self.pitch_remainder or 0)+delta
  local whole=self.pitch_remainder>=0 and math.floor(self.pitch_remainder) or math.ceil(self.pitch_remainder)
  self.pitch_remainder=self.pitch_remainder-whole
  local key=self.fold and 'fold_offset' or 'low_pitch'
  local limit=math.max(0,(self.fold and #self.fold or 128)-self:rows())
  self.s[key]=U.clamp((self.s[key] or 0)+whole,0,limit)
end
function V:pan(dx,dy)
  self.time_zoom_anchor=nil
  self.s.start_qn=U.clamp(self.s.start_qn-dx/self.px_per_qn,self.min_qn or 0,self.max_start or math.huge)
  self:scroll_pitch(dy/self.s.row_height)
end
return V
