-- ChessState (ModuleScript) placed in ReplicatedStorage.Shared
-- Adds castling-rights bookkeeping so adapter can consult real rights.

local ChessConstants = require(script.Parent:WaitForChild("ChessConstants"))

local ChessState = {}
ChessState.__index = ChessState

-- internal board table: square -> pieceSymbol (string) or nil
local board = {}

-- castling rights structure
-- white.k = kingside (h1), white.q = queenside (a1), black.k = kingside (h8), black.q = queenside (a8)
local castling = {
    white = { k = true, q = true },
    black = { k = true, q = true },
}

local function clearBoard()
    board = {}
    castling = {
        white = { k = true, q = true },
        black = { k = true, q = true },
    }
end

local function setSquare(square, symbol)
    if symbol == nil or symbol == "" then
        board[square] = nil
    else
        board[square] = tostring(symbol)
    end
end

local function getSquare(square)
    return board[square]
end

-- helper: update castling flags when a piece moves from 'from' or is captured on 'to'
local function clearCastlingIfKingOrRookMovedOrCaptured(movingFrom, movingTo, movedSymbol)
    -- movedSymbol is pre-move symbol at movingFrom (e.g. "K","R","k","r")
    if not movedSymbol then return end

    local function snapshot()
        return string.format("w.k=%s w.q=%s b.k=%s b.q=%s",
            tostring(castling.white.k), tostring(castling.white.q),
            tostring(castling.black.k), tostring(castling.black.q))
    end
    local before = snapshot()

    -- King moved -> remove both castling rights for that color
    if movedSymbol == "K" then
        castling.white.k = false
        castling.white.q = false
    elseif movedSymbol == "k" then
        castling.black.k = false
        castling.black.q = false
    end

    -- Rook moved from original rook squares -> clear corresponding flag
    if movedSymbol == "R" then
        if movingFrom == "h1" then castling.white.k = false end
        if movingFrom == "a1" then castling.white.q = false end
    elseif movedSymbol == "r" then
        if movingFrom == "h8" then castling.black.k = false end
        if movingFrom == "a8" then castling.black.q = false end
    end

    -- If move captures a rook on its original square, clear its castling right
    local captured = board[movingTo]
    if captured == "R" then
        if movingTo == "h1" then castling.white.k = false end
        if movingTo == "a1" then castling.white.q = false end
    elseif captured == "r" then
        if movingTo == "h8" then castling.black.k = false end
        if movingTo == "a8" then castling.black.q = false end
    end

    local after = snapshot()
    if before ~= after then
        print("[ChessState] clearCastlingIfKingOrRookMovedOrCaptured:", movingFrom, "->", movingTo, "movedSymbol=", tostring(movedSymbol))
        print("    before:", before)
        print("    after: ", after)
    end
end

-- initialize from STARTING_RANKS in ChessConstants
function ChessState.InitializeFromConstants()
    clearBoard()
    -- black
    if ChessConstants.STARTING_RANKS and ChessConstants.STARTING_RANKS.black then
        for rank, row in pairs(ChessConstants.STARTING_RANKS.black) do
            for file = 1, #row do
                local sym = row[file]
                local square = ChessConstants.FILES[file] .. tostring(rank)
                setSquare(square, sym)
            end
        end
    end
    -- white
    if ChessConstants.STARTING_RANKS and ChessConstants.STARTING_RANKS.white then
        for rank, row in pairs(ChessConstants.STARTING_RANKS.white) do
            for file = 1, #row do
                local sym = row[file]
                local square = ChessConstants.FILES[file] .. tostring(rank)
                setSquare(square, sym)
            end
        end
    end
    -- set default castling rights based on starting pieces present
    castling.white.k = (board["h1"] == "R") and (board["e1"] == "K")
    castling.white.q = (board["a1"] == "R") and (board["e1"] == "K")
    castling.black.k = (board["h8"] == "r") and (board["e8"] == "k")
    castling.black.q = (board["a8"] == "r") and (board["e8"] == "k")
end

-- move piece (does not validate move legality)
-- returns true if something changed
function ChessState.MovePiece(fromSquare, toSquare)
    local sym = getSquare(fromSquare)
    if not sym then return false end

    -- update castling flags if necessary (handle capture too)
    clearCastlingIfKingOrRookMovedOrCaptured(fromSquare, toSquare, sym)

    -- perform move
    setSquare(fromSquare, nil)
    setSquare(toSquare, sym)
    return true
end

function ChessState.SetPiece(square, pieceSymbol)
    -- If replacing a pawn with promoted piece or setting piece manually, ensure to clear castling if overwrote rook or king
    local existing = getSquare(square)
    if existing then
        if existing == "R" or existing == "r" or existing == "K" or existing == "k" then
            print("[ChessState] SetPiece will replace existing", existing, "on", square)
        end
        -- if we are removing a rook on original square, clear
        if existing == "R" then
            if square == "h1" then castling.white.k = false end
            if square == "a1" then castling.white.q = false end
        elseif existing == "r" then
            if square == "h8" then castling.black.k = false end
            if square == "a8" then castling.black.q = false end
        elseif existing == "K" then
            castling.white.k = false
            castling.white.q = false
        elseif existing == "k" then
            castling.black.k = false
            castling.black.q = false
        end
    end
    setSquare(square, pieceSymbol)
end

function ChessState.ClearPiece(square)
    local existing = getSquare(square)
    if existing then
        -- if clearing a rook on starting square -> clear castling right
        if existing == "R" then
            if square == "h1" then castling.white.k = false end
            if square == "a1" then castling.white.q = false end
        elseif existing == "r" then
            if square == "h8" then castling.black.k = false end
            if square == "a8" then castling.black.q = false end
        elseif existing == "K" then
            castling.white.k = false
            castling.white.q = false
        elseif existing == "k" then
            castling.black.k = false
            castling.black.q = false
        end
        setSquare(square, nil)
    end
end

function ChessState.GetPiece(square)
    return getSquare(square)
end

function ChessState.GetBoard()
    -- shallow copy
    local copy = {}
    for k,v in pairs(board) do copy[k] = v end
    return copy
end

function ChessState.GetCastlingRights()
    -- return a copy to avoid accidental mutation
    return {
        white = { k = castling.white.k, q = castling.white.q },
        black = { k = castling.black.k, q = castling.black.q },
    }
end

function ChessState.SetCastlingRights(newRights)
    if not newRights then return end
    -- defensive assignments: only change if provided
    if newRights.white then
        if newRights.white.k ~= nil then castling.white.k = newRights.white.k end
        if newRights.white.q ~= nil then castling.white.q = newRights.white.q end
    end
    if newRights.black then
        if newRights.black.k ~= nil then castling.black.k = newRights.black.k end
        if newRights.black.q ~= nil then castling.black.q = newRights.black.q end
    end
end

-- Replace internal board & castling with exact copies (atomic restore for trials)
function ChessState.RestoreBoard(boardCopy, castlingCopy)
    board = {}
    if boardCopy then
        for k,v in pairs(boardCopy) do
            board[k] = v
        end
    end

    -- default structure then copy provided values
    castling = {
        white = { k = true, q = true },
        black = { k = true, q = true },
    }
    if castlingCopy then
        if castlingCopy.white then
            if castlingCopy.white.k ~= nil then castling.white.k = castlingCopy.white.k end
            if castlingCopy.white.q ~= nil then castling.white.q = castlingCopy.white.q end
        end
        if castlingCopy.black then
            if castlingCopy.black.k ~= nil then castling.black.k = castlingCopy.black.k end
            if castlingCopy.black.q ~= nil then castling.black.q = castlingCopy.black.q end
        end
    end
end

-- Allow explicit setting of castling if needed (keeps backwards compatibility)
function ChessState.SetCastlingRights(newRights)
    if not newRights then return end
    if newRights.white then
        if newRights.white.k ~= nil then castling.white.k = newRights.white.k end
        if newRights.white.q ~= nil then castling.white.q = newRights.white.q end
    end
    if newRights.black then
        if newRights.black.k ~= nil then castling.black.k = newRights.black.k end
        if newRights.black.q ~= nil then castling.black.q = newRights.black.q end
    end
end

-- Initialize on require
ChessState.InitializeFromConstants()

return ChessState
