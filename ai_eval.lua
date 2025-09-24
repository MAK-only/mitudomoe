local Eval = {}
Eval.__index = Eval

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

local function color_presence(counts)
  local n = 0
  if (counts.R or 0) > 0 then n = n + 1 end
  if (counts.G or 0) > 0 then n = n + 1 end
  if (counts.B or 0) > 0 then n = n + 1 end
  return n
end

local function center_value(c, r)
  local cx, cy = (SIZE + 1) / 2, (SIZE + 1) / 2
  local dist = math.abs(c - cx) + math.abs(r - cy)
  local maxd = (cx - 1) + (cy - 1)
  if maxd == 0 then return 0 end
  return 1 - (dist / maxd)
end

local function legal_move_forbidden(state, side, piece_id, destC, destR)
  local last = (side == 'W') and state.last_move_white or state.last_move_black
  if not last then return false end
  if last.piece_id ~= piece_id then return false end
  if not last.from then return false end
  return last.from.c == destC and last.from.r == destR
end

local function count_capture_opportunities(state, side)
  local total = 0
  for r = 1, SIZE do
    for c = 1, SIZE do
      local piece = state.board[r][c]
      if piece and piece_side(piece) == side then
        local color = piece_color(piece)
        local pid = state.ids[r][c]
        for _, dir in ipairs(DIRS) do
          local nc, nr = c + dir[1], r + dir[2]
          if in_bounds(nc, nr) and state.board[nr][nc] == nil then
            if not legal_move_forbidden(state, side, pid, nc, nr) then
              local found = false
              for _, d2 in ipairs(DIRS) do
                local ac, ar = nc + d2[1], nr + d2[2]
                if in_bounds(ac, ar) then
                  if not (ac == c and ar == r) then
                    local enemy = state.board[ar][ac]
                    if enemy and piece_side(enemy) ~= side then
                      if dominates(color, piece_color(enemy)) then
                        total = total + 1
                        found = true
                        break
                      end
                    end
                  end
                end
              end
              if found then break end
            end
          end
        end
      end
    end
  end
  return total
end

local function count_exposure(state, side)
  local opp = opponent(side)
  local total = 0
  for r = 1, SIZE do
    for c = 1, SIZE do
      local piece = state.board[r][c]
      if piece and piece_side(piece) == side then
        local color = piece_color(piece)
        local threatened = false
        for _, dir in ipairs(DIRS) do
          local nc, nr = c + dir[1], r + dir[2]
          if in_bounds(nc, nr) then
            local enemy = state.board[nr][nc]
            if enemy and piece_side(enemy) == opp then
              local eColor = piece_color(enemy)
              if eColor == color or dominates(eColor, color) then
                threatened = true
                break
              end
            end
          end
        end
        if not threatened then
          for _, dir in ipairs(DIRS) do
            local adjC, adjR = c + dir[1], r + dir[2]
            if in_bounds(adjC, adjR) and state.board[adjR][adjC] == nil then
              local attacker = false
              for _, d2 in ipairs(DIRS) do
                local pc, pr = adjC + d2[1], adjR + d2[2]
                if in_bounds(pc, pr) then
                  if not (pc == c and pr == r) then
                    local enemy = state.board[pr][pc]
                    if enemy and piece_side(enemy) == opp then
                      local eColor = piece_color(enemy)
                      if eColor == color or dominates(eColor, color) then
                        local pid = state.ids[pr][pc]
                        if not legal_move_forbidden(state, opp, pid, adjC, adjR) then
                          attacker = true
                          break
                        end
                      end
                    end
                  end
                end
              end
              if attacker then
                threatened = true
                break
              end
            end
          end
        end
        if threatened then
          total = total + 1
        end
      end
    end
  end
  return total
end

local function count_trade_risk(state, side)
  local opp = opponent(side)
  local total = 0
  for r = 1, SIZE do
    for c = 1, SIZE do
      local piece = state.board[r][c]
      if piece and piece_side(piece) == side then
        local color = piece_color(piece)
        local risk = false
        for _, dir in ipairs(DIRS) do
          local nc, nr = c + dir[1], r + dir[2]
          if in_bounds(nc, nr) then
            local enemy = state.board[nr][nc]
            if enemy and piece_side(enemy) == opp and piece_color(enemy) == color then
              risk = true
              break
            end
          end
        end
        if not risk then
          for _, dir in ipairs(DIRS) do
            local adjC, adjR = c + dir[1], r + dir[2]
            if in_bounds(adjC, adjR) and state.board[adjR][adjC] == nil then
              local attacker = false
              for _, d2 in ipairs(DIRS) do
                local pc, pr = adjC + d2[1], adjR + d2[2]
                if in_bounds(pc, pr) then
                  if not (pc == c and pr == r) then
                    local enemy = state.board[pr][pc]
                    if enemy and piece_side(enemy) == opp and piece_color(enemy) == color then
                      local pid = state.ids[pr][pc]
                      if not legal_move_forbidden(state, opp, pid, adjC, adjR) then
                        attacker = true
                        break
                      end
                    end
                  end
                end
              end
              if attacker then
                risk = true
                break
              end
            end
          end
        end
        if risk then
          total = total + 1
        end
      end
    end
  end
  return total
end

local function central_control(state, side)
  local my, oppVal = 0, 0
  for r = 1, SIZE do
    for c = 1, SIZE do
      local piece = state.board[r][c]
      if piece then
        local val = center_value(c, r)
        if piece_side(piece) == side then
          my = my + val
        else
          oppVal = oppVal + val
        end
      end
    end
  end
  return my - oppVal
end

local function mobility(state, side)
  local moves = state:legal_moves(side)
  return #moves
end

local function colour_balance_penalty(counts)
  local r, g, b = counts.R or 0, counts.G or 0, counts.B or 0
  local mean = (r + g + b) / 3
  local var = ((r - mean) ^ 2 + (g - mean) ^ 2 + (b - mean) ^ 2) / 3
  return math.sqrt(var)
end

function Eval.make(api)
  local self = setmetatable({
    api = api,
    weights = {
      W1 = 200,
      W2 = 10,
      W3 = 12,
      W4 = 8,
      W5 = 1.5,
      W6 = 0.8,
      W7 = 5,
      piece = 5,
    },
  }, Eval)
  return self
end

function Eval:setWeights(new_weights)
  if not new_weights then return end
  for k, v in pairs(new_weights) do
    self.weights[k] = v
  end
end

function Eval:weights()
  return self.weights
end

function Eval:evaluate(state, side)
  side = side or state.stm or 'W'
  local opp = opponent(side)

  local my_counts = state.counts[side] or { R = 0, G = 0, B = 0, total = 0 }
  local opp_counts = state.counts[opp] or { R = 0, G = 0, B = 0, total = 0 }

  local my_total = my_counts.total or 0
  local opp_total = opp_counts.total or 0
  local my_colors = color_presence(my_counts)
  local opp_colors = color_presence(opp_counts)

  if my_total <= 3 or my_colors <= 2 then
    return -INF
  end
  if opp_total <= 3 or opp_colors <= 2 then
    return INF
  end

  local weights = self.weights

  local min_my = math.min(my_counts.R or 0, my_counts.G or 0, my_counts.B or 0)
  local min_opp = math.min(opp_counts.R or 0, opp_counts.G or 0, opp_counts.B or 0)
  local color_margin = min_my - min_opp

  local capture_my = count_capture_opportunities(state, side)
  local capture_opp = count_capture_opportunities(state, opp)
  local capture_adv = capture_my - capture_opp

  local exposure_my = count_exposure(state, side)
  local exposure_opp = count_exposure(state, opp)
  local exposure_diff = exposure_my - exposure_opp

  local trade_my = count_trade_risk(state, side)
  local trade_opp = count_trade_risk(state, opp)
  local trade_diff = trade_my - trade_opp

  local central_adv = central_control(state, side)
  local mobility_adv = mobility(state, side) - mobility(state, opp)

  local balance_adv = colour_balance_penalty(opp_counts) - colour_balance_penalty(my_counts)

  local piece_diff = my_total - opp_total

  local score = 0
  score = score + weights.W1 * color_margin
  score = score + weights.W2 * capture_adv
  score = score - weights.W3 * exposure_diff
  score = score - weights.W4 * trade_diff
  score = score + weights.W5 * central_adv
  score = score + weights.W6 * mobility_adv
  score = score + weights.W7 * balance_adv
  score = score + weights.piece * piece_diff

  return score
end

return Eval