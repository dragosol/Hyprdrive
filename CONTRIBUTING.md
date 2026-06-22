# Contributing

Contributions are welcome. Feel free to open a pull request with fixes,
cleanup, or small functional improvements. I will review it when I have time.

I would prefer the project to stay close to what the overview in Niri offers.
Small usability and compatibility improvements are fine, but larger feature
ideas should be discussed first so the plugin does not drift too far from that
scope.

## Bug Reports and Fixes

Bug fixes always take priority. I will not start working on new functionality
while there are reported bugs that still need attention.

If you find a bug, please try to narrow down which Hyprland config option causes
or exposes it. This makes it much easier for me to reproduce the issue. Most
bugs happen because I cannot test every possible Hyprland configuration after
each change.

## Development Notes

I have hardware to test whether the overview renders correctly in HDR, on
vertical and horizontal monitors, and at high refresh rates. I will also
review new pull requests with these modes in mind, to make sure changes do not
break anything. I know that HDR mode in Hyprland itself is not perfect yet.
This plugin will not try to fix what is broken in Hyprland; it will just use
the same functions and hopefully things will improve over time.

I do not have any device that supports gesture input, so development help with
gesture behavior is especially welcome. If you want to improve gestures, a pull
request with the actual implementation would be very useful.
