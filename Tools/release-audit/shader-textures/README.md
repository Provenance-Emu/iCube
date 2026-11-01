# Shader target allocation regression

Run `python3 Tools/release-audit/shader-textures/run.py` from the repository root
on a Mac with Xcode/Metal toolchain and a working Metal device. It compiles the
production FilterChain and its shader support files, creates a real default
Metal library, renders synthetic compiled shader presets, waits for completed
command buffers under Metal validation, and checks the resulting pixels.

The texture allocation, clear-buffer allocation and clear-encoder creation calls
are redirected in a temporary copy to fault-injection helpers. Successful allocations still reach the real
Metal device; specified calls return nil to test recoverable allocation/encoder failures without
exhausting device memory. No app or core build is needed.

`python3 Tools/release-audit/shader-textures/run.py --baseline 322f8d99cf`
expects the original native descriptor-validation SIGABRT from a synthetic
zero-scale preset. This proves the reachable crash class, not the actual size
or preset responsible for any Sentry event. Core dumps are disabled.

Coverage includes source/viewport/absolute scales, valid scale preservation,
zero/negative/nonfinite/rounded-zero/oversized and chained invalid sizes,
whole-plan preflight, zero viewport lifecycle recovery, source resize with an
unchanged output viewport, feedback/history allocation failure, repeated
failure cleanup, clear-buffer and clear-encoder failure with current-source fallback
and next-frame recovery, retry, and feedback at the final viewport size.

Run `python3 Tools/release-audit/shader-textures/run.py --debug` to compile the
same fixtures with DEBUG diagnostics. An additional first-frame zero-viewport
fixture explicitly enables first-render logging through a process-local
preference override, checks completed command-buffer/clear output, then verifies
immediate valid-frame recovery. No persisted host preference is changed.
