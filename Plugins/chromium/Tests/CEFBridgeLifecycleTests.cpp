// Copyright (c) 2026 Andreas Pihlstrom
// SPDX-License-Identifier: MIT

#include "../Sources/CEFBridge/bridge_lifecycle.h"

#include <cassert>
#include <set>

using cmdy::cef_bridge::BrowserCloseAction;
using cmdy::cef_bridge::BrowserCreatedAction;
using cmdy::cef_bridge::BrowserLifecycleRegistry;
using cmdy::cef_bridge::AuxiliaryBrowserLifecycle;

int main() {
    BrowserLifecycleRegistry lifecycle;

    // Two asynchronous creates keep their own identity regardless of callback
    // order. This is the interleaving that a single global pending handle lost.
    const auto first = lifecycle.reserve();
    const auto second = lifecycle.reserve();
    assert(first != second);
    assert(lifecycle.didCreate(second) == BrowserCreatedAction::accept);
    assert(lifecycle.didCreate(first) == BrowserCreatedAction::accept);

    assert(lifecycle.requestClose(first) == BrowserCloseAction::closeBrowser);
    assert(lifecycle.requestClose(first) == BrowserCloseAction::alreadyClosing);
    assert(lifecycle.didClose(first));

    // A close request racing an asynchronous create must be remembered and
    // applied as soon as CEF supplies the browser object.
    const auto closeBeforeCreate = lifecycle.reserve();
    assert(lifecycle.requestClose(closeBeforeCreate) ==
           BrowserCloseAction::waitForCreation);
    assert(lifecycle.didCreate(closeBeforeCreate) ==
           BrowserCreatedAction::closeImmediately);
    assert(lifecycle.didClose(closeBeforeCreate));

    // Shutdown snapshots every outstanding handle, including creates that have
    // not reached OnAfterCreated yet, and drains them exactly once.
    std::set<intptr_t> expected;
    for (int index = 0; index < 256; ++index) {
        const auto handle = lifecycle.reserve();
        expected.insert(handle);
        if (index % 3 != 0) {
            assert(lifecycle.didCreate(handle) == BrowserCreatedAction::accept);
        }
    }
    for (const auto handle : lifecycle.handles()) {
        if (!expected.contains(handle)) {
            // `second` is still live from the first scenario.
            assert(handle == second);
            continue;
        }
        const auto action = lifecycle.requestClose(handle);
        assert(action == BrowserCloseAction::closeBrowser ||
               action == BrowserCloseAction::waitForCreation);
        if (action == BrowserCloseAction::waitForCreation) {
            assert(lifecycle.didCreate(handle) ==
                   BrowserCreatedAction::closeImmediately);
        }
        assert(lifecycle.didClose(handle));
    }
    assert(lifecycle.requestClose(second) == BrowserCloseAction::closeBrowser);
    assert(lifecycle.didClose(second));
    assert(lifecycle.empty());

    // Secondary browsers such as DevTools have no synchronous bridge handle.
    // Pending creation and out-of-order close callbacks still gate shutdown.
    AuxiliaryBrowserLifecycle auxiliary;
    auxiliary.beginCreate();
    auxiliary.beginCreate();
    assert(!auxiliary.empty());
    assert(auxiliary.pendingCount() == 2);
    auxiliary.didCreate(902);
    auxiliary.didCreate(901);
    assert(auxiliary.pendingCount() == 0);
    assert(auxiliary.liveCount() == 2);
    assert(auxiliary.didClose(901));
    assert(!auxiliary.empty());
    assert(auxiliary.didClose(902));
    assert(auxiliary.empty());

    const auto cancelled = lifecycle.reserve();
    assert(lifecycle.cancelCreation(cancelled));
    assert(lifecycle.didCreate(cancelled) == BrowserCreatedAction::unknownHandle);
    assert(lifecycle.empty());
    return 0;
}
