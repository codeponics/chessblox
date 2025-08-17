-- MoveAuthority.server.lua (match-aware + targeted broadcast)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Remote objects expected in ReplicatedStorage
local RequestMove = ReplicatedStorage:WaitForChild("RequestMove")        -- RemoteFunction
local MoveApplied = ReplicatedStorage:WaitForChild("MoveApplied")      -- RemoteEvent
local GetOrCreateMatch = ReplicatedStorage:WaitForChild("GetOrCreateMatch") -- RemoteFunction
local JoinMatch = ReplicatedStorage:WaitForChild("JoinMatch")          -- RemoteFunction
local LeaveMatch = ReplicatedStorage:WaitForChild("LeaveMatch")        -- RemoteFunction

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChessConstants = require(Shared:WaitForChild("ChessConstants"))
local ChessAdapter = require(ReplicatedStorage:WaitForChild("ClientChessUI"):WaitForChild("ChessAdapter"))
local ChessState = require(Shared:WaitForChild("ChessState")) -- server-side authoritative chess state currently reused

local MatchManager = require(game.ServerScriptService.Server.MatchManager)

-- Basic per-player illegal attempt tracker (simple anti-abuse)
local IllegalAttempts = {} -- userId -> count
local ILLEGAL_ATTEMPT_LIMIT = 8

local function recordIllegalAttempt(player, reason)
	if not player then return end
	local uid = player.UserId
	IllegalAttempts[uid] = (IllegalAttempts[uid] or 0) + 1
	warn(string.format("[MoveAuthority] Illegal attempt by %s (%d) #%d: %s",
		player.Name, uid, IllegalAttempts[uid], tostring(reason)))
	-- Optional action: kick after too many attempts (commented out by default)
	if IllegalAttempts[uid] >= ILLEGAL_ATTEMPT_LIMIT then
		pcall(function() player:Kick("Too many illegal move attempts") end)
	end
end

-- Helper: targeted broadcaster (only to participants of the match)
local function broadcastToMatch(match, payload)
	if not match or not payload then return end
	for uid,_ in pairs(match.participants or {}) do
		local pl = Players:GetPlayerByUserId(uid)
		if pl then
			pcall(function() MoveApplied:FireClient(pl, payload) end)
		end
	end
end

-- Helper: snapshot board for a match (assumes chessState has GetBoard)
local function snapshotBoardForMatch(match)
	if not match or not match.chessState or not match.chessState.GetBoard then return {} end
	return match.chessState.GetBoard()
end

-- GetOrCreateMatch RPC: returns match info and initial board snapshot
GetOrCreateMatch.OnServerInvoke = function(player)
	-- create or fetch a single-player match for this player by default
	local match = MatchManager.GetOrCreateSinglePlayerMatchFor(player)
	if not match then
		return { success = false, reason = "no_match" }
	end

	local payload = {
		matchId = match.id,
		board = snapshotBoardForMatch(match),
		lastMove = match.lastMove,
		sideToMove = match.sideToMove,
		-- assignedSide: nil => player controls both sides (singleplayer). Otherwise "w" or "b"
		assignedSide = (match.players.white == player.UserId and match.players.black == player.UserId) and nil
					   or (match.players.white == player.UserId and "w")
					   or (match.players.black == player.UserId and "b")
					   or nil,
		-- include authoritative castling rights so clients can mirror engine state
		castlingRights = (match.chessState and type(match.chessState.GetCastlingRights) == "function") and match.chessState.GetCastlingRights() or nil,
	}
	-- ensure player is participant
	match.participants[player.UserId] = true
	return { success = true, payload = payload }
end

-- JoinMatch / LeaveMatch: participants register to receive match updates
JoinMatch.OnServerInvoke = function(player, matchId)
	if not player or not matchId then return { success = false, reason = "bad_args" } end
	local m = MatchManager.GetMatch(matchId)
	if not m then return { success = false, reason = "no_match" } end

	-- Only allow join if spectator allowed OR player is assigned to match players
	if not m.allowSpectators then
		local isAssigned = (m.players.white == player.UserId) or (m.players.black == player.UserId)
		if not isAssigned then
			return { success = false, reason = "spectating_not_allowed" }
		end
	end

	MatchManager.AddParticipant(matchId, player)
	return { success = true }
end

LeaveMatch.OnServerInvoke = function(player, matchId)
	if not player or not matchId then return { success = false, reason = "bad_args" } end
	local m = MatchManager.GetMatch(matchId)
	if not m then return { success = false, reason = "no_match" } end
	MatchManager.RemoveParticipant(matchId, player)
	return { success = true }
end

-- RequestMove: client invokes with { matchId = "...", from = "e2", to = "e4", promotion = "Q" (opt) }
RequestMove.OnServerInvoke = function(player, request)
	if not player or type(request) ~= "table" then
		return { success = false, reason = "bad_request" }
	end

	-- locate match
	local match = nil
	if request.matchId then
		match = MatchManager.GetMatch(request.matchId)
	end
	-- fallback: give player their single-player match
	if not match then
		match = MatchManager.GetOrCreateSinglePlayerMatchFor(player)
		if not match then
			return { success = false, reason = "invalid_match" }
		end
	end

	-- basic shape checks
	local fromSquare = request.from
	local toSquare = request.to
	local promotion = request.promotion
	if type(fromSquare) ~= "string" or type(toSquare) ~= "string" then
		recordIllegalAttempt(player, "bad_squares")
		return { success = false, reason = "bad_squares" }
	end

	-- per-match processing lock
	if match.processing then
		return { success = false, reason = "busy" }
	end

	-- ensure the mover piece exists in this match's chessState
	local moverSymbol = match.chessState.GetPiece(fromSquare)
	if not moverSymbol then
		recordIllegalAttempt(player, "no_piece_at_from")
		return { success = false, reason = "no_piece_at_from" }
	end

	local moverSide = (moverSymbol:upper() == moverSymbol) and "w" or "b"

	-- if match has assigned side and player doesn't own that side, reject
	local assignedUidForMover = match.players[moverSide]
	if assignedUidForMover and assignedUidForMover ~= player.UserId then
		recordIllegalAttempt(player, "not_allowed_color")
		return { success = false, reason = "not_allowed_color" }
	end

	-- server-turn check
	if moverSide ~= match.sideToMove then
		recordIllegalAttempt(player, "not_your_turn")
		return { success = false, reason = "not_your_turn" }
	end

	-- server-side promotion requirement (ensure promotion provided if needed)
	local function requiresPromotion(boardMap, fromS, toS)
		local p = boardMap[fromS]
		if not p or p:upper() ~= "P" then return false end
		local r = tonumber(toS:sub(2,2))
		if p == "P" and r == 8 then return true end
		if p == "p" and r == 1 then return true end
		return false
	end

	local boardMap = match.chessState.GetBoard()
	if requiresPromotion(boardMap, fromSquare, toSquare) then
		if not promotion then
			return { success = false, reason = "promotion_required" }
		end
		-- validate promotion symbol
		local validSymbols = moverSide == "w" and {Q=true,R=true,B=true,N=true} or {q=true,r=true,b=true,n=true}
		if not validSymbols[promotion] then
			recordIllegalAttempt(player, "invalid_promotion")
			return { success = false, reason = "invalid_promotion" }
		end
	end

	-- Validate using ChessAdapter (server authoritative). Use pcall to catch engine errors.
	match.processing = true
	local ok, valid, meta = pcall(function()
		return ChessAdapter.validateMove(boardMap, fromSquare, toSquare, moverSide, ChessConstants.FILES, match.lastMove)
	end)

	if not ok then
		match.processing = false
		recordIllegalAttempt(player, "engine_error")
		return { success = false, reason = "engine_error" }
	end

	if not valid then
		match.processing = false
		recordIllegalAttempt(player, "illegal_move")
		return { success = false, reason = "illegal_move" }
	end

	-- Apply move on match.chessState (same sequence as before)
	local function applyMoveServerSideForMatch(m, fromS, toS, promotionSym, metaT)
		local cs = m.chessState
		cs.MovePiece(fromS, toS)
		if metaT and metaT.isEnPassant and metaT.enPassantCapturedSquare then
			cs.ClearPiece(metaT.enPassantCapturedSquare)
		end
		if promotionSym then
			cs.SetPiece(toS, promotionSym)
		end
		if metaT and metaT.isCastling and metaT.rookFrom and metaT.rookTo then
			cs.MovePiece(metaT.rookFrom, metaT.rookTo)
		end
	end

	applyMoveServerSideForMatch(match, fromSquare, toSquare, promotion, meta)

	-- build server lastMove and flip turn
	local pieceAtTo = match.chessState.GetPiece(toSquare)
	local serverLastMove = { from = fromSquare, to = toSquare, piece = pieceAtTo }
	match.sideToMove = (match.sideToMove == "w") and "b" or "w"
	match.lastMove = serverLastMove

	-- optional analysis
	local analysis = nil
	pcall(function()
		analysis = ChessAdapter.analyzePosition(match.chessState.GetBoard(), match.sideToMove, ChessConstants.FILES, match.lastMove)
	end)


    -- debug: enumerate candidate moves and safe flags from engine (very verbose; remove in production)
    local okDbg, dbgInfo = pcall(function()
        if type(ChessAdapter.debugAnalyze) == "function" then
            return ChessAdapter.debugAnalyze(match.chessState.GetBoard(), match.sideToMove, ChessConstants.FILES, match.lastMove)
        end
        return nil
    end)
    if okDbg and dbgInfo then
        pcall(function()
            print(string.format("[MoveAuthority][DEBUG] castlingRights: w.k=%s w.q=%s b.k=%s b.q=%s",
                tostring(dbgInfo.castlingRights and dbgInfo.castlingRights.white and dbgInfo.castlingRights.white.k),
                tostring(dbgInfo.castlingRights and dbgInfo.castlingRights.white and dbgInfo.castlingRights.white.q),
                tostring(dbgInfo.castlingRights and dbgInfo.castlingRights.black and dbgInfo.castlingRights.black.k),
                tostring(dbgInfo.castlingRights and dbgInfo.castlingRights.black and dbgInfo.castlingRights.black.q)))
            print("[MoveAuthority][DEBUG] pos board string (snippet):")
            local s = tostring(dbgInfo.posString or "")
            print(string.sub(s,1,200)) -- print short snippet to avoid huge logs
            print("[MoveAuthority][DEBUG] Candidate moves (from->to, safe):")
            for i,cm in ipairs(dbgInfo.candidateMoves) do
                print(string.format("  #%d  %s -> %s   safe=%s   (mi=%d mj=%d)", i, tostring(cm.from), tostring(cm.to), tostring(cm.safe), tonumber(cm.mi) or -1, tonumber(cm.mj) or -1))
            end
        end)
    end

	-- build payload to send to participants (authoritative)
	local payload = {
		matchId = match.id,
		board = snapshotBoardForMatch(match),
		lastMove = match.lastMove,
		meta = meta,
		sideToMove = match.sideToMove,
		analysis = analysis,
		initiator = player.UserId,
		-- include authoritative castling rights so clients can mirror engine state
		castlingRights = (match.chessState and type(match.chessState.GetCastlingRights) == "function") and match.chessState.GetCastlingRights() or nil,
	}

	-- Targeted broadcast to participants (safe)
	broadcastToMatch(match, payload)

	-- done processing
	match.processing = false

	-- reset illegal attempts counter on success
	IllegalAttempts[player.UserId] = nil

	-- return success & payload to caller (convenience)
	return { success = true, payload = payload }
end
