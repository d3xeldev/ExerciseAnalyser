# ExerciseAnalyser / Move Moment

Move Moment is a native SwiftUI Apple Watch research app with an iPhone companion that identifies opportunities for short movement breaks and recommends exercises based on participant choices. It uses HealthKit, EventKit, Core Motion, local notifications, and WidgetKit. The watch owns the study dataset; a bounded summary syncs to its paired iPhone and complete exports transfer on request; no server, account, analytics SDK, or third-party package is required.

## Setup

1. Open `ExerciseAnalyser.xcodeproj` in Xcode with the iOS 27 and watchOS 27 SDKs. The apps currently target iOS/watchOS 27.0. Select **ExerciseAnalyser iPhone** to install the phone app with its embedded Watch app, or **ExerciseAnalyser Watch App** for watch development. The watch continues to run independently.
2. Select **ExerciseAnalyser Watch App** and a watch destination. For a physical watch, configure your signing team, HealthKit, and HealthKit Background Delivery. Provision the App Group `group.com.d3xel.ExerciseAnalyser` for both the app and **MoveMoment Complications**. If you change its identifier, update both entitlements and `ComplicationSnapshot.appGroup`.
3. In **Settings**, request Health, Calendar, Motion, and Notification access. HealthKit access is read-only, and the app never modifies calendar events. **Health setup complete** means setup was completed; HealthKit does not disclose individual read grants.
4. Configure active hours, reminder frequency, exploration rate, and exercises, then enable monitoring. Keep at least one exercise enabled in each effort tier.
5. On Apple Watch, set **Settings → General → Return to Clock → ExerciseAnalyser → Custom → After 1 hour** to keep the timer visible during movement breaks. The app shows this tip before the first timer start; it is also available in watch Settings, exercise information, and iPhone Settings. Acknowledging the tip does not change or verify the system setting.
6. Optionally add Move Moment complications to your watch face and keep Background App Refresh enabled. Use **More → Watch activity** to inspect signal availability and background-monitoring diagnostics.

## iPhone companion

The **ExerciseAnalyser iPhone** scheme launches the native SwiftUI companion, with three tabs:

- **Today:** completed interventions lead the day in a bold header that fades as you scroll. Cards begin halfway down the available screen, with equal 16-point margins and gaps. The wide weekly chart is followed by square cards for missed interventions, steps, exercise, and heart rate, with neutral surfaces, uniform uppercase headers, and per-card footers. The weekly card matches a stat card’s height, with weekday letters above stacked effort-color bars and daily counts below. Sleep remains available under Research → Watch activity. The background glow follows the most-selected effort for the current day (low/mint, moderate/yellow, high/orange), or gray when no selection is available. Selection totals use the full Watch history, counting the current choice for each invitation on its selection day; ties prefer the gentler effort. Older snapshots remain gray until an updated Watch syncs. Controls use the same mint as low effort. The top edge uses the native soft scroll-edge effect. Tap the missed or weekly card to open a sheet with a selectable daily chart and details for one day at a time. Missed totals come from the full watch history and include dismissed, expired, and ignored invitations, attributed to their invitation day; active, cancelled, failed, completed, and explicitly abandoned breaks are excluded. Older watch summaries without missed counts show an unavailable value until an updated watch syncs. Timestamps and missing/older readings remain visible without filling the screen with diagnostics.
- **Research:** your completed breaks, recent invitations, and files to share with your researcher. Watch activity, reading issues, and your study ID are available in secondary details. The most recently received export remains shareable after relaunch.
- **Settings:** phone notification authorization, system Settings shortcut, custom chime and foreground haptics with a preview, connection information, and reported watch permissions and reminder settings. Change study settings and grant sensor permissions on the watch; the phone does not collect duplicate sensor data. Exercise selection and timers also stay on the watch.

Open the phone’s **Settings → Allow notifications** once after installation. Movement invitations and explicit watch snoozes request a coordinated phone notification with the same prompt UUID as the watch request, the same action category, and a bundled 1.2-second PCM chime. Matching request identifiers allow iOS/watchOS to recognize the two requests as one reminder. Both apps register **Choose exercise**, **In 5 minutes**, and **In 10 minutes**, so forwarded alerts retain their actions. Phone delay actions are validated and applied on the watch. Fast Watch Connectivity messages have a queued background fallback; persisted version tracking prevents duplicate or outdated requests. Phone transfers arriving more than 10 seconds after the reminder’s due time are suppressed to avoid a second alert after the watch’s coordination window. Future snoozes can still be scheduled ahead of time. Expired reminders are dropped. Watch cancellation/selection/expiry removes corresponding phone requests when connectivity permits. Timer-end alerts remain on the watch.

**Apple does not guarantee alerts on both devices.** iOS normally routes an alert to either the phone or watch, and connectivity, Focus, silent mode, notification settings, and background execution affect timing. Older builds used different identifiers, which could produce a second watch alert without actions. This version removes those legacy phone requests when launched. Update and open both apps to activate the shared identifier and action handling. A custom three-tap haptic runs only while the iPhone app is active; background vibration belongs to iOS and the user’s Sounds & Haptics settings. The companion cannot override this. See [Apple notification forwarding](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding), [Apple’s guidance on matching notification identifiers](https://developer.apple.com/forums/thread/765669), and [Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity).

Summary sync and reminder relay are local to the paired devices. Full research files transfer only after an export request. A separate phone notification journal accompanies exports when available, distinguishing request acceptance, foreground receipt, and opening from exercise responses. There is no account, server, or cloud sync.

## Using the app

The dashboard has three vertically paged screens: **monitoring status**, **steps today**, and **latest heart rate**. The status screen reports missing permissions, paused monitoring, active monitoring, or quiet hours. Swipe or turn the Digital Crown to move between pages; Settings and More are toolbar shortcuts.

**More → Watch activity** contains the detailed activity, recovery, calendar, motion, battery, and background-monitoring readings. Energy, exercise minutes, standing minutes, distance, HRV, and sleep appear there, not as separate dashboard cards.

Automatic invitations offer exactly three exercises, ordered **Low → Moderate → High**, from a nine-exercise catalog lasting one to five minutes. Notification actions open an exercise screen; press Play to start, pause/resume as needed, and record completion with **I did it** or abandon the break. Timer state survives relaunches, and paused time is excluded.

Fresh entry into the app while an invitation or unfinished break is current opens its original **Low → Moderate → High** exercise options; it does not generate a new set. Dimming and waking the watch preserves the current screen, including a running or paused timer, while the break remains valid. Selecting the same exercise resumes its screen. Choosing a different option resets the timer for the new selection.

An unfinished selected break blocks further reminders for **10 minutes** after selection, the latest pause, or the timer’s end (including its scheduled end if the app was suspended). Opening the app alone does not extend this window. When it elapses, the next check records the break as `ignored` with an `ignored_break` event, preserving the selection without marking it completed or explicitly abandoned. Ignored breaks count as misses for reminder backoff. The watch-face active-break label expires at the same cutoff. Unanswered invitations retain their existing validity window of up to 10 minutes and are recorded as `expired` misses. Other reminder gates, including cooldown, still apply after either window ends.

**More → Take a break** opens the current invitation or unfinished exercise, or creates an in-app invitation without sending a notification. This manual path bypasses automatic opportunity gates, including calendar and inactivity checks, while respecting exercise exclusions. Creating a new manual invitation records `manual_intervention` as its event and delivery reason. It does not set a notification request timestamp, so it is excluded from the notification-based history used for recommendation learning, reminder counts, and cooldowns. Its responses and completed breaks are still stored; distinguish these prompts from automatic reminders in research analysis.

At timer expiry, or the next execution opportunity, the app provides completion feedback and attempts a movement estimate using pedometer or wrist-motion evidence. It also requests a local timer-end notification, subject to permission and system delivery. Missing coverage remains inconclusive, and self-reported completion is stored separately. These estimates are not validated exercise recognition. The app does not create a background workout or write workouts to HealthKit.

## Automatic reminders

Checks run when monitoring starts, relevant settings or permissions change, the app enters the foreground, calendar changes are observed, HealthKit updates arrive, or watchOS grants a background refresh.

The policy requires active monitoring, active hours, readable calendar data, at least seven free minutes, fresh wear/inactivity evidence, and no blocking movement, recovery, battery, cooldown, invitation, or unfinished-exercise condition. Only events explicitly marked **Busy** block reminders, including Busy all-day events. Calendar context retains interval times, not event titles, notes, attendees, locations, or event identifiers. **Settings → Calendars** selects which calendars are checked in foreground, background, and immediately before notification delivery. All calendars is the default and includes newly added calendars; selecting none means events do not block reminders. Selected calendar identifiers are saved in preferences and their research snapshots; calendar names are only displayed in the picker.

Defaults for a new study state are (existing saved settings are preserved):

- 30 minutes of low movement and a 60-minute reminder cooldown.
- Six reminders per local day, between 09:00 and 21:00.
- 30% recommendation exploration after the first recorded selection.

Settings also supports zero cooldown and an unlimited daily limit. The first daily reminder receives priority; after two active hours its inactivity threshold is at most 15 minutes. Repeated dismissals, expirations, or ignored breaks increase cooldown from the second consecutive miss that day; acceptance resets the streak.

The first reminder can wait for a learned weekday/hour preference supported by acceptances on at least two distinct dates and a majority acceptance rate in that hour, with yesterday's latest accepted time as a fallback when the weekday has no resolved history. After a Busy period, the app targets a fresh check two minutes later. Within 15 minutes of the Busy period ending, fewer than 100 recorded steps during that event can replace the usual inactivity-duration requirement; the other gates still apply.

Background refresh is normally requested roughly 15 minutes ahead, adjusted for relevant policy boundaries. Future targets request execution rather than queue unconditional reminders. Before submitting an automatic invitation, the app collects fresh signals and rechecks the calendar; existing future plans are cancelled during evaluation. **watchOS controls execution and notification delivery, so these times and daily delivery are not guaranteed.** Complications display cached results and do not run the detector.

Background checks collect essential steps, movement history, heart rate, resting heart rate, sleep, and recent workouts, alongside calendar, motion, and battery state. Background checks reuse a persisted cache of step history, resting heart rate, and sleep for less than one hour to reduce query work. This optimization does not guarantee four checks per hour. Today’s steps, recent movement, heart rate, workouts, calendar, motion, and battery are still read fresh. Cache entries expire at a local-day or time-zone change and are invalidated by relevant HealthKit updates; cached provenance retains the original read window. Foreground checks bypass the cache and collect additional activity and HRV signals. Missing readings are recorded as unavailable rather than silently treated as zero. Compare collection modes separately when analysing scores.

## Exercise recommendations

Before any selection in the notification-based history, choices are uniformly random within each effort tier. Afterwards, one random draw assigns the whole invitation to exploration or learned preferences:

- **Exploration:** uniform choices within each tier; familiar exercises may repeat.
- **Learned:** choose the highest smoothed selection rate, `(selected + 1) / (offered + 2)`, with random tie-breaking.

Automatic candidates must fit the available window and participant exclusions. Notification request acceptance does not prove that the participant saw the invitation. Selection, dismissal, expiry, completion, and abandonment are recorded separately.

## Watch-face complications

The WidgetKit extension offers five complications:

- **Moment:** monitoring status and the current break, in corner, inline, and rectangular slots.
- **Daily Movement:** daily steps, with a seven-day movement chart in rectangular slots; also supports circular, corner, and inline slots.
- **Movement Breaks:** today's completed breaks, with a seven-day chart in rectangular slots; also supports circular, corner, and inline slots.
- **Daily Effort:** today's completed breaks and low/moderate/high effort shares in a circular ring.
- **Weekly Effort:** effort distribution over the last seven days, in corner and rectangular slots.

The app shares a small App Group snapshot with the extension. The extension cannot read the private study database, query HealthKit, or send notifications. Compact step readings require a check less than 30 minutes old from the same local day; low-movement estimates also require a fresh check. Historical step charts retain recorded daily values rather than applying this 30-minute cutoff. Compact break counts remain available for the snapshot’s local day, while effort and weekly charts use recorded completion dates. Weekly Effort uses a rolling seven-day window in its corner gauge and today plus the preceding six calendar days in its rectangular chart. Timelines handle expiry and day transitions without implying continuous monitoring. Content is marked privacy-sensitive for system redaction.

## Research data

Open **More → Research → Prepare my files** to generate:

- `exercise-study.json`: state, settings, prompts, contexts, and events.
- `exercise-choices.csv`: one row per option in every stored prompt, including manual, failed, or cancelled prompts—not proof of notification delivery or exposure. Includes selection details and outcomes.
- `exercise-events.jsonl`: timestamped events with study identifiers and relevant context.

Sharing destinations depend on the watch configuration. Files can also be retrieved through Xcode device tools. Export preparation is logged separately from sharing; the app cannot confirm a successful transfer.

Local storage consists of `Library/Application Support/Study/study.json` and its append-only journal, `study.json.events.jsonl`. When retrieving raw data, copy the whole Study directory while collection is paused. Corrupt or unsupported data stops monitoring rather than being replaced. Records are not automatically pruned, and uninstalling removes local data, so export regularly.

See [RESEARCH_DATA.md](RESEARCH_DATA.md) for detailed schemas, provenance, event definitions, and analysis limitations.

## Development and validation

### SwiftUI previews

Open the relevant Swift file in Xcode, show the Canvas, and select a named `#Preview`:

- **iPhone:** `PhoneContentView.swift` covers all three tabs, daily movement, active/completed invitations, an unsynced reminder sheet, and errors. `PhoneTodayView.swift` covers the dashboard, welcome, stale/missing readings, dark mode, and accessibility text.
- **Watch:** `ContentView.swift` covers the dashboard, effort selection, More, Settings, permissions, calendars, available exercises, active-hours editor, Watch activity, Research, timer states, completion assessments, exercise information, and the Return to Clock tip. Named variants include empty data, large text, and dimmed display.
- **Complications:** `MoveMomentWidgets.swift` retains previews for every supported widget family.

Use an iPhone destination for phone previews and an Apple Watch destination for watch previews. Install the matching simulator runtime in Xcode if it is missing. Sample data lives in the debug extension of `PhoneModel.swift` and in `WatchPreviewData.swift`; dates are relative to when the preview opens.

Previews use isolated sample models. They do not open the study store, start monitoring/connectivity, request permissions, or schedule notifications. Watch preference edits stay in memory; phone toggles and the watch display-tip acknowledgement use separate preview defaults. Navigation and sheets can be explored, but service actions (including starting/stopping an exercise) are inert: select the named timer/completion variant to inspect that state. Validate actual sensors, alerts, haptics, and lifecycle behavior in the running app on devices.


The app is written in Swift. `Package.swift` exposes its platform-independent core for testing with Swift 6 on macOS 14 or later; it is not another app target.

```sh
swift test
xcodebuild -project ExerciseAnalyser.xcodeproj \
  -scheme 'ExerciseAnalyser Watch App' \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath /tmp/ExerciseAnalyserBuild \
  CODE_SIGNING_ALLOWED=NO build
```

The unsigned build checks compilation only. Use a correctly signed installation to validate App Group sharing and complications.

Project layout:

- `ExerciseAnalyser Watch App/`: SwiftUI screens, app coordination, notifications, and sensor services.
- `ExerciseAnalyser iPhone App/`: native phone screens, local notification delivery/haptics, cached summaries, and export sharing.
- `Companion Shared/`: Watch Connectivity transport shared by both apps.
- `ExerciseAnalyser Watch App/Core/`: opportunity policy, recommendations, timers, storage, and complication snapshots.
- `MoveMoment Complications/`: WidgetKit views, configurations, and previews.
- `Tests/`: core policy, reminder planning, session, journal, and complication tests.

Before collecting study data, validate permissions, Busy-event handling, quiet hours, cooldowns, daily limits, manual interventions, notification responses, timer recovery, complication states, and exports on a physical watch. Run a multiday pilot without an attached debugger to measure background latency, signal coverage, notification delivery, and energy/storage cost. **Watch activity → Background updates** and exported events help distinguish missed wakes from interrupted or suppressed checks.

The opportunity and movement rules are research heuristics, not clinically validated thresholds. Sparse sensor data cannot establish uninterrupted sitting, current sleep, watch wear, or another app's active workout reliably. Simulator tests cannot establish real-device background behavior.

### Companion validation

```sh
xcodebuild -project ExerciseAnalyser.xcodeproj \
  -scheme 'ExerciseAnalyser iPhone' \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/ExerciseAnalyserCompanionBuild \
  CODE_SIGNING_ALLOWED=NO build
```

On a signed, paired iPhone and Watch, test first-run/denied permissions, unlocked and locked phone states, Focus/silent mode, disconnected/reconnected devices, watch and phone snoozes (including a forwarded alert’s delay buttons), late relay suppression, cancellation before and after receipt, opening an expired alert, and complete export transfer/relaunch/sharing. Confirm the custom chime and foreground haptics on hardware. Compare the two devices’ notification observations; simulator/build success cannot establish simultaneous alerts or background delivery. Watch Connectivity’s background transfer APIs require physical paired devices for end-to-end validation.
