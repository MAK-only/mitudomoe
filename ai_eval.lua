local M = {}


-- ===== ユーティリティ =====
local function is_empty(v) return v == 0 or v == "0" or v == "." end
local function is_white(v) return type(v) == "string" and v:match("[RGB]") ~= nil end
local function is_black(v) return type(v) == "string" and v:match("[rgb]") ~= nil end
local function color_of(v)
if is_empty(v) then return nil end
local c = v
if is_black(v) then c = string.upper(v) end
if c == 'R' or c == 'G' or c == 'B' then return c end
return nil
end


local function opp(side) return side == 'white' and 'black' or 'white' end


-- 三すくみ：優位色 a が b を食うか？（a,bはいずれも大文字色）
local function dominates(a, b)
if a == 'B' and b == 'R' then return true end
if a == 'R' and b == 'G' then return true end
if a == 'G' and b == 'B' then return true end
return false
end


local DIRS = {{-1,0},{1,0},{0,-1},{0,1}}


-- 盤サイズは 8x8 固定前提
local function inb(r,c) return r>=1 and r<=8 and c>=1 and c<=8 end


-- 色別カウント
local function count_colors(state, side)
local R,G,B = 0,0,0
for r=1,8 do for c=1,8 do
local v = state.board[r][c]
if side=='white' and is_white(v) or side=='black' and is_black(v) then
local col = color_of(v)
if col=='R' then R=R+1 elseif col=='G' then G=G+1 elseif col=='B' then B=B+1 end
end
end end
return R,G,B
end


-- 1手で隣接可能な“捕食機会/脆弱露出/相打ち危険”を概算
local function one_step_maps(state)
-- それぞれの色マップを作る（位置 -> true）
local W = {R={},G={},B={}}; local Bk = {R={},G={},B={}}
for r=1,8 do for c=1,8 do
local v = state.board[r][c]; local col = color_of(v)
if col then
if is_white(v) then W[col][(r<<3)+c] = true else Bk[col][(r<<3)+c] = true end
end
end end
return W,Bk
end


-- 機動力（直近戻り禁止を考慮した概算）
local function mobility(state, side)
local last = (side=='white') and state.last_move_white or state.last_move_black
local forbid_id, forbid_to
if last and last.id and last.from then forbid_id, forbid_to = last.id, (last.from.r<<3)+last.from.c end
local cnt = 0
for r=1,8 do for c=1,8 do
local v = state.board[r][c]
return M