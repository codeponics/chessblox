-- BoardBuilder (ModuleScript)
local BoardBuilder = {}
BoardBuilder.__index = BoardBuilder

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local playerGui = LocalPlayer:WaitForChild("PlayerGui")

local function newInstance(className, props)
	local inst = Instance.new(className)
	if props then
		for k,v in pairs(props) do
			pcall(function() inst[k] = v end)
		end
	end
	return inst
end

-- configuration defaults (can be overridden by caller if desired)
BoardBuilder.CONFIG = {
	BOARD_UI_SCALE = 0.6,
	BOARD_Z_INDEX = 10,
	CELL_Z_INDEX = 20,
	PIECE_Z_INDEX = 30,
}

function BoardBuilder.build(FILES, LIGHT_COLOR, DARK_COLOR, config)
	config = config or BoardBuilder.CONFIG
	local screenGui = newInstance("ScreenGui", {
		Name = "Chess2D_DragDemo",
		ResetOnSpawn = false,
		Parent = playerGui,
		DisplayOrder = 0,
	})
	local boardFrame = newInstance("Frame", {
		Name = "BoardContainer",
		Parent = screenGui,
		AnchorPoint = Vector2.new(0.5,0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(config.BOARD_UI_SCALE, 0, config.BOARD_UI_SCALE, 0),
		BackgroundTransparency = 1,
		ZIndex = config.BOARD_Z_INDEX,
	})
	newInstance("UIAspectRatioConstraint", {
		Parent = boardFrame,
		AspectRatio = 1,
		DominantAxis = Enum.DominantAxis.Width,
	})

	local cellsFrame = newInstance("Frame", {
		Name = "CellsFrame",
		Parent = boardFrame,
		Size = UDim2.new(1,0,1,0),
		BackgroundTransparency = 1,
		ZIndex = config.CELL_Z_INDEX,
	})
	newInstance("UIGridLayout", {
		Parent = cellsFrame,
		CellSize = UDim2.new(0.125,0,0.125,0),
		CellPadding = UDim2.new(0,0,0,0),
		FillDirection = Enum.FillDirection.Horizontal,
		FillDirectionMaxCells = 8,
		StartCorner = Enum.StartCorner.TopLeft,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	local containers = newInstance("Folder", { Name = "Containers", Parent = screenGui })
	local piecesFolder = newInstance("Folder", { Name = "Pieces", Parent = containers })
	local cellsFolder  = newInstance("Folder", { Name = "Cells", Parent = containers })

	local cellBySquare = {}
	local layoutOrder = 0
	for rank = 8, 1, -1 do
		for file = 1, 8 do
			layoutOrder = layoutOrder + 1
			local squareName = FILES[file] .. tostring(rank)
			local isLight = ((file + rank) % 2 == 0)
			local color = isLight and LIGHT_COLOR or DARK_COLOR

			local cell = newInstance("Frame", {
				Name = "Cell_" .. squareName,
				Parent = cellsFrame,
				BackgroundColor3 = color,
				BackgroundTransparency = 0,
				Size = UDim2.new(1, 0, 1, 0),
				LayoutOrder = layoutOrder,
				ZIndex = config.CELL_Z_INDEX,
			})
			cellBySquare[squareName] = cell
			local meta = newInstance("Frame", {
				Name = squareName,
				Parent = cellsFolder,
				Size = UDim2.new(0,0,0,0),
				Visible = false
			})
			meta:SetAttribute("GridOrder", layoutOrder)
		end
	end

	-- wait for layout helper (small)
	local RunService = game:GetService("RunService")
	local function waitForLayout(timeoutSeconds)
		local sample = next(cellBySquare) and cellBySquare[next(cellBySquare)]
		local timeout = tick() + (timeoutSeconds or 1)
		while tick() < timeout do
			if sample and sample.AbsoluteSize.X > 2 then return true end
			RunService.Heartbeat:Wait()
		end
		return false
	end
	waitForLayout(1.0)

	local function getBoardGeometry()
		local pos = boardFrame.AbsolutePosition
		local size = boardFrame.AbsoluteSize
		local tileSize = size.X / 8
		return {
			left = pos.X,
			top = pos.Y,
			width = size.X,
			height = size.Y,
			tile = tileSize
		}
	end

	local function squareAtScreenPosition(x,y)
		local g = getBoardGeometry()
		if x < g.left or x > g.left + g.width or y < g.top or y > g.top + g.height then
			return nil
		end
		local relX = x - g.left
		local relY = y - g.top
		local fileIndex = math.floor(relX / g.tile) + 1
		local rowIndex = math.floor(relY / g.tile) + 1
		fileIndex = math.clamp(fileIndex, 1, 8)
		rowIndex = math.clamp(rowIndex, 1, 8)
		local file = FILES[fileIndex]
		local rank = 8 - (rowIndex - 1)
		return file .. tostring(rank)
	end

	return {
		screenGui = screenGui,
		boardFrame = boardFrame,
		cellsFrame = cellsFrame,
		piecesFolder = piecesFolder,
		cellsFolder = cellsFolder,
		cellBySquare = cellBySquare,
		getBoardGeometry = getBoardGeometry,
		squareAtScreenPosition = squareAtScreenPosition,
	}
end

return BoardBuilder
