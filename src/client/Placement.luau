--!strict
-- src/client/Placement.luau
-- Camera management + mouse-based tower placement and pickup.
-- Default mode is "overview" — a scripted camera high above the map looking
-- straight down. Tab toggles to "explore" where the default Roblox follow
-- camera and character take over so you can walk around.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local Config = require(ReplicatedStorage.Shared.Config)

local Hud = require(script.Parent.Hud)

local Placement = {}

type Mode = "overview" | "explore"

local camera = workspace.CurrentCamera

-- Players spawn in the lobby, so start in character-follow (explore) mode
local mode: Mode = "explore"
local enabled = false
-- When true, the camera is locked to character-follow and both the C
-- keybind and the on-screen camera toggle are no-ops. Flipped by the
-- enterLobbyMode / enterArenaMode helpers.
local cameraLocked = true

-- When set, the RenderStepped loop uses this CFrame every frame instead of
-- the normal overview/explore logic. Used by the castle-destroyed cinematic.
local cinematicCFrame: CFrame? = nil
local lerpStartCFrame: CFrame? = nil
local lerpStartTime = 0
local lerpDuration = 0

local preview: Part? = nil
local previewRange: Part? = nil
local cellsFolder: Folder? = nil
local towersFolder: Folder? = nil

-- Overview camera — positioned high and tilted forward looking at map center.
-- Map extents are ±64 studs (16*8/2) so ~150 up / 100 back frames it nicely.
local OVERVIEW_POS = Vector3.new(0, 150, 100)
local OVERVIEW_TARGET = Vector3.new(0, 0, 0)

-- World-space offset of the local player's arena. On a fresh server
-- this is (0,0,0); when the server spawns multiple players, each
-- player's arena sits at their per-slot offset. The server sends this
-- via EnterRealm and init.client forwards it to Placement.setArenaOffset
-- so the placement ghost + overview camera aim at the player's own
-- arena instead of the origin. Reset to zero when entering the lobby.
local arenaOffset = Vector3.zero

-- --- Helpers ---

-- Re-fetch the local player's Map.Cells and Towers folders if the
-- cached refs have been destroyed. In single-player these were under
-- workspace.Map / workspace.Towers; with per-player private arenas
-- they live under workspace.PlayerArena_<userId> instead. Walking the
-- LocalPlayer's folder keeps raycasts scoped to this player's arena
-- and invisible to everyone else's.
local function ensureWorkspaceFolders()
	local localPlayer = Players.LocalPlayer
	local arenaFolder = if localPlayer
		then workspace:FindFirstChild("PlayerArena_" .. localPlayer.UserId)
		else nil
	if not cellsFolder or cellsFolder.Parent == nil then
		local map = arenaFolder and arenaFolder:FindFirstChild("Map") or nil
		cellsFolder = if map then map:FindFirstChild("Cells") :: Folder? else nil
	end
	if not towersFolder or towersFolder.Parent == nil then
		towersFolder = arenaFolder and arenaFolder:FindFirstChild("Towers") :: Folder? or nil
	end
end

local function applyOverviewCamera()
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(OVERVIEW_POS + arenaOffset, OVERVIEW_TARGET + arenaOffset)
end

-- Called by init.client whenever EnterRealm fires so the client knows
-- where its arena is in world space. Passing Vector3.zero (lobby) is
-- a valid "no offset" value and the ghost math degrades to origin.
function Placement.setArenaOffset(offset: Vector3)
	arenaOffset = offset
	-- Bust cached folder refs since the arena folder name changed
	-- (PlayerArena_<uid> is stable per player, but the contents are
	-- rebuilt every realm switch — ensureWorkspaceFolders will
	-- re-find them on the next call).
	cellsFolder = nil
	towersFolder = nil
end

local function applyExploreCamera()
	camera.CameraType = Enum.CameraType.Custom
end

local function getCellUnderMouse(): (number?, number?, Vector3?)
	ensureWorkspaceFolders()
	if not cellsFolder then
		return nil, nil, nil
	end

	local mousePos = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { cellsFolder }

	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if not result or not result.Instance then
		return nil, nil, nil
	end

	local gx = result.Instance:GetAttribute("gx")
	local gy = result.Instance:GetAttribute("gy")
	if typeof(gx) == "number" and typeof(gy) == "number" then
		return gx, gy, result.Position
	end
	return nil, nil, nil
end

local function getTowerUnderMouse(): (number?, number?)
	ensureWorkspaceFolders()
	if not towersFolder then
		return nil, nil
	end

	local mousePos = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { towersFolder }

	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if not result or not result.Instance then
		return nil, nil
	end

	-- Walk up to the Tower model (direct child of the Towers folder)
	local inst: Instance? = result.Instance
	while inst and inst.Parent ~= towersFolder do
		inst = inst.Parent
	end
	if not inst or not inst:IsA("Model") then
		return nil, nil
	end

	-- The tower's world position includes the arena offset; subtract
	-- it before converting back to grid coords so a tower in slot 2's
	-- arena (x=8000) still resolves to the same (gx, gy) as slot 1.
	local pivot = inst:GetPivot().Position
	local gx, gy = Config.worldToGrid(pivot.X - arenaOffset.X, pivot.Z - arenaOffset.Z)
	return gx, gy
end

local function buildPreview()
	preview = Instance.new("Part")
	preview.Name = "PlacementPreview"
	preview.Anchored = true
	preview.CanCollide = false
	preview.Size = Vector3.new(3, 6, 3)
	preview.Material = Enum.Material.Neon
	preview.Color = Color3.fromRGB(100, 220, 100)
	preview.Transparency = 0.55
	preview.CastShadow = false
	preview.Parent = workspace

	previewRange = Instance.new("Part")
	previewRange.Name = "PlacementPreviewRange"
	previewRange.Anchored = true
	previewRange.CanCollide = false
	previewRange.Size = Vector3.new(20, 0.2, 20)
	previewRange.Material = Enum.Material.Neon
	previewRange.Color = Color3.fromRGB(100, 220, 100)
	previewRange.Transparency = 0.9
	previewRange.CastShadow = false
	previewRange.Parent = workspace
end

local function hidePreview()
	if preview then
		preview.Transparency = 1
	end
	if previewRange then
		previewRange.Transparency = 1
	end
end

local function showPreview(gx: number, gy: number, valid: boolean, rangeStuds: number)
	if not preview or not previewRange then
		return
	end
	-- Config.gridToWorld is origin-relative; add the player's arena
	-- offset so the ghost ends up on their own arena cells instead of
	-- at the origin (which would be another player's arena, or empty
	-- space on a server where the local player isn't in slot 1).
	local cellWorld = Config.gridToWorld(gx, gy) + arenaOffset
	preview.Transparency = 0.55
	preview.Position = Vector3.new(cellWorld.X, 3 + arenaOffset.Y, cellWorld.Z)
	preview.Color = valid and Color3.fromRGB(100, 220, 100) or Color3.fromRGB(230, 80, 80)

	previewRange.Transparency = 0.88
	previewRange.Position = Vector3.new(cellWorld.X, 0.25 + arenaOffset.Y, cellWorld.Z)
	previewRange.Size = Vector3.new(rangeStuds * 2, 0.2, rangeStuds * 2)
	previewRange.Color = preview.Color
end

-- --- Public API ---

function Placement.setEnabled(v: boolean)
	enabled = v
	if not enabled then
		hidePreview()
	end
end

-- Smoothly lerps the camera from its current position to `cf` over
-- `duration` seconds and then holds it there. While cinematic, placement
-- preview is hidden.
function Placement.cinematicPanTo(cf: CFrame, duration: number)
	lerpStartCFrame = camera.CFrame
	cinematicCFrame = cf
	lerpStartTime = os.clock()
	lerpDuration = math.max(0, duration)
end

-- Lerps the camera toward a view of the player's character, then switches
-- CameraType to Custom so Roblox's default follow-cam takes over. Used at
-- the end of the castle-destroyed cinematic so the camera returns to the
-- player instead of the top-down overview.
function Placement.cinematicReturnToCharacter(duration: number)
	local player = Players.LocalPlayer
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: Part?
	if not root then
		-- No character yet; just release the cinematic and fall back to overview
		cinematicCFrame = nil
		lerpStartCFrame = nil
		mode = "overview"
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.lookAt(OVERVIEW_POS + arenaOffset, OVERVIEW_TARGET + arenaOffset)
		return
	end

	local charPos = root.Position
	local eye = charPos + Vector3.new(-14, 10, -14)
	local target = charPos + Vector3.new(0, 3, 0)
	lerpStartCFrame = camera.CFrame
	cinematicCFrame = CFrame.lookAt(eye, target)
	lerpStartTime = os.clock()
	lerpDuration = math.max(0.01, duration)
	task.delay(duration, function()
		cinematicCFrame = nil
		lerpStartCFrame = nil
		-- Hand control to Roblox's default follow camera so it tracks
		-- the character going forward.
		mode = "explore"
		camera.CameraType = Enum.CameraType.Custom
	end)
end

-- Clears any in-progress cinematic lerp. Unlike the original version of
-- this function, we DON'T force the camera back to overview — if the
-- player ended up in character view at the end of the castle-destroyed
-- cinematic, they keep that view across restarts and can press Tab
-- whenever they want to swap to the top-down placement camera.
function Placement.cinematicRelease()
	cinematicCFrame = nil
	lerpStartCFrame = nil
end

-- Flip between overview and explore modes. Shared by the C keybind and
-- the on-screen camera toggle button. No-op while the camera is locked
-- (e.g. in the lobby, where the player is forced into character view).
function Placement.toggleCameraMode()
	if cameraLocked then
		return
	end
	if mode == "overview" then
		mode = "explore"
		applyExploreCamera()
	else
		mode = "overview"
		applyOverviewCamera()
	end
end

-- Sets character follow as the active camera mode (used for walking
-- around the lobby). The lobby always forces follow-cam, so the camera
-- lock is enabled here.
function Placement.enterLobbyMode()
	cinematicCFrame = nil
	lerpStartCFrame = nil
	mode = "explore"
	camera.CameraType = Enum.CameraType.Custom
	cameraLocked = true
end

-- Drops the player into character-follow mode when they enter a realm.
-- Press C or tap the camera toggle to swap to the aerial overview for
-- tower placement. Camera lock is released so the toggle works.
function Placement.enterArenaMode()
	cinematicCFrame = nil
	lerpStartCFrame = nil
	cameraLocked = false
	mode = "explore"
	applyExploreCamera()
end

function Placement.init()
	buildPreview()
	hidePreview()
	-- Start in character follow so players see their avatar in the lobby.
	-- enterArenaMode() swaps to overview when a realm portal is touched.
	applyExploreCamera()

	-- Camera toggle on C (was Tab, which fights with the CoreGui leaderboard)
	ContextActionService:BindAction("ToggleCameraMode", function(_action, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		Placement.toggleCameraMode()
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.C)

	-- Keep the scripted camera pinned each frame + update hover preview
	RunService.RenderStepped:Connect(function()
		if cinematicCFrame then
			camera.CameraType = Enum.CameraType.Scriptable
			if lerpStartCFrame and lerpDuration > 0 then
				local t = math.clamp((os.clock() - lerpStartTime) / lerpDuration, 0, 1)
				-- Ease-out quad
				local eased = 1 - (1 - t) * (1 - t)
				camera.CFrame = lerpStartCFrame:Lerp(cinematicCFrame, eased)
				if t >= 1 then
					lerpStartCFrame = nil
				end
			else
				camera.CFrame = cinematicCFrame
			end
			hidePreview()
			return
		end
		if mode == "overview" and camera.CameraType == Enum.CameraType.Scriptable then
			camera.CFrame = CFrame.lookAt(OVERVIEW_POS + arenaOffset, OVERVIEW_TARGET + arenaOffset)
		end

		if not enabled or Hud.isGameOver() then
			hidePreview()
			return
		end

		local sel = Hud.getSelection()
		local def = TowerDefs[sel.towerType]
		if not def then
			-- Nothing selected → no preview
			hidePreview()
			return
		end

		local gx, gy = getCellUnderMouse()
		if gx and gy then
			local isPath = Config.isPath(gx, gy)
			showPreview(gx, gy, not isPath, def.range)
		else
			hidePreview()
		end
	end)

	-- Mouse handlers: left = place, right = pickup
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not enabled or Hud.isGameOver() then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- Belt-and-suspenders: if the click is over any tracked
			-- button, swallow it here so the button's Activated event
			-- handles it. `processed` should already catch this; the
			-- hover tracker is our backup. (Hud tracks every GuiButton
			-- under PlayerGui, including tutorial/overlay buttons, so
			-- this covers all UI.)
			if Hud.isHoveringHudButton() then
				return
			end
			-- Mobile-friendly pickup: if pickup mode is armed and the
			-- tap landed on a placed tower, send it to inventory. Mode
			-- auto-disables on successful pickup so the player doesn't
			-- accidentally delete more towers on subsequent taps.
			if Hud.isPickupMode() then
				local tgx, tgy = getTowerUnderMouse()
				if tgx and tgy then
					Remotes.PickupTower:FireServer(tgx, tgy)
					Hud.notifyTowerPickedUp()
				end
				return
			end
			local sel = Hud.getSelection()
			if TowerDefs[sel.towerType] then
				-- A tower is selected → a tap on a grass cell places it.
				local gx, gy = getCellUnderMouse()
				if gx and gy then
					if sel.fromInventoryIndex >= 0 then
						Remotes.PlaceFromInventory:FireServer(sel.fromInventoryIndex, gx, gy)
					else
						Remotes.PlaceTower:FireServer(gx, gy, sel.towerType)
					end
					-- Auto-deselect after placing so the gun comes back out
					-- and the player can immediately shoot. They can always
					-- re-select a tower from the panel to place another.
					Hud.clearSelection()
				end
				return
			end
			-- No tower selected → if a gun is equipped, fire it at the
			-- point under the cursor. The server validates range, fire
			-- rate, and which enemy (if any) was actually hit.
			local gunKey = Hud.getEquippedGun()
			if not gunKey then
				return
			end
			local mousePos = UserInputService:GetMouseLocation()
			local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			local char = Players.LocalPlayer.Character
			if char then
				params.FilterDescendantsInstances = { char, preview, previewRange }
			end
			local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
			local targetPos = if result then result.Position else ray.Origin + ray.Direction * 500
			Remotes.FireGun:FireServer(targetPos)
			-- Bump the tutorial-visible shot counter so the "try
			-- shooting" step auto-advances on the first trigger pull.
			Hud.incrementShotsFired()
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			local gx, gy = getTowerUnderMouse()
			if gx and gy then
				Remotes.PickupTower:FireServer(gx, gy)
			end
		end
	end)
end

return Placement
