const std = @import("std");
const causal_graph = @import("causal_graph.zig");
const item_tree = @import("item_tree.zig");

const Lv = causal_graph.Lv;
const none = causal_graph.none;

// Characters live in run-length encoded items, so a position in the sequence is
// an item's rank plus an offset inside it.
const Key = u64;

fn keyOf(tree: *item_tree.Tree, id: Lv) Key {
    const loc = tree.locOfId(id);
    return (@as(Key, tree.rankOf(loc)) << 32) | (id - tree.item(loc).lv);
}

// Ranks are only worth computing when two different characters have to be
// ordered; equal ids and the ends of the document answer themselves.
fn orderOrigins(tree: *item_tree.Tree, a: Lv, b: Lv, missing: std.math.Order) std.math.Order {
    if (a == b) return .eq;
    if (a == none) return missing;
    if (b == none) return missing.invert();
    return std.math.order(keyOf(tree, a), keyOf(tree, b));
}

// Yjs/YATA as modified by josephg, which is the ordering Fugue proves to be
// non-interleaving. The paper leaves this choice open.
pub fn integrate(
    tree: *item_tree.Tree,
    cg: causal_graph.CausalGraph,
    new_item: item_tree.Item,
    cursor: *item_tree.Cursor,
) void {
    if (tree.atEnd(cursor.loc)) return;
    if (tree.item(cursor.loc).cur_state != item_tree.not_yet_inserted) return;

    var scanning = false;
    var scan = cursor.loc;
    var scan_effect_pos = cursor.effect_pos;

    while (!tree.atEnd(scan)) {
        const other = tree.item(scan);
        // Concurrent inserts can only land between here and the first item that
        // already existed when this insert was made.
        if (other.cur_state != item_tree.not_yet_inserted) break;

        // A missing left origin is the start of the document, a missing right
        // parent is its end.
        const side = orderOrigins(tree, other.origin_left, new_item.origin_left, .lt);

        if (side == .lt) break;
        if (side == .eq) {
            const right_side = orderOrigins(tree, other.right_parent, new_item.right_parent, .gt);

            if (right_side == .eq and cg.lvOrder(new_item.lv, other.lv) == .lt) break;
            scanning = right_side == .lt;
        }

        scan_effect_pos += other.widthInEffect();
        scan = tree.nextLoc(scan);

        if (!scanning) {
            cursor.loc = scan;
            cursor.effect_pos = scan_effect_pos;
        }
    }
}
