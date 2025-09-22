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

    local FEATURE_ORDER = {
    "piece_count",
    "kind_diff",
    "danger",
    "defend",
    "last_penalty",
    "advance",
    "center",
    "mobility",
  }
  local DATA_FILE = "ai_training_data.txt"
  local MAX_DATASET = 30000

  local dataset = { samples = {}, dirty = false }

  local function cloneFeaturesOrdered(src)
    local dest = {}
    if not src then return dest end
    for _,key in ipairs(FEATURE_ORDER) do
      dest[key] = src[key] or 0
    end
    return dest
  end

  local function serializeSample(sample)
    local tokens = { string.format("%.6f", sample.reward or 0) }
    for _,key in ipairs(FEATURE_ORDER) do
      tokens[#tokens+1] = string.format("%.6f", sample.features[key] or 0)
    end
    return table.concat(tokens, "\t")
  end

  local function loadDataset()
    dataset.samples = {}
    if not (love and love.filesystem) then
      dataset.dirty = false
      return 0
    end
    local info = love.filesystem.getInfo(DATA_FILE)
    if not info then
      dataset.dirty = false
      return 0
    end
    local raw = love.filesystem.read(DATA_FILE)
    if not raw then
      dataset.dirty = false
      return 0
    end
    for line in raw:gmatch("[^\r\n]+") do
      if line:sub(1,1) ~= "#" then
        local fields = {}
        for token in line:gmatch("[^\t]+") do
          fields[#fields+1] = token
        end
        if #fields == #FEATURE_ORDER + 1 then
          local reward = tonumber(fields[1])
          if reward then
            local feat = {}
            for i,key in ipairs(FEATURE_ORDER) do
              feat[key] = tonumber(fields[i+1]) or 0
            end
            dataset.samples[#dataset.samples+1] = { reward = reward, features = feat }
          end
        end
      end
    end
    dataset.dirty = false
    return #dataset.samples
  end

  local function saveDataset()
    if not dataset.dirty then return true end
    if not (love and love.filesystem) then return false end
    local lines = { "# reward\t" .. table.concat(FEATURE_ORDER, "\t") }
    for _,sample in ipairs(dataset.samples) do
      lines[#lines+1] = serializeSample(sample)
    end
    love.filesystem.write(DATA_FILE, table.concat(lines, "\n"))
    dataset.dirty = false
    return true
  end

  loadDataset()

  local function datasetSize()
    return #dataset.samples
  end

  local function datasetFileName()
    return DATA_FILE
  end

  local function appendSample(reward, features)
    if not reward or reward == 0 or not features then return nil end
    local sample = { reward = reward, features = cloneFeaturesOrdered(features) }
    dataset.samples[#dataset.samples+1] = sample
    if #dataset.samples > MAX_DATASET then
      table.remove(dataset.samples, 1)
    end
    dataset.dirty = true
    return sample
  end

  local function trainWithSamples(samples, lr)
    if not samples or #samples == 0 then return end
    local w = eval.weights()
    for _,sample in ipairs(samples) do
      local pred = 0
      for k,v in pairs(sample.features) do
        pred = pred + (w[k] or 0) * v
      end
      local td = sample.reward - pred
      stepWeights(w, sample.features, td, lr)
    end
    eval.setWeights(w)
    if eval.save then pcall(eval.save) end
    saveDataset()
  end

  local function commitSamples(entries, lr)
    if not entries or #entries == 0 then return end
    local newSamples = {}
    for _,entry in ipairs(entries) do
      local sample = appendSample(entry.reward, entry.features)
      if sample then
        newSamples[#newSamples+1] = sample
      end
    end
    trainWithSamples(newSamples, lr)
  end

  local function rand01()
    if api and api.rand then return api.rand() end
    if love and love.math and love.math.random then
      return love.math.random()
    end
    return math.random()
  end

  local function randInt(a, b)
    if api and api.randint then return api.randint(a, b) end
    if love and love.math and love.math.random then
      return love.math.random(a, b)
    end
    return math.random(a, b)
  end

  local function winnerSamples(trajectory, winSide)
    if not winSide or not trajectory then return {} end
    local samples = {}
    for _,step in ipairs(trajectory) do
      local reward = (step.side == winSide) and 1 or -1
      samples[#samples+1] = { reward = reward, features = step.features }
    end
    return samples
  end

  -- ====== 既存: 自己対戦学習（強化学習＋データ保存） ======
  function selfPlayOnce(cfg)
    local lr    = cfg.lr or 0.01
    local gamma = cfg.gamma or 0.99
    local eps   = cfg.eps or 0.05
    local maxPlies = cfg.maxPlies or 400

    if api.resetToInitial then api.resetToInitial() end

    local trajectory = {}
    local finalWinner = nil

    for ply = 1, maxPlies do
      local side = api.turnSide()
      local moves = api.listLegalMoves(side)
     if not moves or #moves == 0 then break end

      local move
      if rand01() < eps then
        move = moves[randInt(1, #moves)]
      else
        local bestScore, best = -1/0, nil
        for _,m in ipairs(moves) do
          local s = api.snapshot(); api.setFxMute(true)
          api.applyMoveNoFx(side, m)
          local v = V(side)
          api.setFxMute(false); api.restore(s)
          if v > bestScore then bestScore, best = v, m end
        end
        move = best or moves[randInt(1, #moves)]
      end

      local v_s, f_s = eval.value(side)
      trajectory[#trajectory+1] = { side = side, features = cloneFeaturesOrdered(f_s) }

      local ok = api.tryMove({ c = move.from.c, r = move.from.r }, move.to.c, move.to.r)
        if not ok then break end

        local reward = 0
        local win = api.checkGameEnd(api.opponent(side))
        if win then reward = (win == side) and 1 or -1 end

        local v_sp = 0
        if reward == 0 then
          v_sp = -V(api.opponent(side))
        end

        local td = reward + gamma * v_sp - v_s
        stepWeights(eval.weights(), f_s, td, lr)

      if reward ~= 0 then
        finalWinner = win
        break
      end
    end

    local savedByCommit = false
    if finalWinner then
      commitSamples(winnerSamples(trajectory, finalWinner), lr)
      savedByCommit = true
    end

    if eval.save and not savedByCommit then pcall(eval.save) end
    saveDataset()
  end

  -- ====== 人対局からのサンプル採取 ======
  local recorder = {
    active = false,
    humanSide = "W",
    traj = {},
    cfg = { lr = 0.01 },
  }

  function recorder.begin(humanSide, cfg)
    recorder.active = true
    recorder.humanSide = humanSide or "W"
    recorder.traj = {}
    recorder.cfg.lr = (cfg and cfg.lr) or recorder.cfg.lr
  end

  function recorder.onPreHumanMove()
    if not recorder.active then return end
    local _, f = eval.value(recorder.humanSide)
    recorder.traj[#recorder.traj+1] = {
      side = recorder.humanSide,
      features = cloneFeaturesOrdered(f),
    }
  end

  function recorder.onGameEnd(winner)
    if not recorder.active then return end
    local reward = (winner == recorder.humanSide) and 1 or (winner and -1 or 0)
    if reward ~= 0 and #recorder.traj > 0 then
      local samples = {}
      for _,step in ipairs(recorder.traj) do
        samples[#samples+1] = { reward = reward, features = step.features }
      end
      commitSamples(samples, recorder.cfg.lr)
    end
    recorder.active = false
    recorder.traj = {}
  end

  return {
    selfPlayOnce   = selfPlayOnce,
    recorder       = recorder,
    getDatasetSize = datasetSize,
    getDatasetFile = datasetFileName,
    saveDataset    = saveDataset,
    loadDataset    = loadDataset,
    saveAll = function()
      if eval.save then pcall(eval.save) end
      saveDataset()
    end,
    loadAll = function()
      if eval.load then pcall(eval.load) end
      loadDataset()
    end,
  }
end

return Learn