# eg-walker.zig

Eg-walker ([arXiv:2409.14252](https://arxiv.org/abs/2409.14252)) for Zig: an
event graph plus a transient CRDT that merges concurrent text edits and hands
back index based operations. It holds no text: hand it an `egwalker.Sink` and
the patch lands wherever you keep the document. [rope.zig](https://github.com/smartinellimarco/rope.zig)
is one that fits.

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

Edits go into the history and come back out as operations for your buffer, so
local and remote edits travel the same path. Whatever holds the text becomes an
`egwalker.Sink`:

```zig
const egwalker = @import("egwalker");

const Buffer = struct {
    text: MyRope,

    fn sink(self: *Buffer) egwalker.Sink {
        const glue = struct {
            fn insert(ptr: *anyopaque, pos: u32, text: []const u8) egwalker.sink.Error!void {
                const buffer: *Buffer = @ptrCast(@alignCast(ptr));
                return buffer.text.insert(pos, text);
            }
            fn delete(ptr: *anyopaque, pos: u32, count: u32) void {
                const buffer: *Buffer = @ptrCast(@alignCast(ptr));
                buffer.text.delete(pos, count);
            }
        };

        return .{ .ptr = self, .vtable = &.{ .insert = glue.insert, .delete = glue.delete } };
    }
};
```

Positions are unicode character offsets, in both directions.

```zig
var oplog: egwalker.OpLog = .init(gpa, .{ .agent = try egwalker.agent.randomId(io) });
defer oplog.deinit();

var branch: egwalker.Branch = .init(gpa);
defer branch.deinit();

try oplog.insert(0, "hello world");
try oplog.delete(5, 6);

var patch = try branch.merge(&oplog);
defer patch.deinit();

try egwalker.applyPatch(buffer.sink(), &patch);   // "hello"
```

Every merge returns only what is new, already transformed against everything
concurrent, and cursors ride along instead of being recomputed:

```zig
cursor = egwalker.mapCursor(cursor, .after, &patch);
```

Or walk the operations yourself when the buffer needs more than two calls:

```zig
while (patch.next()) |op| switch (op) {
    .insert => |ins| ...,
    .delete => |del| ...,
};
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
