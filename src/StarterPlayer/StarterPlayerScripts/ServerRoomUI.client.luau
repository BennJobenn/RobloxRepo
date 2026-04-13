-- ServerRoomUI.luau (LocalScript)
-- Place inside: StarterPlayerScripts
-- Handles server room UI interactions and updates

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player.PlayerGui

-- UI References
local lobbyGui: ScreenGui?
local shiftFrame: Frame? -- The frame itself, not the label
local shiftLabel: TextLabel?
local moneyLabel: TextLabel?
local settingBtn: TextButton?
local shopBtn: TextButton?

-- Money tracking
local currentMoney = 0
local inGameRoom = false -- Track if we're in a game room

-- Get remote events for room enter/leave
local remotesFolder = ReplicatedStorage:WaitForChild("TableGameRemotes")
local roomReadyEvent = remotesFolder:WaitForChild("RoomReady")
local leaveRoomEvent = remotesFolder:WaitForChild("LeaveRoom")

-- Find UI elements (or create if doesn't exist)
local function findUIElements()
	-- Try to find existing LobbyUI first
	lobbyGui = playerGui:FindFirstChild("LobbyUI")

	if not lobbyGui then
		-- Clone from ReplicatedStorage
		local template = ReplicatedStorage:FindFirstChild("LobbyUI")
		if template then
			lobbyGui = template:Clone()
			lobbyGui.Parent = playerGui
			print("[ServerRoomUI] Cloned LobbyUI from ReplicatedStorage")
		else
			warn("[ServerRoomUI] LobbyUI template not found in ReplicatedStorage")
			return
		end
	else
		print("[ServerRoomUI] Found existing LobbyUI in PlayerGui")
	end

	-- Find SHIFT label
	if not shiftLabel and lobbyGui then
		for _, descendant in ipairs(lobbyGui:GetDescendants()) do
			if descendant:IsA("TextLabel") and descendant.Text:match("SHIFT") then
				shiftLabel = descendant
				-- Get the parent Frame of the SHIFT label
				shiftFrame = shiftLabel.Parent
				break
			end
		end
	end

	-- Find Money label (MoneyCount)
	if not moneyLabel and lobbyGui then
		for _, descendant in ipairs(lobbyGui:GetDescendants()) do
			if descendant:IsA("TextLabel") and descendant.Name == "MoneyCount" then
				moneyLabel = descendant
				break
			end
		end
	end

	-- Find buttons
	if lobbyGui then
		if not settingBtn then
			settingBtn = lobbyGui:FindFirstChild("Setting")
		end
		if not shopBtn then
			shopBtn = lobbyGui:FindFirstChild("Shop")
		end
	end

	print(
		"[ServerRoomUI] UI elements found - Shift Frame:",
		shiftFrame ~= nil,
		"Money:",
		moneyLabel ~= nil,
		"Setting:",
		settingBtn ~= nil,
		"Shop:",
		shopBtn ~= nil
	)
end

-- Destroy LobbyUI
local function destroyLobbyUI()
	if lobbyGui then
		lobbyGui.Enabled = false
		print("[ServerRoomUI] LobbyUI hidden - entering game room")
	end
end

-- Recreate LobbyUI
local function recreateLobbyUI()
	if lobbyGui then
		lobbyGui.Enabled = true
		print("[ServerRoomUI] LobbyUI shown - left game room")
	end
end

-- Setup button handlers
local function setupButtonHandlers()
	-- Find buttons if they don't exist
	if not settingBtn or not shopBtn then
		if lobbyGui then
			settingBtn = lobbyGui:FindFirstChild("Setting")
			shopBtn = lobbyGui:FindFirstChild("Shop")

			if not settingBtn then
				for _, descendant in ipairs(lobbyGui:GetDescendants()) do
					if descendant:IsA("TextButton") and descendant.Name == "Setting" then
						settingBtn = descendant
						break
					end
				end
			end

			if not shopBtn then
				for _, descendant in ipairs(lobbyGui:GetDescendants()) do
					if descendant:IsA("TextButton") and descendant.Name == "Shop" then
						shopBtn = descendant
						break
					end
				end
			end
		end
	end

	-- Set up button click handlers
	if settingBtn then
		-- Handle Setting button click
		settingBtn.MouseButton1Click:Connect(function()
			print("[ServerRoomUI] opened the setting")
		end)
	end
	if shopBtn then
		-- Handle Shop button click
		shopBtn.MouseButton1Click:Connect(function()
			print("[ServerRoomUI] opened the shop")
		end)
	end
end

-- Update SHIFT indicator color and text
local function updateShiftIndicator(isHolding: boolean)
	if not shiftFrame then
		return
	end

	if isHolding then
		-- Shift held: bright/active color
		shiftFrame.BackgroundColor3 = Color3.fromRGB(100, 255, 100) -- Bright green
		if shiftLabel then
			shiftLabel.TextColor3 = Color3.fromRGB(0, 0, 0) -- Dark text
		end
	else
		-- Released: light blue with black text
		shiftFrame.BackgroundColor3 = Color3.fromRGB(100, 200, 255) -- Light blue
		if shiftLabel then
			shiftLabel.TextColor3 = Color3.fromRGB(0, 0, 0) -- Black text
		end
	end
end

-- Update money display
local function setMoney(amount: number)
	currentMoney = amount
	if moneyLabel then
		moneyLabel.Text = "$ " .. tostring(amount)
	end
end

-- Listen for Shift key to update indicator
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.LeftShift then
		updateShiftIndicator(true)
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		updateShiftIndicator(false)
	end
end)

-- Initialize
task.wait(5) -- Wait for loading screen to disappear
findUIElements()

-- Set up elements now that LobbyUI exists
if lobbyGui then
	-- Find SHIFT label and its parent frame
	for _, descendant in ipairs(lobbyGui:GetDescendants()) do
		if descendant:IsA("TextLabel") and descendant.Text:match("SHIFT") then
			shiftLabel = descendant
			shiftFrame = shiftLabel.Parent
			break
		end
	end

	-- Find Money label (MoneyCount)
	for _, descendant in ipairs(lobbyGui:GetDescendants()) do
		if descendant:IsA("TextLabel") and descendant.Name == "MoneyCount" then
			moneyLabel = descendant
			break
		end
	end

	-- Find buttons - search through all descendants if not found as direct children
	settingBtn = lobbyGui:FindFirstChild("Setting")
	shopBtn = lobbyGui:FindFirstChild("Shop")

	-- If not found, search descendants
	if not settingBtn then
		for _, descendant in ipairs(lobbyGui:GetDescendants()) do
			if descendant:IsA("TextButton") and descendant.Name == "Setting" then
				settingBtn = descendant
				print("[ServerRoomUI] Found Setting button in descendants:", descendant:GetFullName())
				break
			end
		end
	end

	if not shopBtn then
		for _, descendant in ipairs(lobbyGui:GetDescendants()) do
			if descendant:IsA("TextButton") and descendant.Name == "Shop" then
				shopBtn = descendant
				print("[ServerRoomUI] Found Shop button in descendants:", descendant:GetFullName())
				break
			end
		end
	end

	-- Debug: list all TextButtons found
	print("[ServerRoomUI] All TextButtons in LobbyUI:")
	for _, descendant in ipairs(lobbyGui:GetDescendants()) do
		if descendant:IsA("TextButton") then
			print("  -", descendant.Name, "@", descendant:GetFullName())
		end
	end

	print(
		"[ServerRoomUI] Elements initialized - Shift Frame:",
		shiftFrame ~= nil,
		"Money:",
		moneyLabel ~= nil,
		"Setting:",
		settingBtn ~= nil,
		"Shop:",
		shopBtn ~= nil
	)

	-- Set up button click handlers
	if settingBtn then
		-- Handle Setting button click
		settingBtn.MouseButton1Click:Connect(function()
			print("[ServerRoomUI] opened the setting")
		end)
	end
	if shopBtn then
		-- Handle Shop button click
		shopBtn.MouseButton1Click:Connect(function()
			print("[ServerRoomUI] opened the shop")
		end)
	end
end

-- Listen for when we enter a game room (destroy LobbyUI)
roomReadyEvent.OnClientEvent:Connect(function()
	inGameRoom = true
	destroyLobbyUI()
end)

-- Listen for when we leave a game room (recreate LobbyUI)
leaveRoomEvent.OnClientEvent:Connect(function()
	inGameRoom = false
	task.wait(0.5) -- Small delay to ensure UI cleanup is done
	recreateLobbyUI()
end)

-- Expose function to update money globally
_G.SetPlayerMoney = setMoney

print("[ServerRoomUI] Ready - Money display initialized")
