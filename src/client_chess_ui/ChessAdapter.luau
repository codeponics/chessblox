-- ChessAdapter (ModuleScript) — updated castling checks
local ChessAdapter = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Chess = require(Shared:WaitForChild("Chess"))
local ChessState = require(Shared:WaitForChild("ChessState"))

-- helpers
local A1 = 91
local function parseSquareToIndex(s)
    if not s then return nil end
    local p, v = s:sub(1,1), s:sub(2,2)
    if not p or not v then return nil end
    local fil = string.byte(p) - string.byte('a')
    local rank = tonumber(v) - 1
    return A1 + fil - 10*rank
end

local function buildBoardStringFromMap(boardMap, FILES)
    local rows = {
        "         \n", "         \n", " rnbqkbnr\n", " pppppppp\n",
        " ........\n", " ........\n", " ........\n", " ........\n",
        " PPPPPPPP\n", " RNBQKBNR\n", "         \n", "          "
    }
    local rowChars = {}
    for i,row in ipairs(rows) do
        local chars = {}
        for j=1,#row do chars[j] = row:sub(j,j) end
        rowChars[i] = chars
    end
    for fileIndex, fileName in ipairs(FILES) do
        for rank = 1,8 do
            local sq = fileName .. tostring(rank)
            local r = 3 + (8 - rank)
            local c = fileIndex + 1
            local ch = boardMap[sq] or '.'
            if ch == nil or ch == "" then ch = '.' end
            rowChars[r][c] = tostring(ch)
        end
    end
    local parts = {}
    for i=1,#rowChars do parts[i] = table.concat(rowChars[i]) end
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
        return ("h" .. rank), ("f" .. rank)
    else
        return ("a" .. rank), ("d" .. rank)
    end
end

-- en-passant detection helper
local function detectEnPassant(boardMap, lastMove, fromSquare, toSquare, pieceSymbol)
    if not pieceSymbol or pieceSymbol:upper() ~= "P" then return nil end
    local fromFile = fromSquare:sub(1,1)
    local fromRank = tonumber(fromSquare:sub(2,2))
    local toFile = toSquare:sub(1,1)
    local toRank = tonumber(toSquare:sub(2,2))
    if math.abs(string.byte(toFile) - string.byte(fromFile)) ~= 1 then return nil end
    -- target must be empty now
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
    return lastMove.to -- the pawn that was jumped
end

-- Find a genMoves() move in pos that corresponds to from->to in board coords (handles rotation for black)
local function findPseudoLegalMoveForPos(pos, fromIdx, toIdx, side)
    for _,m in ipairs(pos:genMoves()) do
        local mi, mj = m[1], m[2]
        if side == "b" then
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

-- Test whether move leaves mover's king in check (reused)
local function moveDoesNotLeaveKingInCheck(pos, move)
    local newPos = pos:move(move)
    for _,oppMove in ipairs(newPos:genMoves()) do
        local destIdx = oppMove[2]
        local ch = newPos.board:sub(destIdx + 1, destIdx + 1)
        if ch == 'k' then
            return false
        end
    end
    return true
end

-- Helper: determine if an algebraic square (e.g. "f1") is attacked by the opponent in the current pos
-- pos must be the Position object constructed for the mover (i.e. rotated for black as we do below).
local function isSquareAttackedByOpponent(pos, sqAlgebraic, side)
    local oppPos = pos:rotate()
    -- computing target index in oppPos coordinate system:
    local targetIdx
    if side == "w" then
        targetIdx = 119 - parseSquareToIndex(sqAlgebraic)
    else
        targetIdx = parseSquareToIndex(sqAlgebraic)
    end
    for _,m in ipairs(oppPos:genMoves()) do
        if m[2] == targetIdx then
            return true
        end
    end
    return false
end

-- MAIN validation function
-- boardMap: current state from ChessState.GetBoard()
-- fromSquare,toSquare: algebraic
-- side: "w" or "b"
-- FILES: table of file names (a..h)
-- lastMove: optional last move table {from=...,to=...,piece=...} for ep
-- returns: allowed:boolean, meta:table or nil
function ChessAdapter.validateMove(boardMap, fromSquare, toSquare, side, FILES, lastMove)
    local meta = {
        isCapture = (boardMap[toSquare] ~= nil),
        isEnPassant = false,
        enPassantCapturedSquare = nil,
        isCastling = false,
        rookFrom = nil,
        rookTo = nil,
        candidateMove = nil,
    }

    local boardStr = buildBoardStringFromMap(boardMap, FILES)

    -- compute epSquare index (the square that was jumped over) if applicable
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

    local rights = ChessState.GetCastlingRights() or { white = {k=true,q=true}, black = {k=true,q=true} }
    -- Engine expects {queenSide, kingSide}
    local whiteRightsArr = { rights.white.q == true, rights.white.k == true }
    local blackRightsArr = { rights.black.q == true, rights.black.k == true }

    local pos = Chess.Position.new(boardStr, 0, whiteRightsArr, blackRightsArr, epIndex, 0)
    if side == "b" then pos = pos:rotate() end

    local fromIdx = parseSquareToIndex(fromSquare)
    local toIdx = parseSquareToIndex(toSquare)

    local candidate = findPseudoLegalMoveForPos(pos, fromIdx, toIdx, side)
    if not candidate then
        return false, nil
    end

    -- check king safety AFTER the move (engine check)
    if not moveDoesNotLeaveKingInCheck(pos, candidate) then
        return false, nil
    end

    -- detect en-passant
    local pieceSymbol = boardMap[fromSquare]
    local epCaptured = detectEnPassant(boardMap, lastMove, fromSquare, toSquare, pieceSymbol)
    if epCaptured then
        meta.isEnPassant = true
        meta.enPassantCapturedSquare = epCaptured
        meta.isCapture = true
    end


    -- detect castling
    local rookFrom, rookTo = detectCastling(fromSquare, toSquare, pieceSymbol)
    if rookFrom and rookTo then
        meta.isCastling = true
        meta.rookFrom = rookFrom
        meta.rookTo = rookTo

        -- debug helper
        local function dbg(msg)
            print(string.format("[ChessAdapter][castling] %s | from=%s to=%s side=%s rookFrom=%s rookTo=%s",
                tostring(msg), tostring(fromSquare), tostring(toSquare), tostring(side), tostring(rookFrom), tostring(rookTo)))
        end

        dbg("entered castling checks")

        -- 1) ensure castling right is present for this color & side
        local kingSide = (rookFrom:sub(1,1) == "h") -- true if kingside
        if side == "w" then
            if kingSide and (not rights.white.k) then dbg("reject: missing white.k right"); return false, nil end
            if (not kingSide) and (not rights.white.q) then dbg("reject: missing white.q right"); return false, nil end
        else
            if kingSide and (not rights.black.k) then dbg("reject: missing black.k right"); return false, nil end
            if (not kingSide) and (not rights.black.q) then dbg("reject: missing black.q right"); return false, nil end
        end
        dbg("passed rights check")

        -- 2) ensure the rook exists on rookFrom and is correct color
        local rookPiece = boardMap[rookFrom]
        if not rookPiece then dbg("reject: rook missing on rookFrom"); return false, nil end
        if side == "w" and rookPiece ~= "R" then dbg("reject: rook on rookFrom wrong color (not R)"); return false, nil end
        if side == "b" and rookPiece ~= "r" then dbg("reject: rook on rookFrom wrong color (not r)"); return false, nil end
        dbg("passed rook presence/color check")

        -- 3) ensure all squares between king and rook are empty
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

        -- 4) king must not be currently in check
        local kingSquare = nil
        for sq, sym in pairs(boardMap) do
            if side == "w" and sym == "K" then kingSquare = sq break end
            if side == "b" and sym == "k" then kingSquare = sq break end
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

        -- 5) the squares the king crosses (and lands on) must not be attacked.
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


local function buildPosFromBoard(boardMap, side, FILES, lastMove)
    local boardStr = buildBoardStringFromMap(boardMap, FILES)

    -- compute epSquare index (passed-over square)
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

    local rights = ChessState.GetCastlingRights() or { white = {k=true,q=true}, black = {k=true,q=true} }
    -- Engine expects {queenSide, kingSide}
    local whiteRightsArr = { rights.white.q == true, rights.white.k == true }
    local blackRightsArr = { rights.black.q == true, rights.black.k == true }

    local pos = Chess.Position.new(boardStr, 0, whiteRightsArr, blackRightsArr, epIndex, 0)
    if side == "b" then pos = pos:rotate() end
    return pos
end

-- Return true if 'side' is currently in check on boardMap
function ChessAdapter.isSideInCheck(boardMap, side, FILES, lastMove)
    FILES = FILES or (require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChessConstants")).FILES)
    local pos = buildPosFromBoard(boardMap, side, FILES, lastMove)
    -- find king square algebraically
    local kingSquare = nil
    for sq, sym in pairs(boardMap) do
        if side == "w" and sym == "K" then kingSquare = sq; break end
        if side == "b" and sym == "k" then kingSquare = sq; break end
    end
    if not kingSquare then return false end
    return isSquareAttackedByOpponent(pos, kingSquare, side)
end

-- Analyze: check, checkmate, stalemate for given side
function ChessAdapter.analyzePosition(boardMap, side, FILES, lastMove)
    FILES = FILES or (require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChessConstants")).FILES)
    local pos = buildPosFromBoard(boardMap, side, FILES, lastMove)

    -- is in check?
    local inCheck = ChessAdapter.isSideInCheck(boardMap, side, FILES, lastMove)

    -- generate moves for 'side' (pos is oriented for side)
    local anyLegal = false
    for _, m in ipairs(pos:genMoves()) do
        if moveDoesNotLeaveKingInCheck(pos, m) then
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


return ChessAdapter
