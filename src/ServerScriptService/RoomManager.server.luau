-- RoomManager (Script)
-- Place inside: ServerScriptService
--
-- Handles spawning hidden game rooms far off in the world,
-- cloning player avatars into seats, and cleaning up on game end.
--
-- ReplicatedStorage structure expected:
--   ReplicatedStorage
--   └── TableGames
--         └── Assets
--               └── Rooms
--                     └── Default (Model)
--                           ├── FloorCenter (BasePart, transparent)
--                           └── Seats (Folder)
--                                 ├── Seat_1 (Model) → has Seat (BasePart) inside
--                                 ├── Seat_2
--                                 └── ... up to Seat_8

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Remotes (created by TableGameServer, we just reference them) ───────────────
local remotesFolder = ReplicatedStorage:WaitForChild("TableGameRemotes")
local gameStartingEvent = remotesFolder:WaitForChild("GameStarting")

-- New remotes for room system
local roomReadyEvent = Instance.new("RemoteEvent")
roomReadyEvent.Name = "RoomReady"
roomReadyEvent.Parent = remotesFolder
-- Args fired to each player: (roomModel, seatCFrame, allSeatCFrames, playerIndex, physicalTable)

local leaveRoomEvent = Instance.new("RemoteEvent")
leaveRoomEvent.Name = "LeaveRoom"
leaveRoomEvent.Parent = remotesFolder

-- Client → Server: player's camera look direction (for head tracking)
local headLookEvent = Instance.new("RemoteEvent")
headLookEvent.Name = "HeadLook"
headLookEvent.Parent = remotesFolder
-- Args: (lookCFrame: CFrame)

-- ── Assets ─────────────────────────────────────────────────────────────────────
local roomsFolder = ReplicatedStorage:WaitForChild("TableGames"):WaitForChild("Assets"):WaitForChild("Rooms")

-- ── Room tracking ──────────────────────────────────────────────────────────────
-- Keyed by the physical tableModel they belong to
local activeRooms: {
	[Model]: {
		roomClone: Model,
		playerClones: { [Player]: Model }, -- player → their avatar clone in the room
		playerSeats: { [Player]: Model }, -- player → their seat model in this room
		seatModels: { Model }, -- ordered seat models used in this room
		slotKey: string,
	},
} =
	{}

local roomSerial = 0
local ROOM_STEP = 400
local ROOM_SIZE = 72
local WALL_HEIGHT = 18

local ROOM_DIRECTIONS = {
	Vector3.new(0, 0, 1), -- North
	Vector3.new(0, 0, -1), -- South
	Vector3.new(-1, 0, 0), -- West
	Vector3.new(1, 0, 0), -- East
	Vector3.new(0, 1, 0), -- Up
	Vector3.new(0, -1, 0), -- Down
}

local occupiedSlots: { [string]: Model } = {}

local function makeSlotKey(directionIndex: number): string
	return tostring(directionIndex)
end

local function allocateRoomSlot(physicalTable: Model): (string?, Vector3?)
	for directionIndex, directionUnit in ipairs(ROOM_DIRECTIONS) do
		local slotKey = makeSlotKey(directionIndex)
		if occupiedSlots[slotKey] == nil then
			occupiedSlots[slotKey] = physicalTable
			return slotKey, directionUnit * ROOM_STEP
		end
	end
	return nil, nil
end

local function releaseRoomSlot(slotKey: string?)
	if not slotKey then
		return
	end
	occupiedSlots[slotKey] = nil
end

-- ── Evenly spaced seat selection ───────────────────────────────────────────────
local TOTAL_SEATS = 8

local function getEvenlySpacedIndices(playerCount: number): { number }
	local indices = {}
	for i = 1, playerCount do
		local index = math.round((i - 1) * TOTAL_SEATS / playerCount) + 1
		table.insert(indices, index)
	end
	return indices
end

-- ── Get all seat models from the room in order ─────────────────────────────────
local function getSeatModels(roomClone: Model): { Model }
	local seatsFolder = roomClone:FindFirstChild("Seats")
	if not seatsFolder then
		warn("[RoomManager] No 'Seats' folder found in room model")
		return {}
	end
	local ordered = {}
	for i = 1, TOTAL_SEATS do
		local seat = seatsFolder:FindFirstChild("Seat_" .. i)
		if seat then
			table.insert(ordered, seat)
		else
			warn("[RoomManager] Missing Seat_" .. i)
		end
	end
	return ordered
end

-- ── Clone a player's full avatar ───────────────────────────────────────────────
local function cloneAvatar(player: Player): Model?
	local char = player.Character
	if not char then
		warn("[RoomManager] cloneAvatar: no character for", player.Name)
		return nil
	end

	-- Wait for character to fully load before cloning
	if not char:FindFirstChild("HumanoidRootPart") then
		char:WaitForChild("HumanoidRootPart", 5)
	end
	if not char:FindFirstChild("Humanoid") then
		char:WaitForChild("Humanoid", 5)
	end
	if not char:FindFirstChild("Head") then
		char:WaitForChild("Head", 5)
	end

	local wasArchivable = char.Archivable
	char.Archivable = true
	local clone = char:Clone()
	char.Archivable = wasArchivable
	if not clone then
		warn("[RoomManager] cloneAvatar: char:Clone() returned nil for", player.Name)
		return nil
	end

	clone.Name = "Clone_" .. player.Name

	-- Remove scripts from clone so it doesn't interfere
	for _, obj in ipairs(clone:GetDescendants()) do
		if obj:IsA("Script") or obj:IsA("LocalScript") or obj:IsA("ModuleScript") then
			obj:Destroy()
		end
	end

	-- Disable the humanoid so it doesn't move on its own
	local hum = clone:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.AutoRotate = false
	end

	-- Remove default nameplate
	local overhead = clone:FindFirstChild("Head") and clone.Head:FindFirstChild("Overhead")
	if overhead then
		overhead:Destroy()
	end

	return clone
end

local function applyLookToClone(clone: Model, lookCFrame: CFrame)
	local pitch, yaw = lookCFrame:ToOrientation()
	local neck = clone:FindFirstChild("Neck", true)
	if neck and neck:IsA("Motor6D") then
		neck.Transform = CFrame.Angles(math.clamp(pitch, -0.7, 0.7), math.clamp(yaw, -0.9, 0.9), 0)
		return
	end

	local head = clone:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		head.CFrame = CFrame.new(head.Position)
			* CFrame.Angles(math.clamp(pitch, -0.7, 0.7), math.clamp(yaw, -0.9, 0.9), 0)
	end
end

-- ── Sit a clone avatar into a seat ─────────────────────────────────────────────
local function sitCloneInSeat(clone: Model, seatModel: Model)
	local seat = seatModel:FindFirstChild("Seat", true) :: BasePart?
	if not seat then
		warn("[RoomManager] Seat BasePart not found in", seatModel.Name)
		return
	end

	-- Position the clone's HumanoidRootPart at the seat's CFrame
	local hrp = clone:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Sit offset: slightly above the seat surface
	clone:SetPrimaryPartCFrame(seat.CFrame * CFrame.new(0, 0.5, 0))

	local hum = clone:FindFirstChildOfClass("Humanoid")
	if hum then
		seat:Sit(hum)
	end
end

-- ── Show/hide seat chair visuals ───────────────────────────────────────────────
local function setSeatChairVisible(seatModel: Model, visible: boolean)
	for _, part in ipairs(seatModel:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "Seat" then
			part.Transparency = visible and 0 or 1
			part.CanCollide = visible and true or false
		end
	end
	-- Seat BasePart always stays invisible/non-collidable
	local seat = seatModel:FindFirstChild("Seat", true)
	if seat and seat:IsA("BasePart") then
		seat.Transparency = 1
		seat.CanCollide = false
	end
end

local function createFallbackRoom(offset: Vector3, playerCount: number): Model
	local roomModel = Instance.new("Model")
	roomModel.Name = "GameRoom_Fallback"
	roomModel.Parent = workspace

	local floorCenter = Instance.new("Part")
	floorCenter.Name = "FloorCenter"
	floorCenter.Anchored = true
	floorCenter.CanCollide = false
	floorCenter.Transparency = 1
	floorCenter.Size = Vector3.new(2, 1, 2)
	floorCenter.CFrame = CFrame.new(offset)
	floorCenter.Parent = roomModel

	local floor = Instance.new("Part")
	floor.Name = "Floor"
	floor.Anchored = true
	floor.Size = Vector3.new(ROOM_SIZE, 1, ROOM_SIZE)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Color = Color3.fromRGB(35, 35, 42)
	floor.CFrame = CFrame.new(offset - Vector3.new(0, 4, 0))
	floor.Parent = roomModel

	local wallColor = Color3.fromRGB(24, 24, 30)
	local halfSize = ROOM_SIZE / 2
	local wallThickness = 2

	local wallSpecs = {
		{
			size = Vector3.new(ROOM_SIZE, WALL_HEIGHT, wallThickness),
			cf = CFrame.new(offset + Vector3.new(0, WALL_HEIGHT / 2 - 4, -halfSize)),
		},
		{
			size = Vector3.new(ROOM_SIZE, WALL_HEIGHT, wallThickness),
			cf = CFrame.new(offset + Vector3.new(0, WALL_HEIGHT / 2 - 4, halfSize)),
		},
		{
			size = Vector3.new(wallThickness, WALL_HEIGHT, ROOM_SIZE),
			cf = CFrame.new(offset + Vector3.new(-halfSize, WALL_HEIGHT / 2 - 4, 0)),
		},
		{
			size = Vector3.new(wallThickness, WALL_HEIGHT, ROOM_SIZE),
			cf = CFrame.new(offset + Vector3.new(halfSize, WALL_HEIGHT / 2 - 4, 0)),
		},
	}

	for _, spec in ipairs(wallSpecs) do
		local wall = Instance.new("Part")
		wall.Anchored = true
		wall.Size = spec.size
		wall.Material = Enum.Material.SmoothPlastic
		wall.Color = wallColor
		wall.CFrame = spec.cf
		wall.Parent = roomModel
	end

	local seatsFolder = Instance.new("Folder")
	seatsFolder.Name = "Seats"
	seatsFolder.Parent = roomModel

	local seatCount = math.max(TOTAL_SEATS, playerCount)
	for i = 1, seatCount do
		local seatModel = Instance.new("Model")
		seatModel.Name = "Seat_" .. i
		seatModel.Parent = seatsFolder

		local seat = Instance.new("Seat")
		seat.Name = "Seat"
		seat.Anchored = true
		seat.Size = Vector3.new(2, 1, 2)
		seat.Transparency = 1
		seat.CanCollide = false

		local angle = (i - 1) / seatCount * math.pi * 2
		local radius = 20
		local seatPos = offset + Vector3.new(math.cos(angle) * radius, -3, math.sin(angle) * radius)
		seat.CFrame = CFrame.new(seatPos)
		seat.Parent = seatModel
	end

	return roomModel
end

local function findRoomTemplate(themeName: string): Model?
	local directChild = roomsFolder:FindFirstChild(themeName)
	if directChild and directChild:IsA("Model") then
		print("[RoomManager] Found room template directly:", directChild:GetFullName())
		return directChild
	end

	local recursiveChild = roomsFolder:FindFirstChild(themeName, true)
	if recursiveChild and recursiveChild:IsA("Model") then
		print("[RoomManager] Found room template recursively:", recursiveChild:GetFullName())
		return recursiveChild
	end

	warn("[RoomManager] Could not find room template named:", themeName, "under", roomsFolder:GetFullName())
	return nil
end

-- ── Build the hidden room ──────────────────────────────────────────────────────
local function buildRoom(physicalTable: Model, seatedPlayers: { Player }, gameType: string, themeName: string?)
	local resolvedTheme: string = themeName or "Default"
	print("[RoomManager] buildRoom called | theme:", resolvedTheme, "| players:", #seatedPlayers, "| gameType:", gameType)

	for i, p in ipairs(seatedPlayers) do
		print("[RoomManager]  Player", i, "->", type(p) == "userdata" and p.Name or tostring(p))
	end

	local template = findRoomTemplate(resolvedTheme)
	if not template then
		warn("[RoomManager] Room theme not found:", resolvedTheme, "- using fallback room")
	else
		print("[RoomManager] Cloning room template:", template:GetFullName())
	end

	local slotKey, offset = allocateRoomSlot(physicalTable)
	if not slotKey or not offset then
		warn("[RoomManager] No room slot available. Max concurrent game rooms reached (6).")
		return
	end
	roomSerial += 1

	-- Clone the whole room model when available, otherwise generate a fallback room
	local roomClone: Model
	if template then
		roomClone = template:Clone()
		roomClone.Name = "GameRoom_" .. roomSerial
		roomClone.Parent = workspace
		print("[RoomManager] Room clone parented:", roomClone:GetFullName())
	else
		roomClone = createFallbackRoom(offset, #seatedPlayers)
		print("[RoomManager] Fallback room created:", roomClone:GetFullName())
	end

	local roomHasVisibleContent = false
	for _, descendant in ipairs(roomClone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			roomHasVisibleContent = true
			break
		end
	end

	if not roomHasVisibleContent then
		warn("[RoomManager] Room clone had no contents - replacing with fallback room")
		roomClone:Destroy()
		roomClone = createFallbackRoom(offset, #seatedPlayers)
		print("[RoomManager] Fallback room replaced empty clone:", roomClone:GetFullName())
	end

	-- Move room to far-off position using FloorCenter as origin
	local floorCenter = roomClone:FindFirstChild("FloorCenter") :: BasePart?
	if floorCenter then
		local currentPos = floorCenter.Position
		local delta = offset - currentPos
		-- Move every BasePart by the delta
		for _, part in ipairs(roomClone:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CFrame = part.CFrame + delta
			end
		end
	else
		warn("[RoomManager] No FloorCenter found in room — using model position")
		roomClone:PivotTo(CFrame.new(offset))
	end

	-- Get all seat models in order
	local allSeatModels = getSeatModels(roomClone)
	print("[RoomManager] Seat models discovered:", #allSeatModels, "from", roomClone:GetFullName())

	-- Pick evenly spaced seats based on player count
	local playerCount = #seatedPlayers
	local chosenIndices = getEvenlySpacedIndices(playerCount)

	-- Hide all seats first
	for _, seatModel in ipairs(allSeatModels) do
		setSeatChairVisible(seatModel, false)
	end

	-- Show and populate only the chosen seats
	local usedSeats: { Model } = {}
	local playerClones: { [Player]: Model } = {}
	local playerSeats: { [Player]: Model } = {}
	local seatCFrames: { CFrame } = {}

	for i, seatIndex in ipairs(chosenIndices) do
		local seatModel = allSeatModels[seatIndex]
		if not seatModel then
			warn("[RoomManager] No seat model at index", seatIndex)
			continue
		end

		setSeatChairVisible(seatModel, true)

		local seatPart = seatModel:FindFirstChild("Seat", true) :: BasePart?
		if seatPart then
			table.insert(seatCFrames, seatPart.CFrame * CFrame.new(0, 0.5, 0))
			print("[RoomManager] Seat", i, "CFrame set at", seatPart.Position)
		else
			warn("[RoomManager] No Seat BasePart in", seatModel.Name)
			-- Still push a placeholder so indices stay aligned
			table.insert(seatCFrames, CFrame.new(offset))
		end

		local p = seatedPlayers[i]
		if not p then
			warn("[RoomManager] No player at slot", i)
			continue
		end
		playerSeats[p] = seatModel
		print("[RoomManager] Cloning avatar for", p.Name)
		if not p.Character then
			warn("[RoomManager]", p.Name, "has no character yet")
			continue
		end

		local clone = cloneAvatar(p)
		if clone then
			clone.Parent = roomClone
			sitCloneInSeat(clone, seatModel)
			playerClones[p] = clone
			print("[RoomManager] Clone placed for", p.Name)
		end

		table.insert(usedSeats, seatModel)
	end

	-- Load game-specific assets (deck, chips, etc.)
	-- Convert spaces to underscores to match folder naming (e.g. "Flip 7" → "Flip_7")
	local gameAssetName = gameType:gsub(" ", "_")
	local gameAssetFolder = ReplicatedStorage:FindFirstChild("TableGames")
		and ReplicatedStorage.TableGames:FindFirstChild("Assets")
		and ReplicatedStorage.TableGames.Assets:FindFirstChild("GameAssets")
		and ReplicatedStorage.TableGames.Assets.GameAssets:FindFirstChild(gameAssetName)

	if gameAssetFolder then
		print("[RoomManager] Loading game assets for:", gameType)
		local deckModel = gameAssetFolder:FindFirstChild("Deck")
		if deckModel then
			local deckClone = deckModel:Clone()
			deckClone.Parent = roomClone

			-- Position deck at DeckPosition marker with upward offset
			local deckPosition = roomClone:FindFirstChild("DeckPosition")
			if deckPosition then
				-- Position deck's pivot point directly on DeckPosition
				deckClone:PivotTo(deckPosition.CFrame)
				print("[RoomManager] Deck positioned at DeckPosition")
			else
				warn("[RoomManager] DeckPosition not found in room")
			end
		else
			warn("[RoomManager] Deck model not found in", gameType, "assets")
		end
	else
		warn("[RoomManager] Game assets folder not found for:", gameType)
	end

	-- Store room state
	activeRooms[physicalTable] = {
		roomClone = roomClone,
		playerClones = playerClones,
		playerSeats = playerSeats,
		seatModels = usedSeats,
		slotKey = slotKey,
	}

	-- Fire each player with their specific seat CFrame and index
	for i, p in ipairs(seatedPlayers) do
		local mySeatCFrame = seatCFrames[i] or CFrame.new(offset)
		roomReadyEvent:FireClient(p, roomClone, mySeatCFrame, seatCFrames, i, physicalTable)
	end

	print("[RoomManager] Room built for", playerCount, "players | theme:", resolvedTheme)
	local finalMarker = roomClone:FindFirstChild("FloorCenter") :: BasePart?
	if finalMarker then
		print("[RoomManager] Final room location:", finalMarker.Position)
	else
		local anyPart = roomClone:FindFirstChildWhichIsA("BasePart", true)
		if anyPart then
			print("[RoomManager] Final room location:", anyPart.Position)
		end
	end
end

-- ── Tear down a room ───────────────────────────────────────────────────────────
local function destroyRoom(physicalTable: Model)
	local room = activeRooms[physicalTable]
	if not room then
		return
	end

	-- Fire all players to return to normal POV
	for p in pairs(room.playerClones) do
		leaveRoomEvent:FireClient(p)
	end

	-- Destroy the room clone
	if room.roomClone and room.roomClone.Parent then
		room.roomClone:Destroy()
	end
	releaseRoomSlot(room.slotKey)

	activeRooms[physicalTable] = nil
	print("[RoomManager] Room destroyed")

	-- Signal back to TableGameServer that the game ended so the table can reset
	local gameEndedEvent = remotesFolder:FindFirstChild("GameEnded")
	if gameEndedEvent then
		gameEndedEvent:Fire(physicalTable)
	end
end

local function removePlayerFromRoom(physicalTable: Model, player: Player)
	local room = activeRooms[physicalTable]
	if not room then
		return
	end

	local clone = room.playerClones[player]
	if clone and clone.Parent then
		clone:Destroy()
	end
	room.playerClones[player] = nil

	local seatModel = room.playerSeats[player]
	if seatModel then
		setSeatChairVisible(seatModel, false)
		for index, usedSeat in ipairs(room.seatModels) do
			if usedSeat == seatModel then
				table.remove(room.seatModels, index)
				break
			end
		end
	end
	room.playerSeats[player] = nil

	leaveRoomEvent:FireClient(player)
	print("[RoomManager] Removed player visuals for", player.Name, "from", physicalTable.Name)
end

-- ── Head tracking: client sends look direction, server applies to clone head ───
headLookEvent.OnServerEvent:Connect(function(player: Player, lookCFrame: CFrame)
	-- Find which room this player is in
	for _, room in pairs(activeRooms) do
		local clone = room.playerClones[player]
		if clone then
			applyLookToClone(clone, lookCFrame)
			break
		end
	end
end)

-- ── Listen for game starting (fired by TableGameServer) ────────────────────────
-- We intercept by connecting to the same remote and building the room
-- TableGameServer fires: (player, tableModel, gameType, playerCount)
-- We need the full player list so we hook into it differently —
-- TableGameServer calls us via a BindableEvent

local roomBuildEvent = remotesFolder:WaitForChild("BuildRoom")
local roomDestroyEvent = remotesFolder:WaitForChild("DestroyRoom")
local roomRemovePlayerEvent = remotesFolder:WaitForChild("RemoveRoomPlayer")

print("[RoomManager] Found BindableEvents, connecting...")

roomBuildEvent.Event:Connect(
	function(physicalTable: Model, seatedPlayers: { Player }, gameType: string, themeName: string?)
		print("[RoomManager] BuildRoom fired for", #seatedPlayers, "players")
		buildRoom(physicalTable, seatedPlayers, gameType, themeName)
	end
)

roomDestroyEvent.Event:Connect(function(physicalTable: Model)
	print("[RoomManager] DestroyRoom fired")
	destroyRoom(physicalTable)
end)

roomRemovePlayerEvent.Event:Connect(function(physicalTable: Model, player: Player)
	print("[RoomManager] RemoveRoomPlayer fired for", player.Name)
	removePlayerFromRoom(physicalTable, player)
end)

print("[RoomManager] Ready")
