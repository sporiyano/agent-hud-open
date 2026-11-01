# Agent HUD for Windows

The Windows shell: a WinUI 3 app (`AgentHUD`) that draws a strip at the top of the primary screen and a tray icon from the snapshots `agenthud-core --watch` prints (see [docs/command-line.md](../docs/command-line.md#agenthud-core)). It is unpackaged and self-contained.

The **Portable core** workflow builds both on `windows-2022` and uploads them as one folder, `agent-hud-windows-x64`: unzip it anywhere and run `AgentHUD.exe`.

To build by hand on Windows, with the Swift toolchain and the .NET 8 SDK:

```
swift build -c release --product agenthud-core
dotnet publish windows/AgentHUD/AgentHUD.csproj -c Release -r win-x64 -p:Platform=x64 -o dist
```

then copy `agenthud-core.exe` and the Swift runtime DLLs beside `AgentHUD.exe` in `dist`.

The vendor marks in `AgentHUD/Assets/Vendors` are the Mac app's, scaled down; see `LobeIcons-LICENSE.txt` there.
