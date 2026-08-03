# Bead bf-1fv: VerifyReceipt JSON parsing fix

## Status: COMPLETED (2026-07-22)

The fix for bead bf-1fv was already applied in commit `dbc6cbf` in the pdftract repository.

## What was fixed

**Before:** VerifyReceipt ran `verify-receipt <path> <receipt>` without `--json` and compared trimmed stdout to the literal string "true".

**After:** VerifyReceipt now:
1. Passes `--json` to the CLI invocation
2. Decodes a structured `ReceiptVerificationResult` model with fields:
   - `status`: Raw CLI status (ok/fingerprint_mismatch/bbox_mismatch/content_mismatch)
   - `bestIou`: Best span intersection-over-union observed
   - `expectedContentHash`: Expected content hash for comparison
   - `actualContentHash`: Actual content hash found
   - `reason`: Human-readable explanation of failure (nil when valid)
3. Provides computed `valid` property (status == "ok") for convenience

## Files modified

In `~/pdftract/templates/sdk-skeleton/swift/`:
- `Sources/PdftractCodegen/Methods.swift.tera` - Added JSON decoding to verifyReceipt method
- `Sources/PdftractCodegen/Types.swift.tera` - Added ReceiptVerificationResult struct
- `Sources/Pdftract/Pdftract.swift.tera` - Re-exported ReceiptVerificationResult type
- `Tests/PdftractTests/ConformanceTests.swift.tera` - Updated test to use result.valid
- `README.md.tera` - Updated example to use result.valid

## Verification

Ran `pdftract sdk validate --lang swift --sdk-dir /home/coding/pdftract-swift`:
- `Sources/PdftractCodegen/Methods.swift` NOT in modified list (✓ matches template)
- Generated code already contains the fix

## References

- pdftract commit: `dbc6cbf5bf6e2448268c41fff5192b49cab7ac38`
- Commit message: "fix(bf-1fv): decode verify-receipt as structured JSON, not stdout string match"
