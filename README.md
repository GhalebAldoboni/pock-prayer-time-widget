# Pock Prayer Time Widget

Prayer Time Widget is a Touch Bar widget for [Pock](https://pock.app/) that shows the next Muslim prayer time, supports Arabic and English labels, and includes an iqama countdown with a red full-width warning state.

It uses the free [AlAdhan Prayer Times API](https://aladhan.com/prayer-times-api) and can calculate prayer times from either your Mac location or manually entered coordinates.

## Features

- Next prayer time directly on the MacBook Touch Bar
- Arabic and English display modes
- 12-hour time format with English digits
- Automatic device location with CoreLocation
- Manual latitude and longitude override
- Configurable AlAdhan calculation method
- Iqama countdown after each prayer
- Default iqama duration: 20 minutes
- Maghrib iqama duration: 5 minutes
- Red full-box countdown when iqama is 5 minutes or less
- Cached location and prayer schedule for faster startup
- Refreshes prayer times every 6 hours

## Screenshots

Add screenshots to `docs/` after installing the widget:

- Next prayer: `العصر 3:41 PM`
- Iqama countdown: `الإقامة: 19:00`
- Critical iqama warning: red `04:00` full-width countdown

## Requirements

- macOS 10.15 or later
- Pock installed
- Xcode command line tools or Swift toolchain
- Internet connection for AlAdhan API requests
- Location permission for automatic location mode

## Install

Download `PrayerTimeWidget.pock` from the latest GitHub release, then double-click it or copy it to:

```bash
~/Library/Application Support/Pock/Widgets/PrayerTimeWidget.pock
```

Restart Pock after installing the widget.

## Build From Source

```bash
git clone https://github.com/GhalebAldoboni/pock-prayer-time-widget.git
cd pock-prayer-time-widget
./build-widget.sh
```

The packaged widget will be created at:

```bash
build/PrayerTimeWidget.pock
```

If you clone this repository by itself, you can also build the Swift package directly:

```bash
swift build
```

## Configure In Pock

Open Pock's widget manager and select `وقت الصلاة` / `Prayer Time`.

Available settings:

- Language: Arabic or English
- Location: device location or manual coordinates
- Latitude and longitude for manual mode
- AlAdhan method number
- Default iqama minutes
- Maghrib iqama minutes

Changes are saved to Pock preferences and the widget refreshes after saving.

## Prayer Time Source

This widget calls AlAdhan's coordinate endpoint:

```text
https://api.aladhan.com/v1/timings/{date}?latitude={lat}&longitude={lng}&method={method}
```

No API key is required.

## Privacy

The widget does not collect analytics and does not send data anywhere except the AlAdhan prayer-time request. In automatic mode, your approximate latitude and longitude are sent to AlAdhan so it can calculate accurate prayer times.

Use manual coordinates if you do not want the widget to request macOS location permission.

## SEO Keywords

Pock prayer time widget, MacBook Touch Bar prayer times, Islamic prayer times macOS, AlAdhan Pock widget, Muslim prayer Touch Bar, iqama countdown widget, Arabic prayer time widget for Mac.

## Development

The widget is written in Swift with AppKit and PockKit.

Useful commands:

```bash
swift build
./build-widget.sh
```

Do not commit local build output:

- `.build/`
- `build/`
- `*.pock/`

## License

MIT
