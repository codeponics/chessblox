local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayTTS = ReplicatedStorage:WaitForChild("PlayTTS")

PlayTTS.OnClientEvent:Connect(function(text, voiceId)
    local parent = workspace  -- or another local container—PlayerGui, Character, etc.

    local tts = Instance.new("AudioTextToSpeech")
    tts.Parent = parent
    tts.Text = text
    tts.VoiceId = voiceId or "1"
    tts.Volume = 1
    tts.Pitch = 1

    local deviceOutput = Instance.new("AudioDeviceOutput", parent)
    local wire = Instance.new("Wire", parent)
    wire.SourceInstance = tts
    wire.TargetInstance = deviceOutput

    tts:Play()
end)
