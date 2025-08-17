-- MatchManager.lua
-- Simple, robust MatchManager for per-match state and participant tracking.
-- For now this reuses the global ChessState module (so singleplayer behaviour is preserved).
-- Later: replace chessState assignment with ChessStateFactory.new() to support independent matches.

local MatchManager = {}
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ChessState = require(Shared:WaitForChild("ChessState")) -- NOTE: currently module-global

-- internal storage
local matches = {} -- matchId -> match object

-- Helper: create a new match
-- opts = {
--   singlePlayer = true|false,
--   assignBothSidesTo = <Player> (optional),
--   allowSpectators = false (optional)
-- }
function MatchManager.CreateMatch(opts)
	opts = opts or {}
	local id = HttpService:GenerateGUID(false)
	local match = {
		id = id,
		-- For now reuse the global ChessState; replace with instance later.
		chessState = ChessState,
		sideToMove = "w",
		lastMove = nil,
		players = { white = nil, black = nil }, -- userId numbers
		participants = {}, -- map userId -> true (players + spectators)
		processing = false, -- per-match processing lock
		allowSpectators = opts.allowSpectators == true,
		isSinglePlayer = false,
		createdAt = os.time(),
	}
	-- single-player creation: assign both colors to the same player (if provided)
	if opts.singlePlayer and opts.assignBothSidesTo then
		local uid = opts.assignBothSidesTo.UserId
		match.players.white = uid
		match.players.black = uid
		match.isSinglePlayer = true
		-- add as participant automatically
		match.participants[uid] = true
	end

	-- if caller provided explicit one-side assignment
	if opts.assignSingleSide and opts.assignSingleSide.player and opts.assignSingleSide.side then
		local s = opts.assignSingleSide.side
		local p = opts.assignSingleSide.player
		if (s == "w" or s == "b") and p then
			match.players[s] = p.UserId
			match.participants[p.UserId] = true
		end
	end

	matches[id] = match
	return match
end

function MatchManager.GetMatch(matchId)
	if not matchId then return nil end
	return matches[matchId]
end

function MatchManager.RemoveMatch(matchId)
	if not matchId then return false end
	matches[matchId] = nil
	return true
end

function MatchManager.AssignPlayerToSide(matchId, player, side)
	if not matchId or not player or (side ~= "w" and side ~= "b") then return false end
	local m = MatchManager.GetMatch(matchId)
	if not m then return false end
	m.players[side] = player.UserId
	-- ensure assigned player receives updates
	m.participants[player.UserId] = true
	return true
end

-- Participant management
function MatchManager.AddParticipant(matchId, player)
	if not matchId or not player then return false end
	local m = MatchManager.GetMatch(matchId)
	if not m then return false end
	m.participants[player.UserId] = true
	return true
end

function MatchManager.RemoveParticipant(matchId, player)
	if not matchId or not player then return false end
	local m = MatchManager.GetMatch(matchId)
	if not m then return false end
	m.participants[player.UserId] = nil
	return true
end

function MatchManager.GetParticipants(matchId)
	local m = MatchManager.GetMatch(matchId)
	if not m then return {} end
	local out = {}
	for uid,_ in pairs(m.participants) do
		table.insert(out, uid)
	end
	return out
end

-- Return an existing single-player match for this user or create one.
-- The single-player match assigns both sides to the same user.
function MatchManager.GetOrCreateSinglePlayerMatchFor(player)
	if not player then return nil end
	-- search existing single-player matches assigned to this user
	for id,m in pairs(matches) do
		if m.isSinglePlayer and m.players.white == player.UserId and m.players.black == player.UserId then
			return m
		end
	end
	-- create new single-player match and add participant
	local m = MatchManager.CreateMatch({ singlePlayer = true, assignBothSidesTo = player })
	if m then
		m.participants[player.UserId] = true
		-- store snapshot if possible (chessState might have GetBoard)
		if m.chessState and m.chessState.GetBoard then
			m.lastBoard = m.chessState.GetBoard()
		end
	end
	return m
end

function MatchManager.GetAllMatches()
	return matches
end

-- Clean up participant entries when players leave; also optionally remove single-player matches owned by leaving user
Players.PlayerRemoving:Connect(function(player)
	-- remove player from any participants lists and optionally remove matches they exclusively own
	for id,m in pairs(matches) do
		if m.participants[player.UserId] then
			m.participants[player.UserId] = nil
		end
		-- If this is a single-player match and owner left, remove match
		if m.isSinglePlayer and m.players.white == player.UserId and m.players.black == player.UserId then
			-- remove the match to avoid stale single-player matches
			matches[id] = nil
		end
	end
end)

return MatchManager
