# MoonRise icon assets

- `logo/moonrise-icon-master.png`: 1024x1024 transparent master
- `logo/moonrise-icon-*.png`: transparent PNG exports
- `MoonRise.iconset/`: standard macOS iconset source images

## Build a macOS ICNS file

On macOS, run:

```bash
iconutil -c icns MoonRise.iconset -o MoonRise.icns
```

The PNG files have transparent backgrounds. The iconset is source material for
`iconutil`; it is not itself a compiled `.icns` file.
