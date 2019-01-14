# prana [experiment; WIP]

An interpreter for GHC Haskell programs

## Name

प्राण, prāṇa; the Sanskrit word for "life force" or "vital principle"
constructed from pra meaning movement and an meaning constant.

## Implementation challenges

The current implementation is bad and just a feeler.

Challenges:

* Names of Core identifiers are not properly globally unique. GHC's
  Unique is per run of GHC, not global across runs. Make a process
  that normalizes all these names into a monotonically increasing
  integer. Then have a separate mapping from Int to ByteString with a
  human-friendly description of the binding.

* Implement LET and LAMBDA using an environment, rather than
  beta-substitution. Beta-substitution requires reconstructing a fresh
  tree, which is not efficient.

* Once names really are unique, we don't need to do lookups on
  strings, we can instead normalize the numbers to allow O(1) lookup
  in a vector (`Vector Exp`) for globals. For locals, I think we can
  just use a vector (`Vector (Int,Exp)`) and do O(n) lookup; on a
  small enough vector it'll fit in cache and O(n) Int64 comparisons
  over 10 elements is fast.

* Ignoring type applications for which functions don't actually even
  accept an argument for that type. Except tagToEnum _does_ expect a
  type argument. Core is incoherent that way.

* Instead of decoding the AST with the `binary` package, use a
  PatternSynonym (as demonstrated in `Prana.View`) to simply walk the
  AST in a read-only fashion, with no new construction of AST
  nodes. This would (ideally) allow keeping the AST in CPU cache,
  avoiding mainline memory accesses, leading to nice speeds.

* Consider use of unboxed sums for the WHNF data type.

## Setup

Build a docker image with a patched GHC that outputs .prana files:

    $ sh scripts/buildimage.sh

Copy the compiled standard libraries (ghc-prim, integer-gmp and base):

    $ sh scripts/copylibs.sh

Run the demo:

    $ sh scripts/compiledemo.sh

## Architecture

How it works:

* GHC is patched to output .prana files along with .hi and .o files,
  which contain ASTs of the GHC Core for each module along with other
  metadata.
* Prana reads all these files in on start-up and interprets any
  expression or top-level binding desired.
* Prana itself is written in GHC Haskell, so it can re-use GHC's own
  runtime to implement primitive operations.

## Example output

`fib 2` output:

https://gist.github.com/chrisdone/999ef8fa071268511d061ded1884f0f5
