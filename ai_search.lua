local M = {}

local INF = 1e9
local SIZE = 8
local DIRS = {
  { 1, 0 },
  { -1, 0 },
  { 0, 1 },
  { 0,-1 },
}

local function opponent(side)
  return (side == 'W') and 'B' or 'W'
end

local function in_bounds(c, r)
  return c >= 1 and c <= SIZE and r >= 1 and r <= SIZE
end

local function piece_side(piece)
  if not piece then return nil end
  if piece == string.upper(piece) then
    return 'W'
  else
    return 'B'
  end
end

local function piece_color(piece)
  return piece and string.upper(piece) or nil
end

local function dominates(a, b)
  if not a or not b then return false end
  return (a == 'B' and b == 'R')
      or (a == 'R' and b == 'G')
      or (a == 'G' and b == 'B')
end

local function center_bonus(c, r)
  local cx, cy = (SIZE + 1) / 2, (SIZE + 1) / 2
  local dist = math.abs(c - cx) + math.abs(r - cy)
  local maxd = (cx - 1) + (cy - 1)
  if maxd == 0 then return 0 end
  return 1 - (dist / maxd)
end

local function copy_grid(src)
  local dest = {}
  for r = 1, SIZE do
    local row = {}
    for c = 1, SIZE do
      row[c] = src[r][c]
    end
    dest[r] = row
  end
  return dest
end

local function copy_counts(src)
  return {
    R = src.R or 0,
    G = src.G or 0,
    B = src.B or 0,
    total = src.total or 0,
  }
end

local function copy_move_info(move)
  if not move then return nil end
  return {
    piece_id = move.piece_id,
    from = move.from and { c = move.from.c, r = move.from.r } or nil,
    to   = move.to   and { c = move.to.c,   r = move.to.r   } or nil,
  }
end

local function copy_rep(rep)
  local dest = {}
  for k, v in pairs(rep or {}) do
    dest[k] = v
  end
  return dest
end

local function move_key(mv)
  if not mv then return '-' end
  local pid = mv.piece_id or 0
  local fc = (mv.from and mv.from.c) or 0
  local fr = (mv.from and mv.from.r) or 0
  local tc = (mv.to   and mv.to.c)   or 0
  local tr = (mv.to   and mv.to.r)   or 0
  return string.format("%d,%d>%d,%d#%d", fc, fr, tc, tr, pid)
end

local function make_key(state)
  local rows = {}
  for r = 1, SIZE do
    local row = {}
    for c = 1, SIZE do
      row[#row + 1] = state.board[r][c] or '.'
    end
    rows[#rows + 1] = table.concat(row)
  end
  return table.concat(rows, '/') .. '|' .. state.stm .. '|' .. move_key(state.last_move_white) .. '|' .. move_key(state.last_move_black)
end

local function colour_presence(counts)
  local n = 0
  if (counts.R or 0) > 0 then n = n + 1 end
  if (counts.G or 0) > 0 then n = n + 1 end
  if (counts.B or 0) > 0 then n = n + 1 end
  return n
end

local StateMT = {}
StateMT.__index = StateMT

local function move_creates_contact(state, move, piece_char)
  local toC, toR = move.to.c, move.to.r
  local fromC, fromR = move.from.c, move.from.r
  local side = piece_side(piece_char)
  for _, dir in ipairs(DIRS) do
    local nc, nr = toC + dir[1], toR + dir[2]
    if in_bounds(nc, nr) then
      if not (nc == fromC and nr == fromR) then
        local other = state.board[nr][nc]
        if other and piece_side(other) ~= side then
          return true
        end
      end
    end
  end
  return false
end

local function move_order_value(state, move, piece_char)
  local score = 0
  local side = piece_side(piece_char)
  local color = piece_color(piece_char)
  local toC, toR = move.to.c, move.to.r
  local fromC, fromR = move.from.c, move.from.r

  for _, dir in ipairs(DIRS) do
    local nc, nr = toC + dir[1], toR + dir[2]
    if in_bounds(nc, nr) then
      if not (nc == fromC and nr == fromR) then
        local other = state.board[nr][nc]
        if other and piece_side(other) ~= side then
          local other_color = piece_color(other)
          if other_color == color then
            score = score + 2.0
          elseif dominates(color, other_color) then
            score = score + 6.0
          elseif dominates(other_color, color) then
            score = score - 7.0
          end
        end
      end
    end
  end

  local forward = (side == 'W') and (fromR - toR) or (toR - fromR)
  score = score + forward * 0.8
  score = score + center_bonus(toC, toR) * 0.6

  return score
end

local function generate_moves_for_side(state, side, ordered, only_contact)
  local moves = {}
  local last = (side == 'W') and state.last_move_white or state.last_move_black
  local forbid_piece = last and last.piece_id
  local forbid_c = last and last.from and last.from.c
  local forbid_r = last and last.from and last.from.r

  for r = 1, SIZE do
    for c = 1, SIZE do
      local piece = state.board[r][c]
      if piece and piece_side(piece) == side then
        local pid = state.ids[r][c]
        for _, dir in ipairs(DIRS) do
          local nc, nr = c + dir[1], r + dir[2]
          if in_bounds(nc, nr) and state.board[nr][nc] == nil then
            if not (forbid_piece == pid and forbid_c == nc and forbid_r == nr) then
              local move = {
                from = { c = c, r = r },
                to   = { c = nc, r = nr },
                piece_id = pid,
              }
              local allow = true
              if only_contact then
                allow = move_creates_contact(state, move, piece)
              end
              if allow then
                if ordered then
                  move.score = move_order_value(state, move, piece)
                end
                moves[#moves + 1] = move
              end
            end
          end
        end
      end
    end
  end

  if ordered then
    table.sort(moves, function(a, b)
      local as, bs = a.score or 0, b.score or 0
      if as == bs then
        if a.piece_id == b.piece_id then
          if a.to.r == b.to.r then
            if a.to.c == b.to.c then
              if a.from.r == b.from.r then
                return a.from.c < b.from.c
              end
              return a.from.r < b.from.r
            end
            return a.to.c < b.to.c
          end
          return a.to.r < b.to.r
        end
        return a.piece_id < b.piece_id
      end
      return as > bs
    end)
  end

  return moves
end

function StateMT:legal_moves(side)
  return generate_moves_for_side(self, side or self.stm, false, false)
end

local function remove_piece(state, c, r)
  if not in_bounds(c, r) then return end
  local piece = state.board[r][c]
  if not piece then return end
  local side = piece_side(piece)
  local color = piece_color(piece)
  local counts = state.counts[side]
  counts[color] = (counts[color] or 0) - 1
  counts.total = (counts.total or 0) - 1
  state.board[r][c] = nil
  state.ids[r][c] = 0
end

local function check_win(state, mover_side)
  local w = state.counts.W
  local b = state.counts.B
  local loseW = (w.total or 0) <= 3 or colour_presence(w) <= 2
  local loseB = (b.total or 0) <= 3 or colour_presence(b) <= 2
  if loseW and loseB then
    return opponent(mover_side)
  elseif loseW then
    return 'B'
  elseif loseB then
    return 'W'
  end
  return nil
end

local function clone_state(state)
  local new_state = {
    board = copy_grid(state.board),
    ids = copy_grid(state.ids),
    counts = {
      W = copy_counts(state.counts.W),
      B = copy_counts(state.counts.B),
    },
    stm = opponent(state.stm),
    ply = state.ply + 1,
    turn_count = state.turn_count + 1,
    last_move_white = copy_move_info(state.last_move_white),
    last_move_black = copy_move_info(state.last_move_black),
    rep = copy_rep(state.rep),
  }
  return setmetatable(new_state, StateMT)
end

local function apply_move(state, move)
  local mover_side = state.stm
  local next_state = clone_state(state)

  local fromC, fromR = move.from.c, move.from.r
  local toC, toR = move.to.c, move.to.r
  local piece = state.board[fromR][fromC]
  local pid = state.ids[fromR][fromC]

  next_state.board[fromR][fromC] = nil
  next_state.ids[fromR][fromC] = 0
  next_state.board[toR][toC] = piece
  next_state.ids[toR][toC] = pid

  if mover_side == 'W' then
    next_state.last_move_white = { piece_id = pid, from = { c = fromC, r = fromR }, to = { c = toC, r = toR } }
  else
    next_state.last_move_black = { piece_id = pid, from = { c = fromC, r = fromR }, to = { c = toC, r = toR } }
  end

  local to_remove = {}
  local remove_self = false
  local mover_color = piece_color(piece)
  for _, dir in ipairs(DIRS) do
    local nc, nr = toC + dir[1], toR + dir[2]
    if in_bounds(nc, nr) then
      local other = next_state.board[nr][nc]
      if other and piece_side(other) ~= mover_side then
        local other_color = piece_color(other)
        if other_color == mover_color then
          to_remove[#to_remove + 1] = { c = nc, r = nr }
          remove_self = true
        elseif dominates(mover_color, other_color) then
          to_remove[#to_remove + 1] = { c = nc, r = nr }
        elseif dominates(other_color, mover_color) then
          remove_self = true
        end
      end
    end
  end

  for _, pos in ipairs(to_remove) do
    remove_piece(next_state, pos.c, pos.r)
  end
  if remove_self then
    remove_piece(next_state, toC, toR)
  end

  local key = make_key(next_state)
  next_state.rep[key] = (next_state.rep[key] or 0) + 1

  local outcome = check_win(next_state, mover_side)
  local result
  if outcome == mover_side then
    result = 'win'
  elseif outcome == opponent(mover_side) then
    result = 'lose'
  end

  return next_state, result
end

local function build_state_from_snapshot(snap, side)
  local board, ids = {}, {}
  local counts = {
    W = { R = 0, G = 0, B = 0, total = 0 },
    B = { R = 0, G = 0, B = 0, total = 0 },
  }
  local positions = {}

  for r = 1, SIZE do
    board[r], ids[r] = {}, {}
    for c = 1, SIZE do
      local cell = snap.board[r][c]
      if cell and cell.id then
        local color = cell.id:sub(1,1)
        local sideChar = cell.id:sub(2,2)
        local ch = (sideChar == 'W') and color or string.lower(color)
        board[r][c] = ch
        ids[r][c] = cell.uid or 0
        if cell.uid then
          positions[cell.uid] = { c = c, r = r, side = sideChar }
        end
        local cnt = counts[sideChar]
        cnt[color] = (cnt[color] or 0) + 1
        cnt.total = (cnt.total or 0) + 1
      else
        board[r][c] = nil
        ids[r][c] = 0
      end
    end
  end

  local state = setmetatable({
    board = board,
    ids = ids,
    counts = counts,
    stm = side or snap.turnSide or 'W',
    ply = 0,
    turn_count = snap.turnCount or 0,
    last_move_white = nil,
    last_move_black = nil,
    rep = {},
  }, StateMT)

  local expected = {
    W = (state.stm == 'W') and state.turn_count or (state.turn_count + 1),
    B = (state.stm == 'B') and state.turn_count or (state.turn_count + 1),
  }
  local fallback = { W = nil, B = nil }

  for uid, info in pairs(snap.restrictions or {}) do
    local pos = positions[uid]
    local sideChar = info.side or (pos and pos.side)
    if pos and sideChar and info.c and info.r then
      local entry = {
        piece_id = uid,
        from = { c = info.c, r = info.r },
        to   = { c = pos.c,  r = pos.r },
        expires = info.expiresAtMove,
      }
      if info.expiresAtMove == expected[sideChar] then
        if sideChar == 'W' then
          state.last_move_white = { piece_id = entry.piece_id, from = entry.from, to = entry.to }
        else
          state.last_move_black = { piece_id = entry.piece_id, from = entry.from, to = entry.to }
        end
      else
        local cur = fallback[sideChar]
        if (not cur) or ((cur.expires or -math.huge) < (info.expiresAtMove or -math.huge)) then
          fallback[sideChar] = entry
        end
      end
    end
  end

  if not state.last_move_white and fallback.W then
    state.last_move_white = { piece_id = fallback.W.piece_id, from = fallback.W.from, to = fallback.W.to }
  end
  if not state.last_move_black and fallback.B then
    state.last_move_black = { piece_id = fallback.B.piece_id, from = fallback.B.from, to = fallback.B.to }
  end

  local key = make_key(state)
  state.rep[key] = 1

  return state
end

local Search = {}
Search.__index = Search

local function default_now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

function M.make(api, eval)
  local now_fn
  if api and api.getTime then
    now_fn = function() return api.getTime() end
  else
    now_fn = default_now
  end
  return setmetatable({
    api = api,
    eval = eval,
    now_fn = now_fn,
    deadline = nil,
    timeout = false,
    nodes = 0,
  }, Search)
end

function Search:timed_out()
  return self.deadline and self.now_fn() >= self.deadline
end

function Search:quiescence(state, alpha, beta)
  if self:timed_out() then
    self.timeout = true
    return self.eval:evaluate(state, state.stm)
  end

  local stand = self.eval:evaluate(state, state.stm)
  if stand >= beta then
    return stand
  end
  if stand > alpha then
    alpha = stand
  end

  local moves = generate_moves_for_side(state, state.stm, true, true)
  for _, move in ipairs(moves) do
    local child, result = apply_move(state, move)
    local val
    if result == 'win' then
      val = INF - child.ply
    elseif result == 'lose' then
      val = -INF + child.ply
    else
      val = -self:quiescence(child, -beta, -alpha)
    end
    if self.timeout then
      return alpha
    end
    if val > alpha then
      alpha = val
    end
    if alpha >= beta then
      break
    end
  end
  return alpha
end

function Search:alphabeta(state, depth, alpha, beta, root)
  if self:timed_out() then
    self.timeout = true
    return root and 0 or self.eval:evaluate(state, state.stm)
  end

  self.nodes = self.nodes + 1

  local count = state.rep[make_key(state)] or 0
  if count >= 3 then
    return root and 0 or 0
  end

  if depth <= 0 then
    local val = self:quiescence(state, alpha, beta)
    return root and val or val
  end

  local moves = generate_moves_for_side(state, state.stm, true, false)
  if #moves == 0 then
    local outcome = check_win(state, opponent(state.stm))
    if outcome == state.stm then
      return root and INF or INF
    elseif outcome == opponent(state.stm) then
      return root and -INF or -INF
    end
    local val = self.eval:evaluate(state, state.stm)
    return root and val or val
  end

  local best = -INF
  local best_move = nil

  for _, move in ipairs(moves) do
    local child, result = apply_move(state, move)
    local val
    if result == 'win' then
      val = INF - child.ply
    elseif result == 'lose' then
      val = -INF + child.ply
    else
      val = -self:alphabeta(child, depth - 1, -beta, -alpha, false)
    end

    if self.timeout then
      break
    end

    if val > best then
      best = val
      best_move = move
    end
    if best > alpha then
      alpha = best
    end
    if alpha >= beta then
      break
    end
  end

  if root then
    return best, best_move
  end
  return best
end

function Search:pick(side, max_depth, deadline, opts)
  self.deadline = deadline
  if not self.deadline and opts and opts.time_budget then
    self.deadline = self.now_fn() + opts.time_budget
  end
  self.timeout = false
  self.nodes = 0

  local snap = self.api.snapshot()
  local state = build_state_from_snapshot(snap, side or snap.turnSide)
  state.stm = side or state.stm

  local best_move, best_score = nil, -INF
  local depth_limit = max_depth or 1

  for depth = 1, depth_limit do
    local score, move = self:alphabeta(state, depth, -INF, INF, true)
    if self.timeout then
      break
    end
    if move then
      best_move, best_score = move, score
    end
  end

  return best_score, best_move
end

return M