# Startup parameter storage for long working directories

Decoding the override is separate from reserving space for it. Both initial
process startup and reconstruction of a child's server-supplied parameters
previously reserved only `MAX_PATH` WCHARs for the current directory. Copying
260 or more UTF-16 code units (before the NUL) crossed that slot, and the DLL
path/image/command-line strings packed immediately after it overwrote the
copied directory. A sufficiently long input also exceeded the total allocation
in an exact-size host allocator.

The iOS adapter now reserves the larger of the existing `MAX_PATH` slot and
the actual current-directory bytes including NUL, uses that same capacity for
`MaximumLength`, and starts the following strings after that capacity. The
initial route measures the DOS path after removing the NT prefix; the child
route uses the server's byte length. Short directories keep their old capacity.

```sh
python3 tests/host/check-startup-cwd-layout.py
```

This compiles the production allocation expressions, packing code and string
helpers under ASan/UBSan. Twenty-four cases cover initial and child startup,
259/260/261-unit boundaries, long UTF-16 paths with surrogate pairs, extended
UNC spellings, an empty child directory, and a representable 32,766-unit string.
It checks that the complete directory and the following strings survive packing,
that capacity includes NUL, and that child input advancement stays correct.
The harness replaces NT allocation with exact-size host allocation; it does not
run Wine, map a filesystem or launch a game.

This is a startup serialization fix, not a claim of complete Windows long-path
support. Other Wine path APIs and `RtlCreateProcessParametersEx` have independent
limits; paths outside `UNICODE_STRING`'s representable range are not covered.
Device launch and gameplay need validation with a matching rebuilt package.
