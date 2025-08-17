-- ChessAdapter (ModuleScript) — Sunfish-backed move legality + helpers (drop-in replacement, fixed parse bug)
local ChessAdapter = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Chess = require(Shared:WaitForChild("Chess"))
local ChessState = require(Shared:WaitForChild("ChessState"))

-- Constants / helpers
local A1 = 91 -- algebraic 'a1' mapped to engine index base used in this repo

-- Parse algebraic square (e.g. "e4") -> engine index used by this repo (base A1 = 91).
-- Returns nil for invalid input.
local function parseSquareToIndex(s)
	if not s or #s < 2 then return nil end
	local fileChar = s:sub(1,1)
	local rankChar = s:sub(2,2)
	if not fileChar or not rankChar then return nil end
	local fil = string.byte(fileChar) - string.byte('a')
	local rank = tonumber(rankChar)
	if not fil or fil < 0 or fil > 7 or not rank or rank < 1 or rank > 8 then return nil end
	-- IMPORTANT: rank must be zero-based like the original adapter (rank - 1)
	return A1 + fil - 10 * (rank - 1)
end

-- Build the Sunfish-style 12-row board string from boardMap (table: "e4" -> "P"/"k"/etc).
-- FILES expected to be {"a","b",...,"h"}; if omitted, client/server normally pass ChessConstants.FILES.
local function buildBoardStringFromMap(boardMap, FILES)
	FILES = FILES or (require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChessConstants")).FILES)
	local rows = {
		"         \n", -- 1
		"         \n", -- 2
		" rnbqkbnr\n", -- 3  (rank 8 initial)
		" pppppppp\n", -- 4
		" ........\n", -- 5 rank 6
		" ........\n", -- 6 rank 5
		" ........\n", -- 7 rank 4
		" ........\n", -- 8 rank 3
		" PPPPPPPP\n", -- 9 rank 2
		" RNBQKBNR\n", --10 rank 1 initial
		"         \n", --11
		"          "   --12
	}
	-- Convert rows to mutable char arrays
	local rowChars = {}
	for i,row in ipairs(rows) do
		local chars = {}
		for j = 1, #row do
			chars[j] = row:sub(j,j)
		end
		rowChars[i] = chars
	end

	-- Fill piece characters from boardMap into rowChars at expected positions
	for fileIndex, fileName in ipairs(FILES) do
		for rank = 1, 8 do
			local sq = fileName .. tostring(rank)
			-- mapping in original: row index = 3 + (8 - rank), col = fileIndex + 1
			local r = 3 + (8 - rank)
			local c = fileIndex + 1
			local ch = boardMap and boardMap[sq] or '.'
			if ch == nil or ch == "" then ch = '.' end
			-- ensure indices valid
			if rowChars[r] and rowChars[r][c] then
				rowChars[r][c] = tostring(ch)
			end
		end
	end

	local parts = {}
	for i = 1, #rowChars do
		parts[i] = table.concat(rowChars[i])
	end
	return table.concat(parts)
end

-- detect castling (returns rookFrom, rookTo or nil)
local function detectCastling(fromSquare, toSquare, pieceSymbol)
	if not pieceSymbol then return nil end
	if pieceSymbol:upper() ~= "K" then return nil end
	local fromFile = fromSquare:sub(1,1)
	local toFile = toSquare:sub(1,1)
	local fileDiff = math.abs(string.byte(toFile) - string.byte(fromFile))
	if fileDiff ~= 2 then return nil end
	local rank = fromSquare:sub(2)
	if string.byte(toFile) > string.byte(fromFile) then
		return ("h" .. rank), ("f" .. rank) -- kingside: rook from h -> f
	else
		return ("a" .. rank), ("d" .. rank) -- queenside: rook from a -> d
	end
end

-- en-passant detection helper; returns captured pawn square (algebraic) or nil
local function detectEnPassant(boardMap, lastMove, fromSquare, toSquare, pieceSymbol)
	if not pieceSymbol or pieceSymbol:upper() ~= "P" then return nil end
	local fromFile = fromSquare:sub(1,1)
	local fromRank = tonumber(fromSquare:sub(2,2))
	local toFile = toSquare:sub(1,1)
	local toRank = tonumber(toSquare:sub(2,2))
	-- must be diagonal one file move
	if math.abs(string.byte(toFile) - string.byte(fromFile)) ~= 1 then return nil end
	-- target square must be empty (capturing en-passant)
	if boardMap[toSquare] ~= nil then return nil end
	if not lastMove or not lastMove.piece then return nil end
	if lastMove.piece:upper() ~= "P" then return nil end
	local lastToFile = lastMove.to:sub(1,1)
	local lastToRank = tonumber(lastMove.to:sub(2,2))
	if lastToFile ~= toFile then return nil end
	if lastToRank ~= fromRank then return nil end
	local lastFromRank = tonumber(lastMove.from:sub(2,2))
	if not lastFromRank then return nil end
	if math.abs(lastToRank - lastFromRank) ~= 2 then return nil end
	return lastMove.to -- the pawn square that was jumped and should be removed
end

-- Find a genMoves() move in pos that corresponds to from->to in board coords (handles rotation for black).
-- pos is a Chess.Position oriented for the mover, consistent with buildPosFromBoard below.
local function findPseudoLegalMoveForPos(pos, fromIdx, toIdx, side)
	for _, m in ipairs(pos:genMoves()) do
		local mi, mj = m[1], m[2]
		if side == "b" then
			-- adapter's mapping uses orig == 119 - mi/mj when pos is rotated for black
			local orig_i = 119 - mi
			local orig_j = 119 - mj
			if orig_i == fromIdx and orig_j == toIdx then
				return m
			end
		else
			if mi == fromIdx and mj == toIdx then
				return m
			end
		end
	end
	return nil
end

-- Return true if performing `move` on `pos` leaves our king still safe (i.e., move is legal).
local function moveDoesNotLeaveKingInCheck(pos, move)
	local ok, newPos = pcall(function() return pos:move(move) end)
	if not ok or not newPos then
		-- If move() errors for some reason, consider it illegal
		return false
	end
	for _, oppMove in ipairs(newPos:genMoves()) do
		local destIdx = oppMove[2]
		local ch = newPos.board:sub(destIdx + 1, destIdx + 1)
		-- check for either king character (uppercase/lowercase)
		if ch == 'k' or ch == 'K' then
			return false
		end
	end
	return true
end

-- Helper: determine if an algebraic square (e.g. "f1") is attacked by the opponent in the current pos.
-- pos must be the Position object constructed for the mover (i.e. rotated for black as buildPosFromBoard does).
local function isSquareAttackedByOpponent(pos, sqAlgebraic, side)
	-- rotate the position to opponent view and generate their moves
	local oppPos = pos:rotate()
	-- compute the target index in oppPos coordinate system
	local targetIdx
	if side == "w" then
		-- when pos is oriented for white, opponent view index is 119 - parseIndex
		local parsed = parseSquareToIndex(sqAlgebraic)
		if not parsed then return false end
		targetIdx = 119 - parsed
	else
		-- when pos is oriented for black, parseSquareToIndex already returned index suitable
		targetIdx = parseSquareToIndex(sqAlgebraic)
	end
	for _, m in ipairs(oppPos:genMoves()) do
		if m[2] == targetIdx then
			return true
		end
	end
	return false
end

-- Build a Position object from boardMap oriented for `side`. This centralizes epIndex and castling rights.
local function buildPosFromBoard(boardMap, side, FILES, lastMove)
	local boardStr = buildBoardStringFromMap(boardMap, FILES)

	-- compute en-passant square index (the square that was jumped over) if applicable
	local epSquare = nil
	if lastMove and lastMove.piece and lastMove.piece:upper() == "P" then
		local fromR = tonumber(lastMove.from:sub(2,2))
		local toR = tonumber(lastMove.to:sub(2,2))
		if fromR and toR and math.abs(toR - fromR) == 2 then
			local file = lastMove.to:sub(1,1)
			local epRank = (fromR + toR) / 2
			epSquare = file .. tostring(epRank)
		end
	end
	local epIndex = 0
	if epSquare then epIndex = parseSquareToIndex(epSquare) or 0 end

	-- castling rights stored in ChessState
	local rights = ChessState.GetCastlingRights and ChessState.GetCastlingRights() or { white = {k=true,q=true}, black = {k=true,q=true} }
	local whiteRightsArr = { rights.white.q == true, rights.white.k == true } -- {queenSide, kingSide}
	local blackRightsArr = { rights.black.q == true, rights.black.k == true }

	local pos = Chess.Position.new(boardStr, 0, whiteRightsArr, blackRightsArr, epIndex, 0)
	if side == "b" then
		pos = pos:rotate()
	end
	return pos
end

-- MAIN validation function
-- boardMap: current state from ChessState.GetBoard()
-- fromSquare,toSquare: algebraic
-- side: "w" or "b"
-- FILES: table of file names (a..h)
-- lastMove: optional last move table {from=...,to=...,piece=...} for ep
-- returns: allowed:boolean, meta:table or nil
function ChessAdapter.validateMove(boardMap, fromSquare, toSquare, side, FILES, lastMove)
	-- Meta shape preserved for compatibility with MoveAuthority and client UI
	local meta = {
		isCapture = (boardMap and boardMap[toSquare] ~= nil),
		isEnPassant = false,
		enPassantCapturedSquare = nil,
		isCastling = false,
		rookFrom = nil,
		rookTo = nil,
		candidateMove = nil,
	}

	FILES = FILES or (require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChessConstants")).FILES)

	local boardStr = buildBoardStringFromMap(boardMap, FILES)

	-- compute ep square index
	local epSquare = nil
	if lastMove and lastMove.piece and lastMove.piece:upper() == "P" then
		local fromR = tonumber(lastMove.from:sub(2,2))
		local toR = tonumber(lastMove.to:sub(2,2))
		if fromR and toR and math.abs(toR - fromR) == 2 then
			local file = lastMove.to:sub(1,1)
			local epRank = (fromR + toR) / 2
			epSquare = file .. tostring(epRank)
		end
	end
	local epIndex = 0
	if epSquare then epIndex = parseSquareToIndex(epSquare) or 0 end

	-- castling rights to pass to engine
	local rights = ChessState.GetCastlingRights and ChessState.GetCastlingRights() or { white = {k=true,q=true}, black = {k=true,q=true} }
	local whiteRightsArr = { rights.white.q == true, rights.white.k == true }
	local blackRightsArr = { rights.black.q == true, rights.black.k == true }

	-- build position and rotate if black
	local pos = Chess.Position.new(boardStr, 0, whiteRightsArr, blackRightsArr, epIndex, 0)
	if side == "b" then pos = pos:rotate() end

	local fromIdx = parseSquareToIndex(fromSquare)
	local toIdx = parseSquareToIndex(toSquare)
	if not fromIdx or not toIdx then
		return false, nil
	end

	-- find a pseudo-legal engine move matching the from->to
	local candidate = findPseudoLegalMoveForPos(pos, fromIdx, toIdx, side)
	if not candidate then
		return false, nil
	end

	-- ensure the move does not leave our king in check (engine simulation)
	if not moveDoesNotLeaveKingInCheck(pos, candidate) then
		return false, nil
	end

	-- detect en-passant (adapter-level because boardMap+lastMove give context outside engine candidate info)
	local pieceSymbol = boardMap and boardMap[fromSquare] or nil
	local epCaptured = detectEnPassant(boardMap, lastMove, fromSquare, toSquare, pieceSymbol)
	if epCaptured then
		meta.isEnPassant = true
		meta.enPassantCapturedSquare = epCaptured
		meta.isCapture = true
	end

	-- detect castling and perform additional checks that are not purely handled by the engine in your setup
	local rookFrom, rookTo = detectCastling(fromSquare, toSquare, pieceSymbol)
	if rookFrom and rookTo then
		meta.isCastling = true
		meta.rookFrom = rookFrom
		meta.rookTo = rookTo

		-- small debug helper (kept from original)
		local function dbg(msg)
			-- comment/uncomment print as needed for debug
			-- print(string.format("[ChessAdapter][castling] %s | from=%s to=%s side=%s rookFrom=%s rookTo=%s",
			-- 	 tostring(msg), tostring(fromSquare), tostring(toSquare), tostring(side), tostring(rookFrom), tostring(rookTo)))
		end

		dbg("entered castling checks")

		-- 1) ensure castling right present
		local kingSide = (rookFrom:sub(1,1) == "h")
		if side == "w" then
			if kingSide and (not rights.white.k) then dbg("reject: missing white.k right"); return false, nil end
			if (not kingSide) and (not rights.white.q) then dbg("reject: missing white.q right"); return false, nil end
		else
			if kingSide and (not rights.black.k) then dbg("reject: missing black.k right"); return false, nil end
			if (not kingSide) and (not rights.black.q) then dbg("reject: missing black.q right"); return false, nil end
		end
		dbg("passed rights check")

		-- 2) ensure rook exists and of correct color
		local rookPiece = boardMap and boardMap[rookFrom] or nil
		if not rookPiece then dbg("reject: rook missing on rookFrom"); return false, nil end
		if side == "w" and rookPiece ~= "R" then dbg("reject: rook on rookFrom wrong color (not R)"); return false, nil end
		if side == "b" and rookPiece ~= "r" then dbg("reject: rook on rookFrom wrong color (not r)"); return false, nil end
		dbg("passed rook presence/color check")

		-- 3) ensure blocking squares are empty
		local rank = fromSquare:sub(2,2)
		if kingSide then
			local s1 = ("f" .. rank)
			local s2 = ("g" .. rank)
			if boardMap[s1] ~= nil or boardMap[s2] ~= nil then
				dbg("reject: blocking piece(s) between king and rook on kingside: " .. tostring(s1) .. "," .. tostring(s2))
				return false, nil
			end
		else
			local s1 = ("b" .. rank)
			local s2 = ("c" .. rank)
			local s3 = ("d" .. rank)
			if boardMap[s1] ~= nil or boardMap[s2] ~= nil or boardMap[s3] ~= nil then
				dbg("reject: blocking piece(s) between king and rook on queenside: " .. tostring(s1) .. "," .. tostring(s2) .. "," .. tostring(s3))
				return false, nil
			end
		end
		dbg("passed empty-squares check")

		-- 4) ensure king is present and not currently in check
		local kingSquare = nil
		for sq, sym in pairs(boardMap or {}) do
			if side == "w" and sym == "K" then kingSquare = sq; break end
			if side == "b" and sym == "k" then kingSquare = sq; break end
		end
		if not kingSquare then
			dbg("reject: no king found on boardMap")
			return false, nil
		end
		if isSquareAttackedByOpponent(pos, kingSquare, side) then
			dbg("reject: king currently in check at " .. tostring(kingSquare))
			return false, nil
		end
		dbg("passed current-check test")

		-- 5) the squares the king passes through (and lands on) must not be attacked
		if kingSide then
			local pass1 = ("f" .. rank)
			local pass2 = ("g" .. rank)
			if isSquareAttackedByOpponent(pos, pass1, side) or isSquareAttackedByOpponent(pos, pass2, side) then
				dbg("reject: castling squares attacked on kingside: " .. tostring(pass1) .. "," .. tostring(pass2))
				return false, nil
			end
		else
			local pass1 = ("d" .. rank)
			local pass2 = ("c" .. rank)
			if isSquareAttackedByOpponent(pos, pass1, side) or isSquareAttackedByOpponent(pos, pass2, side) then
				dbg("reject: castling squares attacked on queenside: " .. tostring(pass1) .. "," .. tostring(pass2))
				return false, nil
			end
		end
		dbg("passed crossing-squares attack checks")
	end

	meta.candidateMove = candidate
	return true, meta
end

-- Return true if 'side' is currently in check on boardMap
function ChessAdapter.isSideInCheck(boardMap, side, FILES, lastMove)
	FILES = FILES or (require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChessConstants")).FILES)
	local pos = buildPosFromBoard(boardMap, side, FILES, lastMove)
	-- find king square algebraically
	local kingSquare = nil
	for sq, sym in pairs(boardMap or {}) do
		if side == "w" and sym == "K" then kingSquare = sq; break end
		if side == "b" and sym == "k" then kingSquare = sq; break end
	end
	if not kingSquare then return false end
	return isSquareAttackedByOpponent(pos, kingSquare, side)
end


-- Analyze: isCheck, isCheckmate, isStalemate for given side
function ChessAdapter.analyzePosition(boardMap, side, FILES, lastMove)
    FILES = FILES or (require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChessConstants")).FILES)
    local pos = buildPosFromBoard(boardMap, side, FILES, lastMove)

    -- is in check?
    local inCheck = ChessAdapter.isSideInCheck(boardMap, side, FILES, lastMove)

    -- Build index -> algebraic square map for mapping generated moves back to algebraic coords
    local indexToSquare = {}
    for _, f in ipairs(FILES) do
        for r = 1,8 do
            local sq = f .. tostring(r)
            local idx = parseSquareToIndex(sq)
            if idx then indexToSquare[idx] = sq end
        end
    end
    local function idxToAlgebraic(mi_or_mj, sideForPos)
        if sideForPos == "b" then
            local orig = 119 - mi_or_mj
            return indexToSquare[orig] or tostring(orig)
        else
            return indexToSquare[mi_or_mj] or tostring(mi_or_mj)
        end
    end

    -- generate moves for 'side' and check if any are legal using the adapter's full validation
    local anyLegal = false
    for _, m in ipairs(pos:genMoves()) do
        local mi, mj = m[1], m[2]
        local fromSq = idxToAlgebraic(mi, side)
        local toSq   = idxToAlgebraic(mj, side)

        -- attempt adapter-level validation for this candidate move:
        local ok, valid = pcall(function()
            return ChessAdapter.validateMove(boardMap, fromSq, toSq, side, FILES, lastMove)
        end)
        if ok and valid then
            anyLegal = true
            break
        end
    end

    local isCheckmate = (inCheck and not anyLegal)
    local isStalemate  = (not inCheck and not anyLegal)

    return {
        isCheck = inCheck,
        isCheckmate = isCheckmate,
        isStalemate = isStalemate
    }
end

-- Debug helper: enumerate generated moves in algebraic coordinates and whether they pass king-safety test.
-- Returns a table with posString, epIndex, castlingRights, and candidateMoves = { {from=.., to=.., mi=.., mj=.., safe=bool} }
function ChessAdapter.debugAnalyze(boardMap, side, FILES, lastMove)
	FILES = FILES or (require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChessConstants")).FILES)
	local pos = buildPosFromBoard(boardMap, side, FILES, lastMove)

	-- build index -> algebraic square map (using parseSquareToIndex mapping)
	local indexToSquare = {}
	for _, f in ipairs(FILES) do
		for r = 1, 8 do
			local sq = f .. tostring(r)
			local idx = parseSquareToIndex(sq)
			if idx then indexToSquare[idx] = sq end
		end
	end

	-- helper convert engine index to algebraic for the mover's side
	local function idxToAlgebraic(mi_or_mj, sideForPos)
		if sideForPos == "b" then
			local orig = 119 - mi_or_mj
			return indexToSquare[orig] or tostring(orig)
		else
			return indexToSquare[mi_or_mj] or tostring(mi_or_mj)
		end
	end

	local out = {
		posString = pos and pos.board or "",
		epIndex = (pos and pos.epIndex) or 0,
		castlingRights = ChessState.GetCastlingRights and ChessState.GetCastlingRights() or nil,
		candidateMoves = {}
	}

	for _, m in ipairs(pos:genMoves()) do
		local mi, mj = m[1], m[2]
		local fromSq = idxToAlgebraic(mi, side)
		local toSq   = idxToAlgebraic(mj, side)
		if not fromSq or type(fromSq) ~= "string" then fromSq = "?" end
		if not toSq   or type(toSq)   ~= "string" then toSq   = "?" end

        -- Determine whether this candidate leaves king safe according to full adapter logic
        local okSafe = false
        local safeOk, safeRes = pcall(function()
            -- From/to are computed above as fromSq/toSq
            return ChessAdapter.validateMove(boardMap, fromSq, toSq, side, FILES, lastMove)
        end)
        if safeOk and safeRes then okSafe = true end

		table.insert(out.candidateMoves, {
			from = fromSq,
			to = toSq,
			mi = mi,
			mj = mj,
			safe = okSafe,
		})
	end

	return out
end

return ChessAdapter
