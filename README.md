# ziew - a tiny status generator for i3bar/swaybar

## Description
*ziew* is a more minimal alternative to *i3status*.

## Goals
* implement useful widgets using the least amount of syscalls and instructions,
* have a small and predictable configuration file,
* be compatible with any x86_64 Linux platform.

## Install

### Files
The configuration file of *ziew* resides at `$XDG_CONFIG_HOME/ziew/config` (usually `~/.config/ziew/config`). See the example configuration file (config) and copy it to this location.

### Prebuilt binary
You can [download the prebuilt binary](https://github.com/gryzus24/ziew/releases/download/v0.0.9/ziew) from the Releases page. If you do not trust it you can always build directly from source.

### Building from source
To build it you will need Zig 0.15.1. Once inside the cloned repository run:

```
zig build -p . -Doptimize=ReleaseSmall -Dstrip
```

The compiled binary will be placed in ./bin, from there you can copy it to somewhere in your $PATH or change `-p` (prefix) e.g. `-p ~/.local` to place the binary in ~/.local/bin. For a debug build, build without the `-Doptimize` and `-Dstrip` options.

## Full documentation

### Configuration
The configuration file consists of *Widget* lines and *Color* lines. Lines consist of fields separated by tabs or spaces. The order of *Widget* lines in the configuration file is reflected in the final status output.

### Widget line

    WIDGET INTERVAL [arg "ARGUMENT"] [format "FORMAT"]

    WIDGET   - uppercase name of the widget,
    INTERVAL - refresh interval in deciseconds (1/10 of a second),
    ARGUMENT - optional widget specific argument enclosed in double quotes,
    FORMAT   - optional widget specific format enclosed in double quotes.

               Format, apart from plain text may contain options which tell the
               widget what information to display. Options are enclosed in
               squirrelly brackets and may contain specifiers that influence
               the formatting of numeric data.

                OPTION[@FLAGS...]:[ALIGNMENT][WIDTH][.PRECISION]

              * OPTION    - widget specific option name,
              * FLAGS     - option specific flag changing what/how value is
                            displayed.
                              * d - show a difference since last refresh
                                    instead of a total,
                              * q - do not display values equal to zero,
              * ALIGNMENT - either < for left alignment or > for right
                            alignment - reserves space for the longest
                            representation of a number (no alignment if
                            unspecified),
              * WIDTH     - number of cells available for the integral part
                            of a number (4 if unspecified),
              * PRECISION - number from 0 to 3 inclusive - specifies digits
                            of precision (adjusted automatically based on
                            width if unspecified).

    Example
      CPU 25 format "CPU {%all:>3} {blkbars} {forks@dq:>}"

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

*Color* lines must come after the *Widget* lines they apply to. You can define multiple widgets and place them in any order you want.

### Widgets
Widget | Data source
------ | -----------
| TIME | strftime(3)
| MEM  | /proc/meminfo
| CPU  | /proc/stat
| DISK | statfs(2)
| NET  | /proc/net/dev, netdevice(7)
| BAT  | /sys/class/power_supply/*
| READ | filesystem

Every option and color configuration for each *Widget* is documented below.

**TIME**

    Displays current date and time.

    Required
      arg "ARGUMENT"

    ARGUMENT
      This widget is special in that its entire argument format is documented
      in the strftime(3) man page and not here.

    Colors
      [+] default
      [ ] conditional (unsupported)

    Example config entry
      TIME 20 arg "%A %d.%m ~ %H:%M:%S"
      FG #28ab28

**MEM**

    Displays memory usage information from /proc/meminfo.

    Values are displayed in a human readable form in the power of two units:
    K M G T, or as a percentage of total memory if prefixed with a % sign.

    Required
      format "FORMAT"

    FORMAT options
      * [%]free      - memory which is not utilized at all,
      * [%]available - memory available for starting new programs,
      * [%]buffers   - memory used for filesystem metadata cache,
      * [%]cached    - memory used for the page cache (excludes buffers),
      * [%]used      - used memory (total - available),
      * total        - total system memory,
      * dirty        - memory waiting to get written back to disk,
      * writeback    - memory actively being written back to disk.

    Colors
      [+] default
      [-] conditional (only %-prefixed options supported)

    Example config entry
      MEM 20 format "mem: {used:<2}:{free:>2} [{cached:.0}]"
      FG %used 0:aaa 50:bbb 60:ccc 70:ddd 80:eee 90:fff

**CPU**

    Displays cpu usage information from /proc/stat.

    Required
      format "FORMAT"

    FORMAT options
      * [%]all  - time spent executing both user and kernel code,
      * [%]user - time spent executing user code,
      * [%]sys  - time spent executing kernel code,
      * intr    - number of serviced interrupts,
      * ctxt    - number of context switches,
      * forks   - number of forks,
      * running - number of processes running right now,
      * blocked - number of processes blocked on I/O right now,
      * softirq - number of serviced software interrupts,
      * brlbars - visualization of %all CPU usage as narrow (Braille
                  characters) bars, one bar per CPU,
      * blkbars - same as above, but needs more space, as it uses actual block
                  characters with more granularity.

    Option flag @d may affect
      intr, ctxt, forks, softirq

    Colors
      [+] default
      [-] conditional (only forks, running, blocked and %-prefixed options
                      supported)

    Example config entry
      CPU 15 format "cpu: {running} {blocked} {brlbars} {all:<}"
      FG %all 0:aaa 60:a66 80:f66

**DISK**

    Displays filesystem statistics obtained via the statfs(2) syscall.

    Values are displayed in a human readable form in the power of two units:
    K M G T, or as a percentage of total filesystem space if prefixed
    with a % sign.

    Required
      arg "<MOUNTPOINT>"
      format "FORMAT"

    FORMAT options
      * arg          - the provided <MOUNTPOINT> name as specified in the
                       argument,
      * [%]used      - used filesystem space,
      * [%]free      - free filesystem space (with reserved blocks included,
                       e.g. ext4 reserves 5% of total filesystem space for
                       the super-user),
      * [%]available - available disk space for the normal user,
      * total        - total filesystem space.

    Colors
      [+] default
      [-] conditional (only %-prefixed options supported)

    Example config entry
      DISK 600 arg /home format "{arg} {available}/{total}"
      FG %used 60:a66 80:f66

**NET**

    Displays current network interface configuration and/or activity.

    Required
      arg "<INTERFACE>"
      format "FORMAT"

    FORMAT options
      * arg   - the provided <INTERFACE> name as specified in the argument,
      * inet  - local IPv4 address,
      * flags - netdevice(7) flag abbreviations, some notable ones:
                  * receive (Al)l multicast packets,
                  * valid (B)roadcast address set,
                  * supports (Mu)lticast,
                  * interface is in (P)romiscuous mode,
                  * (R)resources allocated,
                  * interface is (U)p/running.
      * state - interface state, either "up" or "down",
      * rx_*  - interface receive statistics:
                  * rx_bytes     - data received
                  * rx_pkts      - packets received
                  * rx_errs      - receive errors
                  * rx_drop      - receive packet drops
                  * rx_multicast - multicast packets received
      * tx_*  - interface transmission statistics:
                  * tx_bytes     - data transmitted
                  * tx_pkts      - packets transmitted
                  * tx_errs      - transmission errors
                  * tx_drop      - transmission packet drops

    Option flag @d may affect
      all rx_* and tx_* options

    Colors
      [+] default
      [-] conditional (only state option supported)

      state: 0 - interface is down,
             1 - interface is up.

    Example config entry
      NET arg enp5s0 format "{arg}: {inet} {flags} Rx {rx_bytes@dq:>.0}"
      FG state 0:888 1:eee

**BAT**

    Displays power supply statistics from /sys/class/power_supply/<BATTERY>/*.

    Required
      arg "<BATTERY>"
      format "FORMAT"

    FORMAT options
      * arg         - the <BATTERY> name as specified in the argument,
      * %fullnow    - charge relative to the current battery capacity,
      * %fulldesign - charge relative to the designed battery capacity,
      * state       - battery state, either "Discharging", "Charging",
                      "Full" or "Not charging".

    Colors
      [+] default
      [+] conditional

      state: 0 - battery is discharging,
             1 - battery is charging,
             2 - battery is full,
             3 - battery is not charging,
             4 - unknown state.

    Example config entry
      BAT 300 arg BAT0 format "{arg}: {%fulldesign:>2} {state}"
      FG state 1:4a4 2:4a4
      BG %fulldesign 0:a00 15:220 25:

**READ**

    Reads one line of text from a file given a <FILEPATH>. The line in the file
    may start with optional fields specifying the foreground and/or background
    colors.

    Required
      arg "<FILEPATH>"
      format "FORMAT"

    FORMAT options
      * arg        the <FILEPATH> name as specified in the argument,
      * basename - filename from the <FILEPATH>,
      * content  - line of text from the file with the color fields applied,
      * raw      - line of text from the file.

    Colors
      [+] default
      [-] conditional (read directly from the file)

      color format of the "content" option, specified directly in the file:
        #[FG RGB] #[BG RGB] [TEXT] - apply FG and BG colors
        #[FG RGB] [TEXT]           - apply FG color
        # #[BG RGB] [TEXT]         - apply BG color
        [TEXT]                     - default colors

    Example config entry
      READ 10 arg /home/user/.config/ziew/myfile format "{arg}: {content}"

    Example "myfile" content
      #8a8 greenish text

### Signals
Sending a SIGUSR1 signal to the *ziew* process causes all widgets to be refreshed immediately. You can use the *kill* shell builtin to send the signal:

```
$ kill -s USR1 `pidof ziew`
```

## Notes and caveats
This is an opinionated piece of software that doesn't even use heap memory (explicitly), not all widgets implemented by i3status are available.

If you want:
- sink volume and control,
- file monitoring,
- executing scripts,
- non-English weekday names,
- portability ... etc.,

this program is not for you. You should use i3status, i3blocks, polybar or any other more capable program that will satisfy your needs... and eat your cpu :^)
