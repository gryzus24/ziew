# ziew -- boring status generator for i3bar

## Description
*ziew* is a more minimal alternative to *i3status*.

## Aspirations
*ziew* wants:
* to implement useful widgets using the least amount of syscalls and instructions,
* to have a small and predictable configuration file,
* to be compatible with any x86_64 Linux platform.

## Widgets
Widget | Data source
------ | -----------
| TIME | strftime(3)
| MEM  | /proc/meminfo
| CPU  | /proc/stat
| DISK | statfs(2)
| NET  | netdevice(7), ioctl(2)
| BAT  | /sys/class/power_supply/*
| READ | filesystem

## Files
The configuration file of *ziew* resides at `$XDG_CONFIG_HOME/ziew/config` (usually `~/.config/ziew/config`). See the example configuration file (config) and copy it to this location.

## Configuration
The configuration file consists of *Widget* lines and *Color* lines. Lines consist of fields separated by tabs or spaces. The order of *Widget* lines in the configuration file is reflected in the final status output.

### Widget line

    WIDGET INTERVAL "FORMAT"

    WIDGET   - uppercase name of the widget,
    INTERVAL - refresh interval in deciseconds (1/10 of a second),
    FORMAT   - widget specific format enclosed in double quotes. Format,
               apart from plain text may contain options which tell the widget
               what information to display. Options are enclosed in squirrelly
               brackets and may contain specifiers after a period:

                 {OPTION.[PRECISION][ALIGNMENT]}

               * OPTION    - widget specific option name,
               * PRECISION - number from 0 to 3 inclusive - specifies digits
                             of precision (0 if left unspecified),
               * ALIGNMENT - either < for left alignment or > for right
                             alignment - reserves space for the longest
                             representation of a number (no alignment if left
                             unspecified).

    Example
      CPU 25 "CPU {%all.1>}"

### Default color line

    FG|BG COLOR

    FG|BG - either FG for foreground color or BG for background color,
    COLOR - hexadecimal RGB color value (e.g. #99aabb or #9ab, # is optional).

    Example
      FG TIME #8a8

### Conditional color line

    FG|BG OPTION [THRESHOLD:COLOR...]

    FG|BG     - either FG for foreground color or BG for background color,
    OPTION    - name of the option that can be compared (widget specific),
    THRESHOLD - if OPTION's value is greater than or equal to THRESHOLD
                widget's color (FG or BG) will be set to COLOR,
    COLOR     - hexadecimal RGB color value or either left blank or "default"
                for the default color.

    Example
      BG CPU %all 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
      FG CPU %user 0:22a 10:default 60:aa2

*Color* lines must come after the *Widget* lines they apply to. You can define multiple widgets and place them in any order you want, but with the following limitations:
* maximum number of widgets is 16,
* maximum number of colors is 100,

### Signals
Sending a SIGUSR1 signal to the *ziew* process causes all widgets to be refreshed immediately. You can use the *kill* shell builtin to send the signal:

```console
$ kill -s USR1 `pidof ziew`
```

### Full documentation
Every option and supported color configuration for each *Widget* is documented below.

**TIME**

    Format
      This widget is special in that its entire format is documented in
      strftime(3) and not here.

      Specifiers
        unsupported

    Colors
      [x] default
      [ ] conditional (unsupported - no options to compare)

    Example config entry
      TIME 20 "%A %d.%m ~ %H:%M:%S"
      FG #28ab28

**MEM**

    Values are displayed in a human readable form in the power of two units:
    K M G T, or (if available) as a percentage of total memory if prefixed
    with a % sign.

    Format
      Options
        * [%]used      - used memory (total - available),
        * total        - total system memory,
        * [%]free      - memory which is not utilized at all,
        * [%]available - memory available for starting new programs,
        * buffers      - memory used for filesystem metadata cache,
        * [%]cached    - memory used for the page cache (excludes buffers),
        * dirty        - memory waiting to get written back to the disk,
        * writeback    - memory actively being written back to the disk.

      Specifiers
        [x] precision
        [x] alignment

    Colors
      [x] default
      [-] conditional (partial - only % options supported)

    Example config entry
      MEM 20 "mem: {used.2<}:{free.2>} [{cached.0}]"
      FG %used 0:aaa 50:bbb 60:ccc 70:ddd 80:eee 90:fff

**CPU**

    Values are displayed as a percentage of total possible system cpu usage.

    Format
      Options
        * %user - time spent executing user code,
        * %sys  - time spent executing kernel code,
        * %all  - time spent executing both user and kernel code.

      Specifiers
        [x] precision
        [x] alignment

    Colors
      [x] default
      [x] conditional

    Example config entry
      CPU 15 "cpu: {%user.<}+{%sys.>} = {%all}"
      FG %all 0:aaa 60:a66 80:f66

**DISK**

    Values are displayed in a human readable form in the power of two units:
    K M G T, or (if available) as a percentage of total disk space if prefixed
    with a % sign.

    Required argument at the beginning of the format text
      <mountpoint>{-}

    Format
      Options
        * [%]used      - used disk space,
        * total        - total disk space,
        * [%]free      - free disk space (with reserved blocks included, e.g.
                         ext4 reserves 5% of total disk space for the super-user),
        * [%]available - available disk space for the normal user.

      Specifiers
        [x] precision
        [x] alignment

    Colors
      [x] default
      [-] conditional (partial - only % options supported)

    Example config entry
      DISK 600 "/home{-}/home {available}/{total}"
      FG %used 60:a66 80:f66

**NET**

    Required argument at the beginning of the format text
      <interface>{-}

    Format
      Options
        * ifname - <interface> name as specified in the argument,
        * inet   - local IPv4 address,
        * flags  - a choice of device flags:
                     * receive (A)ll multicast packets,
                     * valid (B)roadcast address set,
                     * supports (M)ulticast,
                     * interface is in (P)romiscuous mode,
                     * (R)resources allocated,
                     * interface is (U)p/running.
        * state  - interface state, either "up" or "down".

      Specifiers
        unsupported

    Colors
      [x] default
      [-] conditional (partial - only state option supported)

      state: 0 - interface is down,
             1 - interface is up.

    Example config entry
      NET "enp5s0{-}{ifname}: {inet} {flags}"
      FG state 0:888 1:eee

**BAT**

    Required argument at the beginning of the format text
      <battery name>{-}

    Format
      Options
        * %fullnow    - charge relative to the current battery capacity,
        * %fulldesign - charge relative to the designed battery capacity,
        * state       - battery state, either "Discharging", "Charging",
                        "Full" or "Not charging".

      Specifiers
        [-] precision (partial - state option unsupported)
        [-] alignment (partial - state option unsupported)

    Colors
      [x] default
      [x] conditional

      state: 0 - battery is discharging,
             1 - battery is charging,
             2 - battery is full,
             3 - battery is not charging,
             4 - unknown state.

    Example config entry
      BAT 300 "BAT0{-}BAT: {%fulldesign.2} {state}"
      FG state 1:4a4 2:4a4
      BG %charge 0:a00 15:220 25:

**READ**

    This widget reads one line of text from a file given a <filepath>. The line
    may start with optional fields specifying the foreground and/or background
    colors.

    Required argument at the beginning of the format text
      <filepath>{-}

    Format
      Options
        * basename - filename from <filepath>,
        * content  - line of text from the file with the color fields applied,
        * raw      - line of text from the file.

      Specifiers
        unsupported

    Colors
      [x] default
      [ ] conditional (unsupported - read directly from the file)

      color format of the "content" option, specified directly in the file:
        #[FG RGB] #[BG RGB] [TEXT] - apply FG and BG colors
        #[FG RGB] [TEXT]           - apply FG color
        # #[BG RGB] [TEXT]         - apply BG color
        [TEXT]                     - default colors

    Example config entry
      READ 0 "/home/user/.config/ziew/myfile{-}{basename}: {content}"

    Example "myfile" content
      #8a8 greenish text

## Notes and caveats
This is an opinionated piece of software that doesn't even use heap memory (explicitly), not all widgets implemented by i3status are available.

If you want:
- sink volume and control,
- file monitoring,
- executing scripts,
- non-English weekday names,
- portability ... etc.,

this program is not for you. You should use i3status, i3blocks, polybar or any other more capable program that will satisfy your needs... and eat your cpu :^)
