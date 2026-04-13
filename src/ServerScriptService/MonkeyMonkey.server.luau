-- MonkeyMonkey.server.luau
-- Monkey-Monkey (Unggoy-Unggoy) card game server
-- Place inside: ServerScriptService
--
-- Game rules:
--   52 cards + 1 unmatchable Monkey card dealt to all players.
--   Each player discards initial rank pairs from their hand.
--   On your turn: draw one card from your right neighbour (next in active list).
--   Discard any new pairs formed. Empty hand → you are safe, exit active list.
--   Last player remaining holds the Monkey and loses.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Wait for TableGameServer remotes ──────────────────────────────────────────
local remotesFolder = ReplicatedStorage:WaitForChild("TableGameRemotes")
local buildRoomEvent = remotesFolder:WaitForChild("BuildRoom")

-- ── Create MonkeyMonkey-specific remotes ──────────────────────────────────────
local mmFolder = Instance.new("Folder")
mmFolder.Name = "MonkeyMonkeyRemotes"
mmFolder.Parent = ReplicatedStorage

local gameStateEvent = Instance.new("RemoteEvent")
gameStateEvent.Name = "GameState"
gameStateEvent.Parent = mmFolder

local drawCardEvent = Instance.new("RemoteEvent")
drawCardEvent.Name = "DrawCard"
drawCardEvent.Parent = mmFolder

local gameOverEvent = Instance.new("RemoteEvent")
gameOverEvent.Name = "GameOver"
gameOverEvent.Parent = mmFolder

-- ── Card definitions ──────────────────────────────────────────────────────────
local SUITS = { "S", "H", "D", "C" }
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local MONKEY = "MONKEY"

local function buildDeck(): { string }
	local deck = {}
	for _, suit in ipairs(SUITS) do
		for _, rank in ipairs(RANKS) do
			table.insert(deck, rank .. "_" .. suit)
		end
	end
	table.insert(deck, MONKEY)
	return deck
end

local function shuffle(t: { string }): { string }
	local d = table.clone(t)
	for i = #d, 2, -1 do
		local j = math.random(1, i)
		d[i], d[j] = d[j], d[i]
	end
	return d
end

local function getCardRank(card: string): string
	if card == MONKEY then
		return MONKEY
	end
	return card:match("^(.-)_") or card
end

-- Remove pairs (by rank) from a hand; Monkey card is never matched.
local function discardPairs(hand: { string }): { string }
	local rankIndices: { [string]: { number } } = {}
	for i, card in ipairs(hand) do
		local rank = getCardRank(card)
		if not rankIndices[rank] then
			rankIndices[rank] = {}
		end
		table.insert(rankIndices[rank], i)
	end

	local toRemove: { [number]: boolean } = {}
	for rank, indices in pairs(rankIndices) do
		if rank ~= MONKEY then
			local pairCount = math.floor(#indices / 2)
			for p = 1, pairCount do
				toRemove[indices[p * 2 - 1]] = true
				toRemove[indices[p * 2]] = true
			end
		end
	end

	local newHand = {}
	for i, card in ipairs(hand) do
		if not toRemove[i] then
			table.insert(newHand, card)
		end
	end
	return newHand
end

-- ── Active game records ───────────────────────────────────────────────────────
-- Keyed by the physical tableModel instance.
-- g = {
--   physicalTable: Model,
--   orderedPlayers: {Player},   -- full list, never changes
--   activePlayers:  {Player},   -- players still holding cards
--   currentPlayer:  Player,     -- whose turn it is
--   hands:          {[Player]: {string}},
--   phase:          "playing" | "gameover",
-- }
local activeGames: { [Model]: any } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Return index of p in activePlayers, or nil.
local function activeIndex(g, p: Player): number?
	for i, ap in ipairs(g.activePlayers) do
		if ap == p then
			return i
		end
	end
	return nil
end

-- The right neighbour of currentPlayer (next in activePlayers, wrapping).
local function getRightNeighbour(g): Player?
	local idx = activeIndex(g, g.currentPlayer)
	if not idx or #g.activePlayers < 2 then
		return nil
	end
	local nextIdx = (idx % #g.activePlayers) + 1
	return g.activePlayers[nextIdx]
end

-- Advance currentPlayer to the next in activePlayers after `afterPlayer`.
local function advanceCurrentPlayer(g, afterPlayer: Player)
	local idx = activeIndex(g, afterPlayer)
	if not idx or #g.activePlayers == 0 then
		return
	end
	local nextIdx = (idx % #g.activePlayers) + 1
	g.currentPlayer = g.activePlayers[nextIdx]
end

-- Remove a player from activePlayers; returns true if the removed player WAS
-- the current player (so caller must pick a new one).
local function removeFromActive(g, p: Player): boolean
	local idx = activeIndex(g, p)
	if not idx then
		return false
	end
	local wasCurrent = g.currentPlayer == p
	table.remove(g.activePlayers, idx)
	return wasCurrent
end

-- ── State broadcast ───────────────────────────────────────────────────────────
local function broadcastState(g)
	local summaries = {}
	for _, p in ipairs(g.orderedPlayers) do
		local hand = g.hands[p]
		local isActive = activeIndex(g, p) ~= nil
		table.insert(summaries, {
			name = p.Name,
			cardCount = hand and #hand or 0,
			isActive = isActive,
		})
	end

	local currentTurnName = g.currentPlayer and g.currentPlayer.Name or ""

	local rightNeighbour = getRightNeighbour(g)
	local rightNeighbourName = rightNeighbour and rightNeighbour.Name or ""
	local rightNeighbourCardCount = rightNeighbour and #(g.hands[rightNeighbour] or {}) or 0

	for _, p in ipairs(g.orderedPlayers) do
		local myHand = g.hands[p] or {}

		-- Only the current player sees the draw-area neighbour count.
		local drawCount = (p == g.currentPlayer) and rightNeighbourCardCount or 0

		gameStateEvent:FireClient(p, {
			players = summaries,
			myHand = myHand,
			currentTurnName = currentTurnName,
			rightNeighbourName = rightNeighbourName,
			rightNeighbourCardCount = drawCount,
			phase = g.phase,
		})
	end
end

-- ── Game-over check ───────────────────────────────────────────────────────────
local function checkGameOver(g): boolean
	if #g.activePlayers <= 1 then
		g.phase = "gameover"
		local loser = g.activePlayers[1]
		local loserName = loser and loser.Name or "?"

		-- Final state broadcast (so UI can show hands)
		broadcastState(g)

		for _, p in ipairs(g.orderedPlayers) do
			gameOverEvent:FireClient(p, loserName)
		end

		-- Let the room/table system clean up after a delay
		task.delay(6, function()
			local gameEndedEvent = remotesFolder:FindFirstChild("GameEnded")
			if gameEndedEvent then
				gameEndedEvent:Fire(g.physicalTable)
			end
			activeGames[g.physicalTable] = nil
		end)

		print("[MonkeyMonkey] Game over — loser:", loserName)
		return true
	end
	return false
end

-- ── Remove an empty-hand player from active list and fix currentPlayer ────────
-- Returns true when the game is over after removal.
local function processEmptyHand(g, p: Player): boolean
	if #(g.hands[p] or {}) > 0 then
		return false
	end

	print("[MonkeyMonkey]", p.Name, "hand empty — safe!")
	local wasCurrent = removeFromActive(g, p)

	if checkGameOver(g) then
		return true
	end

	-- If the emptied player was the current one, pick the player who is now at
	-- the same slot (which is whoever slid into that index after removal).
	if wasCurrent then
		local idx = activeIndex(g, g.currentPlayer)
		if not idx then
			-- currentPlayer was removed; pick index 1 or fallback
			g.currentPlayer = g.activePlayers[1]
		end
		-- currentPlayer reference may be stale; repoint to index 1 as safe default
		-- (the previous advanceCurrentPlayer handles normal advancement)
	end

	return false
end

-- ── Start a new game ──────────────────────────────────────────────────────────
local function startGame(physicalTable: Model, players: { Player })
	print("[MonkeyMonkey] Starting —", #players, "players")

	local deck = shuffle(buildDeck())

	-- Deal round-robin
	local hands: { [Player]: { string } } = {}
	for _, p in ipairs(players) do
		hands[p] = {}
	end
	for i, card in ipairs(deck) do
		local p = players[((i - 1) % #players) + 1]
		table.insert(hands[p], card)
	end

	-- Initial pair discard for every player
	for _, p in ipairs(players) do
		hands[p] = discardPairs(hands[p])
		print("[MonkeyMonkey]", p.Name, "hand after initial discard:", #hands[p], "cards")
	end

	local g = {
		physicalTable = physicalTable,
		orderedPlayers = table.clone(players),
		activePlayers = table.clone(players),
		currentPlayer = players[1],
		hands = hands,
		phase = "playing",
	}
	activeGames[physicalTable] = g

	-- Remove any player who already has an empty hand (all pairs, rare but possible)
	local i = 1
	while i <= #g.activePlayers do
		local p = g.activePlayers[i]
		if #hands[p] == 0 then
			table.remove(g.activePlayers, i)
			print("[MonkeyMonkey]", p.Name, "already safe after deal")
		else
			i += 1
		end
	end

	if #g.activePlayers > 0 then
		g.currentPlayer = g.activePlayers[1]
	end

	if checkGameOver(g) then
		return
	end

	broadcastState(g)
	print("[MonkeyMonkey] State broadcast — turn:", g.currentPlayer.Name)
end

-- ── DrawCard handler ──────────────────────────────────────────────────────────
drawCardEvent.OnServerEvent:Connect(function(player: Player, cardIndex: number)
	-- Find the game this player belongs to
	local g: any = nil
	for _, game in pairs(activeGames) do
		for _, p in ipairs(game.orderedPlayers) do
			if p == player then
				g = game
				break
			end
		end
		if g then
			break
		end
	end

	if not g or g.phase ~= "playing" then
		return
	end
	if g.currentPlayer ~= player then
		return
	end

	local neighbour = getRightNeighbour(g)
	if not neighbour then
		return
	end

	local neighbourHand = g.hands[neighbour]
	if not neighbourHand or #neighbourHand == 0 then
		return
	end

	-- Validate index
	if typeof(cardIndex) ~= "number" or cardIndex < 1 or cardIndex > #neighbourHand then
		return
	end

	-- Transfer card
	local drawn = neighbourHand[cardIndex]
	table.remove(neighbourHand, cardIndex)
	table.insert(g.hands[player], drawn)
	print("[MonkeyMonkey]", player.Name, "drew", drawn, "from", neighbour.Name)

	-- Discard pairs from drawer's hand
	g.hands[player] = discardPairs(g.hands[player])

	-- Check if neighbour hand is now empty → they go safe
	if processEmptyHand(g, neighbour) then
		return
	end

	-- Check if drawer hand is now empty → they go safe too
	-- After processEmptyHand the current player reference might have advanced;
	-- we need to advance the turn to whoever comes after `player`.
	if #g.hands[player] == 0 then
		-- player is safe; advance to next before removing
		local nextAfterDrawer = getRightNeighbour(g) -- this is the player after `player` in current list
		-- We need to find who comes AFTER player in the list
		local drawerIdx = activeIndex(g, player)
		local successor: Player? = nil
		if drawerIdx then
			local succIdx = (drawerIdx % #g.activePlayers) + 1
			if g.activePlayers[succIdx] ~= player then
				successor = g.activePlayers[succIdx]
			end
		end
		removeFromActive(g, player)
		if checkGameOver(g) then
			return
		end
		-- Set current to successor if we found one and they're still active
		if successor and activeIndex(g, successor) then
			g.currentPlayer = successor
		else
			g.currentPlayer = g.activePlayers[1]
		end
	else
		-- Normal advance: next active player after the current drawer
		advanceCurrentPlayer(g, player)
	end

	if checkGameOver(g) then
		return
	end

	broadcastState(g)
end)

-- ── Listen for BuildRoom ──────────────────────────────────────────────────────
buildRoomEvent.Event:Connect(function(physicalTable: Model, players: { Player }, gameType: string)
	if gameType ~= "Monkey Monkey" then
		return
	end
	-- Small delay so RoomManager finishes building and fires RoomReady first
	task.delay(2.5, function()
		startGame(physicalTable, players)
	end)
end)

-- ── Handle player leaving mid-game ────────────────────────────────────────────
Players.PlayerRemoving:Connect(function(player: Player)
	for _, g in pairs(activeGames) do
		if g.phase ~= "playing" then
			continue
		end
		local idx = activeIndex(g, player)
		if not idx then
			continue
		end

		-- If this player was the current player, advance first
		local wasCurrent = g.currentPlayer == player
		local succIdx = (idx % #g.activePlayers) + 1
		local successor = (succIdx ~= idx) and g.activePlayers[succIdx] or nil

		removeFromActive(g, player)
		g.hands[player] = nil

		-- Remove from orderedPlayers so they don't receive future events
		for i, p in ipairs(g.orderedPlayers) do
			if p == player then
				table.remove(g.orderedPlayers, i)
				break
			end
		end

		if checkGameOver(g) then
			return
		end

		if wasCurrent and successor and activeIndex(g, successor) then
			g.currentPlayer = successor
		elseif wasCurrent then
			g.currentPlayer = g.activePlayers[1]
		end

		broadcastState(g)
	end
end)

print("[MonkeyMonkey] Server ready")
