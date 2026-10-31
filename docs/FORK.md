# Smooth scrolling fork

A personal fork of [OmniWM](https://github.com/OmniNull/OmniWM) that makes Niri viewport scrolling smoother.

## Install

On an Apple Silicon Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/wojtekkozlowski/OmniWM/smooth-scroll/Scripts/install-fork.sh | zsh
```

This installs **OmniWM Dev** in `~/Applications` beside any release copy of OmniWM, and quits whichever copy is running. It copies your settings to `~/.config/omniwm-dev` the first time. Grant Accessibility, Input Monitoring and Screen Recording when asked. If a permission shows as not granted while its toggle is on, clear it with `tccutil reset ScreenCapture com.barut.OmniWM.dev` (or `Accessibility`, `ListenEvent`) and grant it again.

The app is self-signed rather than notarized. The script downloads it with `curl`, which macOS does not quarantine, so Gatekeeper does not block it.

## What changed

- **First frame:** a scroll's spring clock started when the command was handled, so the first frame landed far along the curve. It now starts at the first display tick.
- **Backward hops:** frames sampled between display ticks no longer land behind the previous tick.
- **Accessibility writes:** position-only frames stop carrying size writes and readbacks, and Enhanced UI stays off across a motion rather than toggling for every batch.
- **Overlay:** viewport scrolls, window closes and column swaps are drawn from captured window images in one layer, so all columns move together however slowly their apps respond. It needs Screen Recording, and motions fall back to the path above without it.
- **Neighbouring displays:** when a column would hang over an edge that touches another display, the focused column aligns with that edge, so no window has to be hidden and no empty area opens.

Turn the overlay off or on, then relaunch:

```bash
defaults delete com.barut.OmniWM.dev OmniWMExperimentScrollOverlay
```

```bash
defaults write com.barut.OmniWM.dev OmniWMExperimentScrollOverlay -bool true
```

## Keeping up with upstream

`.github/workflows/sync-upstream.yml` merges `OmniNull/OmniWM` main into `smooth-scroll` daily, builds the result, and pushes only if it builds. It also moves this fork's `main` to match upstream. A conflict or a broken build fails the run, and nothing is pushed.

It needs a repository secret named `SYNC_TOKEN`: a fine-grained token for this repository only, with read and write access to Contents and Workflows. Syncing does not publish a release, so installed apps change only when a release is published.

## Known limitations of the overlay

- Motions that change a window's size use the Accessibility path, including resizing a column, moving a window into or out of a stack, and a close that resizes a neighbour. Opening a window does too, because it has no captured image yet.
- The first few motions after launch can use that path while images are captured. So can a window that has just changed shape, until a new image arrives.
- Trackpad gestures and vertical layouts use that path.
- Floating windows are hidden during a motion, and a closing window disappears at once.
- Captured windows have no shadow, and window content is frozen during a motion. Windows fully on screen are captured as the motion starts, which can delay it slightly. A parked window shows how it looked when it left, so its content can snap when it returns.
- macOS shows its recording indicator while windows are captured with a stream, which can happen briefly for parked windows.
- WindowServer moves are not an alternative: macOS 27 ignored them for other apps' windows when tested.
