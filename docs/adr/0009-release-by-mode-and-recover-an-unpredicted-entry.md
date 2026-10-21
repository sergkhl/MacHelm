---
status: accepted
---

# Release by automatic mode alone, and recover an entry the record cannot predict

## Context

On 2026-10-19 at 04:47 local time a development build 7 fan helper on a Mac14,9 (two fans, 2317–6800 RPM) with macOS 26.6.2 left fan 0 stopped in manual mode for about five hours. The helper's own log shows what happened within 2.3 seconds:

1. The smoothed CPU die average reached the 65 °C start. Fan 0 entered manual mode, confirmed, and was given 2322.57 RPM.
2. One reading later the average was 64.68 °C, and control ended at once. The release set fan 0 back to automatic and then wrote a zero target to both fans. Fan 0, now automatic, still reported 2322.57 RPM as its target.
3. The next reading was 65.48 °C. Fan 0 entered manual mode again 40 ms after the release finished, and about 250 ms later it read manual with a target of 0 RPM.

Manual entry admitted a target of the firmware's own only within the fan's range, so the acknowledgement ended as unexpected ownership. That is one of the outcomes after which the helper does not make its one recovery attempt (E-Q1, 2026-10-10), so it held without writing anything. Fan 0 stayed in manual at 0 RPM until the owner chose **Restore automatic now**. The attempt itself would have accepted the state: its start check lets the fan named by an unconfirmed manual entry read manual at any target.

On 2026-10-10 both gaps were recorded as open questions. O-Q2 asked whether the zero reset could come back as a stored target. O-Q3 noted that the acknowledgement refuses what the attempt accepts. Both were left unchanged because neither had been seen, and the hold was thought to end safely. The firmware's rule is still not established. The entry that landed at 0 RPM came 0.6 s after that fan's zero reset. The entry two seconds earlier, with no recent reset, landed in range. A record from 2026-10-10 has a reset fan still reporting its last manual target, and zero twelve seconds later.

## Decision

The owner decided on 2026-10-19. The IDs are the ones the source comments use.

- **Release writes automatic mode only (Z-Q3).** Each fan in manual mode, and the fan named by an unconfirmed command, is set back to automatic. No zero target follows, in a normal stop, in the helper's own attempt, or in Restore automatic now. The hardware adapter still refuses a zero target on a fan that reads manual.
- **A zero entry target is admitted (Z-Q3).** Manual entry accepts a target of 0 as it accepts one within the fan's range. The controller writes its own target in the same cycle.
- **An unpredicted entry keeps the attempt (Z-Q2).** An entry that landed at any other target the record cannot predict ends as `unpredictedEntryTarget`, provided no known fan utility runs. That fan reads manual, and every other fan and the unlock read as recorded. The helper then makes its one bounded attempt to return its fans to automatic. Any other change in fan state still declines it.
- **Control ends after ten seconds below the start (Z-Q4, Z-Q6).** The smoothed average must stay below the start temperature for ten seconds of usable readings. A reading at or above the start, an unusable frame, or a gap of three seconds restarts the count, which also runs during protection. The default profile is 70/85 °C.
- **A hold reaches the owner (Z-Q5, Z-Q7, Z-Q8).** A hold that waits on the owner raises a macOS notification and puts a warning sign on the menu bar item. A hold the helper cleared by itself also raises a notification, because Fan Control then stays paused. Permission is asked when Fan Control is turned on.
- **Holds stay hands-off otherwise (Z-Q9).** Protection temperatures during a hold cause no writes.

## Alternatives

- **Change only one of the two zero-target rules.** Admitting 0 at entry alone works whichever way the firmware produced it, but keeps writing a value whose effect has never been measured. Dropping the reset alone relies on the reset being the cause. The owner chose both.
- **Allow the attempt for any unexpected ownership while no known fan utility runs.** The attempt's start check would still apply. But a change to a fan other than the one being entered is the clearest sign that another program writes fans.
- **Bring back a temperature margin, or hold control for a minimum time after entry.** A 5 °C margin was removed on 2026-10-13. The ten-second wait keeps the start temperature as the point where control ends, adds only a short delay, and matches protection's own cool-down.
- **Act on protection temperatures during a hold.** That means more background work, and writes while another program may be in control. The remaining causes of a hold are rare, and a held fan almost always runs at or above its minimum.

## Consequences

After a release, a fan's target register keeps its last manual value until firmware changes it. Nothing treats that value as a target while the fan reads automatic.

A one-reading dip no longer releases the fans. After the average falls below the start temperature, they stay at their custom minimum for up to ten seconds.

A fan entered at 0 RPM is stopped until the controller's own target follows. If that target does not fit the lease and telemetry window, it is written in the next cycle. If the session ends first and restoration then fails, for example because the fans changed in a way the helper cannot explain, there is no hold. The independent review found this case, so the app treats it like one for the warning sign. It also notifies once that state has lasted ten seconds.

O-Q2's original case is still open: a manual entry that lands after a recovery's settle check has finished. It has not been observed.
