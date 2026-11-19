# HomeKit MCP

A macOS app that bridges Apple HomeKit with the [Model Context Protocol](https://modelcontextprotocol.io), letting Claude (or other MCP-compatible LLMs) control your smart home devices over natural language.

Built as a Mac Catalyst app using the native HomeKit framework and the [official Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk). Runs headless with an optional menu bar status item.

## Prerequisites

- **macOS 15.0+**
- **Xcode 26+** (includes Swift, Mac Catalyst support, and the iOS SDK)
- **Apple Developer account** (free or paid) for code signing — HomeKit requires a signed app with entitlements
- **HomeKit-configured home** — at least one home set up in the Apple Home app on your Mac or iOS device

## Building

1. **Clone the repository:**

   ```bash
   git clone https://github.com/grahamaloo/HomeKitMCP.git
   cd HomeKitMCP
   ```

2. **Configure your development team:**

   ```bash
   cp Local.xcconfig.template Local.xcconfig
   ```

   Open `Local.xcconfig` and replace `YOUR_TEAM_ID_HERE` with your [Apple Development Team ID](https://developer.apple.com/help/account/manage-your-team/locate-your-team-id/).
   Set `BUNDLE_ID_PREFIX` to a reverse-DNS prefix you own (for example `com.yourname`).
   This file is gitignored so your credentials stay local.

   Then register `<prefix>.HomeKitMCP` as an explicit App ID with the **HomeKit** capability in the [developer portal](https://developer.apple.com/account/resources/identifiers/list). Automatic signing otherwise falls back to the team wildcard profile, which can't carry the HomeKit entitlement.

3. **Open in Xcode:**

   ```bash
   open HomeKitMCP.xcodeproj
   ```

   The project will pick up your team ID from `Local.xcconfig` automatically. The HomeKit entitlement is already configured.

4. **Set the destination** to **My Mac (Mac Catalyst)** in the Xcode toolbar

5. **Build and run** (`Cmd+R`)

6. **Grant HomeKit access** when macOS prompts for permission on first launch

The built app will be located at:

```
~/Library/Developer/Xcode/DerivedData/HomeKitMCP-<hash>/Build/Products/Debug-maccatalyst/HomeKitMCP.app
```

> **Tip:** To find the exact path, right-click the app in Xcode's Products group and select "Show in Finder", or use `xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR`.

## Installing

Point MCP clients at an installed copy, not at the DerivedData build. The DerivedData path changes, and Xcode replaces the app on every build. Build a Release copy and install it in `~/Applications`:

```bash
xcodebuild -project HomeKitMCP.xcodeproj -scheme HomeKitMCP -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build -allowProvisioningUpdates build
mkdir -p ~/Applications
ditto build/Build/Products/Release-maccatalyst/HomeKitMCP.app ~/Applications/HomeKitMCP.app
```

To update, run the same commands again. macOS may ask again for HomeKit access after an update.

To test the installed copy from a terminal, send it an `initialize` request and a `list_homes` call:

```bash
( printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_homes","arguments":{}}}'
  sleep 8 ) | ~/Applications/HomeKitMCP.app/Contents/MacOS/HomeKitMCP --headless
```

The second response lists your homes.

## Configuration

The examples below use the install path from [Installing](#installing). Replace `<you>` with your macOS user name.

### Claude Code

```bash
claude mcp add -s user homekit -- ~/Applications/HomeKitMCP.app/Contents/MacOS/HomeKitMCP --headless
```

Check it with `claude mcp get homekit`. The status should be "Connected". Restart Claude Code to load the tools.

### Claude Desktop

Add to your Claude Desktop MCP config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "homekit": {
      "command": "/Users/<you>/Applications/HomeKitMCP.app/Contents/MacOS/HomeKitMCP",
      "args": ["--headless"]
    }
  }
}
```

### ChatGPT desktop app and Codex

The ChatGPT desktop app, the Codex CLI, and the Codex IDE extension share one MCP configuration, `~/.codex/config.toml` ([OpenAI docs](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)). Add the server in one of three ways:

- **ChatGPT desktop app:** open **Settings**, then **MCP servers**, then **Add server**. Enter the name `homekit`, choose **STDIO**, set the command to `/Users/<you>/Applications/HomeKitMCP.app/Contents/MacOS/HomeKitMCP`, and add the argument `--headless`. Save, then select **Restart**.
- **Codex CLI:**

  ```bash
  codex mcp add homekit -- ~/Applications/HomeKitMCP.app/Contents/MacOS/HomeKitMCP --headless
  ```

- **Edit `~/.codex/config.toml`:**

  ```toml
  [mcp_servers.homekit]
  command = "/Users/<you>/Applications/HomeKitMCP.app/Contents/MacOS/HomeKitMCP"
  args = ["--headless"]
  ```

  Use the full path here. TOML doesn't expand `~`.

ChatGPT on the web (chatgpt.com) can't use this server. It can't start a process on your Mac, and this server has only the stdio transport. Use the desktop app.

### Notes for all clients

The `--headless` flag runs the server without the menu bar status item, which is recommended when launched by an MCP client.

## Capabilities

### MCP Tools

| Tool | Description |
|------|-------------|
| `list_homes` | List all HomeKit homes configured on this Mac |
| `list_rooms` | List rooms in a home with device counts |
| `list_devices` | List devices, filtered by home, room, or type |
| `get_device_state` | Get current state of a device (power, brightness, temperature, etc.) |
| `control_device` | Control a single device (on/off, brightness, color, lock, thermostat, etc.) |
| `batch_control_devices` | Control multiple devices in one call |
| `batch_get_device_state` | Query multiple device states in one call |
| `control_devices_by_filter` | Apply an action to all devices matching a filter (e.g. all lights in a room) |
| `list_scenes` | List HomeKit scenes/action sets |
| `execute_scene` | Trigger a scene by name or ID |

### Supported Device Types

| Type | Read | Control |
|------|------|---------|
| Lights | Power, brightness, hue, saturation | on, off, toggle, set_brightness, set_hue, set_saturation, set_color |
| Switches / Outlets | Power | on, off, toggle |
| Fans | Power | on, off, toggle |
| Locks | Lock state | lock, unlock |
| Garage Doors | Door state | open, close |
| Thermostats | Current temp, target temp, mode | set_temperature, set_thermostat_mode (off/heat/cool/auto) |
| Temperature Sensors | Temperature | read-only |
| Humidity Sensors | Humidity | read-only |
| Motion Sensors | Motion detected | read-only |
| Contact Sensors | Contact state | read-only |
| Occupancy Sensors | Occupancy | read-only |
| Windows / Doors / Coverings | Position | read-only |

### Device Addressing

Devices can be addressed by:

- **Name** (case-insensitive): `"name": "Living Room Light"`
- **Unique ID** (from `list_devices`): `"id": "ABC123-DEF456"` — preferred when multiple devices share a name
- **Name + qualifiers**: add `"home"` and/or `"room"` to disambiguate

## Example Usage

Once configured, you can ask Claude (or any MCP-compatible LLM) things like:

- "Turn off all the lights in the bedroom"
- "What's the temperature in the living room?"
- "Set the thermostat to 72 degrees"
- "Lock the front door"
- "Dim the kitchen lights to 30%"
- "Run the Good Night scene"

## Architecture

```
MCP Client (Claude, ChatGPT desktop, etc.)
        | (stdin/stdout JSON-RPC 2.0)
        v
HomeKitMCP --headless (parent: re-launches itself
        |               with TCC responsibility
        |               disclaimed, forwards signals)
        v
+---------------------------+
|  HomeKitMCP.app            |
|  (Mac Catalyst)            |
|                            |
|  +----------------------+  |
|  |  MCPServerManager    |  |  <- JSON-RPC over stdio
|  |  (StdioTransport)    |  |
|  +----------+-----------+  |
|             |              |
|  +----------v-----------+  |
|  |  HomeKitManager      |  |  <- async/await actor
|  |  (HMHomeManager)     |  |
|  +----------+-----------+  |
|             |              |
|  +----------v-----------+  |
|  |  Apple HomeKit       |  |  <- native framework
|  |  Framework           |  |
|  +----------------------+  |
+---------------------------+
```

## Troubleshooting

**"HomeKit permission denied" or no devices found:**

- Open **System Settings > Privacy & Security > HomeKit** and ensure HomeKitMCP is allowed
- Make sure you have at least one home configured in the Apple Home app
- The Mac must be signed into the same iCloud account as your Home setup

**Build fails with signing errors:**

- Make sure you've created `Local.xcconfig` from the template and set your Team ID
- Alternatively, select a team manually in Xcode under Signing & Capabilities
- A free Apple Developer account works, but the app must be re-signed every 7 days
- A paid account ($99/year) provides longer-lived signing

**MCP client can't connect:**

- Verify the path in your MCP config points to the actual built `.app` bundle
- Make sure you're pointing to `Contents/MacOS/HomeKitMCP` inside the `.app`
- Check that the app has been run at least once manually to grant HomeKit permission
- Run the terminal test in [Installing](#installing). Exit status 134 means TCC killed the server. With `--headless`, the app re-launches itself. macOS then checks HomeKitMCP's own HomeKit permission, not that of the client's host app (for example iTerm2). Make sure the binary you run includes that relaunch
- Errors go to stderr. Run the binary from a terminal to see them

## License

MIT
