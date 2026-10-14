# ExerciseAnalyser / Move Moment

A native SwiftUI Apple Watch research app that looks for opportunities for short movement breaks. Built on the existing watch-only Xcode project with HealthKit, EventKit, Core Motion, local notifications, and local research storage. No server, account, analytics SDK, or external package is required.

## Run

1. Open `ExerciseAnalyser.xcodeproj` with Xcode 27 (the original project targets watchOS 27).
2. Select **ExerciseAnalyser Watch App** and a watch destination. For hardware, select your signing team and ensure the app ID/provisioning profile supports HealthKit and HealthKit Background Delivery. Enable the App Group `group.com.d3xel.ExerciseAnalyser` for both **ExerciseAnalyser Watch App** and **MoveMoment Complications**. Both targets include matching entitlements; your developer account must provision the group. If you change the group identifier, also change `ComplicationSnapshot.appGroup`.
3. In **Preferences**, request Health, Calendar, Motion, and Notification access. HealthKit access is read-only; the app never modifies the calendar.
4. Adjust active hours, reminder frequency, exploration rate, and available exercises. Enable monitoring. At least one exercise in each effort tier must remain enabled.
5. Add **Moment**, **Daily Movement**, or **Movement Breaks** to your active watch face. Long-press the face, choose Edit, open its complication slots, and select the desired Move Moment complication. Available shapes depend on the watch face. Keep Background App Refresh enabled.
6. In **Your signals**, inspect actual data availability and suppression reasons. In **Study log**, prepare and share the research export. All opportunity checks are automatic; there is no manual check button.

The watch app uses Swift because it relies on native watchOS APIs. `Package.swift` exposes the platform-independent core for tests; it is not an extra application target and has no third-party dependencies.

Preferences disables completed signal connection buttons and refreshes their state when opened or when the app becomes active. Motion, Calendar, and Notifications display their enabled state. **Health configured** means the permission setup was completed, including any denied categories; HealthKit does not reveal individual read grants. Change those grants in system Health settings. Motion authorization is independent of whether activity history is available, and its permission prompt is not limited by the background query timeout.

```sh
swift test
xcodebuild -project ExerciseAnalyser.xcodeproj \
  -scheme 'ExerciseAnalyser Watch App' \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath /tmp/ExerciseAnalyserBuild \
  CODE_SIGNING_ALLOWED=NO build
```

The unsigned command above checks compilation only. App Group sharing requires entitlements in the installed app and extension: run a normally signed Xcode build for complication testing. For a simulator-only command-line build, replace `CODE_SIGNING_ALLOWED=NO` with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES`. An unavailable shared container is recorded as `complication_cache_error`; the complication shows a setup placeholder instead of invented values.

## Opportunity detection

Checks run automatically when monitoring starts, relevant settings/permissions change, the app enters the foreground, calendar data changes while the process is running, HealthKit observer updates arrive, and watchOS grants a background refresh. There is no manual check button.

During active hours, the app requests background refresh roughly 15 minutes ahead, or earlier for a known meeting end, inactivity threshold, invitation expiry, recovery end, or cooldown boundary. Near-term requests have a one-minute floor. During quiet hours it requests the next active-hours start. Pending requests persist across launches. Ordinary checks preserve earlier requests during a 30-minute delay grace period; a later execution opportunity can then replace a stuck request. Foreground/background transitions rearm future requests or replace overdue ones with a future date, at most once per minute. Background launch does not re-submit the task that just woke the app before its callback is handled. Callbacks without metadata consume only an already-due request, preserving newer future requests. The next request is submitted before collecting data so interrupted work does not break the refresh chain.

Every HealthKit sample type already used by the policy has an observer. The app requests `.immediate` delivery, meaning the fastest the system permits, not continuous monitoring: watchOS caps most of these types to hourly and shares execution budget with app refresh. An active-face complication improves access to the approximately four-per-hour background budget; it does not guarantee four executions or a particular latency. More complications do not multiply that budget. No fake workout, audio session, or background polling loop is used.

Overlapping triggers share an evaluation instead of launching redundant queries. Background collection performs one pass; foreground collection permits one follow-up pass. Additional changes are logged for the next system wake. Expiration handlers cancel in-flight evaluation and complete the system task exactly once. Collections delayed beyond 15 seconds are discarded rather than used to trigger an invitation after suspension. Individual HealthKit queries time out after three seconds and motion history after two. Cancellation stops HealthKit queries and resumes pending continuations. Background evaluation has a six-second cancellation deadline, and an app-refresh wrapper releases its OS task after eight seconds if it has not finished. These timers require execution time; they cannot run while watchOS suspends the process. On any subsequent evaluation trigger, work older than 12 seconds is replaced, so a new background wake need not await a check suspended overnight. Evaluation IDs prevent an older task from clearing its replacement. A shared completion gate releases observer and refresh waiters at cancellation/deadline without waiting for an unresponsive framework callback; late cancelled results cannot publish a new opportunity.

Build 2 uses seven HealthKit queries in background checks instead of thirteen: daily/recent steps, movement history (extended to cover a recently ended Busy period when needed), local-watch heart rate, resting heart rate, recorded sleep, and recent workouts. Calendar, motion, and battery checks remain. Active energy, exercise/stand minutes, distance, HRV, and the HRV baseline are collected in foreground checks only. Background omissions are explicitly logged, not reused as fresh readings or treated as zero. The Daily Movement complication still receives fresh step totals; its exercise-minute value may be unavailable after a lightweight check. Compare collection modes separately in research analysis because supplementary score contributions are absent in background checks.

The context includes local time/time zone, calendar busy state and available window, daily and recent steps, active energy, exercise/stand minutes, walking/running distance, watch-local heart rate, resting heart rate, HRV and a historical baseline, recorded sleep, recent workouts, historical motion classification, and battery/charging/power mode.

The policy first applies hard gates: monitoring, active hours, readable calendar, no busy event, a seven-minute free window, no detected travel/movement, sufficient recent activity evidence, recovery checks, battery, cooldown, daily cap, and no outstanding invitation or exercise. It then scores inactivity, available time, daily movement, recovery, and prior receptivity in the same local weekday and hour.

Default parameters: 30 minutes of low movement, 60-minute reminder cooldown, at most three reminders per local calendar day, active between 09:00 and 21:00. Existing saved preferences are preserved. Cooldown choices include 0, 15, 30, and 45 minutes; zero removes the cooldown but keeps the daily cap and outstanding-invitation gate. The first consecutive dismissal/expiry keeps the base cooldown. Starting at the second miss in the same local day, cooldown is multiplied by `1.5^(misses - 1)` (1.5×, 2.25×, 3.375×, and so on). Acceptance breaks the streak. The extra backoff ends at local midnight; an ordinary base cooldown may still cross midnight. The score must reach 60. These are transparent, configurable prototype heuristics, not clinically validated thresholds.

Policy `opportunity-4` retains the first-daily priority introduced in version 2. It prioritizes the first reminder of each local day with a 10-point score contribution. After two hours into the active window, its inactivity threshold is at most 15 minutes; later reminders use the configured threshold. Calendar, wear evidence, movement, recovery, battery, and outstanding-exercise gates still apply. This aims for a suitable daily opportunity, not a guaranteed notification regardless of context.

Low movement requires a recent heart-rate sample from the local watch plus either supported stationary motion history or low recent steps and an earlier movement sample. An explicit HealthKit no-data result for the recent step window can be treated as an empty window only if the same collection successfully reads older step samples and none overlap the recent window. This inference is separately labelled in provenance. Empty/denied/failed history never becomes zero. Sparse data can still suppress reminders; use the log to measure coverage before a participant deployment.

Only calendar events explicitly marked **Busy** block, including Busy all-day events. Cancelled, free, tentative, unavailable, and unspecified events do not block. Only interval start/end times are retained; event titles, notes, attendees, locations, and identifiers are never retained. Calendar access is always required for movement reminders, including installations with the old opt-out setting. Calendar is checked again immediately before submission.

Before the first reminder of a day, repeated acceptance on at least two distinct dates for that weekday establishes an hourly preference when more than half of the resolved offers in that hour were accepted. The strongest smoothed acceptance rate wins, with an earlier-hour tie break. If the weekday has no resolved history, the fallback is yesterday's latest accepted reminder time (including minutes). Delivery times are interpreted in their recorded local time zones. The first reminder waits for that target; quiet hours, activity, calendar, cooldown, and other eligibility gates still apply. With no usable preference, ordinary opportunity detection continues.

The app requests a background check two minutes after a Busy period ends, including after earlier reminders that day. Overlapping/adjacent Busy intervals merge into one period. During the first 15 minutes after it ends, a reminder requires known event movement below the existing 100-step threshold, fresh wear/inactivity evidence, and all other gates. Low event movement replaces the normal inactivity-duration requirement in this window. Step samples overlapping the whole period are counted conservatively (including boundary-crossing samples and potentially overlapping sources), so this can overestimate movement and suppress a reminder. A readable earlier step sample can establish an empty event window; empty/denied/failed history remains unknown.

Future targets request execution rather than queue unconditional local notifications. Existing future requests are cancelled on reconciliation. A reminder is submitted only after fresh health and calendar checks, so changed events or movement can suppress it. watchOS may delay or omit background wakes; preferred times and the two-minute delay are targets, not delivery guarantees.

## Complications

The embedded WidgetKit extension provides three choices, each supporting circular, corner, inline, and rectangular families:

- **Moment:** monitoring/invitation status. The circular gauge shows the last low-movement estimate relative to the configured threshold; the rectangular layout adds the current reason and last check time. Tapping opens the main app/invitation.
- **Daily Movement:** steps, with exercise minutes and last check time in the rectangular layout. Tapping opens Signals. These are recent HealthKit totals, not a new exercise target.
- **Movement Breaks:** today's self-reported completed breaks. The rectangular layout also shows the current exercise/invitation. Tapping opens the study log. Counts are not presented as sensor-verified workouts.

The app atomically publishes a small snapshot into the shared App Group and requests a WidgetKit reload after checks, preference changes, choices, and completion. The extension cannot read the private study database and does not query HealthKit or issue notifications. Display content is marked privacy-sensitive for system redaction. Taps use registered `movemoment://` links and are logged.

Cached activity values become unavailable after 30 minutes or a local-day change; estimates never count upwards as though monitoring were continuous. Timelines include explicit entries for stale-data transitions, planned-reminder start, invitation expiry, and midnight even if the app receives no further execution time. Moment shows a planned reminder time before its invitation becomes available. The last-check timestamp always identifies actual collection, not a timeline refresh. WidgetKit reloads are themselves budgeted and do not run the app's opportunity detector. Xcode previews cover the four families in `MoveMomentWidgets.swift`.

## Recommendations and responses

Every invitation contains exactly three exercises ordered **Low → Moderate → High**. All candidates must fit the free window and participant exclusions.

- Before the first recorded selection: uniform random choices (`coldStartRandom`).
- Afterwards: one invitation-level random draw assigns the entire set to exploration (default 30%) or learned preferences (70%).
- Exploration: uniform selection within each effort tier, independent of past choices. It may repeat familiar exercises; it offers a chance to discover other behavior, not a guaranteed novel or harder exercise.
- Learned: within each tier, maximize the smoothed selection rate `(selected + 1) / (offered + 2)`, with uniform tie-breaking. Offered means an accepted notification request whose intended notification time has arrived, not verified visible exposure. Future plans, failed requests, and plans cancelled before their target time do not count.

The home screen uses vertically paged metric cards (steps, energy, exercise minutes, standing minutes, heart rate, and sleep), with corner shortcuts for Preferences, More, the study log, and the current break. Swipe vertically or turn the Digital Crown to change metrics. Detailed signals and monitoring controls live under More.

Notifications show the three exercise names/durations and provide three actions. Selecting an exercise opens its dedicated workout-style screen, ready to begin. The countdown starts only when Play is pressed. Pause/Resume excludes paused time, and the information button opens instructions and measurement details. Selection, dismissal, expiration without a response, self-reported completion, and abandonment are different outcomes. Duplicate response callbacks cannot create a second selection. Expired/cancelled invitations cannot start an exercise.

The timer persists its running intervals across relaunches. At expiry, a checkmark, encouragement, and success haptic appear. A local end notification is also requested for when the app is inactive (subject to notification permission and system delivery). The app checks movement at expiry or the next wake: walking uses pedometer steps/distance; shoulder, mobility, and chair exercises use wrist movement; marching/circuits can use either. Ankle mobility remains inconclusive because the wrist cannot reliably observe it. Missing sensor coverage is never treated as failure. These are deliberately loose heuristics, not validated exercise recognition.

The timer does not run an artificial background workout or write a workout into HealthKit. Wrist samples are collected only while execution is available; historical pedometer queries use the running intervals and exclude pauses and time after expiry. **I did it** remains a participant report, separate from the automatic movement estimate. An unfinished exercise remains available across relaunches for completion/abandonment feedback.

## Research data

See [RESEARCH_DATA.md](RESEARCH_DATA.md) for the schema, events, units, provenance, probabilities, and analysis limitations.

State uses an atomic snapshot at `Library/Application Support/Study/study.json` plus an append-only diagnostic journal at `study.json.events.jsonl` in the same directory. App exports merge both. If retrieving raw files with Xcode, copy both files, preferably the whole Study directory, while collection is paused; the snapshot alone may omit recent events. On watchOS, writes use file protection available after the first device unlock. A corrupt or unsupported file stops monitoring rather than being replaced. Existing records are not automatically pruned. Uninstalling the app removes local data, so export regularly during a study.

**Study log → Prepare research export** creates:

- `exercise-study.json`: complete state, settings, prompts, candidate history/scores, contexts, and events.
- `exercise-choices.csv`: one row per offered exercise, including selection method and outcomes.
- `exercise-events.jsonl`: one event per line, with participant/session/sequence identifiers and context where relevant.

ShareLink leaves destination selection to the participant/researcher. Supported sharing destinations depend on the watch configuration. For development, the same files can be retrieved from the app container using Xcode device tools. Preparing an export is logged separately from sharing; the app does not claim to know that a transfer succeeded.

## Limits and device validation

watchOS controls background execution and notification presentation. Requesting checks every 15 minutes cannot guarantee three or four executions per hour. Planned reminders reduce dependence on another background wake, but use the last observed calendar and health context: a local notification cannot independently read those signals at delivery. Calendar edits or activity changes while the app is suspended may therefore invalidate an already queued plan without the app learning in time. The app cancels/replans when it next runs or observes a calendar change. Neither daily delivery nor avoidance of previously unknown Busy events can be guaranteed. Local notifications can remain visible until the next app wake, but expired actions are rejected.

HealthKit does not reveal individual read denials. Motion availability depends on hardware/permissions. Sparse historical data cannot reliably establish uninterrupted sitting, sleep right now, watch wear, or whether another app has an active workout. Recent heart rate, movement, charging, quiet hours, and recorded workouts provide conservative proxies. The app does not claim access to unrestricted system Focus state, phone usage, location, every HealthKit type, or continuous raw sensors.

Diagnostic events append one JSON line without re-encoding the growing history. Settings, prompt and response transactions still atomically write a complete snapshot before clearing the journal. Replay uses event sequence numbers to avoid duplicates if cleanup is interrupted. An incomplete final journal line is discarded as an uncommitted append; complete malformed records fail closed. No committed records are pruned. Long deployments should still measure launch/replay and full-snapshot costs.

For refresh troubleshooting, open **Your signals → Background monitoring**. It shows the last actual app-refresh wake, requested next wake, background checks and HealthKit callbacks in the last 24 hours, execution expirations, and the last scheduling error. Foreground checks are excluded from those counts; older versions lack application-state metadata. A stale complication timestamp alone cannot identify the cause. Export the study log to distinguish missing wakes, interrupted checks, policy suppression, and widget rendering delays.

Before collecting thesis data, validate on a physical watch:

1. Grant/deny/revoke each permission; verify unknown/error provenance and no crash or spurious inactivity. Enabling monitoring and changing permissions/settings automatically trigger evaluation.
2. Create Busy/free/tentative/all-day events; verify only explicit Busy blocks. Before the first reminder of a day, create a short Busy event with at least seven minutes free after its end. Verify a fresh check is requested two minutes afterwards. Test fewer than 100 steps, at least 100 steps, missing event movement evidence, overlapping Busy events, and edits/deletions before the check. Suspended execution depends on watchOS granting a wake.
3. Test quiet hours, charging, sparse heart rate, recent workouts, daily caps, and cooldowns, including zero cooldown. Check first-reminder priority versus subsequent reminders, repeated weekday/hour acceptances, previous-day fallback, 1.5× backoff from the second miss, acceptance resetting the streak, and local-midnight reset.
4. Add each complication to compatible slots. Verify paused, unavailable, fresh, expired, and next-day states, and the three tap destinations. Confirm a new completion updates the break count. Xcode previews are useful for layout, but do not validate device execution or App Group provisioning.
5. Launch the installed app without an attached debugger, enable monitoring, and return to the watch face without force-quitting it. Receive a real background invitation; test each action, dismissal, late response, relaunch, and completion. Do not use foreground activity as evidence of background operation.
6. Export files through an available watch sharing destination, reconcile CSV against JSON, and check timestamps/IDs across app restarts. Inspect `background_refresh_started.delaySeconds` and opportunity sources `background_refresh`/`health_update`; distinguish suppressed decisions from missing execution opportunities.
7. Run a multiday pilot to quantify background-check latency, signal coverage, actual notification delivery, and energy/storage cost. Compare active-face complication and no-complication periods. WidgetKit configuration inventory is logged but does not prove a complication was on the active face; record that study condition separately. Simulator tests cannot establish these properties.

## Apple references

- [HealthKit observer queries](https://developer.apple.com/documentation/healthkit/executing-observer-queries)
- [HealthKit background delivery](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:))
- [watchOS background tasks](https://developer.apple.com/documentation/watchkit/using-background-tasks)
- [Actionable watchOS notifications](https://developer.apple.com/documentation/watchos-apps/adding-actions-to-notifications-on-watchos)
- [EventKit access levels](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels)
- [WidgetKit accessory families](https://developer.apple.com/documentation/widgetkit/widgetfamily)
- [Keeping widgets up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
