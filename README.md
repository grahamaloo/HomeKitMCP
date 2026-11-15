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
   git clone https://github.com/grahamaloo/homekit_mcp.git
   cd homekit_mcp/HomeKitMCP
   ```

2. **Configure your development team:**
   ```bash
   cp Local.xcconfig.template Local.xcconfig
   ```
   Open `Local.xcconfig` and replace `YOUR_TEAM_ID_HERE` with your [Apple Development Team ID](https://developer.apple.com/help/account/manage-your-team/locate-your-team-id/).
   This file is gitignored so your credentials stay local.

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

## Configuration

### Claude Code

Add to `~/.claude/mcp.json`:

```json
{
  "mcpServers": {
    "homekit": {
      "command": "/path/to/HomeKitMCP.app/Contents/MacOS/HomeKitMCP",
      "args": ["--headless"]
    }
  }
}
```

### Claude Desktop

Add to your Claude Desktop MCP config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "homekit": {
      "command": "/path/to/HomeKitMCP.app/Contents/MacOS/HomeKitMCP",
      "args": ["--headless"]
    }
  }
}
```

Replace `/path/to/` with the actual path to your built `.app` bundle.

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
MCP Client (Claude, etc.)
        | (stdin/stdout JSON-RPC 2.0)
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

**Server hangs at "waiting for homes to load" / no homes found when started by the MCP client:**

On some macOS versions (observed on macOS 27.2) HomeKit never reports any homes when the app binary is spawned directly as a child process of the MCP client, even though the same app works when opened normally. Launching it through LaunchServices fixes this. Use the wrapper script instead of the binary:

```json
{
  "mcpServers": {
    "homekit": {
      "command": "/path/to/HomeKitMCP/scripts/homekit-mcp.sh"
    }
  }
}
```

The script starts the app with `open` and connects its stdin/stdout through named pipes. By default it expects the app at `~/Applications/HomeKitMCP.app`; set `HOMEKIT_MCP_APP` to use another path.

**Build fails with signing errors:**
- Make sure you've created `Local.xcconfig` from the template and set your Team ID
- Alternatively, select a team manually in Xcode under Signing & Capabilities
- A free Apple Developer account works, but the app must be re-signed every 7 days
- A paid account ($99/year) provides longer-lived signing

**MCP client can't connect:**
- Verify the path in your MCP config points to the actual built `.app` bundle
- Make sure you're pointing to `Contents/MacOS/HomeKitMCP` inside the `.app`
- Check that the app has been run at least once manually to grant HomeKit permission

## License

MIT
