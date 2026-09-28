# eg-walker.zig

Eg-walker ([arXiv:2409.14252](https://arxiv.org/abs/2409.14252)) for Zig: an
event graph plus a transient CRDT that merges concurrent text edits and hands
back index based operations. Positions are unicode character offsets; the
buffer is the caller's, and a rope is included for when there is none.

## Install

```zsh
    zig fetch --save git+https://github.com/smartinellimarco/eg-walker.zig
```

Then in `build.zig`:

```zig
const egwalker = b.dependency("egwalker", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("egwalker", egwalker.module("egwalker"));
```

## Use

One replica typing. `checkout` replays the whole history into a string:

```zig
const egwalker = @import("egwalker");

var oplog: egwalker.OpLog = .init(gpa, .{ .agent = 1 });
defer oplog.deinit();

try oplog.insert(0, "hello world");
try oplog.delete(5, 6);

const text = try egwalker.checkout(gpa, &oplog);
defer gpa.free(text);        // "hello"
```

An editor keeps a `Branch` instead and merges what arrived since last time.
Every merge returns the operations to apply to the buffer it already has,
already transformed against everything concurrent:

```zig
var branch: egwalker.Branch = .init(gpa);
defer branch.deinit();

var patch = try branch.merge(&oplog);
defer patch.deinit();

while (patch.next()) |op| switch (op) {
    .insert => |ins| try buffer.insert(ins.pos, ins.text),
    .delete => |del| buffer.delete(del.pos, del.len),
};

// Or hand the patch an `egwalker.Sink` and let it do that loop for any buffer.

// Cursors move with the patch instead of being recomputed.
cursor = egwalker.mapCursor(cursor, .after, &patch);
```

Two replicas exchanging changes. The summary says what a replica already has,
per agent, so only the missing events travel:

```zig
var theirs = try remote.versionSummary(gpa);
defer theirs.deinit();

const ranges = try local.rangesMissing(gpa, theirs);
defer gpa.free(ranges);

const bytes = try local.serialize(gpa, ranges);
defer gpa.free(bytes);

try remote.applyWire(bytes);
```

`VersionSummary.encode`/`decode` put that summary on the wire, and
`OpLog.save`/`load` put a whole history on disk. Carrying the bytes is the
caller's job: there is no networking here.

Text can live in the included rope, which indexes by character and by byte:

```zig
var doc: egwalker.Text = try .init(gpa);
defer doc.deinit();

try doc.insertUtf8(0, "hello");
doc.delete(0, 1);
```

## Test

    zig build test

Unit tests only: deterministic and self-contained.

`zig build fuzz` is a separate tool that replays scripts of concurrent edits
over several replicas and checks they all converge. Every knob is explicit,
because each one changes what the run covers:

    zig build fuzz -- --agents 3 --ops 60 --checkpoints 2 --state-limit 64 --from 0 --to 200
    zig build fuzz -- --agents 3 --ops 60 --checkpoints 2 --state-limit 64 --shrink 88
    zig build test --fuzz    # the same simulation, coverage guided

`--shrink` reduces a diverging seed to its smallest script and prints the
operations that produced it, ready to paste into a test. A script that hangs
counts as a divergence.

Zig 0.16.0.

## Sources

- The paper: Gentle, Kleppmann and Howard, *Collaborative Text Editing with
  Eg-walker: Better, Faster, Smaller*
  ([arXiv:2409.14252](https://arxiv.org/abs/2409.14252)).
- [diamond-types](https://github.com/josephg/diamond-types) (ISC), the
  reference implementation, and
  [egwalker-from-scratch](https://github.com/josephg/egwalker-from-scratch)
  (CC0).
