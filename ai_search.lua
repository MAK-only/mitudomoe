-- ai_search.lua
local Search = {}

function Search.make(api, eval)
  local INF = 1e9
  local KILLER = {}  -- ply -> { m1, m2 }（必要なら拡張）
  -- 時刻/タイムアップ
  local now = (api and api.getTime) and api.getTime or function()
    return (love.timer and love.timer.getTime()) or 0
  end
  local function timeUp(deadline)
    if api and api.timeUp then return api.timeUp(deadline) end
    return deadline and (now() >= deadline) or false
  end

  -- 並べ替え（タクティカル→キラー）
  local function orderMoves(side, moves, ply)
    table.sort(moves, function(a,b)
      local qa = api.quickMoveTacticalScore(side, a)
      local qb = api.quickMoveTacticalScore(side, b)
      if qa ~= qb then return qa > qb end
      local k = KILLER[ply]
      if k then
        local ka = (k.m1 and api.sameMove(a,k.m1)) or (k.m2 and api.sameMove(a,k.m2))
        local kb = (k.m1 and api.sameMove(b,k.m1)) or (k.m2 and api.sameMove(b,k.m2))
        if ka ~= kb then return ka end
      end
      return false
    end)
  end

  -- 簡易静止探索（戦闘っぽい手だけ数手読む）
  local function qsearch(side, alpha, beta, ply, deadline)
    local stand = eval.value(side)
    if stand > alpha then alpha = stand end
    if alpha >= beta or timeUp(deadline) then return alpha end

    local moves = api.listLegalMoves(side)
    orderMoves(side, moves, ply)

    local used, EXT_LIMIT = 0, 6
    for _,m in ipairs(moves) do
      if api.quickMoveTacticalScore(side, m) > 0 then
        local s = api.snapshot(); api.setFxMute(true)
        api.applyMoveNoFx(side, m)
        local v = -qsearch(api.opponent(side), -beta, -alpha, ply+1, deadline)
        api.setFxMute(false); api.restore(s)

        if v > alpha then alpha = v end
        if alpha >= beta or timeUp(deadline) then break end
        used = used + 1; if used >= EXT_LIMIT then break end
      end
    end
    return alpha
  end

  -- αβ付き negamax
  local function search(side, depth, alpha, beta, ply, deadline)
    if timeUp(deadline) then
      return eval.value(side)
    end

    local win = api.checkGameEnd(side)
    if win == side then return  1e6 end
    if win == api.opponent(side) then return -1e6 end

    if depth <= 0 then
      return qsearch(side, alpha, beta, ply, deadline)
    end

    local moves = api.listLegalMoves(side)
    if #moves == 0 then
      return eval.value(side)
    end
    orderMoves(side, moves, ply)

    local best = -INF
    for _,m in ipairs(moves) do
      local s = api.snapshot(); api.setFxMute(true)
      api.applyMoveNoFx(side, m)
      local v = -search(api.opponent(side), depth-1, -beta, -alpha, ply+1, deadline)
      api.setFxMute(false); api.restore(s)

      if v > best then best = v end
      if v > alpha then alpha = v end
      if alpha >= beta or timeUp(deadline) then break end
    end
    return best
  end

  -- 反復深化でベストムーブ選択（同値手はランダム）
  local function pick(side, maxDepth, deadline, cfg)
    local md = tonumber(maxDepth) or 1
    local budget = cfg and cfg.time_budget or nil
    if (not deadline) and budget then deadline = now() + budget end

    local best, bestM = -INF, nil
    for d = 1, md do
      if timeUp(deadline) then break end

      local moves = api.listLegalMoves(side)
      if #moves == 0 then break end
      orderMoves(side, moves, 0)

      local curBest, ties = -INF, {}
      for _,m in ipairs(moves) do
        local s = api.snapshot(); api.setFxMute(true)
        api.applyMoveNoFx(side, m)
        local v = -search(api.opponent(side), d-1, -INF, INF, 1, deadline)
        api.setFxMute(false); api.restore(s)

        -- v が nil / NaN なら捨てる
        if v and v == v then
          if v > curBest + 1e-3 then
            curBest = v
            ties = { m }
          elseif math.abs(v - curBest) <= 1e-3 then
            ties[#ties+1] = m
          end
        end

        if timeUp(deadline) then break end
      end

      local curBestM = (#ties > 0) and ties[love.math.random(#ties)] or nil
      if curBestM then best, bestM = curBest, curBestM end
    end

    -- フォールバック：時間切れ等で未決なら合法手からランダム
    if not bestM then
      local moves = api.listLegalMoves(side)
      if #moves > 0 then
        bestM = moves[love.math.random(#moves)]
        best  = -INF
      end
    end

    return best, bestM
  end

  return { pick = pick }
end

return Search