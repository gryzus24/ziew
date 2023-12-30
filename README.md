# ziew -- boring status generator for i3bar

## Description
*ziew* is a more minimal alternative to *i3status*.

## Aspirations
  *ziew* wants:
  * to implement useful widgets using the least amount of syscalls and instructions,
  * to have a small and predictable configuration file,
  * to be compatible with any x86_64 Linux platform,
  * to make you yawn once you understand all the puns.

## Widgets
Widget | Data source
------ | -----------
| TIME | strftime(3)
| MEM  | /proc/meminfo
| CPU  | /proc/stat
| DISK | statfs(2)
| ETH  | netdevice(7), ioctl(2)
| WLAN | netdevice(7), ioctl(2)
| BAT  | /sys/class/power_supply/*

## Files
The configuration file of *ziew* resides at `$XDG_CONFIG_HOME/ziew/config` (usually `~/.config/ziew/config`). See the example configuration file (config) and copy it to this location.

## Configuration
The configuration file consists of *Widget* lines and *Color* lines. Lines consist of fields separated by tabs or spaces. The order of *Widget* lines in the configuration file is reflected in the final status output.

### Widget line

    WIDGET INTERVAL "FORMAT"

    WIDGET   - uppercase name of the widget,
    INTERVAL - refresh interval in deciseconds (1/10 of a second),
    FORMAT   - widget specific format  enclosed in double quotes. Format,
               apart from plain text may contain optional options enclosed in
               squirrelly brackets and optional specifiers after a period.

    Example
      CPU 25 "CPU {%all.1>}"

### Default color line

    FG|BG WIDGET COLOR

    FG|BG  - either FG for foreground color or BG for background color,
    WIDGET - uppercase name of the widget,
    COLOR  - hexadecimal RGB color value (e.g. #99aabb or #9ab, # is optional).

    Example
      FG TIME #8a8

### Conditional color line

    FG|BG WIDGET OPTION [THRESHOLD:COLOR...]

    FG|BG     - either FG for foreground color or BG for background color,
    WIDGET    - uppercase name of the widget,
    OPTION    - name of the option that can be compared (widget specific),
    THRESHOLD - if OPTION's value is greater than or equal to THRESHOLD
                WIDGET's color (FG or BG) will be set to COLOR,
    COLOR     - hexadecimal RGB color value or either left blank or "default"
                for the default color.

    Example
      BG CPU %all 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
      FG CPU %user 0:22a 10:default 60:aa2

All widget format options, specifiers and color options are documented below.

**TIME**

    Format
      This widget is special in that its entire format is documented in
      strftime(3) and not here.

      Example format
        "%A %d.%m ~ %H:%M:%S"

    Colors
      [x] default
      [ ] conditional (unsupported - no options to compare)

      Example color line
        FG TIME #28ab28

**MEM**

    Values are displayed in a human readable form in the power of two units:
    K M G T, or (if available) as a percentage of total memory if prefixed
    with a % sign.

    Format
      Options
        * [%]used      - used memory as reported by free(1),
        * total        - total system memory,
        * [%]free      - memory that is not utilized at all,
        * [%]available - memory available for starting new programs,
        * buffers      - buffers (whatever that means),
        * [%]cached    - memory used for the page cache.

      Optional specifiers
        * precision - number from 0 to 9 inclusive,
        * alignment - either < for left alignment or > for right alignment.

      Example format
        "ram: {used.2<}:{free.2>} [{cached.0}]"

    Colors
      [x] default
      [-] conditional (partial - only % options supported)

      Example color line
        FG MEM %used 0:aaa 50:bbb 60:ccc 70:ddd 80:eee 90:fff

**CPU**

    Values are displayed as a percentage of total possible system cpu usage.

    Format
      Options
        * %user - time spent executing user code,
        * %sys  - time spent executing kernel code,
        * %all  - time spent executing both user and kernel code.

      Optional specifiers
        * precision - number from 0 to 9 inclusive,
        * alignment - either < for left alignment or > for right alignment.

      Example format
        "cpu: {%user.<}+{%sys.>} = {%all}"

    Colors
      [x] default
      [x] conditional

      Example color line
        FG CPU %all 0:aaa 60:a66 80:f66

**DISK**

    Values are displayed in a human readable form in the power of two units:
    K M G T, or (if available) as a percentage of total disk space if prefixed
    with a % sign.

    Required argument at the start of the format text
      <mountpoint>{-}

    Format
      Options
        * [%]used      - used disk space,
        * total        - total disk space,
        * [%]free      - free disk space (with reserved blocks included, e.g.
                         ext4 reserves 5% of total disk space for the super-user),
        * [%]available - available disk space for the normal user.

      Optional specifiers
        * precision - number from 0 to 9 inclusive,
        * alignment - either < for left alignment or > for right alignment.

      Example format
        "/home{-}/home {available}/{total}"

    Colors
      [x] default
      [-] conditional (partial - only % options supported)

      Example color line
        FG DISK %used 60:a66 80:f66

**ETH** and **WLAN**

    Required argument at the start of the format text
      <interface>{-}

    Format
      Options
        * ifname - <interface> name as specified in the argument,
        * inet   - local ipv4 address,
        * flags  - a choice of device flags:
                     * receive (A)ll multicast packets,
                     * valid (B)roadcast address set,
                     * supports (M)ulticast,
                     * interface is in (P)romiscuous mode,
                     * (R)resources allocated,
                     * interface is (U)p/running.
        * state  - interface state, either "up" or "down".

      Optional specifiers
        none

      Example format
        "enp5s0{-}{ifname}: {inet} {flags}"

    Colors
      [x] default
      [-] conditional (partial - only state option supported)

      state: 0 - interface is down,
             1 - interface is up.

      Example color line
        FG ETH state 0:888 1:eee

**BAT**

    Required argument at the start of the format text
      <battery name>{-}

    Format
      Options
        * %fullnow    - charge relative to the current battery capacity,
        * %fulldesign - charge relative to the designed battery capacity,
        * state       - battery state, either "Discharging", "Charging",
                        "Full" or "Not charging".

      Optional specifiers
        * precision - number from 0 to 9 inclusive,
        * alignment - either < for left alignment or > for right alignment.

      Example format
        "BAT0{-}BAT: {%fulldesign.2} {state}"

    Colors
      [x] default
      [x] conditional

      state: 0 - battery is discharging,
             1 - battery is charging,
             2 - battery is full,
             3 - battery is not charging,
             4 - unknown state.

      Example color lines
        FG BAT state 1:4a4 2:4a4
        BG BAT %charge 0:a00 15:220 25:

## Notes and caveats
This is an opinionated piece of software that doesn't even use heap memory, not all widgets implemented by i3status are available.

If you want:
- sink volume and control,
- file monitoring,
- executing scripts,
- non-English weekday names,
- portability ... etc.,

this program is not for you. You should use i3status, i3blocks, polybar or any other more capable program that will satisfy your needs... and eat your cpu :^)
