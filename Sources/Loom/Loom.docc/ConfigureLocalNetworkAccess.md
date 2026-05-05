# Configure Local Network Access

Set up the required Info.plist keys so your app can discover and advertise Loom peers on the local network.

## Overview

Apple platforms require apps to declare their intent to use the local network before Bonjour discovery or advertising can work. Without the correct Info.plist entries, `NWBrowser` and `NWListener` fail silently with error code `-65555 (NoAuth)`.

Loom includes a debug-only assertion that catches missing keys at startup, but your Info.plist still needs to be configured before shipping.

## Required Info.plist Keys

Add both of these keys to your app target's `Info.plist`:

```xml
<key>NSBonjourServices</key>
<array>
    <string>_yourapp._tcp</string>
</array>

<key>NSLocalNetworkUsageDescription</key>
<string>This app uses the local network to discover and connect to nearby devices.</string>
```

Replace `_yourapp._tcp` with the Bonjour service type you pass to ``LoomNetworkConfiguration`` or ``LoomDiscovery``. If you use the Loom default, that is `_loom._tcp`.

`NSBonjourServices` tells the system which service types the app is allowed to browse and advertise. `NSLocalNetworkUsageDescription` provides the user-facing explanation shown in the local network permission prompt.

Both keys are required. If either is missing, the system denies Bonjour operations and `NWBrowser` transitions to a failed state with error `-65555 (kDNSServiceErr_NoAuth)`.

When browsing fails for that reason, `LoomDiscovery` reports the denial through its `localNetworkAccessDenied` state and `onLocalNetworkAccessDeniedChanged` callback so clients can switch from onboarding into recovery UI.

## App Store Distribution

Apps distributed through the App Store or using App Sandbox need an additional entitlement:

```
com.apple.developer.networking.multicast
```

Request this entitlement through your Apple Developer account. Without it, Bonjour discovery may be blocked on end-user devices even if the Info.plist keys are correct.

## Resetting Permissions During Development

If the local network permission prompt was dismissed or denied during testing, you can reset it:

- **System Settings:** Go to Privacy & Security > Local Network and toggle your app back on.
- **Terminal:** Run `tccutil reset LocalNetwork <your.bundle.identifier>` to force the prompt to appear again on next launch.

## Debug Assertion

In debug builds, Loom checks for the required Info.plist keys when ``LoomDiscovery/startDiscovery()`` or the internal advertiser starts. If the keys are missing or the service type is not listed, an `assertionFailure` fires with a message explaining exactly what to add. This assertion is stripped from release builds.
