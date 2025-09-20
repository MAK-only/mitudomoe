-- ai_learn.lua
local Learn = {}

function Learn.make(api, eval)
  local function V(side)
    local v = eval.value(side)
    return v
  end

  local function stepWeights(w, f, td, lr)
    for k,v in pairs(f) do
      w[k] = (w[k] or 0) + lr * td * v
    end
  end

  -- ====== 既存: 自己対戦学習 ======
  function selfPlayOnce(cfg)
    local lr    = cfg.lr or 0.01
    local gamma = cfg.gamma or 0.99
    local eps   = cfg.eps or 0.05
    local maxPlies = cfg.maxPlies or 400

    api.resetToInitial() -- 既定配置＋先手: W

    local w = eval.weights()

    for ply=1,maxPlies do
      local side = api.turnSide()
      local moves = api.listLegalMoves(side)
      if #moves == 0 then break end

      local move
      if api.rand() < eps then
        move = moves[api.randint(1,#moves)]
      else
        local bestScore, best = -1/0, nil
        for _,m in ipairs(moves) do
          local s = api.snapshot(); api.setFxMute(true)
          api.applyMoveNoFx(side, m)
          local v = V(side)
          api.setFxMute(false); api.restore(s)
          if v > bestScore then bestScore, best = v, m end
        end
        move = best or moves[1]
      end

      local v_s, f_s = eval.value(side)
      local ok = api.tryMove({c=move.from.c, r=move.from.r}, move.to.c, move.to.r)
      if not ok then break end

      local reward = 0
      local win = api.checkGameEnd(api.opponent(side))
      if win then reward = (win==side) and 1 or -1 end

      local v_sp = 0
      if reward == 0 then v_sp = -V(api.opponent(side)) end

      local td = reward + gamma * v_sp - v_s
      stepWeights(eval.weights(), f_s, td, lr)

      if reward ~= 0 then break end
    end

    eval.save()
  end

  -- ====== 追加: 人対学習レコーダ ======
  local recorder = {
    active = false,
    humanSide = "W",
    traj = {},       -- { f = features } を順に保存（人の手だけ）
    cfg = { lr = 0.01 },
  }

  function recorder.begin(humanSide, cfg)
    recorder.active = true
    recorder.humanSide = humanSide or "W"
    recorder.traj = {}
    recorder.cfg.lr = (cfg and cfg.lr) or recorder.cfg.lr
  end

  -- 人が指す直前に呼ぶ：その状態 s の特徴 f(s) を保存
  function recorder.onPreHumanMove()
    if not recorder.active then return end
    local _, f = eval.value(recorder.humanSide)
    recorder.traj[#recorder.traj+1] = { f = f }
  end

  -- 対局終了時に呼ぶ：勝ち=+1 / 負け=-1 で一括更新
  function recorder.onGameEnd(winner)
    if not recorder.active then return end
    local reward = (winner == recorder.humanSide) and 1 or (winner and -1 or 0)
    if reward ~= 0 and #recorder.traj > 0 then
      local w = eval.weights()
      for i = 1, #recorder.traj do
        stepWeights(w, recorder.traj[i].f, reward, recorder.cfg.lr)
      end
      eval.setWeights(w)
      eval.save()
    end
    recorder.active = false
    recorder.traj = {}
  end

  return {
    selfPlayOnce = selfPlayOnce,
    recorder     = recorder,
  }
end

return Learn