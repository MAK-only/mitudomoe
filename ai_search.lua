local EVAL = require('ai_eval')
-- ===== αβ本体 =====
local nodes = 0
local start_time, time_limit


local function timed_out() return time_limit and love and love.timer and (love.timer.getTime() - start_time >= time_limit) end


local function alphabeta(state, depth, alpha, beta)
nodes = nodes + 1
if timed_out() then return 0 end


-- 反復検出（3回目で引き分け）。自着で引き分けにする手は負け扱い（−INF）
state._rep = state._rep or {}
local key = make_key(state)
local cnt = (state._rep[key] or 0)
if cnt >= 2 then
-- ここに来るのは相手が指してからなので、直前手側が敗北。評価視点を合わせて0返し、選択側で−INF処理する。
return 0
end


if depth <= 0 and not is_tactical(state) then
return EVAL.evaluate(state, state.side_to_move)
end


local best = -INF
local best_move = nil
local moves = gen_moves(state)
if #moves == 0 then
-- パスは無い前提だが、合法手ゼロなら悪い局面
return -INF/2
end


for _,mv in ipairs(moves) do
local s2, result = apply_move(state, mv)


-- repetition 更新
s2._rep = {}
for k,v in pairs(state._rep) do s2._rep[k]=v end
s2._rep[key] = cnt + 1


local val
if result == 'win' then
val = INF - 1
elseif result == 'lose' then
val = -INF + 1
else
val = -alphabeta(s2, depth-1, -beta, -alpha)
end


if val > best then best = val; best_move = mv end
if best > alpha then alpha = best end
if alpha >= beta then break end
end


return best, best_move
end


function M.think(state, opts)
-- opts: {depth=5, time_ms=1000}
ensure_ids(state)
nodes = 0
start_time = love and love.timer and love.timer.getTime() or 0
time_limit = (opts and opts.time_ms) and (opts.time_ms/1000.0) or nil


local best_move, best_val
local maxd = (opts and opts.depth) or 4
local alpha, beta = -INF, INF


for d=1,maxd do
local v, mv = alphabeta(state, d, alpha, beta)
if mv then best_move, best_val = mv, v end
if timed_out() then break end
end


return best_move, {value=best_val or 0, nodes=nodes}
end


return M