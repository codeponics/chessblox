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
			if moveInput and moveInput.UserInputType == Enum.UserInputType.MouseMovement then
				local movePos = moveInput.Position
				if self.draggedClone and movePos then
					self.draggedClone.Position = UDim2.new(0, movePos.X, 0, movePos.Y)
				end
			end
		end)

		-- release: InputEnded
		self.upConn = UserInputService.InputEnded:Connect(function(endInput)
			if endInput and endInput.UserInputType == Enum.UserInputType.MouseButton1 then
				local ok, m = pcall(function() return UserInputService:GetMouseLocation() end)
				if ok and m then
					self:endDrag(m.X, m.Y)
				else
					-- fallback: use last known clone position
					if self.draggedClone then
						local absPos = self.draggedClone.AbsolutePosition
						local x = absPos.X + (self.draggedClone.AbsoluteSize.X * 0.5)
						local y = absPos.Y + (self.draggedClone.AbsoluteSize.Y * 0.5)
						self:endDrag(x, y)
					else
						self:endDrag(0,0)
					end
				end
			end
		end)
	end

	-- endDrag (with promotion). Does NOT mutate ChessState.
	function self:endDrag(dropX, dropY)
		if not self.dragging then return end
		self.dragging = false

		-- compute GUI inset (top bar) to convert to screen coordinates used by BoardBuilder
		local guiInset = (function()
			local ok, inset = pcall(function() return GuiService:GetGuiInset() end)
			if ok and typeof(inset) == "Vector2" then return inset end
			return Vector2.new(0,0)
		end)()

		local dropPos = Vector2.new(dropX, dropY) - guiInset
		local targetSquare = nil
		if self.boardRefs and type(self.boardRefs.squareAtScreenPosition) == "function" then
			targetSquare = self.boardRefs.squareAtScreenPosition(dropPos.X, dropPos.Y)
		end

		local fromSquare = self.dragOriginalSquare
		local dragged = self.draggedUI

		-- invalid drop: revert original UI into original cell
		if not targetSquare or not self.boardRefs.cellBySquare[targetSquare] or not dragged then
			if dragged and fromSquare and self.boardRefs.cellBySquare[fromSquare] then
				dragged.Parent = self.boardRefs.cellBySquare[fromSquare]
				dragged.Position = UDim2.new(0.05,0,0.05,0)
				dragged.Size = UDim2.new(0.9,0,0.9,0)
				pcall(function()
					if dragged:IsA("ImageLabel") then dragged.ImageTransparency = 0 else dragged.TextTransparency = 0 end
				end)
			end
			if self.draggedClone and self.draggedClone.Parent then self.draggedClone:Destroy() end
			if self.moveConn then self.moveConn:Disconnect() self.moveConn = nil end
			if self.upConn then self.upConn:Disconnect() self.upConn = nil end
			self.draggedClone = nil
			self.draggedUI = nil
			self.dragOriginalSquare = nil
			return
		end

		-- Client-side validation for UX (server is authoritative)
		local side = nil
		if type(self.sideToMoveProvider) == "function" then side = self.sideToMoveProvider() end
		local boardMap = nil
		if self.chessState and type(self.chessState.GetBoard) == "function" then
			boardMap = self.chessState.GetBoard()
		end
		local allowed, meta = ChessAdapter.validateMove(boardMap or {}, fromSquare, targetSquare, side, self.FILES, (type(self.lastMoveProvider) == "function" and self.lastMoveProvider()) or nil)

		if not allowed then
			-- revert original UI
			if dragged and dragged.Parent then
				dragged.Parent = self.boardRefs.cellBySquare[fromSquare]
				dragged.Position = UDim2.new(0.05,0,0.05,0)
				dragged.Size = UDim2.new(0.9,0,0.9,0)
				pcall(function()
					if dragged:IsA("ImageLabel") then dragged.ImageTransparency = 0 else dragged.TextTransparency = 0 end
				end)
			end
		else
			-- promotion detection (local UX)
			local pieceSymbol = dragged and dragged:GetAttribute("PieceSymbol")
			local isPromotionCandidate = false
			local isWhitePiece = pieceSymbol and (pieceSymbol:upper() == pieceSymbol)
			if pieceSymbol and pieceSymbol:upper() == "P" then
				local toRank = tonumber(targetSquare:sub(2,2))
				if (isWhitePiece and toRank == 8) or (not isWhitePiece and toRank == 1) then
					isPromotionCandidate = true
				end
			end

			-- finalize (optimistic UI) helper
			local function finalizeMoveWithPromotion(promotedSymbol)
				-- Optimistic UI move
				self.pieceManager:movePieceUI(fromSquare, targetSquare)

				-- en-passant visual removal
				if meta and meta.isEnPassant and meta.enPassantCapturedSquare then
					self.pieceManager:clearSquare(meta.enPassantCapturedSquare)
				end

				-- castling rook UI
				if meta and meta.isCastling and meta.rookFrom and meta.rookTo then
					local rookUI = self.pieceManager.pieceUIBySquare[meta.rookFrom]
					if rookUI then
						self.pieceManager:movePieceUI(meta.rookFrom, meta.rookTo)
					end
				end

				-- optimistic promotion asset update
				if promotedSymbol then
					local ui = self.pieceManager.pieceUIBySquare[targetSquare]
					if ui then
						ui:SetAttribute("PieceSymbol", promotedSymbol)
						local asset = (ChessConstants.PIECE_ASSET_BY_SYMBOL and ChessConstants.PIECE_ASSET_BY_SYMBOL[promotedSymbol]) or ""
						pcall(function()
							if ui:IsA("ImageLabel") then
								if asset ~= "" then ui.Image = asset else ui.Image = "" end
							elseif ui:IsA("TextLabel") then
								ui.Text = promotedSymbol
							end
						end)
					end
				end

				-- Inform orchestrator to call server (include promotion if present)
				if type(self.onMoveCallback) == "function" then
					if promotedSymbol then meta.promotion = promotedSymbol end
					pcall(function() self.onMoveCallback(fromSquare, targetSquare, meta) end)
				end
			end

			-- Show promotion UI if needed
			if isPromotionCandidate then
				pcall(function()
					PromotionModule.showPromotion((isWhitePiece and "w" or "b"), self.boardRefs, function(selectedSymbol)
						local chosen = selectedSymbol or (isWhitePiece and "Q" or "q")
						finalizeMoveWithPromotion(chosen)
					end)
				end)
			else
				finalizeMoveWithPromotion(nil)
			end
		end

		-- cleanup clone & listeners
		if self.draggedClone and self.draggedClone.Parent then
			pcall(function() self.draggedClone:Destroy() end)
		end
		self.draggedClone = nil
		if self.moveConn then
			self.moveConn:Disconnect()
			self.moveConn = nil
		end
		if self.upConn then
			self.upConn:Disconnect()
			self.upConn = nil
		end
		if self.draggedUI then
			pcall(function()
				if self.draggedUI:IsA("ImageLabel") then self.draggedUI.ImageTransparency = 0 else self.draggedUI.TextTransparency = 0 end
			end)
		end
		self.draggedUI = nil
		self.dragOriginalSquare = nil
	end

	return self
end

return DragController
