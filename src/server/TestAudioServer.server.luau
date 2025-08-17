-- In ServerScriptService
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayTTS = Instance.new("RemoteEvent", ReplicatedStorage)
PlayTTS.Name = "PlayTTS"

-- Example: tell only a specific player to speak
game.Players.PlayerAdded:Connect(function(player)
    -- You can customize the message and voiceId as needed
    local text = "Ladies and gentlemen, buckle up! White’s knight lurks like a cat eyeing a goldfish bowl. Black’s king is sunbathing without sunscreen. Now the sacrifice arrives—not a donation, but an investment. The rook leaps off the cliff, dragging the whole position down in glorious chaos!"
    PlayTTS:FireClient(player, text, "1")
end)
