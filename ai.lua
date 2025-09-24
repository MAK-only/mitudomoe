-- ai.lua
local Eval   = require("ai_eval")
local Search = require("ai_search")

local M = {}

-- 評価器を用意
local function build_eval(api)
  if Eval and Eval.make then
    return Eval.make(api)
  elseif Eval and type(Eval.value) == "function" then
    -- 互換: 直接 value を持つテーブルを評価器として扱う
    return Eval
  else
    error("ai_eval: make(api) か 評価関数をエクスポートしてください")
  end
end

-- 探索で手を選ぶ（score, move を返す）
local function pick_move(api, eval, side, config)
  local search = Search.make(api, eval)

  local diff   = (config and config.difficulty) or "Normal"
  local depth  = (diff=="Hard") and 50 or (diff=="Easy" and 1 or 2)
  local budget = (config and config.time_budget) or ((diff=="Hard") and 3.0 or (diff=="Easy" and 0.25 or 0.6))

  local nowFn = (api and api.getTime) and api.getTime
                or function() return (love.timer and love.timer.getTime()) or 0 end
  local deadline = nowFn() + budget

  local score, move = search:pick(side, depth, deadline, { time_budget = budget })
  return score, move
end

-- COM に1手指させる（main.lua から呼ばれる）
function M.playOneMove(api, side, config)
  local eval = build_eval(api)
  local _, move = pick_move(api, eval, side, config)   -- ★ scoreは捨てて move を受け取る
  assert(move and move.from and move.to, "AI が不正な手を返しました")
  api.tryMove(move.from, move.to.c, move.to.r)
end

-- -- トレーニング1局（self-playのダミー：ai_learn があればそちらを使う）
-- function M.trainOneGame(api, cfg)
--   cfg = cfg or {}
--   local eval = build_eval(api)

--   -- ai_learn があるならそちらを委譲
--   local ok, Learn = pcall(require, "ai_learn")
--   if ok and Learn and Learn.make then
--     local learner = Learn.make(api, eval)
--     if learner and learner.selfplay then
--       learner.selfplay({
--         lr       = cfg.lr or 0.05,
--         eps      = cfg.eps or 0.05,
--         gamma    = cfg.gamma or 0.99,
--         maxPlies = cfg.maxPlies or 1000,
--       })
--       return
--     end
--   end

--   -- フォールバック: 学習なしの自己対局（進捗用）
--   if api.resetToInitial then api.resetToInitial() end
--   local search = Search.make(api, eval)
--   local side = "W"
--   local maxPlies = cfg.maxPlies or 200
--   local plies = 0
--   while (not api.gameIsOver()) and plies < maxPlies do
--     local _, m = search:pick(side, 2, nil, { time_budget = 0.02 })
--     if not m then break end
--     api.tryMove(m.from, m.to.c, m.to.r)
--     side = api.opponent(side)
--     plies = plies + 1
--   end

--   -- 評価器が永続化機能を持っていれば保存
--   if eval.save then pcall(eval.save) end
-- end

return M