# Rust Test Catalog

**Total Tests:** 1

**Numbered Tests:** 1

**Unnumbered Tests:** 0

**Numbered Tests Missing Descriptions:** 0

**Numbering Mismatches:** 0

All numbered test numbers are unique.

This catalog lists all tests in the Rust codebase.

| Test # | Function Name | Description | File |
|--------|---------------|-------------|------|
| test999 | `test999_avrational_is_two_ints_no_padding` | / AVRational must be POD-compatible with ffmpeg's struct (two / `int` fields, no padding) so we can pass it by value across / the FFI boundary. If a future Rust ABI change ever broke this / invariant, the call sites would silently corrupt frame-rate / math; this test pins it down. | src/lib.rs:562 |
---

*Generated from Rust source tree*
*Total tests: 1*
*Total numbered tests: 1*
*Total unnumbered tests: 0*
*Total numbered tests missing descriptions: 0*
*Total numbering mismatches: 0*
