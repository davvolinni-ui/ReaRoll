-- @noindex
local M={}
function M.new() return {ids={}} end
function M.clear(s) s.ids={} end
function M.has(s,id) return s.ids[id]==true end
function M.set_only(s,id) s.ids={[id]=true} end
function M.toggle(s,id) s.ids[id]=not s.ids[id]; if not s.ids[id] then s.ids[id]=nil end end
function M.add(s,id) s.ids[id]=true end
function M.count(s) local n=0 for _ in pairs(s.ids) do n=n+1 end return n end
function M.list(s,notes) local out={} for _,n in ipairs(notes) do if s.ids[n.id] then out[#out+1]=n end end return out end
return M
