-- CharacterCustomization.luau (LocalScript)
-- Place inside: StarterPlayerScripts
-- Handles character movement customization and running

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local NORMAL_SPEED = 18
local RUN_SPEED = 32

local isRunning = false

local function customizeCharacterMovement(character: Model)
	local humanoid = character:WaitForChild("Humanoid")
	humanoid.WalkSpeed = NORMAL_SPEED
	humanoid.JumpPower = 50
end

local function setRunning(running: boolean)
	if isRunning == running then
		return
	end
	isRunning = running

	local char = player.Character
	if not char then
		return
	end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = running and RUN_SPEED or NORMAL_SPEED
	end
end

-- Initial character setup
if player.Character then
	customizeCharacterMovement(player.Character)
end

player.CharacterAdded:Connect(function(c)
	customizeCharacterMovement(c)
	isRunning = false  -- Reset running state on respawn
end)

-- Listen for Left Shift input
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.LeftShift then
		setRunning(true)
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		setRunning(false)
	end
end)
