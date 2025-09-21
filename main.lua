-- ====== 基本設定 ======
local IMG_DIR = "img/"
local GRID_COLS, GRID_ROWS = 8, 8
local BOARD_INNER_PCT = { x=0.112, y=0.112, w=0.777, h=0.777 }
local PIECE_SCALE = 1.0
local PIECE_OX, PIECE_OY = 0, 0
local SHOW_DEBUG = false
local function opponent(side) return (side=="B") and "W" or "B" end
local flippedLayout
local resetGame
local tryMove
local LAYOUT
local CURRENT_LAYOUT
local makeAI_API
local AI = require("ai")
local Eval  = require("ai_eval")
local Learn = require("ai_learn")
local TRAIN = { enabled = false, learner = nil }
local function ensureLearner()
  if not TRAIN.learner then
    -- makeAI_API はこの後で定義されるので、呼ぶのは vsCOM 画面に入ってから
    local api = makeAI_API()
    local eval = Eval.make(api)
    TRAIN.learner = Learn.make(api, eval)
  end
end
local PIECE_ROTATION = 0

-- ===== UI layout tuning =====
local UI = {
  panelW = 560,
  panelH = 460,
  panelTopRatio = 0.18,
  sectionGap = 40,
  lineGap = 22,
  controlGap = 16,
  selectW = 300,
  selectH = 40,
  radioDx = 220,
  radioDxTight = 140,
}

-- ===== Training runner =====
local training = {
  active = false, cancel=false, coro=nil,
  total = 50, done = 0,
  eps = 0.05, lr = 0.01, gamma = 0.99, maxPlies = 300,
}

local function startTraining()
  if training.active then return end
  training.active, training.cancel, training.done = true, false, 0
  ensureLearner()
  training.coro = coroutine.create(function()
    for i=1, training.total do
      if training.cancel then break end
      TRAIN.learner.selfPlayOnce{
        lr=training.lr, eps=training.eps, gamma=training.gamma, maxPlies=training.maxPlies
      }
      training.done = i
      coroutine.yield()
    end
    training.active = false
  end)
end

local function stopTraining()
  training.cancel = true
end

local function pumpTraining()
  if training.coro and coroutine.status(training.coro) ~= "dead" then
    local ok, err = coroutine.resume(training.coro)
    if not ok then
      print("[training] error:", err)
      training.active = false
    end
  end
end

-- === Game config (declare early so every function closes over the same upvalue) ===
local gameConfig = {
  mode = "local",
  side = "W",
  difficulty = "Normal",
  online = { role="create", roomCode="", host="127.0.0.1", port=22122 }
}

-- フォント（日本語対応想定）
local FONTS_DIR = "fonts/"
local fonts = { ui=nil, title=nil, small=nil }
local function loadFonts()
  local ok
  ok, fonts.ui    = pcall(love.graphics.newFont, FONTS_DIR.."NotoSansJP-Regular.ttf", 18)
  ok, fonts.title = pcall(love.graphics.newFont, FONTS_DIR.."NotoSansJP-Bold.ttf",    36)
  ok, fonts.small = pcall(love.graphics.newFont, FONTS_DIR.."NotoSansJP-Regular.ttf", 14)
  if not fonts.ui    then fonts.ui    = love.graphics.newFont(18) end
  if not fonts.title then fonts.title = love.graphics.newFont(36) end
  if not fonts.small then fonts.small = love.graphics.newFont(14) end
end

-- 受信順制御用
local RX = { gotH=false, pendingS=nil, pendingC=nil }

-- ネット送信の再帰ループ抑止
local NET_MUTE = false

--↓一時的にコメントアウト
--local json = require("dkjson")
local function encodeSnapshot() return snapshot() end
local function decodeAndRestore(snap) restore(snap); return true end

-- net.lua 的な薄い層（1ファイルにしても可）
net = {
  role = nil,          -- "host" / "guest"
  connected = false,
  send = function(tbl) end,  -- 後で差し替え
  poll = function() end,     -- 後で差し替え
  close = function() end,
}

-- 疑似ネット（同一プロセス内で相手に即時届ける）
local loopbackPeer = nil

local function net_use_loopback(role)
  net.role = role
  net.connected = true
  function net.send(tbl)
    if tbl.type == "hello" and role == "host" then
      -- ゲストに初期状態配布
      local msg = { type="state", snap = encodeSnapshot() }
      loopbackPeer.onMessage(msg)  -- 擬似的に相手へ
    elseif tbl.type == "move" then
      loopbackPeer.onMessage({ type="move", from=tbl.from, to=tbl.to })
    elseif tbl.type == "reset" then
      loopbackPeer.onMessage({ type="reset" })
    end
  end
  function net.poll() end
  function net.close() net.connected=false end
end

-- オンライン用ハンドラ（ゲーム側が登録）
net.onMessage = function(msg)
  if msg.type == "state" then
    decodeAndRestore(msg.snap)
  elseif msg.type == "move" then
    tryMove({c=msg.from.c, r=msg.from.r}, msg.to.c, msg.to.r)
  elseif msg.type == "reset" then
    resetGame()
  end
end

-- ==== ネット薄層（ENet版：Love同梱、インストール不要） ====
local enet_ok, enet = pcall(require, "enet")

net = {
  role = nil,           -- "create" / "join"
  connected = false,
  server = nil,         -- host側: listen enet
  sock = nil,           -- 相手との接続
}

local _handleLine

local DEFAULT_HOST = "127.0.0.1"
local DEFAULT_PORT = 22122

-- ★第4引数 hostSide を受けるようにする（game_online.enter から渡している）
function net.start(role, host, port, hostSide)
  -- ★ 既存ホストがいれば掃除してから開始
  if net.host then net.close() end
  net.role = role
  net.ready = false
  net.handshake_side = hostSide or "W"
  if not enet_ok then
    print("[net] ENet が見つからないため通信なし（require 'enet' 失敗）")
    net.connected = false
    return
  end

  if role == "create" then
    net.host = assert(enet.host_create(("0.0.0.0:%d"):format(port or DEFAULT_PORT)))
    net.peer = nil
    net.connected = false
    net.ready = false
  else -- "join"
    net.host = assert(enet.host_create())
    net.peer = net.host:connect(("%s:%d"):format(host or DEFAULT_HOST, port or DEFAULT_PORT))
    net.connected = false
    net.ready = false
  end
end

function net.poll()
  if not enet_ok or not net.host then return end
  local event = net.host:service(0)
  while event do
    if event.type == "connect" then
      net.connected = true
      if net.role == "create" then
        net.peer = event.peer
        -- ホストはサイドを通知
        local hostSide = net.handshake_side or "W"
        net.peer:send(string.format("H %s\n", hostSide))
        net.peer:send("S " .. serializeState() .. "\n")
        net.peer:send("C " .. stateDigest() .. "\n")
        net.ready = true -- ホストは即 ready
      end
    elseif event.type == "receive" then
      _handleLine(event.data)
    elseif event.type == "disconnect" then
      net.connected = false
      net.peer = nil
      net.ready = false
      net.peer_lost = true
    end
    event = net.host:service(0)
  end
end

function net.sendLine(s)
  if not enet_ok then return end
  if net.peer and net.connected then
    net.peer:send(s)
  end
end

function net.close()
  if not enet_ok then return end
  pcall(function() if net.peer then net.peer:disconnect_now() end end)
  pcall(function()
    if net.host then
      net.host:flush()
      net.host:destroy()   -- ★ これが重要
    end
  end)
  net.host = nil
  net.peer = nil
  net.connected = false
  net.ready = false
  net.role = nil
  net.peer_lost = false
end
-- ==== /ネット薄層 ====

-- レイアウト
local PAD = 12
local TEXT_MAX_W = 360
local TEXT_RATIO = 0.2

-- 左下ボタン（実座標は動的）
local undoBtn  = { x = 0, y = 0, w = 84, h = 28 }
local resetBtn = { x = 0, y = 0, w = 84, h = 28 }
local goTitleBtn= { x = 0, y = 0, w = 84, h = 28 }
local WIN_MSG_OFFSET = 30

-- 消滅エフェクト設定
local EFFECT_GLOW = 0.18
local EFFECT_FADE = 0.35

-- ===== Scene system =====
local scenes = {}
local scene = "menu"
local function switchScene(name, ...)
  if scenes[name] and scenes[name].enter then scenes[name].enter(...) end
  scene = name
end
local function dispatch_update(dt)   if scenes[scene] and scenes[scene].update then scenes[scene].update(dt) end end
local function dispatch_draw()       if scenes[scene] and scenes[scene].draw   then scenes[scene].draw()     end end
local function dispatch_mousepressed(x,y,b) if scenes[scene] and scenes[scene].mousepressed then scenes[scene].mousepressed(x,y,b) end end
local function dispatch_keypressed(k) if scenes[scene] and scenes[scene].keypressed then scenes[scene].keypressed(k) end end
local function dispatch_textinput(t)  if scenes[scene] and scenes[scene].textinput  then scenes[scene].textinput(t)  end end

-- 共有 util
local function pointInRect(x,y,rx,ry,rw,rh) return x>=rx and x<=rx+rw and y>=ry and y<=ry+rh end

-- ボタン描画（縦センタリング）
local BUTTON_LABEL_TWEAK = -2
local function drawButton(btn, label, font)
  font = font or love.graphics.getFont()
  local fh = font:getHeight()
  local ty = btn.y + (btn.h - fh)/2 + BUTTON_LABEL_TWEAK
  love.graphics.setColor(0.85,0.85,0.85,1)
  love.graphics.rectangle("fill", btn.x, btn.y, btn.w, btn.h, 10,10)
  love.graphics.setColor(0,0,0,1)
  love.graphics.rectangle("line", btn.x, btn.y, btn.w, btn.h, 10,10)
  love.graphics.setFont(font)
  love.graphics.printf(label, btn.x, ty, btn.w, "center")
end

-- ラジオボタン風 UI（disabled 追加）
local function drawRadio(x, y, label, checked, disabled)
  disabled = disabled or false
  local r = 9
  local fh = love.graphics.getFont():getHeight()
  local a = disabled and 0.35 or 1.0

  love.graphics.setColor(0,0,0,a)
  love.graphics.circle("line", x, y, r, 24)
  if checked then love.graphics.circle("fill", x, y, r-4, 24) end

  love.graphics.setColor(0,0,0,a)
  love.graphics.print(label, x + 16, y - fh/2)

  return { x = x - r, y = y - r, w = r*2, h = r*2 }
end

-- セレクト風（キャプションは外で描く）
local function drawSelect(x,y,w,h,value)
  love.graphics.setColor(0.95,0.95,0.95,1)
  love.graphics.rectangle("fill", x, y, w, h, 8,8)
  love.graphics.setColor(0,0,0,1)
  love.graphics.rectangle("line", x, y, w, h, 8,8)
  local fh = love.graphics.getFont():getHeight()
  love.graphics.printf(value, x+8, y + (h - fh)/2 - 2, w-16, "left")
  return {x=x, y=y, w=w, h=h}
end

-- 画像/描画
local board, boardW, boardH
local boarda, boardWa, boardHa
local compati
local pieceImg = {}
local logo
local BOARD_INNER = { x=0, y=0, w=0, h=0 }
local scale, drawX, drawY
local TEXT_W = 240

-- 盤の向き
local BOARD_ROTATION = 0
local currentBottomSide = "W"

local function setBoardOrientation(bottomSide)
  currentBottomSide = bottomSide
  BOARD_ROTATION = (bottomSide == 'B') and math.pi or 0
end

local function fromCanonical(c, r)
  if currentBottomSide == 'B' then
    return GRID_COLS - c + 1, GRID_ROWS - r + 1
  else
    return c, r
  end
end

-- 盤データ／状態
local boardState = {}
for r=1,GRID_ROWS do boardState[r] = {} end

local applyLayout

local turnSide  = "W"
local selected  = nil
local history   = {}
local turnCount = 0
local gameOver  = false
local winner    = nil
local showResetConfirm = false
local showTitleConfirm  = false

-- 駒UID & 戻し禁止
local nextUID = 1
local restrictions = {}  -- uid -> {c,r,expiresAtMove,side}

-- 消滅エフェクトキュー
local effects = {}

-- 初期配置
LAYOUT = [[
0,g,g,0,0,b,b,0
g,g,r,r,r,r,b,b
0,0,0,0,0,0,0,0
0,0,0,0,0,0,0,0
0,0,0,0,0,0,0,0
0,0,0,0,0,0,0,0
G,G,R,R,R,R,B,B
0,G,G,0,0,B,B,0
]]

CURRENT_LAYOUT = LAYOUT

local CHAR2ID = { r="RB", g="GB", b="BB", R="RW", G="GW", B="BW", ["0"]=nil }

-- 便利関数
local function idToColor(id) return id:sub(1,1) end
local function idToSide(id)  return id:sub(2,2) end
local function colorBeats(a,b) return (a=="B" and b=="R") or (a=="R" and b=="G") or (a=="G" and b=="B") end

-- ====== Search budget ======
local SEARCH_TIME_LIMIT = 5
local SEARCH_NODE_LIMIT = 100000
local _searchDeadline = nil
local _searchNodes = 0

-- ========= ここから順序が重要（AIが呼ぶ関数を先に定義） =========

-- R/G/B の相性
local BEATS      = { B='R', R='G', G='B' }
local BEATEN_BY  = { R='B', G='R', B='G' }

-- 近傍4方向
local DIRS = { {0,-1},{0,1},{-1,0},{1,0} }

local function forEachNeighbor(c,r,fn)
  for _,d in ipairs(DIRS) do
    local cc,rr = c+d[1], r+d[2]
    if cc>=1 and cc<=GRID_COLS and rr>=1 and rr<=GRID_ROWS then fn(cc,rr) end
  end
end

-- 自陣→敵陣への“進み具合”（0 … 自陣端 / GRID_ROWS-1 … 敵陣端）
local function rankProgress(side, r)
  return (side=="W") and (GRID_ROWS - r) or (r - 1)
end

-- 盤中央ボーナス（0〜1）
local function centerBonus(c, r)
  local cx, cy = (GRID_COLS+1)/2, (GRID_ROWS+1)/2
  local dist = math.abs(c - cx) + math.abs(r - cy)
  local maxd = (cx-1) + (cy-1)
  return 1 - (dist / maxd)
end

-- 盤内か
local function inBoard(c,r) return c>=1 and c<=GRID_COLS and r>=1 and r<=GRID_ROWS end
-- 4近傍判定
local function isAdj4(c1,r1,c2,r2) return (math.abs(c1-c2)+math.abs(r1-r2))==1 end

-- スナップショット（UndoやAIシミュレーション用）
local function snapshot()
  local s = { turnSide=turnSide, turnCount=turnCount, gameOver=gameOver, winner=winner, nextUID=nextUID }
  local grid = {}
  for r=1,GRID_ROWS do
    grid[r]={}
    for c=1,GRID_COLS do
      local p = boardState[r][c]
      grid[r][c] = p and { id=p.id, uid=p.uid } or nil
    end
  end
  s.board = grid
  local restr = {}
  for uid,info in pairs(restrictions) do
    restr[uid] = { c=info.c, r=info.r, expiresAtMove=info.expiresAtMove, side=info.side }
  end
  s.restrictions = restr
  return s
end

local function restore(s)
  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local p = s.board[r][c]
      boardState[r][c] = p and { id=p.id, uid=p.uid } or nil
    end
  end
  restrictions = {}
  for uid,info in pairs(s.restrictions or {}) do
    restrictions[uid] = { c=info.c, r=info.r, expiresAtMove=info.expiresAtMove, side=info.side }
  end
  nextUID   = s.nextUID or nextUID
  turnSide  = s.turnSide
  turnCount = s.turnCount or 0
  gameOver  = s.gameOver or false
  winner    = s.winner
  selected  = nil
  effects   = {}
end

-- 勝敗（OR 条件）
local function sidePieceStats(side)
  local count, colors = 0, {R=false,G=false,B=false}
  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local p = boardState[r][c]
      if p and idToSide(p.id)==side then
        count = count + 1
        colors[idToColor(p.id)] = true
      end
    end
  end
  local kinds = (colors.R and 1 or 0) + (colors.G and 1 or 0) + (colors.B and 1 or 0)
  return count, kinds
end

local function checkGameEnd(moverSide)
  local cb, kb = sidePieceStats("B")
  local cw, kw = sidePieceStats("W")
  local loseB = (kb <= 2) or (cb <= 3)
  local loseW = (kw <= 2) or (cw <= 3)
  if loseB and loseW then
    return opponent(moverSide)
  elseif loseB then
    return "W"
  elseif loseW then
    return "B"
  else
    return nil
  end
end

-- 描画用・消滅エフェクト
local function addEffect(id, c, r)
  if FX_MUTE then return end
  table.insert(effects, { id=id, c=c, r=r, t=0, phase="glow" })
end

-- 隣接解決（本番）
local function resolveAdjacency(c, r)
  local self = boardState[r][c]; if not self then return end
  local selfColor = idToColor(self.id)
  local selfSide  = idToSide(self.id)
  local rm = {}
  local function mark(cc,rr) rm[rr]=rm[rr] or {}; rm[rr][cc]=true end
  local dirs = { {0,-1}, {0,1}, {-1,0}, {1,0} }
  local selfLose=false
  for _,d in ipairs(dirs) do
    local cc,rr = c+d[1], r+d[2]
    if inBoard(cc,rr) then
      local p = boardState[rr][cc]
      if p and idToSide(p.id) ~= selfSide then
        local nColor = idToColor(p.id)
        if nColor == selfColor then
          selfLose=true; mark(cc,rr)
        else
          if colorBeats(selfColor,nColor) then mark(cc,rr)
          elseif colorBeats(nColor,selfColor) then selfLose=true end
        end
      end
    end
  end
  for rr,row in pairs(rm) do
    for cc,_ in pairs(row) do
      local p = boardState[rr][cc]
      if p then addEffect(p.id, cc, rr) end
      boardState[rr][cc]=nil
    end
  end
  if selfLose then
    local p = boardState[r][c]
    if p then addEffect(p.id, c, r) end
    boardState[r][c]=nil
  end
end

-- 隣接解決（AIシミュ：効果なし）
local function resolveAdjacencySim(c, r)
  local self = boardState[r][c]; if not self then return end
  local selfColor = idToColor(self.id)
  local selfSide  = idToSide(self.id)
  local rm = {}
  local function mark(cc,rr) rm[rr]=rm[rr] or {}; rm[rr][cc]=true end
  local dirs = { {0,-1}, {0,1}, {-1,0}, {1,0} }
  local selfLose=false
  for _,d in ipairs(dirs) do
    local cc,rr = c+d[1], r+d[2]
    if inBoard(cc,rr) then
      local p = boardState[rr][cc]
      if p and idToSide(p.id) ~= selfSide then
        local nColor = idToColor(p.id)
        if nColor == selfColor then
          selfLose=true; mark(cc,rr)
        else
          if colorBeats(selfColor,nColor) then mark(cc,rr)
          elseif colorBeats(nColor,selfColor) then selfLose=true end
        end
      end
    end
  end
  for rr,row in pairs(rm) do
    for cc,_ in pairs(row) do
      boardState[rr][cc]=nil
    end
  end
  if selfLose then boardState[r][c]=nil end
end

-- ★AI用フラグ：評価シミュレーション中は視覚エフェクト抑止
FX_MUTE = false

-- 戻し禁止（※ isEndangered より前に置く）
local function violatesReturnRule(p, toC, toR, sideAtMove, turnAt)
  if not p then return false end
  local info = restrictions[p.uid]; if not info then return false end
  sideAtMove = sideAtMove or turnSide
  turnAt     = (turnAt ~= nil) and turnAt or turnCount
  return (info.side == sideAtMove) and (info.expiresAtMove == turnAt)
         and (info.c == toC and info.r == toR)
end

-- 移動可否
local function canMove(from, toC, toR, sideAtMove, turnAt)
  if not from then return false end
  if not isAdj4(from.c, from.r, toC, toR) then return false end
  if not inBoard(toC,toR) then return false end
  if boardState[toR][toC] ~= nil then return false end
  local p = boardState[from.r][from.c]
  if violatesReturnRule(p, toC, toR, sideAtMove, turnAt) then return false end
  return true
end

-- 指定サイドの全合法手
local function listLegalMoves(side, ply)
  ply = ply or 0
  local moves = {}
  local turnAt = turnCount + ply
  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local p = boardState[r][c]
      if p and idToSide(p.id)==side then
        for _,d in ipairs(DIRS) do
          local tc, tr = c+d[1], r+d[2]
          if inBoard(tc,tr) and boardState[tr][tc]==nil then
            if canMove({c=c,r=r}, tc, tr, side, turnAt) then
              table.insert(moves, { from={c=c,r=r,uid=p.uid}, to={c=tc,r=tr} })
            end
          end
        end
      end
    end
  end
  return moves
end

-- サイド指定の戻し禁止チェック（AIシミュ用）
local function violatesReturnRuleForSide(p, toC, toR, side)
  if not p then return false end
  local info = restrictions[p.uid]; if not info then return false end
  return (info.side == side) and (info.expiresAtMove == turnCount)
         and (info.c == toC and info.r == toR)
end
local function canMoveSide(from, toC, toR, side)
  if not from then return false end
  if not isAdj4(from.c, from.r, toC, toR) then return false end
  if not inBoard(toC,toR) then return false end
  if boardState[toR][toC] ~= nil then return false end
  local p = boardState[from.r][from.c]
  if violatesReturnRuleForSide(p, toC, toR, side) then return false end
  return true
end
local function listLegalMovesSide(side)
  local moves = {}
  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local p = boardState[r][c]
      if p and idToSide(p.id)==side then
        for _,d in ipairs(DIRS) do
          local tc, tr = c+d[1], r+d[2]
          if boardState[tr] and boardState[tr][tc]==nil then
            local from = {c=c,r=r}
            if canMoveSide(from, tc, tr, side) then
              table.insert(moves, { from={c=c,r=r,uid=p.uid}, to={c=tc,r=tr} })
            end
          end
        end
      end
    end
  end
  return moves
end

-- その駒が“次の相手手番”で取られうるか
local function isEndangered(side, c, r)
  local p = boardState[r] and boardState[r][c]; if not p then return false end
  if idToSide(p.id) ~= side then return false end
  local myCol = idToColor(p.id)
  local opp   = opponent(side)

  -- ① すでに隣に脅威がいる？
  for _,d in ipairs(DIRS) do
    local cc,rr = c+d[1], r+d[2]
    if inBoard(cc,rr) then
      local q = boardState[rr][cc]
      if q and idToSide(q.id)==opp then
        local qc = idToColor(q.id)
        if qc==myCol or colorBeats(qc, myCol) then
          return true
        end
      end
    end
  end
  -- ② 相手が1歩で隣接へ踏み込める？（戻し禁止も考慮）
  for rr=1,GRID_ROWS do
    for cc=1,GRID_COLS do
      local q = boardState[rr][cc]
      if q and idToSide(q.id)==opp then
        local qc = idToColor(q.id)
        if qc==myCol or colorBeats(qc, myCol) then
          for _,d in ipairs(DIRS) do
            local tc, tr = cc+d[1], rr+d[2]
            if inBoard(tc,tr) and boardState[tr][tc]==nil and isAdj4(tc,tr,c,r) then
              if not violatesReturnRule(q, tc, tr, opp, turnCount) then
                return true
              end
            end
          end
        end
      end
    end
  end
  return false
end

-- 味方に“守られて”いるか
local function isDefended(side, c, r)
  local p = boardState[r] and boardState[r][c]; if not p then return false end
  if idToSide(p.id) ~= side then return false end
  local myCol = idToColor(p.id)
  for _,d in ipairs(DIRS) do
    local cc,rr = c+d[1], r+d[2]
    if inBoard(cc,rr) then
      local q = boardState[rr][cc]
      if q and idToSide(q.id)==side and colorBeats(idToColor(q.id), myCol) then
        return true
      end
    end
  end
  return false
end

local function countColors(side)
  local n = {R=0,G=0,B=0}
  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local p = boardState[r][c]
      if p and idToSide(p.id)==side then n[idToColor(p.id)] = n[idToColor(p.id)] + 1 end
    end
  end
  return n
end

-- その駒（side側）の「安全な逃げ場」が1つでもあるか（局所シミュレーション）
local function pieceHasSafeMove(side, c, r)
  local p = boardState[r] and boardState[r][c]; if not p then return false end
  if idToSide(p.id) ~= side then return false end

  for _,d in ipairs(DIRS) do
    local tc, tr = c + d[1], r + d[2]
    if inBoard(tc,tr) and boardState[tr][tc]==nil then
      if canMoveSide({c=c,r=r}, tc, tr, side) then
        local snap = snapshot(); FX_MUTE = true
        local uid = p.uid
        -- 動かして隣接解決をシミュレート
        boardState[r][c] = nil
        boardState[tr][tc] = p
        restrictions[uid] = { c=c, r=r, expiresAtMove=turnCount+2, side=side }
        resolveAdjacencySim(tc, tr)
        -- 移動先で生き残っているか（UIDで確認）
        local alive = boardState[tr][tc] and boardState[tr][tc].uid == uid
        FX_MUTE = false; restore(snap)
        if alive then return true end
      end
    end
  end
  return false
end

-- (side) が相手の (c,r) にある駒をロックしているか？
local function isLockedBy(side, c, r)
  local p = boardState[r] and boardState[r][c]; if not p then return false end
  if idToSide(p.id) == side then return false end
  local opp = idToSide(p.id)
  local col = idToColor(p.id)

  -- まず“有利色での圧”が隣にあるか（= ロックの前提）
  local pressured = false
  for _,d in ipairs(DIRS) do
    local nc, nr = c + d[1], r + d[2]
    if inBoard(nc,nr) then
      local q = boardState[nr][nc]
      if q and idToSide(q.id) == side then
        local qc = idToColor(q.id)
        if qc == col or colorBeats(qc, col) then
          pressured = true; break
        end
      end
    end
  end
  if not pressured then return false end

  -- 相手に“安全な逃げ場”が無いならロック成立
  return not pieceHasSafeMove(opp, c, r)
end

-- side 視点で、相手駒のうちロックできている数
local function countLockedFor(side)
  local k = 0
  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      if isLockedBy(side, c, r) then k = k + 1 end
    end
  end
  return k
end

local function countEndangered(side)
  local k = 0
  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local p = boardState[r][c]
      if p and idToSide(p.id)==side and isEndangered(side,c,r) then k = k + 1 end
    end
  end
  return k
end

-- 移動先における簡易タクティカル評価（並べ替え用）
local function quickMoveTacticalScore(side, m)
  local from = boardState[m.from.r][m.from.c]; if not from then return 0 end
  local myC = idToColor(from.id)

  -- 捕獲/交換/自滅の局所評価
  local cap, die, trade = 0,0,0
  forEachNeighbor(m.to.c, m.to.r, function(nc,nr)
    local q = boardState[nr][nc]
    if q and idToSide(q.id)==opponent(side) then
      local eC = idToColor(q.id)
      if     colorBeats(myC, eC) then cap = cap + 1
      elseif myC == eC           then trade = trade + 1
      elseif colorBeats(eC, myC) then die = die + 1 end
    end
  end)

  local tactical = cap*10 + trade*3 - die*9

  -- ★ 前進嗜好（後退は軽い減点）
  local dr = m.to.r - m.from.r
  local fwd = (side=="W") and (-dr) or (dr)  -- 前進:+1, 後退:-1, 横:0
  local lane = 1.2 * fwd                     -- 効きすぎない程度
  if fwd < 0 then lane = lane - 0.6 end      -- 純粋な後退に軽いペナルティ

  -- ★ 背面2段からの離脱は少しボーナス（通路を開ける）
  local backRank = (side=="W") and (m.from.r>=GRID_ROWS-1) or (m.from.r<=2)
  if backRank and fwd>0 then lane = lane + 0.8 end

  return tactical + lane
end

-- 盤面評価：素点+色/安全性+ロック+位置(前進/中央)+モビリティ
local function evaluateBoardFor(side)
  local sc, sk = sidePieceStats(side)
  local oc, ok = sidePieceStats(opponent(side))
  local base      = (sc - oc)
  local kindBonus = 0.6 * (sk - ok)

  local myColors  = countColors(side)
  local opColors  = countColors(opponent(side))

  local dangerW, defendW, lastW = 1.1, 0.6, 1.3
  local myDanger, myDefend, myLastPenalty = 0,0,0
  local opDanger, opDefend, opLastPenalty = 0,0,0

  -- ★ 位置評価（前進・中央）
  local posMe, posOp = 0, 0
  local advanceW, centerW = 0.20, 0.10  -- 前進の重み / 中央の重み

  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local p = boardState[r][c]
      if p then
        local s   = idToSide(p.id)
        local col = idToColor(p.id)

        if s == side then
          -- 安全性
          if isEndangered(side,c,r) then
            myDanger = myDanger + 1
            if myColors[col] == 1 then myLastPenalty = myLastPenalty + 1 end
          end
          if isDefended(side,c,r) then myDefend = myDefend + 1 end
          -- 位置
          posMe = posMe + advanceW * rankProgress(side, r)
                         + centerW  * centerBonus(c, r)
        else
          if isEndangered(opponent(side),c,r) then
            opDanger = opDanger + 1
            if opColors[col] == 1 then opLastPenalty = opLastPenalty + 1 end
          end
          if isDefended(opponent(side),c,r) then opDefend = opDefend + 1 end
          posOp = posOp + advanceW * rankProgress(opponent(side), r)
                         + centerW  * centerBonus(c, r)
        end
      end
    end
  end

  local safety = (-dangerW*myDanger + defendW*myDefend - lastW*myLastPenalty)
               - (-dangerW*opDanger + defendW*opDefend - lastW*opLastPenalty)

  -- ★ ロック圧（前ステップで追加済みの countLockedFor を利用）
  local myLocks = countLockedFor(side)
  local opLocks = countLockedFor(opponent(side))
  local lockW   = 1.2
  local lockScore = lockW * (myLocks - opLocks)

  -- ★ モビリティ（動ける手数）
  local myMob = #listLegalMovesSide(side)
  local opMob = #listLegalMovesSide(opponent(side))
  local mobility = 0.04 * (myMob - opMob)

  -- ★ 位置差
  local positional = (posMe - posOp)

  return base + kindBonus + safety + lockScore + positional + mobility
end

-- エフェクト無しで1手だけ適用（重複を排除：これ1つに統一）
local function applyMoveNoFx(side, move)
  local fromC, fromR = move.from.c, move.from.r
  local toC,   toR   = move.to.c,   move.to.r
  local mover = boardState[fromR][fromC]
  boardState[toR][toC]     = mover
  boardState[fromR][fromC] = nil
  restrictions[mover.uid] = { c=fromC, r=fromR, expiresAtMove=turnCount+2, side=side }
  resolveAdjacencySim(toC, toR)
end

-- 1手だけ適用して即時スコア（取り/自滅/盤面評価）を返す
local function scoreMoveImmediate(side, move)
  local s = snapshot()
  FX_MUTE = true

  local fromC, fromR = move.from.c, move.from.r
  local toC,   toR   = move.to.c,   move.to.r
  local mover = boardState[fromR][fromC]
  boardState[toR][toC]     = mover
  boardState[fromR][fromC] = nil
  restrictions[mover.uid] = { c=fromC, r=fromR, expiresAtMove=turnCount+2, side=side }
  resolveAdjacencySim(toC, toR)

  local win = checkGameEnd(side)
  local score
  if win == side then
    score =  1e6
  elseif win == opponent(side) then
    score = -1e6
  else
    score = evaluateBoardFor(side)
  end

  FX_MUTE = false
  restore(s)
  return score
end

-- この一手を指した“直後の決着”で、手番側が負けるか？
local function isImmediateLossFor(side, move)
  local s = snapshot(); FX_MUTE = true
  applyMoveNoFx(side, move)
  local win = checkGameEnd(side)   -- 両者同時負け→opponent(side)が返る仕様を利用
  FX_MUTE = false; restore(s)
  return win == opponent(side)
end

-- 自滅（即負け）手を除外。ただし全手が即負けなら除外しない
local function filterSuicidalMoves(side, moves)
  local good = {}
  for _,m in ipairs(moves) do
    if not isImmediateLossFor(side, m) then table.insert(good, m) end
  end
  return (#good > 0) and good or moves
end

-- negamax: 手番 side 視点。αβ＋簡易静止拡張
local function negamax(side, depth, alpha, beta)
  _searchNodes = _searchNodes + 1
  if _searchNodes >= SEARCH_NODE_LIMIT then
    return evaluateBoardFor(side)
  end
  if _searchDeadline and love.timer.getTime() >= _searchDeadline then
    return evaluateBoardFor(side)
  end

  -- 深さ0：静止拡張で“戦闘中”だけを1手読む
  if depth == 0 then
    local stand = evaluateBoardFor(side)

    local moves = listLegalMoves(side)
    table.sort(moves, function(a,b)
      return quickMoveTacticalScore(side,a) > quickMoveTacticalScore(side,b)
    end)

    local best = stand
    local EXT_LIMIT = 6
    local used = 0
    for _,m in ipairs(moves) do
      if quickMoveTacticalScore(side,m) > 0 then
        local s = snapshot(); FX_MUTE = true
        applyMoveNoFx(side, m)
        local val = -negamax(opponent(side), 1, -beta, -alpha)
        FX_MUTE = false; restore(s)
        if val > best then best = val end
        if best > alpha then alpha = best end
        if alpha >= beta then break end
        used = used + 1; if used >= EXT_LIMIT then break end
      end
    end
    return best
  end

  local moves = listLegalMoves(side)
  if #moves == 0 then
    local win = checkGameEnd(side)
    if win == side then return  1e6
    elseif win == opponent(side) then return -1e6
    else return evaluateBoardFor(side) end
  end

  -- （negamax内）一時的な並べ替え用詳細スコア
  local function _sortScore(side, m)
    local s0_end = countEndangered(side)
    local snap = snapshot(); FX_MUTE = true

    local fromC,fromR = m.from.c, m.from.r
    local toC,toR     = m.to.c,   m.to.r
    local mover = boardState[fromR][fromC]
    boardState[toR][toC] = mover; boardState[fromR][fromC] = nil
    restrictions[mover.uid] = { c=fromC, r=fromR, expiresAtMove=turnCount+2, side=side }
    resolveAdjacencySim(toC, toR)

    local s1_me  = countEndangered(side)
    local s1_op  = countEndangered(opponent(side))

    FX_MUTE = false; restore(snap)

    local improve = (s0_end - s1_me) + 0.5 * s1_op
    local greedy  = scoreMoveImmediate(side, m) * 0.05
    return improve + greedy
  end

  table.sort(moves, function(a,b)
    return _sortScore(side, a) > _sortScore(side, b)
  end)

  local best = -math.huge
  for _,m in ipairs(moves) do
    local s = snapshot(); FX_MUTE = true
    applyMoveNoFx(side, m)
    local win = checkGameEnd(side)
    local val
    if win == side then
      val = 1e6
    elseif win == opponent(side) then
      val = -1e6
    else
      val = -negamax(opponent(side), depth-1, -beta, -alpha)
    end
    FX_MUTE = false; restore(s)

    if val > best then best = val end
    if best > alpha then alpha = best end
    if alpha >= beta then break end
  end
  return best
end

-- mySide が myMove を指した後、相手の最善応手まで見たスコア
local function scoreAfterOpponentBestReply(mySide, myMove)
  local s0 = snapshot()
  FX_MUTE = true

  do
    local fromC, fromR = myMove.from.c, myMove.from.r
    local toC,   toR   = myMove.to.c,   myMove.to.r
    local mover = boardState[fromR][fromC]
    boardState[toR][toC]     = mover
    boardState[fromR][fromC] = nil
    restrictions[mover.uid] = { c=fromC, r=fromR, expiresAtMove=turnCount+2, side=mySide }
    resolveAdjacencySim(toC, toR)
  end

  do
    local win = checkGameEnd(mySide)
    if win == mySide then FX_MUTE=false; restore(s0); return 1e6 end
    if win == opponent(mySide) then FX_MUTE=false; restore(s0); return -1e6 end
  end

  local opp = opponent(mySide)
  local replies = listLegalMoves(opp)
  if #replies == 0 then
    local val = evaluateBoardFor(mySide)
    FX_MUTE=false; restore(s0); return val
  end

  local worst = math.huge
  for _,rm in ipairs(replies) do
    local s1 = snapshot()

    local rfC, rfR = rm.from.c, rm.from.r
    local rtC, rtR = rm.to.c,   rm.to.r
    local mover2 = boardState[rfR][rfC]
    boardState[rtR][rtC]     = mover2
    boardState[rfR][rfC]     = nil
    restrictions[mover2.uid] = { c=rfC, r=rfR, expiresAtMove=turnCount+2, side=opp }
    resolveAdjacencySim(rtC, rtR)

    local win2 = checkGameEnd(opp)
    local sc
    if win2 == opp then
      sc = -1e6
    elseif win2 == mySide then
      sc = 1e6
    else
      sc = evaluateBoardFor(mySide)
    end

    if sc < worst then worst = sc end
    restore(s1)
  end

  FX_MUTE=false
  restore(s0)
  return worst
end

-- 深読み（相手の最善応手まで読む）
local function scoreMoveDepth(side, move, depth)
  local function apply_and_score(currentSide, m)
    local s = snapshot(); FX_MUTE = true
    local fromC, fromR = m.from.c, m.from.r
    local toC,   toR   = m.to.c,   m.to.r
    local mover = boardState[fromR][fromC]
    boardState[toR][toC]   = mover
    boardState[fromR][fromC] = nil
    restrictions[mover.uid] = { c=fromC, r=fromR, expiresAtMove=turnCount+2, side=currentSide }
    resolveAdjacencySim(toC, toR)
    local win = checkGameEnd(currentSide)
    local scr
    if win == currentSide then
      scr =  1e6
    elseif win == opponent(currentSide) then
      scr = -1e6
    else
      scr = evaluateBoardFor(side)
    end
    FX_MUTE = false
    return scr, s
  end

  if depth <= 1 then
    return scoreMoveImmediate(side, move)
  end

  local scoreAfterMyMove, snap = apply_and_score(side, move)
  if math.abs(scoreAfterMyMove) >= 1e6 then
    restore(snap)
    return scoreAfterMyMove
  end

  local opp = opponent(side)
  local oppMoves = listLegalMoves(opp)
  if #oppMoves == 0 then
    restore(snap)
    return scoreAfterMyMove
  end

  local worstForMe = math.huge
  for _, om in ipairs(oppMoves) do
    local oppScore = scoreMoveImmediate(opp, om)
    if oppScore < worstForMe then
      worstForMe = oppScore
    end
  end

  restore(snap)
  return worstForMe
end

-- 本番の1手実行
function tryMove(from, toC, toR)
  if gameOver then return false end
  if not canMove(from, toC, toR) then return false end

  table.insert(history, snapshot())

  local mover = boardState[from.r][from.c]
  boardState[toR][toC] = mover
  boardState[from.r][from.c] = nil
  restrictions[mover.uid] = { c=from.c, r=from.r, expiresAtMove=turnCount+2, side=turnSide }

  resolveAdjacency(toC, toR)

  selected = nil
  turnCount = turnCount + 1

  local win = checkGameEnd(turnSide)
  if win then
    gameOver = true
    winner   = win
    local loser = opponent(win)
    for r=1,GRID_ROWS do
      for c=1,GRID_COLS do
        local p = boardState[r][c]
        if p and idToSide(p.id)==loser then
          addEffect(p.id, c, r)
          boardState[r][c] = nil
        end
      end
    end
  else
    turnSide = opponent(turnSide)
  end

  -- ★オンライン時は相手へ通知（受信適用中は送らない）
  if gameConfig.mode=="online" and net and net.connected and not NET_MUTE then
    net.sendLine(string.format("M %d %d %d %d\n", from.c, from.r, toC, toR))
    net.sendLine("C " .. stateDigest() .. "\n")
  end

  return true
end

-- ========= ここまでがAIが使う基盤 =========

-- Reset
resetGame = function()
  applyLayout(CURRENT_LAYOUT)
  restrictions = {}; effects = {}
  turnSide  = "W"
  turnCount = 1
  gameOver  = false
  winner    = nil
  selected  = nil
  history   = {}
end

-- 座標系・レイアウト
local function layoutUI()
  local winW, winH = love.graphics.getDimensions()
  TEXT_W = math.min(TEXT_MAX_W, math.floor(winW * TEXT_RATIO))
  local availW = winW - TEXT_W - PAD*2
  scale = math.min(availW / boardW, (winH - PAD*2) / boardH)
  drawX = winW - PAD - boardW * scale
  drawY = (winH - boardH * scale) / 2
  local gap = 8

  -- ボタンを上から順に
  undoBtn.x  = PAD
  undoBtn.y  = winH - PAD - (undoBtn.h + resetBtn.h + goTitleBtn.h + gap*2)
  resetBtn.x = PAD
  resetBtn.y = undoBtn.y + undoBtn.h + gap
  goTitleBtn.x = PAD
  goTitleBtn.y = resetBtn.y + resetBtn.h + gap
end

local function stepSize() return BOARD_INNER.w/7, BOARD_INNER.h/7 end
local function toScreen(c, r)
  local sX, sY = stepSize()
  local cx = BOARD_INNER.x + (c-1)*sX
  local cy = BOARD_INNER.y + (r-1)*sY
  return drawX + cx*scale, drawY + cy*scale, sX*scale, sY*scale
end

-- 交点クリック用のヒット半径係数（ハイライトと同程度）
local HIT_RADIUS_FACTOR = 0.48  -- 必要なら 0.45〜0.50 で微調整

local function toGrid(mx, my)
  -- 画面→ボード座標
  local ix = (mx - drawX) / scale
  local iy = (my - drawY) / scale

  local sX, sY = stepSize()

  -- 1) 最寄り交点を求める（交点=罫線交差）
  local u = (ix - BOARD_INNER.x) / sX
  local v = (iy - BOARD_INNER.y) / sY
  local c = math.floor(u + 0.5) + 1
  local r = math.floor(v + 0.5) + 1

  -- 盤外に丸められた場合は端にクランプ
  if c < 1 then c = 1 elseif c > GRID_COLS then c = GRID_COLS end
  if r < 1 then r = 1 elseif r > GRID_ROWS then r = GRID_ROWS end

  -- 2) その交点の“実座標”
  local cx = BOARD_INNER.x + (c - 1) * sX
  local cy = BOARD_INNER.y + (r - 1) * sY

  -- 3) 交点近傍の円でヒット判定（盤外へはみ出していてもOK）
  local dx, dy = ix - cx, iy - cy
  local radius = math.min(sX, sY) * HIT_RADIUS_FACTOR
  if (dx*dx + dy*dy) <= (radius * radius) then
    local c, r = c, r
    if currentBottomSide == 'B' then
      c = GRID_COLS - c + 1
      r = GRID_ROWS - r + 1
    end
    return c, r
  else
    return nil
  end
end

-- レイアウト適用
local function newPiece(id) local p={id=id, uid=nextUID}; nextUID=nextUID+1; return p end
applyLayout = function(layout)
  -- 中身はそのまま（newPiece 呼び出しや盤面構築の処理）
  for r=1,GRID_ROWS do boardState[r]={} end
  restrictions = {}; effects = {}; nextUID=1
  local rows={}
  for line in layout:gmatch("[^\r\n]+") do
    line=line:gsub("%s+",""); if line~="" then table.insert(rows,line) end
  end
  for r=1,GRID_ROWS do
    local cols={}
    for cell in rows[r]:gmatch("[^,]+") do table.insert(cols,cell) end
    for c=1,GRID_COLS do
      local id=CHAR2ID[cols[c]]
      boardState[r][c]= id and newPiece(id) or nil
    end
  end
end

-- レイアウト上下反転（サイドは入れ替えない）
flippedLayout = function(layout)
  local rows = {}
  for line in layout:gmatch("[^\r\n]+") do
    line = line:gsub("%s+","")
    if line ~= "" then table.insert(rows, line) end
  end
  local newRows = {}
  for i = #rows, 1, -1 do
    table.insert(newRows, rows[i])
  end
  return table.concat(newRows, "\n")
end

_handleLine = function(line)
  if not line or line == "" then return end
  local cmd = line:sub(1,1)

  if cmd == 'H' then
    local side = line:match("^H%s+([WB])")
    if side then
      gameConfig.side = opponent(side)
      CURRENT_LAYOUT = LAYOUT
      setBoardOrientation(gameConfig.side)

      RX.gotH = true

      -- ★H 受信後にペンディングを適用
      if RX.pendingS then
        applySerializedState(RX.pendingS.tc, RX.pendingS.ts, RX.pendingS.bs)
        RX.pendingS = nil
      end
      if RX.pendingC then
        -- ここで整合性チェック（省略可）
        NET_DESYNC = (stateDigest() ~= RX.pendingC.hash)
        RX.pendingC = nil
      end

      net.ready = true
    end

  elseif cmd == 'S' then
    local tc, ts, bs = line:match("^S%s+(%d+)%s+([WB])%s+(%S+)")
    if tc and ts and bs and #bs == GRID_COLS*GRID_ROWS*2 then
      if RX.gotH then
        applySerializedState(tc, ts, bs)     -- ★H 済 → 即適用
        NET_DESYNC = false
        net.ready  = true
      else
        RX.pendingS = { tc=tc, ts=ts, bs=bs } -- ★H 前 → 保留
      end
    end

  elseif cmd == 'C' then
    local hash = line:match("^C%s+([0-9a-fA-F]+)")
    if hash then
      if RX.gotH then
        NET_DESYNC = (stateDigest() ~= hash)
        if NET_DESYNC and net.role == "join" then net.sendLine("G\n") end
      else
        RX.pendingC = { hash = hash }  -- ★H 前 → 保留
      end
    end

  elseif cmd == 'G' then
    if net.role == "create" then
      net.sendLine("S " .. serializeState() .. "\n")
      net.sendLine("C " .. stateDigest() .. "\n")
    end
  elseif cmd == 'R' then
    resetGame()
  elseif cmd == 'M' then
    local c,r,tc,tr = line:match("^M%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
    if c then
      c,r,tc,tr = tonumber(c), tonumber(r), tonumber(tc), tonumber(tr)
      NET_MUTE = true
      tryMove({c=c, r=r}, tc, tr)
      NET_MUTE = false
    end
  end
end

-- forward declarations (must be before scenes.* use them)
local handleResetModalClick
local handleTitleModalClick

-- ====== GAME共通ロジック ======
local function layoutResetModal()
  local ww, hh = love.graphics.getDimensions()
  local pad   = 16
  local btnW, btnH, gap = 100, 34, 20
  local mw = math.min(460, math.floor(ww * 0.7))
  local mx = (ww - mw) / 2
  local title = "Reset the game?"
  local desc  = "This will set: White to move, Moves = 1."
  local font  = fonts.ui or love.graphics.getFont()
  local _, wrapTitle = font:getWrap(title, mw - pad*2)
  local _, wrapDesc  = font:getWrap(desc,  mw - pad*2)
  local lineH = font:getHeight()
  local textH = (#wrapTitle + #wrapDesc) * lineH + 10
  local mh = pad + textH + pad + btnH + pad
  local my = (hh - mh) / 2
  local yBtn = my + mh - pad - btnH
  local bx1  = mx + mw/2 - gap/2 - btnW
  local bx2  = mx + mw/2 + gap/2
  local yes = { x = bx1, y = yBtn, w = btnW, h = btnH }
  local no  = { x = bx2, y = yBtn, w = btnW, h = btnH }
  return {mx=mx,my=my,mw=mw,mh=mh,pad=pad,title=title,desc=desc,yes=yes,no=no}
end

local function layoutGoTitleModal()
  local ww, hh = love.graphics.getDimensions()
  local pad   = 16
  local btnW, btnH, gap = 100, 34, 20
  local mw = math.min(460, math.floor(ww * 0.7))
  local mx = (ww - mw) / 2
  local title = "Return to Title?"
  local desc  = "Current game will be lost."
  local font  = fonts.ui or love.graphics.getFont()
  local _, wrapTitle = font:getWrap(title, mw - pad*2)
  local _, wrapDesc  = font:getWrap(desc,  mw - pad*2)
  local lineH = font:getHeight()
  local textH = (#wrapTitle + #wrapDesc) * lineH + 10
  local mh = pad + textH + pad + btnH + pad
  local my = (hh - mh) / 2
  local yBtn = my + mh - pad - btnH
  local bx1  = mx + mw/2 - gap/2 - btnW
  local bx2  = mx + mw/2 + gap/2
  local yes = { x = bx1, y = yBtn, w = btnW, h = btnH }
  local no  = { x = bx2, y = yBtn, w = btnW, h = btnH }
  return {mx=mx,my=my,mw=mw,mh=mh,pad=pad,title=title,desc=desc,yes=yes,no=no}
end

-- === Online sync helpers (global) ===
function serializeBoard()
  local t = {}
  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local p = boardState[r][c]
      t[#t+1] = p and p.id or "00"
    end
  end
  return table.concat(t)
end

function serializeState()
  -- 送信フォーマット: "<turnCount> <turnSide> <boardStr>"
  return string.format(
    "%d %s %s",
    tonumber(turnCount) or 1,
    tostring(turnSide or "W"),
    serializeBoard()                 -- ← 正規座標での文字列
  )
end

function applySerializedState(tc, ts, bs)
  tc = tonumber(tc) or 1
  ts = (ts == "B") and "B" or "W"
  if not bs or #bs ~= GRID_COLS*GRID_ROWS*2 then return false end

  for r=1,GRID_ROWS do boardState[r] = {} end
  restrictions = {}; effects = {}; history = {}; nextUID = 1

  local i = 1
  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local id = bs:sub(i, i+1); i = i + 2
      if id ~= "00" then
        boardState[r][c] = { id=id, uid=nextUID }; nextUID = nextUID + 1
      else
        boardState[r][c] = nil
      end
    end
  end

  turnCount = tc
  turnSide  = ts
  gameOver  = false
  winner    = nil
  selected  = nil
  return true
end

function stateDigest()
  -- 正規座標の盤面でハッシュを計算（相手と常に一致）
  local payload = string.format(
    "%d|%s|%s",
    tonumber(turnCount) or 1,
    tostring(turnSide or "W"),
    serializeBoard()  -- ← 正規座標
  )
  if love.data and love.data.hash then
    local raw = love.data.hash("sha1", payload)
    return love.data.encode("string", "hex", raw) -- 16進文字列
  else
    local sum = 0; for i=1,#payload do sum = (sum + payload:byte(i)) % 0xFFFFFFFF end
    return string.format("%08x", sum)
  end
end

NET_DESYNC = false   -- デシンク検知フラグ（描画で使うならすでにある想定）

-- === モーダルのクリック処理 ===
handleResetModalClick = function(mx, my, b)
  if not showResetConfirm or b ~= 1 then return false end
  local M = layoutResetModal()
  if pointInRect(mx,my, M.yes.x,M.yes.y,M.yes.w,M.yes.h) then
    resetGame()
    showResetConfirm = false
    if gameConfig.mode=="online" and net and net.connected then
      net.sendLine("R\n")
      net.sendLine("C " .. stateDigest() .. "\n")
    end
    return true
  elseif pointInRect(mx,my, M.no.x,M.no.y,M.no.w,M.no.h) then
    showResetConfirm = false
    return true
  else
    -- モーダル表示中は盤への入力をブロック
    return true
  end
end

handleTitleModalClick = function(mx, my, b)
  if not showTitleConfirm or b ~= 1 then return false end
  local M = layoutGoTitleModal()
  if pointInRect(mx,my, M.yes.x,M.yes.y,M.yes.w,M.yes.h) then
    if gameConfig.mode=="online" and net then net.close() end
    showTitleConfirm = false
    switchScene("menu")
    return true
  elseif pointInRect(mx,my, M.no.x,M.no.y,M.no.w,M.no.h) then
    showTitleConfirm = false
    return true
  else
    return true
  end
end

local function game_update(dt)
  if #effects > 0 then
    local i = 1
    while i <= #effects do
      local e = effects[i]
      e.t = e.t + dt
      if e.phase == "glow" then
        if e.t >= EFFECT_GLOW then e.phase = "fade"; e.t = 0 end
      elseif e.phase == "fade" then
        if e.t >= EFFECT_FADE then table.remove(effects, i); goto continue end
      end
      i = i + 1
      ::continue::
    end
  end
end

local function drawPiece(img, c, r)
  local x,y,sw,sh = toScreen(c,r)
  local target = math.min(sw,sh) * PIECE_SCALE
  local sx,sy = target/img:getWidth(), target/img:getHeight()
  -- ★ 盤の向きに応じて一律回転
  love.graphics.draw(
    img, x, y, PIECE_ROTATION, sx, sy,
    img:getWidth()/2+PIECE_OX, img:getHeight()/2+PIECE_OY
  )
end

local function game_draw()
  local winW, winH = love.graphics.getDimensions()
  love.graphics.setColor(1,1,1,1); love.graphics.rectangle("fill", 0, 0, winW, winH)

  local tx, ty, tw = PAD, PAD, TEXT_W
  local ycur = ty

  if logo then
    local lw, lh = logo:getWidth(), logo:getHeight()
    local s = math.min( tw/lw, (winH*0.14)/lh )
    love.graphics.setColor(0,0,0,1); love.graphics.draw(logo, tx, ycur, 0, s, s)
    ycur = ycur + lh*s + 10
  end

  love.graphics.setColor(0,0,0,1)
  local turnTxt = (turnSide=="B") and "Black" or "White"
  love.graphics.print(("Turn: %s"):format(turnTxt), tx, ycur); ycur = ycur + 20
  love.graphics.print(("Moves: %d"):format(turnCount), tx, ycur); ycur = ycur + 20

  local cb,_ = sidePieceStats("B")
  local cw,_ = sidePieceStats("W")
  love.graphics.print(("Black: %d"):format(cb), tx, ycur); ycur = ycur + 20
  love.graphics.print(("White: %d"):format(cw), tx, ycur); ycur = ycur + 20

  local textTop = ycur
  local textBottom = undoBtn.y - 10
  local textH = math.max(0, textBottom - textTop)
  local sx, sy, sw, sh = math.floor(tx), math.floor(textTop), math.floor(tw), math.floor(textH)
  love.graphics.setScissor(sx, sy, sw, sh)
  love.graphics.setColor(0.1,0.1,0.1,1)
  love.graphics.setScissor()

  -- Undo：オンラインでは描かない（将来完全削除するならこのままでもOK）
  if gameConfig.mode ~= "online" then
    drawButton(undoBtn, "Undo", fonts.ui)
  end

  -- Reset：オフラインは常時、オンラインは勝敗後のみ有効
  if gameConfig.mode ~= "online" or gameOver then
    drawButton(resetBtn, "Reset", fonts.ui)
  else
    -- 無効表示にしたい場合は薄く覆う等（クリックは上のハンドラで既に無効）
    drawButton(resetBtn, "Reset", fonts.ui)
    love.graphics.setColor(1,1,1,0.55)
    love.graphics.rectangle("fill", resetBtn.x, resetBtn.y, resetBtn.w, resetBtn.h, 10,10)
    love.graphics.setColor(1,1,1,1)
  end

   -- Title：常時
  drawButton(goTitleBtn, "Title", fonts.ui)

  local cx = drawX + boardW * scale / 2
  local cy = drawY + boardH * scale / 2
  love.graphics.push()
  love.graphics.translate(cx, cy)
  love.graphics.rotate(BOARD_ROTATION)
  love.graphics.translate(-cx, -cy)

  love.graphics.setColor(1,1,1,1)
  love.graphics.draw(board, drawX, drawY, 0, scale, scale)

  if selected then
    local cand = { {0,-1}, {0,1}, {-1,0}, {1,0} }
    for _,d in ipairs(cand) do
      local tc, tr = selected.c + d[1], selected.r + d[2]
      if canMove(selected, tc, tr) then
        local x,y,sw2,sh2 = toScreen(tc,tr)
        love.graphics.setColor(0,1,0,0.22); love.graphics.circle("fill", x, y, math.min(sw2,sh2)*0.46)
        love.graphics.setColor(0,0.5,0,0.9); love.graphics.circle("line", x, y, math.min(sw2,sh2)*0.46)
      end
    end
    local x0,y0,sw0,sh0 = toScreen(selected.c,selected.r)
    love.graphics.setColor(1,0.9,0,0.25); love.graphics.circle("fill", x0, y0, math.min(sw0,sh0)*0.45)
  end
  love.graphics.setColor(1,1,1,1)

  for r=1,GRID_ROWS do
    for c=1,GRID_COLS do
      local p = boardState[r][c]
      if p then drawPiece(pieceImg[p.id], c, r) end
    end
  end

  if #effects > 0 then
    for _,e in ipairs(effects) do
      local x,y,sw,sh = toScreen(e.c, e.r)
      local target = math.min(sw,sh) * PIECE_SCALE
      local img = pieceImg[e.id]
      local sx2,sy2 = target/img:getWidth(), target/img:getHeight()
      local rot = PIECE_ROTATION

      if e.phase == "glow" then
        love.graphics.setBlendMode("add")
        love.graphics.setColor(1,1,0.6, 0.8)
        love.graphics.circle("fill", x, y, math.min(sw,sh)*0.48)
        love.graphics.setColor(1,1,1, 0.9)
        love.graphics.draw(img, x, y, rot, sx2, sy2,
                          img:getWidth()/2+PIECE_OX, img:getHeight()/2+PIECE_OY)
        love.graphics.setBlendMode("alpha")
      else
        local t = math.max(0, math.min(1, e.t / EFFECT_FADE))
        local a = 1 - t
        love.graphics.setColor(1,1,1, a)
        love.graphics.draw(img, x, y, rot, sx2, sy2,
                          img:getWidth()/2+PIECE_OX, img:getHeight()/2+PIECE_OY)
        love.graphics.setBlendMode("add")
        love.graphics.setColor(1,1,0.6, 0.25*a)
        love.graphics.circle("line", x, y, math.min(sw,sh)*0.48)
        love.graphics.setBlendMode("alpha")
        love.graphics.setColor(1,1,1,1)
      end
    end
  end

  love.graphics.pop()

  if gameOver then
    local msg = (winner=="W") and "White wins" or "Black wins"
    love.graphics.setColor(0,0,0,1)
    local yWin = math.min(textTop + WIN_MSG_OFFSET, textBottom - 18)
    love.graphics.print(msg, tx, yWin)
  end

  if showResetConfirm then
    love.graphics.setColor(0,0,0,0.5)
    love.graphics.rectangle("fill", 0,0, winW,winH)
    local M = layoutResetModal()
    love.graphics.setColor(1,1,1,1)
    love.graphics.rectangle("fill", M.mx,M.my, M.mw,M.mh, 12,12)
    love.graphics.setColor(0,0,0,1)
    love.graphics.rectangle("line", M.mx,M.my, M.mw,M.mh, 12,12)
    love.graphics.setFont(fonts.ui)
    local xText = M.mx + M.pad
    local yText = M.my + M.pad
    love.graphics.printf(M.title, xText, yText, M.mw - M.pad*2, "left")
    yText = yText + fonts.ui:getHeight() + 10
    love.graphics.printf(M.desc,  xText, yText, M.mw - M.pad*2, "left")
    drawButton(M.yes, "Yes", fonts.ui)
    drawButton(M.no,  "No",  fonts.ui)
  end

  if showTitleConfirm then
    love.graphics.setColor(0,0,0,0.5)
    love.graphics.rectangle("fill", 0,0, winW,winH)
    local M = layoutGoTitleModal()
    love.graphics.setColor(1,1,1,1)
    love.graphics.rectangle("fill", M.mx,M.my, M.mw,M.mh, 12,12)
    love.graphics.setColor(0,0,0,1)
    love.graphics.rectangle("line", M.mx,M.my, M.mw,M.mh, 12,12)
    love.graphics.setFont(fonts.ui)
    local xText = M.mx + M.pad
    local yText = M.my + M.pad
    love.graphics.printf(M.title, xText, yText, M.mw - M.pad*2, "left")
    yText = yText + fonts.ui:getHeight() + 10
    love.graphics.printf(M.desc,  xText, yText, M.mw - M.pad*2, "left")
    drawButton(M.yes, "Yes", fonts.ui)
    drawButton(M.no,  "No",  fonts.ui)
  end
end

-- 盤の中央に半透明の白いバナーを描く（テキストは黒でセンタリング）
local function drawBoardCenterBanner(text)
  if not text or text == "" then return end
  local bw, bh = boardW * scale, boardH * scale
  local bx, by = drawX, drawY
  local cx, cy = bx + bw/2, by + bh/2

  local font = fonts.ui or love.graphics.getFont()
  love.graphics.setFont(font)

  -- バナー最大幅は盤の 70%
  local maxW = math.floor(bw * 0.7)
  local padX, padY = 16, 12
  local _, lines = font:getWrap(text, maxW - padX*2)
  local lineH = font:getHeight()
  local textH = #lines * lineH

  -- 実際の幅（改行後の最長行幅に合わせる）
  local w = 0
  for _,ln in ipairs(lines) do
    w = math.max(w, font:getWidth(ln))
  end
  w = math.min(maxW - padX*2, w)
  local boxW = w + padX*2
  local boxH = textH + padY*2

  local rx = math.floor(cx - boxW/2)
  local ry = math.floor(cy - boxH/2)

  -- 影
  love.graphics.setColor(0,0,0,0.22)
  love.graphics.rectangle("fill", rx+2, ry+3, boxW, boxH, 12,12)

  -- 半透明の白い面
  love.graphics.setColor(1,1,1,0.78)
  love.graphics.rectangle("fill", rx, ry, boxW, boxH, 12,12)

  -- 枠線（薄め）
  love.graphics.setColor(0,0,0,0.35)
  love.graphics.rectangle("line", rx, ry, boxW, boxH, 12,12)

  -- テキスト
  love.graphics.setColor(0,0,0,1)
  love.graphics.printf(text, rx + padX, ry + padY, boxW - padX*2, "center")
  love.graphics.setColor(1,1,1,1)
end

-- === 共通UIヘルパ ===
local function handleTopButtons(mx, my, b)
  if b ~= 1 then return false end

  -- Undo：オンラインでは廃止（クリックも無効化）
  if pointInRect(mx,my, undoBtn.x,undoBtn.y,undoBtn.w,undoBtn.h) then
    if gameConfig.mode=="online" then
      return true -- 何もしない（押下は飲む）
    end
    local s = table.remove(history); if s then restore(s) end
    return true
  end

  -- Reset：オフラインは常時OK、オンラインは勝敗後のみ
  if pointInRect(mx,my, resetBtn.x,resetBtn.y,resetBtn.w,resetBtn.h) then
    if gameConfig.mode=="online" and not gameOver then
      return true -- 勝敗が付くまでは無効
    end
    showResetConfirm = true
    return true
  end

  -- Title：常時OK（オンライン時はnet.close()はモーダル側ですでに実施済み）
  if pointInRect(mx,my, goTitleBtn.x,goTitleBtn.y,goTitleBtn.w,goTitleBtn.h) then
    showTitleConfirm = true
    return true
  end

  return false
end

local function game_mousepressed(mx,my,b)
  -- 先にUI処理（常時有効）
  if handleTitleModalClick(mx,my,b) then return end
  if handleResetModalClick(mx,my,b) then return end
  if handleTopButtons(mx,my,b) then return end

  if b~=1 or gameOver then return end

  if showResetConfirm and b==1 then
    local M = layoutResetModal()
    if pointInRect(mx,my, M.yes.x,M.yes.y,M.yes.w,M.yes.h) then resetGame(); showResetConfirm=false; return
    elseif pointInRect(mx,my, M.no.x,M.no.y,M.no.w,M.no.h) then showResetConfirm=false; return
    else return end
  end

  if showTitleConfirm and b==1 then
    local M = layoutGoTitleModal()
    if pointInRect(mx,my, M.yes.x,M.yes.y,M.yes.w,M.yes.h) then
      if gameConfig.mode=="online" and net then net.close() end
      switchScene("menu"); showTitleConfirm=false; return
    elseif pointInRect(mx,my, M.no.x,M.no.y,M.no.w,M.no.h) then
      showTitleConfirm=false; return
    else return end
  end

  if b~=1 or gameOver then return end

  local c,r = toGrid(mx,my); if not c then selected=nil; return end
  if selected then
    if selected.c == c and selected.r == r then selected = nil; return end
    if not tryMove(selected, c, r) then
      local p = boardState[r][c]
      if p and idToSide(p.id)==turnSide then selected={c=c,r=r} else selected=nil end
    end
  else
    local p = boardState[r][c]
    if p and idToSide(p.id)==turnSide then selected={c=c,r=r} else selected=nil end
  end
end

local function game_keypressed(k)
  if k=="escape" then love.event.quit() return end
  if k=="z" or k=="u" then local s=table.remove(history); if s then restore(s) end; return end
  if k=="r" then showResetConfirm=true; return end
  if showResetConfirm then
    if k=="y" then resetGame(); showResetConfirm=false end
    if k=="n" or k=="escape" then showResetConfirm=false end
    return
  end

  if gameOver or not selected then return end
  local c,r = selected.c, selected.r
  if k=="up"    and canMove(selected, c,   r-1) then tryMove(selected,c,  r-1) end
  if k=="down"  and canMove(selected, c,   r+1) then tryMove(selected,c,  r+1) end
  if k=="left"  and canMove(selected, c-1, r  ) then tryMove(selected,c-1,r  ) end
  if k=="right" and canMove(selected, c+1, r  ) then tryMove(selected,c+1,r  ) end
end

-- ====== MENU scene ======
local menu = { buttons = {}, sub = nil }
function menu.enter()
  local ww, hh = love.graphics.getDimensions()
  local bw, bh, gap = 240, 48, 16
  local cx = ww * 0.5
  local baseY = hh * 0.48

  -- 小さな Training トグルの矩形を用意（関数ではなく、矩形そのものを保持）
  menu.trainBtn = { x = 12, y = hh - 26, w = 140, h = 18 }

  menu.buttons = {
    {label="ルール",         x=cx - bw/2, y=baseY + (bh+gap)*0, w=bw, h=bh, action=function() switchScene("rules") end},
    {label="ローカル対戦",   x=cx - bw/2, y=baseY + (bh+gap)*1, w=bw, h=bh, action=function() switchScene("opt_local")   end},
    {label="vs COM",         x=cx - bw/2, y=baseY + (bh+gap)*2, w=bw, h=bh, action=function() switchScene("opt_com")     end},
    {label="オンライン対戦", x=cx - bw/2, y=baseY + (bh+gap)*3, w=bw, h=bh, action=function() switchScene("opt_online") end},
  }
end

function menu.update(dt) end

local function drawSimpleModal(text)
  local ww, hh = love.graphics.getDimensions()
  local mw, mh = 560, 200
  local mx, my = (ww-mw)/2, (hh-mh)/2
  love.graphics.setColor(0,0,0,0.5); love.graphics.rectangle("fill", 0,0, ww,hh)
  love.graphics.setColor(1,1,1,1);   love.graphics.rectangle("fill", mx,my, mw,mh, 12,12)
  love.graphics.setColor(0,0,0,1);   love.graphics.rectangle("line", mx,my, mw,mh, 12,12)
  love.graphics.printf(text, mx+16, my+24, mw-32, "left")
end

function menu.draw()
  local ww, hh = love.graphics.getDimensions()
  love.graphics.clear(1,1,1,1)
  if logo then
    local lw, lh = logo:getWidth(), logo:getHeight()
    local s = math.min((ww*0.5)/lw, (hh*0.14)/lh)
    local x = (ww - lw*s)/2
    local y = hh*0.24 - (lh*s)/2
    love.graphics.setColor(0,0,0,1)
    love.graphics.draw(logo, x, y, 0, s, s)
  else
    love.graphics.setColor(0,0,0,1)
    love.graphics.setFont(fonts.title); love.graphics.printf("三ツ巴", 0, hh*0.24-18, ww, "center")
    love.graphics.setFont(fonts.small); love.graphics.setColor(0,0,0,0.7); love.graphics.printf("Mitsudomoe", 0, hh*0.24+24, ww, "center")
    love.graphics.setFont(fonts.ui)
  end
  for _,btn in ipairs(menu.buttons) do drawButton(btn, btn.label, fonts.ui) end

  -- コピーライト（画面下部中央・薄め）
  local ww,hh = love.graphics.getDimensions()
  love.graphics.setColor(0,0,0,0.55)
  love.graphics.setFont(fonts.small)
  love.graphics.printf("© 2025 M.A.K / MITUDOMOE. All Rights Reserved.", 0, hh-22, ww, "center")
  love.graphics.setColor(1,1,1,1)

  do
    local b = menu.trainBtn
    local t = TRAIN.enabled and "ON" or "OFF"
    love.graphics.setColor(0,0,0,0.18)
    love.graphics.rectangle("fill", b.x,b.y,b.w,b.h, 8,8)
    love.graphics.setColor(0,0,0,0.55)
    love.graphics.rectangle("line", b.x,b.y,b.w,b.h, 8,8)
    love.graphics.setFont(fonts.small)
    love.graphics.printf("Training : "..t, b.x, b.y+2, b.w, "center")
    love.graphics.setColor(1,1,1,1)
  end
end

function menu.mousepressed(x,y,b)
  if b ~= 1 then return end

  -- 小トグル
  if menu.trainBtn and pointInRect(x,y, menu.trainBtn.x, menu.trainBtn.y, menu.trainBtn.w, menu.trainBtn.h) then
    TRAIN.enabled = not TRAIN.enabled
    return
  end

  -- メニューの各ボタン
  for _,btn in ipairs(menu.buttons) do
    if pointInRect(x,y, btn.x, btn.y, btn.w, btn.h) then
      btn.action(); return
    end
  end
end

function menu.keypressed(k) if k=="escape" then love.event.quit() end end
scenes.menu = menu

-- 共通：中央パネル
local function drawOptionPanel(title, contentFn)
  local ww, hh = love.graphics.getDimensions()
  love.graphics.clear(1,1,1,1)

  if logo then
    local lw, lh = logo:getWidth(), logo:getHeight()
    local s = math.min((ww*0.35)/lw, (hh*0.10)/lh)
    local x = (ww - lw*s)/2
    local y = hh*0.10 - (lh*s)/2
    love.graphics.setColor(0,0,0,1); love.graphics.draw(logo, x, y, 0, s, s)
  end

  local pw = math.min(UI.panelW, ww*0.86)
  local ph = math.min(UI.panelH, hh*0.74)
  local px = (ww - pw)/2
  local py = hh*UI.panelTopRatio

  love.graphics.setColor(0.98,0.98,0.98,1); love.graphics.rectangle("fill", px,py, pw,ph, 12,12)
  love.graphics.setColor(0,0,0,1); love.graphics.rectangle("line", px,py, pw,ph, 12,12)

  love.graphics.setFont(fonts.title)
  love.graphics.printf(title, px, py+10, pw, "center")
  love.graphics.setFont(fonts.ui)

  contentFn(px,py,pw,ph)
end

--↓後で消す
-- ===== Training scene =====
local train = { startBtn=nil, stopBtn=nil, backBtn=nil }

function train.enter()
  local ww, hh = love.graphics.getDimensions()
  local bw, bh, gap = 120, 40, 14
  local cx = ww/2
  local baseY = hh*0.68
  train.startBtn = { x=cx - bw - gap/2, y=baseY, w=bw, h=bh }
  train.stopBtn  = { x=cx + gap/2,      y=baseY, w=bw, h=bh }
  train.backBtn  = { x=cx - bw/2,       y=baseY + bh + gap, w=bw, h=bh }
  train.saveBtn = { x=cx - 260, y=baseY - (bh + gap), w=120, h=bh }
  train.loadBtn = { x=cx + 140, y=baseY - (bh + gap), w=120, h=bh }
end

function train.update(dt) end

local function _kv(x,y,key,fmt,inc)
  -- 小さな +/- で数値をいじるヘルパ
  local w,h = 180, 32
  love.graphics.setColor(0,0,0,1)
  love.graphics.print(key, x, y)
  local bx = x + 160
  love.graphics.setColor(0.95,0.95,0.95,1)
  love.graphics.rectangle("fill", bx, y-4, w, h, 8,8)
  love.graphics.setColor(0,0,0,1)
  love.graphics.rectangle("line", bx, y-4, w, h, 8,8)
  love.graphics.printf(string.format(fmt, inc()), bx, y-2, w, "center")
  return {x=bx, y=y-4, w=w, h=h}
end

function train.draw()
  drawOptionPanel("Training", function(px,py,pw,ph)
    local x = px + 40
    local y = py + 88
    love.graphics.setColor(0,0,0,1)
    love.graphics.setFont(fonts.ui)

    -- パラメータ表示
    local fields = {}

    fields.total = _kv(x,y, "Games", "%d", function() return training.total end);        y=y+40
    fields.eps   = _kv(x,y, "Epsilon", "%.3f", function() return training.eps end);      y=y+40
    fields.lr    = _kv(x,y, "LR", "%.3f", function() return training.lr end);            y=y+40
    fields.gamma = _kv(x,y, "Gamma", "%.2f", function() return training.gamma end);      y=y+40
    fields.maxp  = _kv(x,y, "Max plies", "%d", function() return training.maxPlies end); y=y+40

    -- 進捗
    y = y + 10
    local done, total = training.done, training.total
    local ratio = (total>0) and (done/total) or 0
    local barW, barH = pw-80, 18
    love.graphics.setColor(0,0,0,0.25)
    love.graphics.rectangle("fill", px+40, y, barW, barH, 8,8)
    love.graphics.setColor(0.2,0.6,0.2, 0.9)
    love.graphics.rectangle("fill", px+40, y, barW*ratio, barH, 8,8)
    love.graphics.setColor(0,0,0,0.8)
    love.graphics.printf(("%d / %d"):format(done,total), px+40, y-2, barW, "center")

    -- 状態
    y = y + 34
    local msg = training.active and "Training... (coroutine)" or "Idle"
    love.graphics.setColor(0,0,0,0.75)
    love.graphics.printf(msg, px+40, y, pw-80, "left")
  end)

  drawButton(train.startBtn, training.active and "Running..." or "Start", fonts.ui)
  drawButton(train.stopBtn,  "Stop", fonts.ui)
  drawButton(train.backBtn,  "Back", fonts.ui)
  drawButton(train.saveBtn, "Save", fonts.ui)
  drawButton(train.loadBtn, "Load", fonts.ui)

  -- 薄い注意書き（右下）
  local ww,hh = love.graphics.getDimensions()
  love.graphics.setFont(fonts.small)
  love.graphics.setColor(0,0,0,0.55)
  love.graphics.printf("Learning updates weights used by Hard.", 0, hh-24, ww, "right")
  love.graphics.setColor(1,1,1,1)
end

function train.mousepressed(x,y,b)
  if b~=1 then return end
  if pointInRect(x,y, train.startBtn.x,train.startBtn.y,train.startBtn.w,train.startBtn.h) then
    if not training.active then startTraining() end
    return
  end
  if pointInRect(x,y, train.stopBtn.x,train.stopBtn.y,train.stopBtn.w,train.stopBtn.h) then
    stopTraining(); return
  end
  if pointInRect(x,y, train.backBtn.x,train.backBtn.y,train.backBtn.w,train.backBtn.h) then
    switchScene("menu"); return
  end
  if b==1 and pointInRect(x,y, train.saveBtn.x,train.saveBtn.y,train.saveBtn.w,train.saveBtn.h) then
    pcall(function() Eval.save() end); return
  end
  if b==1 and pointInRect(x,y, train.loadBtn.x,train.loadBtn.y,train.loadBtn.w,train.loadBtn.h) then
    pcall(function() Eval.load() end); return
  end
end

function train.keypressed(k)
  if k=="escape" then switchScene("menu") end
end

scenes.train = train
-- ===== /Training scene =====

-- ===== Rules scene =====
local rules = { page=1, pages={} , closeBtn=nil, prevBtn=nil, nextBtn=nil }

-- ここでページ定義（必要に応じて増やせます）
local function _makeRulesPages()
  local p = {}
  -- 盤画像＋概要
  table.insert(p, {
    draw=function(px,py,pw,ph)
      local title = "闘いの舞台"
      love.graphics.setFont(fonts.title); love.graphics.setColor(0,0,0,1)
      love.graphics.printf(title, px, py+10, pw, "center")
      love.graphics.setFont(fonts.ui)
      local tx = px+20; local ty = py+100; local tw = pw-48
      local text =
        "闘いの舞台となるのはこの縦横\n" ..
        "8本の罫線が引かれた盤の上。\n" ..
        "白と黒の駒が世界の存亡を賭けて\n" ..
        "ぶつかり合います。\n" ..
        "手前側があなたの駒。\n" ..
        "プレイヤーは交互に自分の駒を1つ、上下左右のいずれかに\n" ..
        "1歩ずつ進めていきます。"
      love.graphics.printf(text, tx, ty, tw*0.45, "left")

      -- 右側に盤イメージ
      if board then
        local bw, bh = boarda:getWidth(), boarda:getHeight()
        local s = math.min( (pw*0.75)/bw, (ph*0.75)/bh )
        local bx = px + pw - bw*s - 24
        local by = py + 90
        love.graphics.setColor(1,1,1,1)
        love.graphics.draw(boarda, bx, by, 0, s, s)
      end
    end
  })

  -- 駒の相性
  table.insert(p, {
    draw=function(px,py,pw,ph)
      -- タイトル
      love.graphics.setFont(fonts.title)
      love.graphics.setColor(0,0,0,1)
      love.graphics.printf("三つの駒", px, py+10, pw, "center")
      local titleBottom = py + 10 + fonts.title:getHeight() + 12  -- タイトルの直下Y

      -- 説明文（先に高さだけ計算しておく）
      local text = 
        "陽(赤)、地(緑)、海(青)の3つの駒があなたの世界を形作っています。\n" ..
        "陽、地、海各4個、計12個があなたの駒です。\n" ..
        "陽は地に強く、地は海に強く、海は陽に強い。\n" ..
        "相手の駒と隣り合った時、違う色ならば不利な駒が、同じ色なら両方が消滅します。"
      love.graphics.setFont(fonts.ui)
      local tw = pw - 48
      local _, lines = fonts.ui:getWrap(text, tw)
      local descH = #lines * fonts.ui:getHeight()
      local bottomPad   = 24         -- パネル下の余白
      local gapTitleImg = 12         -- タイトルと画像の間
      local gapImgText  = 16         -- 画像と説明の間

      -- 画像の描画領域（タイトル下〜説明文上）の矩形を決める
      local imgTop    = titleBottom + gapTitleImg
      local imgBottom = py + ph - bottomPad - descH - gapImgText
      local maxW      = pw - 80
      local maxH      = math.max(40, imgBottom - imgTop)

      -- 画像（パネル中央に収まる倍率で）
      if compati and maxH > 0 then
        local iw, ih = compati:getWidth(), compati:getHeight()
        local s  = math.min(maxW/iw, maxH/ih, 1.0)  -- パネルからはみ出さない最大倍率
        local cx = px + pw/2
        local cy = imgTop + maxH/2
        love.graphics.setColor(1,1,1,1)
        love.graphics.draw(compati, cx, cy, 0, s, s, iw/2, ih/2)  -- 中央基準で描く
      end

      -- 説明文（画像の下端にぴったり続けて描く）
      local descTop = imgBottom + gapImgText
      love.graphics.setColor(0,0,0,1)
      love.graphics.printf(text, px+24, descTop, tw, "left")

      -- テキストの折り返し高から画像領域を計算
      local _, lines = fonts.ui:getWrap(text, tw)
      local textH = #lines * fonts.ui:getHeight()
    end
  })
  
  -- 勝敗
  table.insert(p, {
    draw=function(px,py,pw,ph)
      love.graphics.setFont(fonts.title); love.graphics.setColor(0,0,0,1)
      love.graphics.printf("三つの敗北条件", px, py+20, pw, "center")
      love.graphics.setFont(fonts.ui)
      local tx = px+45; local ty = py+90; local tw = pw-48
      love.graphics.printf(
        "以下の状態になると世界の均衡が崩壊し、敗北します。\n" ..
        "・残り駒数が3つ以下になる\n" ..
        "・駒が2色以下になる\n" ..
        "・引き分けになる一手を差す",
        tx, ty, tw, "left"
      )
      love.graphics.setFont(fonts.title); love.graphics.setColor(0,0,0,1)
      love.graphics.printf("禁じ手", px, py+240, pw, "center")
      love.graphics.setFont(fonts.ui)
      local tx = px+45; local ty = py+310; local tw = pw-48
      love.graphics.printf(
        "動かした駒を次の自分の手番で元の位置に戻すことはできません。",
        tx, ty, tw, "left"
      )
    end
  })
  return p
end

function rules.enter()
  rules.pages = _makeRulesPages()
  rules.page = 1
end

local function _rulesLayoutButtons()
  local ww, hh = love.graphics.getDimensions()
  local mw, mh = math.min(820, ww*0.86), math.min(560, hh*0.82)
  local mx, my = (ww-mw)/2, (hh-mh)/2
  local btnW, btnH = 110, 40
  rules.prevBtn = { x = mx + 20,        y = my + mh - btnH - 16, w=btnW, h=btnH }
  rules.nextBtn = { x = mx + mw - btnW - 20, y = my + mh - btnH - 16, w=btnW, h=btnH }
  rules.closeBtn= { x = mx + mw/2 - btnW/2,  y = my + mh - btnH - 16, w=btnW, h=btnH }
  return mx,my,mw,mh
end

function rules.draw()
  local ww,hh = love.graphics.getDimensions()
  love.graphics.clear(1,1,1,1)

  -- 半透明背景
  love.graphics.setColor(0,0,0,0.5); love.graphics.rectangle("fill", 0,0, ww,hh)

  local mx,my,mw,mh = _rulesLayoutButtons()
  -- 本体
  love.graphics.setColor(1,1,1,1); love.graphics.rectangle("fill", mx,my, mw,mh, 12,12)
  love.graphics.setColor(0,0,0,1); love.graphics.rectangle("line", mx,my, mw,mh, 12,12)

  -- ページ内容
  local page = rules.pages[rules.page]
  if page and page.draw then page.draw(mx+20, my+16, mw-40, mh-90) end

  -- ページインジケータ
  love.graphics.setColor(0,0,0,0.7)
  love.graphics.printf(("<%d/%d>"):format(rules.page, #rules.pages), mx, my+mh-62, mw, "center")

  -- ボタン
  local function _btn(b, label, disabled)
    local a = disabled and 0.45 or 1
    love.graphics.setColor(0.92,0.92,0.92,a)
    love.graphics.rectangle("fill", b.x,b.y,b.w,b.h, 10,10)
    love.graphics.setColor(0,0,0,a)
    love.graphics.rectangle("line", b.x,b.y,b.w,b.h, 10,10)
    love.graphics.printf(label, b.x, b.y + (b.h - (fonts.ui:getHeight()))/2 - 2, b.w, "center")
    love.graphics.setColor(1,1,1,1)
  end
  _btn(rules.prevBtn, "＜", rules.page<=1)
  _btn(rules.closeBtn,"Close", false)
  _btn(rules.nextBtn, "＞", rules.page>=#rules.pages)
end

function rules.mousepressed(x,y,b)
  if b ~= 1 then return end
  local function _hit(btn) return pointInRect(x,y,btn.x,btn.y,btn.w,btn.h) end
  if _hit(rules.prevBtn) and rules.page>1 then rules.page = rules.page - 1; return end
  if _hit(rules.nextBtn) and rules.page<#rules.pages then rules.page = rules.page + 1; return end
  if _hit(rules.closeBtn) then switchScene("menu"); return end
end

function rules.keypressed(k)
  if k=="escape" then switchScene("menu"); return end
  if (k=="left" or k=="h") and rules.page>1 then rules.page=rules.page-1; return end
  if (k=="right" or k=="l") and rules.page<#rules.pages then rules.page=rules.page+1; return end
  if k=="return" or k=="space" then switchScene("menu"); return end
end

scenes.rules = rules
-- ===== /Rules scene =====

-- Local 対戦
local opt_local = { startBtn=nil, backBtn=nil }
function opt_local.enter()
  local ww, hh = love.graphics.getDimensions()
  local bw, bh = 140, 44
  local y = hh*0.72
  opt_local.startBtn = { x=ww*0.5 - bw - 10, y=y, w=bw, h=bh }
  opt_local.backBtn  = { x=ww*0.5 + 10,      y=y, w=bw, h=bh }
end
function opt_local.draw()
  drawOptionPanel("ローカル対戦の設定", function(px,py,pw,ph)
    love.graphics.setColor(0,0,0,1)
    love.graphics.printf("オプションはありません。そのまま開始できます。", px+20, py+80, pw-40, "left")
  end)
  drawButton(opt_local.startBtn, "Start", fonts.ui)
  drawButton(opt_local.backBtn,  "Back",  fonts.ui)
end

function opt_local.mousepressed(x,y,b)
  CURRENT_LAYOUT = LAYOUT
  if b~=1 then return end
  if pointInRect(x,y,opt_local.startBtn.x,opt_local.startBtn.y,opt_local.startBtn.w,opt_local.startBtn.h) then
    gameConfig.mode="local"; switchScene("game_local"); return
  end
  if pointInRect(x,y,opt_local.backBtn.x,opt_local.backBtn.y,opt_local.backBtn.w,opt_local.backBtn.h) then
    switchScene("menu"); return
  end
end
function opt_local.keypressed(k) if k=="escape" then switchScene("menu") end end
scenes.opt_local = opt_local

-- vs COM：先手/後手＋難易度
local opt_com = { startBtn=nil, backBtn=nil, side="W", diffIdx=2, diffs={"Easy","Normal","Hard"} }
function opt_com.enter()
  local ww, hh = love.graphics.getDimensions()
  local bw, bh = 140, 44
  local y = hh*0.75
  opt_com.startBtn = { x=ww*0.5 - bw - 10, y=y, w=bw, h=bh }
  opt_com.backBtn  = { x=ww*0.5 + 10,      y=y, w=bw, h=bh }
end

function opt_com.draw()
  drawOptionPanel("vs COM の設定", function(px,py,pw,ph)
    local x = px + 36
    local y = py + 80
    love.graphics.setFont(fonts.ui)
    love.graphics.setColor(0,0,0,1)

    -- 先手/後手
    love.graphics.printf("先手/後手", x, y, pw - 72, "left")
    y = y + UI.controlGap
    local r1 = drawRadio(x,               y + 22, "White（先手）", opt_com.side=="W")
    local r2 = drawRadio(x + UI.radioDx,  y + 22, "Black（後手）", opt_com.side=="B")
    opt_com._r1, opt_com._r2 = r1, r2

    local lineH = math.max(24, love.graphics.getFont():getHeight() + 6)
    y = y + lineH + 24   -- ここは少し詰める

    -- 難易度（ラジオ3択・横間隔はタイト）
    love.graphics.printf("COMの強さ（表示のみ）", x, y, pw - 72, "left")
    y = y + UI.controlGap
    local baseY = y + 22
    local d1 = drawRadio(x,                           baseY, "Easy",   opt_com.diffIdx==1)
    local d2 = drawRadio(x + UI.radioDxTight,         baseY, "Normal", opt_com.diffIdx==2)
    local d3 = drawRadio(x + UI.radioDxTight * 2,     baseY, "Hard",   opt_com.diffIdx==3)
    opt_com._d1, opt_com._d2, opt_com._d3 = d1, d2, d3
  end)

  drawButton(opt_com.startBtn, "Start", fonts.ui)
  drawButton(opt_com.backBtn,  "Back",  fonts.ui)
end

function opt_com.mousepressed(x,y,b)
  if b~=1 then return end
  -- 難易度（ラジオ）
  if opt_com._d1 and pointInRect(x,y,opt_com._d1.x,opt_com._d1.y,opt_com._d1.w,opt_com._d1.h) then opt_com.diffIdx=1; return end
  if opt_com._d2 and pointInRect(x,y,opt_com._d2.x,opt_com._d2.y,opt_com._d2.w,opt_com._d2.h) then opt_com.diffIdx=2; return end
  if opt_com._d3 and pointInRect(x,y,opt_com._d3.x,opt_com._d3.y,opt_com._d3.w,opt_com._d3.h) then opt_com.diffIdx=3; return end

  -- 先手/後手（ラジオ）
  if opt_com._r1 and pointInRect(x,y,opt_com._r1.x,opt_com._r1.y,opt_com._r1.w,opt_com._r1.h) then opt_com.side="W"; return end
  if opt_com._r2 and pointInRect(x,y,opt_com._r2.x,opt_com._r2.y,opt_com._r2.w,opt_com._r2.h) then opt_com.side="B"; return end

  -- Start / Back
  if pointInRect(x,y,opt_com.startBtn.x,opt_com.startBtn.y,opt_com.startBtn.w,opt_com.startBtn.h) then
    gameConfig.mode="com"
    gameConfig.side=opt_com.side
    gameConfig.difficulty=opt_com.diffs[opt_com.diffIdx]
    switchScene("game_com"); return
  end
  if pointInRect(x,y,opt_com.backBtn.x,opt_com.backBtn.y,opt_com.backBtn.w,opt_com.backBtn.h) then
    switchScene("menu"); return
  end
end

function opt_com.keypressed(k) if k=="escape" then switchScene("menu") end end
scenes.opt_com = opt_com

-- オンライン（IP/Port入力対応）
local opt_online = {
  startBtn=nil, backBtn=nil,
  role="create", side="W",
  focus=nil,          -- "host" / "port" / nil
  host="", port=""
}

local function _acceptHostChar(ch) return ch:match("[0-9a-zA-Z%.:%-]") ~= nil end -- IPv4/IPv6/ホスト名ざっくり
local function _acceptPortChar(ch) return ch:match("%d") ~= nil end

function opt_online.enter()
  local ww, hh = love.graphics.getDimensions()
  local bw, bh = 160, 44
  local y = hh*0.78
  opt_online.startBtn = { x=ww*0.5 - bw - 10, y=y, w=bw, h=bh }
  opt_online.backBtn  = { x=ww*0.5 + 10,      y=y, w=bw, h=bh }

  -- 既存設定をUIに反映
  opt_online.role = gameConfig.online.role or "create"
  opt_online.side = gameConfig.side or "W"
  opt_online.host = tostring(gameConfig.online.host or "127.0.0.1")
  opt_online.port = tostring(gameConfig.online.port or 22122)
  opt_online.focus = nil
end

function opt_online.draw()
  drawOptionPanel("オンライン対戦の設定", function(px,py,pw,ph)
    local x = px + 36
    local y = py + 80
    love.graphics.setFont(fonts.ui)
    love.graphics.setColor(0,0,0,1)

    -- 役割
    love.graphics.printf("役割", x, y, pw - 72, "left")
    y = y + UI.controlGap
    local r1 = drawRadio(x,               y + 22, "部屋を作る（Create）", opt_online.role=="create")
    local r2 = drawRadio(x + UI.radioDx,  y + 22, "部屋に入る（Join）",    opt_online.role=="join")
    opt_online._r1, opt_online._r2 = r1, r2

    local lineH = math.max(24, love.graphics.getFont():getHeight() + 6)
    local SECTION_TIGHT = 22       -- ← ここで全体を詰める
    y = y + lineH + SECTION_TIGHT

    -- 自分の手番（Join時は無効・薄く）
    love.graphics.printf("自分の手番", x, y, pw - 72, "left")
    y = y + UI.controlGap
    local sideY = y + 22
    local r3 = drawRadio(x,               sideY, "White（先手）", opt_online.side=="W")
    local r4 = drawRadio(x + UI.radioDx,  sideY, "Black（後手）", opt_online.side=="B")
    opt_online._r3, opt_online._r4 = r3, r4

    -- 無効オーバーレイ（見た目だけ薄くする）
    if opt_online.role == "join" then
      local blockW = pw - 72
      love.graphics.setColor(1,1,1,0.6)
      love.graphics.rectangle("fill", x - 12, y - 8, blockW + 24, lineH + 26, 8, 8)
      love.graphics.setColor(0,0,0,1)
    end

    y = y + lineH + SECTION_TIGHT

    -- 接続先
    love.graphics.printf("接続先（IP/ホスト名 と ポート）", x, y, pw - 72, "left")
    y = y + fonts.ui:getHeight() + UI.controlGap
    local hostW, portW = UI.selectW, 120
    opt_online._host = drawSelect(x,                 y, hostW, UI.selectH, (opt_online.focus=="host" and "> " or "")..opt_online.host)
    opt_online._port = drawSelect(x + hostW + 12,    y, portW, UI.selectH, (opt_online.focus=="port" and "> " or "")..opt_online.port)

    y = y + UI.selectH + 8
    love.graphics.setColor(0,0,0,0.7)
    love.graphics.printf("※Join時は相手のIP/ポートに合わせてください。", x, y, pw - 72, "left")
  end)

  drawButton(opt_online.startBtn, "Start", fonts.ui)
  drawButton(opt_online.backBtn,  "Back",  fonts.ui)

  if scenes.game_online._peerLost then
    love.graphics.setColor(0,0,0,0.6)
    love.graphics.printf("Opponent disconnected", 0, 8, love.graphics.getWidth(), "center")
    love.graphics.setColor(1,1,1,1)
  end
  if NET_DESYNC then
    love.graphics.setColor(0.8,0,0,0.7)
    love.graphics.printf("State mismatch detected. Resyncing...", 0, 28, love.graphics.getWidth(), "center")
    love.graphics.setColor(1,1,1,1)
  end
end

function opt_online.mousepressed(x,y,b)
  if b~=1 then return end

  -- Role（Create/Join）
  if opt_online._r1 and pointInRect(x,y,opt_online._r1.x,opt_online._r1.y,opt_online._r1.w,opt_online._r1.h) then
    opt_online.role = "create"
    return
  end
  if opt_online._r2 and pointInRect(x,y,opt_online._r2.x,opt_online._r2.y,opt_online._r2.w,opt_online._r2.h) then
    opt_online.role = "join"
    return
  end

  -- Side（Join中は無効）
  if opt_online.role == "create" then
    if opt_online._r3 and pointInRect(x,y,opt_online._r3.x,opt_online._r3.y,opt_online._r3.w,opt_online._r3.h) then
      opt_online.side = "W"
      return
    end
    if opt_online._r4 and pointInRect(x,y,opt_online._r4.x,opt_online._r4.y,opt_online._r4.w,opt_online._r4.h) then
      opt_online.side = "B"
      return
    end
  end

  -- 入力欄
  if opt_online._host and pointInRect(x,y,opt_online._host.x,opt_online._host.y,opt_online._host.w,opt_online._host.h) then
    opt_online.focus = "host"; return
  end
  if opt_online._port and pointInRect(x,y,opt_online._port.x,opt_online._port.y,opt_online._port.w,opt_online._port.h) then
    opt_online.focus = "port"; return
  end

  -- Start / Back
  if pointInRect(x,y,opt_online.startBtn.x,opt_online.startBtn.y,opt_online.startBtn.w,opt_online.startBtn.h) then
    gameConfig.mode="online"
    gameConfig.side=opt_online.side
    gameConfig.online.role=opt_online.role
    gameConfig.online.host=opt_online.host ~= "" and opt_online.host or "127.0.0.1"
    gameConfig.online.port=tonumber(opt_online.port) or 22122
    switchScene("game_online")
    return
  end

  if pointInRect(x,y,opt_online.backBtn.x,opt_online.backBtn.y,opt_online.backBtn.w,opt_online.backBtn.h) then
    switchScene("menu")
    return
  end
end

function opt_online.keypressed(k)
  if k=="escape" then
    if opt_online.focus then opt_online.focus=nil else switchScene("menu") end
    return
  end
  if k=="backspace" and opt_online.focus then
    if opt_online.focus=="host" then opt_online.host = opt_online.host:sub(1,-2)
    elseif opt_online.focus=="port" then opt_online.port = opt_online.port:sub(1,-2) end
    return
  end
  if k=="return" or k=="kpenter" then opt_online.focus=nil; return end
end

function opt_online.textinput(t)
  if not opt_online.focus then return end
  if opt_online.focus=="host" then
    if _acceptHostChar(t) and #opt_online.host < 64 then
      opt_online.host = opt_online.host .. t
    end
  elseif opt_online.focus=="port" then
    if _acceptPortChar(t) and #opt_online.port < 5 then
      opt_online.port = opt_online.port .. t
    end
  end
end

scenes.opt_online = opt_online
-- ====== /OPTION scenes ======

-- ====== GAME vs COM scene ======
local humanSide = "W"
local aiSide    = "B"
local aiThinkTimer = 0
local AI_THINK_DELAY = 0.45

local function game_com_enter()
  humanSide = gameConfig.side or "W"
  aiSide    = (humanSide=="W") and "B" or "W"

  CURRENT_LAYOUT = LAYOUT

  setBoardOrientation(humanSide)  -- ★人間が手前なのでその側を正位置に
  resetGame()
  aiThinkTimer = 0
  if TRAIN.enabled then
    ensureLearner()
    TRAIN.learner.recorder.begin(humanSide, { lr = 0.01 })
  end
end

local function game_com_update(dt)
  game_update(dt)
  if not gameOver and turnSide == aiSide then
    aiThinkTimer = aiThinkTimer + dt
    if aiThinkTimer >= AI_THINK_DELAY then
      aiThinkTimer = 0
      AI.playOneMove(makeAI_API(), aiSide, gameConfig)
      -- COMの手で決着したなら学習を締める
      if TRAIN.enabled and TRAIN.learner and gameOver then
        TRAIN.learner.recorder.onGameEnd(winner)
      end
    end
  end
end

local function game_com_draw()
  game_draw()
  if not gameOver and turnSide==aiSide then
    drawBoardCenterBanner("COM Thinking...")
  end
end

local function game_com_mousepressed(mx,my,b)
  -- モーダル優先
  if handleTitleModalClick(mx,my,b) then return end
  if handleResetModalClick(mx,my,b) then return end
  -- 上部ボタン
  if handleTopButtons(mx,my,b) then return end

  -- 盤入力は人手番のみ
  if turnSide ~= humanSide or gameOver then return end

  -- 人の着手“直前”にスナップ
  if TRAIN.enabled and TRAIN.learner then
    TRAIN.learner.recorder.onPreHumanMove()
  end

  -- 一度だけ実際の着手処理
  game_mousepressed(mx,my,b)

  -- （決着チェックはこの後でOK）
  if TRAIN.enabled and TRAIN.learner and gameOver then
    TRAIN.learner.recorder.onGameEnd(winner)
  end
end

local function game_com_keypressed(k)
  if k=="z" or k=="u" or k=="r" or k=="escape" then
    game_keypressed(k)
    return
  end
  if turnSide == humanSide then
    game_keypressed(k)
  end
end

-- AIブリッジ
makeAI_API = function()
  return {
    -- 時間
    getTime = function() return (love.timer and love.timer.getTime()) or 0 end,
    timeUp  = function(deadline)
      local now = (love.timer and love.timer.getTime()) or 0
      return now >= (deadline or math.huge)
    end,

    -- ゲーム状態
    gameIsOver  = function() return gameOver end,
    setGameOver = function(win) gameOver = true; winner = win end,
    turnSide    = function() return turnSide end,
    opponent    = opponent,

    -- 盤面スナップショット/操作（探索・評価用）
    snapshot       = snapshot,
    restore        = restore,
    setFxMute      = function(b) FX_MUTE = not not b end,
    applyMoveNoFx  = applyMoveNoFx,
    tryMove        = tryMove,

    -- 合法手/評価/即時スコアなど
    listLegalMoves                 = listLegalMoves,
    listLegalMovesSide             = listLegalMovesSide,
    checkGameEnd                   = checkGameEnd,
    scoreMoveImmediate             = scoreMoveImmediate,
    scoreAfterOpponentBestReply    = scoreAfterOpponentBestReply,
    evaluateBoardFor               = evaluateBoardFor,
    quickMoveTacticalScore         = quickMoveTacticalScore,
    countEndangered                = countEndangered,
    countColors                    = countColors,
    sidePieceStats                 = sidePieceStats,
    isEndangered                   = isEndangered,
    isDefended                     = isDefended,
    -- === Eval/Learn 向けのIDユーティリティを公開 ===
    idToSide  = idToSide,   -- "RW" → "W"
    idToColor = idToColor,  -- "RW" → "R"
    colorBeats = colorBeats,

    -- ハッシュ/同一手判定
    stateDigest = stateDigest,
    sameMove = function(a,b)
      return a and b
        and a.from.c==b.from.c and a.from.r==b.from.r
        and a.to.c==b.to.c     and a.to.r==b.to.r
    end,

    -- 盤の読み取り（必要なら）
    at = function(c,r) return boardState[r] and boardState[r][c] or nil end,

    -- 定数
    consts = { GRID_ROWS = GRID_ROWS, GRID_COLS = GRID_COLS },

    resetToInitial = function()
      CURRENT_LAYOUT = LAYOUT
      setBoardOrientation('W')  -- 学習は固定で白先にしておく
      resetGame()
    end,
  }
end

scenes.game_com = {
  enter = function() game_com_enter() end,
  update = function(dt) game_com_update(dt) end,
  draw   = function()   game_com_draw()   end,
  mousepressed = function(x,y,b) game_com_mousepressed(x,y,b) end,
  keypressed   = function(k)     game_com_keypressed(k)       end,
}
-- ====== /GAME vs COM ======

-- ===== Scene registration for local game =====
scenes.game_local = {
  enter = function()
    CURRENT_LAYOUT = LAYOUT     -- ローカルは常に既定配置
    setBoardOrientation('W')    -- 下＝White の向きに戻す
    resetGame()                 -- ★ここで盤面を即リセット
  end,
  update = function(dt)   game_update(dt) end,
  draw   = function()     game_draw()     end,
  mousepressed = function(x,y,b) game_mousepressed(x,y,b) end,
  keypressed   = function(k)     game_keypressed(k)       end,
}

-- ===== LÖVE callbacks & boot =====
function love.load()
  love.graphics.setDefaultFilter("nearest", "nearest", 1)
  local w,h,flags = love.window.getMode(); flags.highdpi=true; love.window.setMode(w,h,flags)
  love.window.setTitle("三ツ巴")

  loadFonts()
  love.graphics.setFont(fonts.ui)

  board = love.graphics.newImage(IMG_DIR.."board.png")
  boardW, boardH = board:getWidth(), board:getHeight()
  boarda = love.graphics.newImage(IMG_DIR.."boarda.png")
  boardWa, boardHa = boarda:getWidth(), boarda:getHeight()
  compati = love.graphics.newImage(IMG_DIR.."compati.png")
  pieceImg["RB"]=love.graphics.newImage(IMG_DIR.."you_black.png")
  pieceImg["RW"]=love.graphics.newImage(IMG_DIR.."you_white.png")
  pieceImg["BB"]=love.graphics.newImage(IMG_DIR.."kai_black.png")
  pieceImg["BW"]=love.graphics.newImage(IMG_DIR.."kai_white.png")
  pieceImg["GB"]=love.graphics.newImage(IMG_DIR.."ti_black.png")
  pieceImg["GW"]=love.graphics.newImage(IMG_DIR.."ti_white.png")
  pcall(function()
    local ok = Eval.load()
    if ok then print("[eval] weights loaded") end
  end)

  setBoardOrientation('W')

  BOARD_INNER.x = boardW * BOARD_INNER_PCT.x
  BOARD_INNER.y = boardH * BOARD_INNER_PCT.y
  BOARD_INNER.w = boardW * BOARD_INNER_PCT.w
  BOARD_INNER.h = boardH * BOARD_INNER_PCT.h

  layoutUI()
  applyLayout(LAYOUT)
  switchScene("menu")
  love.math.setRandomSeed(os.time())
  pcall(function()
    local ok = Eval.load()
    if ok then print("[eval] weights loaded") end
  end)
end

-- ===== GAME online scene =====
scenes.game_online = {
  enter = function()
    RX = { gotH=false, pendingS=nil, pendingC=nil }  -- ★追加

    local side = gameConfig.side or "W"
    CURRENT_LAYOUT = LAYOUT
    setBoardOrientation(side)
    resetGame()

    net.start(
      gameConfig.online.role or "create",
      gameConfig.online.host,
      gameConfig.online.port,
      gameConfig.side or "W"
    )
  end,
  update = function(dt)
    game_update(dt)
    if gameConfig.mode=="online" and net then net.poll() end
  end,
  draw = function()
    game_draw()

    local msg = nil
    if not enet_ok then
      msg = "Networking disabled (ENet not found)"
    elseif not net.connected then
      msg = "Waiting for connection..."
    elseif net.role=="join" and not net.ready then
      msg = "Waiting for host handshake..."
    end

    if msg then
      drawBoardCenterBanner(msg)
    end
  end,

  mousepressed = function(mx,my,b)
    -- ★Title → Reset → TopButtons の順で早期 return
    if handleTitleModalClick(mx,my,b) then return end
    if handleResetModalClick(mx,my,b) then return end
    if handleTopButtons(mx,my,b) then return end

    -- ここから盤クリック
    if b~=1 or gameOver then return end

    -- 接続/準備チェック（必要ならホストは例外許可にしてもOK）
    if not (net and net.connected and (net.ready or net.role=="create")) then return end

    local mySide = gameConfig.side or "W"
    if turnSide ~= mySide then return end
    game_mousepressed(mx,my,b)
  end,
  keypressed = function(k)
    if k=="z" or k=="u" or k=="r" or k=="escape" then
      game_keypressed(k)
      return
    end
    local mySide = gameConfig.side or "W"
    if turnSide == mySide then
      game_keypressed(k)
    end
  end,
}
-- ===== /GAME online =====

function love.resize() layoutUI() end
function love.update(dt)
  pumpTraining()
  dispatch_update(dt)
end
function love.draw() dispatch_draw() end
function love.mousepressed(x,y,b) dispatch_mousepressed(x,y,b) end
function love.keypressed(k) dispatch_keypressed(k) end
function love.textinput(t) dispatch_textinput(t) end