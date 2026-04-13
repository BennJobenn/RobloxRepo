-- TableGameClient (LocalScript)
-- Place inside: StarterPlayerScripts

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player.PlayerGui

local remotesFolder = ReplicatedStorage:WaitForChild("TableGameRemotes")
local updatePromptEvent = remotesFolder:WaitForChild("UpdatePromptForPlayer")
local hostConfirmedEvent = remotesFolder:WaitForChild("HostConfirmed")
local cancelEvent = remotesFolder:WaitForChild("PlayerCancelled")
local lobbyUpdateEvent = remotesFolder:WaitForChild("LobbyUpdate")
local hostStartEvent = remotesFolder:WaitForChild("HostStart")
local gameStartingEvent = remotesFolder:WaitForChild("GameStarting")

local tablesFolder = workspace:WaitForChild("Tables")

-- ── Loading Screen ─────────────────────────────────────────────────────────────
local function showLoadingScreen()
	-- Load LoadingScreen from ReplicatedStorage
	local loadingTemplate = ReplicatedStorage:FindFirstChild("LoadingScreen")
	if not loadingTemplate then
		warn("[TableGameClient] LoadingScreen not found in ReplicatedStorage")
		return
	end

	local loadingGui = loadingTemplate:Clone()

	-- Ensure it's a ScreenGui with proper settings
	if loadingGui:IsA("ScreenGui") then
		loadingGui.ResetOnSpawn = false
		loadingGui.IgnoreGuiInset = true
		loadingGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	end

	loadingGui.Parent = playerGui

	-- Wait 5 seconds
	task.wait(5)

	-- Fade out the frame background
	local frame = loadingGui:FindFirstChild("Frame")
	if frame then
		TweenService:Create(
			frame,
			TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		):Play()

		-- Fade UIGradient manually (can't be tweened as NumberSequence)
		local gradient = frame:FindFirstChild("UIGradient")
		if gradient then
			task.spawn(function()
				local startTime = tick()
				local duration = 2
				local startTransparency = gradient.Transparency or NumberSequence.new(0)
				while tick() - startTime < duration do
					local elapsed = tick() - startTime
					local progress = math.min(elapsed / duration, 1)
					-- Quad out easing
					local eased = 1 - (1 - progress) ^ 2
					gradient.Transparency = NumberSequence.new(eased)
					task.wait(0.016) -- ~60fps
				end
				gradient.Transparency = NumberSequence.new(1)
			end)
		end

		-- Fade all elements manually in sync with gradient
		local animateElement = function(element, transparencyProperty)
			if not element then
				return
			end
			task.spawn(function()
				local startTime = tick()
				local duration = 2
				while tick() - startTime < duration do
					local elapsed = tick() - startTime
					local progress = math.min(elapsed / duration, 1)
					-- Quad out easing
					local eased = 1 - (1 - progress) ^ 2
					element[transparencyProperty] = eased

					-- Also fade any UIStroke children
					for _, child in ipairs(element:GetChildren()) do
						if child:IsA("UIStroke") then
							child.Transparency = eased
						end
					end

					task.wait(0.016) -- ~60fps
				end
				element[transparencyProperty] = 1
				-- Ensure strokes are fully transparent
				for _, child in ipairs(element:GetChildren()) do
					if child:IsA("UIStroke") then
						child.Transparency = 1
					end
				end
			end)
		end

		-- Fade "image" (ImageLabel)
		local image = frame:FindFirstChild("image")
		if image and image:IsA("ImageLabel") then
			animateElement(image, "ImageTransparency")
		end

		-- Fade "card" (TextLabel for "Cards Galore" title)
		local card = frame:FindFirstChild("card")
		if card and card:IsA("TextLabel") then
			animateElement(card, "TextTransparency")
		end

		-- Fade "loading" (TextLabel for "Loading ..." text)
		local loading = frame:FindFirstChild("loading")
		if loading and loading:IsA("TextLabel") then
			animateElement(loading, "TextTransparency")
		end
	end

	-- Wait for fade to complete, then completely unparent and destroy
	task.wait(2.1)

	-- Completely remove from visual tree
	loadingGui.Parent = nil

	-- Finally destroy the GUI itself
	loadingGui:Destroy()
end

-- Show loading screen at startup
task.spawn(showLoadingScreen)

-- ── Per-table prompt tracking ──────────────────────────────────────────────────
-- We manage each table's ProximityPrompt independently
local tablePrompts: { [Model]: ProximityPrompt } = {}

local function registerTable(tableModel: Model)
	local interactpart = tableModel:WaitForChild("InteractPart")
	local prompt = interactpart:WaitForChild("ProximityPrompt") :: ProximityPrompt
	tablePrompts[tableModel] = prompt

	-- Track which table's prompt we last triggered (to know if we're host)
	prompt.Triggered:Connect(function()
		_G.TableGame_LastTriggeredTable = tableModel
		_G.TableGame_WasHostPrompt = (prompt.ActionText == "Host a game")
	end)
end

for _, tableModel in ipairs(tablesFolder:GetChildren()) do
	if tableModel:IsA("Model") then
		registerTable(tableModel)
	end
end
tablesFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		registerTable(child)
	end
end)

-- ── State ──────────────────────────────────────────────────────────────────────
local isSeated = false
local isHost = false
local isFrozen = false
local myTable: Model? = nil -- which table this player is currently seated at

-- Store last game info for cinematic handoff
local lastGameType = "Game"
local lastPlayerCount = 4

-- ── UI references ──────────────────────────────────────────────────────────────
local hostSetupGui: ScreenGui? = nil
local lobbyGui: ScreenGui? = nil
local gameScreenGui: ScreenGui? = nil
local gameHudGui: ScreenGui? = nil
local leaveConfirmGui: ScreenGui? = nil
local playerListLabel: TextLabel? = nil
local inRoom = false

-- Forward declare leaveRoom so closeAllUIs can call it
local leaveRoom: () -> ()

local function closeLeaveConfirmGui()
	if leaveConfirmGui then
		leaveConfirmGui:Destroy()
		leaveConfirmGui = nil
	end
end

-- ── Freeze / unfreeze ──────────────────────────────────────────────────────────
local function freezeCharacter()
	if isFrozen then
		return
	end
	isFrozen = true
	local char = player.Character
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 0
		hum.JumpPower = 0
	end
	workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
end

local function unfreezeCharacter()
	if not isFrozen then
		return
	end
	isFrozen = false
	local char = player.Character
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 16
		hum.JumpPower = 50
		local currentCamera: any = workspace.CurrentCamera
		currentCamera.CameraType = Enum.CameraType.Custom
		currentCamera.CameraSubject = hum
	end
end

-- ── Close all UIs ──────────────────────────────────────────────────────────────
local function closeAllUIs()
	if hostSetupGui then
		hostSetupGui:Destroy()
		hostSetupGui = nil
	end
	if lobbyGui then
		lobbyGui:Destroy()
		lobbyGui = nil
	end
	if gameScreenGui then
		gameScreenGui:Destroy()
		gameScreenGui = nil
	end
	if gameHudGui then
		gameHudGui:Destroy()
		gameHudGui = nil
	end
	closeLeaveConfirmGui()
	playerListLabel = nil
	if inRoom then
		leaveRoom()
	end
	workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
end

-- ── UI helpers ─────────────────────────────────────────────────────────────────
local function makeFrame(parent, size, pos, color, transparency)
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = pos
	f.BackgroundColor3 = color or Color3.fromRGB(20, 20, 30)
	f.BackgroundTransparency = transparency or 0
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function addCorner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 12)
	c.Parent = parent
end

local function makeLabel(parent, text, size, pos, color, bold, xAlign)
	local l = Instance.new("TextLabel")
	l.Text = text
	l.Size = size
	l.Position = pos
	l.BackgroundTransparency = 1
	l.TextColor3 = color or Color3.fromRGB(255, 255, 255)
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextScaled = true
	l.TextXAlignment = xAlign or Enum.TextXAlignment.Center
	l.Parent = parent
	return l
end

local function makeButton(parent, text, size, pos, bg, fg)
	local b = Instance.new("TextButton")
	b.Text = text
	b.Size = size
	b.Position = pos
	b.BackgroundColor3 = bg or Color3.fromRGB(80, 160, 255)
	b.TextColor3 = fg or Color3.fromRGB(255, 255, 255)
	b.Font = Enum.Font.GothamBold
	b.TextScaled = true
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Parent = parent
	addCorner(b, 8)
	return b
end

local function makeXButton(parent, onClose)
	local btn = Instance.new("TextButton")
	btn.Text = "✕"
	btn.Size = UDim2.fromOffset(36, 36)
	btn.Position = UDim2.new(1, -46, 0, 10)
	btn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Font = Enum.Font.GothamBold
	btn.TextScaled = true
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = true
	btn.ZIndex = 10
	btn.Parent = parent
	addCorner(btn, 8)
	btn.MouseButton1Click:Connect(onClose)
	return btn
end

local function makeDivider(parent, yOffset)
	local d = Instance.new("Frame")
	d.Size = UDim2.new(1, -40, 0, 1)
	d.Position = UDim2.new(0, 20, 0, yOffset)
	d.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
	d.BorderSizePixel = 0
	d.Parent = parent
end

-- ── Cancel helper (shared by all X buttons and Leave button) ───────────────────
local function doCancel()
	cancelEvent:FireServer()
	closeAllUIs()
	unfreezeCharacter()
	isHost = false
	isSeated = false
	myTable = nil
	local char = player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.Sit = false
		end
	end
end

-- ── Prompt update ──────────────────────────────────────────────────────────────
-- Server sends the tableModel so we know which prompt to update
updatePromptEvent.OnClientEvent:Connect(function(tableModel: Model, phase: string, iAmSeated: boolean, settings)
	local prompt = tablePrompts[tableModel]
	if not prompt then
		return
	end

	if iAmSeated then
		prompt.Enabled = false
		return
	end

	if phase == "idle" then
		prompt.Enabled = true
		prompt.ActionText = "Host a game"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
	elseif phase == "setup" then
		prompt.Enabled = true
		prompt.ActionText = "Host is setting up..."
		prompt.KeyboardKeyCode = Enum.KeyCode.Unknown
	elseif phase == "lobby" then
		prompt.Enabled = true
		prompt.ActionText = "Join game"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
	elseif phase == "game" then
		prompt.Enabled = false
	end

	-- If we just lost our seat (server reset), clean up
	if not iAmSeated and myTable == tableModel then
		isHost = false
		isSeated = false
		myTable = nil
		closeAllUIs()
		unfreezeCharacter()
	end
end)

-- ── HOST SETUP UI ──────────────────────────────────────────────────────────────
local GAMES = {
	"Flip 7",
	"Uno",
	"Monkey Monkey",
}

local function openHostSetupUI()
	if hostSetupGui then
		hostSetupGui:Destroy()
	end

	-- Load HostUI from ReplicatedStorage
	local hostUITemplate = ReplicatedStorage:FindFirstChild("HostUI")
	if not hostUITemplate then
		warn("[TableGameClient] HostUI not found in ReplicatedStorage")
		return
	end

	local gui = hostUITemplate:Clone()
	gui.Parent = playerGui
	hostSetupGui = gui

	-- Animate in from top
	local frame = gui:FindFirstChild("Frame")
	if frame then
		local targetPos = frame.Position
		frame.Position = targetPos - UDim2.new(0, 0, 1, 0)
		TweenService
			:Create(
				frame,
				TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Position = targetPos }
			)
			:Play()
	end

	-- Get references to UI components
	local frame = gui:FindFirstChild("Frame")
	if not frame then
		warn("[TableGameClient] Frame not found in HostUI")
		return
	end

	-- Close button
	local closeBtn = frame:FindFirstChild("Close")
	if closeBtn then
		closeBtn.MouseButton1Click:Connect(doCancel)
	end

	-- Game buttons
	local options = frame:FindFirstChild("Options")
	local flip7Btn = options and options:FindFirstChild("Flip_7")
	local unoBtn = options and options:FindFirstChild("Uno")
	local monkeyBtn = options and options:FindFirstChild("Monkey_Monkey")

	local selectedGame = GAMES[1]
	local COLOR_SELECTED = Color3.fromRGB(100, 255, 100) -- Bright green
	local COLOR_UNSELECTED = Color3.fromRGB(150, 150, 200) -- Light gray

	local function updateGameButtonStates()
		if flip7Btn then
			flip7Btn.BackgroundColor3 = (selectedGame == "Flip 7") and COLOR_SELECTED or COLOR_UNSELECTED
		end
		if unoBtn then
			unoBtn.BackgroundColor3 = (selectedGame == "Uno") and COLOR_SELECTED or COLOR_UNSELECTED
		end
		if monkeyBtn then
			monkeyBtn.BackgroundColor3 = (selectedGame == "Monkey Monkey") and COLOR_SELECTED or COLOR_UNSELECTED
		end
	end

	if flip7Btn then
		flip7Btn.MouseButton1Click:Connect(function()
			selectedGame = "Flip 7"
			updateGameButtonStates()
		end)
	end

	if unoBtn then
		unoBtn.MouseButton1Click:Connect(function()
			selectedGame = "Uno"
			updateGameButtonStates()
		end)
	end

	if monkeyBtn then
		monkeyBtn.MouseButton1Click:Connect(function()
			selectedGame = "Monkey Monkey"
			updateGameButtonStates()
		end)
	end

	updateGameButtonStates()

	-- Player count controls
	local countModifier = frame:FindFirstChild("CountModifier")
	if countModifier then
		local minus = countModifier:FindFirstChild("Minus")
		local count = countModifier:FindFirstChild("Count")
		local plus = countModifier:FindFirstChild("Plus")

		local playerCount = 4
		local MIN_P, MAX_P = 2, 8

		local function updateCountDisplay()
			if count then
				count.Text = tostring(playerCount)
			end
		end

		if minus then
			minus.MouseButton1Click:Connect(function()
				if playerCount > MIN_P then
					playerCount -= 1
					updateCountDisplay()
				end
			end)
		end

		if plus then
			plus.MouseButton1Click:Connect(function()
				if playerCount < MAX_P then
					playerCount += 1
					updateCountDisplay()
				end
			end)
		end

		updateCountDisplay()

		-- Confirm button
		local confirmBtn = frame:FindFirstChild("Confirm")
		if confirmBtn then
			confirmBtn.MouseButton1Click:Connect(function()
				hostConfirmedEvent:FireServer(selectedGame, playerCount)
				if hostSetupGui then
					hostSetupGui:Destroy()
					hostSetupGui = nil
				end
			end)
		end
	end
end

-- ── WAITING LOBBY UI ───────────────────────────────────────────────────────────
local playerNameClones: { TextLabel } = {} -- Track cloned player name labels

local function openLobbyUI(
	hostName: string,
	playerNames: { string },
	gameType: string,
	playerCount: number,
	amHost: boolean
)
	-- If already open, just update the content
	if lobbyGui then
		-- Update host name (search in multiple locations)
		local frame = lobbyGui:FindFirstChild("Frame")
		if frame then
			local hostLabel = frame:FindFirstChild("HostName")
			if not hostLabel then
				-- Try looking in Description section
				local description = frame:FindFirstChild("Description")
				if description then
					hostLabel = description:FindFirstChild("HostName")
				end
			end
			if hostLabel then
				hostLabel.Text = hostName
			end

			-- Update game, host, and max players info
			local gameLabel = frame:FindFirstChild("Game")
			if gameLabel then
				gameLabel.Text = gameType
			end

			local maxPlayersLabel = frame:FindFirstChild("PlayerCount")
			if not maxPlayersLabel then
				local description = frame:FindFirstChild("Description")
				if description then
					maxPlayersLabel = description:FindFirstChild("PlayerCount")
				end
			end
			if maxPlayersLabel then
				maxPlayersLabel.Text = tostring(playerCount)
			end

			-- Update player list by updating/creating clones
			local playerNamesTemplate = frame:FindFirstChild("PlayerNames")
			if not playerNamesTemplate then
				local description = frame:FindFirstChild("Description")
				if description then
					playerNamesTemplate = description:FindFirstChild("PlayerNames")
				end
			end

			if playerNamesTemplate then
				-- Clear old clones
				for _, clone in ipairs(playerNameClones) do
					clone:Destroy()
				end
				playerNameClones = {}

				-- Create new clones for updated player list (with 2-column support for >4 players)
				local playerNameCount = #playerNames
				local useDoubleColumn = playerNameCount > 4

				for i, playerName in ipairs(playerNames) do
					local clone = playerNamesTemplate:Clone()
					clone.Text = playerName

					if useDoubleColumn then
						-- Two-column layout: up to 4 rows per column
						local rowInColumn = (i - 1) % 4
						local columnIndex = math.floor((i - 1) / 4)

						-- Position: template position + (row * template height) + (column offset to the right)
						local yOffset = rowInColumn * playerNamesTemplate.Size.Y.Offset
						local xOffset = columnIndex * (playerNamesTemplate.Size.X.Offset / 2)

						clone.Position = playerNamesTemplate.Position + UDim2.new(0, xOffset, 0, yOffset)
						clone.Size = UDim2.new(
							playerNamesTemplate.Size.X.Scale / 2,
							playerNamesTemplate.Size.X.Offset / 2,
							playerNamesTemplate.Size.Y.Scale,
							playerNamesTemplate.Size.Y.Offset
						)
					else
						-- Single column layout: stack vertically below template
						clone.Position = UDim2.new(
							playerNamesTemplate.Position.X.Scale,
							playerNamesTemplate.Position.X.Offset,
							playerNamesTemplate.Position.Y.Scale + (i - 1) * playerNamesTemplate.Size.Y.Scale,
							playerNamesTemplate.Position.Y.Offset
						)
						clone.Size = playerNamesTemplate.Size
					end

					clone.Visible = true
					clone.Parent = frame
					table.insert(playerNameClones, clone)
				end
			end
		end
		return
	end

	if lobbyGui then
		lobbyGui:Destroy()
	end

	-- Load Waiting template from ReplicatedStorage
	local waitingTemplate = ReplicatedStorage:FindFirstChild("Waiting")
	if not waitingTemplate then
		warn("[TableGameClient] Waiting template not found in ReplicatedStorage")
		return
	end

	local gui = waitingTemplate:Clone()
	gui.Parent = playerGui
	lobbyGui = gui

	-- Animate in from top
	local frame = gui:FindFirstChild("Frame")
	if frame then
		local targetPos = frame.Position
		frame.Position = targetPos - UDim2.new(0, 0, 1, 0)
		TweenService
			:Create(
				frame,
				TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Position = targetPos }
			)
			:Play()
	end

	-- Get references to UI components
	local frame = gui:FindFirstChild("Frame")
	if not frame then
		warn("[TableGameClient] Frame not found in Waiting template")
		return
	end

	-- Close button
	local closeBtn = frame:FindFirstChild("Close")
	if closeBtn then
		closeBtn.MouseButton1Click:Connect(doCancel)
	end

	-- Update game, host, and max players info
	local gameLabel = frame:FindFirstChild("Game")
	if gameLabel then
		gameLabel.Text = gameType
	end

	local hostLabel = frame:FindFirstChild("HostName")
	if not hostLabel then
		-- Try looking in Description section
		local description = frame:FindFirstChild("Description")
		if description then
			hostLabel = description:FindFirstChild("HostName")
		end
	end
	if hostLabel then
		hostLabel.Text = hostName
	end

	local maxPlayersLabel = frame:FindFirstChild("PlayerCount")
	if not maxPlayersLabel then
		-- Try looking in Description section
		local description = frame:FindFirstChild("Description")
		if description then
			maxPlayersLabel = description:FindFirstChild("PlayerCount")
		end
	end
	if maxPlayersLabel then
		maxPlayersLabel.Text = tostring(playerCount)
	end

	-- Set up player list using PlayerNames as template
	local playerNamesTemplate = frame:FindFirstChild("PlayerNames")
	if not playerNamesTemplate then
		-- Try looking in Description section
		local description = frame:FindFirstChild("Description")
		if description then
			playerNamesTemplate = description:FindFirstChild("PlayerNames")
		end
	end

	if playerNamesTemplate then
		-- Clear previous clones
		playerNameClones = {}

		local playerNameCount = #playerNames
		local useDoubleColumn = playerNameCount > 4

		for i, playerName in ipairs(playerNames) do
			local clone = playerNamesTemplate:Clone()
			clone.Text = playerName

			if useDoubleColumn then
				-- Two-column layout: up to 4 rows per column
				local rowInColumn = (i - 1) % 4
				local columnIndex = math.floor((i - 1) / 4)

				-- Position: template position + (row * template height) + (column offset to the right)
				local yOffset = rowInColumn * playerNamesTemplate.Size.Y.Offset
				local xOffset = columnIndex * (playerNamesTemplate.Size.X.Offset / 2)

				clone.Position = playerNamesTemplate.Position + UDim2.new(0, xOffset, 0, yOffset)
				clone.Size = UDim2.new(
					playerNamesTemplate.Size.X.Scale / 2,
					playerNamesTemplate.Size.X.Offset / 2,
					playerNamesTemplate.Size.Y.Scale,
					playerNamesTemplate.Size.Y.Offset
				)
			else
				-- Single column layout: stack vertically below template
				clone.Position = UDim2.new(
					playerNamesTemplate.Position.X.Scale,
					playerNamesTemplate.Position.X.Offset,
					playerNamesTemplate.Position.Y.Scale + (i - 1) * playerNamesTemplate.Size.Y.Scale,
					playerNamesTemplate.Position.Y.Offset
				)
				clone.Size = playerNamesTemplate.Size
			end

			clone.Visible = true
			clone.Parent = frame
			table.insert(playerNameClones, clone)
		end

		-- Hide the template
		playerNamesTemplate.Visible = false
	end

	-- Start Game button for host, or waiting message for guests
	local confirmBtn = frame:FindFirstChild("Confirm")
	if confirmBtn then
		if amHost then
			confirmBtn.Text = "Start Game"
			confirmBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 100)
			confirmBtn.MouseButton1Click:Connect(function()
				hostStartEvent:FireServer()
				if lobbyGui then
					lobbyGui:Destroy()
					lobbyGui = nil
				end
			end)
		else
			-- For non-host, replace button with waiting message
			confirmBtn:Destroy()
			local waitingMsg = Instance.new("TextLabel")
			waitingMsg.Name = "WaitingMessage"
			waitingMsg.Text = "Waiting for host to start..."
			waitingMsg.Size = UDim2.fromScale(0.8, 0.08)
			waitingMsg.Position = UDim2.fromScale(0.1, 0.84)
			waitingMsg.BackgroundTransparency = 1
			waitingMsg.TextColor3 = Color3.fromRGB(255, 255, 255)
			waitingMsg.Font = Enum.Font.GothamBold
			waitingMsg.TextScaled = true
			waitingMsg.Parent = frame
		end
	end
end

-- ── ROOM POV SYSTEM ────────────────────────────────────────────────────────────
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local roomReadyEvent = remotesFolder:WaitForChild("RoomReady")
local leaveRoomEvent = remotesFolder:WaitForChild("LeaveRoom")
local headLookEvent = remotesFolder:WaitForChild("HeadLook")

local headLookConnection: RBXScriptConnection? = nil
local roomCameraConnection: RBXScriptConnection? = nil
local streamKeepAliveToken = 0
local topDownActive = false
local roomTopDownCF: CFrame? = nil
local mySeatCFrame: CFrame? = nil
local roomCenter: Vector3? = nil
local currentRoomClone: Model? = nil

-- camera yaw/pitch accumulated from mouse delta while in room
local camYaw = 0
local camPitch = 0

local function setCurrentCloneHeadHidden(hidden: boolean)
	return
end

local function getCurrentCloneHumanoid(): Humanoid?
	if not currentRoomClone then
		return nil
	end

	local cloneModel = currentRoomClone:FindFirstChild("Clone_" .. player.Name, true)
	return cloneModel and cloneModel:FindFirstChildOfClass("Humanoid") or nil
end

local function updateRoomCamera()
	if not inRoom then
		return
	end

	local cam = workspace.CurrentCamera
	local cloneHumanoid = getCurrentCloneHumanoid()

	if topDownActive then
		local seatFrame = mySeatCFrame or roomTopDownCF
		local topViewHumanoid = getCurrentCloneHumanoid()
		local cloneModel = topViewHumanoid and topViewHumanoid.Parent
		local rootPart = cloneModel and cloneModel:FindFirstChild("HumanoidRootPart")

		local clonePos = rootPart and rootPart.Position or (seatFrame and seatFrame.Position) or Vector3.new()

		-- 🔄 rotation (already working)
		local yRotation = math.rad(90)

		-- 📌 move camera toward table (forward from seat)
		local forward = seatFrame.LookVector
		local offset = forward * 6 -- tweak this value (2–5 is typical)

		local camPosition = clonePos + offset + Vector3.new(0, 7, 0)

		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.new(camPosition) * CFrame.Angles(0, yRotation, 0) * CFrame.Angles(-math.rad(90), 0, 0)

		setCurrentCloneHeadHidden(true)
		return
	end

	cam.CameraType = Enum.CameraType.Custom
	if cloneHumanoid then
		cam.CameraSubject = cloneHumanoid
	end
	setCurrentCloneHeadHidden(true)
end

-- ── Fade helper (returns immediately, runs async) ──────────────────────────────
local function fadeOut(duration: number, onDone: () -> ())
	local fadeGui = Instance.new("ScreenGui")
	fadeGui.Name = "Fade"
	fadeGui.ResetOnSpawn = false
	fadeGui.IgnoreGuiInset = true
	fadeGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	fadeGui.Parent = playerGui
	local frame = makeFrame(fadeGui, UDim2.fromScale(1, 1), UDim2.new(), Color3.fromRGB(0, 0, 0), 1) -- starts transparent
	TweenService:Create(frame, TweenInfo.new(duration), { BackgroundTransparency = 0 }):Play() -- fades TO black
	task.delay(duration, function()
		onDone()
		fadeGui:Destroy()
	end)
end

local function fadeIn(duration: number)
	local fadeGui = Instance.new("ScreenGui")
	fadeGui.Name = "Fade"
	fadeGui.ResetOnSpawn = false
	fadeGui.IgnoreGuiInset = true
	fadeGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	fadeGui.Parent = playerGui
	local frame = makeFrame(fadeGui, UDim2.fromScale(1, 1), UDim2.new(), Color3.fromRGB(0, 0, 0), 0) -- starts black
	TweenService:Create(frame, TweenInfo.new(duration), { BackgroundTransparency = 1 }):Play() -- fades FROM black
	task.delay(duration, function()
		fadeGui:Destroy()
	end)
end

-- ── Game HUD ───────────────────────────────────────────────────────────────────
local function openGameHUD(gameType: string)
	if gameHudGui then
		gameHudGui:Destroy()
	end

	-- Load Hud template from ReplicatedStorage
	local hudTemplate = ReplicatedStorage:FindFirstChild("Hud")
	if not hudTemplate then
		warn("[TableGameClient] Hud template not found in ReplicatedStorage")
		return
	end

	local gui = hudTemplate:Clone()
	gui.Parent = playerGui
	gameHudGui = gui

	-- Get references to UI components
	local frame = gui:FindFirstChild("Frame")
	if not frame then
		warn("[TableGameClient] Frame not found in Hud template")
		return
	end

	-- Leave button
	local leaveBtn = frame:FindFirstChild("Leave")
	if leaveBtn then
		leaveBtn.MouseButton1Click:Connect(function()
			if leaveConfirmGui and leaveConfirmGui.Parent then
				return
			end

			-- Load LeaveConfirm template from ReplicatedStorage
			local leaveConfirmTemplate = ReplicatedStorage:FindFirstChild("LeaveConfirm")
			if not leaveConfirmTemplate then
				warn("[TableGameClient] LeaveConfirm template not found in ReplicatedStorage")
				return
			end

			local confirmGui = leaveConfirmTemplate:Clone()
			leaveConfirmGui = confirmGui
			confirmGui.Parent = playerGui

			-- Animate in from top
			local confirmFrame = confirmGui:FindFirstChild("Frame")
			if confirmFrame then
				local targetPos = confirmFrame.Position
				confirmFrame.Position = targetPos - UDim2.new(0, 0, 1, 0)
				TweenService:Create(
					confirmFrame,
					TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Position = targetPos }
				):Play()
			end

			-- Get references to UI components
			local confirmFrame = confirmGui:FindFirstChild("Frame")
			if not confirmFrame then
				warn("[TableGameClient] Frame not found in LeaveConfirm template")
				closeLeaveConfirmGui()
				return
			end

			-- Yes button
			local yesBtn = confirmFrame:FindFirstChild("yes")
			if yesBtn then
				yesBtn.MouseButton1Click:Connect(function()
					closeLeaveConfirmGui()
					cancelEvent:FireServer()
				end)
			end

			-- No button
			local noBtn = confirmFrame:FindFirstChild("no")
			if noBtn then
				noBtn.MouseButton1Click:Connect(function()
					closeLeaveConfirmGui()
				end)
			end
		end)
	end

	-- POV button
	local povBtn = frame:FindFirstChild("Pov")
	if povBtn then
		-- Ensure text color is visible
		povBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		povBtn.MouseButton1Click:Connect(function()
			topDownActive = not topDownActive
			updateRoomCamera()
		end)
	end
end

-- ── Enter hidden room (called in its own task.spawn thread) ────────────────────
local function enterRoomAsync(
	roomClone: Model,
	seatCF: CFrame,
	allSeatCFs: { CFrame },
	gameType: string,
	physicalTable: Model?
)
	inRoom = true
	mySeatCFrame = seatCF
	topDownActive = false
	currentRoomClone = roomClone

	-- Compute room center from all seat positions
	local center = seatCF.Position
	if #allSeatCFs > 0 then
		center = Vector3.new(0, 0, 0)
		for _, cf in ipairs(allSeatCFs) do
			center += cf.Position
		end
		center /= #allSeatCFs
	end
	roomCenter = center
	roomTopDownCF = CFrame.new(center + Vector3.new(0, 28, 0), center)
	pcall(function()
		player:RequestStreamAroundAsync(center)
	end)

	streamKeepAliveToken += 1
	local myToken = streamKeepAliveToken
	task.spawn(function()
		while inRoom and streamKeepAliveToken == myToken do
			pcall(function()
				player:RequestStreamAroundAsync(center)
			end)
			if mySeatCFrame then
				pcall(function()
					player:RequestStreamAroundAsync(mySeatCFrame.Position)
				end)
			end
			task.wait(1)
		end
	end)

	-- Close lobby UI
	if lobbyGui then
		lobbyGui:Destroy()
		lobbyGui = nil
	end

	if roomCameraConnection then
		roomCameraConnection:Disconnect()
		roomCameraConnection = nil
	end

	-- ── Step 1: cinematic on the physical table ────────────────────────────────
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable

	local transitionTable = physicalTable or myTable
	local tablePart = transitionTable and transitionTable:FindFirstChildWhichIsA("BasePart", true)
	local tableCenter = tablePart and tablePart.Position or center

	-- Start top-down, fade in to show the cinematic
	cam.CFrame = CFrame.new(tableCenter + Vector3.new(0, 40, 0), tableCenter)

	local revealGui = Instance.new("ScreenGui")
	revealGui.Name = "CinReveal"
	revealGui.ResetOnSpawn = false
	revealGui.IgnoreGuiInset = true
	revealGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	revealGui.Parent = playerGui
	local revealFrame = makeFrame(revealGui, UDim2.fromScale(1, 1), UDim2.new(), Color3.fromRGB(0, 0, 0), 0)

	-- Fade in the cinematic view
	TweenService:Create(revealFrame, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()

	-- Zoom camera down toward the table
	local endCF = CFrame.new(tableCenter + Vector3.new(0, 8, 4), tableCenter)
	local zoom = TweenService:Create(
		cam,
		TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ CFrame = endCF }
	)
	zoom:Play()
	task.wait(3)

	-- Fade to black
	TweenService:Create(revealFrame, TweenInfo.new(0.5), { BackgroundTransparency = 0 }):Play()
	task.wait(0.5)
	revealGui:Destroy()

	-- ── Step 2: silently move camera to the hidden room seat ───────────────────
	local headPos = seatCF.Position + Vector3.new(0, 1.5, 0)
	pcall(function()
		player:RequestStreamAroundAsync(headPos)
	end)

	-- Hand control back to the default Roblox camera, but follow the local clone's head.
	local cloneModel = roomClone:FindFirstChild("Clone_" .. player.Name, true)
	local cloneHumanoid = cloneModel and cloneModel:FindFirstChildOfClass("Humanoid")
	cam.CameraType = Enum.CameraType.Custom
	if cloneHumanoid then
		cam.CameraSubject = cloneHumanoid
	else
		cam.CameraSubject = player.Character and player.Character:FindFirstChildOfClass("Humanoid") or nil
	end
	updateRoomCamera()

	roomCameraConnection = RunService.RenderStepped:Connect(function()
		updateRoomCamera()
	end)

	-- ── Step 3: fade in to reveal the hidden room ──────────────────────────────
	local fadeInGui = Instance.new("ScreenGui")
	fadeInGui.Name = "CinFadeIn"
	fadeInGui.ResetOnSpawn = false
	fadeInGui.IgnoreGuiInset = true
	fadeInGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	fadeInGui.Parent = playerGui
	local fadeInFrame = makeFrame(fadeInGui, UDim2.fromScale(1, 1), UDim2.new(), Color3.fromRGB(0, 0, 0), 0)
	TweenService:Create(fadeInFrame, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()
	task.wait(0.6)
	fadeInGui:Destroy()

	-- ── Step 4: open HUD ───────────────────────────────────────────────────────
	openGameHUD(gameType)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

-- ── Leave the hidden room ──────────────────────────────────────────────────────
leaveRoom = function()
	if not inRoom then
		-- Still clean up just in case
		if headLookConnection then
			headLookConnection:Disconnect()
			headLookConnection = nil
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
		if gameHudGui then
			gameHudGui:Destroy()
			gameHudGui = nil
		end
		closeLeaveConfirmGui()
		return
	end

	inRoom = false
	topDownActive = false
	streamKeepAliveToken += 1
	if roomCameraConnection then
		roomCameraConnection:Disconnect()
		roomCameraConnection = nil
	end
	setCurrentCloneHeadHidden(false)
	currentRoomClone = nil

	if headLookConnection then
		headLookConnection:Disconnect()
		headLookConnection = nil
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		local currentCamera: any = workspace.CurrentCamera
		currentCamera.CameraSubject = hum
	end

	task.spawn(function()
		-- Fade to black
		local fadeGui = Instance.new("ScreenGui")
		fadeGui.Name = "LeaveFade"
		fadeGui.ResetOnSpawn = false
		fadeGui.IgnoreGuiInset = true
		fadeGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
		fadeGui.Parent = playerGui
		local frame = makeFrame(fadeGui, UDim2.fromScale(1, 1), UDim2.new(), Color3.fromRGB(0, 0, 0), 1)
		TweenService:Create(frame, TweenInfo.new(0.4), { BackgroundTransparency = 0 }):Play()
		task.wait(0.4)

		-- Restore camera and clean up HUD
		workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
		if hum then
			local currentCamera: any = workspace.CurrentCamera
			currentCamera.CameraSubject = hum
		end
		if gameHudGui then
			gameHudGui:Destroy()
			gameHudGui = nil
		end
		closeLeaveConfirmGui()

		-- Fade back in
		TweenService:Create(frame, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
		task.wait(0.4)
		fadeGui:Destroy()
	end)
end

-- ── Remote listeners ───────────────────────────────────────────────────────────

-- Lobby updates
lobbyUpdateEvent.OnClientEvent:Connect(function(tableModel, hostName, playerNames, gameType, playerCount)
	lastGameType = gameType
	lastPlayerCount = playerCount
	local amHost = (player.Name == hostName)
	openLobbyUI(hostName, playerNames, gameType, playerCount, amHost)
end)

-- Room ready — spawn in its own thread so task.wait() works correctly
roomReadyEvent.OnClientEvent:Connect(
	function(roomClone: Model, seatCF: CFrame, allSeatCFs: { CFrame }, myIndex: number, physicalTable: Model?)
		task.spawn(function()
			local ok, err = pcall(function()
				enterRoomAsync(roomClone, seatCF, allSeatCFs, lastGameType, physicalTable or myTable)
			end)
			if not ok then
				warn("[TableGameClient] enterRoomAsync failed:", err)
				inRoom = false
				topDownActive = false
				currentRoomClone = nil
				if roomCameraConnection then
					roomCameraConnection:Disconnect()
					roomCameraConnection = nil
				end
				workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
				unfreezeCharacter()
				closeAllUIs()
			end
		end)
	end
)

-- Server says leave the room
leaveRoomEvent.OnClientEvent:Connect(function()
	task.spawn(leaveRoom)
end)

-- ── Detect local player sitting ────────────────────────────────────────────────
local function watchLocalHumanoid(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Seated:Connect(function(seated: boolean, currentSeat)
		if seated then
			-- Check if the seat belongs to any of our tables
			local seatedTable: Model? = nil
			for tableModel in pairs(tablePrompts) do
				if currentSeat and currentSeat:IsDescendantOf(tableModel) then
					seatedTable = tableModel
					break
				end
			end
			if not seatedTable then
				return
			end

			isSeated = true
			myTable = seatedTable
			freezeCharacter()

			task.wait(0.2)
			if _G.TableGame_WasHostPrompt and _G.TableGame_LastTriggeredTable == seatedTable then
				_G.TableGame_WasHostPrompt = false
				isHost = true
				openHostSetupUI()
			end
		else
			if isSeated then
				isSeated = false
				isHost = false
				myTable = nil
				unfreezeCharacter()
				closeAllUIs()
			end
		end
	end)
end

if player.Character then
	watchLocalHumanoid(player.Character)
end
player.CharacterAdded:Connect(function(c)
	task.wait(0.1)
	watchLocalHumanoid(c)
	isSeated = false
	isHost = false
	isFrozen = false
	myTable = nil
	_G.TableGame_WasHostPrompt = false
	closeAllUIs()
	unfreezeCharacter()
end)
