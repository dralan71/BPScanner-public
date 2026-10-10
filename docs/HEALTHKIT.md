# Reading identity and updates

History preserves the HealthKit blood-pressure correlation UUID as the reading ID. Edit and delete query that exact UUID, verify that the correlation and its constituent samples belong to this app, and never fall back to value or timestamp matching. Missing or foreign readings produce an error.

New readings carry a random `com.dralan71.BPScanner.readingID` metadata value on the correlation, SYS/DIA samples, and optional pulse sample. The correlation also records the pulse sample UUID as `com.dralan71.BPScanner.pulseID`. Pulse mutation requires that exact UUID, matching link metadata, and app ownership. Deletion includes the selected correlation and its constituent SYS/DIA samples.

## Older readings

No migration rewrites existing HealthKit data. Existing BP readings retain their HealthKit UUID and remain editable/deletable when owned by BPScanner. For older readings without link metadata, a nearby heart-rate sample may still be displayed, but it is never deleted on the basis of proximity. Updating such a reading saves a newly linked pulse if one is entered and leaves the old unlinked heart-rate sample in Apple Health. Users can manage those legacy heart-rate samples in Apple Health.

## Update recovery

HealthKit samples are immutable, so editing creates a replacement. The service resolves and validates the original, saves the replacement first, then deletes the original by identity. A failed replacement save leaves the original untouched.

If deleting the original fails, the service checks every original sample by UUID before attempting to remove the replacement. If the original is missing any samples, or that check fails, it preserves the replacement and reports that manual recovery may be needed. If rollback itself fails, it also reports a recovery error. These operations are not presented as an atomic transaction. A process interruption between save and delete can leave duplicates; the implementation does not yet persist a recovery journal.

Overlapping edit/delete operations on the same UUID are rejected while a mutation is in progress. Edit and delete failures are shown in the UI. Regression tests use an injected store and never modify actual HealthKit data; physical-device verification remains necessary for HealthKit permissions and store behavior.
