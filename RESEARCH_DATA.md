# Research data dictionary — schema 1

## Identity and time

`participantID` is a random installation UUID, not a name, Apple ID, or hardware identifier. Reinstalling creates a new identifier. `schemaVersion` identifies the JSON shape. Policy `epsilon-greedy-1` identifies the recommendation implementation. The separately logged `attributes.opportunityPolicy = opportunity-2` identifies first-daily-reminder prioritization, the revised activity inference, Busy-only calendar filtering, and future reminder planning; older records lack this field. Policy `opportunity-3` (build 2) retains those rules but separates lightweight background collection from full foreground collection. Policy `opportunity-4` adds weekday/hour timing, previous-day fallback, same-day 1.5× backoff starting at the second miss, mandatory calendar availability, whole-event step evidence, and fresh checks instead of queued future movement notifications. App/build/OS/model/locale/time zone are captured by `session_started` events. Optional planning fields preserve compatibility with existing schema-1 records.

Timestamps use UTC ISO 8601 with milliseconds. Each context also contains the local hour and time-zone identifier used for decisions. All timestamps come from the device clock. `sequence` is the authoritative event order within an installation if clock changes cause timestamps to move backwards. `sessionID` groups events from a process launch. JSONL events include their participant ID; the full JSON also carries it at the root.

## Context snapshots

Every `opportunity_evaluated` event carries a context, decision, settings, policy version, check ID, permission-status snapshot, and query duration. Thus suppressed opportunities are part of the dataset, not just successful notifications. Prompts retain their original context and `opportunityCheckID` even if subsequent settings change.

`attributes.collectionMode` identifies `background_essential` versus `foreground_full`. Background checks retain daily/recent steps, movement history (six hours, extended to the start of a recently ended Busy period when needed), local-watch/resting heart rate, sleep, workouts, motion, calendar, and battery. Active energy, exercise/stand minutes, distance, HRV, and HRV baseline are omitted and marked `omitted_for_background_budget` in provenance. Their optional score contributions are absent; separate collection modes in analysis. Missing values do not represent zero or participant denial.

Background checks may reuse persisted step history, resting heart rate, and sleep for less than one hour within the same local day and time zone. Relevant HealthKit observer callbacks invalidate these entries; foreground checks read them again. Cached signals use `signalProvenance.source = HealthKit_cache` and retain their original query window and sample date. `stepHistory` provenance describes the historical query; `stepsToday` is refreshed separately on cache hits. Recent steps, movement, current heart rate, workouts, calendar, motion, and battery are always read again. Cache hits do not extend the original expiry time.

Fields and units:

- `date`, `readCompletedAt`: collection start/end. Signals are queried independently; this is a bounded collection interval, not a simultaneous sensor reading.
- `localHour`, `timeZoneIdentifier`: local scheduling context.
- `calendarAvailable`, `busy`, `freeMinutes`, `busyUntil`: EventKit authorization/availability and time bounds. `busyIntervals` optionally retains start/end pairs from the queried window, including recently ended intervals needed for post-event revalidation. Policy 2 includes only non-cancelled events explicitly marked Busy. No event text or identifiers. Calendar queries follow `settings.selectedCalendarIDs`: absent/null means all calendars, an empty array means none, and other arrays select calendar identifiers. These identifiers are retained in settings snapshots and exports; calendar titles are not retained.
- `lastBusyEventActivity`: optional merged Busy interval plus overlapping step-sample total. Only collected within 15 minutes after the event. `busyEventSteps` provenance records the window and whether zero was inferred from readable earlier history. Boundary-crossing and overlapping-source samples can overcount; unknown history stays absent. A changed interval invalidates this evidence.
- `stepsToday`: cumulative steps since local midnight; `stepsRecent`: last 15 minutes. HealthKit statistics aggregate sources.
- `activeEnergy`: kcal since local midnight.
- `exerciseMinutes`, `standMinutes`: minutes since local midnight.
- `distanceMeters`: walking/running meters since local midnight.
- `heartRate`: latest local-watch sample within one hour, in bpm, with sample timestamp. Inactivity requires freshness within 20 minutes.
- `restingHeartRate`: latest bpm sample within seven days; timestamp included.
- `heartRateVariability`: latest SDNN in milliseconds within 24 hours; timestamp included.
- `hrvBaseline`: median of at least three HRV samples between seven days ago and one day ago.
- `sleepHours`: total recorded asleep time within the previous 24 hours. Overlapping sources/stages are merged; awake/in-bed-only records are excluded. This is not a guarantee that the entire night was recorded.
- `lastWorkoutEnd`: latest recorded workout end within 24 hours. This does not identify an ongoing workout in another app.
- `lastMovement`: latest end of a step sample containing at least 20 steps in the movement-history query window (normally six hours). This is a heuristic, not a gait/sitting classifier.
- `motion`: stationary/walking/running/cycling/automotive/unknown based on historical Core Motion transitions, excluding low-confidence results.
- `stationaryMinutes`, `motionObservedAt`: estimated consecutive stationary interval (capped at three hours), and time of the historical query. Observation time is not a fresh raw sensor timestamp.
- `batteryLevel`: fraction 0–1; absent when unknown. `charging`, `lowPower`: device conditions.
- `issues`: unavailable/failed reads; `signalProvenance`: source, unit, queried window, sample date where meaningful, and availability classification.

Absent numeric fields mean unknown, never zero. Provenance uses `available`, `no_data_or_denied`, `query_failed`, `unavailable_or_unknown`, or `not_authorized`. HealthKit deliberately makes no samples and denied reads indistinguishable. An explicit no-data result for recent steps becomes zero only when a successful six-hour history query contains older readable samples and none overlap the last 15 minutes. This is recorded with source `HealthKit_history_inference` and availability `inferred_empty_window_from_readable_history`; retain it as an inference rather than a measured zero. Empty/denied/failed history cannot support it. Inactivity still requires recent local-watch heart rate. Never infer consent from these values. Background read failure can also reflect protected data or execution limits.

The decision stores `shouldNotify`, `score` (0–100), individual `scoreContributions`, the derived `inactivityMinutes`, human-readable reasons, and `availableMinutes`. Hard gates return score zero and all applicable suppression reasons. An eligible decision can still produce no notification because notification permission is unavailable, an effort tier has no eligible exercises, or scheduling/storage fails; inspect subsequent events.

## Invitations and treatment assignment

Each prompt has a UUID, creation/expiration times, policy and settings snapshots, an opportunity check ID, a method, method probability, seed, and three ordered options.

Legacy policy 2 adds optional `plannedFor` and `deliveryReason` (`after_busy_event`, `predicted_inactivity_threshold`, or `immediate_opportunity`). `createdAt` and the context timestamp remain the original collection time; `plannedFor` is the future notification target. The prompt's decision records the planned window separately from the original suppressed `opportunity_evaluated` decision linked by check ID. A planned score of 60 with `planned_calendar_window` is a planning eligibility marker, not a measured delivery-time opportunity score. Treat planned and immediate invitations as distinct timing strata.

Before the first due reminder of each local day, decisions receive a 10-point priority contribution and, after two active-window hours, an inactivity target of at most 15 minutes. Evaluations log `effectiveInactivityMinutes`. Policy 4 can instead use known movement below 100 steps across a Busy period ending 2–15 minutes earlier; wear/inactivity evidence and all other gates still apply.

Policy 4 targets the strongest weekday/hour with acceptances on at least two distinct dates and acceptance of more than half its resolved offers; smoothed rate `(accepted + 1)/(resolved + 2)` ranks eligible hours, then earlier hour breaks ties. With no resolved history for that weekday, yesterday's latest accepted delivery time is reused. Historical delivery times use the recorded local time zone, not plan creation time. Before today's first reminder, opportunities wait until that preferred time. Scoring receptivity now also uses weekday/hour rather than three-hour buckets.

Same-day consecutive dismissals/expirations use base cooldown through the first miss, then `1.5^(misses - 1)` from the second. Acceptance breaks the streak. Additional backoff is clipped at local midnight while preserving any base cooldown that crosses midnight. Zero stays zero. Expiration is a proxy for nonresponse, not proof the notification was seen.

Policy 4 requests background execution at preferred and post-event times and only submits immediate notifications after fresh checks. No new future movement notification is queued. Legacy future requests are cancelled on reconciliation and retained for auditing. watchOS controls actual execution; target times are not guarantees.

`method` values:

- `coldStartRandom`: no selection exists among scheduled historical invitations. Method probability is 1; this is a separate analysis stratum, not randomized assignment to the learned arm.
- `randomExploration`: assigned with the configured exploration rate, independently of preference history.
- `learned`: assigned with probability one minus the exploration rate.

Each option stores the entire exercise definition (stable ID, title, effort, duration, instructions), candidate IDs, preference scores, exposure counts, selection counts, and `selectionProbability` **conditional on its method**. In exploration it is `1 / eligible_count`; in learned selection it is `1 / best_score_tie_count`.

The probability of the recorded **method and full ordered slate jointly** is `methodProbability × product(option.selectionProbability)`, exported as `slate_assignment_probability` in CSV. This is not the marginal probability of an exercise across both methods, and it is not the probability that a notification is delivered or selected. Scores/counts are captured before the new invitation is added to history.

`randomizationSeed` is a decimal string, preserving all 64 bits. `StudyRandom` uses SplitMix64; the seed plus original candidate order/history and matching policy/Swift random-sampling implementation permits replay. The stored actual assignment/options/probabilities remain the primary audit record.

Selection rate is `(chosen + 1) / (scheduled_offers + 2)` for each exercise. Notification-center acceptance is the exposure proxy for immediate invitations. Future plans count only once `plannedFor` is due; failed requests and plans cancelled before their target time are excluded. A later cancellation does not erase an already due exposure proxy; `cancelledAt` records the distinction. The app cannot observe every actual screen impression, so due but unseen requests can affect learning. Keep this limitation explicit when analyzing preference effects.

## Outcomes

`status` is prepared/scheduled/selected/dismissed/expired/ignored/cancelled/failed. `scheduledAt` is notification-center acceptance time, even for a request queued for later. Scheduling does not prove presentation. `expiresAt` is relative to `plannedFor` for future requests; they cannot be selected beforehand. Daily caps, cooldown, and learning use the effective notification time (`plannedFor` for due plans, otherwise `scheduledAt`), not time spent waiting in the queue. `selectedExerciseID` and `respondedAt` record the current accepted selection; explicit reselections update them and are logged separately. Duplicate notification responses do not change them. `completedAt` is a self-report; `abandonedAt` records a separate negative completion report. Completion is not automatically inferred from timer expiry.

CSV `response_latency_seconds` is response time minus the effective notification time (or creation when immediate scheduling was interrupted). It is not latency from an observed delivery, which is generally unavailable. CSV adds `planned_for`, `delivery_reason`, `cancelled_at`, and `notification_requested_at` (the acceptance timestamp) for reproducible separation of queue time and response time. Explicit dismissal has a response timestamp but no exercise. Expiration records no response and does not prove the notification was seen or ignored. Old actions rejected after expiry/cancellation are not preferences and do not train the recommender.

### Exercise timer and movement evidence

Optional `exerciseSession` on each prompt preserves compatibility with older exports. Selection alone never starts it. `startedAt` records the first Play; `runningSince` and closed `intervals` record active time; `endedAt` is the deadline, even when the app wakes late. Pauses and time after expiry are excluded from evidence windows.

`exerciseSession.assessment` stores `outcome` (`movementDetected`, `littleMovement`, or `inconclusive`), an explanation, policy version `movement-check-1`, and evidence: optional pedometer steps/distance plus wrist movement/observed seconds. A movement second contains an accelerometer delta above 0.08 g at 10 Hz. Walking thresholds are 0.3 steps per timer second (0.5 for brisk walking), or half that target in meters. Wrist targets are 12% of duration for shoulders and 20% for other supported exercises; marching/circuits also accept 0.25 steps per second. Low wrist movement is reported only with at least 70% temporal coverage. Ankle mobility always stays inconclusive. These thresholds are unvalidated proxies and do not establish exercise execution, technique, or physiological benefit. Background suspension or permission denial can leave insufficient evidence.

`exercise_started`, `exercise_paused`, `exercise_resumed`, `exercise_timer_ended`, and `exercise_movement_assessed` log the lifecycle. `exercise_alert_unavailable` records an end-notification scheduling error. Timer expiry and movement estimates do not set `completedAt`; only the explicit **I did it** report does. Full timer/evidence data are in the JSON export; existing CSV completion fields retain their self-report meaning.

## Event stream

New runtime events and completed evaluations include `attributes.applicationState` (`active`, `inactive`, `background`, or `unknown`). Do not infer background execution from an old record lacking this field merely because its source is `health_update`.

Every event has a unique `id`, monotonic `sequence`, participant/session IDs, timestamp, `kind`, `source`, policy version, settings snapshot, and optional prompt/exercise IDs, detail, attributes, context, and decision.

- `session_started`, `foreground_entered`, `background_entered`: runtime context and app lifecycle.
- `permission_requested`, `permission_result`, `permission_error`: permission flow and observable result. HealthKit result explicitly does not report individual read grants.
- `settings_changed`: full new settings; existing unresolved invitations are cancelled and logged as `cancelled_settings_changed`.
- `background_refresh_requested`, `background_refresh_rearmed`, `background_refresh_accepted`, `background_refresh_failed`: requested wakeups and scheduling outcomes. Attributes include request ID, preferred date, reason, and scheduler version (`opportunistic-refresh-4`; older records use versions 1–3). Version 4 adds learned-time wake targets, two-minute post-event checks, and the shared same-day cooldown calculation. Acceptance is not execution. Future rearmed requests retain their date/ID. Overdue replacements receive a new ID and include `replacesOverdueRequestID` and `overdueSeconds`. An overdue local marker can be replaced after a 30-minute grace period, or at a foreground/background lifecycle transition; this does not prove the OS lost the original request.
- `background_refresh_started`: actual watchOS app-refresh callback, with its request metadata and `delaySeconds` relative to the preferred date where metadata is available. Negative values are possible after clock changes. A callback without metadata remains observable but has no inferred latency. `metadataPresent` and `pendingRequestConsumed` describe callback matching.
- `background_refresh_completed`: wall-clock duration of handling the callback. An absent completion after a start can indicate interruption; it is not automatically labelled a policy suppression.
- `background_refresh_expired`: watchOS ended the execution window; the evaluator is cancelled and the task completed without reporting a normal completion.
- `background_refresh_deactivated`: monitoring was paused. An already-requested OS callback may still arrive but will not collect data or perpetuate the schedule.
- `health_observer_received`: callback arrival before coalescing/collection, including sample type and actual application state. It is not necessarily a completed check or a background wake.
- `health_background_registered`, `health_background_error`: per-sample-type registration outcome. Requested frequency is `immediate`; effective frequency is system-limited, not assumed to match the request.
- `check_started`, `check_coalesced`, `check_cancelled`, `check_failed`, `check_deferred_to_next_wake`: evaluation lifecycle. Health-triggered starts include `sampleType`. Overlapping triggers await the active check; only foreground checks may run a second pass with source `coalesced_update`. Background work stops after one pass. Further changes await the next wake. `check_cancelled` also records suspended/slow collection exceeding 15 seconds.
- `opportunity_evaluated`: collected context, collection mode, decision, permissions, query duration, and check ID for every completed evaluation, including suppressed ones.
- `check_deadline_exceeded`: the app requested cancellation after its evaluation budget elapsed. `check_recovered`: a later trigger replaced work left waiting beyond 12 seconds, with elapsed duration. Neither is proof of continuous CPU execution. The eight-second app-refresh watchdog also uses `background_refresh_expired`; `attributes.reason` distinguishes `app_8_second_deadline` from `watchOS_expiration`.
- `no_eligible_options`: no complete three-tier slate could be formed.
- `prompt_prepared`, `notification_scheduled`, `notification_failed`, `schedule_reconciled`: persisted intent and notification-center outcome, including recovery from interrupted scheduling.
- `planned_reminder_prepared`: legacy future notification intent, with target timestamp, reason, and opportunity-policy version. `planned_reminder_cancelled`: an observed calendar/context change or a fresh immediate opportunity invalidated/replaced the queued plan. Keep cancelled plans in the audit dataset; exclude those cancelled before their target time from offered-exercise exposures.
- `schedule_evidence_from_response`: a notification response proved the request existed after scheduling was interrupted. The unavailable original scheduling timestamp is replaced by creation time as an explicitly logged proxy; exclude these latencies if exact request timing matters.
- `notification_cancelled_deadline`: a notification scheduling callback returned after cancellation and its still-prepared request was cancelled.
- `foreground_received`: the notification reached the foreground delegate; not a generic delivery receipt.
- `opened`: default notification tap, separate from an exercise selection.
- `selected`, `dismissed`: first valid choice/dismissal, with response source (`app` or `notification`).
- `response_ignored`: a duplicate or terminal-status callback, with prior status; it never changes the first response or trains learning again.
- `response_rejected`: unknown/expired invalid response; detail provides the reason.
- `ignored_break`: an unfinished selected break passed its ten-minute feedback window. Prompt status becomes `ignored`; selection and timer evidence remain stored, while completion and abandonment remain unset. `attributes.ignoredAt` is the cutoff as Unix seconds; the event date is reconciliation time. This is a policy classification, not proof of deliberate ignoring. It counts as a miss for reminder backoff.
- `exercise_reselected`: an explicit choice of another option from the same invitation, with `previousExerciseID`. The new selection resets its timer and selection window.
- `expired_no_response`: observation at the next check that an invitation's validity window elapsed. Event time is reconciliation time; use prompt `expiresAt` for the intended cutoff.
- `completed_self_report`, `abandoned`: distinct completion outcomes.
- `export_prepared`: a local export was requested; not a sharing receipt.
- `complication_snapshot_published`, `complication_cache_error`: shared-snapshot write and widget reload request, or a storage/App Group error. Publication does not prove the face rendered new data.
- `complication_configurations_observed`, `complication_configurations_error`: WidgetKit's configured kinds/families, observed on foreground entry. Configured does not establish currently visible on the active watch face. Do not use this as definitive treatment assignment for a with/without-complication experiment.
- `complication_opened`: a complication URL was opened, including its kind. This records interaction, not passive impressions or how long it was visible.

There is no manual-check control in the proactive app. Automatic sources also include `settings_changed`, `health_permission_changed`, `calendar_permission_changed`, `motion_permission_changed`, and `notification_permission_changed`. Earlier datasets may contain legacy `manual_check` events; keep them distinguishable from background triggers.

The WidgetKit extension reads only a separate minimal snapshot (status, last-check time, low-movement estimate, steps, exercise minutes, daily reported completions, invitation start/expiry, and optional current exercise title). Participant IDs, calendar intervals, heart-rate data, recommendation history, and research events are not shared with the extension. Widget timeline refreshes never trigger health collection or research notification decisions, and never advance the last-check timestamp without collection.

## Analysis guidance

Use all evaluated opportunities to quantify eligibility and data coverage; use scheduled invitations for acceptance/adherence outcomes, with separate flags for unknown delivery. Group by participant and retain settings/policy versions. Separate cold start, learned, and randomized exploration. Analyze selection effort separately from exercise identity and self-reported completion.

Within-method choice probabilities and invitation-level assignment probabilities support policy-aware analyses, but this implementation is not by itself a preregistered randomized trial. Timing adapts to historical responses, participants can change settings, treatment labels are visible, and actual notification exposure is incompletely observed. Random exploration offers different options; it does not establish causal behavior change. Long-term change needs a defined study protocol, baseline/follow-up measures, and an analysis plan.

Storage is entirely local and retains the full history without automatic pruning. Exports contain sensitive health-derived context, even though identifiers are pseudonymous and calendar contents are excluded. Use the thesis study's agreed handling and retention process. The app has no remote upload endpoint.

## Diagnostic journal (build 2)

Diagnostic events and evaluated opportunities append to `Study/study.json.events.jsonl`; mutations to settings/prompts/responses atomically checkpoint the merged state in `Study/study.json` and then remove the journal. Exports include both automatically. Raw device retrieval must include both files from a quiescent Study directory. Event sequence and participant identity are checked on replay; a checkpointed sequence is not added twice. Only a final incomplete line can be discarded as an uncommitted write; corruption in a complete record stops loading. A successful append means the file write succeeded, not that physical storage survives every possible power failure. No committed history is intentionally pruned.

## iPhone companion

The watch remains authoritative for opportunity checks, recommendation assignment, exercise responses, settings, and timers. A bounded `CompanionSnapshot` (wire schema 1) transfers the last seven calendar days of activity, the latest 30 invitation summaries, the latest 40 event summaries, permission/configuration summaries, and lifetime counts using Watch Connectivity application context. It is a UI projection, not the research dataset; timestamps use Codable’s reference-date encoding on this private wire format. No calendar identifiers, calendar text, or full raw contexts are included in that projection. The phone caches it locally with file protection until first unlock. Watch permissions are reported status, not phone authorization grants. Snapshot age and signal check/sample age are separate.

After a watch notification request succeeds, a separate phone request is attempted using a prompt-ID-keyed packet. The fast and background paths may both deliver; a persisted timestamp ledger suppresses duplicates, earlier versions, expired invitations, and packets older than 24 hours. Snoozes retain their due date; cancellation packets remove phone requests when received. Connectivity delays, suspension, permission changes, Focus, and Apple notification routing can prevent simultaneous delivery. A cancellation arriving after presentation cannot undo exposure. Both requests now use the same prompt UUID and action category to enable system coordination. The previous phone-only `movement.` request prefix caused duplicate watch alerts and is removed on phone launch. Phone relay attempts more than 10 seconds after the original due time are suppressed (`late_relay_skipped`); future snoozes remain eligible. This is a coordination policy, not proof of watch presentation. These are delivery limitations to measure during a paired-device pilot, not evidence of participant non-adherence. Watch scheduling records do not prove phone receipt.

When the phone receives or handles reminders, it appends `phone-notification-events.jsonl` in its protected Companion directory, separately from the watch journal. Fields are `date` (ISO 8601, phone clock), `kind`, optional `promptID`, and `detail`. Kinds are `request_accepted`, `request_failed`, `permission_disabled`, `disabled`, `cancelled`, `foreground_received`, `opened`, `late_relay_skipped`, `snooze_requested`, and `dismissed`. Request acceptance is not delivery. `foreground_received` is an observed callback while the phone app is open. Opening a phone reminder does not select or complete an exercise. Phone dismissal does not mutate watch exercise state. A phone snooze request is applied only if it reaches the watch within 60 seconds, refers to the current unexpired invitation window, and asks for 5 or 10 minutes; the watch records `companion_snooze_received` or `companion_snooze_rejected` before its usual snooze event. Forwarded background actions run on the originating device, so a delay tapped on the watch may take this same phone-to-watch path. Join these records to watch prompts by `promptID`; do not include them in the watch’s `sequence` ordering or infer background delivery from absence of a foreground callback. Records currently capture processing observations, not an authoritative cross-device delivery trace.

**Research → Request complete export** asks the watch to prepare all three original research files in an immutable per-request directory and transfer them to the phone. The `companion_export_prepared` watch event records preparation, not receipt/sharing. The phone exposes a batch for sharing only after all three files arrive and includes a copy of its local notification journal when available. Exports persist across phone app relaunches. The notification journal may include prompts from previous paired-watch installations; join by prompt ID, not the most recent participant ID. Sharing is explicit and no server is involved. Neither device automatically prunes research records or received export batches.
