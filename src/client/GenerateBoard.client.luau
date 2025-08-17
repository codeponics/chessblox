-- GenerateBoard.client.luau (server-authoritative move flow, match-aware)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local task = task

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClientMods = ReplicatedStorage:WaitForChild("ClientChessUI")

local ChessState = require(Shared:WaitForChild("ChessState"))
local ChessConstants = require(Shared:WaitForChild("ChessConstants"))
local BoardBuilder = require(ClientMods:WaitForChild("BoardBuilder"))
local PieceManager = require(ClientMods:WaitForChild("PieceManager"))
local DragController = require(ClientMods:WaitForChild("DragController"))
local SoundManager = require(ClientMods:WaitForChild("SoundManager"))
local ChessAdapter = require(ClientMods:WaitForChild("ChessAdapter"))

-- Remote objects (must exist)
local RequestMove = ReplicatedStorage:WaitForChild("RequestMove") -- RemoteFunction
local MoveApplied = ReplicatedStorage:WaitForChild("MoveApplied") -- RemoteEvent
local GetOrCreateMatch = ReplicatedStorage:WaitForChild("GetOrCreateMatch") -- RemoteFunction
local JoinMatch = ReplicatedStorage:WaitForChild("JoinMatch") -- RemoteFunction
local LeaveMatch = ReplicatedStorage:WaitForChild("LeaveMatch") -- RemoteFunction

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	warn("GenerateBoard must run as a LocalScript on client.")
	return
end

-- Player-side configuration helper (read attribute from GUI or player)
local function getConfiguredPlayerSide(screenGui)
	local s = nil
	if screenGui then s = screenGui:GetAttribute("PlayerSide") end
	if not s then s = LocalPlayer:GetAttribute("PlayerSide") end
	if s == "w" then return "w" end
	if s == "b" then return "b" end
	return nil
end

-- Build board UI
local FILES = ChessConstants.FILES or {"a","b","c","d","e","f","g","h"}
local boardRefs = BoardBuilder.build(FILES, ChessConstants.LIGHT_COLOR, ChessConstants.DARK_COLOR, {
	BOARD_UI_SCALE = 0.6,
	BOARD_Z_INDEX = 10,
	CELL_Z_INDEX = 20,
	PIECE_Z_INDEX = 30,
})

local screenGui = boardRefs.screenGui
local PLAYER_SIDE = getConfiguredPlayerSide(screenGui) -- "w" or "b" or nil (both)

-- Match-local vars
local myMatchId = nil

-- Turn / bookkeeping
local sideToMove = "w"
local localMovePending = false
local lastMove = nil -- {from=..., to=..., piece=...}

-- Track most recent authoritative payload time to suppress double-play locally
local lastAuthoritativeAt = 0
local AUTHORITATIVE_SUPPRESSION_WINDOW = 0.35 -- seconds to avoid local-sound race

-- Pending local-sound mechanism: schedule local sound with small delay and cancel if authoritative arrives
local pendingLocalSound = nil -- { type = "check"|"checkmate", ts = tick(), timerId = <handle> }

local function scheduleLocalSound(soundType, delaySec)
	-- cancel any existing pending if it's the same or lower priority
	if pendingLocalSound then
		-- if server already gave authoritative recently, skip scheduling
		if tick() - lastAuthoritativeAt < AUTHORITATIVE_SUPPRESSION_WINDOW then
			return
		end
		-- If an existing pending is checkmate, keep it (higher priority)
		if pendingLocalSound.type == "checkmate" and soundType == "check" then
			return
		end
		-- cancel existing
		pendingLocalSound = nil
	end

	local ts = tick()
	pendingLocalSound = { type = soundType, ts = ts }

	-- schedule a delayed playback (will be canceled if authoritative payload arrives in the meantime)
	local handle = task.delay(delaySec or 0.25, function()
		-- only play if still pending and timestamp matches and no authoritative update arrived
		if not pendingLocalSound then return end
		if pendingLocalSound.ts ~= ts then return end
		-- if authoritative recently arrived, skip
		if tick() - lastAuthoritativeAt < AUTHORITATIVE_SUPPRESSION_WINDOW then
			pendingLocalSound = nil
			return
		end
		if pendingLocalSound.type == "checkmate" then
			pcall(function() SoundManager.playCheckmate() end)
		elseif pendingLocalSound.type == "check" then
			pcall(function() SoundManager.playCheck() end)
		end
		pendingLocalSound = nil
	end)

	-- store handle (not strictly required, but useful if we wanted to explicitly cancel)
	pendingLocalSound.timerId = handle
end

local function cancelPendingLocalSound()
	if pendingLocalSound then
		-- There's not a direct cancel handle for task.delay; we clear the pending flag so the callback no-ops
		pendingLocalSound = nil
	end
end

-- Turn label
local turnLabel = Instance.new("TextLabel")
turnLabel.Name = "TurnLabel"
turnLabel.Parent = boardRefs.boardFrame
turnLabel.AnchorPoint = Vector2.new(0.5,0)
turnLabel.Position = UDim2.new(0.5,0,0, -28)
turnLabel.Size = UDim2.new(0, 220, 0, 20)
turnLabel.BackgroundTransparency = 0.5
turnLabel.BackgroundColor3 = Color3.fromRGB(0,0,0)
turnLabel.TextColor3 = Color3.fromRGB(255,255,255)
turnLabel.TextScaled = true
turnLabel.Font = Enum.Font.SourceSansBold
turnLabel.ZIndex = 999
local function updateTurnLabel()
	local you = (PLAYER_SIDE == nil) and "Both" or (PLAYER_SIDE == "w" and "White" or "Black")
	turnLabel.Text = string.format("You: %s   |   To move: %s", you, (sideToMove == "w" and "White" or "Black"))
end
updateTurnLabel()

-- Create PieceManager and populate
local pieceManager = require(ClientMods:WaitForChild("PieceManager")).new(boardRefs, ChessConstants.PIECE_ASSET_BY_SYMBOL, ChessConstants.PIECE_ASSET_BY_SYMBOL.K or "", 30)
pieceManager:populateFromState(ChessState.GetBoard())

-- small helper: attach drag handlers to all current pieces
local function attachDragToAllPieces(dragCtrl)
	for sq, ui in pairs(pieceManager.pieceUIBySquare) do
		-- attach controller's handler
		dragCtrl:attachToPiece(ui)
	end
end

-- side & lastMove providers for DragController
local function sideProvider() return sideToMove end
local function lastMoveProvider() return lastMove end

-- Utility: board signature for change detection
local function boardSignature(board)
	if not board then return "" end
	local parts = {}
	for rank = 8,1,-1 do
		for fi, f in ipairs(FILES) do
			local sq = f .. tostring(rank)
			parts[#parts+1] = tostring(board[sq] or ".")
		end
	end
	return table.concat(parts)
end

-- Reconcile client's ChessState with authoritative board table (pieces only; castling rights handled via payload)
local function reconcileLocalChessStateToBoard(board)
	if not board then return end
	local localBoard = ChessState.GetBoard() or {}

	-- Build set of squares to consider
	local seen = {}
	for sq,_ in pairs(localBoard) do seen[sq] = true end
	for sq,_ in pairs(board) do seen[sq] = true end

	for sq,_ in pairs(seen) do
		local localSym = localBoard[sq]
		local serverSym = board[sq]
		if (localSym == nil or localSym == "") and (serverSym == nil or serverSym == "") then
			-- both empty -> nothing
		elseif serverSym == nil or serverSym == "" then
			-- server says empty -> clear locally
			pcall(function() ChessState.ClearPiece(sq) end)
		elseif localSym == nil or localSym == "" then
			-- server has a piece, local doesn't -> set
			pcall(function() ChessState.SetPiece(sq, serverSym) end)
		elseif localSym ~= serverSym then
			-- different symbol -> set to server value
			pcall(function() ChessState.SetPiece(sq, serverSym) end)
		end
	end
end

-- set castling rights safely if module supports it
local function setLocalCastlingRightsIfPresent(rights)
	if not rights then return end
	if type(ChessState.SetCastlingRights) == "function" then
		pcall(function() ChessState.SetCastlingRights(rights) end)
	end
end

-- Compute last-move via diff (best-effort; reused from original)
local function computeLastMove(prevBoard, newBoard)
	local fromSquares, toSquares = {}, {}
	for _, fileName in ipairs(FILES) do
		for rank = 1,8 do
			local sq = fileName .. tostring(rank)
			local prev = prevBoard[sq]
			local now  = newBoard[sq]
			if prev ~= now then
				if prev ~= nil and (now == nil or now == "") then
					table.insert(fromSquares, {sq = sq, piece = prev})
				elseif (prev == nil or prev == "") and now ~= nil then
					table.insert(toSquares, {sq = sq, piece = now})
				else
					table.insert(fromSquares, {sq = sq, piece = prev})
					table.insert(toSquares, {sq = sq, piece = now})
				end
			end
		end
	end
	if #fromSquares == 1 and #toSquares == 1 then
		return { from = fromSquares[1].sq, to = toSquares[1].sq, piece = toSquares[1].piece }
	end
	return nil
end

-- initial snapshot
local lastBoardSnapshot = ChessState.GetBoard()
local lastBoardSig = boardSignature(lastBoardSnapshot)

-- Ask server for a match (returns existing singleplayer match or creates one)
do
	local ok, resp = pcall(function() return GetOrCreateMatch:InvokeServer() end)
	if ok and resp and resp.success and resp.payload then
		myMatchId = resp.payload.matchId
		-- initialize local state from payload
		local board = resp.payload.board
		if board then
			reconcileLocalChessStateToBoard(board)
			pieceManager:populateFromState(board)
			lastBoardSnapshot = board
			lastBoardSig = boardSignature(board)
		end
		sideToMove = resp.payload.sideToMove or sideToMove
		lastMove = resp.payload.lastMove or lastMove
		-- set castling rights if present
		if resp.payload.castlingRights then
			setLocalCastlingRightsIfPresent(resp.payload.castlingRights)
		end
		lastAuthoritativeAt = tick()
	else
		-- fallback: proceed without matchId (older servers). myMatchId stays nil.
		warn("[GenerateBoard] GetOrCreateMatch failed; proceeding without matchId.")
	end
end

-- If we have a matchId, register as participant to receive updates
if myMatchId then
	pcall(function()
		local ok, resp = pcall(function() return JoinMatch:InvokeServer(myMatchId) end)
		if not ok or not resp or not resp.success then
			warn("[GenerateBoard] JoinMatch failed or was rejected:", resp and resp.reason)
		end
	end)
end

-- cleanup: attempt to leave match when our GUI is removed (best-effort)
do
	local function tryLeave()
		if myMatchId then
			pcall(function() LeaveMatch:InvokeServer(myMatchId) end)
		end
	end
	-- when the GUI is destroyed/removed call LeaveMatch
	boardRefs.screenGui.AncestryChanged:Connect(function()
		if not boardRefs.screenGui.Parent then
			tryLeave()
		end
	end)
end

-- Instantiate DragController
local dragCtrl = DragController.new(pieceManager, boardRefs, ChessState, FILES, sideProvider, lastMoveProvider, nil)
-- we'll provide our own onMoveCallback below (so construct dragCtrl with nil then attach function next)
-- Attach to pieces created during populate
attachDragToAllPieces(dragCtrl)

-- Also attach future pieces automatically: monkey-patch PieceManager.createPieceUI to attach after creation
do
	local origCreate = pieceManager.createPieceUI
	pieceManager.createPieceUI = function(self, ...)
		local ui = origCreate(self, ...)
		-- attach drag behavior
		if ui and dragCtrl then pcall(function() dragCtrl:attachToPiece(ui) end) end
		return ui
	end
end

-- Play sound helper based on meta/analysis returned by server
local function playSoundForMetaOrAnalysis(meta, analysis)
	if analysis and analysis.isCheckmate then
		pcall(function() SoundManager.playCheckmate() end)
		return
	end
	if analysis and analysis.isCheck then
		pcall(function() SoundManager.playCheck() end)
		return
	end
	if meta and meta.isCastling then
		pcall(function() SoundManager.playCastle() end)
	elseif meta and (meta.isCapture or meta.isEnPassant) then
		pcall(function() SoundManager.playCapture() end)
	elseif meta and meta.promotion then
		pcall(function() SoundManager.playPromote() end)
	else
		pcall(function() SoundManager.playMove() end)
	end
end

-- onMoveCallback: called by DragController finalizer when user completes a move (promotion already chosen)
local function onMoveCallback(fromSquare, toSquare, meta)
	-- mark optimistic local pending (DragController already moved UI)
	localMovePending = true

	-- record a tentative lastMove locally so UI shows immediate change; keep old snapshot for possible revert
	local tentativePiece = ChessState.GetPiece(toSquare) or (meta and meta.candidateMove and meta.candidateMove.piece)
	lastMove = { from = fromSquare, to = toSquare, piece = tentativePiece }
	sideToMove = (sideToMove == "w") and "b" or "w"
	updateTurnLabel()

	-- Build request for server. Include promotion and matchId if present.
	local request = { from = fromSquare, to = toSquare }
	if meta and meta.promotion then request.promotion = meta.promotion end
	if myMatchId then request.matchId = myMatchId end

	-- Invoke server synchronously (RemoteFunction). Protect with pcall.
	local ok, resp = pcall(function()
		return RequestMove:InvokeServer(request)
	end)

	-- If RPC failed (timeout/error), revert optimistic UI/state and inform user
	if not ok then
		warn("[GenerateBoard] RequestMove failed (pcall):", tostring(resp))
		-- revert visuals from previous authoritative snapshot
		if lastBoardSnapshot then
			pieceManager:populateFromState(lastBoardSnapshot)
			-- reconcile ChessState to authoritative snapshot
			reconcileLocalChessStateToBoard(lastBoardSnapshot)
			lastMove = nil
			sideToMove = (sideToMove == "w") and "b" or "w" -- flip back because we had flipped earlier
			localMovePending = false
			updateTurnLabel()
		end
		return
	end

	-- If RPC returned non-table
	if not resp or type(resp) ~= "table" then
		warn("[GenerateBoard] RequestMove returned bad response")
		if lastBoardSnapshot then
			pieceManager:populateFromState(lastBoardSnapshot)
			reconcileLocalChessStateToBoard(lastBoardSnapshot)
			lastMove = nil
			sideToMove = (sideToMove == "w") and "b" or "w"
			localMovePending = false
			updateTurnLabel()
		end
		return
	end

	if not resp.success then
		-- Server rejected move: reason in resp.reason (string)
		warn("[GenerateBoard] Move rejected by server:", tostring(resp.reason))
		-- revert optimistic UI/state
		if lastBoardSnapshot then
			pieceManager:populateFromState(lastBoardSnapshot)
			reconcileLocalChessStateToBoard(lastBoardSnapshot)
		end
		lastMove = nil
		sideToMove = (sideToMove == "w") and "b" or "w"
		localMovePending = false
		updateTurnLabel()
		-- Optionally: show brief UI hint to user (not implemented here)
		return
	end

	-- success: use server payload (authoritative)
	local payload = resp.payload
	if payload and payload.board then
		-- reconcile local ChessState to authoritative board
		reconcileLocalChessStateToBoard(payload.board)
		-- refresh visuals from authoritative board (this will also re-attach drag handlers)
		pieceManager:populateFromState(payload.board)
		attachDragToAllPieces(dragCtrl)

		-- update bookkeeping using authoritative values
		lastBoardSnapshot = payload.board
		lastBoardSig = boardSignature(payload.board)
		lastMove = payload.lastMove or lastMove
		sideToMove = payload.sideToMove or sideToMove
		localMovePending = false
		updateTurnLabel()

		-- set castling rights from server if provided
		if payload.castlingRights then
			setLocalCastlingRightsIfPresent(payload.castlingRights)
		end
		-- debug: print server analysis if present
		if payload.analysis then
			print("[GenerateBoard] authoritative analysis received (RequestMove):", "isCheck=", tostring(payload.analysis.isCheck), "isCheckmate=", tostring(payload.analysis.isCheckmate))
		end
		lastAuthoritativeAt = tick()

		-- cancel any pending local sound (authoritative will produce correct audio)
		cancelPendingLocalSound()

		-- play sound based on server-provided meta/analysis (avoid double-play)
		playSoundForMetaOrAnalysis(payload.meta, payload.analysis)
	else
		-- if no board included, fallback to refreshing from ChessState module
		local board = ChessState.GetBoard()
		pieceManager:populateFromState(board)
		lastBoardSnapshot = board
		lastBoardSig = boardSignature(board)
		localMovePending = false
		updateTurnLabel()
		lastAuthoritativeAt = tick()
		cancelPendingLocalSound()
	end
end

-- Give DragController the orchestrator callback (we set it after constructing controller earlier)
dragCtrl.onMoveCallback = onMoveCallback

-- Also attach to pieces created during populate (again) in case pieceManager create replaced earlier
attachDragToAllPieces(dragCtrl)

-- Listen for server broadcasts (authoritative updates from MoveAuthority.Apply)
MoveApplied.OnClientEvent:Connect(function(payload)
	-- payload = { matchId=..., board=..., lastMove=..., meta=..., sideToMove=..., analysis=..., initiator=..., castlingRights=... }
	if not payload or type(payload) ~= "table" then return end

	-- Filter out broadcasts for other matches
	if myMatchId and payload.matchId and payload.matchId ~= myMatchId then
		return
	end

	local board = payload.board
	if not board then return end

	-- determine whether this was our local optimistic move being confirmed
	local wasLocal = localMovePending and payload.lastMove and lastMove and (payload.lastMove.from == lastMove.from and payload.lastMove.to == lastMove.to)

	-- reconcile local ChessState -> authoritative board
	reconcileLocalChessStateToBoard(board)
	-- refresh visuals
	pieceManager:populateFromState(board)
	attachDragToAllPieces(dragCtrl)

	-- set castling rights if present
	if payload.castlingRights then
		setLocalCastlingRightsIfPresent(payload.castlingRights)
	end

	-- debug logging for authoritative payload analysis
	if payload.analysis then
		print("[GenerateBoard] authoritative analysis received (MoveApplied):", "isCheck=", tostring(payload.analysis.isCheck), "isCheckmate=", tostring(payload.analysis.isCheckmate))
	end

	lastAuthoritativeAt = tick()
	-- cancel any pending local playback to avoid double-play or wrong sound
	cancelPendingLocalSound()

	-- consume pending if it was ours (otherwise flip turn)
	if wasLocal then
		localMovePending = false
		-- lastMove already set to authoritative below
	else
		-- external move: flip turn (server already provides sideToMove)
		-- we'll just use server-provided sideToMove
	end

	-- update bookkeeping
	lastBoardSnapshot = board
	lastBoardSig = boardSignature(board)
	lastMove = payload.lastMove or lastMove
	sideToMove = payload.sideToMove or sideToMove
	updateTurnLabel()

	-- Play authoritative sounds / analysis-driven audio
	playSoundForMetaOrAnalysis(payload.meta, payload.analysis)
end)

-- Heartbeat poll for external changes (keeps legacy support & change-detection)
do
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc = acc + dt
		if acc < 0.25 then return end
		acc = 0
		local board = ChessState.GetBoard()
		local sig = boardSignature(board)
		if sig ~= lastBoardSig then
			-- external change happened to client's local chessstate (e.g., from some non-server source)
			-- best-effort: compute last move
			local computed = computeLastMove(lastBoardSnapshot or {}, board)
			if computed then
				lastMove = computed
			end

			local wasLocalPending = localMovePending

			-- refresh visuals from state (client-side)
			pieceManager:populateFromState(board)
			attachDragToAllPieces(dragCtrl)

			if localMovePending then
				-- the change we observed was the local optimistic move being confirmed (consume pending)
				localMovePending = false
				-- turn already flipped locally in onMoveCallback
			else
				-- external move -> flip turn
				sideToMove = (sideToMove == "w") and "b" or "w"
			end

			-- update snapshots and UI
			lastBoardSnapshot = board
			lastBoardSig = sig
			updateTurnLabel()

			-- analyze new position for the side to move and play check/checkmate if present
			-- but skip playing if this was the local optimistic move (to avoid double-play).
			-- Instead of playing immediately, schedule a short delayed local playback so authoritative payloads can override it.
			if not wasLocalPending then
				-- Do not schedule local sound if an authoritative update was very recent
				if tick() - lastAuthoritativeAt < AUTHORITATIVE_SUPPRESSION_WINDOW then
					-- skip: authoritative likely handled the sound
				else
					local analysis = ChessAdapter.analyzePosition(board, sideToMove, FILES, lastMove)
					if analysis and analysis.isCheckmate then
						-- schedule checkmate playback; authoritative can cancel or override
						scheduleLocalSound("checkmate", 0.25)
					elseif analysis and analysis.isCheck then
						scheduleLocalSound("check", 0.25)
					end
				end
			end
		end
	end)
end

-- Attempt to leave match when player leaves the game (best-effort)
do
	-- When this client LocalScript is destroyed, call LeaveMatch if possible
	boardRefs.screenGui:GetPropertyChangedSignal("Parent"):Connect(function()
		if not boardRefs.screenGui.Parent and myMatchId then
			pcall(function() LeaveMatch:InvokeServer(myMatchId) end)
			myMatchId = nil
		end
	end)
end

print("Chess board generated for player:", LocalPlayer.Name, "PlayerSide:", tostring(PLAYER_SIDE), "MatchId:", tostring(myMatchId))
