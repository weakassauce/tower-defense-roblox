--!strict
-- src/server/PlayerSlot.luau
-- Hands out per-server arena slots to joining players. Each slot maps
-- to a unique world-space offset so every player's arena (map, castle,
-- towers, enemies) can sit side-by-side in the same place without
-- visually overlapping. The shared lobby stays at its own fixed
-- location; slots only offset arena-side geometry.
--
-- Slot 1 is at the origin; subsequent slots step 8000 studs along +X
-- (well beyond the 200-stud arena + mountain padding, so players never
-- glimpse each other's arenas across the skybox). Max 6 slots per
-- server — matches the "6 players per server" gameplay cap.

local PlayerSlot = {}

PlayerSlot.MAX_SLOTS = 6
PlayerSlot.SLOT_STRIDE = 8000

-- slotIndex[1] is the first assigned slot, slotIndex[MAX_SLOTS] is the
-- last. A nil entry means the slot is free. We allocate linearly so the
-- lowest-numbered free slot is always reused next.
local slots: { Player? } = {}

-- Translate a 1-based slot index into the world-space origin offset for
-- that slot's arena. Slot 1 → (0,0,0), slot 2 → (8000,0,0), etc. Kept
-- deterministic (not random) so a rejoining player lands on the same
-- arena position as long as the slot is still reserved, and so tests
-- can reason about exact coordinates.
function PlayerSlot.offsetFor(slotIndex: number): Vector3
	return Vector3.new((slotIndex - 1) * PlayerSlot.SLOT_STRIDE, 0, 0)
end

-- Reserve the lowest-numbered free slot for `player`. Returns the slot
-- index + offset on success, or nil if the server is full (should not
-- happen as long as Players.MaxPlayers is also 6, but defensive anyway).
function PlayerSlot.allocate(player: Player): (number?, Vector3?)
	for i = 1, PlayerSlot.MAX_SLOTS do
		if slots[i] == nil then
			slots[i] = player
			return i, PlayerSlot.offsetFor(i)
		end
	end
	return nil, nil
end

-- Release `player`'s slot on disconnect so the next join can reuse it.
function PlayerSlot.release(player: Player)
	for i = 1, PlayerSlot.MAX_SLOTS do
		if slots[i] == player then
			slots[i] = nil
			return
		end
	end
end

function PlayerSlot.getSlotIndex(player: Player): number?
	for i = 1, PlayerSlot.MAX_SLOTS do
		if slots[i] == player then
			return i
		end
	end
	return nil
end

return PlayerSlot
