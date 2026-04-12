# Android Tablet Testing Guide

## Purpose

This guide explains how to test a locally built RustDesk APK on an Android
tablet and verify that another RustDesk client can connect to it remotely.

The main focus is:

- basic end-to-end connection testing
- troubleshooting connection setup
- bypassing the Android 13+ restricted-settings block for input control

## Scope

This guide assumes:

- the APK was built locally from this repo
- the APK was installed on a tablet through a sideloaded flow
- the remote operator is using another RustDesk client such as desktop or a
  second mobile device
- you may be using either the public RustDesk infrastructure or your own
  ID/relay server

## Test Setup

Before testing, make sure you have:

- the tablet with the RustDesk APK installed
- a second device with a working RustDesk client
- network access between both devices and the same RustDesk server path
- any custom `ID Server` and `Key` values you intend to test

Useful note:

- if the tablet APK is sideloaded, Android 13 and newer may block Accessibility
  until you explicitly allow restricted settings for the app

## Recommended Test Flow

### 1. Install And Open The APK

- install the APK on the tablet
- open RustDesk and confirm the app launches without crashing

### 2. Configure The RustDesk Server If Needed

If you are testing against a custom server:

1. open `Settings`
2. open `ID/Relay Server`
3. enter the `ID Server`
4. leave `Relay Server` and `API Server` blank unless your deployment requires
   them
5. enter the public `Key` when your server requires it
6. save the settings

If you are testing against the default public RustDesk service, leave the
server settings unchanged.

### 3. Start Screen Sharing On The Tablet

1. open `Share Screen` from the bottom navigation bar
2. enable `Screen Capture`
3. enable `Input Control` if you want to test remote input
4. enable `File Transfer` or `Audio Capture` only if they are part of the test
5. tap `Start Service`

What to expect:

- after the service starts, the tablet should show a RustDesk ID and password
- if `Screen Capture` is not granted, other devices cannot issue control
  requests

### 4. Connect From The Remote Client

On the remote device:

1. open RustDesk
2. enter the tablet's RustDesk ID
3. connect with the shown password or approve the request on the tablet

Basic pass criteria:

- the session connects successfully
- the remote client can see the tablet screen
- the session stays connected long enough for a basic interaction test

### 5. Verify Input Control

If input control is part of the test:

1. switch between `Mouse mode` and `Touch mode` on the remote side as needed
2. verify that taps, navigation, and scrolling work
3. if Android opens the Accessibility settings flow, complete the permission
   step on the tablet first

Important behavior:

- changing `Input Control` or `File Transfer` permissions affects new
  connections, not the connection that is already open
- if you change those permissions, close the current connection and reconnect

## Connection Troubleshooting

### The Tablet Does Not Show A RustDesk ID

Likely causes:

- `Start Service` was not completed
- `Screen Capture` permission was denied

What to do:

1. go back to `Share Screen`
2. grant `Screen Capture`
3. tap `Start Service` again

### The Remote Client Cannot Reach The Tablet

Likely causes:

- the tablet and remote client are pointing at different RustDesk servers
- the custom server `Key` is missing or wrong
- the tablet never started the sharing service

What to do:

1. verify the tablet server settings under `Settings -> ID/Relay Server`
2. verify the remote client is using the same server path
3. restart the sharing service on the tablet
4. retry the connection

### The Connection Opens But No Screen Is Visible

Likely causes:

- `Screen Capture` permission was not accepted
- the service started before the permission flow finished cleanly

What to do:

1. stop the current session
2. return to `Share Screen`
3. re-grant `Screen Capture`
4. tap `Start Service` again
5. reconnect

### Input Control Still Does Not Work After Enabling It

Likely causes:

- Android Accessibility permission is still blocked
- the permission was changed during an already-open session

What to do:

1. confirm the Accessibility service is enabled for RustDesk
2. close the current session
3. reconnect after the permission change

## Restricted Settings On Android 13+

### What The Problem Looks Like

Common reproduction path:

1. open RustDesk on the tablet
2. go to `Share Screen`
3. enable `Input Control`
4. tap the in-app path that opens Android system settings
5. open RustDesk under Accessibility
6. hit the Android security warning instead of the normal enable flow

### Why It Happens

This is usually expected Android behavior for a sideloaded app that requests a
sensitive setting such as Accessibility.

Important correction:

- this does not automatically mean APK signing failed
- a release-signed local APK can still hit the restricted-settings block
- the main trigger is the sideloaded install path, not only whether the APK is
  signed or unsigned

### How To Bypass It

On the tablet:

1. open `Settings`
2. open `Apps`
3. open `RustDesk`
4. tap the three-dot menu
5. tap `Allow restricted settings`
6. return to `Settings -> Accessibility`
7. open the RustDesk service and enable it
8. return to RustDesk and reconnect

Vendor note:

- the exact menu labels may vary across Samsung, Xiaomi, and other Android
  skins
- if the path looks different, work from the app info page first, then the
  Accessibility page

## Optional ADB Helper For Media Projection

If you are doing repeated developer-side testing with `adb`, you can reduce one
specific prompt with:

```bash
adb shell appops set com.carriez.flutter_hbb PROJECT_MEDIA allow
```

Important limitation:

- this only helps with the media-projection permission state
- it does not bypass the Android Accessibility restricted-settings block for
  input control

## Suggested Test Checklist

- APK installs on the tablet successfully
- RustDesk launches successfully
- the tablet shows a RustDesk ID after `Start Service`
- the remote client connects successfully
- the remote client can see the tablet screen
- `Input Control` can be enabled after any required restricted-settings step
- mouse or touch input works remotely
- reconnecting after a permission change works as expected

## References

- RustDesk Android documentation:
  <https://rustdesk.com/docs/en/client/android/>
- Google Android Help, restricted settings:
  <https://support.google.com/android/answer/12623953?hl=en&ref_topic=7311596>
- RustDesk discussion about Android 13 input control restriction:
  <https://github.com/rustdesk/rustdesk/discussions/6241>
