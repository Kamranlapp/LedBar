# LedBar

LedBar is a lightweight macOS menu bar app for controlling three LED strips over MQTT. Adjust each strip or all strips together on a 0–12 brightness scale. Incoming MQTT messages keep the controls in sync when brightness changes elsewhere.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools

## Build and launch

Run the included launcher:

```sh
./Launch.command
```

The app bundle is built at `build/LedBar.app` and opened automatically. You can also build without launching it:

```sh
./build.sh
```

## MQTT setup

Open LedBar's settings and configure one MQTT broker, then add the topics for your strips. Assign a topic to each strip. The app publishes brightness values from `0` to `12` and subscribes to those topics to reflect updates received from other devices.

Quick commands can publish a different payload to each selected topic. Click a command to publish immediately. Press and hold it for two seconds to schedule the messages for delivery in five minutes. Delayed publishing requires a broker that supports EMQX Delayed Publish and the **EMQX delayed publishing** option enabled in settings. A green outline with a five-minute countdown appears after the broker acknowledges the scheduled messages.

## Sync settings between Macs

Open the **Sync** tab in settings and select the same iCloud Drive folder on each Mac. LedBar syncs the broker configuration, topics, strip assignments, and quick commands through `LedBar-settings.json`. Use one Mac at a time when editing, since the file contains the complete settings snapshot.

Broker passwords are stored separately in each Mac's Keychain and are not included in the sync file. Enter the password on each Mac that needs to connect to an authenticated broker.

## Privacy

Broker settings and passwords are not bundled with the app or stored in this repository. Passwords are kept in macOS Keychain; optional settings sync contains no password.
