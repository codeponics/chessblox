-- LocalScript (place this LocalScript inside StarterGui)
-- Creates a ScreenGui with an 8x8 chessboard using the provided asset IDs.
-- Pieces are created as ImageLabels (using the provided king asset temporarily for all pieces).

-- Docs referenced when writing this:
-- ImageLabel/Image property accepts "rbxassetid://<id>" (Roblox docs). :contentReference[oaicite:1]{index=1}
-- UIGridLayout usage & properties (CellSize, CellPadding, StartCorner, SortOrder). :contentReference[oaicite:2]{index=2}
-- Prefer PlayerGui access via Players.LocalPlayer:WaitForChild("PlayerGui") in LocalScripts. :contentReference[oaicite:3]{index=3}

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
assert(LocalPlayer, "This LocalScript must run in a player's client environment.")

local playerGui = LocalPlayer:WaitForChild("PlayerGui")

-- ========== CONFIG: image asset ids (temporary) ==========
local PIECE_IMAGE_ASSET_ID = "rbxassetid://12414181624"      -- white king asset (user provided) used for all pieces temporarily
local BOARD_BG_ASSET_ID    = "rbxassetid://106424991909153" -- chess board background texture (user provided)

-- Visual tuning
local BOARD_UI_SCALE = 0.6         -- fraction of screen (width and height) to use for the board
local BOARD_Z_INDEX = 10
local PIECE_Z_INDEX = 20
local CELL_Z_INDEX  = 15

-- Helper: file letters
local FILES = {"a","b","c","d","e","f","g","h"}

-- Starting piece layout (for positioning only; we're using same image for every piece for now)
-- White is at ranks 1 (major pieces) and 2 (pawns); black at ranks 8 and 7.
local STARTING_RANKS = {
	white = {
		[1] = {"R","N","B","Q","K","B","N","R"},
		[2] = {"P","P","P","P","P","P","P","P"},
	},
	black = {
		[8] = {"r","n","b","q","k","b","n","r"},
		[7] = {"p","p","p","p","p","p","p","p"},
	}
}

-- Utility: create instance with properties
local function newInstance(className, props)
	local inst = Instance.new(className)
	if props then
		for k,v in pairs(props) do
			pcall(function() inst[k] = v end)
		end
	end
	return inst
end

-- Build ScreenGui and structure
local screenGui = newInstance("ScreenGui", {
	Name = "Chess2DSimple",
	ResetOnSpawn = false, -- keep between respawns if desired
	DisplayOrder = 0,
	Parent = playerGui,
})

-- Main board container (centered)
local boardFrame = newInstance("Frame", {
	Name = "BoardContainer",
	Parent = screenGui,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = UDim2.new(BOARD_UI_SCALE, 0, BOARD_UI_SCALE, 0),
	BackgroundTransparency = 1,
	ZIndex = BOARD_Z_INDEX,
})

-- Keep board square (1:1) regardless of screen aspect
local aspect = newInstance("UIAspectRatioConstraint", {
	Parent = boardFrame,
	AspectRatio = 1,
	AspectType = Enum.AspectType.XY,
	DominantAxis = Enum.DominantAxis.Height,
})

-- Background image (board texture) - distinct from pieces
local background = newInstance("ImageLabel", {
	Name = "BoardBackground",
	Parent = boardFrame,
	Size = UDim2.new(1, 0, 1, 0),
	Position = UDim2.new(0, 0, 0, 0),
	BackgroundTransparency = 1,
	Image = BOARD_BG_ASSET_ID,
	ScaleType = Enum.ScaleType.Fit,
	ZIndex = BOARD_Z_INDEX,
	-- optionally tint or change Transparency
	BackgroundColor3 = Color3.fromRGB(255,255,255),
})

-- Container to hold the 64 cell frames laid out by a UIGridLayout.
local cellsFrame = newInstance("Frame", {
	Name = "CellsFrame",
	Parent = boardFrame,
	Size = UDim2.new(1, 0, 1, 0),
	Position = UDim2.new(0, 0, 0, 0),
	BackgroundTransparency = 1,
	ZIndex = CELL_Z_INDEX,
})

-- UIGridLayout: configure for 8x8 cells
local grid = newInstance("UIGridLayout", {
	Parent = cellsFrame,
	CellSize = UDim2.new(0.125, 0, 0.125, 0),      -- 1/8 by 1/8
	CellPadding = UDim2.new(0, 0, 0, 0),
	FillDirection = Enum.FillDirection.Horizontal,
	FillDirectionMaxCells = 8,                     -- wrap after 8 cells
	StartCorner = Enum.StartCorner.TopLeft,
	SortOrder = Enum.SortOrder.LayoutOrder,
})

-- Folders for organization
local containers = newInstance("Folder", { Name = "Containers", Parent = screenGui })
local piecesFolder = newInstance("Folder", { Name = "Pieces", Parent = containers })
local cellsFolder  = newInstance("Folder", { Name = "Cells", Parent = containers })

-- Generate 64 cell frames in the correct visual order:
-- We want top-left = a8, then left-to-right across rank 8, then rank7, ... down to rank1 bottom.
-- UIGridLayout will place children in order of LayoutOrder; we'll set that accordingly.
local layoutOrder = 0
local cellBySquare = {}  -- map "a8" -> Frame for easy piece parent lookup

for rank = 8, 1, -1 do            -- 8 down to 1 (top to bottom)
	for file = 1, 8 do             -- a .. h (left to right)
		layoutOrder = layoutOrder + 1
		local squareName = FILES[file] .. tostring(rank)

		-- create cell frame
		local cell = newInstance("Frame", {
			Name = "Cell_" .. squareName,
			Parent = cellsFrame,
			BackgroundTransparency = 1,   -- keep transparent so board BG shows through
			Size = UDim2.new(1,0,1,0),
			LayoutOrder = layoutOrder,
			ZIndex = CELL_Z_INDEX,
		})

		-- Optional: add a transparent clickable ImageButton or overlay if you want click handling
		-- We'll add a small invisible TextButton to receive click events (can be changed later)
		local clickTouch = newInstance("TextButton", {
			Name = "ClickArea",
			Parent = cell,
			Size = UDim2.new(1, 0, 1, 0),
			Position = UDim2.new(0,0,0,0),
			BackgroundTransparency = 1,
			Text = "",
			ZIndex = CELL_Z_INDEX + 1,
		})

		-- Store reference
		cellBySquare[squareName] = cell
		-- also keep inside Cells folder (optional organization)
		local cloneForFolder = newInstance("Frame", {
			Name = squareName,
			Parent = cellsFolder,
			Size = UDim2.new(0,0,0,0), -- not used visually
			Visible = false,
		})
		cloneForFolder:SetAttribute("GridOrder", layoutOrder)
	end
end

-- Helper: create a piece ImageLabel and parent to a given cell frame
local function createPieceAt(squareName, pieceSymbol)
	-- pieceSymbol is for naming only (e.g. "P", "K", "p", "k")
	local parentCell = cellBySquare[squareName]
	if not parentCell then
		warn("Invalid square: ".. tostring(squareName))
		return nil
	end

	local piece = newInstance("ImageLabel", {
		Name = "Piece_" .. squareName .. "_" .. tostring(pieceSymbol),
		Parent = parentCell,
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
		Image = PIECE_IMAGE_ASSET_ID,
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = PIECE_Z_INDEX,
	})
	-- Use an attribute if you want to later know what piece it is
	piece:SetAttribute("PieceSymbol", pieceSymbol)
	return piece
end

-- Place starting pieces using STARTING_RANKS mapping
-- Black (top)
for rank, row in pairs(STARTING_RANKS.black) do
	for file = 1, #row do
		local sym = row[file]
		local sq = FILES[file] .. tostring(rank)
		createPieceAt(sq, sym)
	end
end

-- White (bottom)
for rank, row in pairs(STARTING_RANKS.white) do
	for file = 1, #row do
		local sym = row[file]
		local sq = FILES[file] .. tostring(rank)
		createPieceAt(sq, sym)
	end
end

-- Optional: expose the GUI root for debugging / future access
screenGui:SetAttribute("GeneratedBy", "Sunfish2D_Generator_LocScript")
print("Chess board GUI generated for player:", LocalPlayer.Name)
