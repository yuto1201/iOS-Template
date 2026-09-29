# Legacy Simulator resource manager fixture

`ios-simulator-resource.rb` is the Mac-wide Simulator resource manager exactly as it shipped before D-063 (template commit `1b87502`). Repositories that still use the old tools run this version. `tools/tests/test-ios-simulator-resource.sh` uses it only to fix how that manager sees dedicated Simulator leases; it is never used for verification.
