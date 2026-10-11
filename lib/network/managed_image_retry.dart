import 'dart:async';

final _managedImageRetryZoneKey = Object();

/// Only reading providers opt in. Covers, APIs and downloads keep their policy.
bool get isManagedImageRetry => Zone.current[_managedImageRetryZoneKey] == true;

T runWithManagedImageRetry<T>(T Function() body) =>
    runZoned(body, zoneValues: {_managedImageRetryZoneKey: true});
