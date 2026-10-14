-- @noindex
local Take=require 'src.take'
local Canvas=require 'src.ui.canvas'
local bounds
for i=1,100 do
  local name,value=debug.getupvalue(Canvas.draw,i)
  if name=='source_timeline_bounds' then bounds=value; break end
end
assert(bounds,'canvas timeline bounds must be available')
local valid_take,valid_item,throw_track=true,true,false
local track_calls=0
reaper={
  ValidatePtr2=function(_,_,kind)return kind=='MediaItem_Take*' and valid_take or kind=='MediaItem*' and valid_item end,
  TakeIsMIDI=function()return true end,
  GetMediaItemTake_Item=function()return 'item' end,
  GetMediaItemTrack=function()
    track_calls=track_calls+1
    if throw_track then error('MediaItem expected') end
    return 'track'
  end,
  CountTrackMediaItems=function()return 0 end,
}
local app={take='take',settings={ghost_enabled=true},item_start_qn=4,item_end_qn=8}
assert(Take.track(app.take)=='track','valid items retain their track')
valid_item=false; track_calls=0
local first,last=bounds(app)
assert(first==4 and last==8 and track_calls==0,'invalid owning items must not reach GetMediaItemTrack')
valid_take=false
assert(Take.track(app.take)==nil,'deleted takes must safely resolve to no track')
valid_take,valid_item,throw_track=true,true,true
first,last=bounds(app)
assert(first==4 and last==8,'item invalidation during the lookup must preserve active timeline bounds')
assert(Take.track(nil)==nil,'missing takes have no track')
print('PASS: canvas tolerates invalid items and track lookup invalidation')
