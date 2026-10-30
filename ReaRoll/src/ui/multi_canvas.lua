-- @noindex
-- Compatibility entry: additional sources use the original piano-roll canvas.
return {draw=function(app)return require('src.ui.canvas').draw(app)end}
