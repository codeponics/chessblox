-- src/client_chess_ui/DragController.luau
-- DragController (ModuleScript) - server-authoritative safe variant
-- This version performs optimistic UI moves but does NOT mutate ChessState.
-- The orchestrator (GenerateBoard.client) is responsible for calling RequestMove and
-- reconciling authoritative state from the server.
local DragController = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClientMods = ReplicatedStorage:WaitForChild("ClientChessUI")
local ChessAdapter = require(ClientMods:WaitForChild("ChessAdapter"))
local SoundManager = require(ClientMods:WaitForChild("SoundManager"))
local PromotionModule = require(ClientMods:WaitForChild("PromotionModule"))
local ChessConstants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChessConstants"))

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local function newInstance(className, props)
	local inst = Instance.new(className)
	if props then
		for k,v in pairs(props) do
			pcall(function() inst[k] = v end)
		end
	end
	return inst
end

-- Constructor:
-- pieceManager: instance of PieceManager
-- boardRefs: board builder returned refs
-- chessStateModule: the ChessState module (we do not mutate it here)
-- files: FILES table
-- sideToMoveProvider: function() => "w" or "b"
-- lastMoveProvider: function() => lastMove table
-- onMoveCallback(from,to,meta) -- orchestrator will call server and reconcile
function DragController.new(pieceManager, boardRefs, chessStateModule, files, sideToMoveProvider, lastMoveProvider, onMoveCallback)
	local self = {}
	self.pieceManager = pieceManager
	self.boardRefs = boardRefs
	self.chessState = chessStateModule
	self.FILES = files
	self.sideToMoveProvider = sideToMoveProvider
	self.lastMoveProvider = lastMoveProvider
	self.onMoveCallback = onMoveCallback
	self.dragging = false
	self.draggedUI = nil
	self.draggedClone = nil
	self.dragOriginalSquare = nil
	self.moveConn = nil
	self.upConn = nil

	-- Attach to existing UIs and future creations (caller uses PieceManager to create pieces)
	function self:attachToPiece(piece)
		if not piece then return end
		-- Note: it's okay to attach multiple times (idempotent from caller side),
		-- but callers should avoid attaching the same piece repeatedly.
		piece.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				self:beginDrag(piece, input)
			end
		end)
	end

	-- beginDrag
	function self:beginDrag(piece, input)
		-- basic guards
		if not piece or self.dragging then return end

		-- Check permission: ensure piece belongs to side to move
		local side = nil
		if type(self.sideToMoveProvider) == "function" then
			side = self.sideToMoveProvider()
		end
		-- Block dragging entirely if the side to move is checkmated
		-- Use ChessState from self.chessState and lastMoveProvider to compute full analysis
		local okAnal, analysis = pcall(function()
			local boardMap = (self.chessState and type(self.chessState.GetBoard) == "function") and self.chessState.GetBoard() or {}
			local lastMv = (type(self.lastMoveProvider) == "function") and self.lastMoveProvider() or nil
			return ChessAdapter.analyzePosition(boardMap, side, self.FILES, lastMv)
		end)
		if okAnal and analysis and analysis.isCheckmate then
			return
		end

		-- existing ownership check (piece belongs to side)
		local sym = piece:GetAttribute("PieceSymbol")
		local isWhite = sym and (sym:upper() == sym)
		if side == "w" and not isWhite then return end
		if side == "b" and isWhite then return end

		self.dragging = true
		self.draggedUI = piece
		self.dragOriginalSquare = piece:GetAttribute("Square")

		-- get a reliable mouse position (input.Position may not exist for some touches)
		local mousePos = Vector2.new(0,0)
		if input and input.Position then
			mousePos = input.Position
		else
			local ok, pos = pcall(function() return UserInputService:GetMouseLocation() end)
			if ok and pos then mousePos = Vector2.new(pos.X, pos.Y) end
		end

		-- create clone for dragging
		self.draggedClone = piece:Clone()
		self.draggedClone.Name = piece.Name .. "_DragClone"
		self.draggedClone.Parent = self.boardRefs.screenGui
		self.draggedClone.ZIndex = 9999
		-- size using absolute pixels, keep it visually consistent
		self.draggedClone.Size = UDim2.new(0, piece.AbsoluteSize.X, 0, piece.AbsoluteSize.Y)
		self.draggedClone.AnchorPoint = Vector2.new(0.5, 0.5)
		self.draggedClone.Position = UDim2.new(0, mousePos.X, 0, mousePos.Y)

		-- dim original
		pcall(function()
			if piece:IsA("ImageLabel") then piece.ImageTransparency = 0.6
			elseif piece:IsA("TextLabel") then piece.TextTransparency = 0.6 end
		end)

		-- movement: InputChanged for mouse movement
		self.moveConn = UserInputService.InputChanged:Connect(function(moveInput)
			if moveInput and (moveInput.UserInputType == Enum.UserInputType.MouseMovement or moveInput.UserInputType == Enum.UserInputType.Touch) then
				local movePos = moveInput.Position
				if self.draggedClone and movePos then
					self.draggedClone.Position = UDim2.new(0, movePos.X, 0, movePos.Y)
				end
			end
		end)

		-- REFACTORED SECTION START
		-- release: InputEnded. This is the only change to beginDrag.
		self.upConn = UserInputService.InputEnded:Connect(function(endInput)
			if endInput and (endInput.UserInputType == Enum.UserInputType.MouseButton1 or endInput.UserInputType == Enum.UserInputType.Touch) then
				-- CRITICAL: Use GetMouseLocation() for the most reliable screen coordinates on drop.
				local success, mousePos = pcall(function() return UserInputService:GetMouseLocation() end)
				if success and mousePos then
					self:endDrag(mousePos.X, mousePos.Y)
				elseif self.draggedClone then
					-- Fallback for rare cases where GetMouseLocation might fail
					local absPos = self.draggedClone.AbsolutePosition
					local absSize = self.draggedClone.AbsoluteSize
					self:endDrag(absPos.X + absSize.X * 0.5, absPos.Y + absSize.Y * 0.5)
				end
			end
		end)
	end

	-- Replace your entire 'endDrag' function with this refactored version:
	function self:endDrag(dropX, dropY)
		if not self.dragging then return end

		-- All state variables are captured before being cleared
		local draggedUI = self.draggedUI
		local fromSquare = self.dragOriginalSquare
		local toSquare = nil

		-- This helper function contains the duplicated cleanup logic.
		-- It's now in one place and called at the end of every code path.
		local function cleanUp()
			if self.draggedClone and self.draggedClone.Parent then self.draggedClone:Destroy() end
			if self.moveConn then self.moveConn:Disconnect() end
			if self.upConn then self.upConn:Disconnect() end
			if draggedUI then
				pcall(function()
					if draggedUI:IsA("ImageLabel") then draggedUI.ImageTransparency = 0
					else draggedUI.TextTransparency = 0 end
				end)
			end
			self.dragging, self.draggedUI, self.draggedClone, self.dragOriginalSquare, self.moveConn, self.upConn = false, nil, nil, nil, nil, nil
		end

		local guiInset = GuiService:GetGuiInset()
		local dropPos = Vector2.new(dropX, dropY) - guiInset
		toSquare = self.boardRefs.squareAtScreenPosition(dropPos.X, dropPos.Y)

		if not toSquare or not fromSquare or not draggedUI then
			if draggedUI then -- Revert UI if the drop was invalid
				draggedUI.Parent = self.boardRefs.cellBySquare[fromSquare]
				draggedUI.Position = UDim2.fromScale(0.05, 0.05)
				draggedUI.Size = UDim2.fromScale(0.9, 0.9)
			end
			cleanUp()
			return
		end

		local side = self.sideToMoveProvider and self.sideToMoveProvider()
		local boardMap = self.chessState and self.chessState.GetBoard and self.chessState.GetBoard() or {}
		local allowed, meta = ChessAdapter.validateMove(boardMap, fromSquare, toSquare, side, self.FILES, self.lastMoveProvider and self.lastMoveProvider())

		if not allowed then
			-- Revert UI for illegal move
			draggedUI.Parent = self.boardRefs.cellBySquare[fromSquare]
			draggedUI.Position = UDim2.fromScale(0.05, 0.05)
			draggedUI.Size = UDim2.fromScale(0.9, 0.9)
		else
			-- Handle promotion and finalize the move
			local pieceSymbol = draggedUI:GetAttribute("PieceSymbol")
			local isWhitePiece = pieceSymbol:upper() == pieceSymbol
			local toRank = tonumber(toSquare:sub(2, 2))
			local isPromotionCandidate = pieceSymbol:upper() == "P" and ((isWhitePiece and toRank == 8) or (not isWhitePiece and toRank == 1))

			local function finalizeMoveWithPromotion(promotedSymbol)
				self.pieceManager:movePieceUI(fromSquare, toSquare)
				if meta and meta.isEnPassant and meta.enPassantCapturedSquare then self.pieceManager:clearSquare(meta.enPassantCapturedSquare) end
				if meta and meta.isCastling and meta.rookFrom and meta.rookTo then self.pieceManager:movePieceUI(meta.rookFrom, meta.rookTo) end
				if promotedSymbol then
					local ui = self.pieceManager.pieceUIBySquare[toSquare]
					if ui then
						ui:SetAttribute("PieceSymbol", promotedSymbol)
						local asset = ChessConstants.PIECE_ASSET_BY_SYMBOL[promotedSymbol]
						if ui:IsA("ImageLabel") and asset then ui.Image = asset
						elseif ui:IsA("TextLabel") then ui.Text = promotedSymbol end
					end
				end
				if self.onMoveCallback then
					if promotedSymbol then meta.promotion = promotedSymbol end
					self.onMoveCallback(fromSquare, toSquare, meta)
				end
			end

			if isPromotionCandidate then
				PromotionModule.showPromotion(isWhitePiece and "w" or "b", self.boardRefs, function(selectedSymbol)
					finalizeMoveWithPromotion(selectedSymbol or (isWhitePiece and "Q" or "q"))
				end)
			else
				finalizeMoveWithPromotion(nil)
			end
		end

		cleanUp()
	end
	-- REFACTORED SECTION END

	return self
end

return DragController
