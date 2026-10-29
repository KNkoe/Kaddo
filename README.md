# Kaddo

Kaddo is an experimental native macOS desktop assistant inspired by HeyClicky. It offers chat, voice, screen context and background Codex agents. It was developed by observing and reverse engineering the installed application; it is an independent project and is not affiliated with HeyClicky. Features and reliability may differ.

This is an experimental community release. Expect bugs and changing behavior; no maintenance or support schedule is promised. Review agent actions and outputs before relying on them.

## Requirements

- macOS 14 or later, Swift 6 and Xcode command-line tools.
- The installed Codex CLI, signed in with a compatible ChatGPT account, for the default chat provider and background agents. Account access and usage limits depend on OpenAI's current offerings. An optional OpenAI-compatible chat endpoint has separate requirements.
- Background agents additionally require Apple Silicon, Python 3.12 or later, network access to install Python packages and download the pinned public Laya model, and an available local port 8765. They will not run without the local verifier.

## Setup

First inspect the provisioning script and its pinned requirements, then run:

```sh
python3.12 Sources/Kaddo/Resources/Verification/runtime/setup.py
./scripts/build.sh
open dist/Kaddo.app
```

The setup script creates a local virtual environment under `~/.local/share/kaddo-verifier`, downloads a pinned public model, generates a local authentication token if needed, and registers a loopback-only LaunchAgent. It refuses to replace an existing service on port 8765. The build script checks that the service is healthy; it does not install it automatically. The app is signed with a development identity when available, otherwise ad hoc.

Open the notch from the menu bar or with Command–Shift–Space. macOS permissions for screen recording, accessibility, microphone and speech recognition are requested through user actions. Features using third-party integrations or an alternative API endpoint may require separate accounts and charges.

## Privacy and operation

Chat and attached content are sent through the selected provider. Voice streams microphone audio to the signed-in Codex realtime service; active voice refreshes screen context. Screen captures and text can be sent when explicitly attached or used for planning; optional proactive suggestions can send locally recognized screen text and recent activity to Codex. Read the settings before enabling features. Local conversations, attachments, screenshots and agent workspaces live under `~/Library/Application Support/Kaddo/`; API keys use the macOS Keychain. Agents can write in their workspaces and desktop control requires macOS permissions. Workspace restrictions are not full filesystem isolation.

This release omits the copied HeyClicky sound recordings and third-party integration logos. Event sounds are currently silent; integration icons use generic initials.

## Tests

```sh
swift test
```

Live tests require installed, signed-in tools and can perform real operations; inspect the tests before opting in with `KADDO_LIVE_TESTS=1 swift test`.

## License

Kaddo's own code is available under the MIT License; see [LICENSE](LICENSE). Dependencies and model weights are separately distributed and governed by their own terms.
