-- TableGameServer (Script)
-- Place inside: ServerScriptService
--
-- Workspace structure:
--   Workspace
--   └── Tables (Folder)
--         ├── table (Model)
--         │     ├── InteractPart (BasePart) → ProximityPrompt inside
--         │     └── chair (Model, x8)
--         │           └── Seat (BasePart)
--         ├── table (Model)
--         └── ... (as many as you want)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Remotes ────────────────────────────────────────────────────────────────────
local remotesFolder = Instance.new("Folder")
remotesFolder.Name = "TableGameRemotes"
remotesFolder.Parent = ReplicatedStorage

local updatePromptEvent = Instance.new("RemoteEvent")
updatePromptEvent.Name = "UpdatePromptForPlayer"
updatePromptEvent.Parent = remotesFolder

local hostConfirmedEvent = Instance.new("RemoteEvent")
hostConfirmedEvent.Name = "HostConfirmed"
hostConfirmedEvent.Parent = remotesFolder

local cancelEvent = Instance.new("RemoteEvent")
cancelEvent.Name = "PlayerCancelled"
cancelEvent.Parent = remotesFolder

local lobbyUpdateEvent = Instance.new("RemoteEvent")
lobbyUpdateEvent.Name = "LobbyUpdate"
lobbyUpdateEvent.Parent = remotesFolder

local hostStartEvent = Instance.new("RemoteEvent")
hostStartEvent.Name = "HostStart"
hostStartEvent.Parent = remotesFolder

local gameStartingEvent = Instance.new("RemoteEvent")
gameStartingEvent.Name = "GameStarting"
gameStartingEvent.Parent = remotesFolder

-- BindableEvents for communicating with RoomManager
-- Created here so they exist regardless of script load order
local buildRoomEvent = Instance.new("BindableEvent")
buildRoomEvent.Name = "BuildRoom"
buildRoomEvent.Parent = remotesFolder

local destroyRoomEvent = Instance.new("BindableEvent")
destroyRoomEvent.Name = "DestroyRoom"
destroyRoomEvent.Parent = remotesFolder

local removeRoomPlayerEvent = Instance.new("BindableEvent")
removeRoomPlayerEvent.Name = "RemoveRoomPlayer"
removeRoomPlayerEvent.Parent = remotesFolder

local gameEndedEvent = Instance.new("BindableEvent")
gameEndedEvent.Name = "GameEnded"
gameEndedEvent.Parent = remotesFolder

-- ── Find all tables ────────────────────────────────────────────────────────────
local tablesFolder = workspace:WaitForChild("Tables")

-- ── Per-table state ────────────────────────────────────────────────────────────
-- Each entry in tableStates is keyed by the table Model instance itself
-- state = {
--   model, prompt, chairs, seats,
--   phase, host, hostChairIndex,
--   seatedPlayers {[Player]: number (chairIndex)},
--   gameSettings {gameType, playerCount}?,
--   visibleChairIndices {number}
-- }
local tableStates: { [Model]: any } = {}

-- Track which table a player is currently seated at
local playerTableMap: { [Player]: Model } = {}

local DEFAULT_VISIBLE = 4
local DEFAULT_HIGHLIGHT_OUTLINE = 0.2

local function setTableHighlightVisible(state, visible: boolean)
	local highlight = state.highlight
	if not highlight or not highlight.Parent or not highlight:IsA("Highlight") then
		return
	end

	highlight.Enabled = true
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = visible and state.highlightOutlineTransparency or 1
end

-- ── Chair helpers ──────────────────────────────────────────────────────────────
local function setChairVisible(chair: Model, visible: boolean)
	for _, part in ipairs(chair:GetDescendants()) do
		if part:IsA("BasePart") then
			if part.Name ~= "Seat" then
				part.Transparency = visible and 0 or 1
				part.CanCollide = visible
			end
		end
	end
	-- Seat is always invisible and non-collidable
	local seat = chair:FindFirstChild("Seat", true)
	if seat and seat:IsA("BasePart") then
		seat.Transparency = 1
		seat.CanCollide = false
	end
end

local function applyChairVisibility(state, visibleIndices: { number })
	local indexSet: { [number]: true } = {}
	for _, i in ipairs(visibleIndices) do
		indexSet[i] = true
	end
	for i, chair in ipairs(state.chairs) do
		setChairVisible(chair, indexSet[i] == true)
	end
	state.visibleChairIndices = visibleIndices
end

local function showDefaultChairs(state)
	local indices = {}
	for i = 1, math.min(DEFAULT_VISIBLE, #state.chairs) do
		table.insert(indices, i)
	end
	applyChairVisibility(state, indices)
end

local function getAvailableVisible(state): { number }
	local available = {}
	for _, i in ipairs(state.visibleChairIndices) do
		if not state.seats[i].Occupant then
			table.insert(available, i)
		end
	end
	return available
end

-- ── Prompt broadcasting ────────────────────────────────────────────────────────
local function refreshAllPrompts(state)
	for _, p in ipairs(Players:GetPlayers()) do
		local iAmSeated = state.seatedPlayers[p] ~= nil
		updatePromptEvent:FireClient(p, state.model, state.phase, iAmSeated, state.gameSettings)
	end
end

-- ── Lobby broadcasting ─────────────────────────────────────────────────────────
local function broadcastLobbyUpdate(state)
	if not state.gameSettings then
		return
	end
	local hostName = state.host and state.host.Name or "?"
	local playerNames = {}
	for p in pairs(state.seatedPlayers) do
		table.insert(playerNames, p.Name)
	end
	-- Send to ALL seated players (including host)
	for p in pairs(state.seatedPlayers) do
		lobbyUpdateEvent:FireClient(
			p,
			state.model,
			hostName,
			playerNames,
			state.gameSettings.gameType,
			state.gameSettings.playerCount
		)
	end
end

-- ── Unseat helpers ─────────────────────────────────────────────────────────────
local function unseatPlayer(p: Player)
	local char = p.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.Sit = false
		end
	end
end

local function getUsableHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	if humanoid.Health <= 0 then
		return nil
	end

	if humanoid:GetState() == Enum.HumanoidStateType.Dead then
		return nil
	end

	return humanoid
end

local function fullReset(state)
	print("[TableGame]", state.model.Name, "full reset")

	-- Destroy hidden game room if one exists
	destroyRoomEvent:Fire(state.model)

	for p in pairs(state.seatedPlayers) do
		playerTableMap[p] = nil
		unseatPlayer(p)
	end
	state.seatedPlayers = {}
	state.host = nil
	state.hostChairIndex = nil
	state.gameSettings = nil
	state.phase = "idle"
	state.visibleChairIndices = {}
	showDefaultChairs(state)
	setTableHighlightVisible(state, true)
	state.prompt.ActionText = "Host a game"
	state.prompt.KeyboardKeyCode = Enum.KeyCode.E
	refreshAllPrompts(state)
end

local function sitPlayer(state, player: Player, chairIndex: number): boolean
	local humanoid = getUsableHumanoid(player)
	if not humanoid then
		return false
	end

	local ok, err = pcall(function()
		state.seats[chairIndex]:Sit(humanoid)
	end)
	if not ok then
		warn("[TableGame] Failed to seat", player.Name, "at", state.model.Name, ":", err)
		return false
	end

	state.seatedPlayers[player] = chairIndex
	playerTableMap[player] = state.model
	return true
end

-- ── Initialise each table ──────────────────────────────────────────────────────
local function initTable(tableModel: Model)
	local interactpart = tableModel:WaitForChild("InteractPart")
	local prompt = interactpart:WaitForChild("ProximityPrompt") :: ProximityPrompt
	local tableHighlight = tableModel:FindFirstChild("Highlight")
	local highlightOutlineTransparency = DEFAULT_HIGHLIGHT_OUTLINE
	if tableHighlight and tableHighlight:IsA("Highlight") then
		highlightOutlineTransparency = tableHighlight.OutlineTransparency
	end

	local chairs: { Model } = {}
	local seats: { BasePart } = {}

	for _, child in ipairs(tableModel:GetChildren()) do
		if child:IsA("Model") and child.Name == "chair" then
			local seat = child:FindFirstChild("Seat", true)
			if seat then
				table.insert(chairs, child)
				table.insert(seats, seat)
			end
		end
	end

	print("[TableGame] Table:", tableModel.Name, "| Chairs:", #chairs, "| Seats:", #seats)

	local state = {
		model = tableModel,
		prompt = prompt,
		chairs = chairs,
		seats = seats,
		phase = "idle",
		host = nil,
		hostChairIndex = nil,
		seatedPlayers = {},
		gameSettings = nil,
		visibleChairIndices = {},
		highlight = (tableHighlight and tableHighlight:IsA("Highlight")) and tableHighlight or nil,
		highlightOutlineTransparency = highlightOutlineTransparency,
	}

	tableStates[tableModel] = state
	showDefaultChairs(state)
	setTableHighlightVisible(state, true)

	-- ── ProximityPrompt ────────────────────────────────────────────────────────
	prompt.Triggered:Connect(function(player: Player)
		print("[TableGame] Prompt triggered:", player.Name, "| table phase:", state.phase)

		if not getUsableHumanoid(player) then
			print("[TableGame] Ignoring prompt from dead/unready player:", player.Name)
			return
		end

		if state.seatedPlayers[player] then
			return
		end
		-- Ignore if player is seated at a DIFFERENT table
		local mappedTable = playerTableMap[player]
		if mappedTable then
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local seatPart = humanoid and humanoid.SeatPart
			local stillSeatedAtMapped = seatPart ~= nil and seatPart:IsDescendantOf(mappedTable)

			if stillSeatedAtMapped then
				return
			end

			-- Cleanup stale mapping so stuck players can interact again.
			playerTableMap[player] = nil
			local mappedState = tableStates[mappedTable]
			if mappedState then
				mappedState.seatedPlayers[player] = nil
			end
		end

		if state.phase == "idle" then -- Sanity check: if there are leftover seated players, reset first
			if next(state.seatedPlayers) ~= nil then
				print(
					"[TableGame] WARNING: Table",
					state.model.Name,
					"has seated players but phase is idle! Resetting..."
				)
				fullReset(state)
			end
			local chosenIndex = math.random(1, #state.chairs)
			state.hostChairIndex = chosenIndex
			applyChairVisibility(state, { chosenIndex })
			state.host = player
			state.phase = "setup"
			if not sitPlayer(state, player, chosenIndex) then
				fullReset(state)
				return
			end
			state.prompt.ActionText = "Host is setting up..."
			state.prompt.KeyboardKeyCode = Enum.KeyCode.Unknown
			refreshAllPrompts(state)
		elseif state.phase == "lobby" then
			local available = getAvailableVisible(state)
			if #available == 0 then
				return
			end
			local chosenIndex = available[math.random(1, #available)]
			if not sitPlayer(state, player, chosenIndex) then
				return
			end
			refreshAllPrompts(state)
			broadcastLobbyUpdate(state)
		end
	end)
end

-- ── Remote handlers ────────────────────────────────────────────────────────────

-- Helper: get the state for the table a player is seated at
local function getStateForPlayer(player: Player)
	local tableModel = playerTableMap[player]
	if not tableModel then
		return nil
	end
	return tableStates[tableModel]
end

hostConfirmedEvent.OnServerEvent:Connect(function(player, gameType, playerCount)
	local state = getStateForPlayer(player)
	if not state then
		print("[TableGame] Host confirmed FAILED: No state found for player", player.Name)
		return
	end
	if player ~= state.host then
		print(
			"[TableGame] Host confirmed FAILED: Player",
			player.Name,
			"is not the host. Host is",
			state.host and state.host.Name or "nil"
		)
		return
	end
	if state.phase ~= "setup" then
		print("[TableGame] Host confirmed FAILED: Table is in phase", state.phase, "not setup")
		return
	end
	if not state.seatedPlayers[player] then
		print("[TableGame] Host confirmed FAILED: Player", player.Name, "is not seated")
		return
	end
	print("[TableGame] Host confirmed:", gameType, playerCount)

	state.gameSettings = { gameType = gameType, playerCount = playerCount }

	-- Pick visible chairs
	local otherIndices = {}
	for i = 1, #state.chairs do
		if i ~= state.hostChairIndex then
			table.insert(otherIndices, i)
		end
	end
	for i = #otherIndices, 2, -1 do
		local j = math.random(1, i)
		otherIndices[i], otherIndices[j] = otherIndices[j], otherIndices[i]
	end
	local visIndices = { state.hostChairIndex }
	for i = 1, math.min(playerCount - 1, #otherIndices) do
		table.insert(visIndices, otherIndices[i])
	end
	applyChairVisibility(state, visIndices)

	state.phase = "lobby"
	state.prompt.ActionText = "Join game"
	state.prompt.KeyboardKeyCode = Enum.KeyCode.E
	refreshAllPrompts(state)
	broadcastLobbyUpdate(state)
end)

hostStartEvent.OnServerEvent:Connect(function(player)
	local state = getStateForPlayer(player)
	if not state or player ~= state.host then
		return
	end
	if not state.gameSettings then
		return
	end
	print("[TableGame] Game starting!")
	state.phase = "game"
	state.prompt.Enabled = false
	setTableHighlightVisible(state, false)

	-- Build clean ordered array: host first, then guests
	local orderedPlayers: { Player } = {}
	table.insert(orderedPlayers, state.host)
	for p in pairs(state.seatedPlayers) do
		if p ~= state.host then
			table.insert(orderedPlayers, p)
		end
	end
	print("[TableGame] Players in game:", #orderedPlayers)
	for i, p in ipairs(orderedPlayers) do
		print("[TableGame]  Slot", i, "->", p.Name)
	end

	print("[TableGame] Firing BuildRoom...")
	buildRoomEvent:Fire(state.model, orderedPlayers, state.gameSettings.gameType, "Default")
	print("[TableGame] BuildRoom fired")
end)

cancelEvent.OnServerEvent:Connect(function(player)
	local state = getStateForPlayer(player)
	if not state then
		return
	end
	print("[TableGame] Cancel from:", player.Name)
	if player == state.host then
		fullReset(state)
	else
		-- Guest cancelling: only remove themselves, don't affect others
		state.seatedPlayers[player] = nil
		playerTableMap[player] = nil
		if state.phase == "game" then
			removeRoomPlayerEvent:Fire(state.model, player)
		end
		local char = player.Character
		if char then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.Sit = false
			end
		end
		if state.phase == "lobby" then
			broadcastLobbyUpdate(state)
		end
		refreshAllPrompts(state)
	end
end)

-- ── Watch humanoids ────────────────────────────────────────────────────────────
local function watchHumanoid(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Seated:Connect(function(isSeated: boolean)
		if isSeated then
			return
		end
		local state = getStateForPlayer(player)
		if not state then
			return
		end
		if state.seatedPlayers[player] == nil then
			return
		end

		state.seatedPlayers[player] = nil
		playerTableMap[player] = nil
		print("[TableGame]", player.Name, "stood up | phase:", state.phase)

		if player == state.host then
			-- Host leaving always causes a full reset regardless of phase
			fullReset(state)
		else
			-- Guest leaving: update lobby list only if in lobby phase
			-- In game phase: silently remove them, everyone else continues
			if state.phase == "lobby" then
				broadcastLobbyUpdate(state)
				refreshAllPrompts(state)
			elseif state.phase == "game" then
				removeRoomPlayerEvent:Fire(state.model, player)
			end
			-- game phase: no action, game continues for remaining players
		end
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	if player.Character then
		watchHumanoid(player, player.Character)
	end
	player.CharacterAdded:Connect(function(c)
		watchHumanoid(player, c)
	end)
end

Players.PlayerAdded:Connect(function(player)
	-- Send idle state for all tables on join
	for _, state in pairs(tableStates) do
		updatePromptEvent:FireClient(player, state.model, state.phase, false, state.gameSettings)
	end
	player.CharacterAdded:Connect(function(c)
		watchHumanoid(player, c)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	local state = getStateForPlayer(player)
	if not state then
		return
	end
	state.seatedPlayers[player] = nil
	playerTableMap[player] = nil
	if player == state.host then
		fullReset(state)
	else
		if state.phase == "lobby" then
			broadcastLobbyUpdate(state)
		elseif state.phase == "game" then
			removeRoomPlayerEvent:Fire(state.model, player)
		end
		if state.phase ~= "game" then
			refreshAllPrompts(state)
		end
	end
end)

-- ── Listen for game end (room destroyed) ──────────────────────────────────────
gameEndedEvent.Event:Connect(function(tableModel: Model)
	local state = tableStates[tableModel]
	if state then
		print("[TableGame] Game ended for", tableModel.Name, "- resetting phase to idle")
		-- Unseat all players and reset to idle
		fullReset(state)
	end
end)

-- ── Boot: initialise all tables in the folder ──────────────────────────────────
for _, tableModel in ipairs(tablesFolder:GetChildren()) do
	if tableModel:IsA("Model") then
		initTable(tableModel)
	end
end

-- Also handle tables added at runtime (e.g. dynamically spawned)
tablesFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		initTable(child)
	end
end)

print("[TableGame] Server ready —", #tablesFolder:GetChildren(), "table(s) found")
