-- PromotionModule (ModuleScript)
local Promotion = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChessConstants = require(Shared:WaitForChild("ChessConstants"))

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

-- showPromotion(side, boardRefs, callback)
-- side: "w" or "b" (color of pawn being promoted)
-- boardRefs: return value of BoardBuilder.build(...) (used to parent UI)
-- callback(symbol) -> called with promoted piece symbol (e.g. "Q" or "q")
function Promotion.showPromotion(side, boardRefs, callback)
	local parentGui = boardRefs and boardRefs.screenGui or playerGui

	-- backdrop: full-screen invisible button to detect clicks outside the overlay
	local backdrop = newInstance("TextButton", {
		Name = "PromotionBackdrop",
		Parent = parentGui,
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 9998, -- behind overlay but above board
	})

	-- overlay container (on top of backdrop)
	local overlay = newInstance("Frame", {
		Name = "PromotionOverlay",
		Parent = parentGui,
		AnchorPoint = Vector2.new(0.5,0.5),
		Position = UDim2.new(0.5, 0.5, 0.5, 0), -- center
		Size = UDim2.new(0, 240, 0, 60),
		BackgroundTransparency = 0.2,
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		ZIndex = 9999,
	})
	newInstance("UICorner", { Parent = overlay, CornerRadius = UDim.new(0,6) })

	-- choices (Q,R,B,N) with assets from ChessConstants
	local choices = {}
	if side == "w" then
		choices = {"Q","R","B","N"}
	else
		choices = {"q","r","b","n"}
	end

	local padding = 6
	local btnSize = 56

	-- store connections so we can clean them up reliably
	local btnConns = {}
	local backConn

	-- helper to cleanup UI and disconnect handlers
	local function cleanup()
		-- disconnect btn connections
		for _, conn in ipairs(btnConns) do
			if conn and conn.Disconnect then
				pcall(function() conn:Disconnect() end)
			end
		end
		btnConns = {}

		-- disconnect backdrop conn
		if backConn and backConn.Disconnect then
			pcall(function() backConn:Disconnect() end)
			backConn = nil
		end

		-- destroy UI elements
		if overlay and overlay.Parent then
			pcall(function() overlay:Destroy() end)
		end
		if backdrop and backdrop.Parent then
			pcall(function() backdrop:Destroy() end)
		end
	end

	for i, symbol in ipairs(choices) do
		local asset = (ChessConstants.PIECE_ASSET_BY_SYMBOL and ChessConstants.PIECE_ASSET_BY_SYMBOL[symbol]) or ""
		local btn = newInstance("ImageButton", {
			Name = "Promo_" .. symbol,
			Parent = overlay,
			Size = UDim2.new(0, btnSize, 0, btnSize),
			Position = UDim2.new(0, padding + (i-1)*(btnSize + padding), 0, padding),
			BackgroundTransparency = 0,
			BackgroundColor3 = Color3.fromRGB(230,230,230),
			Image = asset,
			ScaleType = Enum.ScaleType.Fit,
			ZIndex = overlay.ZIndex + 1,
		})
		newInstance("UICorner", { Parent = btn, CornerRadius = UDim.new(0,6) })

		local conn = btn.Activated:Connect(function()
			-- callback with chosen symbol, then cleanup
			local ok, err = pcall(function()
				if type(callback) == "function" then callback(symbol) end
			end)
			-- ensure cleanup regardless of callback outcome
			cleanup()
		end)
		table.insert(btnConns, conn)
	end

	-- clicking the backdrop defaults to queen (common UX)
	backConn = backdrop.Activated:Connect(function()
		-- default choice
		local default = (side == "w") and "Q" or "q"
		pcall(function()
			if type(callback) == "function" then callback(default) end
		end)
		cleanup()
	end)
end

return Promotion
