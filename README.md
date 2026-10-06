# MicWarm

A tiny macOS menu-bar app that keeps your **Bluetooth headphones' microphone** (AirPods, AirPods Pro, and other Bluetooth headsets) open, so **Wispr Flow and other dictation apps** start recording instantly.

## The problem

When a dictation app starts using a Bluetooth mic, macOS has to switch the headphones from their high-quality listening mode into a two-way "headset" mode. That switch can take a second or more, so the first words you say get cut off. Right after a dictation, the switch has already happened, so the next one is instant. After a few seconds idle, macOS switches back and the delay returns.

## What MicWarm does

While a Bluetooth mic is connected and your Mac is unlocked, MicWarm keeps that mic open, so it is already on when you start dictating. Wispr Flow (or any other app) uses the same mic at the same time, with no setup or changes to the dictation app.

- **Nothing is recorded.** Audio from the mic is thrown away immediately. Nothing is stored, analyzed, or sent anywhere.
- **Bluetooth only.** Wired mics (EarPods, USB mics) and the built-in MacBook mic are ignored.
- **Lets go when you're away.** It releases the mic on screen lock, display sleep, system sleep, or disconnect, and opens it again when you return.
- **Uses no CPU while waiting.** It doesn't poll; it only reacts when macOS reports a device change, a lock, or a sleep.

## Tradeoffs

While the mic is held open:
- Audio played through the headphones is lower quality (phone-call quality).
- The orange microphone-in-use dot stays visible.
- The headphones' battery drains somewhat faster.
- Switching the headphones automatically to another device (like your iPhone) may be less reliable.

Use the menu-bar toggle to turn it off when you want full-quality listening.

## Build and install

```bash
./build.sh
```

This builds `MicWarm.app` and installs it to `/Applications`. Grant microphone access on first launch. Turn on **Start at login** from the menu-bar icon.

Requires macOS 13 or later.

## Files

- `main.swift`: the whole app (device selection, keepalive stream, lock/sleep handling, menu)
- `make_icon.swift`: draws the app icon
- `build.sh`: compiles, bundles, signs ad hoc, and installs
