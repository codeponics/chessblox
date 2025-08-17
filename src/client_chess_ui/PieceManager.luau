-- PieceManager (ModuleScript) - diff + animated moves
local PieceManager = {}
PieceManager.__index = PieceManager

local replicated = game:GetService("ReplicatedStorage")
local ClientMods = replicated:WaitForChild("ClientChessUI")
local TweenService = game:GetService("TweenService")
local BoardBuilder = require(ClientMods:WaitForChild("BoardBuilder"))

-- Caller must pass in boardRefs returned by BoardBuilder.build(...)
-- animateMoves: optional boolean (default true). durationSeconds: optional number for tween len (default 0.18)
function PieceManager.new(boardRefs, piecesAssetMap, defaultAsset, pieceZIndex, animateMoves, durationSeconds)
	local self = setmetatable({}, PieceManager)
	self.board = boardRefs
	self.pieceAssetMap = piecesAssetMap or {}
	self.defaultAsset = defaultAsset or ""
	self.pieceZIndex = pieceZIndex or 30
	self.pieceUIBySquare = {}
	self.refByUI = setmetatable({}, {__mode="k"})
	self.animateMoves = (animateMoves == nil) and true or (not not animateMoves)
	self.moveDuration = durationSeconds or 0.18
	return self
end

local function newInstance(className, props)
	local inst = Instance.new(className)
	if props then
		for k,v in pairs(props) do
			pcall(function() inst[k] = v end)
		end
	end
	return inst
end

-- Create UI element for a pieceSymbol at square
function PieceManager:createPieceUI(squareName, pieceSymbol)
	local parentCell = self.board.cellBySquare[squareName]
	if not parentCell then return nil end

	local asset = self.pieceAssetMap[pieceSymbol] or self.defaultAsset
	local piece
	if asset and asset ~= "" then
		piece = newInstance("ImageLabel", {
			Name = "Piece_" .. squareName .. "_" .. tostring(pieceSymbol),
			Parent = parentCell,
			Size = UDim2.new(0.9,0,0.9,0),
			Position = UDim2.new(0.05,0,0.05,0),
			BackgroundTransparency = 1,
			Image = asset,
			ScaleType = Enum.ScaleType.Fit,
			ZIndex = self.pieceZIndex,
			Visible = true,
			Active = true,
		})
	else
		piece = newInstance("TextLabel", {
			Name = "Piece_" .. squareName .. "_" .. tostring(pieceSymbol),
			Parent = parentCell,
			Size = UDim2.new(0.95,0,0.95,0),
			Position = UDim2.new(0.025,0,0.025,0),
			BackgroundTransparency = 1,
			Text = pieceSymbol,
			TextScaled = true,
			Font = Enum.Font.SourceSansBold,
			TextColor3 = (pieceSymbol:upper() == pieceSymbol) and Color3.fromRGB(255,255,255) or Color3.fromRGB(0,0,0),
			ZIndex = self.pieceZIndex,
			Active = true,
		})
	end

	piece:SetAttribute("PieceSymbol", pieceSymbol)
	piece:SetAttribute("Square", squareName)

	local ref = newInstance("ObjectValue", {
		Name = squareName,
		Parent = self.board.piecesFolder,
	})
	pcall(function() ref.Value = piece end)
	self.refByUI[piece] = ref

	self.pieceUIBySquare[squareName] = piece
	return piece
end

-- Clear a square's visual (destroy UI & ObjectValue)
function PieceManager:clearSquare(square)
	local existing = self.pieceUIBySquare[square]
	if existing then
		local ref = self.refByUI[existing]
		if ref and ref.Parent then ref:Destroy() end
		self.refByUI[existing] = nil
		if existing.Parent then existing:Destroy() end
		self.pieceUIBySquare[square] = nil
	end
end

-- Low-level: immediately reparent UI to target cell and update bookkeeping.
-- Used after animation completes (or directly when no animation).
function PieceManager:finalizeMoveUI(ui, fromSquare, toSquare, newSymbol)
	-- clear target if present
	if self.pieceUIBySquare[toSquare] and self.pieceUIBySquare[toSquare] ~= ui then
		local ex = self.pieceUIBySquare[toSquare]
		local ref = self.refByUI[ex]
		if ref and ref.Parent then ref:Destroy() end
		self.refByUI[ex] = nil
		if ex.Parent then ex:Destroy() end
		self.pieceUIBySquare[toSquare] = nil
	end

	-- reparent original UI into the target cell
	ui.Parent = self.board.cellBySquare[toSquare]
	ui.Position = UDim2.new(0.05,0,0.05,0)
	ui.Size = UDim2.new(0.9,0,0.9,0)
	ui:SetAttribute("Square", toSquare)

	-- update asset if symbol changed (promotion)
	if newSymbol then
		ui:SetAttribute("PieceSymbol", newSymbol)
		local asset = (self.pieceAssetMap and self.pieceAssetMap[newSymbol]) or ""
		pcall(function()
			if ui:IsA("ImageLabel") then
				if asset ~= "" then
					ui.Image = asset
				else
					ui.Image = ""
				end
			elseif ui:IsA("TextLabel") then
				ui.Text = newSymbol
			end
		end)
	end

	-- bookkeeping
	self.pieceUIBySquare[toSquare] = ui
	self.pieceUIBySquare[fromSquare] = nil

	local ref = self.refByUI[ui]
	if ref and ref.Parent then
		ref.Name = toSquare
	else
		local newRef = Instance.new("ObjectValue")
		newRef.Name = toSquare
		newRef.Parent = self.board.piecesFolder
		pcall(function() newRef.Value = ui end)
		self.refByUI[ui] = newRef
	end

	return ui
end

-- Smooth animation helper: clone UI to screenGui, tween, then finalize original in new cell.
function PieceManager:animateMoveUI(ui, fromSquare, toSquare, newSymbol)
	-- only animate if toggled and geometry available
	if not self.animateMoves then
		return self:finalizeMoveUI(ui, fromSquare, toSquare, newSymbol)
	end

	local fromCell = self.board.cellBySquare[fromSquare]
	local toCell = self.board.cellBySquare[toSquare]
	if not fromCell or not toCell then
		return self:finalizeMoveUI(ui, fromSquare, toSquare, newSymbol)
	end

	-- ensure layout has sizes
	if fromCell.AbsoluteSize.X < 4 or toCell.AbsoluteSize.X < 4 then
		return self:finalizeMoveUI(ui, fromSquare, toSquare, newSymbol)
	end

	-- compute centers
	local fromCenter = Vector2.new(fromCell.AbsolutePosition.X + fromCell.AbsoluteSize.X*0.5,
								   fromCell.AbsolutePosition.Y + fromCell.AbsoluteSize.Y*0.5)
	local toCenter   = Vector2.new(toCell.AbsolutePosition.X + toCell.AbsoluteSize.X*0.5,
								   toCell.AbsolutePosition.Y + toCell.AbsoluteSize.Y*0.5)

	-- clone for animation
	local clone = ui:Clone()
	clone.Name = ui.Name .. "_Anim"
	clone.Parent = self.board.screenGui
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	-- size based on absolute pixels
	clone.Size = UDim2.new(0, ui.AbsoluteSize.X, 0, ui.AbsoluteSize.Y)
	clone.Position = UDim2.new(0, fromCenter.X, 0, fromCenter.Y)
	clone.ZIndex = (ui.ZIndex or self.pieceZIndex) + 100
	-- hide original while animating
	pcall(function() ui.Visible = false end)

	-- tween
	local tweenInfo = TweenInfo.new(self.moveDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local ok, tween = pcall(function()
		return TweenService:Create(clone, tweenInfo, { Position = UDim2.new(0, toCenter.X, 0, toCenter.Y) })
	end)
	if not ok or not tween then
		-- fallback
		if clone and clone.Parent then clone:Destroy() end
		pcall(function() ui.Visible = true end)
		return self:finalizeMoveUI(ui, fromSquare, toSquare, newSymbol)
	end

	tween:Play()
	tween.Completed:Connect(function()
		-- cleanup clone and finalize
		if clone and clone.Parent then clone:Destroy() end
		pcall(function() ui.Visible = true end)
		self:finalizeMoveUI(ui, fromSquare, toSquare, newSymbol)
	end)
    return
end

-- Public API: move UI immediately (no animation)
function PieceManager:movePieceUI(fromSquare, toSquare)
	local ui = self.pieceUIBySquare[fromSquare]
	if not ui then return nil end
	return self:finalizeMoveUI(ui, fromSquare, toSquare, nil)
end

-- Populate using a diff algorithm with reuse + animation
function PieceManager:populateFromState(boardMap)
	-- Build lists of existing UI and target squares
	local existing = {}
	for sq, ui in pairs(self.pieceUIBySquare) do
		local sym = ui:GetAttribute("PieceSymbol")
		existing[#existing + 1] = { square = sq, ui = ui, sym = sym, used = false }
	end

	local targets = {}
	for sq, sym in pairs(boardMap) do
		if sym and sym ~= "" then
			targets[#targets + 1] = { square = sq, sym = sym, matched = false }
		end
	end

	-- Helper: square -> coords (file index 1..8, rank 1..8)
	local function squareToCoords(sq)
		local file = sq:sub(1,1)
		local rank = tonumber(sq:sub(2,2)) or 0
		local fileIdx = (string.byte(file) - string.byte('a')) + 1
		return fileIdx, rank
	end
	local function manhattanDist(a,b)
		return math.abs(a.x - b.x) + math.abs(a.y - b.y)
	end

	-- Build quick lookup of existing by square for fast same-square checks
	local existingBySquare = {}
	for _,e in ipairs(existing) do existingBySquare[e.square] = e end

	-- 1) Fast pass: keep UI already correct on same square with same symbol
	for _,t in ipairs(targets) do
		local e = existingBySquare[t.square]
		if e and e.sym == t.sym then
			t.matched = true
			e.used = true
			-- keep mapping (no op)
		end
	end

	-- 2) Try to match targets to nearest existing UI with same symbol
	for _,t in ipairs(targets) do
		if not t.matched then
			-- collect candidate existing unused with same symbol
			local best, bestIdx, bestDist = nil, nil, math.huge
			local tx, tr = squareToCoords(t.square)
			local targPos = { x = tx, y = tr }
			for idx,e in ipairs(existing) do
				if (not e.used) and e.sym == t.sym then
					local ex, er = squareToCoords(e.square)
					local d = manhattanDist({x=ex,y=er}, targPos)
					if d < bestDist then best = e; bestIdx = idx; bestDist = d end
				end
			end
			if best then
				-- move UI (animate)
				best.used = true
				t.matched = true
				-- perform animated move
				self:animateMoveUI(best.ui, best.square, t.square, nil)
			end
		end
	end

	-- 3) For remaining unmatched targets, match nearest ANY unused existing UI (fallback)
	for _,t in ipairs(targets) do
		if not t.matched then
			local best, bestIdx, bestDist = nil, nil, math.huge
			local tx, tr = squareToCoords(t.square)
			local targPos = { x = tx, y = tr }
			for idx,e in ipairs(existing) do
				if (not e.used) then
					local ex, er = squareToCoords(e.square)
					local d = manhattanDist({x=ex,y=er}, targPos)
					if d < bestDist then best = e; bestIdx = idx; bestDist = d end
				end
			end
			if best then
				best.used = true
				t.matched = true
				-- if symbol differs, we pass the new symbol so finalizeMoveUI updates asset/text
				self:animateMoveUI(best.ui, best.square, t.square, t.sym ~= best.sym and t.sym or nil)
			end
		end
	end

	-- 4) Any targets still unmatched => create new UI
	for _,t in ipairs(targets) do
		if not t.matched then
			self:createPieceUI(t.square, t.sym)
			t.matched = true
		end
	end

	-- 5) Any existing UI that was not used => remove (captured / disappeared)
	for _,e in ipairs(existing) do
		if not e.used then
			-- double-check boardMap doesn't now contain same UI (race condition)
			if boardMap[e.square] == nil or boardMap[e.square] == "" then
				-- remove
				self:clearSquare(e.square)
			else
				-- This can happen if we didn't match but the square is still occupied by some piece.
				-- Best-effort: if symbol mismatches, update UI symbol/asset in-place.
				local desired = boardMap[e.square]
				if desired and desired ~= "" and desired ~= e.sym then
					local ui = e.ui
					ui:SetAttribute("PieceSymbol", desired)
					local asset = (self.pieceAssetMap and self.pieceAssetMap[desired]) or ""
					pcall(function()
						if ui:IsA("ImageLabel") then
							if asset ~= "" then ui.Image = asset else ui.Image = "" end
						elseif ui:IsA("TextLabel") then
							ui.Text = desired
						end
					end)
				end
			end
		end
	end
end

return PieceManager
