-- SoundManager (PlaybackRegion-enabled, pooled & preloaded)
local SoundManager = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	warn("SoundManager: must run in LocalScript context")
	return SoundManager
end
local playerGui = LocalPlayer:WaitForChild("PlayerGui")

-- CONFIG: bundled asset + region map (seconds)
local BUNDLED_ASSET = "rbxassetid://7032661792"

local REGIONS = {
    move    = { start = 3.90, stop = 4.00, volume = 0.8 },
    capture = { start = 7.90, stop = 8.00, volume = 0.8 },
    castle  = { start = 5.80, stop = 6.00, volume = 0.8 },
    promote = { start = 3.90, stop = 4.00, volume = 0.8 },

    check   = { start = 9.80, stop = 10.00, volume = 0.9 },
    checkmate= { start = 13.8, stop = 14.20, volume = 1.0 },
}

local DEFAULT_VOLUME = 0.7

-- Pool config: how many concurrent sounds we allow without allocating
local POOL_SIZE = 6

-- internal pool
local pool = {}
local nextIndex = 1 -- round-robin fallback index

-- helper to create a single pooled Sound
local function makePooledSound(i)
	local s = Instance.new("Sound")
	s.Name = "BundledAudio_Pool_" .. tostring(i)
	s.SoundId = BUNDLED_ASSET
	s.Looped = false
	pcall(function() s.PlaybackRegionsEnabled = true end)
	s.Parent = playerGui
	return {
		sound = s,
		busy = false,
		endedConn = nil,
	}
end

-- initialize pool (created once)
local function initPool()
	for i = 1, POOL_SIZE do
		pool[i] = makePooledSound(i)
	end

	-- Preload the pooled Sound instances so they're cached
	local instances = {}
	for i = 1, POOL_SIZE do
		instances[i] = pool[i].sound
	end

	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(instances)
		end)
		if not ok then
			warn("SoundManager: PreloadAsync failed:", err)
		end
	end)
end

initPool()

-- internal helper: find an available sound in the pool
local function acquirePooledSound()
	-- first try to find non-busy
	for i = 1, POOL_SIZE do
		if not pool[i].busy then
			return pool[i], i
		end
	end
	-- none free: pick nextIndex in round-robin and reuse it (force-stop)
	local idx = nextIndex
	nextIndex = (nextIndex % POOL_SIZE) + 1
	local ent = pool[idx]
	-- stop it immediately if playing
	pcall(function()
		ent.sound:Stop()
	end)
	-- mark as available and return
	ent.busy = false
	if ent.endedConn then
		pcall(function() ent.endedConn:Disconnect() end)
		ent.endedConn = nil
	end
	return ent, idx
end

-- internal helper: play a region using pooled sounds
function SoundManager._playRegion(regionName, opts)
	opts = opts or {}
	local region = REGIONS[regionName]
	if not region then
		warn("SoundManager: unknown region:", regionName)
		return
	end

	local startSec = region.start or 0
	local stopSec  = region.stop or startSec
	local vol = opts.Volume or region.volume or DEFAULT_VOLUME
	local length = math.max(0, stopSec - startSec)
	local buffer = 0.06 -- safety buffer to ensure stop

	local ent, idx = acquirePooledSound()
	local s = ent.sound
	ent.busy = true

	-- disconnect prior Ended connection if any
	if ent.endedConn then
		pcall(function() ent.endedConn:Disconnect() end)
		ent.endedConn = nil
	end

	-- connect Ended to mark free
	ent.endedConn = s.Ended:Connect(function()
		ent.busy = false
		if ent.endedConn then
			pcall(function() ent.endedConn:Disconnect() end)
			ent.endedConn = nil
		end
	end)

	-- defensively set PlaybackRegion/TimePosition/Volume
	pcall(function() s.PlaybackRegion = NumberRange.new(startSec, stopSec) end)
	pcall(function() s.TimePosition = startSec end)
	pcall(function() s.Volume = vol end)

	-- play and defensively schedule stop, marking available
	local ok, err = pcall(function() s:Play() end)
	if not ok then
		warn("SoundManager: Play failed:", err)
		-- mark free immediately
		ent.busy = false
		if ent.endedConn then
			pcall(function() ent.endedConn:Disconnect() end)
			ent.endedConn = nil
		end
		return
	end

	-- fallback stopper in case PlaybackRegion doesn't auto-stop
	if length > 0 then
		task.delay(length + buffer, function()
			-- only stop if still busy (we may already have Ended)
			if ent.busy then
				pcall(function() s:Stop() end)
				ent.busy = false
				if ent.endedConn then
					pcall(function() ent.endedConn:Disconnect() end)
					ent.endedConn = nil
				end
			end
		end)
	end

	return s
end

-- Public API wrappers
function SoundManager.playMove()
	SoundManager._playRegion("move")
end

function SoundManager.playCapture()
	SoundManager._playRegion("capture")
end

function SoundManager.playCastle()
	SoundManager._playRegion("castle")
end

function SoundManager.playPromote()
	SoundManager._playRegion("promote")
end

function SoundManager.playCheck()
    SoundManager._playRegion("check")
end

function SoundManager.playCheckmate()
    SoundManager._playRegion("checkmate")
end

function SoundManager.play(name, opts)
	return SoundManager._playRegion(name, opts)
end

function SoundManager.setRegion(name, startSec, stopSec, volume)
	REGIONS[name] = { start = startSec, stop = stopSec, volume = volume }
end

-- Optional: expose a preload function to explicitly wait for loading at a controlled time
function SoundManager.preloadNow(timeout)
	timeout = timeout or 10
	local instances = {}
	for i = 1, POOL_SIZE do
		instances[i] = pool[i].sound
	end
	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(instances)
	end)
	if not ok then
		warn("SoundManager.preloadNow failed:", err)
	end
end

return SoundManager
