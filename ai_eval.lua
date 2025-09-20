-- ai_eval.lua（学習・保存つき互換版）
local M = {}

function M.make(api, cfg)
  cfg = cfg or {}

  -- 盤サイズ（APIから取得、なければ8x8）
  local COLS = (api.consts and api.consts.GRID_COLS) or 8
  local ROWS = (api.consts and api.consts.GRID_ROWS) or 8

  -- 学習対象の重み（初期値はヒューリスティック）
  local W = {
    piece_count  = 1.00,  -- 駒枚数差
    kind_diff    = 0.60,  -- 色種類差
    danger       = -1.10, -- 危険駒
    defend       = 0.60,  -- 守られている駒
    last_penalty = -1.30, -- 残り1枚色の危険
    advance      = 0.20,  -- 前進
    center       = 0.10,  -- 中央寄り
    mobility     = 0.04,  -- 手の多さ
  }
  -- 上書き（cfg.weights があれば優先）
  if cfg.weights then
    for k,v in pairs(cfg.weights) do W[k] = v end
  end

  -- 重みの保存/読み込み
  local WEIGHT_FILE = "ai_weights_hard.txt"
  local function save()
    if not love.filesystem then return end
    local lines = {}
    for k,v in pairs(W) do
      lines[#lines+1] = string.format("%s\t%.17g", k, v)
    end
    love.filesystem.write(WEIGHT_FILE, table.concat(lines, "\n"))
  end
  local function load()
    if not love.filesystem or not love.filesystem.getInfo(WEIGHT_FILE) then return false end
    local data = love.filesystem.read(WEIGHT_FILE)
    if not data then return false end
    for line in data:gmatch("[^\r\n]+") do
      local k, v = line:match("^([%w_]+)%s+([%+%-%.%deE]+)$")
      if k and v then W[k] = tonumber(v) or W[k] end
    end
    return true
  end
  pcall(load)

  -- ここから特徴量
  local function idToSide(id)  return id and id:sub(2,2) or nil end
  local function colorOfId(id) return id and id:sub(1,1) or nil end

  local function rankProgress(side, r)
    return (side=="W") and (ROWS - r) or (r - 1)
  end
  local function centerBonus(c, r)
    local cx, cy = (COLS+1)/2, (ROWS+1)/2
    local dist = math.abs(c - cx) + math.abs(r - cy)
    local maxd = (cx-1) + (cy-1)
    return 1 - (dist / maxd)
  end

  local function features(side)
    local opp = api.opponent(side)

    -- 駒数 / 種類
    local sc, sk = api.sidePieceStats(side)
    local oc, ok = api.sidePieceStats(opp)

    -- 色ごとの残数
    local myColors = api.countColors(side)       -- {R=..,G=..,B=..}
    local opColors = api.countColors(opp)

    -- 危険/守備/ラスト色危険・位置（前進/中央）
    local myDanger, myDefend, myLast = 0, 0, 0
    local opDanger, opDefend, opLast = 0, 0, 0
    local posMe, posOp = 0, 0
    local cenMe, cenOp = 0, 0

    for r=1,ROWS do
      for c=1,COLS do
        local p = api.at(c,r)
        if p then
          local s   = idToSide(p.id)
          local col = colorOfId(p.id)
          if s == side then
            if api.isEndangered(side,c,r) then
              myDanger = myDanger + 1
              if myColors[col] == 1 then myLast = myLast + 1 end
            end
            if api.isDefended(side,c,r) then myDefend = myDefend + 1 end
            posMe = posMe + rankProgress(side, r)
            cenMe = cenMe + centerBonus(c, r)
          else
            if api.isEndangered(opp,c,r) then
              opDanger = opDanger + 1
              if opColors[col] == 1 then opLast = opLast + 1 end
            end
            if api.isDefended(opp,c,r) then opDefend = opDefend + 1 end
            posOp = posOp + rankProgress(opp, r)
            cenOp = cenOp + centerBonus(c, r)
          end
        end
      end
    end

    -- モビリティ
    local myMob = #api.listLegalMovesSide(side)
    local opMob = #api.listLegalMovesSide(opp)

    -- 差分ベースの特徴ベクトル
    local f = {
      piece_count  = (sc - oc),
      kind_diff    = (sk - ok),
      danger       = (myDanger - opDanger),
      defend       = (myDefend - opDefend),
      last_penalty = (myLast - opLast),
      advance      = (posMe - posOp),
      center       = (cenMe - cenOp),
      mobility     = (myMob - opMob),
    }
    return f
  end

  -- 評価：内積（学習器から (v,f) で使えるように特徴も返す）
  local function value(side)
    local f = features(side)
    local v = 0
    for k,fw in pairs(f) do
      v = v + (W[k] or 0) * fw
    end
    return v, f
  end

  -- エクスポート
  return {
    value      = value,
    features   = features,
    weights    = function() return W end,
    setWeights = function(newW) if newW then W = newW end end,
    save       = save,
    load       = load,
  }
end

return M