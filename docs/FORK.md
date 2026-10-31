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
- **Scroll overlay:** viewport scrolls are drawn from captured window images in one layer, so all columns move together however slowly their apps respond. It needs Screen Recording, and scrolling falls back to the path above without it.

Turn the overlay off or on, then relaunch:

```bash
defaults delete com.barut.OmniWM.dev OmniWMExperimentScrollOverlay
```

```bash
defaults write com.barut.OmniWM.dev OmniWMExperimentScrollOverlay -bool true
```

## Known limitations of the overlay

- Other transitions, such as closing a window or moving one into a column, still use the Accessibility path.
- Floating windows are hidden during a scroll.
- Captured windows have no shadow, and window content is frozen during a scroll. It can be out of date when the scroll starts and snap when the real window returns.
- macOS shows its recording indicator while windows are being captured, which can happen briefly between scrolls.
- WindowServer moves are not an alternative: macOS 27 ignored them for other apps' windows when tested.
