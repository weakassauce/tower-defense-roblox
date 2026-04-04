# Tower Defense — Roblox port

Luau port of the Three.js tower defense prototype at
[weakassauce/tower-defense](https://github.com/weakassauce/tower-defense).

## Toolchain

All tools are pinned via [Rokit](https://github.com/rojo-rbx/rokit) in `rokit.toml`.
After cloning, run:

```sh
rokit install
```

This installs the exact versions of Rojo, StyLua, selene, and Wally used by the project.

## Running

```sh
rojo serve
```

Then in Roblox Studio, open any blank place, install the Rojo plugin
(from the plugin marketplace or via `rojo plugin install`), and click **Connect**.
Every save in this folder will sync into Studio.

To build an rbxl file without Studio running:

```sh
rojo build -o TowerDefense.rbxl
```

## Project layout

```
src/
  shared/    -> ReplicatedStorage.Shared   (modules used by both sides)
  server/    -> ServerScriptService.Server (authoritative game state)
  client/    -> StarterPlayerScripts.Client (UI, camera, effects)
```

Each folder that maps to an instance uses `init.luau` (ModuleScript),
`init.server.luau` (Script), or `init.client.luau` (LocalScript).
